import AppKit
import ApplicationServices
import CoreGraphics
import XCTest
@testable import ExpanderEngine

// MARK: - Nothing confirmed an AI replace after the paste
//
// Field report, Safari build 389: a proofread of a 67-character selection was refused because the
// paste target resolved to AXWindow. The first pass made the selection check careful. The ⌘V that
// follows it was still fire-and-forget: `injectSecureClipboardPasteOnMain` reported
// `postedUnverified` whatever happened, so a paste that landed nowhere (focus slipped back to the
// window after the confirm) lost the generated result the moment the broker restored the user's
// clipboard.
//
// The first half drives `DeliveryVerifier.readReplacementOutcome` against a scripted field; the
// second drives the real broker (private pasteboard, ⌘V recorded, never posted) and the real
// pipeline method against the same field, with the clipboard keeper recorded. Both run on the
// shared `InjectionHarness`: trust and Secure Input are the harness's to script, so no test here
// depends on the session it runs in.
final class ReplacementWitnessTests: XCTestCase {

    private let selected = "teh quick brwon fox"
    private let result = "the quick brown fox"
    private var before: String { "say: \(selected) now" }
    private var selectionLength: Int { (selected as NSString).length }

    /// A harness whose field holds `before` with the misspelt words selected.
    private func makeHarness() throws -> InjectionHarness {
        let harness = try InjectionHarness()
        harness.seed(before, caret: 5, selection: selectionLength)
        return harness
    }

    /// Taken before the paste, as the pipeline does; the page is then mutated by the caller.
    private func baseline(_ harness: InjectionHarness) -> DeliveryVerifier.FocusedTextObservation {
        harness.verifier.captureFocusedTextObservation(focus: .resolved(harness.field))!
    }

    private func reading(
        _ harness: InjectionHarness, baseline: DeliveryVerifier.FocusedTextObservation,
        mirrorTrusted: Bool = true, expected: String? = nil
    ) -> DeliveryVerifier.ReplacementOutcome {
        harness.verifier.readReplacementOutcome(
            expectedText: expected ?? result, baseline: baseline, mirrorTrusted: mirrorTrusted
        )
    }

    private func landOnField(_ harness: InjectionHarness, _ element: AXUIElement) {
        let k = harness.page.key(element)
        harness.page.values[k] = "say: \(result) now"
        harness.page.selections[k] = NSRange(location: 5 + (result as NSString).length, length: 0)
    }

    // MARK: - The reading

    func testAResultThatReplacedTheSelectionLanded() throws {
        let harness = try makeHarness()
        let base = baseline(harness)
        landOnField(harness, harness.field)
        XCTAssertEqual(reading(harness, baseline: base), .landed)
    }

    func testAResultOnAReplacedNodeOfTheSameControlLanded() throws {
        let harness = try makeHarness()
        let base = baseline(harness)
        harness.page.focused = harness.replacementNode
        landOnField(harness, harness.replacementNode)
        XCTAssertEqual(reading(harness, baseline: base), .landed)
    }

    /// The report's own shape: focus is the window, so a focus-based read has nothing to say, but
    /// the field the selection came from still answers and still holds the original.
    func testAFieldStillHoldingTheOriginalWhileFocusIsTheWindowDidNotLand() throws {
        let harness = try makeHarness()
        let base = baseline(harness)
        harness.page.focused = harness.window
        XCTAssertEqual(reading(harness, baseline: base), .notLanded)
    }

    func testAFieldStillHoldingTheOriginalWhileItIsFocusedDidNotLand() throws {
        let harness = try makeHarness()
        XCTAssertEqual(reading(harness, baseline: baseline(harness)), .notLanded)
    }

    func testAMirrorThatCannotBeTrustedNeverProvesAMiss() throws {
        let harness = try makeHarness()
        let base = baseline(harness)
        harness.page.focused = harness.window
        XCTAssertEqual(reading(harness, baseline: base, mirrorTrusted: false), .unverified)
    }

    func testAFieldThatCannotBeReadNowIsNotAMiss() throws {
        let harness = try makeHarness()
        let base = baseline(harness)
        harness.page.focused = harness.window
        harness.page.unreadable.insert(harness.page.key(harness.field))
        XCTAssertEqual(reading(harness, baseline: base), .unverified)
    }

    func testAFieldThatChangedInSomeOtherWayIsNotAMiss() throws {
        let harness = try makeHarness()
        let base = baseline(harness)
        harness.page.focused = harness.window
        harness.page.values[harness.page.key(harness.field)] = before + "!"
        XCTAssertEqual(reading(harness, baseline: base), .unverified, "the user typed — the field is no longer the one that was read")
    }

