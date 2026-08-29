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

        store.record(
            category: .expansion,
            title: "Expansion Failed",
            details: "Could not expand ;test",
            action: .openPermissionRecovery
        )

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
}
