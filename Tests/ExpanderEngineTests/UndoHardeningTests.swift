import XCTest
@testable import ExpanderEngine

/// §3.1 undo hardening — the policies added after the "Sch`slm" incident (2026-08-11).
///
/// The incident class: an undo whose erase geometry assumes "the caret sits immediately after
/// `injectedText`" runs when that premise is false, eats the wrong span, and restores the trigger
/// onto a remnant. Four independent ways the premise breaks, four guards:
///
///  1. Text typed after the expansion, readable field  → strict precondition + widening
///     (`insertionPointFollowsExpectedText: false`, `widenedUndo`).
///  2. Text typed after the expansion, AX-opaque field → input-event counter refuses blind undo
///     (`undoEraseRefusalReason`).
///  3. Trailing keys / mid-text cursor placement       → no undo point recorded at all
///     (`undoPointAllowed`).
///  4. Caret moved by mouse click                      → record cleared at the tap
///     (EventTapEngine mouse branch — wiring, not unit-testable here).
final class UndoHardeningTests: XCTestCase {

    // MARK: - undoPointAllowed (guard 3)

    func testPlainExpansionIsUndoable() {
        XCTAssertTrue(TextInjectionPipeline.undoPointAllowed(
            trailingKeys: [], cursorOffset: nil, totalUTF16: 9
        ))
    }

    func testTrailingKeysForbidAnUndoPoint() {
        // An Enter posted after the text may have submitted a form; Tab may have moved focus.
        // Either way the caret is no longer ours to reason about.
        XCTAssertFalse(TextInjectionPipeline.undoPointAllowed(
            trailingKeys: ["\r"], cursorOffset: nil, totalUTF16: 9
        ))
        XCTAssertFalse(TextInjectionPipeline.undoPointAllowed(
            trailingKeys: ["\t", "\t"], cursorOffset: nil, totalUTF16: 9
        ))
    }

    func testMidTextCursorPlacementForbidsAnUndoPoint() {
        // A $|$ macro parked the caret inside the injected text — erasing `injectedText.count`
        // units backwards from there would eat text that precedes the injection.
        XCTAssertFalse(TextInjectionPipeline.undoPointAllowed(
            trailingKeys: [], cursorOffset: 4, totalUTF16: 9
        ))
    }

    func testCursorPlacedExactlyAtTheEndStaysUndoable() {
        // Offset == length is "caret after the last character" — the premise holds.
        XCTAssertTrue(TextInjectionPipeline.undoPointAllowed(
            trailingKeys: [], cursorOffset: 9, totalUTF16: 9
        ))
    }

    // MARK: - undoEraseRefusalReason (guard 2)

    func testCleanPreconditionProceedsRegardlessOfInputCount() {
        // A readable field that verifies is the strongest evidence there is — the counter is
        // only a stand-in for evidence AX cannot provide.
        XCTAssertNil(TextInjectionPipeline.undoEraseRefusalReason(
            result: .ok, inputEventsSinceExpansion: 12
        ))
    }

    func testMismatchAlwaysRefuses() {
        XCTAssertNotNil(TextInjectionPipeline.undoEraseRefusalReason(
            result: .mismatch("field holds other text"), inputEventsSinceExpansion: 0
        ))
    }

    func testOpaqueFieldWithNoInputSinceExpansionMayProceedBlind() {
        // Pre-existing §3.1 behaviour, now with its premise actually enforced: zero input events
        // (and clicks clear the record) mean the caret provably still sits after the injection.
        XCTAssertNil(TextInjectionPipeline.undoEraseRefusalReason(
            result: .unavailable("AXValue unreadable"), inputEventsSinceExpansion: 0
        ))
    }

    func testOpaqueFieldWithInputSinceExpansionRefusesBlindUndo() {
        // The "Sch`slm" shape in a host where no precondition read can catch it: input landed,
        // the field cannot be read, so the erase span is unknowable. Refuse.
        let reason = TextInjectionPipeline.undoEraseRefusalReason(
            result: .unavailable("AXValue unreadable"), inputEventsSinceExpansion: 3
        )
        XCTAssertNotNil(reason)
        XCTAssertTrue(
            reason?.contains("3 input event") == true,
            "The refusal must carry the evidence count for diagnostics, got \(reason ?? "nil")"
        )
    }

    func testSingleInputEventIsEnoughToRefuseBlindUndo() {
        // The type-ahead replay case: one held character replayed after delivery is one unit
        // sitting between the injected text and the caret — one unit of mis-erase.
        XCTAssertNotNil(TextInjectionPipeline.undoEraseRefusalReason(
            result: .unavailable("no focused element"), inputEventsSinceExpansion: 1
        ))
    }
}
