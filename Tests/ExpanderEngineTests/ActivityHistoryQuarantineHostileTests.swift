import XCTest
@testable import ExpanderEngine

/// Hostile cases around a thrown activity-history load. `PersistedFileLoader.moveItem` is
/// process-global; every test that replaces it restores the previous closure before returning.
final class ActivityHistoryQuarantineHostileTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!
    private var savedMove: ((URL, URL) throws -> Void)?

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityHistoryQuarantineHostile-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("activity-history.json")
    }

    override func tearDown() {
        if let savedMove {
            PersistedFileLoader.moveItem = savedMove
            self.savedMove = nil
        }
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testRefusedMoveSurvivesAnotherRecordAndClearThenALaterRecordPreservesIt() throws {
        let corrupt = Data("[{still-corrupt}]".utf8)
        try corrupt.write(to: storeURL)
        let original = refuseMoves()
        defer { PersistedFileLoader.moveItem = original }

        let store = ActivityHistoryStore(fileURL: storeURL)
        let kind = store.persistenceHealth.lastFailureKind
        XCTAssertNotNil(kind)

        guard case .persistenceFailed = store.record(category: .general, title: "First", details: "no") else {
            return XCTFail("first record replaced or ignored a blocked history")
        }
        guard case .persistenceFailed = store.record(category: .general, title: "Second", details: "no") else {
            return XCTFail("second record replaced a blocked history")
        }
        guard case .persistenceFailed = store.clear() else {
            return XCTFail("clear replaced a blocked history")
        }
        let batch = ActivityHistoryStore.ActivityEvent(category: .library, title: "Batch", details: "no")
        guard case .persistenceFailed = store.recordBatch([batch]) else {
            return XCTFail("recordBatch replaced a blocked history")
        }
        _ = store.remove(id: UUID())
        XCTAssertEqual(try Data(contentsOf: storeURL), corrupt)
        XCTAssertEqual(store.persistenceHealth.lastFailureKind, kind)
        XCTAssertTrue(store.recentEvents().isEmpty)

        PersistedFileLoader.moveItem = original
        XCTAssertEqual(
            store.record(category: .expansion, title: "After", details: "preserved"),
            .persisted
        )
        let aside = storeURL.appendingPathExtension("unreadable")
        XCTAssertEqual(try Data(contentsOf: aside), corrupt)
        XCTAssertNotEqual(try? Data(contentsOf: storeURL), corrupt)
        let reloaded = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.recentEvents().map(\.title), ["After"])
        XCTAssertEqual(reloaded.recentEvents().first?.details, "preserved")
        XCTAssertTrue(reloaded.persistenceHealth.isHealthy)
        try assertMoveHookRestored(original)
    }

    func testCorruptHistoryInASpacedUnicodeDirectoryIsQuarantined() throws {
        // Space, precomposed é (U+00E9), and e + combining acute (U+0301).
        let directory = tempDir.appendingPathComponent("notes e\u{0301} \u{00E9} dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("activity-history.json")
        let corrupt = Data("{\"not\":\"an-array\"".utf8)
        try corrupt.write(to: url)

        let store = ActivityHistoryStore(fileURL: url)
        let aside = url.appendingPathExtension("unreadable")
        XCTAssertEqual(try Data(contentsOf: aside), corrupt)
        XCTAssertNotEqual(try? Data(contentsOf: url), corrupt)
        XCTAssertTrue(store.recentEvents().isEmpty)
        XCTAssertFalse(store.persistenceHealth.isHealthy)
        XCTAssertEqual(
            store.persistenceHealth.lastFailureKind,
            ActivityHistoryStore.PersistenceFailureKind.invalidContent.rawValue
        )
    }

    func testValidJSONPrefixPlusTrailingGarbageIsNotLeftAsTheLiveFileWhenRejected() throws {
        let payload = Data(
            ("[{\"id\":\"00000000-0000-0000-0000-0000000000aa\",\"timestamp\":0,"
                + "\"category\":\"general\",\"title\":\"Prefix\",\"details\":\"kept\",\"action\":\"none\"}]"
                + "<<<trailing-garbage").utf8
        )
        try payload.write(to: storeURL)

        let store = ActivityHistoryStore(fileURL: storeURL)
        let aside = storeURL.appendingPathExtension("unreadable")
        if FileManager.default.fileExists(atPath: aside.path) {
            XCTAssertEqual(try Data(contentsOf: aside), payload)
            XCTAssertNotEqual(try? Data(contentsOf: storeURL), payload)
            XCTAssertTrue(store.recentEvents().isEmpty)
            XCTAssertFalse(store.persistenceHealth.isHealthy)
            fputs("HOSTILE_OUTCOME trailing-garbage: decoder rejected; bytes quarantined\n", stderr)
        } else {
            // The bounded decoder accepted the prefix. Do not require a reject.
            XCTAssertEqual(store.recentEvents().map(\.title), ["Prefix"])
            XCTAssertTrue(store.persistenceHealth.isHealthy)
            fputs("HOSTILE_OUTCOME trailing-garbage: decoder accepted the prefix\n", stderr)
        }
    }

    func testZeroByteFileIsNotTheMissingFileOutcome() throws {
        try Data().write(to: storeURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        let store = ActivityHistoryStore(fileURL: storeURL)
        // A missing file stays healthy and creates no sibling. Empty bytes fail JSON decode,
        // so this load throws and must be quarantined instead of looking like first run.
        let aside = storeURL.appendingPathExtension("unreadable")
        XCTAssertFalse(
            store.persistenceHealth.isHealthy,
            "a zero-byte file was treated as a missing file"
        )
        XCTAssertEqual(
            store.persistenceHealth.lastFailureKind,
            ActivityHistoryStore.PersistenceFailureKind.invalidContent.rawValue
        )
        XCTAssertEqual(try Data(contentsOf: aside), Data())
        XCTAssertTrue(store.recentEvents().isEmpty)
        XCTAssertEqual(store.record(category: .general, title: "After empty", details: "ok"), .persisted)
        XCTAssertEqual(try Data(contentsOf: aside), Data())
        XCTAssertEqual(ActivityHistoryStore(fileURL: storeURL).recentEvents().map(\.title), ["After empty"])
        fputs("HOSTILE_OUTCOME zero-byte: thrown invalidContent, quarantined, later record persisted\n", stderr)
    }

    func testPreseededUnreadableSiblingSurvivesTwoLaterCorruptInits() throws {
        let seeded = Data("seeded-sibling".utf8)
        let first = Data("{\"pass\":1}".utf8)
        let second = Data("{\"pass\":2}".utf8)
        let seededAside = storeURL.appendingPathExtension("unreadable")
        try seeded.write(to: seededAside)

        try first.write(to: storeURL)
        _ = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertEqual(try Data(contentsOf: seededAside), seeded)
        XCTAssertNotEqual(try? Data(contentsOf: storeURL), first)

        try second.write(to: storeURL)
        _ = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertEqual(try Data(contentsOf: seededAside), seeded)
        XCTAssertNotEqual(try? Data(contentsOf: storeURL), second)

        let copies = try unreadableCopies()
        XCTAssertEqual(copies.count, 3)
        let preserved = try Set(copies.map { try Data(contentsOf: $0) })
        XCTAssertEqual(preserved, Set([seeded, first, second]))
    }

    func testLegacyPlaintextScrubSavesWithoutQuarantine() throws {
        let secret = "dictated password sentinel hostile"
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","timestamp":0,"category":"voice","title":"Recovered dictation","details":"\(secret)","action":"none"}]
        """
        try Data(legacy.utf8).write(to: storeURL)

        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertTrue(store.recentEvents().isEmpty)
        XCTAssertTrue(store.persistenceHealth.isHealthy)
        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertFalse(names.contains { $0.contains("unreadable") })
        let rewritten = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertFalse(rewritten.contains(secret))
        XCTAssertTrue(ActivityHistoryStore(fileURL: storeURL).persistenceHealth.isHealthy)
    }

    func testSuccessfulQuarantineDoesNotLeaveCorruptBytesOnTheLivePathWhenDestinationExists() throws {
        let earlier = Data("earlier-sibling".utf8)
        let corrupt = Data("{\"live\":true".utf8)
        let taken = storeURL.appendingPathExtension("unreadable")
        try earlier.write(to: taken)
        try corrupt.write(to: storeURL)

        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertNotEqual(try? Data(contentsOf: storeURL), corrupt)
        XCTAssertEqual(try Data(contentsOf: taken), earlier)
        XCTAssertTrue(store.recentEvents().isEmpty)
        let copies = try unreadableCopies()
        let preserved = try copies.map { try Data(contentsOf: $0) }
        XCTAssertTrue(preserved.contains(corrupt))
        XCTAssertTrue(preserved.contains(earlier))
    }

    func testConcurrentRecordsAfterAFailedQuarantineDoNotReplaceTheLiveBytes() throws {
        let corrupt = Data("[{concurrent-corrupt}]".utf8)
        try corrupt.write(to: storeURL)
        let original = refuseMoves()
        defer { PersistedFileLoader.moveItem = original }

        let store = ActivityHistoryStore(fileURL: storeURL)
        let group = DispatchGroup()
        let results = NSLock()
        var outcomes: [ActivityHistoryStore.MutationResult] = []
        let queue = DispatchQueue(label: "ahq.hostile.concurrent", attributes: .concurrent)
        for index in 0..<6 {
            group.enter()
            queue.async {
                let result = store.record(category: .general, title: "Race \(index)", details: "x")
                results.lock()
                outcomes.append(result)
                results.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(outcomes.count, 6)
        XCTAssertTrue(outcomes.allSatisfy { if case .persistenceFailed = $0 { return true }; return false })
        XCTAssertEqual(try Data(contentsOf: storeURL), corrupt)
        XCTAssertTrue(store.recentEvents().isEmpty)
        try assertMoveHookRestored(original)
    }

    private struct MoveRefused: Error {}

    private func refuseMoves() -> ((URL, URL) throws -> Void) {
        let original = PersistedFileLoader.moveItem
        savedMove = original
        PersistedFileLoader.moveItem = { _, _ in throw MoveRefused() }
        return original
    }

    private func assertMoveHookRestored(_ original: @escaping (URL, URL) throws -> Void) throws {
        PersistedFileLoader.moveItem = original
        savedMove = nil
        let source = tempDir.appendingPathComponent("probe-\(UUID().uuidString)")
        let dest = tempDir.appendingPathComponent("probe-dst-\(UUID().uuidString)")
        try Data("restored".utf8).write(to: source)
        try PersistedFileLoader.moveItem(source, dest)
        XCTAssertEqual(try Data(contentsOf: dest), Data("restored".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    private func unreadableCopies() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("unreadable") }
    }
}
