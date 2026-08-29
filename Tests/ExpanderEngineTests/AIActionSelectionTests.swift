import XCTest
@testable import ExpanderEngine

/// The AI action panel used to run `.custom` while leaving the typed instruction behind in
/// its text field: the pick carried a kind and nothing else. `.custom`'s own prompt is a
/// wrapper with no direction in it, so the model received no instructions at all.
///
/// `AIActionSelection` is the decision that regressed, lifted out of the AppKit panel so it
/// can be exercised here. Wiring lives in `SourceContractTests` — `DevTypeApp` is an
/// executable target and cannot be imported.
final class AIActionSelectionTests: XCTestCase {

    // MARK: - Why the pairing matters

    /// `.custom` alone is not an action. If this ever stops being true, the rest of this
    /// file is guarding something that no longer needs guarding.
    func testCustomKindCarriesNoDirectionOfItsOwn() {
        let prompt = AITransformKind.custom.instructions.lowercased()
        XCTAssertTrue(
            prompt.contains("additional instructions"),
            "`.custom` defers entirely to caller-supplied instructions: \(prompt)"
        )
        XCTAssertFalse(
            AITransformKind.builtInPalette.contains(.custom),
            "`.custom` must not be pickable as a bare palette row — it needs instructions."
        )
    }

    // MARK: - Return in the panel

    func testTypedInstructionIsCarriedWithTheCustomKind() {
        let selection = AIActionSelection.confirmingReturn(
            instructionFieldText: "translate to Portuguese",
            isEditingInstructionField: true,
            highlightedAction: .proofread
        )
        XCTAssertEqual(selection?.kind, .custom)
        XCTAssertEqual(selection?.customInstructions, "translate to Portuguese")
    }

    func testTypedInstructionIsTrimmedButOtherwiseUntouched() {
        let selection = AIActionSelection.confirmingReturn(
            instructionFieldText: "  \n translate to Portuguese\t",
            isEditingInstructionField: true,
            highlightedAction: nil
        )
        XCTAssertEqual(selection?.customInstructions, "translate to Portuguese")
    }

    /// An instruction field with nothing in it is not a custom action — the highlighted row
    /// is what the user is looking at.
    func testEmptyInstructionFieldFallsBackToTheHighlightedAction() {
        for text in ["", "   ", "\n\t "] {
            let selection = AIActionSelection.confirmingReturn(
                instructionFieldText: text,
                isEditingInstructionField: true,
                highlightedAction: .condense
            )
            XCTAssertEqual(selection?.kind, .condense, "text: \(text.debugDescription)")
            XCTAssertNil(selection?.customInstructions)
        }
    }

    /// Text left in the field while focus is elsewhere (the list, the filter) does not
    /// hijack a built-in pick.
    func testUnfocusedInstructionFieldDoesNotOverrideTheHighlightedAction() {
        let selection = AIActionSelection.confirmingReturn(
            instructionFieldText: "translate to Portuguese",
            isEditingInstructionField: false,
            highlightedAction: .proofread
        )
        XCTAssertEqual(selection?.kind, .proofread)
        XCTAssertNil(selection?.customInstructions)
    }

    func testNothingToRunResolvesToNoAction() {
        XCTAssertNil(AIActionSelection.confirmingReturn(
            instructionFieldText: "   ",
            isEditingInstructionField: true,
            highlightedAction: nil
        ))
        XCTAssertNil(AIActionSelection.confirmingReturn(
            instructionFieldText: "filtered everything out",
            isEditingInstructionField: false,
            highlightedAction: nil
        ))
    }

    /// A filter that matched no rows still runs what the user typed.
    func testInstructionRunsEvenWithNoHighlightedRow() {
        let selection = AIActionSelection.confirmingReturn(
            instructionFieldText: "rewrite as a haiku",
            isEditingInstructionField: true,
            highlightedAction: nil
        )
        XCTAssertEqual(selection?.kind, .custom)
        XCTAssertEqual(selection?.customInstructions, "rewrite as a haiku")
    }

    // MARK: - The empty/absent instruction invariant

    func testBlankInstructionsAreNotRepresentable() {
        XCTAssertNil(AIActionSelection(kind: .custom, customInstructions: "").customInstructions)
        XCTAssertNil(AIActionSelection(kind: .custom, customInstructions: " \n ").customInstructions)
        XCTAssertEqual(
            AIActionSelection(kind: .custom, customInstructions: "  go  "),
            AIActionSelection(kind: .custom, customInstructions: "go"),
            "Normalization happens at construction, so equal requests compare equal."
        )
    }

    func testBuiltInPickCarriesNoInstructions() {
        XCTAssertNil(AIActionSelection(kind: .proofread).customInstructions)
    }

    // MARK: - Preview policy

    func testUserAuthoredInstructionsAlwaysPreview() {
        XCTAssertTrue(AIActionSelection(kind: .custom, customInstructions: "x").requiresPreview)
        XCTAssertTrue(
            AIActionSelection(kind: .custom).requiresPreview,
            "`.custom` previews even with nothing attached — its output is unbounded."
        )
        XCTAssertTrue(
            AIActionSelection(kind: .rewrite, customInstructions: "in Portuguese").requiresPreview,
            "A built-in kind steered by user text is just as open-ended."
        )
    }

    func testPlainBuiltInPickLeavesTheOutputModeToPreferences() {
        for kind in AITransformKind.builtInPalette {
            XCTAssertFalse(
                AIActionSelection(kind: kind).requiresPreview,
                "\(kind) must keep honouring its configured output mode."
            )
        }
    }

    // MARK: - Merging (preview panel tone menu)

    func testMergedKeepsBothPartsInOrder() {
        XCTAssertEqual(
            AIActionSelection.merged(["translate to Portuguese", "Keep it formal."]),
            "translate to Portuguese\nKeep it formal."
        )
    }

    /// A preset must never stand in for the user's own words.
    func testMergedDropsOnlyTheEmptyParts() {
        XCTAssertEqual(AIActionSelection.merged([nil, "Keep it formal."]), "Keep it formal.")
        XCTAssertEqual(AIActionSelection.merged(["  ", "Keep it formal."]), "Keep it formal.")
        XCTAssertEqual(AIActionSelection.merged(["translate", nil]), "translate")
        XCTAssertNil(AIActionSelection.merged([nil, "   ", nil]))
        XCTAssertNil(AIActionSelection.merged([]))
    }

    // MARK: - One normalization for both authoring paths

    /// The ⌘/ palette's `>` prefix and the panel's instruction field must agree on what
    /// counts as an instruction, or the same typed text runs in one place and not the other.
    func testTypedPalettePrefixNormalizesLikeTheInstructionField() {
        guard case .customAI(let instructions)? =
            CommandPaletteCatalog.parseTypedQuery(">   translate to Portuguese  ") else {
            return XCTFail("expected a custom AI query")
        }
        XCTAssertEqual(instructions, "translate to Portuguese")
        XCTAssertEqual(
            instructions,
            AIActionSelection.confirmingReturn(
                instructionFieldText: "   translate to Portuguese  ",
                isEditingInstructionField: true,
                highlightedAction: nil
            )?.customInstructions
        )
        XCTAssertNil(CommandPaletteCatalog.parseTypedQuery(">    "))
    }
}
