import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// §1.5: Coalesced usage-statistics sidecar.
///
/// Before this existed, `SnippetStore.incrementUsage` rewrote the entire library
/// on every expansion (full pretty-printed JSON encode + full-file read + SHA256 +
/// atomic write + every store listener fired) — on the thread the event tap lives
/// on. Usage counters are *not* library data: they are per-device telemetry with a
/// completely different write cadence, so they live in their own small file.
///
/// Writes are debounced (~5 s) and flushed on app terminate. Reads are served
/// entirely from memory.
///
/// The file is intentionally **device-local** (never inside the synced library
/// directory): two Macs incrementing the same counter would otherwise produce a
/// permanent iCloud conflict on the hot path.
public final class UsageStatsStore {
    public static let shared = UsageStatsStore()

    /// Per-snippet counters. `lastUsedAt` is new in this sidecar — the library
    /// schema never carried it (§4.5).
    public struct Stat: Codable, Equatable {
        public var usageCount: Int
        public var lastUsedAt: Date?

        public init(usageCount: Int = 0, lastUsedAt: Date? = nil) {
            self.usageCount = usageCount
            self.lastUsedAt = lastUsedAt
        }

        private enum CodingKeys: String, CodingKey {
            case usageCount, lastUsedAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usageCount = try c.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
            lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        }
    }

    /// On-disk envelope. Versioned for the same reason `SnippetDocument` is.
    private struct Document: Codable {
        static let currentSchemaVersion = 1
        var schemaVersion: Int
        /// Keyed by `UUID.uuidString` — JSON object keys must be strings.
        var stats: [String: Stat]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, stats
        }

