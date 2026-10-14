import XCTest
@testable import ExpanderEngine

/// The `devtype.route` request, byte for byte (contract §4), and the bytes-not-String rule
/// for its context (schema-api.md, "Request").
final class LappiRequestTests: XCTestCase {

    func testTheRequestLineIsExactlyTheContractShape() throws {
        let line = try LappiRouteRequest.line(
            context: Data("date three weeks out".utf8),
            recordID: LappiTestFixtures.recordID
        )
        let expected = #"{"context_b64":"ZGF0ZSB0aHJlZSB3ZWVrcyBvdXQ=","context_len":20,"#
            + #""example_id":"devtype:devtype.route:0123456789abcdef0123456789abcdef","metadata":{},"#
            + #""question":"Which DevType tool should answer this palette query?","route":"generic","#
            + #""schema_version":1,"slots":[{"name":"route","options":["resolveDate","runMacro","findSnippet","none"],"type":"choice"}],"#
            + #""task":"devtype.route"}"#
        XCTAssertEqual(String(decoding: line, as: UTF8.self), expected)
        XCTAssertFalse(line.contains(0x0A), "a request is one line")
    }

    func testTheRequestDecodesToTheExpectedObject() throws {
        let line = try LappiRouteRequest.line(context: Data("x y z w".utf8), recordID: LappiTestFixtures.recordID)
        let object = try LappiTestFixtures.object(line)
        XCTAssertEqual(Set(object.keys), [
            "schema_version", "task", "context_b64", "context_len", "question", "slots", "route",
            "example_id", "metadata",
        ])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["task"] as? String, "devtype.route")
        XCTAssertEqual(object["question"] as? String, "Which DevType tool should answer this palette query?")
        XCTAssertEqual(object["route"] as? String, "generic")
        XCTAssertEqual(object["example_id"] as? String, "devtype:devtype.route:\(LappiTestFixtures.recordID)")
        XCTAssertEqual((object["metadata"] as? [String: Any])?.isEmpty, true)
        let slots = try XCTUnwrap(object["slots"] as? [[String: Any]])
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0]["name"] as? String, "route")
        XCTAssertEqual(slots[0]["type"] as? String, "choice")
        XCTAssertEqual(slots[0]["options"] as? [String], ["resolveDate", "runMacro", "findSnippet", "none"])
    }

    func testContextBytesCrossExactlyIncludingNULEmojiAndUnnormalizedMarks() throws {
        // NFD "é" (e + U+0301), a precomposed "é", an emoji, a NUL and an invalid UTF-8 byte:
        // none of these may be normalized, dropped or re-encoded on the way out.
        let bytes = Data([0x65, 0xCC, 0x81, 0x20, 0xC3, 0xA9, 0x20, 0xF0, 0x9F, 0xAB, 0xA0, 0x00, 0x78, 0xFF])
        let line = try LappiRouteRequest.line(context: bytes, recordID: LappiTestFixtures.recordID)
        let object = try LappiTestFixtures.object(line)
        let b64 = try XCTUnwrap(object["context_b64"] as? String)
        XCTAssertEqual(Data(base64Encoded: b64), bytes)
        XCTAssertEqual(object["context_len"] as? Int, bytes.count)
        XCTAssertEqual(b64.count % 4, 0, "padded, canonical base64")
        XCTAssertFalse(b64.contains("-") || b64.contains("_") || b64.contains("\n"), "standard alphabet, unwrapped")
    }

    func testAQueryStringsUTF8IsTakenOnceAndNotNormalized() throws {
        let query = "e\u{301} \u{1FAE0}\u{0}x"
        XCTAssertEqual(Array(query.utf8), [0x65, 0xCC, 0x81, 0x20, 0xF0, 0x9F, 0xAB, 0xA0, 0x00, 0x78])
        let line = try LappiRouteRequest.line(context: Data(query.utf8), recordID: LappiTestFixtures.recordID)
        let b64 = try XCTUnwrap(try LappiTestFixtures.object(line)["context_b64"] as? String)
        XCTAssertEqual(Data(base64Encoded: b64), Data(query.utf8))
    }

    func testTheCoordinatorSendsTheQueryBytesOverTheSocket() async throws {
        let query = "e\u{301} \u{1FAE0}\u{0}x date"
        let agent = try LappiFakeAgent.replying("coord", #"""
        {"status":"refused","schema_version":1,"refusal":{"kind":"task_not_trained","task":"devtype.route","available":[]},"message":"m"}
        """#)
        let path = agent.path
        let routing = LappiPaletteRouting(environment: .init(
            client: { LappiClient(socketPath: path, timeout: 2) },
            writer: nil,
            askEnabled: { true },
            collectionAllowed: { false },
            isSecureContext: { false }
        ))
        let attempt = try await XCTUnwrapAsync(await routing.ask(query: query))
        XCTAssertEqual(attempt.exchange.reading, .requestRefused(kind: "task_not_trained"))
        agent.waitUntilDone()
        var sent = try XCTUnwrap(agent.receivedRequest)
        XCTAssertEqual(sent.last, 0x0A)
        sent.removeLast()
        let object = try LappiTestFixtures.object(sent)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(object["context_b64"] as? String)), Data(query.utf8))
        XCTAssertEqual(object["example_id"] as? String, "devtype:devtype.route:\(attempt.ticket.recordID)")
    }

    func testAskStaysOffWhenThePreferenceIsUnset() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: LappiPreferences.askEnabledKey)
        defer {
            if let saved { defaults.set(saved, forKey: LappiPreferences.askEnabledKey) }
            else { defaults.removeObject(forKey: LappiPreferences.askEnabledKey) }
        }
        defaults.removeObject(forKey: LappiPreferences.askEnabledKey)
        XCTAssertFalse(LappiPreferences.isAskEnabled)
        XCTAssertEqual(LappiPreferences.askEnabledKey, "devtype.lappi.askEnabled")
    }

    func testAskingDisabledSendsNothing() async throws {
        let agent = try LappiFakeAgent.replying("off", #"{"status":"error","schema_version":1}"#)
        let path = agent.path
        let routing = LappiPaletteRouting(environment: .init(
            client: { LappiClient(socketPath: path) },
            writer: nil,
            askEnabled: { false },
            collectionAllowed: { false },
            isSecureContext: { false }
        ))
        let attempt = try await XCTUnwrapAsync(await routing.ask(query: "date three weeks out"))
        XCTAssertEqual(attempt.exchange, LappiExchange(reading: .notAsked(.askingDisabled), latencyMs: nil))
        XCTAssertFalse(agent.waitUntilDone(timeout: 0.3))
        XCTAssertEqual(agent.connectionCount, 0)
    }

    func testSecureInputSendsNothing() async throws {
        let agent = try LappiFakeAgent.replying("sec", #"{"status":"error","schema_version":1}"#)
        let path = agent.path
        let routing = LappiPaletteRouting(environment: .init(
            client: { LappiClient(socketPath: path) },
            writer: nil,
            askEnabled: { true },
            collectionAllowed: { false },
            isSecureContext: { true }
        ))
        let attempt = try await XCTUnwrapAsync(await routing.ask(query: "date three weeks out"))
        XCTAssertEqual(attempt.exchange.reading, .notAsked(.secureInput))
        XCTAssertFalse(agent.waitUntilDone(timeout: 0.3))
        XCTAssertEqual(agent.connectionCount, 0)
    }
}

/// `XCTUnwrap` cannot take an `await` inside its autoclosure.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
