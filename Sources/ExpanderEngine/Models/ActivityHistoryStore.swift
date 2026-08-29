import Foundation

/// Bounded ring buffer of the most recent system activity and events.
///
/// Designed to capture actionable occurrences that toasts alone might drop:
/// expansion failures, secure input changes, library errors, import summaries,
/// AI/dictation issues, and hotkey registration conflicts.
public final class ActivityHistoryStore {
    public static let shared = ActivityHistoryStore()

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
        case openLab
        case copyDiagnostics
    }

    public struct ActivityEvent: Identifiable, Codable, Equatable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let category: EventCategory
        public let title: String
        public let details: String
        public let action: EventAction

        public init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            category: EventCategory,
            title: String,
            details: String,
            action: EventAction = .none
        ) {
            self.id = id
            self.timestamp = timestamp
            self.category = category
            self.title = title
            self.details = details
            self.action = action
        }
    }

    public static let maxEvents = 25
    public static let didUpdateNotification = Notification.Name("devtype.activityHistory.didUpdate")

    private let lock = NSLock()
    private var events: [ActivityEvent] = []
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let env = ProcessInfo.processInfo.environment[SnippetStore.storeDirEnvKey], !env.isEmpty {
            self.fileURL = URL(fileURLWithPath: env, isDirectory: true).appendingPathComponent("activity-history.json")
        } else {
            self.fileURL = SnippetStore.defaultLocalSupportDirectory.appendingPathComponent("activity-history.json")
        }
        self.events = Self.load(from: self.fileURL)
    }

    public func record(
        category: EventCategory,
        title: String,
        details: String,
        action: EventAction = .none,
        timestamp: Date = Date()
    ) {
        let event = ActivityEvent(
            timestamp: timestamp,
            category: category,
            title: title,
            details: details,
            action: action
        )
        lock.lock()
        events.insert(event, at: 0)
        if events.count > Self.maxEvents {
            events = Array(events.prefix(Self.maxEvents))
        }
        let snapshot = events
        // Persist before releasing the lock so concurrent records cannot enqueue
        // snapshots out of order on a concurrent queue and roll the file back.
        Self.save(snapshot, to: fileURL)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }

    public func recentEvents(limit: Int = 25) -> [ActivityEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(events.prefix(max(0, limit)))
    }

    public func clear() {
        lock.lock()
        events.removeAll()
        Self.save([], to: fileURL)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ActivityEvent].self, from: data) else {
            return []
        }
        return Array(decoded.prefix(maxEvents))
    }

    private static func save(_ events: [ActivityEvent], to url: URL) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
