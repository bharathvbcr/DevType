import Darwin
import Foundation
@testable import ExpanderEngine

/// A fake Lappi agent: a plain AF_UNIX listener that never runs any model. What is under test
/// is DevType's client — its framing, its single deadline and its reading of replies.
final class LappiFakeAgent: @unchecked Sendable {
    let directory: String
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var request: Data?
    private var connections = 0
    private let finished = DispatchSemaphore(value: 0)

    /// Binds a short path (`sun_path` is 104 bytes on macOS, so not the temp dir), accepts one
    /// connection on a background thread and hands its descriptor to `handler`.
    ///
    /// `socketMode` is applied with `chmod` after bind. The default is `0600` because the client
    /// refuses any other mode; pass `0o666` to exercise that refusal.
    init(
        tag: String,
        socketMode: mode_t = 0o600,
        handler: @escaping @Sendable (Int32, LappiFakeAgent) -> Void
    ) throws {
        directory = "/private/tmp/qdl-\(getpid())-\(tag)"
        try? FileManager.default.removeItem(atPath: directory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        path = directory + "/s.sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0, var address = LappiClient.unixAddress(path: path) else {
            throw LappiTestError.setup("socket")
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw LappiTestError.setup("bind/listen errno=\(errno)") }
        guard chmod(path, socketMode) == 0 else { throw LappiTestError.setup("chmod errno=\(errno)") }
        // A reply written after the client has already closed raises SIGPIPE. Blocking that
        // signal on the writing thread still killed the process (signal 13), so ignore it
        // for the rest of this test process. The assertions still require zero request bytes.
        _ = signal(SIGPIPE, SIG_IGN)
        // Swift 6.3 treats a later `let listener` as the binding captured by the
        // bind closure above, and rejects that capture as use before declaration.
        // The hosted macOS 26 job is Swift 6.3.3. Keep the fd under another name.
        let boundListener = listener
        Thread.detachNewThread { [self] in
            defer { finished.signal() }
            var descriptor = pollfd(fd: boundListener, events: Int16(POLLIN), revents: 0)
            // Bounded: a test whose client never connects must not leave this thread behind.
            guard poll(&descriptor, 1, 5_000) > 0 else { return }
            let client = accept(boundListener, nil, nil)
            guard client >= 0 else { return }
            var one: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock(); connections += 1; lock.unlock()
            handler(client, self)
            close(client)
        }
    }

    deinit {
        close(listener)
        try? FileManager.default.removeItem(atPath: directory)
    }

    var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections
    }

    var receivedRequest: Data? {
        lock.lock(); defer { lock.unlock() }
        return request
    }

    /// Waits for the handler to return (bounded).
    @discardableResult
    func waitUntilDone(timeout: TimeInterval = 5) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }

    /// Reads the request line (with its newline) and remembers it.
    func readRequest(_ fd: Int32) {
        var line = Data()
        var byte: UInt8 = 0
        while line.count <= LappiWire.maxPayloadBytes + 1, read(fd, &byte, 1) == 1 {
            line.append(byte)
            if byte == 0x0A { break }
        }
        lock.lock(); request = line; lock.unlock()
    }

    static func write(_ fd: Int32, _ data: Data) {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if n <= 0 { return }
            offset += n
        }
    }

    /// An agent that reads the request and answers `reply` (a newline is appended).
    static func replying(_ tag: String, _ reply: String) throws -> LappiFakeAgent {
        try LappiFakeAgent(tag: tag) { fd, agent in
            agent.readRequest(fd)
            write(fd, Data((reply + "\n").utf8))
        }
    }
}

enum LappiTestError: Error {
    case setup(String)
}

enum LappiTestFixtures {
    static let recordID = "0123456789abcdef0123456789abcdef"

    static func scratchStore(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lappi-\(tag)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("heldout/caller-records", isDirectory: true)
        return url
    }

    static func lines(in file: URL) throws -> [Data] {
        let data = try Data(contentsOf: file)
        return data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast().map { Data($0) }
    }

    static func object(_ line: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw LappiTestError.setup("line is not an object")
        }
        return object
    }

    static func permissions(_ path: String) -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return info.st_mode & 0o777
    }
}
