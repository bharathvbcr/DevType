import Foundation
import OSLog

/// §9.1: an in-process mirror of this process's unified-log lines, so diagnostics survive past
/// what OSLog itself retains.
///
/// The gap this closes: `DiagnosticReport.fetchRecentLogLines` can only read what logd still
/// holds, and that is less than it looks. Debug-level entries live in memory buffers and are gone
/// within minutes; info-level persistence is best-effort; and the persistent store rotates well
/// inside a support conversation ("it broke yesterday in Slack" is not answerable from a
/// 30-minute window). Every earlier attempt to widen retrieval hit the same wall — `os.Logger`
/// offers no interception point (`OSLogMessage` exposes no rendered text), so the only reliable
/// capture point left was reading the store back from inside the process, periodically, into
/// memory we own.
///
/// The result: a ring bounded by both entry count and rendered UTF-8 bytes, polled once a minute
/// from a utility queue. `DiagnosticReport` prints it as its own section, so a report generated
/// hours after an incident still carries the engine's own account of it, per app, at every level.
///
/// **Privacy:** lines are stored exactly as `OSLogStore` renders them — interpolations marked
/// `.private` come back as `<private>`, which is the redaction doing its job. This type adds no
/// new content and never writes to disk; it is a debugging aid, not telemetry, and dies with the
/// process.
public final class DevLogMirror {
    public static let shared = DevLogMirror()

    /// Most recent lines retained. The independent byte cap handles unexpectedly large entries.
    public static let defaultCapacity = 4000
    public static let defaultByteCapacity = 1 * 1_024 * 1_024
    /// How often the store is polled. One minute loses at most one minute of pre-crash history
    /// and costs one bounded query per interval.
    public static let defaultPollInterval: TimeInterval = 60
    /// Re-read this much before the last poll so entries landing between logd's flush and our
    /// position snapshot are seen by two polls instead of zero.
    public static let pollOverlap: TimeInterval = 5
    /// How far back the first poll reaches. Long enough to catch launch-time permission noise,
    /// short enough that a cold start does not scan the whole buffer.
    public static let firstPollLookback: TimeInterval = 10 * 60

    /// One mirrored line. `identity` dedupes across overlapping polls.
    public struct Line: Equatable {
        public let date: Date
        public let category: String
        public let level: String
        public let message: String

        public var identity: String {
            "\(date.timeIntervalSince1970)|\(category)|\(message)"
        }

        fileprivate struct DeduplicationIdentity: Hashable {
            let date: Date
            let category: String
            let message: String
        }

        fileprivate var deduplicationIdentity: DeduplicationIdentity {
            DeduplicationIdentity(date: date, category: category, message: message)
        }

        public var rendered: String {
            "\(Self.timestampFormatter.string(from: date)) [\(category)] \(level) \(message)"
        }

        /// Includes the newline separator used when diagnostic lines are joined into a report.
        fileprivate var retainedUTF8ByteCount: Int {
            rendered.utf8.count + 1
        }

        static let timestampFormatter: ISO8601DateFormatter = {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso
        }()
    }

    /// A poll that could not read OSLog must never be indistinguishable from a successful poll
    /// that happened to contain no entries.
    public enum PollOutcome: Equatable, Sendable {
        case success(added: Int)
        case failure
    }

    public struct Health: Equatable, Sendable {
        public let hasSuccessfulPoll: Bool
        public let consecutiveFailures: Int
        public let lastSuccessfulPollAt: Date?
        /// Error type only. Free-form error descriptions can contain paths or log content and do
        /// not belong in a support report.
        public let lastFailureKind: String?
        /// All log entries offered by successful fetches/merges, including overlap duplicates
        /// and entries later rejected or evicted by a retention cap.
        public let observedEntryCount: Int
        public let retainedEntryCount: Int
        public let retainedUTF8Bytes: Int
        public let entryCapacity: Int
        public let byteCapacity: Int
        public let oversizedEntryCount: Int
        public let evictedEntryCount: Int
    }

    /// Atomic report snapshot: lines and counters describe the same instant.
    public struct Snapshot: Equatable, Sendable {
        public let lines: [String]
        public let health: Health
    }

    private let lock = UnfairLock()
    /// `poll()` includes an external OSLog read. Serialize whole cycles so an older, slower fetch
    /// cannot move the cursor backwards after a newer one has completed.
    private let pollCycleLock = NSLock()
    private var retainedLines: BoundedUTF8Tail<Line>
    private var knownIdentities: Set<Line.DeduplicationIdentity> = []
    private var observedEntryCount = 0
    /// Entries discarded while bounding the temporary OSLog enumeration before it reached the
    /// persistent tail. `retainedLines` separately accounts for persistent-tail drops.
    private var fetchOversizedEntryCount = 0
    private var fetchEvictedEntryCount = 0
    private var pollCursor: Date?
    private var hasSuccessfulPoll = false
    private var consecutiveFailures = 0
    private var lastSuccessfulPollAt: Date?
    private var lastFailureKind: String?

