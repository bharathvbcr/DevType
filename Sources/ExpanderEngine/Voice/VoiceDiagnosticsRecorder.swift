import Foundation

/// Opt-in trace of the live dictation path, written to a local file.
///
/// The unified log carries lengths and outcomes, which is enough to see *that* text was
/// erased but not always *why*. Reproducing an erase needs the actual sequence: which
/// segment arrived, what the assembler made of it, what the reconciler decided. That
/// requires the transcript, and a transcript is exactly what must not go into a system log
/// that other software can read.
///
/// So it goes here instead: off by default, written only to a file in the app's own
/// container, and only while the user has switched it on to capture a problem.
public final class VoiceDiagnosticsRecorder: @unchecked Sendable {
    public static let shared = VoiceDiagnosticsRecorder()

    /// Cap on the trace file. A dictation produces a few hundred lines; this is generous
    /// for several sessions and small enough to attach to a bug report.
    public static let maxBytes = 4 * 1024 * 1024
    /// Content-free terminal summaries are always on, so their retention is deliberately much
    /// smaller than the opt-in transcript trace.
    public static let maxTerminalEntries = 64
    public static let maxTerminalBytes = 64 * 1024

    /// Serializes the point at which a record is accepted with destructive operations. Once
    /// `record` returns `.accepted`, its append is already ahead of a subsequent clear/delete.
    private let submissionLock = UnfairLock()
    private let queue = DispatchQueue(label: "com.devtype.voice.diagnostics", qos: .utility)
    private let fileURL: URL
    private let terminalManifestURL: URL
    private let beforeAppendForTesting: (() -> Void)?
    private let afterAppendForTesting: (() -> Void)?
    private let afterTerminalManifestSizeCheckForTesting: (() -> Void)?
    /// Injectable only so tests can prove a chmod failure is not reported as a successful write.
    /// Production uses `FileManager.setAttributes`, after which the resulting mode is read back.
    private let permissionSetter: (_ url: URL, _ mode: Int) throws -> Void
    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private var writeStatus: IOStatus = .notAttempted
    private var readStatus: IOStatus = .notAttempted
    private var traceReadCoverage: TraceReadCoverage?
    private var deleteStatus: IOStatus = .notAttempted
    private var terminalWriteStatus: IOStatus = .notAttempted
    private var terminalReadStatus: IOStatus = .notAttempted
    private var terminalDeleteStatus: IOStatus = .notAttempted
    private var terminalEntries: [VoiceTerminalDiagnostic] = []
    /// Entries accepted by this process that have not reached the atomic on-disk manifest yet.
    /// IDs keep this exact when a later write fails after older entries were persisted.
    private var volatileTerminalEntryIDs: Set<UUID> = []
    private var terminalObservedCount: UInt64 = 0
    private var terminalEncodedByteCount = 0
    private var didLoadTerminalManifest = false

    private init() {
        fileURL = Self.traceURL
        terminalManifestURL = Self.terminalManifestURL
        beforeAppendForTesting = nil
        afterAppendForTesting = nil
        afterTerminalManifestSizeCheckForTesting = nil
        permissionSetter = Self.setPOSIXPermissions
    }

    /// Isolated file seam for deterministic queue, retention, and I/O-failure tests.
    init(
        traceURL: URL,
        terminalManifestURL: URL? = nil,
        beforeAppendForTesting: (() -> Void)? = nil,
        afterAppendForTesting: (() -> Void)? = nil,
        afterTerminalManifestSizeCheckForTesting: (() -> Void)? = nil,
        permissionSetter: ((_ url: URL, _ mode: Int) throws -> Void)? = nil
    ) {
        fileURL = traceURL
        self.terminalManifestURL = terminalManifestURL
            ?? traceURL.deletingLastPathComponent().appendingPathComponent("voice-terminal-manifest.json")
        self.beforeAppendForTesting = beforeAppendForTesting
        self.afterAppendForTesting = afterAppendForTesting
        self.afterTerminalManifestSizeCheckForTesting = afterTerminalManifestSizeCheckForTesting
        self.permissionSetter = permissionSetter ?? Self.setPOSIXPermissions
    }

