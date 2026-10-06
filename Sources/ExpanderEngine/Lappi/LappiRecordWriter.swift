import Darwin
import Foundation

/// Appends caller records to DevType's held-out store (contract §5, "Writing").
///
/// `O_APPEND | O_CREAT`, file `0600`, directories `0700`, one `write(2)` per complete line
/// including its newline, then `fsync`. Never read-modify-write. A line over 64 KiB is not
/// written; a day's file over 32 MiB or a store over 256 MiB stops recording until the user
/// clears it (re-measured on every write, so clearing it resumes recording). Every drop is
/// counted in `stats`, and each kind of failure is logged once. A failed write never changes
/// the app's decision: callers ignore the outcome except to count it.
public final class LappiRecordWriter: @unchecked Sendable {
    public static let maxLineBytes = 64 * 1024
    public static let maxDayFileBytes = 32 * 1024 * 1024
    public static let maxStoreBytes = 256 * 1024 * 1024
    /// `caller_record::STORE_RELATIVE_TO_HOME`.
    public static let storeRelativeToHome = "Library/Application Support/Lappi/heldout/caller-records"
    /// `caller_record::HELD_OUT_MARKERS`.
    public static let heldOutMarkers = ["heldout", "held_out", "held-out"]
    /// Most directory entries measured for the store cap; past it the store counts as full.
    static let maxStoreEntries = 4_096

    public enum WriteOutcome: Equatable, Sendable {
        case written
        case droppedLineOverCap
        case droppedDayFileCap
        case droppedStoreCap
        case refusedNotHeldOut
        case failed(String)
    }

    public struct Stats: Equatable, Sendable {
        public var written = 0
        public var droppedLineOverCap = 0
        public var droppedDayFileCap = 0
        public var droppedStoreCap = 0
        public var refusedNotHeldOut = 0
        public var failed = 0

        public var dropped: Int {
            droppedLineOverCap + droppedDayFileCap + droppedStoreCap + refusedNotHeldOut + failed
        }
    }

    /// The `caller-records` directory; this app writes under `<root>/devtype/`.
    public let root: URL
    let maxDayFileBytes: Int
    let maxStoreBytes: Int

    private let lock = NSLock()
    private var counters = Stats()
    private var loggedFailures = Set<String>()

    public convenience init(root: URL) {
        self.init(root: root, maxDayFileBytes: Self.maxDayFileBytes, maxStoreBytes: Self.maxStoreBytes)
    }

    init(root: URL, maxDayFileBytes: Int, maxStoreBytes: Int) {
        self.root = root
        self.maxDayFileBytes = maxDayFileBytes
        self.maxStoreBytes = maxStoreBytes
    }

    /// The process's one writer for the default store, so drop counts and "logged once" span
    /// every palette the app opens rather than resetting with each. Nil when `$HOME` is unset.
    public static let shared: LappiRecordWriter? = defaultRoot().map { LappiRecordWriter(root: $0) }

