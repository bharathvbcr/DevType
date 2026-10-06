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
}