    // MARK: - Location

    public static var traceURL: URL {
        supportDirectory.appendingPathComponent("voice-trace.jsonl")
    }

    public static var terminalManifestURL: URL {
        supportDirectory.appendingPathComponent("voice-terminal-manifest.json")
    }

    private static var supportDirectory: URL {
        (FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("DevType", isDirectory: true)
    }

    /// Whether tracing is on. Off by default — this records what the user dictated.
    public var isEnabled: Bool {
        get {
            submissionLock.withLock { VoicePreferences.isVoiceTracingEnabled }
        }
        set {
            submissionLock.withLock { VoicePreferences.isVoiceTracingEnabled = newValue }
        }
    }

    // MARK: - I/O state

    public enum RecordDisposition: Equatable, Sendable {
        /// The event is ordered on the recorder queue. Call `read()` or `ioHealth` to wait for it.
        case accepted
        case disabled
    }

    /// Content-free failure classes. Never carry a path, transcript, note, or error description.
    public enum IOFailure: String, Equatable, Sendable {
        case encoding
        case eventExceedsLimit
        case directoryCreation
        case directoryPermissions
        case filePermissions
        case open
        case seek
        case truncate
        case write
        case close
        case read
        case invalidUTF8
        case decoding
        case manifestExceedsLimit
        case traceExceedsLimit
        case delete
    }

    /// `notAttempted` is deliberately distinct from success: an unchecked channel is not healthy.
    public enum IOStatus: Equatable, Sendable {
        case notAttempted
        case succeeded
        case failed(IOFailure)
    }

    public struct IOHealth: Equatable, Sendable {
        public let write: IOStatus
        public let read: IOStatus
        public let delete: IOStatus
        public let terminalWrite: IOStatus
        public let terminalRead: IOStatus
        public let terminalDelete: IOStatus
        /// Byte coverage from the most recent opt-in trace read. `observed = retained + dropped`;
        /// rollover metadata carries cumulative dropped bytes across process launches. An
        /// oversized current file is refused, so retained is zero and dropped is its observed size.
        public let traceReadCoverage: TraceReadCoverage?

        public var hasFailure: Bool {
            if case .failed = write { return true }
            if case .failed = read { return true }
            if case .failed = delete { return true }
            if case .failed = terminalWrite { return true }
            if case .failed = terminalRead { return true }
            if case .failed = terminalDelete { return true }
            return false
        }
    }

    public struct TraceReadCoverage: Equatable, Sendable {
        public let observedByteCount: UInt64
        public let retainedByteCount: Int
        public let droppedByteCount: UInt64
        public let isComplete: Bool

        public init(
            observedByteCount: UInt64,
            retainedByteCount: Int,
            droppedByteCount: UInt64,
            isComplete: Bool
        ) {
            self.observedByteCount = observedByteCount
            self.retainedByteCount = retainedByteCount
            self.droppedByteCount = droppedByteCount
            self.isComplete = isComplete
        }
    }

    /// Waits for pending recorder work, then returns typed state without exposing error payloads.
    public var ioHealth: IOHealth {
        queue.sync {
            IOHealth(
                write: writeStatus,
                read: readStatus,
                delete: deleteStatus,
                terminalWrite: terminalWriteStatus,
                terminalRead: terminalReadStatus,
                terminalDelete: terminalDeleteStatus,
                traceReadCoverage: traceReadCoverage
            )
        }
    }

    public enum TerminalRecordDisposition: Equatable, Sendable {
        case persisted
        /// The bounded in-process entry remains reportable, but the manifest did not reach disk.
        case retainedInMemory(IOFailure)
    }

    private struct TerminalManifest: Codable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let observedCount: UInt64
        let entries: [VoiceTerminalDiagnostic]
    }

    // MARK: - Events

