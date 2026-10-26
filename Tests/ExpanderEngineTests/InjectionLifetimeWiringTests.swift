import Foundation
import XCTest
import SourceTreeTestSupport

@testable import ExpanderEngine

/// The owner of "which injection is the live one" is the pipeline's ledger. A new claim and the
/// engine stopping both cancel the one operation it holds, so neither can leave a second running.
/// Driven on a real engine with its own pipeline, not by reading the source for the call.
final class InjectionLifetimeWiringTests: TapEventTestCase {
    private func source(_ name: String) throws -> String {
        return try SourceTree.text("Sources/ExpanderEngine/Engine/\(name).swift")
    }

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

    func testCancellingTheCurrentInjectionCancelsTheOperationInFlight() {
        let claim = pipeline.claimOperationForTesting()
        pipeline.cancelCurrentInjection()
        XCTAssertFalse(isCurrent(claim))
        XCTAssertEqual(claim.operation.continuationBlock(), .cancelled)
    }

    func testEmptyEraseCannotBypassContinuationAndDelayedCursorMustCheckIt() throws {
        let pipeline = try source("TextInjectionPipeline")
        XCTAssertFalse(pipeline.contains("erasePlan.isEmpty || self.eraseContextIsCurrent"))
        XCTAssertTrue(pipeline.contains("sendLeftArrowsAsync(count: arrowCount, shouldContinue: shouldContinue"))
        // The deferred re-verify is read-only, so it keeps only the operation half of the
        // continue-check; the target half moved into the verifier, which accepts a replaced node
        // only when it vouches for it and fails closed as `.focusReplaced` otherwise.
        let reverify = try SourceTree.functionBody("func scheduleDeferredPasteReverify(", in: pipeline)
        XCTAssertTrue(reverify.contains(
            "guard self.operationStateIsCurrent(\n                context.operation, revision: context.inputRevision, observationOnly: true\n            ) else { return }"
        ))
        XCTAssertTrue(reverify.contains("vouchingReplacement: true"))
        XCTAssertFalse(reverify.contains("recordDeliveryConfirmed"), "a late confirmation must not mint read proof")
    }
}