    func testAResultThatReadsLikeTheSelectionProvesNothingByLeavingTheFieldAlone() throws {
        let harness = try makeHarness()
        let base = baseline(harness)
        harness.page.focused = harness.window
        XCTAssertEqual(reading(harness, baseline: base, expected: selected), .unverified)
        XCTAssertEqual(
            reading(harness, baseline: base, expected: selected.replacingOccurrences(of: " ", with: "\u{00A0}")),
            .unverified,
            "a difference the field's own whitespace folding erases is not a difference"
        )
    }

    func testABaselineThatNeverReadTheFieldCannotJudgeAMiss() throws {
        let harness = try makeHarness()
        harness.page.values[harness.page.key(harness.field)] = nil
        let base = baseline(harness)
        harness.page.focused = harness.window
        XCTAssertEqual(reading(harness, baseline: base), .unverified)
    }

    // MARK: - The pipeline, end to end

    /// The field report's failure: ⌘V goes out, focus has slipped back to the window, nothing is
    /// pasted. Pre-fix this ended `postedUnverified` with the result nowhere.
    func testAPasteThatLandedNowhereKeepsTheResultAndSaysSo() throws {
        let harness = try makeHarness()
        harness.hostPastes = false
        harness.afterPaste = { harness in
            harness.page.focused = harness.window
            harness.targetMovedAfterPaste = true
        }
        let outcome = harness.replaceSelection(in: self, result: result)

        XCTAssertEqual(outcome, .refused(SelectionReplacementGuard.Refusal.notLanded.reason))
        XCTAssertEqual(harness.kept, [result], "the generated result is kept on the clipboard")
        XCTAssertEqual(harness.toasts, [true])
        XCTAssertEqual(harness.chords, 1, "a miss never re-pastes: a late host read would duplicate the result")
    }

    /// The miss is judged for the miss window *after* the hold answered, and the residency floor
    /// alone ended before that: the user's clipboard was back on the board while the witness was
    /// still deciding, so a host that pasted late in the window pasted the user's clipboard over
    /// the selection. The board must still hold the result when the miss is called.
    func testTheResultIsStillOnTheBoardWhenTheMissIsCalled() throws {
        let harness = try makeHarness()
        harness.hostPastes = false
        harness.afterPaste = { harness in
            harness.page.focused = harness.window
            harness.targetMovedAfterPaste = true
        }
        harness.replaceSelection(in: self, result: result)
        XCTAssertEqual(harness.kept, [result])
        XCTAssertEqual(harness.boardAtKeep, [result], "the user's clipboard came back before the verdict")
    }

    /// Once someone else owns the board — the user copied, or it was restored — a late paste
    /// would paste *that*, so the field cannot say the result never landed, and copying the
    /// result over the board would throw away what is there now.
    func testNoMissIsCalledOnceTheBoardIsNoLongerTheResult() throws {
        let harness = try makeHarness()
        harness.hostPastes = false
        harness.afterPaste = { harness in
            harness.page.focused = harness.window
            harness.targetMovedAfterPaste = true
            harness.board.clearContents()
            harness.board.setString("copied by the user meanwhile", forType: .string)
        }
        let outcome = harness.replaceSelection(in: self, result: result)
        XCTAssertEqual(outcome, .postedUnverified)
        XCTAssertEqual(harness.kept, [])
        XCTAssertEqual(harness.toasts, [])
        XCTAssertEqual(harness.board.string(forType: .string), "copied by the user meanwhile")
    }

    /// Measured from the hold's answer — where the witness's window starts — and never past the
    /// payload's hard deadline.
    func testTheAnswerHoldRunsFromTheAnswerWithinTheHardDeadline() throws {
        let held = try XCTUnwrap(PasteboardBroker.answerHoldDeadline(answeredAt: 10.35, afterAnswer: 0.6, hardDeadline: 12))
        XCTAssertEqual(held, 10.95, accuracy: 1e-9)
        let capped = try XCTUnwrap(PasteboardBroker.answerHoldDeadline(answeredAt: 11.8, afterAnswer: 0.6, hardDeadline: 12))
        XCTAssertEqual(capped, 12, accuracy: 1e-9)
        XCTAssertNil(PasteboardBroker.answerHoldDeadline(answeredAt: 10, afterAnswer: 0, hardDeadline: 12))
        XCTAssertNil(PasteboardBroker.answerHoldDeadline(answeredAt: 10, afterAnswer: .nan, hardDeadline: 12))
        XCTAssertNil(PasteboardBroker.answerHoldDeadline(answeredAt: 10, afterAnswer: -1, hardDeadline: 12))
    }

    /// The witness stops on its own clock at the window, inside the time the broker holds for it.
    func testTheWitnessWindowFitsInsideTheHoldTheBrokerKeeps() {
        XCTAssertLessThan(
            InjectTiming.replacementMissWindow,
            InjectTiming.replacementMissWindow + 2 * InjectTiming.pasteDeliverySettleDelay
        )
        XCTAssertLessThan(
            InjectTiming.pasteDeliveryHoldTimeout + InjectTiming.replacementMissWindow
                + 2 * InjectTiming.pasteDeliverySettleDelay,
            InjectTiming.unverifiedPayloadResidencyCeiling,
            "the longest hold plus the window must fit under the hard deadline"
        )
    }