    /// One line of the trace. Field names are short because these are read as a column of
    /// JSON, often hundreds at a time.
    public struct Event: Codable, Sendable {
        public let at: Date
        public let kind: String
        /// Segment identity, when the event concerns one.
        public let segment: String?
        public let revision: UInt64?
        public let finality: String?
        /// The dictated text at this point. Present only because the whole purpose of this
        /// file is to reproduce a text defect.
        public let text: String?
        /// Assembler view.
        public let settled: String?
        public let active: String?
        public let cumulative: String?
        /// Reconciler decision.
        public let committedLength: Int?
        public let volatileLength: Int?
        public let erase: Int?
        public let inject: String?
        public let suppressed: Bool?
        public let note: String?
        /// Cumulative bytes discarded before this retained event because the bounded trace rolled
        /// over. Optional so every legacy JSONL event remains decodable without migration.
        public let droppedBytes: UInt64?

        fileprivate func markingRollover(droppedBytes: UInt64) -> Event {
            Event(
                at: at,
                kind: kind,
                segment: segment,
                revision: revision,
                finality: finality,
                text: text,
                settled: settled,
                active: active,
                cumulative: cumulative,
                committedLength: committedLength,
                volatileLength: volatileLength,
                erase: erase,
                inject: inject,
                suppressed: suppressed,
                note: note,
                droppedBytes: droppedBytes
            )
        }
    }

    // MARK: - Recording

    @discardableResult
    public func record(
        _ kind: String,
        segment: SpeechSegment? = nil,
        settled: String? = nil,
        active: String? = nil,
        cumulative: String? = nil,
        committedLength: Int? = nil,
        volatileLength: Int? = nil,
        erase: Int? = nil,
        inject: String? = nil,
        suppressed: Bool? = nil,
        note: String? = nil
    ) -> RecordDisposition {
        submissionLock.withLock {
            guard VoicePreferences.isVoiceTracingEnabled else { return .disabled }

            let event = Event(
                at: Date(),
                kind: kind,
                segment: segment?.segmentID,
                revision: segment?.revision,
                finality: segment.map { $0.finality == .final ? "final" : "volatile" },
                text: segment?.text,
                settled: settled,
                active: active,
                cumulative: cumulative,
                committedLength: committedLength,
                volatileLength: volatileLength,
                erase: erase,
                inject: inject,
                suppressed: suppressed,
                note: note,
                droppedBytes: nil
            )

            queue.async { [self] in
                beforeAppendForTesting?()
                defer { afterAppendForTesting?() }
                append(event)
            }
            return .accepted
        }
    }

    private func append(_ event: Event) {
        var data: Data
        do {
            data = try encoder.encode(event)
        } catch {
            recordWriteFailure(.encoding)
            return
        }
        data.append(0x0A)   // newline

        // One JSON line is indivisible. Keeping a partial line would corrupt every downstream
        // decoder, so an event that cannot fit is rejected and reported through typed health.
        guard data.count <= Self.maxBytes else {
            recordWriteFailure(.eventExceedsLimit)
            return
        }

        let directory = fileURL.deletingLastPathComponent()
        if let failure = prepareDiagnosticsDirectory(directory) {
            recordWriteFailure(failure)
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            do {
                try data.write(to: fileURL, options: .atomic)
                guard enforcePermissions(at: fileURL, mode: 0o600) else {
                    // The containing directory is already 0700, but do not retain a raw transcript
                    // whose own mode violates the privacy contract.
                    try? FileManager.default.removeItem(at: fileURL)
                    recordWriteFailure(.filePermissions)
                    return
                }
                writeStatus = .succeeded
            } catch {
                recordWriteFailure(.write)
            }
            return
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            recordWriteFailure(.open)
            return
        }

        // Tighten a permissive pre-existing trace before appending any new dictated content.
        guard enforcePermissions(at: fileURL, mode: 0o600) else {
            try? handle.close()
            recordWriteFailure(.filePermissions)
            return
        }

        var operation: IOFailure = .seek
        do {
            let currentBytes = try handle.seekToEnd()
            let eventBytes = UInt64(data.count)
            let projected = currentBytes.addingReportingOverflow(eventBytes)

            // Decide from the projected size, not the old size. This keeps every successful
            // append at or below the cap even when the old file is exactly at the boundary.
            if projected.overflow || projected.partialValue > UInt64(Self.maxBytes) {
                let previouslyDropped = persistedTraceDroppedByteCount()
                let cumulativeDropped = Self.saturatingAdd(previouslyDropped, currentBytes)
                do {
                    data = try encoder.encode(
                        event.markingRollover(droppedBytes: cumulativeDropped)
                    )
                    data.append(0x0A)
                } catch {
                    try? handle.close()
                    recordWriteFailure(.encoding)
                    return
                }
                // Rollover metadata is part of the retained event rather than a second line, so
                // existing JSONL consumers keep one-event-per-record behavior. If the enriched
                // record cannot fit, preserve the old trace and fail before truncating it.
                guard data.count <= Self.maxBytes else {
                    try? handle.close()
                    recordWriteFailure(.eventExceedsLimit)
                    return
                }
                operation = .truncate
                try handle.truncate(atOffset: 0)
                operation = .seek
                try handle.seek(toOffset: 0)
            }

            operation = .write
            try handle.write(contentsOf: data)

            // Verify the postcondition against the file itself. The arithmetic above should make
            // this impossible, but truncating on violation keeps the privacy/retention bound true
            // if a filesystem behaves unexpectedly.
            operation = .seek
            let finalBytes = try handle.seekToEnd()
            if finalBytes > UInt64(Self.maxBytes) {
                operation = .truncate
                try handle.truncate(atOffset: 0)
                operation = .close
                try handle.close()
                recordWriteFailure(.eventExceedsLimit)
                return
            }

            operation = .close
            try handle.close()
            guard enforcePermissions(at: fileURL, mode: 0o600) else {
                recordWriteFailure(.filePermissions)
                return
            }
            writeStatus = .succeeded
        } catch {
            // Best-effort cleanup after the primary, typed failure has already been identified.
            try? handle.close()
            recordWriteFailure(operation)
        }
    }

