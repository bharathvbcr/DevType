import XCTest
@testable import ExpanderEngine

final class ActivityHistoryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("activity-test.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testRecordAndRetrieveEvents() {
        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertTrue(store.recentEvents().isEmpty)

        XCTAssertEqual(store.record(
            category: .expansion,
            title: "Expansion Failed",
            details: "Could not expand ;test",
            action: .openPermissionRecovery
        ), .persisted)

        let events = store.recentEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.category, .expansion)
        XCTAssertEqual(events.first?.title, "Expansion Failed")
        XCTAssertEqual(events.first?.action, .openPermissionRecovery)
    }

    func testRingBufferBoundsAtMaxEvents() {
        let store = ActivityHistoryStore(fileURL: storeURL)

        for i in 0..<35 {
            store.record(
                category: .general,
                title: "Event \(i)",
                details: "Details \(i)"
            )
        }

        let events = store.recentEvents(limit: 50)
        XCTAssertEqual(events.count, ActivityHistoryStore.maxEvents)
        XCTAssertEqual(events.first?.title, "Event 34")
        XCTAssertEqual(events.last?.title, "Event 10")
    }

    func testClearEvents() {
        let store = ActivityHistoryStore(fileURL: storeURL)
        store.record(category: .ai, title: "AI Error", details: "Model busy")
        XCTAssertEqual(store.recentEvents().count, 1)

        store.clear()
        XCTAssertTrue(store.recentEvents().isEmpty)
    }

    func testRecordIsDurableWhenItReturns() {
        let store = ActivityHistoryStore(fileURL: storeURL)
        store.record(category: .voice, title: "Voice Error", details: "No microphone")

        let reloaded = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.recentEvents().first?.title, "Voice Error")
    }

    func testTypedSignalRoundTripRendersInTheCurrentLanguageWithoutPersistingLocalizedCopy() throws {
        let previousLanguage = UserDefaults.standard.object(forKey: LocalizationManager.deviceKey)
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: LocalizationManager.deviceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
            }
        }

        let localization = LocalizationManager()
        localization.language = .en
        let signal = ActivitySignal.importCompleted(added: 2, updated: 1, unchanged: 3, saved: true)
        let english = signal.descriptor(localization: localization)
        let store = ActivityHistoryStore(fileURL: storeURL)

        XCTAssertEqual(store.record(signal, localization: localization), .persisted)

        let encoded = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertTrue(encoded.contains("\"contentVersion\":1"))
        XCTAssertFalse(encoded.contains(english.title))
        XCTAssertFalse(encoded.contains(english.details))

        let event = try XCTUnwrap(ActivityHistoryStore(fileURL: storeURL).recentEvents().first)
        XCTAssertEqual(event.typedSignal, signal)
        XCTAssertEqual(event.presentation(localization: localization).title, english.title)
        XCTAssertEqual(event.presentation(localization: localization).details, english.details)

        localization.language = .ja
        let japanese = signal.descriptor(localization: localization)
        XCTAssertEqual(event.presentation(localization: localization).title, japanese.title)
        XCTAssertEqual(event.presentation(localization: localization).details, japanese.details)
        XCTAssertNotEqual(japanese.title, english.title)
    }

    func testLegacyLocalizedEventStillDecodesAndKeepsItsLiteralFallback() throws {
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000002","timestamp":0,"category":"general","title":"Legacy title","details":"Legacy details","action":"none"}]
        """
        try Data(legacy.utf8).write(to: storeURL)
        let event = try XCTUnwrap(ActivityHistoryStore(fileURL: storeURL).recentEvents().first)
        let localization = LocalizationManager()
        localization.language = .ja

        XCTAssertNil(event.typedSignal)
        XCTAssertEqual(event.presentation(localization: localization).title, "Legacy title")
        XCTAssertEqual(event.presentation(localization: localization).details, "Legacy details")
    }

    func testLegacyAndTypedRowsCoexistAcrossTheVersionedMigration() throws {
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000003","timestamp":0,"category":"general","title":"Literal legacy title","details":"Literal legacy details","action":"none"}]
        """
        try Data(legacy.utf8).write(to: storeURL)
        let localization = LocalizationManager()
        localization.language = .en
        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertEqual(store.record(.aiFailed, localization: localization), .persisted)

        localization.language = .ja
        let reloaded = ActivityHistoryStore(fileURL: storeURL).recentEvents()
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded[0].typedSignal, .aiFailed)
        XCTAssertEqual(
            reloaded[0].presentation(localization: localization).title,
            localization.s("activity.ai.failed.title")
        )
        XCTAssertNil(reloaded[1].typedSignal)
        XCTAssertEqual(
            reloaded[1].presentation(localization: localization),
            .init(title: "Literal legacy title", details: "Literal legacy details")
        )

        let encoded = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertTrue(encoded.contains("\"contentVersion\":1"))
        XCTAssertTrue(encoded.contains("Literal legacy title"))
    }

    func testTypedEventsRemainBoundedAndBatchCopyPreservesTheirPayload() throws {
        let localization = LocalizationManager()
        localization.language = .en
        let store = ActivityHistoryStore(fileURL: storeURL)

        for status in 0..<35 {
            XCTAssertEqual(
                store.record(.hotkeyRegistrationFailed(status: Int32(status)), localization: localization),
                .persisted
            )
        }

        let bounded = ActivityHistoryStore(fileURL: storeURL).recentEvents(limit: 100)
        XCTAssertEqual(bounded.count, ActivityHistoryStore.maxEvents)
        XCTAssertTrue(bounded.allSatisfy { $0.typedSignal != nil })

        let batchURL = tempDir.appendingPathComponent("activity-batch.json")
        let batchStore = ActivityHistoryStore(fileURL: batchURL)
        XCTAssertEqual(batchStore.recordBatch([try XCTUnwrap(bounded.first)]), .persisted)
        XCTAssertEqual(
            ActivityHistoryStore(fileURL: batchURL).recentEvents().first?.typedSignal,
            bounded.first?.typedSignal
        )
    }

    func testDeduplicationKeyReplacesARepeatedStateInsteadOfFloodingTheRing() {
        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertEqual(store.record(
            category: .secureInput,
            title: "Secure Input active",
            details: "Expansion is paused while this field is protected.",
            deduplicationKey: "secure-input"
        ), .persisted)
        XCTAssertEqual(store.record(
            category: .secureInput,
            title: "Secure Input cleared",
            details: "Expansion resumed.",
            deduplicationKey: "secure-input"
        ), .persisted)

        let events = store.recentEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].title, "Secure Input cleared")
        XCTAssertEqual(events[0].deduplicationKey, "secure-input")
    }

    func testRecordBatchPreservesNewestFirstOrderAndDeduplicatesExistingRows() {
        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertEqual(store.record(
            category: .voice,
            title: "stale recovery",
            details: "old",
            action: .reviewRecoveredVoice,
            deduplicationKey: "voice-recovery-a",
            referenceID: "a"
        ), .persisted)
        XCTAssertEqual(store.record(
            category: .general,
            title: "existing activity",
            details: "keep"
        ), .persisted)

        let newest = ActivityHistoryStore.ActivityEvent(
            timestamp: Date(timeIntervalSince1970: 20),
            category: .voice,
            title: "newest recovery",
            details: "new",
            action: .reviewRecoveredVoice,
            deduplicationKey: "voice-recovery-b",
            referenceID: "b"
        )
        let olderReplacement = ActivityHistoryStore.ActivityEvent(
            timestamp: Date(timeIntervalSince1970: 10),
            category: .voice,
            title: "updated recovery",
            details: "updated",
            action: .reviewRecoveredVoice,
            deduplicationKey: "voice-recovery-a",
            referenceID: "a"
        )

        XCTAssertEqual(store.recordBatch([newest, olderReplacement]), .persisted)

        let events = store.recentEvents()
        XCTAssertEqual(events.map(\.title), [
            "newest recovery",
            "updated recovery",
            "existing activity",
        ])
        XCTAssertEqual(events.filter { $0.deduplicationKey == "voice-recovery-a" }.count, 1)
        XCTAssertEqual(ActivityHistoryStore(fileURL: storeURL).recentEvents(), events)
    }

    func testPersistenceFailureIsExplicitAndDoesNotPublishAnUndurableEvent() throws {
        let blockingFile = tempDir.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)
        let store = ActivityHistoryStore(fileURL: blockingFile.appendingPathComponent("history.json"))

        let result = store.record(category: .general, title: "Must persist", details: "state")

        guard case .persistenceFailed(let kind) = result else {
            return XCTFail("Expected an explicit persistence failure, got \(result)")
        }
        XCTAssertFalse(kind.isEmpty)
        XCTAssertTrue(store.recentEvents().isEmpty)
        XCTAssertFalse(store.persistenceHealth.isHealthy)
    }

    func testPersistenceFailureDiagnosticLabelCannotExposeTheUnderlyingErrorMetadata() {
        let sentinel = "/Users/example/private/activity-history.json"
        let result = ActivityHistoryStore.MutationResult.persistenceFailed(sentinel)

        XCTAssertEqual(result.diagnosticLabel, "persistence_failed")
        XCTAssertFalse(result.diagnosticLabel.contains(sentinel))
    }

    func testClearFailureRetainsTheVisibleHistory() throws {
        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertEqual(store.record(category: .general, title: "Keep me", details: "state"), .persisted)
        try FileManager.default.removeItem(at: storeURL)
        try FileManager.default.removeItem(at: tempDir)
        try Data("block".utf8).write(to: tempDir)

        guard case .persistenceFailed = store.clear() else {
            return XCTFail("Clear must expose the failed durable write")
        }
        XCTAssertEqual(store.recentEvents().map(\.title), ["Keep me"])
    }

    func testLegacyRecoveredTranscriptIsScrubbedFromDiskOnLoad() throws {
        let secret = "dictated password sentinel 4d4930"
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","timestamp":0,"category":"voice","title":"Recovered dictation","details":"\(secret)","action":"none"}]
        """
        try Data(legacy.utf8).write(to: storeURL)

        let store = ActivityHistoryStore(fileURL: storeURL)

        XCTAssertTrue(store.recentEvents().isEmpty)
        let rewritten = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertFalse(rewritten.contains(secret))
    }

    func testOversizedHistoryIsRejectedBeforeDecodeWithDistinctHealth() throws {
        let oversized = Data(
            repeating: 0x20,
            count: ActivityHistoryStore.maximumPersistedBytes + 1
        )
        try oversized.write(to: storeURL)

        let store = ActivityHistoryStore(fileURL: storeURL)

        XCTAssertTrue(store.recentEvents().isEmpty)
        XCTAssertEqual(
            store.persistenceHealth.lastFailureKind,
            ActivityHistoryStore.PersistenceFailureKind.fileTooLarge.rawValue
        )
    }

    func testMalformedBoundedHistoryHasDifferentHealthFromOversize() throws {
        try Data("[{not-json]".utf8).write(to: storeURL)

        let store = ActivityHistoryStore(fileURL: storeURL)

        XCTAssertTrue(store.recentEvents().isEmpty)
        XCTAssertEqual(
            store.persistenceHealth.lastFailureKind,
            ActivityHistoryStore.PersistenceFailureKind.invalidContent.rawValue
        )
    }

    func testClearRepairsUnreadableHistoryWithoutRetainingFailureState() throws {
        try Data("[{not-json]".utf8).write(to: storeURL)
        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertFalse(store.persistenceHealth.isHealthy)

        XCTAssertEqual(store.clear(), .persisted)

        XCTAssertTrue(store.persistenceHealth.isHealthy)
        XCTAssertTrue(store.recentEvents().isEmpty)
        XCTAssertTrue(ActivityHistoryStore(fileURL: storeURL).persistenceHealth.isHealthy)
    }

    func testOversizedLegacyCopyAndOpaqueMetadataNeverReachPresentation() throws {
        let title = String(
            repeating: "T",
            count: ActivityHistoryStore.maximumLegacyTitleCharacters + 1
        )
        let details = String(
            repeating: "D",
            count: ActivityHistoryStore.maximumLegacyDetailsCharacters + 1
        )
        let opaque = String(
            repeating: "K",
            count: ActivityHistoryStore.maximumOpaqueIdentifierCharacters + 1
        )
        let object: [[String: Any]] = [[
            "id": "00000000-0000-0000-0000-000000000004",
            "timestamp": 0,
            "category": "general",
            "title": title,
            "details": details,
            "action": "none",
            "deduplicationKey": opaque,
            "referenceID": opaque,
        ]]
        try JSONSerialization.data(withJSONObject: object).write(to: storeURL)

        let store = ActivityHistoryStore(fileURL: storeURL)

        XCTAssertTrue(store.recentEvents().isEmpty)
        XCTAssertEqual(
            store.persistenceHealth.lastFailureKind,
            ActivityHistoryStore.PersistenceFailureKind.invalidContent.rawValue
        )
    }

    func testPublicLegacyBoundaryClampsEveryFreeFormFieldBeforePersistence() throws {
        let title = String(
            repeating: "T",
            count: ActivityHistoryStore.maximumLegacyTitleCharacters + 50
        )
        let details = String(
            repeating: "D",
            count: ActivityHistoryStore.maximumLegacyDetailsCharacters + 50
        )
        let opaque = String(
            repeating: "K",
            count: ActivityHistoryStore.maximumOpaqueIdentifierCharacters + 50
        )
        let store = ActivityHistoryStore(fileURL: storeURL)

        XCTAssertEqual(store.record(
            category: .general,
            title: title,
            details: details,
            deduplicationKey: opaque,
            referenceID: opaque
        ), .persisted)

        let event = try XCTUnwrap(store.recentEvents().first)
        XCTAssertEqual(event.title.count, ActivityHistoryStore.maximumLegacyTitleCharacters)
        XCTAssertEqual(event.details.count, ActivityHistoryStore.maximumLegacyDetailsCharacters)
        XCTAssertEqual(
            event.deduplicationKey?.count,
            ActivityHistoryStore.maximumOpaqueIdentifierCharacters
        )
        XCTAssertEqual(
            event.referenceID?.count,
            ActivityHistoryStore.maximumOpaqueIdentifierCharacters
        )
        XCTAssertLessThanOrEqual(
            try Data(contentsOf: storeURL).count,
            ActivityHistoryStore.maximumPersistedBytes
        )
    }

    func testLoaderMaterializesOnlyTheRetainedProjectionAndRewritesTheTail() throws {
        let valid = (0..<ActivityHistoryStore.maxEvents).map { index in
            let suffix = String(format: "%012d", index + 10)
            return """
            {"id":"00000000-0000-0000-0000-\(suffix)","timestamp":\(index),"category":"general","title":"Event \(index)","details":"Details \(index)","action":"none"}
            """
        }
        // This schema-invalid row would reject the entire file if the loader decoded the full
        // array before taking its prefix. It is outside the persisted ring and must never be
        // materialized or rendered.
        let invalidTail = """
        {"id":"not-a-uuid","timestamp":999,"category":"general","title":"tail","action":"none"}
        """
        try Data(("[" + (valid + [invalidTail]).joined(separator: ",") + "]").utf8)
            .write(to: storeURL)

        let store = ActivityHistoryStore(fileURL: storeURL)

        XCTAssertEqual(store.recentEvents(limit: 100).count, ActivityHistoryStore.maxEvents)
        XCTAssertTrue(store.persistenceHealth.isHealthy)
        let canonical = try JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [Any]
        XCTAssertEqual(canonical?.count, ActivityHistoryStore.maxEvents)
    }
}
