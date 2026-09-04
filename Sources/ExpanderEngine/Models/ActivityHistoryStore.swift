import Foundation

/// Bounded ring buffer of the most recent system activity and events.
///
/// Designed to capture actionable occurrences that toasts alone might drop:
/// expansion failures, secure input changes, library errors, import summaries,
/// AI/dictation issues, and hotkey registration conflicts.
public final class ActivityHistoryStore {
    public static let shared = ActivityHistoryStore()

    /// Subsystems may report from worker actors/queues. The finite typed signal is what reaches
    /// disk; localization is deferred until presentation. Centralizing the main-thread hop keeps
    /// notification delivery deterministic and LocalizationManager's mutable language state off
    /// worker queues while deriving the signal's routing metadata.
    public static func publish(_ signal: ActivitySignal) {
        let work = {
            _ = ActivityHistoryStore.shared.record(signal)
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    public enum EventCategory: String, Codable, Sendable {
        case expansion
        case secureInput
        case library
        case importExport
        case ai
        case voice
        case hotkey
        case general
    }

    public enum EventAction: String, Codable, Sendable {
        case none
        case openPermissionRecovery
        case openSnippetManager
        case openPreferences
        case openAIPreferences
        case openVoicePreferences
        case openHotkeyPreferences
        case openLab
        case copyDiagnostics
        case reviewRecoveredVoice
    }

    public enum MutationResult: Equatable, Sendable {
        case persisted
        /// Type-only failure evidence; paths and event text never enter diagnostics.
        case persistenceFailed(String)

        /// Safe public-log vocabulary. The associated failure kind remains available to the
        /// in-process health UI but is never interpolated through `String(describing:)`.
        var diagnosticLabel: String {
            switch self {
            case .persisted: return "persisted"
            case .persistenceFailed: return "persistence_failed"
            }
        }
    }

    /// Stable, privacy-safe persistence health vocabulary. Callers can distinguish a hostile or
    /// corrupted input from a filesystem write failure without exposing a path or NSError text.
    public enum PersistenceFailureKind: String, Equatable, Sendable {
        case fileTooLarge = "file_too_large"
        case invalidContent = "invalid_content"
        case readFailed = "read_failed"
        case outputTooLarge = "output_too_large"
        case writeFailed = "write_failed"
    }

    public struct PersistenceHealth: Equatable, Sendable {
        public let lastFailureKind: String?

        public init(lastFailureKind: String?) {
            self.lastFailureKind = lastFailureKind
        }

        public var isHealthy: Bool { lastFailureKind == nil }
    }

    public struct ActivityEvent: Identifiable, Codable, Equatable, Sendable {
        public struct Presentation: Equatable, Sendable {
            public let title: String
            public let details: String
        }

        /// Versioned separately from the surrounding event envelope so future typed payloads can
        /// migrate without invalidating the stable timestamp/category/action fields. Legacy rows
        /// have no version or signal and continue to decode through their literal title/details.
        private static let currentContentVersion = 1

        public let id: UUID
        public let timestamp: Date
        public let category: EventCategory
        public let action: EventAction
        /// Opaque identifier used to replace a repeated state instead of filling the ring with a
        /// polling storm. It must never contain user-authored text.
        public let deduplicationKey: String?
        /// Opaque resource identity for an action such as reviewing a retained voice session.
        public let referenceID: String?
        /// New activity uses a finite, Codable signal rather than persisting localized UI copy.
        /// Associated values are bounded enums, booleans, counters, or OSStatus values; there is
        /// no field capable of carrying selected text, transcripts, paths, or error descriptions.
        public let typedSignal: ActivitySignal?

        private let legacyTitle: String?
        private let legacyDetails: String?

        /// Compatibility accessors now render typed rows in the currently selected language.
        /// UI that needs deterministic localization should call `presentation(localization:)`.
        public var title: String { presentation(localization: .shared).title }
        public var details: String { presentation(localization: .shared).details }

        public init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            category: EventCategory,
            title: String,
            details: String,
            action: EventAction = .none,
            deduplicationKey: String? = nil,
            referenceID: String? = nil
        ) {
            self.id = id
            self.timestamp = timestamp
            self.category = category
            self.action = action
            self.deduplicationKey = deduplicationKey.map {
                Self.bounded($0, maximum: ActivityHistoryStore.maximumOpaqueIdentifierCharacters)
            }
            self.referenceID = referenceID.map {
                Self.bounded($0, maximum: ActivityHistoryStore.maximumOpaqueIdentifierCharacters)
            }
            self.typedSignal = nil
            self.legacyTitle = Self.bounded(
                title,
                maximum: ActivityHistoryStore.maximumLegacyTitleCharacters
            )
            self.legacyDetails = Self.bounded(
                details,
                maximum: ActivityHistoryStore.maximumLegacyDetailsCharacters
            )
        }

        public init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            signal: ActivitySignal,
            localization: LocalizationManager = .shared
        ) {
            let descriptor = signal.descriptor(localization: localization)
            self.id = id
            self.timestamp = timestamp
            self.category = descriptor.category
            self.action = descriptor.action
            self.deduplicationKey = descriptor.deduplicationKey
            self.referenceID = descriptor.referenceID
            self.typedSignal = signal
            self.legacyTitle = nil
            self.legacyDetails = nil
        }

        public func presentation(localization: LocalizationManager = .shared) -> Presentation {
            if let typedSignal {
                let descriptor = typedSignal.descriptor(localization: localization)
                return Presentation(title: descriptor.title, details: descriptor.details)
            }
            return Presentation(
                title: legacyTitle ?? "",
                details: legacyDetails ?? ""
            )
        }

        fileprivate func replacingID(_ id: UUID) -> ActivityEvent {
            ActivityEvent(
                id: id,
                timestamp: timestamp,
                category: category,
                action: action,
                deduplicationKey: deduplicationKey,
                referenceID: referenceID,
                typedSignal: typedSignal,
                legacyTitle: legacyTitle,
                legacyDetails: legacyDetails
            )
        }

        private init(
            id: UUID,
            timestamp: Date,
            category: EventCategory,
            action: EventAction,
            deduplicationKey: String?,
            referenceID: String?,
            typedSignal: ActivitySignal?,
            legacyTitle: String?,
            legacyDetails: String?
        ) {
            self.id = id
            self.timestamp = timestamp
            self.category = category
            self.action = action
            self.deduplicationKey = deduplicationKey.map {
                Self.bounded($0, maximum: ActivityHistoryStore.maximumOpaqueIdentifierCharacters)
            }
            self.referenceID = referenceID.map {
                Self.bounded($0, maximum: ActivityHistoryStore.maximumOpaqueIdentifierCharacters)
            }
            self.typedSignal = typedSignal
            self.legacyTitle = legacyTitle.map {
                Self.bounded($0, maximum: ActivityHistoryStore.maximumLegacyTitleCharacters)
            }
            self.legacyDetails = legacyDetails.map {
                Self.bounded($0, maximum: ActivityHistoryStore.maximumLegacyDetailsCharacters)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case timestamp
            case category
            case title
            case details
            case action
            case deduplicationKey
            case referenceID
            case contentVersion
            case typedSignal
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            category = try container.decode(EventCategory.self, forKey: .category)
            action = try container.decodeIfPresent(EventAction.self, forKey: .action) ?? .none
            let decodedDeduplicationKey = try container.decodeIfPresent(
                String.self,
                forKey: .deduplicationKey
            )
            let decodedReferenceID = try container.decodeIfPresent(String.self, forKey: .referenceID)
            guard Self.isWithinBound(
                decodedDeduplicationKey,
                maximum: ActivityHistoryStore.maximumOpaqueIdentifierCharacters
            ), Self.isWithinBound(
                decodedReferenceID,
                maximum: ActivityHistoryStore.maximumOpaqueIdentifierCharacters
            ) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deduplicationKey,
                    in: container,
                    debugDescription: "Activity event opaque metadata exceeds its bound"
                )
            }
            deduplicationKey = decodedDeduplicationKey
            referenceID = decodedReferenceID

            let contentVersion = try container.decodeIfPresent(Int.self, forKey: .contentVersion)
            if contentVersion == Self.currentContentVersion {
                typedSignal = try container.decode(ActivitySignal.self, forKey: .typedSignal)
                legacyTitle = nil
                legacyDetails = nil
            } else {
                typedSignal = nil
                let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
                let decodedDetails = try container.decodeIfPresent(String.self, forKey: .details)
                guard Self.isWithinBound(
                    decodedTitle,
                    maximum: ActivityHistoryStore.maximumLegacyTitleCharacters
                ), Self.isWithinBound(
                    decodedDetails,
                    maximum: ActivityHistoryStore.maximumLegacyDetailsCharacters
                ) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .details,
                        in: container,
                        debugDescription: "Legacy activity copy exceeds its presentation bound"
                    )
                }
                legacyTitle = decodedTitle
                legacyDetails = decodedDetails
            }

            guard typedSignal != nil || (legacyTitle != nil && legacyDetails != nil) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .contentVersion,
                    in: container,
                    debugDescription: "Activity event has neither a supported typed payload nor legacy copy"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(category, forKey: .category)
            try container.encode(action, forKey: .action)
            try container.encodeIfPresent(deduplicationKey, forKey: .deduplicationKey)
            try container.encodeIfPresent(referenceID, forKey: .referenceID)
            if let typedSignal {
                try container.encode(Self.currentContentVersion, forKey: .contentVersion)
                try container.encode(typedSignal, forKey: .typedSignal)
            } else {
                try container.encode(legacyTitle ?? "", forKey: .title)
                try container.encode(legacyDetails ?? "", forKey: .details)
            }
        }

        private static func bounded(_ value: String, maximum: Int) -> String {
            guard value.count > maximum else { return value }
            return String(value.prefix(maximum))
        }

        private static func isWithinBound(_ value: String?, maximum: Int) -> Bool {
            guard let value else { return true }
            return value.count <= maximum
        }
    }

    public static let maxEvents = 25
    /// Read one byte beyond the envelope so growth between open and read still fails closed.
    public static let maximumPersistedBytes = 2 * 1_024 * 1_024
    public static let maximumLegacyTitleCharacters = 1_024
    public static let maximumLegacyDetailsCharacters = 8_192
    public static let maximumOpaqueIdentifierCharacters = 512
    public static let didUpdateNotification = Notification.Name("devtype.activityHistory.didUpdate")

    private let lock = NSLock()
    private var events: [ActivityEvent] = []
    private var lastPersistenceFailureKind: String?
    private let fileURL: URL

    /// Finite public-log vocabulary. Keeping the operation typed prevents a future caller from
    /// accidentally treating a path, event title, or other free-form value as public log data.
    private enum MutationOperation: String {
        case record
        case batch
        case clear
        case remove
    }

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let env = ProcessInfo.processInfo.environment[SnippetStore.storeDirEnvKey], !env.isEmpty {
            self.fileURL = URL(fileURLWithPath: env, isDirectory: true).appendingPathComponent("activity-history.json")
        } else {
            self.fileURL = SnippetStore.defaultLocalSupportDirectory.appendingPathComponent("activity-history.json")
        }
        do {
            let loaded = try Self.load(from: self.fileURL)
            let scrubbed = loaded.events.filter { !Self.isLegacyPlaintextRecoveryEvent($0) }
            self.events = scrubbed
            if loaded.hadDiscardedTail || scrubbed.count != loaded.events.count {
                try Self.save(scrubbed, to: self.fileURL)
            }
        } catch {
            self.events = []
            self.lastPersistenceFailureKind = Self.failureKind(
                for: error,
                fallback: .readFailed
            ).rawValue
        }
    }

    @discardableResult
    public func record(
        category: EventCategory,
        title: String,
        details: String,
        action: EventAction = .none,
        deduplicationKey: String? = nil,
        referenceID: String? = nil,
        timestamp: Date = Date()
    ) -> MutationResult {
        lock.lock()
        let proposed = ActivityEvent(
            timestamp: timestamp,
            category: category,
            title: title,
            details: details,
            action: action,
            deduplicationKey: deduplicationKey,
            referenceID: referenceID
        )
        let existingID = proposed.deduplicationKey.flatMap { key in
            events.first(where: { $0.deduplicationKey == key })?.id
        }
        let event = proposed.replacingID(existingID ?? proposed.id)
        var candidate = events
        if let existingID {
            candidate.removeAll { $0.id == existingID }
        }
        candidate.insert(event, at: 0)
        candidate = Array(candidate.prefix(Self.maxEvents))
        let result = persistLocked(candidate)
        lock.unlock()
        publishMutation(result, operation: .record)
        return result
    }

    /// Records one typed subsystem signal. The signal surface intentionally accepts no
    /// user-authored text, file paths, app names, or provider error descriptions; activity
    /// history is persisted and must remain safe to show and export.
    @discardableResult
    public func record(
        _ signal: ActivitySignal,
        localization: LocalizationManager = .shared,
        timestamp: Date = Date()
    ) -> MutationResult {
        let descriptor = signal.descriptor(localization: localization)
        lock.lock()
        let existingID = events.first(where: {
            $0.deduplicationKey == descriptor.deduplicationKey
        })?.id
        let event = ActivityEvent(
            id: existingID ?? UUID(),
            timestamp: timestamp,
            signal: signal,
            localization: localization
        )
        var candidate = events
        if let existingID {
            candidate.removeAll { $0.id == existingID }
        }
        candidate.insert(event, at: 0)
        candidate = Array(candidate.prefix(Self.maxEvents))
        let result = persistLocked(candidate)
        lock.unlock()
        publishMutation(result, operation: .record)
        return result
    }

    /// Persists a newest-first group of related events with one atomic file replacement and one
    /// notification. Launch recovery can surface every retained dictation without synchronously
    /// rewriting the same history file once per session on the main thread.
    ///
    /// Repeated deduplication keys use the first (newest) incoming value and preserve the existing
    /// row identity when one is being refreshed. Events without a key are de-duplicated by id.
    @discardableResult
    public func recordBatch(_ incoming: [ActivityEvent]) -> MutationResult {
        guard !incoming.isEmpty else { return .persisted }

        lock.lock()
        var candidate = events
        for proposed in incoming.reversed() {
            let existingID: UUID?
            if let key = proposed.deduplicationKey {
                existingID = candidate.first(where: { $0.deduplicationKey == key })?.id
                candidate.removeAll { $0.deduplicationKey == key }
            } else {
                existingID = candidate.first(where: { $0.id == proposed.id })?.id
                candidate.removeAll { $0.id == proposed.id }
            }
            let event = proposed.replacingID(existingID ?? proposed.id)
            candidate.insert(event, at: 0)
        }
        candidate = Array(candidate.prefix(Self.maxEvents))

        let result = persistLocked(candidate)
        lock.unlock()
        publishMutation(result, operation: .batch)
        return result
    }

    public func recentEvents(limit: Int = 25) -> [ActivityEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(events.prefix(max(0, limit)))
    }

    @discardableResult
    public func clear() -> MutationResult {
        lock.lock()
        let result = persistLocked([])
        lock.unlock()
        publishMutation(result, operation: .clear)
        return result
    }

    @discardableResult
    public func remove(id: UUID) -> MutationResult {
        lock.lock()
        let candidate = events.filter { $0.id != id }
        guard candidate.count != events.count else {
            lock.unlock()
            return .persisted
        }
        let result = persistLocked(candidate)
        lock.unlock()
        publishMutation(result, operation: .remove)
        return result
    }

    public var persistenceHealth: PersistenceHealth {
        lock.lock()
        defer { lock.unlock() }
        return PersistenceHealth(lastFailureKind: lastPersistenceFailureKind)
    }

    // MARK: - Persistence

    /// Must be called while `lock` is held. A write that did not happen never becomes the visible
    /// in-memory snapshot, so callers cannot mistake an undurable mutation for success.
    private func persistLocked(_ candidate: [ActivityEvent]) -> MutationResult {
        do {
            try Self.save(candidate, to: fileURL)
            events = candidate
            lastPersistenceFailureKind = nil
            return .persisted
        } catch {
            let kind = Self.failureKind(for: error, fallback: .writeFailed).rawValue
            lastPersistenceFailureKind = kind
            return .persistenceFailed(kind)
        }
    }

    private func publishMutation(_ result: MutationResult, operation: MutationOperation) {
        if result == .persisted {
            NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
        } else {
            DevTypeLog.store.error(
                "[Activity] \(operation.rawValue, privacy: .public) failed outcome=\(result.diagnosticLabel, privacy: .public)"
            )
        }
    }

    private struct LoadedHistory {
        let events: [ActivityEvent]
        let hadDiscardedTail: Bool
    }

    private struct BoundedEventArray: Decodable {
        let events: [ActivityEvent]
        let hadDiscardedTail: Bool

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var bounded: [ActivityEvent] = []
            bounded.reserveCapacity(ActivityHistoryStore.maxEvents)
            while !container.isAtEnd, bounded.count < ActivityHistoryStore.maxEvents {
                bounded.append(try container.decode(ActivityEvent.self))
            }
            events = bounded
            hadDiscardedTail = !container.isAtEnd
        }
    }

    private struct PersistenceError: Error {
        let kind: PersistenceFailureKind
    }

    private static func load(from url: URL) throws -> LoadedHistory {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadedHistory(events: [], hadDiscardedTail: false)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PersistenceError(kind: .readFailed)
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: maximumPersistedBytes + 1) ?? Data()
        } catch {
            throw PersistenceError(kind: .readFailed)
        }
        guard data.count <= maximumPersistedBytes else {
            throw PersistenceError(kind: .fileTooLarge)
        }
        do {
            let decoded = try JSONDecoder().decode(BoundedEventArray.self, from: data)
            return LoadedHistory(
                events: decoded.events,
                hadDiscardedTail: decoded.hadDiscardedTail
            )
        } catch {
            throw PersistenceError(kind: .invalidContent)
        }
    }

    private static func save(_ events: [ActivityEvent], to url: URL) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(events)
        } catch {
            throw PersistenceError(kind: .writeFailed)
        }
        guard data.count <= maximumPersistedBytes else {
            throw PersistenceError(kind: .outputTooLarge)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw PersistenceError(kind: .writeFailed)
        }
    }

    private static func failureKind(
        for error: Error,
        fallback: PersistenceFailureKind
    ) -> PersistenceFailureKind {
        (error as? PersistenceError)?.kind ?? fallback
    }

    /// Builds before the recovery redesign persisted the full dictated transcript in `details`
    /// and deleted its source session. Drop those legacy rows on load so upgrading removes the
    /// leaked plaintext rather than carrying it forward indefinitely.
    private static func isLegacyPlaintextRecoveryEvent(_ event: ActivityEvent) -> Bool {
        event.category == .voice
            && event.referenceID == nil
            && event.title == "Recovered dictation"
    }
}