    /// Reads only through the recorder's existing bounded/permission-verified path. Rollover is
    /// rare, so re-reading at most four MiB is preferable to a second sidecar whose durability
    /// could diverge from the JSONL file it describes.
    private func persistedTraceDroppedByteCount() -> UInt64 {
        switch boundedFileRead(at: fileURL, maximumBytes: Self.maxBytes) {
        case .complete(let data, _):
            return Self.persistedDroppedByteCount(in: data)
        case .exceedsLimit, .incomplete, .permissionsFailed, .failed:
            return 0
        }
    }

    private static func persistedDroppedByteCount(in data: Data) -> UInt64 {
        let firstLineEnd = data.firstIndex(of: 0x0A) ?? data.endIndex
        guard firstLineEnd > data.startIndex else { return 0 }
        let firstLine = data[data.startIndex..<firstLineEnd]
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(firstLine)) else {
            return 0
        }
        return event.droppedBytes ?? 0
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? UInt64.max : sum.partialValue
    }

    private func recordWriteFailure(_ failure: IOFailure) {
        writeStatus = .failed(failure)
        DevTypeLog.voice.error(
            "[VoiceTrace] write unavailable reason=\(failure.rawValue, privacy: .public)"
        )
    }

    /// Creates (or tightens) the directory that contains diagnostics. `createDirectory`'s
    /// attributes apply only to a newly created final component, so an existing permissive
    /// directory needs the explicit read-back-verified permission step as well.
    private func prepareDiagnosticsDirectory(_ directory: URL) -> IOFailure? {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .directoryCreation
        }
        return enforcePermissions(at: directory, mode: 0o700) ? nil : .directoryPermissions
    }

    private static func setPOSIXPermissions(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: url.path
        )
    }

    /// Applies and verifies the requested owner-only mode. A setter that returns without changing
    /// the inode is still a failure; diagnostics must never call an unchecked chmod a success.
    private func enforcePermissions(at url: URL, mode: Int) -> Bool {
        do {
            try permissionSetter(url, mode)
            guard let permissions = try FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else {
                return false
            }
            return (permissions.intValue & 0o777) == mode
        } catch {
            return false
        }
    }

    // MARK: - Content-free terminal manifest

    /// Persists one finite-vocabulary terminal summary even when transcript tracing is disabled.
    /// The write is synchronous on the recorder queue so `.persisted` means the atomic manifest
    /// replacement completed before this method returned.
    @discardableResult
    public func recordTerminal(
        _ diagnostic: VoiceTerminalDiagnostic
    ) -> TerminalRecordDisposition {
        submissionLock.withLock {
            queue.sync { recordTerminalOnQueue(diagnostic) }
        }
    }

    private func recordTerminalOnQueue(
        _ diagnostic: VoiceTerminalDiagnostic
    ) -> TerminalRecordDisposition {
        if let loadFailure = loadTerminalManifestIfNeeded() {
            // Preserve the new typed observation in memory, but never replace an existing manifest
            // from an empty projection that was empty only because its read failed.
            var candidate = terminalEntries
            let isNewObservation = !candidate.contains { $0.id == diagnostic.id }
            candidate.removeAll { $0.id == diagnostic.id }
            candidate.append(diagnostic)
            if candidate.count > Self.maxTerminalEntries {
                candidate.removeFirst(candidate.count - Self.maxTerminalEntries)
            }
            terminalEntries = candidate
            volatileTerminalEntryIDs.insert(diagnostic.id)
            volatileTerminalEntryIDs.formIntersection(Set(candidate.map(\.id)))
            if isNewObservation {
                terminalObservedCount = Self.saturatingAdd(terminalObservedCount, 1)
            }
            return recordTerminalWriteFailure(loadFailure)
        }

        var candidate = terminalEntries
        let isNewObservation: Bool
        if let existingIndex = candidate.firstIndex(where: { $0.id == diagnostic.id }) {
            candidate.remove(at: existingIndex)
            isNewObservation = false
        } else {
            isNewObservation = true
        }
        candidate.append(diagnostic)
        if candidate.count > Self.maxTerminalEntries {
            candidate.removeFirst(candidate.count - Self.maxTerminalEntries)
        }
        volatileTerminalEntryIDs.insert(diagnostic.id)
        volatileTerminalEntryIDs.formIntersection(Set(candidate.map(\.id)))

        let incremented = terminalObservedCount.addingReportingOverflow(1)
        let observed = isNewObservation
            ? (incremented.overflow ? UInt64.max : incremented.partialValue)
            : terminalObservedCount
        var data: Data
        do {
            data = try encodedTerminalManifest(entries: candidate, observedCount: observed)
            while data.count > Self.maxTerminalBytes, candidate.count > 1 {
                candidate.removeFirst()
                data = try encodedTerminalManifest(entries: candidate, observedCount: observed)
            }
            volatileTerminalEntryIDs.formIntersection(Set(candidate.map(\.id)))
        } catch {
            terminalEntries = candidate
            terminalObservedCount = observed
            return recordTerminalWriteFailure(.encoding)
        }

        guard data.count <= Self.maxTerminalBytes else {
            terminalEntries = Array(candidate.suffix(1))
            volatileTerminalEntryIDs.formIntersection(Set(terminalEntries.map(\.id)))
            terminalObservedCount = observed
            terminalEncodedByteCount = 0
            return recordTerminalWriteFailure(.eventExceedsLimit)
        }

        terminalEntries = candidate
        terminalObservedCount = observed
        terminalEncodedByteCount = data.count

        if let failure = prepareDiagnosticsDirectory(
            terminalManifestURL.deletingLastPathComponent()
        ) {
            return recordTerminalWriteFailure(failure)
        }

        do {
            try data.write(to: terminalManifestURL, options: .atomic)
            guard enforcePermissions(at: terminalManifestURL, mode: 0o600) else {
                try? FileManager.default.removeItem(at: terminalManifestURL)
                return recordTerminalWriteFailure(.filePermissions)
            }
            terminalWriteStatus = .succeeded
            volatileTerminalEntryIDs.removeAll(keepingCapacity: true)
            return .persisted
        } catch {
            return recordTerminalWriteFailure(.write)
        }
    }

    private func encodedTerminalManifest(
        entries: [VoiceTerminalDiagnostic],
        observedCount: UInt64
    ) throws -> Data {
        try encoder.encode(TerminalManifest(
            schemaVersion: TerminalManifest.schemaVersion,
            observedCount: max(observedCount, UInt64(entries.count)),
            entries: entries
        ))
    }

    @discardableResult
    private func recordTerminalWriteFailure(
        _ failure: IOFailure
    ) -> TerminalRecordDisposition {
        terminalWriteStatus = .failed(failure)
        DevTypeLog.voice.error(
            "[VoiceTerminal] manifest write unavailable reason=\(failure.rawValue, privacy: .public)"
        )
        return .retainedInMemory(failure)
    }

    private enum BoundedFileRead {
        case complete(data: Data, observedByteCount: UInt64)
        case exceedsLimit(observedByteCount: UInt64)
        case incomplete(observedByteCount: UInt64)
        case permissionsFailed
        case failed
    }

    /// Reads one regular file through an already-open descriptor, never accepting more than
    /// `maximumBytes + 1` bytes into memory. The initial extent rejects known oversize files
    /// without reading them; the bounded read and final extent catch growth after that check.
    /// Opening first also makes a path replacement harmless: this operation stays on one inode.
    private func boundedFileRead(
        at url: URL,
        maximumBytes: Int,
        afterInitialSizeCheck: (() -> Void)? = nil
    ) -> BoundedFileRead {
        guard maximumBytes >= 0, maximumBytes < Int.max else { return .failed }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .failed
        }
        defer { try? handle.close() }

        // Apply the mode after opening as well as after every atomic replacement. The enclosing
        // directory has already been reduced to 0700, so this path cannot be swapped by another
        // local account between the open and the verified chmod.
        guard enforcePermissions(at: url, mode: 0o600) else {
            return .permissionsFailed
        }

        do {
            let initialByteCount = try handle.seekToEnd()
            guard initialByteCount <= UInt64(maximumBytes) else {
                return .exceedsLimit(observedByteCount: initialByteCount)
            }

            afterInitialSizeCheck?()
            try handle.seek(toOffset: 0)

            var data = Data()
            data.reserveCapacity(min(maximumBytes + 1, 64 * 1024))
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(remaining, 64 * 1024)),
                      !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }

            let finalByteCount = try handle.seekToEnd()
            let observedByteCount = max(
                max(initialByteCount, finalByteCount),
                UInt64(data.count)
            )
            guard observedByteCount <= UInt64(maximumBytes), data.count <= maximumBytes else {
                return .exceedsLimit(observedByteCount: observedByteCount)
            }
            guard UInt64(data.count) == observedByteCount else {
                return .incomplete(observedByteCount: observedByteCount)
            }
            return .complete(data: data, observedByteCount: observedByteCount)
        } catch {
            return .failed
        }
    }

    /// Returns a typed failure while leaving the latch open for a future retry. `true once` state
    /// is committed only after absence or a decoded manifest has actually been established.
    private func loadTerminalManifestIfNeeded() -> IOFailure? {
        guard !didLoadTerminalManifest else { return nil }

        if let failure = prepareDiagnosticsDirectory(
            terminalManifestURL.deletingLastPathComponent()
        ) {
            terminalReadStatus = .failed(failure)
            return failure
        }

        guard FileManager.default.fileExists(atPath: terminalManifestURL.path) else {
            terminalReadStatus = .succeeded
            terminalEncodedByteCount = 0
            didLoadTerminalManifest = true
            return nil
        }

        let data: Data
        switch boundedFileRead(
            at: terminalManifestURL,
            maximumBytes: Self.maxTerminalBytes,
            afterInitialSizeCheck: afterTerminalManifestSizeCheckForTesting
        ) {
        case .complete(let boundedData, _):
            data = boundedData
        case .exceedsLimit:
            terminalReadStatus = .failed(.manifestExceedsLimit)
            return .manifestExceedsLimit
        case .permissionsFailed:
            terminalReadStatus = .failed(.filePermissions)
            return .filePermissions
        case .incomplete, .failed:
            terminalReadStatus = .failed(.read)
            return .read
        }

        do {
            let manifest = try JSONDecoder().decode(TerminalManifest.self, from: data)
            guard manifest.schemaVersion == TerminalManifest.schemaVersion else {
                terminalReadStatus = .failed(.decoding)
                return .decoding
            }
            let persistedEntries = Array(manifest.entries.suffix(Self.maxTerminalEntries))
            let persistedIDs = Set(persistedEntries.map(\.id))
            let volatileEntries = terminalEntries.filter {
                volatileTerminalEntryIDs.contains($0.id)
            }
            let duplicatedVolatileCount = volatileEntries.reduce(into: UInt64(0)) { count, entry in
                if persistedIDs.contains(entry.id) {
                    count = Self.saturatingAdd(count, 1)
                }
            }
            var combined = persistedEntries
            for volatile in volatileEntries {
                combined.removeAll { $0.id == volatile.id }
                combined.append(volatile)
            }
            if combined.count > Self.maxTerminalEntries {
                combined.removeFirst(combined.count - Self.maxTerminalEntries)
            }
            terminalEntries = combined
            volatileTerminalEntryIDs.formIntersection(Set(combined.map(\.id)))
            let persistedObserved = max(manifest.observedCount, UInt64(manifest.entries.count))
            let novelVolatileObserved = terminalObservedCount >= duplicatedVolatileCount
                ? terminalObservedCount - duplicatedVolatileCount
                : 0
            terminalObservedCount = Self.saturatingAdd(
                persistedObserved,
                novelVolatileObserved
            )
            terminalEncodedByteCount = data.count
            terminalReadStatus = .succeeded
            didLoadTerminalManifest = true
            return nil
        } catch {
            terminalReadStatus = .failed(.decoding)
            return .decoding
        }
    }

    /// Newest retained entries, in chronological order. Free-form content cannot enter the type.
    public func recentTerminalDiagnostics(
        limit: Int = VoiceDiagnosticsRecorder.maxTerminalEntries
    ) -> [VoiceTerminalDiagnostic] {
        queue.sync {
            _ = loadTerminalManifestIfNeeded()
            return Array(terminalEntries.suffix(max(0, limit)))
        }
    }

    /// Lines consumed by `DiagnosticReport`. Both the retained sample and its coverage/cap state
    /// are explicit so a bounded tail can never be mistaken for complete history.
    public func terminalReportLines(limit: Int = 16) -> [String] {
        queue.sync {
            _ = loadTerminalManifestIfNeeded()
            let retained = terminalEntries.count
            let visible = Array(terminalEntries.suffix(max(0, limit)))
            let volatile = volatileTerminalEntryIDs.count
            var lines = [
                "(voice terminal retention — observed=\(terminalObservedCount); "
                    + "retained=\(retained)/\(Self.maxTerminalEntries); "
                    + "bytes=\(terminalEncodedByteCount)/\(Self.maxTerminalBytes); "
                    + "visible=\(visible.count); volatile=\(volatile); "
                    + "terminal-write=\(statusLabel(terminalWriteStatus)); "
                    + "terminal-read=\(statusLabel(terminalReadStatus)))"
            ]
            if retained > visible.count {
                lines.append("(oldest \(retained - visible.count) terminal entries omitted from report)")
            }
            if visible.isEmpty {
                lines.append("(none recorded)")
                return lines
            }

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            lines.append(contentsOf: visible.map { diagnostic in
                "\(iso.string(from: diagnostic.recordedAt)) "
                    + "outcome=\(diagnostic.outcome.rawValue) "
                    + "code=\(diagnostic.code.rawValue) "
                    + "stage=\(diagnostic.stage.rawValue) "
                    + "provider=\(diagnostic.provider.rawValue) "
                    + "locality=\(diagnostic.locality.rawValue) "
                    + "recoverability=\(diagnostic.recoverability.rawValue)"
            })
            return lines
        }
    }

    /// Deletes the always-on, content-free manifest without changing the opt-in trace setting.
    @discardableResult
    public func deleteTerminalDiagnostics() -> IOStatus {
        submissionLock.withLock {
            queue.sync {
                terminalEntries.removeAll(keepingCapacity: false)
                volatileTerminalEntryIDs.removeAll(keepingCapacity: false)
                terminalObservedCount = 0
                terminalEncodedByteCount = 0
                didLoadTerminalManifest = true
                guard FileManager.default.fileExists(atPath: terminalManifestURL.path) else {
                    terminalDeleteStatus = .succeeded
                    return terminalDeleteStatus
                }
                do {
                    try FileManager.default.removeItem(at: terminalManifestURL)
                    terminalDeleteStatus = .succeeded
                } catch {
                    terminalDeleteStatus = .failed(.delete)
                    DevTypeLog.voice.error("[VoiceTerminal] manifest delete unavailable reason=delete")
                }
                return terminalDeleteStatus
            }
        }
    }

    private func statusLabel(_ status: IOStatus) -> String {
        switch status {
        case .notAttempted: return "not-attempted"
        case .succeeded: return "succeeded"
        case .failed(let failure): return "failed(\(failure.rawValue))"
        }
    }

    // MARK: - Retrieval

    /// The trace as text, newest last. `nil` when nothing has been recorded.
    public func read() -> String? {
        queue.sync {
            if let failure = prepareDiagnosticsDirectory(fileURL.deletingLastPathComponent()) {
                readStatus = .failed(failure)
                traceReadCoverage = nil
                return nil
            }

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                readStatus = .succeeded
                traceReadCoverage = TraceReadCoverage(
                    observedByteCount: 0,
                    retainedByteCount: 0,
                    droppedByteCount: 0,
                    isComplete: true
                )
                return nil
            }

            let data: Data
            switch boundedFileRead(at: fileURL, maximumBytes: Self.maxBytes) {
            case .complete(let boundedData, _):
                data = boundedData
            case .exceedsLimit(let observed):
                readStatus = .failed(.traceExceedsLimit)
                traceReadCoverage = TraceReadCoverage(
                    observedByteCount: observed,
                    retainedByteCount: 0,
                    droppedByteCount: observed,
                    isComplete: false
                )
                return nil
            case .incomplete(let observed):
                readStatus = .failed(.read)
                traceReadCoverage = TraceReadCoverage(
                    observedByteCount: observed,
                    retainedByteCount: 0,
                    droppedByteCount: observed,
                    isComplete: false
                )
                return nil
            case .permissionsFailed:
                readStatus = .failed(.filePermissions)
                traceReadCoverage = nil
                return nil
            case .failed:
                readStatus = .failed(.read)
                traceReadCoverage = nil
                return nil
            }

            let droppedByteCount = Self.persistedDroppedByteCount(in: data)
            traceReadCoverage = TraceReadCoverage(
                observedByteCount: Self.saturatingAdd(
                    droppedByteCount,
                    UInt64(data.count)
                ),
                retainedByteCount: data.count,
                droppedByteCount: droppedByteCount,
                isComplete: droppedByteCount == 0
            )
            guard let text = String(data: data, encoding: .utf8) else {
                readStatus = .failed(.invalidUTF8)
                return nil
            }
            readStatus = .succeeded
            return text.isEmpty ? nil : text
        }
    }

    /// Deletes the current trace but leaves capture enabled for a fresh reproduction.
    @discardableResult
    public func deleteTrace() -> IOStatus {
        submissionLock.withLock {
            queue.sync { deleteTraceOnQueue() }
        }
    }

    /// Backward-compatible spelling for a fresh capture.
    @discardableResult
    public func clear() -> IOStatus {
        deleteTrace()
    }

    /// Privacy action for settings/UI: stop accepting events, drain accepted writes, then delete.
    @discardableResult
    public func disableAndDelete() -> IOStatus {
        submissionLock.withLock {
            VoicePreferences.isVoiceTracingEnabled = false
            return queue.sync { deleteTraceOnQueue() }
        }
    }

    private func deleteTraceOnQueue() -> IOStatus {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            deleteStatus = .succeeded
            return deleteStatus
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
            deleteStatus = .succeeded
        } catch {
            deleteStatus = .failed(.delete)
            DevTypeLog.voice.error("[VoiceTrace] delete unavailable reason=delete")
        }
        return deleteStatus
    }

    /// Marks a session boundary so separate dictations are distinguishable in the file.
    @discardableResult
    public func beginSession(engine: String, liveDeliveryMode: String) -> RecordDisposition {
        record(
            "session.begin",
            note: "engine=\(engine) liveDelivery=\(liveDeliveryMode)"
        )
    }
}
