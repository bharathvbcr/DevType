import XCTest
import SourceTreeTestSupport
@testable import ExpanderEngine

final class SnippetSnapshotThreadTests: XCTestCase {
    func testApplySnippetSnapshotLeavesTheMainThread() {
        XCTAssertTrue(Thread.isMainThread, "this test proves the main-thread hop")
        let engine = EventTapEngine()
        let snippet = SnippetModel(title: "t", triggerKeyword: ";t", replacementText: "body")
        let built = expectation(description: "snapshot built")
        engine.applySnippetSnapshot([snippet]) { built.fulfill() }
        wait(for: [built], timeout: 2)
        XCTAssertFalse(engine.lastSnippetSnapshotBuiltOnMain)
        XCTAssertEqual(engine.matchSnapshot.snippets.count, 1)
        XCTAssertEqual(engine.matchSnapshot.snippets.first?.triggerKeyword, ";t")
    }

    func testSnippetSetterStaysSynchronous() {
        let engine = EventTapEngine()
        engine.snippets = [SnippetModel(title: "t", triggerKeyword: ";sync", replacementText: "body")]
        XCTAssertEqual(engine.matchSnapshot.snippets.first?.triggerKeyword, ";sync")
    }
}

final class PermissionPollCadenceTests: XCTestCase {
    func testPollBacksOffWhileFullyCapable() {
        let observer = PermissionObserver()
        observer.start { _ in }
        defer { observer.stop() }

        observer.refreshNow(with: PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true))
        XCTAssertEqual(observer.currentPollInterval, PermissionObserver.capablePollInterval)

        observer.refreshNow(with: PermissionSnapshot(canListenTap: false, canUseAX: true, canPostEvents: true))
        XCTAssertEqual(observer.currentPollInterval, PermissionObserver.pollInterval)

        observer.refreshNow(with: PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true))
        XCTAssertEqual(observer.currentPollInterval, PermissionObserver.capablePollInterval)
    }
}

final class ActivityPublishThreadTests: XCTestCase {
    func testRecordOnThePersistQueueIsOffMain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-thread-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityHistoryStore(fileURL: directory.appendingPathComponent("activity.json"))
        let recorded = expectation(description: "recorded")
        ActivityHistoryStore.persistQueue.async {
            _ = store.record(.importFailed)
            XCTAssertFalse(store.lastPersistWasOnMain)
            recorded.fulfill()
        }
        wait(for: [recorded], timeout: 5)

        let source = try SourceTree.text("Sources/ExpanderEngine/Models/ActivityHistoryStore.swift")
        let range = try XCTUnwrap(source.range(of: "public static func publish"))
        let body = String(source[range.lowerBound...].prefix(400))
        XCTAssertTrue(body.contains("persistQueue.async"))
        XCTAssertFalse(body.contains("DispatchQueue.main.async"))
    }
}

final class HotPathStructureTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        try SourceTree.text(relative)
    }

    func testKeyPathSkipsLayoutWorkWhenPhysicalFallbackIsOff() throws {
        let text = try source("Sources/ExpanderEngine/Engine/EventTapEngine.swift")
        XCTAssertTrue(text.contains("layoutBuffer.recordKeystroke"))
        XCTAssertTrue(text.contains("LayoutBuffer.idle"))
        XCTAssertFalse(text.contains("layoutBuffer.deleteLast()"))
        XCTAssertFalse(text.contains("layoutBuffer.appendLiteral"))
    }

    func testHealthMonitorSchedulesWithLeeway() throws {
        let text = try source("Sources/ExpanderEngine/Engine/EventTapEngine.swift")
        XCTAssertTrue(text.contains("leeway: EventTapEngine.healthCheckLeeway"))
        XCTAssertEqual(EventTapEngine.healthCheckLeeway, .milliseconds(500))
    }
}
