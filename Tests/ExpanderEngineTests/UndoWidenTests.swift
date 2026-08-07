import XCTest
@testable import ExpanderEngine

/// §3.1 undo assumed the caret was still exactly where injection left it. Type one more
/// character and the check window shifts by one, so it compares the wrong slice and refuses:
///
///     injected "ScholarLM", user then types "l"  →  field "ScholarLMl", caret 10
///     naive window = units[1..<10] = "cholarLMl" ≠ "ScholarLM"  →  refused
///
/// Refusing was *correct* — erasing there would have eaten the wrong nine characters and left a
/// stray "S" — but undo silently did nothing. `widenedUndo` finds the injected text at its real
/// offset and undoes the whole span, restoring the trigger plus whatever was typed after it.
final class UndoWidenTests: XCTestCase {

    private func widen(
        injected: String,
        trigger: String,
        value: String,
        caret: Int,
        maxTypedAfter: Int = TextInjectionPipeline.undoMaxTypedAfter
    ) -> (plan: ErasePlan, restore: String)? {
        TextInjectionPipeline.widenedUndo(
            injectedText: injected,
            triggerText: trigger,
            value: value,
            caretLocation: caret,
            maxTypedAfter: maxTypedAfter
        )
    }

    // MARK: - The reported failure

    func testWidensOverASingleCharacterTypedAfterTheExpansion() {
        let result = widen(
            injected: "ScholarLM",
            trigger: "`slm",
            value: "ScholarLMl",
            caret: 10
        )
        XCTAssertNotNil(result, "This is the exact case that used to refuse.")
        // Erase the injection *and* the typed character…
        XCTAssertEqual(result?.plan.utf16Count, "ScholarLMl".utf16.count)
        // …then put back what the user actually typed.
        XCTAssertEqual(result?.restore, "`slml")
    }

    func testWidensOverSeveralTypedCharacters() {
        let result = widen(
            injected: "ScholarLM",
            trigger: "`slm",
            value: "ScholarLMabout",
            caret: 14
        )
        XCTAssertEqual(result?.restore, "`slmabout")
        XCTAssertEqual(result?.plan.utf16Count, "ScholarLMabout".utf16.count)
    }

    /// Text before the expansion must be preserved — only the injected span and what follows it
    /// are ours to remove.
    func testLeadingContextIsNotIncludedInTheErase() {
        let result = widen(
            injected: "ScholarLM",
            trigger: "`slm",
            value: "see ScholarLMl",
            caret: 14
        )
        XCTAssertEqual(result?.restore, "`slml")
        XCTAssertEqual(
            result?.plan.utf16Count, "ScholarLMl".utf16.count,
            "Erase must cover only the injection plus the typed tail, never the preceding text."
        )
    }

    // MARK: - Cases that must stay on the fail-closed path

    func testUntouchedFieldIsNotWidened() {
        // k == 0 is the normal plan's job; widening must not duplicate it.
        XCTAssertNil(
            widen(injected: "ScholarLM", trigger: "`slm", value: "ScholarLM", caret: 9),
            "An untouched field needs no widening."
        )
    }

    func testInjectedTextAbsentMeansNoUndo() {
        XCTAssertNil(
            widen(injected: "ScholarLM", trigger: "`slm", value: "something else entirely", caret: 23),
            "Without a positive match of the injected text, undo must refuse."
        )
    }

    func testNewlineAfterExpansionRefusesToWiden() {
        // A newline may have submitted a form or moved focus; re-typing past it is not safe.
        XCTAssertNil(
            widen(injected: "ScholarLM", trigger: "`slm", value: "ScholarLM\nnext", caret: 14),
            "A newline in the typed tail must abort widening."
        )
    }

    func testWideningIsBounded() {
        let tail = String(repeating: "x", count: TextInjectionPipeline.undoMaxTypedAfter + 5)
        XCTAssertNil(
            widen(
                injected: "ScholarLM",
                trigger: "`slm",
                value: "ScholarLM" + tail,
                caret: 9 + tail.count
            ),
            "Beyond the bound, a stale record must not authorise an ever-larger erase."
        )
    }

    func testExactlyAtTheBoundStillWidens() {
        let tail = String(repeating: "x", count: TextInjectionPipeline.undoMaxTypedAfter)
        let result = widen(
            injected: "ScholarLM",
            trigger: "`slm",
            value: "ScholarLM" + tail,
            caret: 9 + tail.count
        )
        XCTAssertEqual(result?.restore, "`slm" + tail, "The bound itself must be inclusive.")
    }

    func testUnreadableFieldYieldsNil() {
        XCTAssertNil(
            TextInjectionPipeline.widenedUndo(
                injectedText: "ScholarLM", triggerText: "`slm",
                value: nil, caretLocation: 10
            ),
            "An unreadable AXValue must not be treated as a match."
        )
        XCTAssertNil(
            TextInjectionPipeline.widenedUndo(
                injectedText: "ScholarLM", triggerText: "`slm",
                value: "ScholarLMl", caretLocation: nil
            ),
            "Without a caret there is no window to verify."
        )
    }

    func testCaretBeyondValueIsRejected() {
        XCTAssertNil(
            widen(injected: "ScholarLM", trigger: "`slm", value: "ScholarLMl", caret: 999),
            "A caret past the end signals a virtualised/stale AX snapshot."
        )
    }

    func testEmptyInjectedTextYieldsNil() {
        XCTAssertNil(
            widen(injected: "", trigger: "`slm", value: "abc", caret: 3),
            "Nothing was injected, so there is nothing to undo."
        )
    }

    // MARK: - Unicode

    /// The window arithmetic is in UTF-16 units, so a non-BMP tail must not corrupt the span.
    func testAstralCharactersUseUTF16UnitsConsistently() {
        let injected = "ScholarLM"
        let tail = "🎓"                     // 2 UTF-16 units
        let value = injected + tail
        let result = widen(
            injected: injected,
            trigger: "`slm",
            value: value,
            caret: value.utf16.count
        )
        XCTAssertEqual(result?.restore, "`slm🎓")
        XCTAssertEqual(result?.plan.utf16Count, value.utf16.count)
    }
}