        init(schemaVersion: Int = Document.currentSchemaVersion, stats: [String: Stat]) {
            self.schemaVersion = schemaVersion
            self.stats = stats
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            stats = try c.decodeIfPresent([String: Stat].self, forKey: .stats) ?? [:]
        }
    }

    public static let fileName = "usage-stats.json"

    /// Debounce window for disk writes.
    public static let defaultFlushInterval: TimeInterval = 5.0

    /// Delay before a failed flush is retried. Long enough to ride out a transient
    /// failure (full disk, iCloud eviction), short enough that counters are not
    /// stranded for a whole debounce window.
    public static let defaultFlushRetryDelay: TimeInterval = 5.0

    private let fileURL: URL
    private let flushInterval: TimeInterval
    private let flushRetryDelay: TimeInterval
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "devtype.usagestats", qos: .utility)

    private var stats: [UUID: Stat] = [:]
    private var dirty = false
    /// Monotonic token: only the newest scheduled flush is allowed to run.
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

    /// - Parameters:
    ///   - fileURL: override for tests; defaults to the device-local support directory.
    ///   - flushInterval: debounce window; pass `0` in tests for immediate writes.
    ///   - flushRetryDelay: delay before a failed write is retried; pass a small
    ///     value in tests.
    public init(
        fileURL: URL? = nil,
        flushInterval: TimeInterval = UsageStatsStore.defaultFlushInterval,
        flushRetryDelay: TimeInterval = UsageStatsStore.defaultFlushRetryDelay
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

    // MARK: - Recording

    /// Records one expansion. Cheap: in-memory mutation plus a debounced write.
    public func recordUsage(for snippetID: UUID, at date: Date = Date()) {
        lock.lock()
        var stat = stats[snippetID] ?? Stat()
        stat.usageCount += 1
        stat.lastUsedAt = date
        stats[snippetID] = stat
        dirty = true
        _revision &+= 1
        lock.unlock()
        scheduleFlush()
    }

    /// §1.5 migration: seeds counters from legacy in-library `usageCount` values.
    /// Only fills IDs the sidecar has never seen, so it is idempotent and never
    /// resurrects a counter the user has since reset.
    public func seedLegacyCounts(from snippets: [SnippetModel]) {
        var changed = false
        lock.lock()
        for snippet in snippets where snippet.usageCount > 0 {
            if stats[snippet.id] == nil {
                stats[snippet.id] = Stat(usageCount: snippet.usageCount, lastUsedAt: nil)
                changed = true
            }
        }
        if changed {
            dirty = true
            _revision &+= 1
        }
        lock.unlock()
        if changed { scheduleFlush() }
    }

    /// Convenience wrapper for the group-shaped library.
    public func seedLegacyCounts(from groups: [SnippetGroup]) {
        seedLegacyCounts(from: groups.flatMap(\.snippets))
    }

    public func reset(for snippetID: UUID) {
        lock.lock()
        if stats.removeValue(forKey: snippetID) != nil {
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

    // MARK: - Reading

    public func stat(for snippetID: UUID) -> Stat? {
        lock.lock()
        defer { lock.unlock() }
        return stats[snippetID]
    }

    public func usageCount(for snippetID: UUID) -> Int {
        stat(for: snippetID)?.usageCount ?? 0
    }

    public func lastUsedAt(for snippetID: UUID) -> Date? {
        stat(for: snippetID)?.lastUsedAt
    }

    public func allStats() -> [UUID: Stat] {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Total recorded expansions across every snippet (§4.5 statistics surface).
    public func totalUsage() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stats.values.reduce(0) { $0 + $1.usageCount }
    }

    /// Most-used snippet IDs, highest first. Ties broken by recency.
    public func topSnippetIDs(limit: Int = 10) -> [UUID] {
        guard limit > 0 else { return [] }
        let snapshot = allStats()
        let ordered = snapshot.sorted { lhs, rhs in
            if lhs.value.usageCount != rhs.value.usageCount {
                return lhs.value.usageCount > rhs.value.usageCount
            }
            let l = lhs.value.lastUsedAt ?? .distantPast
            let r = rhs.value.lastUsedAt ?? .distantPast
            if l != r { return l > r }
            return lhs.key.uuidString < rhs.key.uuidString
        }
        return ordered.prefix(limit).map(\.key)
    }

    /// Most-recently-used snippet IDs, newest first. Survives relaunch, unlike the
    /// in-memory list `AppDelegate` keeps (§4.5).
    public func recentSnippetIDs(limit: Int = 10) -> [UUID] {
        guard limit > 0 else { return [] }
        let snapshot = allStats()
        let ordered = snapshot
            .filter { $0.value.lastUsedAt != nil }
            .sorted { ($0.value.lastUsedAt ?? .distantPast) > ($1.value.lastUsedAt ?? .distantPast) }
        return ordered.prefix(limit).map(\.key)
    }

    /// Bounded ranking bonus for search (§4.5): frequency plus a recency kicker.
    /// Deliberately capped so a hot snippet cannot outrank an exact trigger match.
    public func rankBoost(for snippetID: UUID) -> Int {
        guard let stat = stat(for: snippetID), stat.usageCount > 0 else { return 0 }
        // log2-ish saturating curve: 1 use -> 1, 4 -> 3, 64 -> 7, capped at 10.
        var boost = 0
        var remaining = stat.usageCount
        while remaining > 0 && boost < 10 {
            boost += 1
            remaining /= 2
        }
        if let last = stat.lastUsedAt, Date().timeIntervalSince(last) < 60 * 60 * 24 * 7 {
            boost += 2
        }
        return min(boost, 12)
    }

    // MARK: - Persistence

    /// Writes any pending changes synchronously. Call from `applicationWillTerminate`.
    public func flush() {
        lock.lock()
        // Invalidate any in-flight debounced write so it cannot re-run after us.
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

        var keyed: [String: Stat] = [:]
        keyed.reserveCapacity(snapshot.count)
        for (id, stat) in snapshot { keyed[id.uuidString] = stat }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Document(stats: keyed))
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
                "[Store] Failed to write usage stats: \(error.localizedDescription, privacy: .public)"
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

    private static func loadFromDisk(fileURL: URL) -> [UUID: Stat] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return [:]
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            DevTypeLog.store.error(
                "[Store] Usage stats unreadable at \(fileURL.path, privacy: .public); starting empty"
            )
            return [:]
        }
        var out: [UUID: Stat] = [:]
        out.reserveCapacity(document.stats.count)
        for (key, stat) in document.stats {
            guard let id = UUID(uuidString: key) else { continue }
            out[id] = stat
        }
        return out
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
