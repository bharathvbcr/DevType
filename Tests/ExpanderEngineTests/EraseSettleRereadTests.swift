import CoreGraphics
import SourceTreeTestSupport
import XCTest
@testable import ExpanderEngine

/// After the backspaces are all sent, a refusal means the user has lost the trigger *and* gets no
/// expansion. WebKit makes three readings in that window that are not verdicts: focus momentarily
/// nothing, focus on a container instead of the text field, and the replacement field's AX value
/// still behind the keys. `decide` refused all three on the first look. These tests pin which
/// readings earn a bounded second look and, as importantly, which never do.
final class EraseSettleRereadTests: XCTestCase {

    private let frame = CGRect(x: 10, y: 20, width: 200, height: 22)

    private func picture(_ value: String?, caret: Int? = nil) -> EraseContinuation.EraseFieldPicture {
        EraseContinuation.EraseFieldPicture(
            value: value, caretLocation: caret ?? value?.utf16.count, selectionLength: 0, frame: frame
        )
    }

    private func facts(
        mismatch: PasteboardBroker.PasteTarget.Mismatch? = .elementChanged,
        role: String? = "AXTextField",
        matched: Bool = false,
        lagging: Bool = false,
        allowsRetarget: Bool = true,
        phase: EraseContinuationPhase = .beforeInsertion
    ) -> EraseContinuationFacts {
        EraseContinuationFacts(
            phase: phase,
            revisionCurrent: true,
            continuationBlock: nil,
            secureInputBlocked: false,
            axUntrusted: false,
            mismatch: mismatch,
            allowsRetarget: allowsRetarget,
            deletionMatched: matched,
            livePrecondition: nil,
            liveRole: role,
            fieldReading: .unreadable,
            deletionLagging: lagging
        )
    }

    // MARK: - The readings that are not verdicts

    func testAFieldWhoseValueIsStillBehindTheKeysIsReadAgain() {
        let row = facts(lagging: true)
        guard case .refuse = EraseContinuation.decide(row) else {
            return XCTFail("the first look still refuses; the second look is what can clear it")
        }
        XCTAssertTrue(EraseContinuation.mayClearOnReread(row))
    }

    func testFocusMomentarilyNothingIsReadAgain() {
        XCTAssertTrue(EraseContinuation.mayClearOnReread(facts(mismatch: .focusLost, role: nil)))
    }

    func testFocusOnAContainerOrAnUnreadableRoleIsReadAgain() {
        for role: String? in ["AXWebArea", "AXGroup", "AXWindow", "AXScrollArea", nil] {
            XCTAssertTrue(EraseContinuation.mayClearOnReread(facts(role: role)), "role \(String(describing: role))")
        }
    }

    // MARK: - The readings that must stay verdicts

    func testASecureFieldIsNeverReadAgain() {
        XCTAssertFalse(EraseContinuation.mayClearOnReread(facts(role: "AXSecureTextField", lagging: true)))
    }

    func testADifferentTextFieldIsNotReadAgain() {
        XCTAssertFalse(
            EraseContinuation.mayClearOnReread(facts(role: "AXTextField", lagging: false)),
            "a text field whose value is not this field minus part of the trigger is another field"
        )
        XCTAssertFalse(EraseContinuation.mayClearOnReread(facts(role: "AXTextArea", matched: false)))
    }

    func testAMatchedDeletionIsAlreadyAVoucherAndNeedsNoSecondLook() {
        XCTAssertFalse(EraseContinuation.mayClearOnReread(facts(matched: true, lagging: true)))
    }

    func testProcessMovesCaretMovesAndArrivalsAreNeverReadAgain() {
        for mismatch: PasteboardBroker.PasteTarget.Mismatch in [
            .noCapturedProcess, .processChanged, .focusArrived, .rangeChanged,
        ] {
            XCTAssertFalse(
                EraseContinuation.mayClearOnReread(facts(mismatch: mismatch, role: "AXTextField", lagging: true)),
                "\(mismatch)"
            )
        }
        XCTAssertFalse(EraseContinuation.mayClearOnReread(facts(mismatch: nil, lagging: true)))
    }

    func testOnlyAVouchedTypedExpansionIsReadAgain() {
        for row in [
            facts(mismatch: .focusLost, role: nil, allowsRetarget: false),
            facts(lagging: true, allowsRetarget: false),
            facts(role: "AXWebArea", allowsRetarget: false),
        ] {
            XCTAssertFalse(EraseContinuation.mayClearOnReread(row))
        }
    }

