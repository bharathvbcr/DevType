import Darwin
import Foundation

/// The result of one ask: what was read, and how long the exchange took.
public struct LappiExchange: Equatable, Sendable {
    public let reading: LappiReading
    /// Wall time of the exchange in milliseconds; nil when nothing was sent.
    public let latencyMs: Int?

    public init(reading: LappiReading, latencyMs: Int?) {
        self.reading = reading
        self.latencyMs = latencyMs
    }
}

/// A client for the Lappi agent's Unix socket (contract §1).
///
/// One request line out, one reply line back, and **one deadline for the whole exchange**:
/// connect, write and the complete reply share it. Each `poll` is given only what is left, so
/// a peer that drips one byte at a time cannot hold the caller past it — the property
/// `crates/qd-runtime/tests/client_deadline.rs` pins for the runtime's own client
/// (`oneshot.rs`, `DeadlineStream`). There is never an in-process fallback: no socket is
/// `unavailable`, and the app keeps its own path.
public struct LappiClient: Sendable {
    /// Interactive callers wait at most this long (contract §1: ≤ 300 ms).
    public static let interactiveTimeout: TimeInterval = 0.3

    /// The longest any exchange may take: the contract's batch bound (≤ 10 s).
    public static let maximumTimeout: TimeInterval = 10

    /// `$HOME/Library/Caches/qd/qd.sock`, where `qd serve` and `qd-metal-serve` listen.
    public static let defaultSocketRelativeToHome = "Library/Caches/qd/qd.sock"

    public let socketPath: String
    public let timeout: TimeInterval
    /// Reply cap; `LappiWire.maxPayloadBytes` outside tests.
    let replyCap: Int

    public init(socketPath: String, timeout: TimeInterval = LappiClient.interactiveTimeout) {
        self.init(socketPath: socketPath, timeout: timeout, replyCap: LappiWire.maxPayloadBytes)
    }

    init(socketPath: String, timeout: TimeInterval, replyCap: Int) {
        self.socketPath = socketPath
        self.timeout = timeout
        self.replyCap = replyCap
    }

