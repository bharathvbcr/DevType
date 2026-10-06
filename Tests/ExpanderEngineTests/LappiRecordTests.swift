import Darwin
import XCTest
@testable import ExpanderEngine

/// Caller records (contract §5): shape, privacy, gates, the writer's bounds, pairing, and a
/// cross-check against the Rust checker when it is available.
final class LappiRecordTests: XCTestCase {

    private let createdAt = Date(timeIntervalSince1970: 1_791_299_405.25) // 2026-10-06T15:10:05.250Z

    private static let allReadings: [LappiExchange] = [
        LappiExchange(reading: .modelAnswered(backend: "qd-metal/qwen3.5-2b-base/tessl", slots: [
            "route": LappiSlotAnswer(value: .label("resolveDate"), conformalSet: ["resolveDate"], score: 0.91, noul: false, degraded: false),
        ]), latencyMs: 140),
        LappiExchange(reading: .modelAbstained(backend: "reference-deterministic-v1", slots: [
            "route": LappiSlotAnswer(value: nil, conformalSet: nil, score: 0.04, noul: true, degraded: true),
        ]), latencyMs: 9),
        LappiExchange(reading: .requestRefused(kind: "task_not_trained"), latencyMs: 3),
        LappiExchange(reading: .backendFailed(kind: "overloaded"), latencyMs: 2),
        LappiExchange(reading: .unavailable(.deadline), latencyMs: 300),
        LappiExchange(reading: .notAsked(.askingDisabled), latencyMs: nil),
    ]

    private func decision(_ exchange: LappiExchange, query: String = "date three weeks out") -> [String: Any] {
        LappiCallerRecord.decision(
            recordID: LappiTestFixtures.recordID,
            createdAt: createdAt,
            appVersion: "0.1.4",
            query: query,
            tool: "resolveDate",
            engine: LappiCallerRecord.engineFoundationModels,
            exchange: exchange
        )
    }

    // MARK: - Shape

    func testADecisionRecordHasExactlyTheVersionOneKeys() throws {
        let object = try LappiTestFixtures.object(LappiCallerRecord.encode(decision(Self.allReadings[2])))
        XCTAssertEqual(Set(object.keys), [
            "record", "record_version", "kind", "record_id", "app", "app_version", "decision_point",
            "created_at", "admission", "facts", "app_choice", "lappi", "redaction",
        ])
        XCTAssertEqual(object["record"] as? String, "lappi.caller_record")
        XCTAssertEqual(object["record_version"] as? Int, 1)
        XCTAssertEqual(object["kind"] as? String, "decision")
        XCTAssertEqual(object["app"] as? String, "devtype")
        XCTAssertEqual(object["decision_point"] as? String, "devtype.route")
        XCTAssertEqual(object["admission"] as? String, "not_admitted")
        XCTAssertEqual(object["created_at"] as? String, "2026-10-06T15:10:05.250Z")
        XCTAssertEqual(object["app_choice"] as? [String: String], ["tool": "resolveDate", "engine": "foundation-models"])
        let facts = try XCTUnwrap(object["facts"] as? [String: Any])
        XCTAssertEqual(Set(facts.keys), ["query_chars", "query_shape"])
        XCTAssertEqual(facts["query_chars"] as? Int, 20)
        let redaction = try XCTUnwrap(object["redaction"] as? [String: Any])
        XCTAssertEqual(redaction["policy"] as? String, "devtype.diagnostic-privacy")
        XCTAssertEqual(redaction["fields_redacted"] as? Int, 1)
    }

    func testAnOutcomeRecordHasExactlyTheVersionOneKeys() throws {
        let object = try LappiTestFixtures.object(LappiCallerRecord.encode(LappiCallerRecord.outcome(
            recordID: LappiTestFixtures.recordID, createdAt: createdAt, appVersion: "0.1.4", picked: .routed
        )))
        XCTAssertEqual(Set(object.keys), [
            "record", "record_version", "kind", "record_id", "app", "app_version", "decision_point",
            "created_at", "admission", "observed", "redaction",
        ])
        XCTAssertEqual(object["observed"] as? [String: String], ["picked": "routed"])
    }

