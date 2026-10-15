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

    private let writer: DebouncedSidecarWriter
    private let ledger: KeyedUsageLedger<String, Stat>

    /// Test seam: when set, replaces the atomic disk write so failure paths are
    /// reachable without a full disk. `nil` (the default) means production I/O.
    var writeInterceptor: ((Data) throws -> Void)? {
        get { writer.writeInterceptor }
        set { writer.writeInterceptor = newValue }
    }

    public var revision: UInt64 { ledger.currentRevision }

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
        ledger = KeyedUsageLedger(stats: Self.loadFromDisk(fileURL: writer.fileURL))
        writer.source = self
        writer.installTerminateHook()
    }

    public var storeFileURL: URL { writer.fileURL }

    public func recordUsage(for commandID: String, at date: Date = Date()) {
        let key = commandID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        ledger.update { stats in
            var stat = stats[key] ?? Stat()
            stat.usageCount += 1
            stat.lastUsedAt = date
            stats[key] = stat
            return true
        }
        scheduleFlush()
    }

    public func stat(for commandID: String) -> Stat? {
        ledger.stat(for: commandID)
    }

    public func usageCount(for commandID: String) -> Int {
        stat(for: commandID)?.usageCount ?? 0
    }

    public func lastUsedAt(for commandID: String) -> Date? {
        stat(for: commandID)?.lastUsedAt
    }

    public func allStats() -> [String: Stat] {
        ledger.allStats()
    }

    public func totalUsage() -> Int {
        ledger.totalUsage { $0.usageCount }
    }

    public func reset(for commandID: String) {
        ledger.reset(for: commandID)
        scheduleFlush()
    }

    public func resetAll() {
        ledger.resetAll()
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
        guard let stat = stat(for: commandID), stat.usageCount > 0 else { return 0 }
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
        let ordered = allStats()
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
        let ordered = allStats()
            .filter { $0.value.lastUsedAt != nil }
            .sorted {
                ($0.value.lastUsedAt ?? .distantPast) > ($1.value.lastUsedAt ?? .distantPast)
            }
        return ordered.prefix(limit).map(\.key)
    }

    public func flush() { writer.flush() }

    private func scheduleFlush() { writer.schedule() }

    private static func loadFromDisk(fileURL: URL) -> [String: Stat] {
        PersistedFileLoader.load(store: "CommandUsageStatsStore", fileURL: fileURL) {
            try JSONDecoder().decode(Document.self, from: $0)
        }.value?.stats ?? [:]
    }
}

extension CommandUsageStatsStore: SidecarPayloadSource {
    func takePendingSidecarPayload() throws -> Data? {
        guard let snapshot = ledger.takeDirtySnapshot() else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(stats: snapshot))
    }

    func reArmPendingSidecarPayload() {
        ledger.rearm()
    }
}
