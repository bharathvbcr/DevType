import Carbon.HIToolbox
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

    func testCancellingTheCurrentInjectionCancelsTheOperationInFlight() {
        let claim = pipeline.claimOperationForTesting()
        pipeline.cancelCurrentInjection()
        XCTAssertFalse(isCurrent(claim))
        XCTAssertEqual(claim.operation.continuationBlock(), .cancelled)
    }
}

/// The continue-checks of an inject, driven on the shared harness: an insert that erases nothing is
/// still held to them, cursor placement checks them between arrows, and the deferred re-verify is
/// read-only — it may upgrade a recorded outcome on evidence, never mint proof a host's mirror can
/// be trusted in the hold window, and never act for an operation that has been superseded.
final class InjectionContinuationTests: XCTestCase {

    // MARK: An empty erase is not a pass

    func testAnInsertThatErasesNothingIsHeldToTheContinueCheck() throws {
        let control = try InjectionHarness()
        XCTAssertEqual(control.typeExpansion(in: self, erasing: false).text, "say: Sincerely, Slim")

        let harness = try InjectionHarness()
        // Input lands after the inject resolved focus: the very next live read finds the
        // operation stale, however little there is to erase.
        harness.onFocusRead = { harness in harness.pipeline.noteDeliveryInput() }
        let run = harness.typeExpansion(in: self, erasing: false)

        XCTAssertNotEqual(run.outcome, .succeeded, harness.timeline)
        XCTAssertEqual(harness.chords, 0, "an insert with nothing to erase still pasted over a stale operation")
        XCTAssertEqual(run.text, "say: ")
    }

    // MARK: Cursor placement

    private func arrows(_ harness: InjectionHarness) -> Int {
        harness.log.filter { $0 == .key(kVK_LeftArrow) }.count
    }

    func testCursorPlacementPostsOneArrowPerGraphemeAfterTheOffset() throws {
        let harness = try InjectionHarness()
        let run = harness.typeExpansion(in: self, cursorFromEnd: 4)
        XCTAssertEqual(run.text, "say: Sincerely, Slim")
        XCTAssertEqual(arrows(harness), 4, harness.timeline)
    }

    /// The arrows are a burst checked between pairs: when the operation stops being the user's part
    /// way through, the rest are not sent.
    func testCursorPlacementStopsWhenTheOperationMovesBetweenArrows() throws {
        let harness = try InjectionHarness()
        harness.onFocusRead = { harness in
            if harness.log.contains(.key(kVK_LeftArrow)) { harness.page.focused = harness.window }
        }
        harness.typeExpansion(in: self, cursorFromEnd: 4)
        XCTAssertEqual(arrows(harness), 1, "one arrow went before focus moved, none after: \(harness.timeline)")
    }

    // MARK: The deferred re-verify

    private func fieldKey(_ harness: InjectionHarness) -> String { harness.page.key(harness.field) }

    /// A host whose mirror cannot be read for the whole hold window, then can: the paste is
    /// recorded unverified and then upgraded by the re-verify, which reads the field after the
    /// settle. The upgrade is not proof: the mirror caught up only after the window, so its reads
    /// are still not trusted inside one.
    private func unreadableThroughTheHold(_ harness: InjectionHarness, readableAgainAfter delay: TimeInterval) {
        harness.afterPaste = { harness in
            harness.page.unreadable.insert(self.fieldKey(harness))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                harness.page.unreadable.remove(self.fieldKey(harness))
            }
        }
    }

    private func settleForTheReverify(_ harness: InjectionHarness) {
        let until = InputClock.monotonicNow() + InjectTiming.pasteReverifyDelay + 0.2
        harness.pump(in: self, timeout: 3, "the deferred re-verify") { InputClock.monotonicNow() > until }
    }

    func testALateConfirmationUpgradesTheOutcomeButMintsNoReadProof() throws {
        let harness = try InjectionHarness()
        unreadableThroughTheHold(harness, readableAgainAfter: InjectTiming.pasteDeliveryHoldTimeout + 0.1)
        let run = harness.typeExpansion(in: self)
        XCTAssertEqual(run.outcome, .postedUnverified, harness.timeline)
        XCTAssertEqual(PermissionCoordinator.shared.lastRecordedInjectOutcome, .postedUnverified)

        settleForTheReverify(harness)

        XCTAssertEqual(PermissionCoordinator.shared.lastRecordedInjectOutcome, .succeeded,
                       "the re-verify read the pasted text and upgraded the record")
        XCTAssertFalse(
            AXWriteCapabilityStore.shared.hasProvenDeliveryReads(
                bundleID: harness.frontmostBundleID ?? "", role: "AXTextArea"
            ),
            "a late confirmation must not mint read proof"
        )
    }

    /// The control for the proof above: a delivery confirmed inside the hold window *does* earn it.
    func testADeliveryConfirmedInsideTheWindowEarnsReadProof() throws {
        let harness = try InjectionHarness()
        let run = harness.typeExpansion(in: self)
        XCTAssertEqual(run.outcome, .succeeded, harness.timeline)
        XCTAssertTrue(AXWriteCapabilityStore.shared.hasProvenDeliveryReads(
            bundleID: harness.frontmostBundleID ?? "", role: "AXTextArea"
        ))
    }

    /// The re-verify is read-only and keeps only the operation half of the continue-check: an
    /// operation that was superseded before it ran has no claim on the record.
    func testASupersededOperationIsNotUpgradedByTheReverify() throws {
        let harness = try InjectionHarness()
        unreadableThroughTheHold(harness, readableAgainAfter: InjectTiming.pasteDeliveryHoldTimeout + 0.1)
        let run = harness.typeExpansion(in: self)
        XCTAssertEqual(run.outcome, .postedUnverified, harness.timeline)
        harness.pipeline.cancelCurrentInjection()

        settleForTheReverify(harness)

        XCTAssertEqual(PermissionCoordinator.shared.lastRecordedInjectOutcome, .postedUnverified)
    }

    /// A different field that happens to be focused when the re-verify reads proves nothing: the
    /// text must be in the control the paste went to, or in one the verifier vouches for.
    func testADifferentFieldNeverVerifiesThePaste() throws {
        let harness = try InjectionHarness()
        unreadableThroughTheHold(harness, readableAgainAfter: InjectTiming.pasteDeliveryHoldTimeout + 0.1)
        let elsewhereKey = harness.page.key(harness.elsewhere)
        harness.page.values[elsewhereKey] = "an unrelated field"
        harness.page.selections[elsewhereKey] = NSRange(location: 18, length: 0)
        let run = harness.typeExpansion(in: self)
        XCTAssertEqual(run.outcome, .postedUnverified, harness.timeline)
        // The user (or the page) moved on to another field and the paste's own field is gone.
        harness.page.focused = harness.elsewhere
        harness.page.values[fieldKey(harness)] = nil

        settleForTheReverify(harness)

        XCTAssertEqual(PermissionCoordinator.shared.lastRecordedInjectOutcome, .postedUnverified)
    }
}
