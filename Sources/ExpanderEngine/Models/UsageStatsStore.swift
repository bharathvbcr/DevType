import Foundation

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

    /// Calendar periods offered by the Statistics UI. Bounded periods include
    /// the current calendar day plus the stated number of preceding days.
    public enum Period: Int, CaseIterable {
        case all = 0
        case today = 1
        case sevenDays = 2
        case thirtyDays = 3
    }

    /// One hour of timestamped usage. Hourly aggregation keeps the recording hot
    /// path and sidecar bounded without losing counts when a snippet is expanded
    /// repeatedly in the same hour.
    public struct UsageBucket: Codable, Equatable {
        public var startedAt: Date
        public var usageCount: Int
        public var lastUsedAt: Date

        public init(startedAt: Date, usageCount: Int, lastUsedAt: Date) {
            self.startedAt = startedAt
            self.usageCount = usageCount
            self.lastUsedAt = lastUsedAt
        }
    }

    /// At most 800 non-empty hourly buckets are retained for each snippet. That
    /// covers every hour in the 30-day UI window, including long DST days, while
    /// putting a fixed ceiling on sidecar growth.
    public static let maximumBucketsPerSnippet = 800

    public struct PeriodStat: Equatable {
        public let usageCount: Int
        public let lastUsedAt: Date?

        public init(usageCount: Int, lastUsedAt: Date?) {
            self.usageCount = usageCount
            self.lastUsedAt = lastUsedAt
        }
    }

    public struct TimelinePoint: Equatable {
        public let startedAt: Date
        public let usageCount: Int

        public init(startedAt: Date, usageCount: Int) {
            self.startedAt = startedAt
            self.usageCount = usageCount
        }
    }

    /// One internally consistent view of usage for a selected period. Callers
    /// should derive every displayed metric from this value rather than mixing
    /// lifetime reads with period-filtered reads.
    public struct PeriodSnapshot {
        public let period: Period
        public let generatedAt: Date
        public let entries: [UUID: PeriodStat]
        public let timeline: [TimelinePoint]
        public let totalUsage: Int

        /// Lifetime usages that predate schema v2, or whose old hourly buckets
        /// fell beyond the retention cap. Their count is still exact, but their
        /// timestamps are unknowable, so bounded periods intentionally omit them.
        public let unbucketedUsageCount: Int

        public func usageCount(for snippetID: UUID) -> Int {
            entries[snippetID]?.usageCount ?? 0
        }

        public func lastUsedAt(for snippetID: UUID) -> Date? {
            entries[snippetID]?.lastUsedAt
        }

        public func topSnippetIDs(limit: Int = 10) -> [UUID] {
            guard limit > 0 else { return [] }
            return entries.sorted { lhs, rhs in
                if lhs.value.usageCount != rhs.value.usageCount {
                    return lhs.value.usageCount > rhs.value.usageCount
                }
                let lhsDate = lhs.value.lastUsedAt ?? .distantPast
                let rhsDate = rhs.value.lastUsedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.key.uuidString < rhs.key.uuidString
            }
            .prefix(limit)
            .map(\.key)
        }

        public func recentSnippetIDs(limit: Int = 10) -> [UUID] {
            guard limit > 0 else { return [] }
            return entries
                .filter { $0.value.lastUsedAt != nil }
                .sorted { lhs, rhs in
                    let lhsDate = lhs.value.lastUsedAt ?? .distantPast
                    let rhsDate = rhs.value.lastUsedAt ?? .distantPast
                    if lhsDate != rhsDate { return lhsDate > rhsDate }
                    return lhs.key.uuidString < rhs.key.uuidString
                }
                .prefix(limit)
                .map(\.key)
        }
    }

    /// Per-snippet counters. `lastUsedAt` is new in this sidecar — the library
    /// schema never carried it (§4.5).
    public struct Stat: Codable, Equatable {
        public var usageCount: Int
        public var lastUsedAt: Date?
        public var buckets: [UsageBucket]

        public init(
            usageCount: Int = 0,
            lastUsedAt: Date? = nil,
            buckets: [UsageBucket] = []
        ) {
            self.usageCount = usageCount
            self.lastUsedAt = lastUsedAt
            self.buckets = buckets
        }

        private enum CodingKeys: String, CodingKey {
            case usageCount, lastUsedAt, buckets
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usageCount = try c.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
            lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
            buckets = try c.decodeIfPresent([UsageBucket].self, forKey: .buckets) ?? []
        }
    }

    /// On-disk envelope. Versioned for the same reason `SnippetDocument` is.
    private struct Document: Codable {
        static let currentSchemaVersion = 2
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

    private struct LoadResult {
        var stats: [UUID: Stat]
        var needsRewrite: Bool
    }

    public static let fileName = "usage-stats.json"

    /// Debounce window for disk writes.
    public static let defaultFlushInterval: TimeInterval = 5.0

    /// Delay before a failed flush is retried. Long enough to ride out a transient
    /// failure (full disk, iCloud eviction), short enough that counters are not
    /// stranded for a whole debounce window.
    public static let defaultFlushRetryDelay: TimeInterval = 5.0

    private let lock = NSLock()
    private let writer: DebouncedSidecarWriter

    private var stats: [UUID: Stat] = [:]
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
        writer = DebouncedSidecarWriter(
            fileURL: DebouncedSidecarWriter.resolveFileURL(
                override: fileURL, fileName: Self.fileName
            ),
            flushInterval: flushInterval,
            flushRetryDelay: flushRetryDelay,
            queueLabel: "devtype.usagestats",
            failureMessage: "[Store] Failed to write usage stats"
        )
        let loaded = Self.loadFromDisk(fileURL: writer.fileURL)
        stats = loaded.stats
        dirty = loaded.needsRewrite
        writer.source = self
        writer.installTerminateHook()
        if dirty { scheduleFlush() }
    }

    public var storeFileURL: URL { writer.fileURL }

    // MARK: - Recording

    /// Records one expansion. Cheap: in-memory mutation plus a debounced write.
    public func recordUsage(
        for snippetID: UUID,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) {
        let bucketStart = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        lock.lock()
        var stat = stats[snippetID] ?? Stat()
        stat.usageCount = Saturating.adding(stat.usageCount, 1)
        if let previous = stat.lastUsedAt {
            stat.lastUsedAt = max(previous, date)
        } else {
            stat.lastUsedAt = date
        }

        if let index = stat.buckets.lastIndex(where: { $0.startedAt == bucketStart }) {
            stat.buckets[index].usageCount = Saturating.adding(
                stat.buckets[index].usageCount,
                1
            )
            if date > stat.buckets[index].lastUsedAt {
                stat.buckets[index].lastUsedAt = date
            }
        } else {
            stat.buckets.append(UsageBucket(
                startedAt: bucketStart,
                usageCount: 1,
                lastUsedAt: date
            ))
            stat.buckets.sort { $0.startedAt < $1.startedAt }
            if stat.buckets.count > Self.maximumBucketsPerSnippet {
                stat.buckets.removeFirst(stat.buckets.count - Self.maximumBucketsPerSnippet)
            }
        }
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

    /// Returns a period-correct snapshot from one locked copy of the sidecar.
    /// `snippetIDs` lets a UI constrain all metrics, including the timeline, to
    /// the exact library projection it is displaying.
    public func snapshot(
        period: Period,
        snippetIDs: Set<UUID>? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PeriodSnapshot {
        let stored = allStats()
        let selected = stored.filter { snippetIDs?.contains($0.key) ?? true }
        let start = Self.startDate(for: period, now: now, calendar: calendar)
        var entries: [UUID: PeriodStat] = [:]
        var selectedBuckets: [UsageBucket] = []
        var totalUsage = 0
        var unbucketedUsage = 0

        for (id, stat) in selected {
            let retainedCount = stat.buckets.reduce(0) {
                Saturating.adding($0, max(0, $1.usageCount))
            }

            if period == .all {
                let count = max(0, stat.usageCount)
                if count > 0 {
                    entries[id] = PeriodStat(usageCount: count, lastUsedAt: stat.lastUsedAt)
                    totalUsage = Saturating.adding(totalUsage, count)
                }
                unbucketedUsage = Saturating.adding(
                    unbucketedUsage,
                    max(0, count - retainedCount)
                )
                selectedBuckets.append(contentsOf: stat.buckets)
                continue
            }

            let buckets = stat.buckets.filter { bucket in
                guard let start else { return false }
                return bucket.lastUsedAt >= start && bucket.lastUsedAt <= now
            }
            let count = buckets.reduce(0) {
                Saturating.adding($0, max(0, $1.usageCount))
            }
            guard count > 0 else { continue }
            let lastUsedAt = buckets.map(\.lastUsedAt).max()
            entries[id] = PeriodStat(usageCount: count, lastUsedAt: lastUsedAt)
            totalUsage = Saturating.adding(totalUsage, count)
            selectedBuckets.append(contentsOf: buckets)
        }

        return PeriodSnapshot(
            period: period,
            generatedAt: now,
            entries: entries,
            timeline: Self.makeTimeline(
                period: period,
                buckets: selectedBuckets,
                now: now,
                calendar: calendar
            ),
            totalUsage: totalUsage,
            unbucketedUsageCount: unbucketedUsage
        )
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
    public func flush() { writer.flush() }

    private func scheduleFlush() { writer.schedule() }

    private static func loadFromDisk(fileURL: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return LoadResult(stats: [:], needsRewrite: false)
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            DevTypeLog.store.error(
                "[Store] Usage stats unreadable \(DevTypeLog.publicPathMetadata(fileURL.path), privacy: .public); starting empty"
            )
            return LoadResult(stats: [:], needsRewrite: false)
        }
        var out: [UUID: Stat] = [:]
        out.reserveCapacity(document.stats.count)
        var needsRewrite = document.schemaVersion < Document.currentSchemaVersion
        for (key, stat) in document.stats {
            guard let id = UUID(uuidString: key) else {
                needsRewrite = true
                continue
            }
            let normalized = normalize(stat)
            if normalized != stat { needsRewrite = true }
            out[id] = normalized
        }
        return LoadResult(stats: out, needsRewrite: needsRewrite)
    }

    private static func normalize(_ stat: Stat) -> Stat {
        var merged: [Date: UsageBucket] = [:]
        for bucket in stat.buckets where bucket.usageCount > 0 {
            let sanitized = UsageBucket(
                startedAt: bucket.startedAt,
                usageCount: bucket.usageCount,
                lastUsedAt: max(bucket.startedAt, bucket.lastUsedAt)
            )
            if var existing = merged[bucket.startedAt] {
                existing.usageCount = Saturating.adding(existing.usageCount, sanitized.usageCount)
                existing.lastUsedAt = max(existing.lastUsedAt, sanitized.lastUsedAt)
                merged[bucket.startedAt] = existing
            } else {
                merged[bucket.startedAt] = sanitized
            }
        }

        var buckets = merged.values.sorted { $0.startedAt < $1.startedAt }
        if buckets.count > maximumBucketsPerSnippet {
            buckets.removeFirst(buckets.count - maximumBucketsPerSnippet)
        }
        let retainedCount = buckets.reduce(0) {
            Saturating.adding($0, max(0, $1.usageCount))
        }
        let latestBucketDate = buckets.map(\.lastUsedAt).max()
        let lastUsedAt: Date?
        switch (stat.lastUsedAt, latestBucketDate) {
        case let (lhs?, rhs?): lastUsedAt = max(lhs, rhs)
        case let (lhs?, nil): lastUsedAt = lhs
        case let (nil, rhs?): lastUsedAt = rhs
        case (nil, nil): lastUsedAt = nil
        }
        return Stat(
            usageCount: max(max(0, stat.usageCount), retainedCount),
            lastUsedAt: lastUsedAt,
            buckets: buckets
        )
    }

    private static func startDate(
        for period: Period,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .all:
            return nil
        case .today:
            return today
        case .sevenDays:
            return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        }
    }

    private static func makeTimeline(
        period: Period,
        buckets: [UsageBucket],
        now: Date,
        calendar: Calendar
    ) -> [TimelinePoint] {
        let component: Calendar.Component = period == .today ? .hour : .day
        var counts: [Date: Int] = [:]
        for bucket in buckets where bucket.usageCount > 0 {
            let start: Date
            if component == .hour {
                start = calendar.dateInterval(of: .hour, for: bucket.lastUsedAt)?.start
                    ?? bucket.startedAt
            } else {
                start = calendar.startOfDay(for: bucket.lastUsedAt)
            }
            counts[start] = Saturating.adding(counts[start] ?? 0, bucket.usageCount)
        }

        if period == .all {
            return counts.keys.sorted().map {
                TimelinePoint(startedAt: $0, usageCount: counts[$0] ?? 0)
            }
        }

        guard let first = startDate(for: period, now: now, calendar: calendar) else {
            return []
        }
        let last: Date
        if component == .hour {
            last = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        } else {
            last = calendar.startOfDay(for: now)
        }

        var points: [TimelinePoint] = []
        var cursor = first
        while cursor <= last {
            points.append(TimelinePoint(startedAt: cursor, usageCount: counts[cursor] ?? 0))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor),
                  next > cursor else {
                break
            }
            cursor = next
        }
        return points
    }

}

extension UsageStatsStore: SidecarPayloadSource {
    func takePendingSidecarPayload() throws -> Data? {
        lock.lock()
        guard dirty else {
            lock.unlock()
            return nil
        }
        let snapshot = stats
        dirty = false
        lock.unlock()

        // JSON object keys must be strings; the in-memory map is keyed by UUID.
        var keyed: [String: Stat] = [:]
        keyed.reserveCapacity(snapshot.count)
        for (id, stat) in snapshot { keyed[id.uuidString] = stat }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(stats: keyed))
    }

    func reArmPendingSidecarPayload() {
        lock.lock()
        dirty = true
        lock.unlock()
    }
}