    public var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    /// `$HOME/` + `storeRelativeToHome`, or — inside a test bundle — the same relative path
    /// under the process's scratch root, so a test that forgets an override can never write
    /// into the real store. Nil when `$HOME` is unset: never a relative fallback.
    public static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let scratch = SupportDirectory.testDirectory {
            return scratch.deletingLastPathComponent()
                .appendingPathComponent("Lappi/heldout/caller-records", isDirectory: true)
        }
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(storeRelativeToHome, isDirectory: true)
    }

    /// Lexical, like `caller_record::check_store_path`: the store must sit under a held-out
    /// segment, because that segment is what makes `qd-train` refuse it.
    public static func isHeldOut(_ url: URL) -> Bool {
        url.pathComponents.contains { component in
            heldOutMarkers.contains { $0.caseInsensitiveCompare(component) == .orderedSame }
        }
    }

    /// The day file a record created at `date` belongs in: `<root>/devtype/<YYYY-MM-DD>.jsonl`, UTC.
    public func dayFile(for date: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(format: "%04ld-%02ld-%02ld.jsonl", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return appDirectory.appendingPathComponent(name)
    }

    var appDirectory: URL {
        root.appendingPathComponent(LappiCallerRecord.app, isDirectory: true)
    }

    /// Appends one line (given without its newline). Blocking; call off the main thread.
    @discardableResult
    public func append(_ line: Data, createdAt: Date) -> WriteOutcome {
        lock.lock()
        defer { lock.unlock() }
        let outcome = appendLocked(line, createdAt: createdAt)
        switch outcome {
        case .written: counters.written += 1
        case .droppedLineOverCap: counters.droppedLineOverCap += 1
        case .droppedDayFileCap: counters.droppedDayFileCap += 1
        case .droppedStoreCap: counters.droppedStoreCap += 1
        case .refusedNotHeldOut: counters.refusedNotHeldOut += 1
        case .failed: counters.failed += 1
        }
        logOnce(outcome)
        return outcome
    }

    private func appendLocked(_ line: Data, createdAt: Date) -> WriteOutcome {
        guard Self.isHeldOut(root) else { return .refusedNotHeldOut }
        guard line.count <= Self.maxLineBytes else { return .droppedLineOverCap }
        guard !line.isEmpty, !line.contains(0x0A) else { return .failed("line is empty or not one line") }
        if let failure = makeDirectories() { return .failed(failure) }

        let framedCount = line.count + 1
        switch storeBytes() {
        case .none:
            return .droppedStoreCap
        case .some(let used) where used + framedCount > maxStoreBytes:
            return .droppedStoreCap
        default:
            break
        }

        let path = dayFile(for: createdAt).path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .failed("open errno=\(errno)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failed("fstat errno=\(errno)") }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failed("day file is not a regular file") }
        guard Int(info.st_size) + framedCount <= maxDayFileBytes else { return .droppedDayFileCap }

        var framed = line
        framed.append(0x0A)
        // One write of the whole line: a record and its newline are one message, and O_APPEND
        // makes that one append. A short write would leave a torn line; it is reported, never
        // completed by a second write that could interleave with another writer.
        var written = -1
        repeat {
            written = framed.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base, framed.count)
            }
        } while written < 0 && errno == EINTR
        guard written >= 0 else { return .failed("write errno=\(errno)") }
        guard written == framed.count else { return .failed("short write \(written)/\(framed.count)") }
        guard fsync(fd) == 0 else { return .failed("fsync errno=\(errno)") }
        return .written
    }

    /// Creates `root/devtype` one component at a time with `0700`. Directories that already
    /// exist are kept as they are; the leaf must be a real directory, not a symlink.
    private func makeDirectories() -> String? {
        var current = "/"
        for component in appDirectory.standardizedFileURL.pathComponents where component != "/" {
            current = (current as NSString).appendingPathComponent(component)
            var existing = stat()
            if lstat(current, &existing) == 0 { continue }
            if mkdir(current, 0o700) != 0 {
                let code = errno
                guard code == EEXIST else { return "mkdir errno=\(code)" }
            }
        }
        var info = stat()
        guard lstat(current, &info) == 0 else { return "lstat errno=\(errno)" }
        guard info.st_mode & S_IFMT == S_IFDIR else { return "store directory is not a directory" }
        return nil
    }

    /// Bytes held by this app's store, or nil when it cannot be measured (fail closed: an
    /// unmeasurable store counts as full).
    private func storeBytes() -> Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: appDirectory.path),
              names.count <= Self.maxStoreEntries else { return nil }
        var total = 0
        for name in names {
            var info = stat()
            let path = appDirectory.appendingPathComponent(name).path
            guard lstat(path, &info) == 0 else { return nil }
            if info.st_mode & S_IFMT == S_IFREG { total += Int(info.st_size) }
        }
        return total
    }

    private func logOnce(_ outcome: WriteOutcome) {
        let key: String
        switch outcome {
        case .written: return
        case .droppedLineOverCap: key = "line_over_cap"
        case .droppedDayFileCap: key = "day_file_cap"
        case .droppedStoreCap: key = "store_cap"
        case .refusedNotHeldOut: key = "not_held_out"
        case .failed(let why): key = "failed: \(why)"
        }
        guard loggedFailures.insert(key).inserted, loggedFailures.count <= 64 else { return }
        DevTypeLog.lappi.error("[Lappi] caller record not written: \(key, privacy: .public)")
    }
}
