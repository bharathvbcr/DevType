import Foundation
import XCTest

final class InjectionLifetimeWiringTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/ExpanderEngine/Engine/\(name).swift"), encoding: .utf8)
    }

    func testQueuedOperationsAndEngineStopUseTheSameCancellationOwner() throws {
        let pipeline = try source("TextInjectionPipeline")
        XCTAssertTrue(pipeline.contains("activeOperation?.cancel()"))
        XCTAssertTrue(pipeline.contains("let completionGuard = operation"))
        XCTAssertTrue(try source("EventTapEngine").contains("TextInjectionPipeline.shared.cancelCurrentInjection()"))
    }

    func testEmptyEraseCannotBypassContinuationAndDelayedCursorMustCheckIt() throws {
        let pipeline = try source("TextInjectionPipeline")
        XCTAssertFalse(pipeline.contains("erasePlan.isEmpty || self.eraseContextIsCurrent"))
        XCTAssertTrue(pipeline.contains("sendLeftArrowsAsync(count: arrowCount, shouldContinue: shouldContinue"))
        XCTAssertTrue(pipeline.contains("canContinue(context, observationOnly: true)"))
    }
}
