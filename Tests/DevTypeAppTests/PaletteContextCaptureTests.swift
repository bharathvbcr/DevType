import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// Mapping the captured selection onto the palette's ranking context.
///
/// The read happens once, before the panel takes key — a live re-read would resolve to our own
/// search field. Everything downstream depends on this one reduction being conservative.
final class PaletteContextCaptureTests: XCTestCase {

    private func result(_ text: String) -> SelectionReader.Outcome {
        .selection(SelectionReader.Result(text: text, bundleID: "com.example.app", isWeakAX: false))
    }

    func testRealSelectedTextPromotesTransforms() {
        XCTAssertEqual(
            InlineSearchPanel.context(for: result("rewrite this paragraph")),
            .selection
        )
    }

    /// Whitespace is not a selection worth transforming.
    func testWhitespaceOnlySelectionIsNotASelection() {
        XCTAssertEqual(InlineSearchPanel.context(for: result("   \n\t ")), .none)
        XCTAssertEqual(InlineSearchPanel.context(for: result("")), .none)
    }

    /// Every failure means we do not *know* text is selected. Guessing would put a screenful
    /// of transforms the user cannot run above the rows they can.
    func testEveryReadFailureFallsBackToTheIdleList() {
        let failures: [SelectionReader.Failure] = [
            .accessibilityUntrusted,
            .secureInputActive,
            .appMuted("com.example.app"),
            .noFocusedElement,
            .noSourceSelection,
            .emptySelection,
            .selectionTooLarge(999_999)
        ]
        for failure in failures {
            XCTAssertEqual(
                InlineSearchPanel.context(for: .failure(failure)), .none,
                "\(failure.diagnosticLabel) must not be treated as a live selection."
            )
        }
    }
}
