import Carbon.HIToolbox
import SourceTreeTestSupport
import XCTest
@testable import ExpanderEngine

/// Holding the chord that accepted an AI result (Return in the preview panel) autorepeats it into
/// the frontmost app while the result is delivered. Every real key moves the input revision, so the
/// repeats aborted the replace confirm as `.focusMoved` — the result was kept on the clipboard
/// instead of replacing the selection the user had just accepted it for.
///
/// Only the chord that began *this* delivery, and only its autorepeat, is the same press: the
/// panel consumed the press itself, so the tap swallows the repeat rather than let it reach the
/// field uncounted. A fresh press, any other key, other modifiers, an earlier chord, or the same
/// key once the delivery is over is real input and moves the revision as before.
final class TapAcceptChordRepeatTests: TapEventTestCase {

    private var claimed: (operation: InjectCompletionGuard, revision: UInt64)!
    private var suspension: EventTapEngine.MatchingSuspension!

    private let acceptReturn = DeliveryChord(keyCode: Int64(kVK_Return), flags: [])

    override func setUp() {
        super.setUp()
        // The AI delivery suspends matching for its whole length, which is why every key takes a
        // bypass branch that counts it.
        suspension = engine.suspendMatching(reason: "test")
    }

    override func tearDown() {
        suspension.release()
        TextInjectionPipeline.shared.cancelCurrentInjection()
        claimed = nil
        super.tearDown()
    }

    private func claimDelivery(acceptedBy chord: DeliveryChord?) {
        if let chord { TextInjectionPipeline.shared.noteAcceptChord(chord) }
        claimed = TextInjectionPipeline.shared.claimOperationForTesting()
    }

    /// Whether the tap handed the key on. The returned `Unmanaged<CGEvent>` points at an event the
    /// harness has already released, so only its nil-ness is read, never the event.
    private func passesThrough(
        _ text: String, keyCode: Int64, flags: CGEventFlags = [], autorepeat: Bool
    ) -> Bool {
        key(text, keyCode: keyCode, flags: flags, autorepeat: autorepeat) != nil
    }

    private var stillCurrent: Bool {
        TextInjectionPipeline.shared.operationIsCurrentForTesting(claimed.operation, revision: claimed.revision)
    }

    func testTheRepeatOfTheChordThatStartedTheDeliveryDoesNotAbortIt() {
        claimDelivery(acceptedBy: acceptReturn)
        XCTAssertFalse(
            passesThrough("\r", keyCode: Int64(kVK_Return), autorepeat: true),
            "the repeat is the same press the panel consumed; it must not reach the field"
        )
        XCTAssertTrue(stillCurrent, "a repeat of the accept chord is not user input")
        XCTAssertFalse(passesThrough("\r", keyCode: Int64(kVK_Return), autorepeat: true))
        XCTAssertTrue(stillCurrent)
    }

    func testAFreshPressOfTheSameChordIsRealInput() {
        claimDelivery(acceptedBy: acceptReturn)
        XCTAssertTrue(
            passesThrough("\r", keyCode: Int64(kVK_Return), autorepeat: false), "a new press is passed to the field"
        )
        XCTAssertFalse(stillCurrent)
    }

    func testTheRepeatOfAnyOtherKeyIsRealInput() {
        claimDelivery(acceptedBy: acceptReturn)
        XCTAssertTrue(passesThrough("l", keyCode: Int64(kVK_ANSI_L), autorepeat: true))
        XCTAssertFalse(stillCurrent)
    }

    func testTheRepeatOfTheSameKeyWithOtherModifiersIsRealInput() {
        claimDelivery(acceptedBy: acceptReturn)
        XCTAssertTrue(passesThrough("\r", keyCode: Int64(kVK_Return), flags: .maskAlternate, autorepeat: true))
        XCTAssertFalse(stillCurrent)
    }

    func testAChordNotNotedForThisDeliveryIsRealInput() {
        claimDelivery(acceptedBy: nil)
        XCTAssertTrue(passesThrough("\r", keyCode: Int64(kVK_Return), autorepeat: true))
        XCTAssertFalse(stillCurrent, "nothing says this repeat belongs to the delivery: the old behaviour stands")
    }

    func testTheChordIsRealInputAgainOnceTheDeliveryIsOver() {
        claimDelivery(acceptedBy: acceptReturn)
        _ = claimed.operation.markCompleted(.succeeded)
        XCTAssertTrue(passesThrough("\r", keyCode: Int64(kVK_Return), autorepeat: true))
        XCTAssertFalse(stillCurrent)
    }

    func testANewerDeliveryDoesNotInheritAnEarlierChord() {
        claimDelivery(acceptedBy: acceptReturn)
        claimDelivery(acceptedBy: nil)
        XCTAssertTrue(passesThrough("\r", keyCode: Int64(kVK_Return), autorepeat: true))
        XCTAssertFalse(stillCurrent)
    }

    /// The panel is the one place the accept chord is identified: both chords that accept a result
    /// note themselves before the replace they start is handed to the pipeline, and the tap asks the
    /// pipeline ahead of every bypass branch.
    func testThePanelNotesBothAcceptChordsAheadOfTheReplaceTheyStart() throws {
        let panel = try SourceTree.text("Sources/DevTypeAppCore/AIPreviewPanel.swift")
        for call in ["self.replaceTapped()", "self.replaceAndCopyTapped()"] {
            let tapped = try XCTUnwrap(panel.range(of: call, options: .backwards))
            let noted = try XCTUnwrap(panel.range(of: "noteAcceptChord(", options: .backwards, range: panel.startIndex..<tapped.lowerBound))
            XCTAssertLessThan(
                panel.distance(from: noted.lowerBound, to: tapped.lowerBound), 250, "\(call) is preceded by its note"
            )
        }
        let tap = try SourceTree.text("Sources/ExpanderEngine/Engine/EventTapEngine+TapCallback.swift")
        let swallow = try XCTUnwrap(tap.range(of: "isRepeatOfDeliveryChord("))
        let bypass = try XCTUnwrap(tap.range(of: "guard enabled && !secureFlag && !suspended else {"))
        XCTAssertLessThan(swallow.lowerBound, bypass.lowerBound)
    }

    /// A chord that led to no delivery must not attach to an unrelated one claimed much later.
    func testAStaleChordIsNotAttachedToALaterDelivery() {
        let ledger = TextInjectionPipeline.ExpansionLedger(defaults: UserDefaults(suiteName: "TapAcceptChordRepeatTests")!)
        let noted = Date()
        ledger.noteAcceptChord(acceptReturn, now: noted)
        let operation = InjectCompletionGuard()
        _ = ledger.claim(operation, consumingUndo: false, now: noted.addingTimeInterval(TextInjectionPipeline.ExpansionLedger.acceptChordWindow + 1))
        XCTAssertFalse(ledger.isDeliveryChord(acceptReturn))

        ledger.noteAcceptChord(acceptReturn, now: noted)
        let fresh = InjectCompletionGuard()
        _ = ledger.claim(fresh, consumingUndo: false, now: noted.addingTimeInterval(0.5))
        XCTAssertTrue(ledger.isDeliveryChord(acceptReturn))
    }
}