    func testEveryHardStopOutranksTheSecondLook() {
        var stale = facts(mismatch: .focusLost, role: nil)
        stale.revisionCurrent = false
        XCTAssertFalse(EraseContinuation.mayClearOnReread(stale), "the user typed: never wait through that")
        var secure = facts(mismatch: .focusLost, role: nil)
        secure.secureInputBlocked = true
        XCTAssertFalse(EraseContinuation.mayClearOnReread(secure))
        var untrusted = facts(mismatch: .focusLost, role: nil)
        untrusted.axUntrusted = true
        XCTAssertFalse(EraseContinuation.mayClearOnReread(untrusted))
    }

    func testOnlyTheReadAfterTheEraseIsReadAgain() {
        XCTAssertFalse(EraseContinuation.mayClearOnReread(facts(lagging: true, phase: .beforeErase)))
        XCTAssertFalse(EraseContinuation.mayClearOnReread(facts(lagging: true, phase: .duringErase)))
    }

    // MARK: - Bound

    func testTheSecondLookIsBoundedAndTheWaitIsAboutNinetyMilliseconds() {
        XCTAssertEqual(EraseContinuation.maxSettleRereads, 3)
        XCTAssertTrue(EraseContinuation.rereadBudgetRemains(attempt: 0))
        XCTAssertTrue(EraseContinuation.rereadBudgetRemains(attempt: 2))
        XCTAssertFalse(EraseContinuation.rereadBudgetRemains(attempt: 3))
        XCTAssertFalse(EraseContinuation.rereadBudgetRemains(attempt: -1))
        XCTAssertLessThanOrEqual(
            Double(EraseContinuation.maxSettleRereads) * AXSettleRetry.settleDelay, 0.1
        )
    }

    // MARK: - Lagging

    func testPartOfTheTriggerStillInTheReplacementIsLagging() {
        let anchor = picture("hello sig")
        XCTAssertTrue(EraseContinuation.deletionIsLagging(
            anchor: anchor, live: picture("hello si"), expectedText: "sig", caseInsensitive: false
        ))
        XCTAssertTrue(EraseContinuation.deletionIsLagging(
            anchor: anchor, live: picture("hello s"), expectedText: "sig", caseInsensitive: false
        ))
        XCTAssertTrue(
            EraseContinuation.deletionIsLagging(
                anchor: anchor, live: picture("hello sig"), expectedText: "sig", caseInsensitive: false
            ),
            "no key reflected yet is the same mirror, one turn earlier"
        )
    }

    func testAFullDeletionAnUnrelatedFieldAndAMissingPictureAreNotLagging() {
        let anchor = picture("hello sig")
        XCTAssertFalse(EraseContinuation.deletionIsLagging(
            anchor: anchor, live: picture("hello "), expectedText: "sig", caseInsensitive: false
        ), "the deletion is complete: `deletionConfirms` already accepts it")
        XCTAssertFalse(EraseContinuation.deletionIsLagging(
            anchor: anchor, live: picture("another field"), expectedText: "sig", caseInsensitive: false
        ))
        XCTAssertFalse(EraseContinuation.deletionIsLagging(
            anchor: nil, live: picture("hello si"), expectedText: "sig", caseInsensitive: false
        ))
        XCTAssertFalse(EraseContinuation.deletionIsLagging(
            anchor: anchor, live: nil, expectedText: "sig", caseInsensitive: false
        ))
        XCTAssertFalse(EraseContinuation.deletionIsLagging(
            anchor: anchor, live: picture("hello si"), expectedText: nil, caseInsensitive: false
        ))
    }

    func testAnEmojiTriggerLagsByWholeGraphemes() {
        let anchor = picture("hi a😀")
        XCTAssertTrue(EraseContinuation.deletionIsLagging(
            anchor: anchor, live: picture("hi a"), expectedText: "a😀", caseInsensitive: false
        ), "one grapheme (the emoji, two UTF-16 units) is gone, the `a` is not")
    }

    // MARK: - Wiring

    func testThePipelineReReadsBeforeItRefusesAfterTheErase() throws {
        let pipeline = SourceContractTests.strippingComments(
            try SourceTree.text("Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift")
        )
        let afterErase = try SourceTree.functionBody("func afterErase(", in: pipeline)
        XCTAssertTrue(
            afterErase.contains("context.adopted.lastRefusalMayClear")
                && afterErase.contains("EraseContinuation.rereadBudgetRemains(attempt: settleAttempt)"),
            "A refusal after the erase must consult the bounded second look before it stands"
        )
        XCTAssertTrue(afterErase.contains("AXSettleRetry.settleDelay"), "The wait is the shared settle, never a sleep")
        XCTAssertFalse(afterErase.contains("Thread.sleep"), "Blocking main starves the event tap")
    }
}