    private var timer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.devtype.logmirror", qos: .utility)
    private let capacity: Int
    private let byteCapacity: Int
    private let pollInterval: TimeInterval
    private var started = false

    /// Test seam: injects the fetcher so the poll loop is exercisable without OSLog.
    private let fetch: (_ since: Date) throws -> FetchedBatch

    private struct FetchedBatch {
        let lines: [Line]
        let observedEntryCount: Int
        let oversizedEntryCount: Int
        let evictedEntryCount: Int
    }

    public init(
        capacity: Int = DevLogMirror.defaultCapacity,
        byteCapacity: Int = DevLogMirror.defaultByteCapacity,
        pollInterval: TimeInterval = DevLogMirror.defaultPollInterval,
        fetch: ((_ since: Date) throws -> [Line])? = nil
    ) {
        let resolvedCapacity = max(1, capacity)
        let resolvedByteCapacity = max(1, byteCapacity)
        self.capacity = resolvedCapacity
        self.byteCapacity = resolvedByteCapacity
        self.retainedLines = BoundedUTF8Tail(
            countLimit: resolvedCapacity,
            byteLimit: resolvedByteCapacity
        )
        self.pollInterval = max(1, pollInterval)
        if let fetch {
            self.fetch = { since in
                let lines = try fetch(since)
                return FetchedBatch(
                    lines: lines,
                    observedEntryCount: lines.count,
                    oversizedEntryCount: 0,
                    evictedEntryCount: 0
                )
            }
        } else {
            self.fetch = { since in
                try Self.fetchLines(
                    since: since,
                    countLimit: resolvedCapacity,
                    byteLimit: resolvedByteCapacity
                )
            }
        }
    }

    // MARK: - Lifecycle

    /// Starts the poll loop. Idempotent; safe to call from app startup.
    public func start(now: Date = Date()) {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        if pollCursor == nil {
            pollCursor = now.addingTimeInterval(-Self.firstPollLookback)
        }
        let interval = pollInterval
        lock.unlock()

        let source = DispatchSource.makeTimerSource(queue: pollQueue)
        // First capture one interval after launch, not immediately: an immediate fire
        // races whatever constructed us and buys nothing — `firstPollLookback` already
        // reaches back over launch-time noise on that first tick.
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        source.setEventHandler { [weak self] in
            self?.poll(now: Date())
        }
        lock.lock()
        timer = source
        lock.unlock()
        source.resume()
    }

