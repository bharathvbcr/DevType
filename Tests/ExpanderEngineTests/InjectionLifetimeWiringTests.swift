import Foundation
import XCTest

@testable import ExpanderEngine

/// The owner of "which injection is the live one" is the pipeline's ledger. A new claim and the
/// engine stopping both cancel the one operation it holds, so neither can leave a second running.
/// Driven on a real engine with its own pipeline, not by reading the source for the call.
final class InjectionLifetimeWiringTests: TapEventTestCase {
    private func isCurrent(_ claim: (operation: InjectCompletionGuard, revision: UInt64)) -> Bool {
        pipeline.operationIsCurrentForTesting(claim.operation, revision: claim.revision)
    }

    func testAClaimCancelsTheOperationItSupersedes() {
        let first = pipeline.claimOperationForTesting()
        XCTAssertTrue(isCurrent(first))
        let second = pipeline.claimOperationForTesting()
        XCTAssertFalse(isCurrent(first), "two operations must never both be live")
        XCTAssertEqual(first.operation.continuationBlock(), .cancelled,
                       "a superseded operation already queued or scheduled must stop itself")
        XCTAssertTrue(isCurrent(second))
    }

    func testStoppingTheEngineCancelsTheOperationInFlight() {
        let claim = pipeline.claimOperationForTesting()
        XCTAssertTrue(isCurrent(claim))
        engine.stop()
        XCTAssertFalse(isCurrent(claim), "stop() must reach the same ledger a claim does")
        XCTAssertEqual(claim.operation.continuationBlock(), .cancelled)
    }

    /// The undo record is of the app the user was in: switching apps drops it, on the pipeline this
    /// engine drives.
    func testAnAppSwitchDropsTheUndoRecordOfThePipelineTheEngineDrives() {
        pipeline.recordUndoExpansion(.init(
            erasePlan: ErasePlan(text: "ab"), injectedText: "expanded", triggerText: "abc", bundleID: "test.editor"
        ), target: .init(pid: 735, element: nil, range: nil))
        XCTAssertNotNil(pipeline.lastExpansion)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        XCTAssertNil(pipeline.lastExpansion)
    }

    func testCancellingTheCurrentInjectionCancelsTheOperationInFlight() {
        let claim = pipeline.claimOperationForTesting()
        pipeline.cancelCurrentInjection()
        XCTAssertFalse(isCurrent(claim))
        XCTAssertEqual(claim.operation.continuationBlock(), .cancelled)
    }
}
