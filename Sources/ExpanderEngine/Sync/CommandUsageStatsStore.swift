import Foundation
#if canImport(AppKit)
import AppKit
#endif

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

    private let fileURL: URL
    private let flushInterval: TimeInterval
    private let flushRetryDelay: TimeInterval
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "devtype.commandusagestats", qos: .utility)

    private var stats: [String: Stat] = [:]
    private var dirty = false
    private var flushGeneration: UInt64 = 0
    private var terminateObserver: NSObjectProtocol?
    private var _revision: UInt64 = 0

    /// Test seam: when set, replaces the atomic disk write so failure paths are
    /// reachable without a full disk. `nil` (the default) means production I/O.
    var writeInterceptor: ((Data) throws -> Void)?

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
        if let fileURL {
            self.fileURL = fileURL
        } else if let env = ProcessInfo.processInfo.environment[SnippetStore.storeDirEnvKey], !env.isEmpty {
            self.fileURL = URL(fileURLWithPath: env, isDirectory: true)
                .appendingPathComponent(Self.fileName)
        } else {
            self.fileURL = SnippetStore.defaultLocalSupportDirectory
                .appendingPathComponent(Self.fileName)
        }
        self.flushInterval = max(0, flushInterval)
        self.flushRetryDelay = max(0, flushRetryDelay)
        stats = Self.loadFromDisk(fileURL: self.fileURL)
        installTerminateHook()
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    public var storeFileURL: URL { fileURL }

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

    public func flush() {
        lock.lock()
        flushGeneration &+= 1
        lock.unlock()
        ioQueue.sync { self.writeIfDirty() }
    }

    private func scheduleFlush() {
        lock.lock()
        flushGeneration &+= 1
        let generation = flushGeneration
        lock.unlock()

        if flushInterval == 0 {
            ioQueue.async { [weak self] in self?.writeIfDirty() }
            return
        }

        ioQueue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = generation == self.flushGeneration
            self.lock.unlock()
            guard isCurrent else { return }
            self.writeIfDirty()
        }
    }

    private func writeIfDirty() {
        lock.lock()
        guard dirty else {
            lock.unlock()
            return
        }
        let snapshot = stats
        dirty = false
        lock.unlock()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Document(stats: snapshot))
            try persist(data)
        } catch {
            // Re-arm and schedule exactly one bounded retry. Re-arming alone used
            // to be the whole story: with no flush pending, the counters sat
            // unwritten until some *later* mutation happened to schedule a tick —
            // an indefinite data-loss window after a transient failure. The
            // generation guard collapses overlapping retries the same way it
            // dedupes debounced flushes: any newer mutation or explicit `flush()`
            // supersedes this retry, because that newer work owns the write.
            lock.lock()
            dirty = true
            let generation = flushGeneration
            lock.unlock()
            DevTypeLog.store.error(
                "[Store] Failed to write command usage stats \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            ioQueue.asyncAfter(deadline: .now() + flushRetryDelay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let isCurrent = generation == self.flushGeneration
                self.lock.unlock()
                guard isCurrent else { return }
                self.writeIfDirty()
            }
        }
    }

    /// The atomic disk write, split out so tests can inject failures. Production
    /// path (`writeInterceptor == nil`) is unchanged.
    private func persist(_ data: Data) throws {
        if let writeInterceptor {
            try writeInterceptor(data)
            return
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func loadFromDisk(fileURL: URL) -> [String: Stat] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL), !data.isEmpty,
              let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return [:]
        }
        return document.stats
    }

    private func installTerminateHook() {
        #if canImport(AppKit)
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flush()
        }
        #endif
    }
}