    func testAKeeperThatCannotCopyIsToldToTheUser() throws {
        let harness = try makeHarness()
        harness.keepAnswer = false
        harness.hostPastes = false
        harness.afterPaste = { harness in
            harness.page.focused = harness.window
            harness.targetMovedAfterPaste = true
        }
        harness.replaceSelection(in: self, result: result)
        XCTAssertEqual(harness.toasts, [false])
    }

    /// The host pastes where focus is, over the selection: the field ends holding the result.
    func testAPasteThatLandedIsSucceededAndKeepsNothing() throws {
        let harness = try makeHarness()
        let outcome = harness.replaceSelection(in: self, result: result)
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(harness.page.value(of: harness.field), "say: \(result) now")
        XCTAssertEqual(harness.kept, [])
        XCTAssertEqual(harness.toasts, [])
    }

    /// WebKit swaps the node when the paste lands, so the strict gate sees focus move — and the
    /// result is in the field. That is a landing, not a slip.
    func testAPasteThatReplacedTheNodeUnderItIsNotCalledAMiss() throws {
        let harness = try makeHarness()
        harness.hostPastes = false
        harness.afterPaste = { harness in
            harness.page.focused = harness.replacementNode
            self.landOnField(harness, harness.replacementNode)
            harness.targetMovedAfterPaste = true
        }
        let outcome = harness.replaceSelection(in: self, result: result)
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(harness.kept, [])
    }

    /// A field AX cannot read gives no evidence either way: exactly the outcome it always had.
    func testAFieldThatCannotBeReadStaysPostedUnverified() throws {
        let harness = try makeHarness()
        harness.hostPastes = false
        harness.page.unreadable.insert(harness.page.key(harness.field))
        let outcome = harness.replaceSelection(in: self, result: result)
        XCTAssertEqual(outcome, .postedUnverified)
        XCTAssertEqual(harness.kept, [])
        XCTAssertEqual(harness.toasts, [])
    }

    /// Only a replace owes the field a read; an insert at the caret is untouched.
    func testAnInsertIsNotWatched() throws {
        let harness = try makeHarness()
        harness.hostPastes = false
        harness.afterPaste = { harness in
            harness.page.focused = harness.window
            harness.targetMovedAfterPaste = true
        }
        let outcome = harness.replaceSelection(in: self, result: result, replacesSelection: false)
        XCTAssertEqual(outcome, .postedUnverified)
        XCTAssertEqual(harness.kept, [])
    }

    /// A cancelled or superseded inject has no claim on the field, so it keeps nothing.
    func testACancelledReplaceIsNotJudged() throws {
        let harness = try makeHarness()
        var cancelled = false
        harness.hostPastes = false
        harness.afterPaste = { harness in
            harness.page.focused = harness.window
            harness.targetMovedAfterPaste = true
            cancelled = true
        }
        let outcome = harness.replaceSelection(in: self, result: result, operationStillOurs: { !cancelled })
        XCTAssertEqual(outcome, .postedUnverified)
        XCTAssertEqual(harness.kept, [])
    }

    /// ⌘V never went out (the target moved before it): the broker has restored the user's
    /// clipboard, so without the keep the result would simply be gone.
    func testAPasteThatWasNeverPostedKeepsTheResult() throws {
        let harness = try makeHarness()
        harness.brokerRefusesTarget = true
        let outcome = harness.replaceSelection(in: self, result: result)
        XCTAssertEqual(outcome, .failedSilent)
        XCTAssertEqual(harness.chords, 0)
        XCTAssertEqual(harness.kept, [result])
        XCTAssertEqual(harness.toasts, [true])
    }

    /// Secure Input is the harness's to switch on, and the replace path under it never takes the
    /// witnessed route: it leaves the payload for a manual ⌘V instead of judging the field.
    func testASecureInputSessionNeverTakesTheWitnessedRoute() throws {
        let harness = try makeHarness()
        harness.secureInput = true
        harness.hostPastes = false
        let outcome = harness.replaceSelection(in: self, result: result)
        XCTAssertEqual(outcome, .postedUnverified)
        XCTAssertEqual(harness.kept, [], "under Secure Input the payload stays on the board, not via the keeper")
    }

    func testRefusalClassifiesAndKeepsItsSentence() {
        let refusal = SelectionReplacementGuard.Refusal.notLanded
        XCTAssertFalse(refusal.reason.hasPrefix(SelectionReplacementGuard.refusalPrefix))
        let classified = InjectRefusalKind.classify(refusal.reason, path: SelectionReplacementGuard.refusalPath)
        XCTAssertEqual(classified.kind, .selectionReplaceUnconfirmed)
        XCTAssertEqual(classified.sentence, refusal.reason)
    }
}