    /// Test / shutdown hook.
    public func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        started = false
        lock.unlock()
    }

    /// One poll cycle: fetch everything newer than the previous poll (minus overlap), merge into
    /// the ring. Returns the number of genuinely new lines stored (overlap duplicates excluded).
    ///
    /// Works standalone: a manual `poll()` before — or instead of — `start()` lazily seeds the
    /// read position from `firstPollLookback`, which also makes the cycle directly testable and
    /// lets a report pull one catch-up window even if startup never began the timer. Identity
    /// dedupe makes the overlap harmless. The cursor advances only after a successful fetch; a
    /// failed read is reported and the full missing window is retried next time.
    @discardableResult
    public func poll(now: Date = Date()) -> PollOutcome {
        pollCycleLock.lock()
        defer { pollCycleLock.unlock() }

        let since: Date
        lock.lock()
        if let cursor = pollCursor {
            since = hasSuccessfulPoll
                ? cursor.addingTimeInterval(-Self.pollOverlap)
                : cursor
        } else {
            since = now.addingTimeInterval(-Self.firstPollLookback)
            // Retain the initial lower bound across failures. Recomputing it from a later `now`
            // would silently discard the oldest part of the failed interval.
            pollCursor = since
        }
        lock.unlock()

        do {
            let batch = try fetch(since)
            lock.lock()
            let added = merge(
                batch.lines,
                observedCount: batch.observedEntryCount,
                prefetchedOversizedCount: batch.oversizedEntryCount,
                prefetchedEvictedCount: batch.evictedEntryCount
            )
            pollCursor = now
            hasSuccessfulPoll = true
            consecutiveFailures = 0
            lastSuccessfulPollAt = now
            lastFailureKind = nil
            lock.unlock()
            return .success(added: added)
        } catch {
            lock.lock()
            consecutiveFailures += 1
            lastFailureKind = String(reflecting: type(of: error))
            lock.unlock()
            return .failure
        }
    }

    // MARK: - Reading

    /// Newest-last snapshot, at most `limit` lines.
    public func recentLines(limit: Int? = nil) -> [String] {
        snapshot(limit: limit).lines
    }

    public var count: Int {
        lock.withLock { retainedLines.statistics.retainedCount }
    }

    public var health: Health {
        lock.withLock { healthLocked() }
    }

    public func snapshot(limit: Int? = nil) -> Snapshot {
        lock.withLock {
            let all = retainedLines.values
            let resolvedLimit = limit.map { max(0, $0) }
            let selected = resolvedLimit.map { Array(all.suffix($0)) } ?? all
            return Snapshot(lines: selected.map(\.rendered), health: healthLocked())
        }
    }

    private func healthLocked() -> Health {
        let retention = retainedLines.statistics
        return Health(
            hasSuccessfulPoll: hasSuccessfulPoll,
            consecutiveFailures: consecutiveFailures,
            lastSuccessfulPollAt: lastSuccessfulPollAt,
            lastFailureKind: lastFailureKind,
            observedEntryCount: observedEntryCount,
            retainedEntryCount: retention.retainedCount,
            retainedUTF8Bytes: retention.retainedUTF8Bytes,
            entryCapacity: capacity,
            byteCapacity: byteCapacity,
            oversizedEntryCount: saturatingAdd(
                fetchOversizedEntryCount,
                retention.oversizedCount
            ),
            evictedEntryCount: saturatingAdd(fetchEvictedEntryCount, retention.evictedCount)
        )
    }

    /// Test / reset hook.
    public func clear() {
        lock.lock()
        retainedLines = BoundedUTF8Tail(countLimit: capacity, byteLimit: byteCapacity)
        knownIdentities.removeAll()
        observedEntryCount = 0
        fetchOversizedEntryCount = 0
        fetchEvictedEntryCount = 0
        pollCursor = nil
        hasSuccessfulPoll = false
        consecutiveFailures = 0
        lastSuccessfulPollAt = nil
        lastFailureKind = nil
        lock.unlock()
    }

    // MARK: - Test seams

    /// Test seam: run one merge under the type's own lock.
    @discardableResult
    func mergeLocked(_ batch: [Line]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return merge(batch)
    }

    /// Test seam: snapshot of the stored lines, oldest-first.
    var storedLines: [Line] {
        lock.withLock { retainedLines.values }
    }

    // MARK: - Merge (pure core)

    /// Appends a fetched batch, dropping identities already stored (the overlap guarantees some),
    /// oldest-first. The bounded tail evicts before a projected count/byte overflow, and the
    /// identity set is trimmed alongside it. Returns how many lines were genuinely new. Internal
    /// so tests can drive it; caller must hold `lock`.
    func merge(
        _ batch: [Line],
        observedCount: Int? = nil,
        prefetchedOversizedCount: Int = 0,
        prefetchedEvictedCount: Int = 0
    ) -> Int {
        observedEntryCount = saturatingAdd(observedEntryCount, observedCount ?? batch.count)
        fetchOversizedEntryCount = saturatingAdd(
            fetchOversizedEntryCount,
            prefetchedOversizedCount
        )
        fetchEvictedEntryCount = saturatingAdd(fetchEvictedEntryCount, prefetchedEvictedCount)
        var added = 0
        for line in batch {
            let identity = line.deduplicationIdentity
            guard !knownIdentities.contains(identity) else { continue }
            let result = retainedLines.append(
                line,
                utf8ByteCount: line.retainedUTF8ByteCount
            )
            guard result.accepted else { continue }
            for evicted in result.evicted {
                knownIdentities.remove(evicted.deduplicationIdentity)
            }
            knownIdentities.insert(identity)
            added += 1
        }
        return added
    }

    // MARK: - OSLog fetch

    /// Reads this process's entries for the DevType subsystem newer than `since`, oldest-first.
    private static func fetchLines(
        since: Date,
        countLimit: Int,
        byteLimit: Int
    ) throws -> FetchedBatch {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)
        let predicate = NSPredicate(format: "subsystem == %@", DevTypeLog.subsystem)
        let entries = try store.getEntries(at: position, matching: predicate)
        var result = BoundedUTF8Tail<Line>(countLimit: countLimit, byteLimit: byteLimit)
        for entry in entries {
            guard let log = entry as? OSLogEntryLog else { continue }
            let line = Line(
                date: log.date,
                category: log.category,
                level: levelLabel(log.level),
                message: log.composedMessage
            )
            _ = result.append(line, utf8ByteCount: line.retainedUTF8ByteCount)
        }
        let statistics = result.statistics
        return FetchedBatch(
            lines: result.values,
            observedEntryCount: statistics.observedCount,
            oversizedEntryCount: statistics.oversizedCount,
            evictedEntryCount: statistics.evictedCount
        )
    }

    private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    static func levelLabel(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "undef"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        @unknown default: return "level"
        }
    }
}