    /// The `lappi` block's consistency rules, as `caller_record.rs::check_lappi` enforces them.
    func testTheLappiBlockIsConsistentForEveryReading() throws {
        for exchange in Self.allReadings {
            let object = try LappiTestFixtures.object(LappiCallerRecord.encode(decision(exchange)))
            let lappi = try XCTUnwrap(object["lappi"] as? [String: Any])
            let name = exchange.reading.name
            XCTAssertEqual(Set(lappi.keys), ["asked", "task", "reading", "kind", "backend", "slots", "latency_ms"], name)
            XCTAssertEqual(lappi["reading"] as? String, name)
            let asked = try XCTUnwrap(lappi["asked"] as? Bool)
            XCTAssertEqual(asked, name != "not_asked", name)
            XCTAssertEqual(lappi["task"] as? String, asked ? "devtype.route" : nil, name)
            switch name {
            case "model_answered", "model_abstained":
                XCTAssertNotNil(lappi["slots"] as? [String: Any], name)
                XCTAssertNotNil(lappi["backend"] as? String, name)
                XCTAssertTrue(lappi["kind"] is NSNull, name)
            case "request_refused", "backend_failed", "unavailable":
                XCTAssertNotNil(lappi["kind"] as? String, name)
                XCTAssertTrue(lappi["slots"] is NSNull, name)
                XCTAssertTrue(lappi["backend"] is NSNull, name)
            default:
                XCTAssertTrue(lappi["kind"] is NSNull && lappi["slots"] is NSNull && lappi["backend"] is NSNull, name)
                XCTAssertTrue(lappi["latency_ms"] is NSNull, name)
            }
        }
    }

    func testTheQueryTextNeverReachesTheRecord() throws {
        let query = "zebracorn invoice for quokka"
        for exchange in Self.allReadings {
            let line = try LappiCallerRecord.encode(decision(exchange, query: query))
            let text = String(decoding: line, as: UTF8.self)
            for word in ["zebracorn", "invoice", "quokka"] {
                XCTAssertFalse(text.contains(word), "\(exchange.reading.name) leaked \(word)")
            }
        }
    }

    func testAnEchoOfTheQueryOrACredentialFromTheAgentIsScrubbed() throws {
        let query = "zebracorn invoice for quokka"
        let exchange = LappiExchange(reading: .modelAnswered(backend: "echo zebracorn invoice for quokka", slots: [
            "route": LappiSlotAnswer(value: .label("ghp_abcdefghijklmnop1234"), conformalSet: nil, score: 0.5, noul: false, degraded: false),
        ]), latencyMs: 1)
        let line = try LappiCallerRecord.encode(decision(exchange, query: query))
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertFalse(text.contains("zebracorn"))
        XCTAssertFalse(text.contains("ghp_abcdefghijklmnop1234"))
        let redaction = try XCTUnwrap(try LappiTestFixtures.object(line)["redaction"] as? [String: Any])
        XCTAssertEqual(redaction["fields_redacted"] as? Int, 3, "the query, the echoed backend and the credential")
    }

