import Foundation
import XCTest
@testable import ExpanderEngine

final class ActivityHistoryStoreStressTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("activity-stress.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testHighConcurrencyInterleavedReadWriteClear() {
        let store = ActivityHistoryStore(fileURL: storeURL)
        let queue = DispatchQueue(label: "test.stress.concurrent", attributes: .concurrent)
        let iterations = 100
        let group = DispatchGroup()

        for i in 0..<iterations {
            group.enter()
            queue.async {
                switch i % 5 {
                case 0:
                    _ = store.record(
                        category: .expansion,
                        title: "Event \(i)",
                        details: "Details \(i)"
                    )
                case 1:
                    _ = store.recentEvents(limit: 10)
                case 2:
                    let event = ActivityHistoryStore.ActivityEvent(
                        category: .ai,
                        title: "Batch \(i)",
                        details: "Batch details \(i)",
                        deduplicationKey: "key-\(i % 3)"
                    )
                    _ = store.recordBatch([event])
                case 3:
                    _ = store.persistenceHealth
                case 4:
                    if i == 50 {
                        _ = store.clear()
                    }
                default:
                    break
                }
                group.leave()
            }
        }

        let waitResult = group.wait(timeout: .now() + 10.0)
        XCTAssertEqual(waitResult, .success, "Concurrent operations should not deadlock")

        let events = store.recentEvents(limit: 50)
        XCTAssertLessThanOrEqual(events.count, ActivityHistoryStore.maxEvents)
    }

    func testRingBufferRolloverBoundaryUnderRapidMutation() {
        let store = ActivityHistoryStore(fileURL: storeURL)
        let total = 300

        for i in 0..<total {
            _ = store.record(
                category: .general,
                title: "Sequential Event \(i)",
                details: "Details \(i)"
            )
        }

        let events = store.recentEvents(limit: 100)
        XCTAssertEqual(events.count, ActivityHistoryStore.maxEvents)
        XCTAssertEqual(events.first?.title, "Sequential Event \(total - 1)")
        XCTAssertEqual(events.last?.title, "Sequential Event \(total - ActivityHistoryStore.maxEvents)")
    }

    func testCorruptedFileDetectionAndCleanRecovery() throws {
        // 1. Write corrupted content to the file
        let corruptedData = "{\"invalid\": [not valid json".data(using: .utf8)!
        try corruptedData.write(to: storeURL, options: .atomic)

        // 2. Initializing store with corrupted file detects invalid content
        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertFalse(store.persistenceHealth.isHealthy)
        XCTAssertEqual(store.persistenceHealth.lastFailureKind, ActivityHistoryStore.PersistenceFailureKind.invalidContent.rawValue)
        XCTAssertTrue(store.recentEvents().isEmpty)

        // 3. Calling clear() resets the file and restores health
        let clearResult = store.clear()
        XCTAssertEqual(clearResult, .persisted)
        XCTAssertTrue(store.persistenceHealth.isHealthy)

        // 4. Subsequent writes succeed
        let recordResult = store.record(category: .expansion, title: "Recovered", details: "Works")
        XCTAssertEqual(recordResult, .persisted)
        XCTAssertEqual(store.recentEvents().count, 1)
        XCTAssertEqual(store.recentEvents().first?.title, "Recovered")
    }

    func testOversizedPayloadClampingAndSafety() {
        let store = ActivityHistoryStore(fileURL: storeURL)
        let hugeTitle = String(repeating: "A", count: 20_000)
        let hugeDetails = String(repeating: "B", count: 50_000)
        let hugeKey = String(repeating: "K", count: 5_000)
        let hugeRef = String(repeating: "R", count: 5_000)

        let result = store.record(
            category: .library,
            title: hugeTitle,
            details: hugeDetails,
            deduplicationKey: hugeKey,
            referenceID: hugeRef
        )

        XCTAssertEqual(result, .persisted)
        let loaded = store.recentEvents().first
        XCTAssertNotNil(loaded)
        XCTAssertLessThanOrEqual(loaded?.title.count ?? 0, ActivityHistoryStore.maximumLegacyTitleCharacters)
        XCTAssertLessThanOrEqual(loaded?.details.count ?? 0, ActivityHistoryStore.maximumLegacyDetailsCharacters)
        XCTAssertLessThanOrEqual(loaded?.deduplicationKey?.count ?? 0, ActivityHistoryStore.maximumOpaqueIdentifierCharacters)
        XCTAssertLessThanOrEqual(loaded?.referenceID?.count ?? 0, ActivityHistoryStore.maximumOpaqueIdentifierCharacters)
    }

    func testConcurrentDeduplicationPreservesSingleRow() {
        let store = ActivityHistoryStore(fileURL: storeURL)
        let sharedKey = "dedup.key.concurrent"
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.dedup.concurrent", attributes: .concurrent)

        for i in 0..<30 {
            group.enter()
            queue.async {
                _ = store.record(
                    category: .hotkey,
                    title: "Conflict \(i)",
                    details: "Details \(i)",
                    deduplicationKey: sharedKey
                )
                group.leave()
            }
        }

        let waitResult = group.wait(timeout: .now() + 10.0)
        XCTAssertEqual(waitResult, .success)

        let events = store.recentEvents()
        let matching = events.filter { $0.deduplicationKey == sharedKey }
        XCTAssertEqual(matching.count, 1, "Concurrent writes with identical deduplicationKey must leave exactly 1 row")
    }
}
