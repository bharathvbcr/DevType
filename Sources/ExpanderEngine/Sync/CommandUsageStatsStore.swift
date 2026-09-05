import Foundation

/// String-keyed usage sidecar for palette commands (`"ai.proofread"`, …).
///
/// Parallel to `UsageStatsStore` (UUID-keyed snippets). Same debounce / terminate
/// flush pattern; separate on-disk file so command IDs never collide with UUIDs.
public final class CommandUsageStatsStore {
    public static let shared = CommandUsageStatsStore()

    public struct Stat: Codable, Equatable {
        public var usageCount: Int
        public var lastUsedAt: Date?

        public init(usageCount: Int = 0, lastUsedAt: Date? = nil) {
            self.usageCount = usageCount
            self.lastUsedAt = lastUsedAt
        }
    }

    private struct Document: Codable {
        static let currentSchemaVersion = 1
        var schemaVersion: Int
        var stats: [String: Stat]

        init(schemaVersion: Int = Document.currentSchemaVersion, stats: [String: Stat]) {
            self.schemaVersion = schemaVersion
            self.stats = stats
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            stats = try c.decodeIfPresent([String: Stat].self, forKey: .stats) ?? [:]
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, stats
        }
    }

    public static let fileName = "command-usage-stats.json"
    public static let defaultFlushInterval: TimeInterval = 5.0

    /// Delay before a failed flush is retried. Long enough to ride out a transient
    /// failure (full disk, iCloud eviction), short enough that counters are not
    /// stranded for a whole debounce window.
    public static let defaultFlushRetryDelay: TimeInterval = 5.0

    private let lock = NSLock()
    private let writer: DebouncedSidecarWriter

    private var stats: [String: Stat] = [:]
    private var dirty = false
    private var _revision: UInt64 = 0

    /// Test seam: when set, replaces the atomic disk write so failure paths are
    /// reachable without a full disk. `nil` (the default) means production I/O.
    var writeInterceptor: ((Data) throws -> Void)? {
        get { writer.writeInterceptor }
        set { writer.writeInterceptor = newValue }
    }

    public var revision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _revision
    }

    public init(
        fileURL: URL? = nil,
        flushInterval: TimeInterval = CommandUsageStatsStore.defaultFlushInterval,
        flushRetryDelay: TimeInterval = CommandUsageStatsStore.defaultFlushRetryDelay
    ) {
        writer = DebouncedSidecarWriter(
            fileURL: DebouncedSidecarWriter.resolveFileURL(
                override: fileURL, fileName: Self.fileName
            ),
            flushInterval: flushInterval,
            flushRetryDelay: flushRetryDelay,
            queueLabel: "devtype.commandusagestats",
            failureMessage: "[Store] Failed to write command usage stats"
        )
        stats = Self.loadFromDisk(fileURL: writer.fileURL)
        writer.source = self
        writer.installTerminateHook()
    }

    public var storeFileURL: URL { writer.fileURL }

    public func recordUsage(for commandID: String, at date: Date = Date()) {
        let key = commandID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        lock.lock()
        var stat = stats[key] ?? Stat()
        stat.usageCount += 1
        stat.lastUsedAt = date
        stats[key] = stat
        dirty = true
        _revision &+= 1
        lock.unlock()
        scheduleFlush()
    }

    public func stat(for commandID: String) -> Stat? {
        lock.lock()
        defer { lock.unlock() }
        return stats[commandID]
    }

    public func usageCount(for commandID: String) -> Int {
        stat(for: commandID)?.usageCount ?? 0
    }

    public func lastUsedAt(for commandID: String) -> Date? {
        stat(for: commandID)?.lastUsedAt
    }

    public func allStats() -> [String: Stat] {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    public func totalUsage() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stats.values.reduce(0) { $0 + $1.usageCount }
    }

    public func reset(for commandID: String) {
        lock.lock()
        if stats.removeValue(forKey: commandID) != nil {
            dirty = true
            _revision &+= 1
        }
        lock.unlock()
        scheduleFlush()
    }

    public func resetAll() {
        lock.lock()
        stats.removeAll()
        dirty = true
        _revision &+= 1
        lock.unlock()
        scheduleFlush()
    }

    /// Personalization weight, log-scaled in usage count with a recency kicker.
    ///
    /// The ceiling used to be 12 against a semantic boost of up to 80, so how often you
    /// actually ran a command was the weakest signal in the palette by a factor of six.
    /// Doubling the per-doubling step and the recency kicker lifts the ceiling to 24 —
    /// comparable to `CommandPaletteCatalog.semanticBoostWeight` (40), so habit competes with
    /// similarity, while still far too small to unseat an exact trigger match (~1000).
    public static let maximumRankBoost = 24

    public func rankBoost(for commandID: String) -> Int {
        lock.lock()
        let stat = stats[commandID]
        lock.unlock()
        guard let stat, stat.usageCount > 0 else { return 0 }
        var boost = 0
        var remaining = stat.usageCount
        while remaining > 0 && boost < 20 {
            boost += 2
            remaining /= 2
        }
        if let last = stat.lastUsedAt, Date().timeIntervalSince(last) < 60 * 60 * 24 * 7 {
            boost += 4
        }
        return min(boost, Self.maximumRankBoost)
    }

    /// Most-used command IDs, highest first. Ties broken by recency.
    public func topCommandIDs(limit: Int = 10) -> [String] {
        guard limit > 0 else { return [] }
        lock.lock()
        let snapshot = stats
        lock.unlock()
        let ordered = snapshot
            .filter { $0.value.usageCount > 0 }
            .sorted { lhs, rhs in
                if lhs.value.usageCount != rhs.value.usageCount {
                    return lhs.value.usageCount > rhs.value.usageCount
                }
                let l = lhs.value.lastUsedAt ?? .distantPast
                let r = rhs.value.lastUsedAt ?? .distantPast
                if l != r { return l > r }
                return lhs.key < rhs.key
            }
        return ordered.prefix(limit).map(\.key)
    }

    /// Most-recently-used command IDs, newest first.
    public func recentCommandIDs(limit: Int = 12) -> [String] {
        guard limit > 0 else { return [] }
        lock.lock()
        let snapshot = stats
        lock.unlock()
        let ordered = snapshot
            .filter { $0.value.lastUsedAt != nil }
            .sorted {
                ($0.value.lastUsedAt ?? .distantPast) > ($1.value.lastUsedAt ?? .distantPast)
            }
        return ordered.prefix(limit).map(\.key)
    }

    public func flush() { writer.flush() }

    private func scheduleFlush() { writer.schedule() }

    private static func loadFromDisk(fileURL: URL) -> [String: Stat] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL), !data.isEmpty,
              let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return [:]
        }
        return document.stats
    }
}

extension CommandUsageStatsStore: SidecarPayloadSource {
    func takePendingSidecarPayload() throws -> Data? {
        lock.lock()
        guard dirty else {
            lock.unlock()
            return nil
        }
        let snapshot = stats
        dirty = false
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(stats: snapshot))
    }

    func reArmPendingSidecarPayload() {
        lock.lock()
        dirty = true
        lock.unlock()
    }
}
