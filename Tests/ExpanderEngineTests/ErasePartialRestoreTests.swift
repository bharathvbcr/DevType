import SourceTreeTestSupport
import XCTest
@testable import ExpanderEngine

/// A backspace burst that stops part-way (a continue-check fails between two pairs) leaves the
/// head of the trigger in the field: `tri` + swallowed `g` became `tr`, and replaying the
/// swallowed key then produced `trg` — neither the trigger the user typed nor the expansion.
/// What was removed is exactly known (the last N graphemes of the plan, N = pairs authorized), so
/// it can be put back before the key is replayed.
final class ErasePartialRestoreTests: XCTestCase {

    func testTheErasedTailIsTheLastPostedGraphemesOfThePlan() {
        let plan = ErasePlan(text: "trig")
        XCTAssertEqual(plan.erasedTail(graphemes: 1)?.expectedText, "g")
        XCTAssertEqual(plan.erasedTail(graphemes: 2)?.expectedText, "ig")
        XCTAssertEqual(plan.erasedTail(graphemes: 4)?.expectedText, "trig")
    }

    func testTheTailCarriesConsistentCountsInBothUnitSystems() {
        let tail = ErasePlan(text: "a😀é").erasedTail(graphemes: 2)
        XCTAssertEqual(tail?.expectedText, "😀é")
        XCTAssertEqual(tail?.backspaceCount, 2)
        XCTAssertEqual(tail?.utf16Count, "😀é".utf16.count)
        XCTAssertNil(tail?.validationFailure)
    }

    func testACombiningSequenceIsRestoredWholeNotSplit() {
        // One backspace removes the whole grapheme, so one posted pair restores the whole thing.
        let plan = ErasePlan(text: "ae\u{0301}")
        XCTAssertEqual(plan.erasedTail(graphemes: 1)?.expectedText, "e\u{0301}")
    }

    func testMoreThanThePlanIsClampedToThePlan() {
        XCTAssertEqual(ErasePlan(text: "trig").erasedTail(graphemes: 99)?.expectedText, "trig")
    }

    func testNothingPostedOrNothingKnownRestoresNothing() {
        XCTAssertNil(ErasePlan(text: "trig").erasedTail(graphemes: 0))
        XCTAssertNil(ErasePlan(text: "trig").erasedTail(graphemes: -3))
        XCTAssertNil(ErasePlan.counted(4).erasedTail(graphemes: 2), "a count-only plan has no text to restore")
        XCTAssertNil(ErasePlan.empty.erasedTail(graphemes: 2))
    }

    func testCaseSensitivityIsCarriedSoTheRestoredTextIsWhatTheUserTyped() {
        XCTAssertEqual(ErasePlan(text: "TrIg", caseInsensitive: true).erasedTail(graphemes: 2)?.expectedText, "Ig")
    }

    // MARK: - Kept head

    func testTheKeptHeadIsWhatThePostedCountShouldHaveLeft() {
        let plan = ErasePlan(text: "trig")
        XCTAssertEqual(plan.keptHead(graphemes: 1)?.expectedText, "tri")
        XCTAssertEqual(plan.keptHead(graphemes: 3)?.expectedText, "t")
        XCTAssertEqual(ErasePlan(text: "a😀é").keptHead(graphemes: 2)?.expectedText, "a")
        XCTAssertEqual(ErasePlan(text: "TrIg", caseInsensitive: true).keptHead(graphemes: 2)?.caseInsensitive, true)
    }

    func testNoHeadIsClaimedWhereNoReadingCouldConfirmIt() {
        // A count that covers the whole plan leaves nothing to read back — and is exactly the count
        // an authorized-but-never-created last pair produces, with one character still in the field.
        XCTAssertNil(ErasePlan(text: "trig").keptHead(graphemes: 4))
        XCTAssertNil(ErasePlan(text: "trig").keptHead(graphemes: 9))
        XCTAssertNil(ErasePlan(text: "trig").keptHead(graphemes: 0))
        XCTAssertNil(ErasePlan.counted(4).keptHead(graphemes: 2))
    }

    func testAnOverstatedCountIsCaughtByTheHeadCheck() throws {
        // Two pairs authorized, one posted: the field holds `tri`, the count says `tr`. `tri` does
        // not end in `tr`, so the check does not answer `.ok` (it downgrades to `.unavailable` for
        // text past the expected run, which the erase path treats as best-effort) — and the restore
        // is admitted only on `.ok`, so the `ig` that would have produced `triig` never goes in.
        let head = try XCTUnwrap(ErasePlan(text: "trig").keptHead(graphemes: 2))
        let overstated = ErasePreconditionChecker.evaluate(
            plan: head, value: "hello tri", caretLocation: 9, selectionLength: 0
        )
        XCTAssertNotEqual(overstated, .ok)
        let unreadable = ErasePreconditionChecker.evaluate(
            plan: head, value: nil, caretLocation: nil, selectionLength: nil
        )
        XCTAssertNotEqual(unreadable, .ok, "An unreadable field must not admit a restore")
        let exact = ErasePreconditionChecker.evaluate(
            plan: head, value: "hello tr", caretLocation: 8, selectionLength: 0
        )
        XCTAssertEqual(exact, .ok)
    }

    // MARK: - Wiring

    func testAnIncompleteEraseRestoresTheTailBeforeTheKeyIsReplayed() throws {
        let pipeline = SourceContractTests.strippingComments(
            try SourceTree.text("Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift")
        )
        let afterErase = try SourceTree.functionBody("func afterErase(", in: pipeline)
        let incomplete = try XCTUnwrap(afterErase.range(of: "guard erased else {"))
        let refuse = try XCTUnwrap(afterErase.range(of: "path: \"eraseIncomplete\""))
        let restore = try XCTUnwrap(afterErase.range(of: "erasePlan.erasedTail(graphemes: postedBackspaces)"))
        XCTAssertLessThan(incomplete.lowerBound, restore.lowerBound)
        XCTAssertLessThan(restore.lowerBound, refuse.lowerBound, "restore first, then the refusal replays the key")
        XCTAssertTrue(
            afterErase.contains("swallowed: .notSwallowed"),
            "The restore must not replay the swallowed key itself; the refusal that follows does, after the tail"
        )
        XCTAssertTrue(
            afterErase.contains("canProceedAfterMutation()"),
            "No restore into a field the continue-check no longer vouches for"
        )
        let headCheck = try XCTUnwrap(
            afterErase.range(of: "erasePlan.keptHead(graphemes: postedBackspaces)"),
            "The restore must be gated on the field holding the head the count implies"
        )
        XCTAssertLessThan(restore.lowerBound, headCheck.lowerBound)
        XCTAssertLessThan(headCheck.lowerBound, refuse.lowerBound)
        XCTAssertTrue(afterErase.contains("== .ok {"), "Only a confirmed head admits the restore; unavailable does not")
    }
}
