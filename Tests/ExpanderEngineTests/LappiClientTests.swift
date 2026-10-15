import Darwin
import XCTest
@testable import ExpanderEngine

/// DevType's Lappi client against a fake AF_UNIX agent: the six outcomes of contract §2, the
/// single whole-exchange deadline of §1, and the bounds on what goes out and comes back.
final class LappiClientTests: XCTestCase {

    private let request = Data(#"{"op":"ping"}"#.utf8)

    private func ask(_ agent: LappiFakeAgent, timeout: TimeInterval = 2) -> LappiExchange {
        LappiClient(socketPath: agent.path, timeout: timeout).askBlocking(request)
    }

    // MARK: - The six outcomes

    func testAnAnsweredRouteSlotIsModelAnswered() throws {
        let agent = try LappiFakeAgent.replying("ans", #"""
        {"status":"ok","schema_version":1,"backend":"qd-metal/qwen3.5-2b-base/tessl","degraded":false,"slots":{"route":{"value":"findSnippet","conformal_set":["findSnippet"],"score":0.91,"noul":false,"degraded":false}}}
        """#)
        let exchange = ask(agent)
        XCTAssertEqual(LappiTestFixtures.permissions(agent.path), 0o600)
        let slot = LappiSlotAnswer(value: .label("findSnippet"), conformalSet: ["findSnippet"], score: 0.91, noul: false, degraded: false)
        XCTAssertEqual(exchange.reading, .modelAnswered(backend: "qd-metal/qwen3.5-2b-base/tessl", slots: ["route": slot]))
        XCTAssertNotNil(exchange.latencyMs)
        agent.waitUntilDone()
        XCTAssertEqual(agent.receivedRequest, request + Data([0x0A]), "one request line, framed by one newline")
    }

    func testAReplyWrittenAtAcceptIsReadEvenWhenTheRequestWriteFails() throws {
        // `qd serve` over its connection cap writes `overloaded` at accept and closes without
        // reading. A request larger than the socket buffer then fails mid-write, but the reply is
        // already in the receive buffer and must be the outcome. Repeated so the race lands both ways.
        let big = Data(repeating: 0x20, count: 512 * 1024)
        for round in 0..<20 {
            let agent = try LappiFakeAgent(tag: "early\(round)") { fd, _ in
                LappiFakeAgent.write(fd, Data(#"{"status":"error","schema_version":1,"error":{"kind":"overloaded","limit":8},"message":"busy"}"#.utf8 + [0x0A]))
                shutdown(fd, SHUT_RDWR)
            }
            let exchange = LappiClient(socketPath: agent.path, timeout: 2).askBlocking(big)
            agent.waitUntilDone()
            XCTAssertEqual(exchange.reading, .backendFailed(kind: "overloaded"), "round \(round)")
        }
    }

    func testEverySlotNoulIsModelAbstained() throws {
        let agent = try LappiFakeAgent.replying("abs", #"""
        {"status":"ok","schema_version":1,"backend":"qd-metal","degraded":false,"slots":{"route":{"value":null,"conformal_set":null,"score":0.02,"noul":true,"degraded":false}}}
        """#)
        guard case .modelAbstained(let backend, let slots) = ask(agent).reading else {
            return XCTFail("all-noul must read as an abstention")
        }
        XCTAssertEqual(backend, "qd-metal")
        XCTAssertEqual(slots["route"]?.noul, true)
    }

    func testADegradedAnswerIsAnAbstentionNotAModelAnswer() throws {
        // The reference backend answers with values, but its answer is not a model's (§2).
        let agent = try LappiFakeAgent.replying("deg", #"""
        {"status":"ok","schema_version":1,"backend":"reference-deterministic-v1","degraded":true,"slots":{"route":{"value":"runMacro","conformal_set":["runMacro"],"score":0.7,"noul":false,"degraded":true}}}
        """#)
        guard case .modelAbstained(let backend, _) = ask(agent).reading else {
            return XCTFail("degraded:true must be model_abstained")
        }
        XCTAssertEqual(backend, "reference-deterministic-v1")
    }

    func testARefusalIsRequestRefusedWithItsKind() throws {
        let agent = try LappiFakeAgent.replying("ref", #"""
        {"status":"refused","schema_version":1,"refusal":{"kind":"task_not_trained","task":"devtype.route","available":["code.defect_class"]},"message":"task `devtype.route` is not one this release was trained on"}
        """#)
        XCTAssertEqual(ask(agent).reading, .requestRefused(kind: "task_not_trained"))
    }

    func testABackendErrorIsBackendFailedWithItsKind() throws {
        let agent = try LappiFakeAgent.replying("err", #"""
        {"status":"error","schema_version":1,"error":{"kind":"overloaded","limit":8},"message":"the runtime is at its concurrency limit of 8 in-flight requests"}
        """#)
        XCTAssertEqual(ask(agent).reading, .backendFailed(kind: "overloaded"))
    }

    func testAnUnknownStatusIsUnavailableNotAGuess() throws {
        let agent = try LappiFakeAgent.replying("unk", #"{"status":"maybe","schema_version":1,"slots":{}}"#)
        XCTAssertEqual(ask(agent).reading, .unavailable(.replyUnparseable))
    }

    func testGarbageIsUnparseable() throws {
        let agent = try LappiFakeAgent.replying("gar", "not json at all {")
        XCTAssertEqual(ask(agent).reading, .unavailable(.replyUnparseable))
    }

    func testRequestOverThePayloadCapIsNotSent() throws {
        let agent = try LappiFakeAgent.replying("cap", #"{"status":"error","schema_version":1}"#)
        let line = Data(repeating: 0x61, count: LappiWire.maxPayloadBytes + 1)
        let exchange = LappiClient(socketPath: agent.path).askBlocking(line)
        XCTAssertEqual(exchange.reading, .notAsked(.overBound))
        XCTAssertNil(exchange.latencyMs)
        XCTAssertFalse(agent.waitUntilDone(timeout: 0.3), "nothing may connect for an over-cap request")
        XCTAssertEqual(agent.connectionCount, 0)
    }

    func testTheCapMirrorsTheRuntime() {
        // crates/qd-runtime/src/wire.rs:64 — `pub const MAX_PAYLOAD_BYTES: usize = 1_572_864;`
        XCTAssertEqual(LappiWire.maxPayloadBytes, 1_572_864)
    }

    // MARK: - Unavailable, each reason

    func testNoSocketIsSocketNotFound() {
        let client = LappiClient(socketPath: "/private/tmp/qdl-\(getpid())-none/missing.sock")
        XCTAssertEqual(client.askBlocking(request).reading, .unavailable(.socketNotFound))
    }

    func testAnOverlongSocketPathIsSocketNotFoundNotACrash() {
        let client = LappiClient(socketPath: "/" + String(repeating: "a", count: 200))
        XCTAssertEqual(client.askBlocking(request).reading, .unavailable(.socketNotFound))
    }

    func testABoundSocketNobodyListensOnIsConnectRefused() throws {
        let directory = "/private/tmp/qdl-\(getpid())-refused"
        try? FileManager.default.removeItem(atPath: directory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/s.sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try XCTUnwrap(LappiClient.unixAddress(path: path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(fd) // the socket file stays; nobody accepts on it
        XCTAssertEqual(LappiClient(socketPath: path).askBlocking(request).reading, .unavailable(.connectRefused))
    }

    func testAMode0666SocketIsRefusedWithNoRequestBytes() throws {
        let agent = try LappiFakeAgent(tag: "mode666", socketMode: 0o666) { fd, agent in
            // A reply already queued at accept must not become the outcome: a mode refusal
            // is not a failed write, so the client must not read it.
            LappiFakeAgent.write(fd, Data(#"{"status":"error","schema_version":1,"error":{"kind":"overloaded"},"message":"x"}"#.utf8 + [0x0A]))
            agent.readRequest(fd)
        }
        XCTAssertEqual(LappiTestFixtures.permissions(agent.path), 0o666)
        let exchange = ask(agent)
        XCTAssertEqual(exchange.reading, .unavailable(.connectRefused))
        XCTAssertTrue(agent.waitUntilDone())
        XCTAssertEqual(agent.receivedRequest, Data(), "a refused peer must observe zero request bytes")
    }

    func testASymlinkToAPrivateSocketIsRefusedWithNoRequestBytes() throws {
        let agent = try LappiFakeAgent(tag: "symlink") { fd, agent in
            agent.readRequest(fd)
        }
        let link = agent.directory + "/link.sock"
        XCTAssertEqual(symlink(agent.path, link), 0)
        let exchange = LappiClient(socketPath: link, timeout: 2).askBlocking(request)
        XCTAssertEqual(exchange.reading, .unavailable(.connectRefused))
        XCTAssertTrue(agent.waitUntilDone())
        XCTAssertEqual(agent.receivedRequest, Data(), "lstat must not follow the symlink into a write")
    }

    /// Not a second OS user. Feeds the mode/uid decision the observed values only.
    func testPeerMayReceiveQueryRequiresSocketMode0600AndSameUid() {
        let own = getuid()
        let other = own &+ 1
        let socket0600 = S_IFSOCK | mode_t(0o600)
        XCTAssertTrue(LappiClient.peerMayReceiveQuery(stMode: socket0600, peerUID: own, ownUID: own))
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: S_IFSOCK | mode_t(0o666), peerUID: own, ownUID: own))
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: S_IFSOCK | mode_t(0o700), peerUID: own, ownUID: own))
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: S_IFSOCK | mode_t(0o640), peerUID: own, ownUID: own))
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: S_IFREG | mode_t(0o600), peerUID: own, ownUID: own))
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: S_IFLNK | mode_t(0o777), peerUID: own, ownUID: own))
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: socket0600, peerUID: other, ownUID: own))
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: nil, peerUID: own, ownUID: own))
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: socket0600, peerUID: nil, ownUID: own))
        // Sticky, setgid, and setuid are not exactly 0600.
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: S_ISUID | socket0600, peerUID: own, ownUID: own))
    }

    func testAPeerThatDripsBytesCannotHoldTheCallerPastItsDeadline() throws {
        // 40 bytes at 150 ms each is 6 s of reply, every gap well inside a 500 ms per-read
        // timeout — the case a per-read timeout cannot bound (client_deadline.rs).
        let reply = Data(#"{"status":"error","schema_version":1}"#.utf8) + Data([0x0A])
        let agent = try LappiFakeAgent(tag: "drip") { fd, agent in
            agent.readRequest(fd)
            for byte in reply {
                usleep(150_000)
                if Darwin.write(fd, [byte], 1) != 1 { return }
            }
        }
        let started = Date()
        let exchange = ask(agent, timeout: 0.5)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(exchange.reading, .unavailable(.deadline))
        XCTAssertLessThan(elapsed, 1.5, "the whole exchange is bounded by one deadline, not each read")
    }

    func testAnAgentThatAcceptsAndNeverWritesIsADeadline() throws {
        let agent = try LappiFakeAgent(tag: "mute") { fd, agent in
            agent.readRequest(fd)
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 3_000) // hold until the client gives up
        }
        let started = Date()
        XCTAssertEqual(ask(agent, timeout: 0.3).reading, .unavailable(.deadline))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testAnAgentThatNeverReadsCannotHoldTheWrite() throws {
        // A request bigger than the socket buffers, to a peer that never reads: the write
        // itself must be bounded by the same deadline.
        let agent = try LappiFakeAgent(tag: "deaf") { fd, _ in
            var descriptor = pollfd(fd: fd, events: 0, revents: 0)
            _ = poll(&descriptor, 1, 3_000)
        }
        let big = Data(repeating: 0x61, count: 1_000_000)
        let started = Date()
        let exchange = LappiClient(socketPath: agent.path, timeout: 0.3).askBlocking(big)
        XCTAssertEqual(exchange.reading, .unavailable(.deadline))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testClosingWithoutANewlineIsClosedWithoutReply() throws {
        let agent = try LappiFakeAgent(tag: "eof") { fd, agent in
            agent.readRequest(fd)
            LappiFakeAgent.write(fd, Data(#"{"status":"refused","schema_version":1"#.utf8))
        }
        XCTAssertEqual(ask(agent).reading, .unavailable(.closedWithoutReply))
    }

    func testClosingWithNothingIsClosedWithoutReplyNotAnEmptyAnswer() throws {
        let agent = try LappiFakeAgent(tag: "nil") { fd, agent in agent.readRequest(fd) }
        XCTAssertEqual(ask(agent).reading, .unavailable(.closedWithoutReply))
    }

    func testAReplyOverTheCapIsReplyOverCap() throws {
        let agent = try LappiFakeAgent(tag: "big") { fd, agent in
            agent.readRequest(fd)
            LappiFakeAgent.write(fd, Data(repeating: 0x61, count: LappiWire.maxPayloadBytes + 64))
        }
        XCTAssertEqual(ask(agent, timeout: 5).reading, .unavailable(.replyOverCap))
    }

    func testAZeroTimeoutIsRefusedBeforeConnecting() throws {
        let agent = try LappiFakeAgent.replying("zero", #"{"status":"error","schema_version":1}"#)
        XCTAssertEqual(ask(agent, timeout: 0).reading, .unavailable(.deadline))
        XCTAssertFalse(agent.waitUntilDone(timeout: 0.3))
        XCTAssertEqual(agent.connectionCount, 0)
    }

    // MARK: - Strict reading

    func testIllegalAnswerShapesAreUnparseable() {
        let illegal = [
            // value present but noul:true — one fact spelled two ways
            #"{"status":"ok","schema_version":1,"backend":"b","degraded":false,"slots":{"route":{"value":"none","conformal_set":null,"score":0.5,"noul":true,"degraded":false}}}"#,
            // value null but noul:false
            #"{"status":"ok","schema_version":1,"backend":"b","degraded":false,"slots":{"route":{"value":null,"conformal_set":null,"score":0.5,"noul":false,"degraded":false}}}"#,
            // unknown envelope key
            #"{"status":"ok","schema_version":1,"backend":"b","degraded":false,"slots":{},"extra":1}"#,
            // missing backend: the record checker requires one for an answer
            #"{"status":"ok","schema_version":1,"degraded":false,"slots":{"route":{"value":"none","conformal_set":null,"score":0.5,"noul":false,"degraded":false}}}"#,
            // degraded as a number, not a boolean
            #"{"status":"ok","schema_version":1,"backend":"b","degraded":0,"slots":{"route":{"value":"none","conformal_set":null,"score":0.5,"noul":false,"degraded":false}}}"#,
            // unknown schema version
            #"{"status":"refused","schema_version":2,"refusal":{"kind":"x"},"message":"m"}"#,
            // refusal without a kind
            #"{"status":"refused","schema_version":1,"refusal":{},"message":"m"}"#,
            // score outside [0, 1]
            #"{"status":"ok","schema_version":1,"backend":"b","degraded":false,"slots":{"route":{"value":"none","conformal_set":null,"score":1.5,"noul":false,"degraded":false}}}"#,
            "[]",
            "",
        ]
        for line in illegal {
            XCTAssertEqual(LappiReply.read(Data(line.utf8)), .unavailable(.replyUnparseable), line)
        }
    }

    // MARK: - Never on the main thread

    @MainActor
    func testAskSuspendsInsteadOfBlockingTheMainThread() async throws {
        let agent = try LappiFakeAgent(tag: "main") { fd, agent in
            agent.readRequest(fd)
            usleep(250_000)
            LappiFakeAgent.write(fd, Data((#"{"status":"error","schema_version":1,"error":{"kind":"overloaded"},"message":"m"}"# + "\n").utf8))
        }
        var mainRanDuringAsk = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { mainRanDuringAsk = true }
        let exchange = await LappiClient(socketPath: agent.path, timeout: 2).ask(request)
        XCTAssertEqual(exchange.reading, .backendFailed(kind: "overloaded"))
        XCTAssertTrue(mainRanDuringAsk, "the main queue must keep running while the exchange waits")
    }

    // MARK: - Socket path

    func testSocketPathPrefersTheEnvironmentOverride() {
        XCTAssertEqual(
            LappiClient.defaultSocketPath(environment: ["LAPPI_SOCKET": "/x/y.sock", "HOME": "/Users/u"]),
            "/x/y.sock"
        )
        XCTAssertEqual(
            LappiClient.defaultSocketPath(environment: ["HOME": "/Users/u"]),
            "/Users/u/Library/Caches/qd/qd.sock"
        )
        XCTAssertEqual(LappiClient.defaultSocketPath(environment: ["LAPPI_SOCKET": "", "HOME": "/h"]), "/h/Library/Caches/qd/qd.sock")
        XCTAssertNil(LappiClient.defaultSocketPath(environment: [:]), "never a relative fallback")
    }

    // MARK: - Hostile peer checks

    func testUnavailableReasonsStayTheClosedSet() {
        XCTAssertEqual(
            Set(LappiUnavailableReason.allCases.map(\.rawValue)),
            ["socket_not_found", "connect_refused", "deadline", "closed_without_reply", "reply_over_cap", "reply_unparseable"]
        )
    }

    func testMode0600StillExchanges() throws {
        let agent = try LappiFakeAgent(tag: "still600", socketMode: 0o600) { fd, agent in
            agent.readRequest(fd)
            LappiFakeAgent.write(fd, Self.overloadedReply)
        }
        XCTAssertEqual(LappiTestFixtures.permissions(agent.path), 0o600)
        let exchange = ask(agent)
        XCTAssertEqual(exchange.reading, .backendFailed(kind: "overloaded"))
        XCTAssertTrue(agent.waitUntilDone())
        XCTAssertEqual(agent.receivedRequest, request + Data([0x0A]))
    }

    /// Modes that are not the permission bits 0600. 0400 and 0000 fail inside connect (EACCES);
    /// the others connect and must still be refused before any request byte.
    func testModesNear0600AreRefusedWithNoRequestBytes() throws {
        let modes: [mode_t] = [0o601, 0o604, 0o620, 0o640, 0o700, 0o400, 0o000, 0o660, 0o670, 0o1600]
        for mode in modes {
            try assertRefused(mode)
        }
    }

    /// Not a live second user, and not a chmod this kernel keeps: macOS drops setgid on a socket
    /// inode, so 02600 is stored as 0600. The decision must still refuse a mode word that has the bit.
    func testMode02600IsRefusedWhenTheSetgidBitIsPresent() throws {
        let agent = try LappiFakeAgent(tag: "m2600", socketMode: 0o2600) { fd, agent in
            agent.readRequest(fd)
            LappiFakeAgent.write(fd, Self.overloadedReply)
        }
        var info = stat()
        XCTAssertEqual(lstat(agent.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        if info.st_mode & S_ISGID != 0 {
            let exchange = LappiClient(socketPath: agent.path, timeout: 2).askBlocking(request)
            XCTAssertEqual(exchange.reading, .unavailable(.connectRefused))
            XCTAssertTrue(agent.waitUntilDone())
            XCTAssertEqual(agent.receivedRequest, Data(), "a stored 02600 socket must see zero request bytes")
        } else {
            XCTAssertEqual(info.st_mode & 0o777, mode_t(0o600), "the kernel dropped setgid and left 0600")
            let exchange = ask(agent)
            XCTAssertEqual(exchange.reading, .backendFailed(kind: "overloaded"), "the stored inode is 0600")
            XCTAssertTrue(agent.waitUntilDone())
            XCTAssertEqual(agent.receivedRequest, request + Data([0x0A]))
        }
        let own = getuid()
        XCTAssertFalse(
            LappiClient.peerMayReceiveQuery(stMode: S_IFSOCK | mode_t(0o2600), peerUID: own, ownUID: own),
            "02600 is not exactly 0600"
        )
    }

    /// Not a second OS user. The uid value is one this process does not own a credential for.
    func testAUidOtherThanOursIsRefusedWithoutASecondOSUser() {
        let own = getuid()
        let other: uid_t = own == 0 ? 1 : 0
        XCTAssertNotEqual(other, own)
        let socket0600 = S_IFSOCK | mode_t(0o600)
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: socket0600, peerUID: other, ownUID: own))
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: socket0600, peerUID: uid_t.max, ownUID: own))
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: nil, peerUID: own, ownUID: own))
        XCTAssertFalse(LappiClient.peerMayReceiveQuery(stMode: socket0600, peerUID: nil, ownUID: own))
    }

    func testASecondSymlinkNameIsRefusedWithNoRequestBytes() throws {
        let agent = try listeningAgent(tag: "symname")
        let link = agent.directory + "/alias.sock"
        XCTAssertEqual(symlink(agent.path, link), 0)
        try assertSymlinkRefused(agent, link: link)
    }

    func testASymlinkInAnotherDirectoryIsRefusedWithNoRequestBytes() throws {
        let agent = try listeningAgent(tag: "symdir")
        let directory = "/private/tmp/qdl-\(getpid())-otherlink"
        try? FileManager.default.removeItem(atPath: directory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        XCTAssertEqual(chmod(directory, 0o777), 0)
        let link = directory + "/via.sock"
        XCTAssertEqual(symlink(agent.path, link), 0)
        try assertSymlinkRefused(agent, link: link)
    }

    /// Both sockets are bound first. The symlink names the first path; that inode is then
    /// replaced by the second socket. `lstat` still sees a symlink and must not write.
    func testASymlinkTargetReplacedAfterBindIsRefusedWithNoRequestBytes() throws {
        let first = try listeningAgent(tag: "swapold")
        let second = try listeningAgent(tag: "swapnew")
        let directory = "/private/tmp/qdl-\(getpid())-swaplink"
        try? FileManager.default.removeItem(atPath: directory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let link = directory + "/via.sock"
        XCTAssertEqual(symlink(first.path, link), 0)
        XCTAssertEqual(rename(second.path, first.path), 0)
        var info = stat()
        XCTAssertEqual(lstat(link, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
        let started = Date()
        let exchange = LappiClient(socketPath: link, timeout: 2).askBlocking(request)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.75, "symlink refusal must not sit in readLine")
        XCTAssertEqual(exchange.reading, .unavailable(.connectRefused))
        XCTAssertTrue(second.waitUntilDone())
        XCTAssertEqual(second.receivedRequest, Data())
        XCTAssertEqual(first.connectionCount, 0)
        XCTAssertNil(first.receivedRequest)
    }

    func testARegularFileAtTheSocketPathIsRefusedAndNotWritten() throws {
        let directory = "/private/tmp/qdl-\(getpid())-regfile"
        try? FileManager.default.removeItem(atPath: directory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/s.sock"
        let marker = Data("not-a-socket-MARKER".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: marker))
        XCTAssertEqual(chmod(path, 0o600), 0)
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
        let line = Data(#"{"op":"ping","secret":"zebracorn"}"#.utf8)
        let started = Date()
        let exchange = LappiClient(socketPath: path, timeout: 2).askBlocking(line)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.75)
        XCTAssertEqual(exchange.reading, .unavailable(.connectRefused))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), marker)
        XCTAssertFalse(try Data(contentsOf: URL(fileURLWithPath: path)).contains(line))
    }

    func testADotDotPathToAPrivateSocketStillExchanges() throws {
        let agent = try LappiFakeAgent.replying("dotdot", #"{"status":"error","schema_version":1,"error":{"kind":"overloaded"},"message":"m"}"#)
        let nested = agent.directory + "/nested"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let exchange = LappiClient(socketPath: nested + "/../s.sock", timeout: 2).askBlocking(request)
        XCTAssertEqual(exchange.reading, .backendFailed(kind: "overloaded"))
        XCTAssertTrue(agent.waitUntilDone())
        XCTAssertEqual(agent.receivedRequest, request + Data([0x0A]))
    }

    func testAnExtraPathComponentIsSocketNotFoundAndSendsNothing() throws {
        let agent = try listeningAgent(tag: "extra")
        let exchange = LappiClient(socketPath: agent.path + "/nope", timeout: 2).askBlocking(request)
        XCTAssertEqual(exchange.reading, .unavailable(.socketNotFound))
        XCTAssertFalse(agent.waitUntilDone(timeout: 0.3))
        XCTAssertEqual(agent.connectionCount, 0)
        XCTAssertNil(agent.receivedRequest)
    }

    func testAWorldWritableDirectoryDoesNotRefuseItsPrivateSocket() throws {
        let agent = try LappiFakeAgent.replying("dir777", #"{"status":"error","schema_version":1,"error":{"kind":"overloaded"},"message":"m"}"#)
        XCTAssertEqual(chmod(agent.directory, 0o777), 0)
        XCTAssertEqual(LappiTestFixtures.permissions(agent.directory), 0o777)
        XCTAssertEqual(LappiTestFixtures.permissions(agent.path), 0o600)
        let exchange = ask(agent)
        XCTAssertEqual(exchange.reading, .backendFailed(kind: "overloaded"))
        XCTAssertTrue(agent.waitUntilDone())
        XCTAssertEqual(agent.receivedRequest, request + Data([0x0A]))
    }

    func testNulAndOverlongSocketPathsAreSocketNotFound() {
        let paths = [
            "/tmp/\u{0}qd.sock",
            "\u{0}",
            "a\u{0}b",
            "/" + String(repeating: "é", count: 80),
            "/" + String(repeating: "a", count: 200),
            String(repeating: "b", count: 104),
        ]
        for path in paths {
            XCTAssertNil(LappiClient.unixAddress(path: path), path.debugDescription)
            let exchange = LappiClient(socketPath: path, timeout: 2).askBlocking(request)
            XCTAssertEqual(exchange.reading, .unavailable(.socketNotFound), path.debugDescription)
        }
    }

    func testPeerRefusalReturnsInsideTheTimeout() throws {
        let agent = try LappiFakeAgent(tag: "slow666", socketMode: 0o666) { fd, agent in
            agent.readRequest(fd)
        }
        XCTAssertEqual(LappiTestFixtures.permissions(agent.path), 0o666)
        let started = Date()
        let exchange = LappiClient(socketPath: agent.path, timeout: 2).askBlocking(request)
        XCTAssertEqual(exchange.reading, .unavailable(.connectRefused))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.75, "a mode refusal must not sit in readLine")
        XCTAssertTrue(agent.waitUntilDone())
        XCTAssertEqual(agent.receivedRequest, Data())
    }

    func testConcurrentPrivateAndWorldSocketsDoNotCrossTalk() throws {
        let goodLine = Data(#"{"op":"good","token":"alpha-private"}"#.utf8)
        let badLine = Data(#"{"op":"bad","token":"beta-world"}"#.utf8)
        let good = try LappiFakeAgent(tag: "cone600", socketMode: 0o600) { fd, agent in
            agent.readRequest(fd)
            LappiFakeAgent.write(fd, Self.overloadedReply)
        }
        let bad = try LappiFakeAgent(tag: "cone666", socketMode: 0o666) { fd, agent in
            LappiFakeAgent.write(fd, Self.overloadedReply)
            agent.readRequest(fd)
        }
        let group = DispatchGroup()
        var goodExchange: LappiExchange?
        var badExchange: LappiExchange?
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            goodExchange = LappiClient(socketPath: good.path, timeout: 2).askBlocking(goodLine)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            badExchange = LappiClient(socketPath: bad.path, timeout: 2).askBlocking(badLine)
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(goodExchange?.reading, .backendFailed(kind: "overloaded"))
        XCTAssertEqual(badExchange?.reading, .unavailable(.connectRefused))
        XCTAssertTrue(good.waitUntilDone())
        XCTAssertTrue(bad.waitUntilDone())
        XCTAssertEqual(good.receivedRequest, goodLine + Data([0x0A]))
        XCTAssertFalse(good.receivedRequest?.contains(Data("beta-world".utf8)) ?? true)
        XCTAssertEqual(bad.receivedRequest, Data(), "the 0666 client must write nothing")
        XCTAssertFalse(bad.receivedRequest?.contains(Data("beta-world".utf8)) ?? true)
    }

    private static let overloadedReply = Data(
        #"{"status":"error","schema_version":1,"error":{"kind":"overloaded"},"message":"x"}"#.utf8 + [0x0A]
    )

    private func listeningAgent(tag: String, socketMode: mode_t = 0o600) throws -> LappiFakeAgent {
        try LappiFakeAgent(tag: tag, socketMode: socketMode) { fd, agent in
            agent.readRequest(fd)
            // A refusal closes before this runs. Writing the reply anyway races a SIGPIPE
            // on a socket the client has already dropped; only answer a request that arrived.
            if agent.receivedRequest?.isEmpty == false {
                LappiFakeAgent.write(fd, Self.overloadedReply)
            }
        }
    }

    private func assertRefused(_ mode: mode_t, file: StaticString = #filePath, line: UInt = #line) throws {
        let tag = "m" + String(mode, radix: 8)
        let agent = try listeningAgent(tag: tag, socketMode: mode)
        var info = stat()
        XCTAssertEqual(lstat(agent.path, &info), 0, tag, file: file, line: line)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK, tag, file: file, line: line)
        if mode == 0o1600 {
            XCTAssertEqual(info.st_mode & S_ISVTX, S_ISVTX, "sticky bit did not stick", file: file, line: line)
        }
        let started = Date()
        let exchange = LappiClient(socketPath: agent.path, timeout: 2).askBlocking(request)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.75, tag, file: file, line: line)
        XCTAssertEqual(
            exchange.reading,
            .unavailable(.connectRefused),
            "mode \(tag) got \(exchange.reading)",
            file: file,
            line: line
        )
        // accept() can still be in poll when askBlocking returns, so the handler's
        // counter is not visible until this wait. A kernel refusal (0400, 0000) never accepts.
        if agent.waitUntilDone(timeout: 0.5) {
            XCTAssertEqual(agent.receivedRequest, Data(), "mode \(tag) saw request bytes", file: file, line: line)
        } else {
            XCTAssertEqual(agent.connectionCount, 0, tag, file: file, line: line)
            XCTAssertNil(agent.receivedRequest, tag, file: file, line: line)
            XCTAssertTrue(
                mode == 0o400 || mode == 0o000,
                "mode \(tag) never connected; only 0400 and 0000 are expected to die in connect()",
                file: file,
                line: line
            )
        }
    }

    private func assertSymlinkRefused(_ agent: LappiFakeAgent, link: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var info = stat()
        XCTAssertEqual(lstat(link, &info), 0, file: file, line: line)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK, file: file, line: line)
        let started = Date()
        let exchange = LappiClient(socketPath: link, timeout: 2).askBlocking(request)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.75, file: file, line: line)
        XCTAssertEqual(exchange.reading, .unavailable(.connectRefused), file: file, line: line)
        XCTAssertTrue(agent.waitUntilDone(), file: file, line: line)
        XCTAssertEqual(agent.receivedRequest, Data(), file: file, line: line)
    }
}