    /// `LAPPI_SOCKET` when set and non-empty, else `$HOME/Library/Caches/qd/qd.sock`. Nil when
    /// neither can be named — never a relative path resolved against the working directory.
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = environment["LAPPI_SOCKET"], !override.isEmpty { return override }
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return (home as NSString).appendingPathComponent(defaultSocketRelativeToHome)
    }

    /// The client for the live socket, or nil when no path can be named.
    public static func live(timeout: TimeInterval = interactiveTimeout) -> LappiClient? {
        guard let path = defaultSocketPath() else {
            DevTypeLog.lappi.error("[Lappi] no socket path: LAPPI_SOCKET and HOME are both unset")
            return nil
        }
        return LappiClient(socketPath: path, timeout: timeout)
    }

    /// Asks off the calling thread. The POSIX exchange runs on a utility queue, so a caller on
    /// the main actor suspends here instead of blocking the run loop.
    public func ask(_ line: Data) async -> LappiExchange {
        await withCheckedContinuation { continuation in
            Self.exchangeQueue.async {
                continuation.resume(returning: askBlocking(line))
            }
        }
    }

    private static let exchangeQueue = DispatchQueue(
        label: "com.devtype.lappi.exchange",
        qos: .utility,
        attributes: .concurrent
    )

    /// The blocking exchange. Never call this on the main thread; `ask` is the entry point.
    public func askBlocking(_ line: Data) -> LappiExchange {
        // Bounds before sending (contract §1): over the cap, or not one line, is not sent.
        guard line.count <= LappiWire.maxPayloadBytes, !line.contains(0x0A) else {
            return LappiExchange(reading: .notAsked(.overBound), latencyMs: nil)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let result = Self.exchange(line: line, socketPath: socketPath, timeout: timeout, replyCap: replyCap)
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
        switch result {
        case .success(let reply):
            return LappiExchange(reading: LappiReply.read(reply), latencyMs: elapsed)
        case .failure(let failure):
            return LappiExchange(reading: .unavailable(failure.reason), latencyMs: elapsed)
        }
    }

    // MARK: - POSIX exchange

    struct ExchangeFailure: Error, Equatable {
        let reason: LappiUnavailableReason
    }

    /// Connect, write `line` plus a newline, and read one reply line — all inside one deadline.
    static func exchange(
        line: Data,
        socketPath: String,
        timeout: TimeInterval,
        replyCap: Int
    ) -> Result<Data, ExchangeFailure> {
        // A zero or negative timeout cannot bound anything; refuse before connecting, so the
        // agent never sees a connection that sends nothing (the same rule `ask_over_socket` has).
        guard timeout > 0, timeout.isFinite else { return .failure(ExchangeFailure(reason: .deadline)) }
        // Batch callers use ≤ 10 s (contract §1); anything longer is clamped, never unbounded.
        let bounded = min(timeout, maximumTimeout)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(bounded * 1_000_000_000)

        guard var address = unixAddress(path: socketPath) else {
            DevTypeLog.lappi.error("[Lappi] socket path is empty, holds a NUL, or exceeds sun_path")
            return .failure(ExchangeFailure(reason: .socketNotFound))
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logErrno("socket()", errno)
            return .failure(ExchangeFailure(reason: .connectRefused))
        }
        defer { close(fd) }

        // SIGPIPE must not kill DevType when the agent hangs up mid-write.
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            logErrno("setsockopt(SO_NOSIGPIPE)", errno)
            return .failure(ExchangeFailure(reason: .connectRefused))
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            logErrno("fcntl(O_NONBLOCK)", errno)
            return .failure(ExchangeFailure(reason: .connectRefused))
        }

        if let failure = connect(fd: fd, address: &address, deadline: deadline) {
            return .failure(failure)
        }
        // Mode and peer uid are checked on the connected socket, before any request byte.
        // A miss is a refusal, not a failed write: do not writeAll and do not readLine.
        if let failure = refusePeer(fd: fd, socketPath: socketPath) {
            return .failure(failure)
        }

        var framed = line
        framed.append(0x0A)
        // A failed write is not yet the outcome: an agent over its connection cap writes
        // `overloaded` the moment it accepts and closes, so the request can meet a closed socket
        // while that reply sits unread. Read it; only a socket with nothing to read reports the
        // write's failure (Lappi-decision `oneshot::ask_over_socket` does the same).
        let writeFailure = writeAll(fd: fd, bytes: framed, deadline: deadline)
        let read = readLine(fd: fd, cap: replyCap, deadline: deadline)
        if let writeFailure, case .failure = read {
            return .failure(writeFailure)
        }
        return read
    }

    /// A `sockaddr_un` for `path`, or nil when the path cannot be one.
    static func unixAddress(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity, !bytes.contains(0) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return address
    }

    /// Milliseconds left before `deadline`, rounded up, or nil when it has passed.
    private static func remainingMilliseconds(_ deadline: UInt64) -> Int32? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return nil }
        let left = (deadline - now + 999_999) / 1_000_000
        return Int32(clamping: max(1, left))
    }

    /// Waits for `events` within the deadline. Returns the revents, or a failure.
    private static func wait(fd: Int32, events: Int16, deadline: UInt64) -> Result<Int16, ExchangeFailure> {
        while true {
            guard let ms = remainingMilliseconds(deadline) else {
                return .failure(ExchangeFailure(reason: .deadline))
            }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&descriptor, 1, ms)
            if ready > 0 { return .success(descriptor.revents) }
            if ready == 0 { continue } // the loop re-checks the deadline
            let code = errno
            if code == EINTR || code == EAGAIN { continue }
            logErrno("poll()", code)
            return .failure(ExchangeFailure(reason: .closedWithoutReply))
        }
    }

    private static func connect(fd: Int32, address: inout sockaddr_un, deadline: UInt64) -> ExchangeFailure? {
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        if result == 0 { return nil }
        let code = errno
        guard code == EINPROGRESS || code == EINTR else { return connectFailure(code) }
        switch wait(fd: fd, events: Int16(POLLOUT), deadline: deadline) {
        case .failure(let failure):
            return failure
        case .success:
            var soError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &size) == 0 else {
                logErrno("getsockopt(SO_ERROR)", errno)
                return ExchangeFailure(reason: .connectRefused)
            }
            return soError == 0 ? nil : connectFailure(soError)
        }
    }

    /// Whether the connected peer may be sent a query.
    ///
    /// `stMode` is from `lstat` (a symlink is not followed). `peerUID` is nil when `getpeereid`
    /// failed. Either nil, a non-socket, a mode other than exactly 0600 (sticky, setgid, and
    /// setuid included), or a uid other than `ownUID` is a refusal.
    static func peerMayReceiveQuery(stMode: mode_t?, peerUID: uid_t?, ownUID: uid_t) -> Bool {
        guard let stMode, let peerUID else { return false }
        guard stMode & S_IFMT == S_IFSOCK else { return false }
        guard (stMode & 0o7777) == 0o600 else { return false }
        return peerUID == ownUID
    }

    /// `lstat`s `socketPath` and `getpeereid`s `fd`. Any miss refuses with `connectRefused`
    /// and does not touch the request bytes.
    private static func refusePeer(fd: Int32, socketPath: String) -> ExchangeFailure? {
        var info = stat()
        let listed = lstat(socketPath, &info)
        let listErrno = errno
        var uid: uid_t = 0
        var gid: gid_t = 0
        let peered = getpeereid(fd, &uid, &gid)
        let peerErrno = errno
        let stMode: mode_t? = listed == 0 ? info.st_mode : nil
        let peerUID: uid_t? = peered == 0 ? uid : nil
        guard peerMayReceiveQuery(stMode: stMode, peerUID: peerUID, ownUID: getuid()) else {
            if listed != 0 {
                logErrno("lstat(socket)", listErrno)
            }
            if peered != 0 {
                logErrno("getpeereid()", peerErrno)
            }
            DevTypeLog.lappi.error("[Lappi] peer refused before write")
            return ExchangeFailure(reason: .connectRefused)
        }
        return nil
    }

    private static func connectFailure(_ code: Int32) -> ExchangeFailure {
        switch code {
        case ENOENT, ENOTDIR:
            return ExchangeFailure(reason: .socketNotFound)
        case ECONNREFUSED, EACCES, EPERM, EPROTOTYPE, ENOTSOCK, EAGAIN:
            return ExchangeFailure(reason: .connectRefused)
        default:
            logErrno("connect()", code)
            return ExchangeFailure(reason: .connectRefused)
        }
    }

    private static func writeAll(fd: Int32, bytes: Data, deadline: UInt64) -> ExchangeFailure? {
        var offset = 0
        while offset < bytes.count {
            switch wait(fd: fd, events: Int16(POLLOUT), deadline: deadline) {
            case .failure(let failure):
                return failure
            case .success(let revents):
                if revents & Int16(POLLOUT) == 0, revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    return ExchangeFailure(reason: .closedWithoutReply)
                }
            }
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            let code = errno
            if written < 0, code == EINTR || code == EAGAIN { continue }
            // EPIPE / ECONNRESET: the agent hung up before taking the request.
            return ExchangeFailure(reason: .closedWithoutReply)
        }
        return nil
    }

    /// Reads up to the first newline, bounded by `cap`. EOF before a newline is
    /// `closed_without_reply`, never an empty answer.
    private static func readLine(fd: Int32, cap: Int, deadline: UInt64) -> Result<Data, ExchangeFailure> {
        var buffer = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            if case .failure(let failure) = wait(fd: fd, events: Int16(POLLIN), deadline: deadline) {
                return .failure(failure)
            }
            // One byte past the cap is enough to know the line is over it.
            let want = min(chunkSize, cap + 1 - buffer.count)
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(fd, base, want)
            }
            if count == 0 {
                return .failure(ExchangeFailure(reason: .closedWithoutReply))
            }
            if count < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN { continue }
                return .failure(ExchangeFailure(reason: .closedWithoutReply))
            }
            let fresh = chunk[0..<count]
            if let newline = fresh.firstIndex(of: 0x0A) {
                buffer.append(contentsOf: fresh[0..<newline])
                guard buffer.count <= cap else { return .failure(ExchangeFailure(reason: .replyOverCap)) }
                // An empty line is no reply, as `ask_over_socket` reads it.
                guard !buffer.isEmpty else { return .failure(ExchangeFailure(reason: .closedWithoutReply)) }
                return .success(buffer)
            }
            buffer.append(contentsOf: fresh)
            if buffer.count > cap {
                return .failure(ExchangeFailure(reason: .replyOverCap))
            }
        }
    }

    private static func logErrno(_ call: String, _ code: Int32) {
        DevTypeLog.lappi.error("[Lappi] \(call, privacy: .public) failed errno=\(code, privacy: .public)")
    }
}
