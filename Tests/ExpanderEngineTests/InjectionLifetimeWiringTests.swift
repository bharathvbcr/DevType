import Foundation
import XCTest
import SourceTreeTestSupport

final class InjectionLifetimeWiringTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        return try SourceTree.text("Sources/ExpanderEngine/Engine/\(name).swift")
    }

    func testQueuedOperationsAndEngineStopUseTheSameCancellationOwner() throws {
        let pipeline = try source("TextInjectionPipeline")
        // The owner is the ledger: claiming a new operation and stopping the engine both cancel
        // the one `activeOperation` it holds, so neither path can leave a second one running.
        let ledger = try source("ExpansionLedger")
        XCTAssertEqual(ledger.components(separatedBy: "activeOperation?.cancel()").count - 1, 2,
                       "claim and cancelCurrent must both cancel the ledger's current operation")
        XCTAssertTrue(pipeline.contains("let revision = ledger.claim(operation, consumingUndo: purpose.consumesUndo)"))
        XCTAssertTrue(pipeline.contains("ledger.cancelCurrent()"))
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
