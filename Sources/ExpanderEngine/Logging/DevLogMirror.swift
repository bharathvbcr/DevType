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
/// The result: a bounded ring (default 4 000 lines ≈ well under 1 MB) polled once a minute from a
/// utility queue. `DiagnosticReport` prints it as its own section, so a report generated hours
/// after an incident still carries the engine's own account of it, per app, at every level.
///
/// **Privacy:** lines are stored exactly as `OSLogStore` renders them — interpolations marked
/// `.private` come back as `<private>`, which is the redaction doing its job. This type adds no
/// new content and never writes to disk; it is a debugging aid, not telemetry, and dies with the
/// process.
public final class DevLogMirror {
    public static let shared = DevLogMirror()

    /// Most recent lines retained. 4 000 lines covers days of idle use and hours of heavy
    /// typing; memory cost stays under a megabyte.
    public static let defaultCapacity = 4000
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

        public var rendered: String {
            "\(Self.timestampFormatter.string(from: date)) [\(category)] \(level) \(message)"
        }

        static let timestampFormatter: ISO8601DateFormatter = {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso
        }()
    }

    private let lock = UnfairLock()
    private var lines: [Line] = []
    private var knownIdentities: Set<String> = []
    private var lastPollAt: Date?

    private var timer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.devtype.logmirror", qos: .utility)
    private let capacity: Int
    private let pollInterval: TimeInterval
    private var started = false

    /// Test seam: injects the fetcher so the poll loop is exercisable without OSLog.
    private let fetch: (_ since: Date) -> [Line]

    public init(
        capacity: Int = DevLogMirror.defaultCapacity,
        pollInterval: TimeInterval = DevLogMirror.defaultPollInterval,
        fetch: ((_ since: Date) -> [Line])? = nil
    ) {
        self.capacity = max(1, capacity)
        self.pollInterval = max(1, pollInterval)
        self.fetch = fetch ?? { since in Self.fetchLines(since: since) }
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
        lastPollAt = now.addingTimeInterval(-Self.firstPollLookback)
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
    /// dedupe makes the overlap harmless, so the position advances on every poll; a line logd
    /// flushes late is re-read by the next poll's overlap rather than lost.
    ///
    /// Fetch failures are indistinguishable from a quiet store by design (`fetch` returns `[]`
    /// for both) and are simply absorbed: the next poll re-covers the window via the overlap.
    @discardableResult
    public func poll(now: Date = Date()) -> Int {
        let since: Date
        lock.lock()
        if let last = lastPollAt {
            since = last.addingTimeInterval(-Self.pollOverlap)
        } else {
            since = now.addingTimeInterval(-Self.firstPollLookback)
        }
        lastPollAt = now
        lock.unlock()

        let batch = fetch(since)
        lock.lock()
        defer { lock.unlock() }
        return merge(batch)
    }

    // MARK: - Reading

    /// Newest-last snapshot, at most `limit` lines.
    public func recentLines(limit: Int? = nil) -> [String] {
        lock.lock()
        let snapshot = lines
        lock.unlock()
        let capped = limit.map { Array(snapshot.suffix($0)) } ?? snapshot
        return capped.map(\.rendered)
    }

    public var count: Int {
        lock.withLock { lines.count }
    }

    /// Test / reset hook.
    public func clear() {
        lock.lock()
        lines.removeAll()
        knownIdentities.removeAll()
        lastPollAt = nil
        lock.unlock()
    }

    // MARK: - Test seams

    /// Test seam: run one merge under the type's own lock.
    func mergeLocked(_ batch: [Line]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return merge(batch)
    }

    /// Test seam: snapshot of the stored lines, oldest-first.
    var storedLines: [Line] {
        lock.withLock { lines }
    }

    // MARK: - Merge (pure core)

    /// Appends a fetched batch, dropping identities already stored (the overlap guarantees some),
    /// oldest-first, trimming the head beyond `capacity`. The identity set is trimmed alongside
    /// the lines so long sessions cannot grow it without bound. Returns how many lines were
    /// genuinely new. Internal so tests can drive it; caller must hold `lock`.
    func merge(_ batch: [Line]) -> Int {
        var added = 0
        for line in batch {
            guard !knownIdentities.contains(line.identity) else { continue }
            knownIdentities.insert(line.identity)
            lines.append(line)
            added += 1
        }
        if lines.count > capacity {
            let excess = lines.count - capacity
            for evicted in lines.prefix(excess) {
                knownIdentities.remove(evicted.identity)
            }
            lines.removeFirst(excess)
        }
        return added
    }

    // MARK: - OSLog fetch

    /// Reads this process's entries for the DevType subsystem newer than `since`, oldest-first.
    static func fetchLines(since: Date) -> [Line] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            let predicate = NSPredicate(format: "subsystem == %@", DevTypeLog.subsystem)
            let entries = try store.getEntries(at: position, matching: predicate)
            var result: [Line] = []
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                result.append(
                    Line(
                        date: log.date,
                        category: log.category,
                        level: levelLabel(log.level),
                        message: log.composedMessage
                    )
                )
            }
            return result
        } catch {
            // The poll loop reports persistent failures; nothing useful to add here.
            return []
        }
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