    func testRecordIDsAndTimestampsHaveTheCheckedShapes() throws {
        let id = try XCTUnwrap(LappiCallerRecord.newRecordID())
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        XCTAssertNotEqual(id, LappiCallerRecord.newRecordID())
        let stamp = LappiCallerRecord.timestamp(createdAt)
        XCTAssertNotNil(stamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression), stamp)
        XCTAssertFalse(LappiCallerRecord.appVersion().isEmpty)
    }

    // MARK: - Preferences and gates

    func testPreferencesDefaultOff() {
        let defaults = UserDefaults.standard
        let saved = [LappiPreferences.askEnabledKey, LappiPreferences.recordEnabledKey].map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip([LappiPreferences.askEnabledKey, LappiPreferences.recordEnabledKey], saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.removeObject(forKey: LappiPreferences.askEnabledKey)
        defaults.removeObject(forKey: LappiPreferences.recordEnabledKey)
        XCTAssertFalse(LappiPreferences.isAskEnabled)
        XCTAssertFalse(LappiPreferences.isRecordEnabled)
        XCTAssertFalse(LappiPreferences.isCollectionAllowed(environment: [:]))
        XCTAssertEqual(LappiPreferences.askEnabledKey, "devtype.lappi.askEnabled")
        XCTAssertEqual(LappiPreferences.recordEnabledKey, "devtype.lappi.recordEnabled")
    }

    func testLappiCollectZeroForcesRecordingOff() {
        XCTAssertFalse(LappiPreferences.isCollectionAllowed(recordEnabled: true, environment: ["LAPPI_COLLECT": "0"]))
        XCTAssertTrue(LappiPreferences.isCollectionAllowed(recordEnabled: true, environment: ["LAPPI_COLLECT": "1"]))
        XCTAssertTrue(LappiPreferences.isCollectionAllowed(recordEnabled: true, environment: [:]))
        XCTAssertFalse(LappiPreferences.isCollectionAllowed(recordEnabled: false, environment: ["LAPPI_COLLECT": "1"]))
    }

    func testTheDefaultStoreIsHeldOutAndNeverTheRealOneUnderTests() throws {
        let root = try XCTUnwrap(LappiRecordWriter.defaultRoot(environment: ["HOME": "/Users/someone"]))
        XCTAssertTrue(LappiRecordWriter.isHeldOut(root))
        XCTAssertFalse(root.path.hasPrefix("/Users/someone"), "a test process must not resolve the real store")
        XCTAssertTrue(root.path.hasSuffix("Lappi/heldout/caller-records"))
    }

    func testEveryPaletteSharesOneWriterSoDropCountsPersist() throws {
        // A palette builds a fresh coordinator per open; the writer (its counters and its
        // log-once set) must not be rebuilt with it.
        let first = try XCTUnwrap(LappiPaletteRouting.Environment.live().writer)
        let second = try XCTUnwrap(LappiPaletteRouting.Environment.live().writer)
        XCTAssertTrue(first === second)
        XCTAssertTrue(first === LappiRecordWriter.shared)
    }

    // MARK: - Coordinator: gates at write time, pairing

    private func makeRouting(
        store: URL,
        collect: Bool = true,
        secure: @escaping @Sendable () -> Bool = { false }
    ) -> (LappiPaletteRouting, LappiRecordWriter) {
        let writer = LappiRecordWriter(root: store)
        let createdAt = self.createdAt
        let routing = LappiPaletteRouting(environment: .init(
            client: { nil },
            writer: writer,
            askEnabled: { false },
            collectionAllowed: { collect },
            isSecureContext: secure,
            now: { createdAt },
            appVersion: "0.1.4"
        ))
        return (routing, writer)
    }

    private let ticket = LappiPaletteRouting.Ticket(recordID: LappiTestFixtures.recordID, query: "date three weeks out")
    private let notAsked = LappiExchange(reading: .notAsked(.askingDisabled), latencyMs: nil)

    func testADecisionAndItsOutcomeShareARecordID() throws {
        let store = try LappiTestFixtures.scratchStore("pair")
        let (routing, writer) = makeRouting(store: store)
        routing.recordDecision(ticket: ticket, tool: "none", engine: "foundation-models", exchange: notAsked)
        routing.recordOutcome(.cancel, query: ticket.query)
        routing.recordOutcome(.routed, query: ticket.query) // consumed: no second outcome
        routing.waitUntilIdle()
        let lines = try LappiTestFixtures.lines(in: writer.dayFile(for: createdAt))
        XCTAssertEqual(lines.count, 2)
        let kinds = try lines.map { try LappiTestFixtures.object($0)["kind"] as? String }
        XCTAssertEqual(kinds, ["decision", "outcome"])
        let ids = try lines.map { try LappiTestFixtures.object($0)["record_id"] as? String }
        XCTAssertEqual(ids, [LappiTestFixtures.recordID, LappiTestFixtures.recordID])
        XCTAssertEqual(try LappiTestFixtures.object(lines[1])["observed"] as? [String: String], ["picked": "cancel"])
    }

    func testAnOutcomeForADifferentQueryIsNotPaired() throws {
        let store = try LappiTestFixtures.scratchStore("stale")
        let (routing, writer) = makeRouting(store: store)
        routing.recordDecision(ticket: ticket, tool: "none", engine: "foundation-models", exchange: notAsked)
        routing.recordOutcome(.snippet, query: "date three weeks out and more")
        routing.waitUntilIdle()
        XCTAssertEqual(try LappiTestFixtures.lines(in: writer.dayFile(for: createdAt)).count, 1)
    }

    func testSecureInputSuppressesEveryRecord() throws {
        let store = try LappiTestFixtures.scratchStore("secure")
        let (routing, writer) = makeRouting(store: store, secure: { true })
        routing.recordDecision(ticket: ticket, tool: "none", engine: "foundation-models", exchange: notAsked)
        routing.recordOutcome(.routed, query: ticket.query)
        routing.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.dayFile(for: createdAt).path))
        XCTAssertEqual(writer.stats, LappiRecordWriter.Stats())
    }

    func testSecureInputArrivingBeforeThePickSuppressesTheOutcome() throws {
        let store = try LappiTestFixtures.scratchStore("secure-late")
        let flag = LappiFlag()
        let (routing, writer) = makeRouting(store: store, secure: { flag.value })
        routing.recordDecision(ticket: ticket, tool: "none", engine: "foundation-models", exchange: notAsked)
        routing.waitUntilIdle()
        flag.set(true)
        routing.recordOutcome(.routed, query: ticket.query)
        routing.waitUntilIdle()
        XCTAssertEqual(try LappiTestFixtures.lines(in: writer.dayFile(for: createdAt)).count, 1, "checked live at write time")
    }

    func testRecordingOffWritesNothing() throws {
        let store = try LappiTestFixtures.scratchStore("off")
        let (routing, writer) = makeRouting(store: store, collect: false)
        routing.recordDecision(ticket: ticket, tool: "none", engine: "foundation-models", exchange: notAsked)
        routing.recordOutcome(.routed, query: ticket.query)
        routing.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.dayFile(for: createdAt).path))
    }

    // MARK: - Writer

    private func line(_ size: Int, tag: String = "a") -> Data {
        // A valid JSON object padded to `size` bytes, so a reader can parse every line.
        let prefix = #"{"pad":""#
        let suffix = #""}"#
        let pad = String(repeating: tag, count: max(0, size - prefix.count - suffix.count))
        return Data((prefix + pad + suffix).utf8)
    }

    func testWriterPermissionsAndAppend() throws {
        let store = try LappiTestFixtures.scratchStore("perm")
        let writer = LappiRecordWriter(root: store)
        XCTAssertEqual(writer.append(line(100), createdAt: createdAt), .written)
        XCTAssertEqual(writer.append(line(120, tag: "b"), createdAt: createdAt), .written)
        let file = writer.dayFile(for: createdAt)
        XCTAssertEqual(file.lastPathComponent, "2026-10-06.jsonl")
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "devtype")
        XCTAssertEqual(LappiTestFixtures.permissions(file.path), 0o600)
        XCTAssertEqual(LappiTestFixtures.permissions(file.deletingLastPathComponent().path), 0o700)
        XCTAssertEqual(LappiTestFixtures.permissions(store.path), 0o700, "directories this writer creates are 0700")
        let lines = try LappiTestFixtures.lines(in: file)
        XCTAssertEqual(lines, [line(100), line(120, tag: "b")])
        XCTAssertEqual(writer.stats.written, 2)
    }

    func testALineOverSixtyFourKiBIsDroppedAndCounted() throws {
        let store = try LappiTestFixtures.scratchStore("line")
        let writer = LappiRecordWriter(root: store)
        XCTAssertEqual(writer.append(line(64 * 1024), createdAt: createdAt), .written)
        XCTAssertEqual(writer.append(line(64 * 1024 + 1), createdAt: createdAt), .droppedLineOverCap)
        XCTAssertEqual(try LappiTestFixtures.lines(in: writer.dayFile(for: createdAt)).count, 1)
        XCTAssertEqual(writer.stats.droppedLineOverCap, 1)
    }

    func testTheDayFileCapStopsRecordingUntilCleared() throws {
        let store = try LappiTestFixtures.scratchStore("day")
        let writer = LappiRecordWriter(root: store, maxDayFileBytes: 250, maxStoreBytes: LappiRecordWriter.maxStoreBytes)
        XCTAssertEqual(writer.append(line(100), createdAt: createdAt), .written)
        XCTAssertEqual(writer.append(line(100), createdAt: createdAt), .written)
        XCTAssertEqual(writer.append(line(100), createdAt: createdAt), .droppedDayFileCap)
        XCTAssertEqual(writer.append(line(10), createdAt: createdAt), .written, "a line that still fits is written")
        XCTAssertEqual(writer.append(line(100), createdAt: createdAt), .droppedDayFileCap)
        XCTAssertEqual(writer.stats.droppedDayFileCap, 2)
        try FileManager.default.removeItem(at: writer.dayFile(for: createdAt))
        XCTAssertEqual(writer.append(line(100), createdAt: createdAt), .written, "clearing the file resumes recording")
    }

    func testTheStoreCapCountsEveryDaysFile() throws {
        let store = try LappiTestFixtures.scratchStore("store")
        let writer = LappiRecordWriter(root: store, maxDayFileBytes: LappiRecordWriter.maxDayFileBytes, maxStoreBytes: 300)
        let yesterday = createdAt.addingTimeInterval(-86_400)
        XCTAssertEqual(writer.append(line(200), createdAt: yesterday), .written)
        XCTAssertEqual(writer.append(line(200), createdAt: createdAt), .droppedStoreCap)
        XCTAssertEqual(writer.stats.droppedStoreCap, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.dayFile(for: createdAt).path))
    }

    func testAStoreOutsideAHeldOutSegmentIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lappi-trainable-\(UUID().uuidString)/caller-records", isDirectory: true)
        let writer = LappiRecordWriter(root: root)
        XCTAssertEqual(writer.append(line(50), createdAt: createdAt), .refusedNotHeldOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(writer.stats.refusedNotHeldOut, 1)
    }

    func testConcurrentWritersProduceWholeLinesOnly() throws {
        let store = try LappiTestFixtures.scratchStore("concurrent")
        // Two writers, as two DevType processes would be: separate locks, one file.
        let writers = [LappiRecordWriter(root: store), LappiRecordWriter(root: store)]
        let perThread = 40
        let threads = 6
        DispatchQueue.concurrentPerform(iterations: threads) { index in
            let writer = writers[index % writers.count]
            let tag = String(UnicodeScalar(UInt8(97 + index)))
            for _ in 0..<perThread {
                _ = writer.append(line(3_000, tag: tag), createdAt: createdAt)
            }
        }
        let file = writers[0].dayFile(for: createdAt)
        let data = try Data(contentsOf: file)
        XCTAssertEqual(data.last, 0x0A, "the file ends on a whole line")
        let lines = try LappiTestFixtures.lines(in: file)
        XCTAssertEqual(lines.count, perThread * threads)
        for line in lines {
            let object = try LappiTestFixtures.object(line)
            let pad = try XCTUnwrap(object["pad"] as? String)
            XCTAssertEqual(Set(pad).count, 1, "a line interleaved with another writer's")
        }
    }

    // MARK: - Cross-check against the Rust checker

    func testRecordsPassTheRustCheckerWhenItIsAvailable() throws {
        let store = try LappiTestFixtures.scratchStore("xcheck")
        let writer = LappiRecordWriter(root: store)
        for (index, exchange) in Self.allReadings.enumerated() {
            let id = String(format: "%032lx", index + 1)
            let decisionLine = try LappiCallerRecord.encode(LappiCallerRecord.decision(
                recordID: id, createdAt: createdAt, appVersion: LappiCallerRecord.appVersion(),
                query: "uppercase what I copied \u{1FAE0}", tool: LappiRouteRequest.options[index % 4],
                engine: LappiCallerRecord.engineFoundationModels, exchange: exchange
            ))
            XCTAssertEqual(writer.append(decisionLine, createdAt: createdAt), .written)
            let picked = LappiCallerRecord.Picked.allCases[index % 4]
            let outcomeLine = try LappiCallerRecord.encode(LappiCallerRecord.outcome(
                recordID: id, createdAt: createdAt.addingTimeInterval(2), appVersion: LappiCallerRecord.appVersion(), picked: picked
            ))
            XCTAssertEqual(writer.append(outcomeLine, createdAt: createdAt), .written)
        }
        let file = writer.dayFile(for: createdAt)
        XCTAssertTrue(file.path.contains("/heldout/"))

        guard let binary = ProcessInfo.processInfo.environment["QD_CALLER_RECORDS_BIN"], !binary.isEmpty else {
            print("cross-check NOT RUN: QD_CALLER_RECORDS_BIN is unset; records at \(file.path)")
            throw XCTSkip("cross-check NOT RUN: QD_CALLER_RECORDS_BIN is unset")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain before waiting, so a report larger than the pipe buffer cannot deadlock.
        let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        print("qd-caller-records: exit \(process.terminationStatus)\n\(report)")
        XCTAssertEqual(process.terminationStatus, 0, report)
    }
}

/// A thread-safe boolean for a gate that flips during a test.
final class LappiFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set(_ new: Bool) {
        lock.lock(); flag = new; lock.unlock()
    }
}
