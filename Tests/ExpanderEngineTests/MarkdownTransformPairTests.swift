import XCTest
@testable import ExpanderEngine

/// `toMarkdown` and `removeMarkdown` are opposites, and the AI surface has to treat them
/// as opposites in every place it makes a decision about a kind. Most of the ways this
/// could break are silent: a policy inherited from the wrong group, an action offered on a
/// machine that cannot run it, or the automatic Markdown pass deleting the very formatting
/// `toMarkdown` was asked to produce.
final class MarkdownTransformPairTests: XCTestCase {

    // MARK: - The pairing

    /// The one that must never regress. `toMarkdown`'s whole output is Markdown; if it were
    /// ever classified `.strip` like its neighbours, `AITextTransformer` would hand the
    /// answer to `AIMarkdownStripper` and undo the transform on the way to the field —
    /// silently, with a plausible-looking result.
    func testFormattingToMarkdownIsNotUndoneByTheAutomaticPass() {
        XCTAssertEqual(AITransformKind.toMarkdown.markdownPolicy, .preserve)

        let answer = "## Setup\n\nRun the **installer**, then `reboot`."
        XCTAssertEqual(
            AIMarkdownStripper.strip(answer, policy: AITransformKind.toMarkdown.markdownPolicy),
            answer
        )
        // Same answer under its opposite's policy, to show the two really do disagree.
        XCTAssertEqual(
            AIMarkdownStripper.strip(answer, policy: AITransformKind.removeMarkdown.markdownPolicy),
            "Setup\n\nRun the installer, then reboot."
        )
    }

    /// Round trip: format prose, then strip it back. The words survive; only syntax moved.
    func testStrippingUndoesFormattingOnTheWordsThatMatter() {
        let original = "Setup\n\nRun the installer, then reboot."
        let formatted = "## Setup\n\nRun the **installer**, then `reboot`."
        guard case .success(let back)? = AILocalTransform.run(kind: .removeMarkdown, input: formatted) else {
            return XCTFail("Expected a local success")
        }
        XCTAssertEqual(back, original)
    }

    func testTheTwoKindsDisagreeOnEveryDecisionThatShouldDiffer() {
        let format = AITransformKind.toMarkdown
        let remove = AITransformKind.removeMarkdown

        XCTAssertNotEqual(format.markdownPolicy, remove.markdownPolicy)
        XCTAssertNotEqual(format.requiresModel, remove.requiresModel)
        // Formatting restructures a whole document and is reviewed first; removal is
        // deterministic and lands immediately.
        XCTAssertEqual(format.defaultOutputMode, .preview)
        XCTAssertEqual(remove.defaultOutputMode, .direct)
        // A paragraph cannot know it is the third item of a list, so formatting refuses
        // oversized input instead of chunking it.
        XCTAssertFalse(format.isChunkSafe)
        XCTAssertTrue(remove.isChunkSafe)
    }

    /// Formatting adds syntax to every line it touches, so it must not be held to a
    /// correction-sized length budget — that would reject its own correct answers.
    func testFormattingIsAllowedToGrow() {
        XCTAssertEqual(AITransformKind.toMarkdown.lengthPolicy, .unconstrained)
        let input = "Setup\nRun the installer"
        let output = "## Setup\n\n- Run the **installer**"
        XCTAssertFalse(AITransformKind.toMarkdown.lengthPolicy.exceeded(input: input, output: output))
    }

    // MARK: - Discoverability

    func testBothAreSearchableAndTellThemselvesApart() {
        for (id, titleKey) in [("ai.tomarkdown", "ai.kind.tomarkdown"),
                               ("ai.removemarkdown", "ai.kind.removemarkdown")] {
            let command = CommandPaletteCatalog.commands.first { $0.id == id }
            XCTAssertEqual(command?.titleKey, titleKey, "\(id) missing from the catalogue")
        }

        // Typing the ambiguous word offers both, and the unambiguous ones pick a side.
        let both = CommandPaletteCatalog.matchCommands(query: "markdown", limit: 40).map(\.command.id)
        XCTAssertTrue(both.contains("ai.tomarkdown"))
        XCTAssertTrue(both.contains("ai.removemarkdown"))

        for query in ["format as markdown", "convert to markdown", "markdownify", "add headings"] {
            let ids = CommandPaletteCatalog.matchCommands(query: query, limit: 40).map(\.command.id)
            XCTAssertTrue(ids.contains("ai.tomarkdown"), "\(query.debugDescription) missed Format as Markdown")
        }
        for query in ["remove markdown", "strip markdown", "plain text", "unformat"] {
            let ids = CommandPaletteCatalog.matchCommands(query: query, limit: 40).map(\.command.id)
            XCTAssertTrue(ids.contains("ai.removemarkdown"), "\(query.debugDescription) missed Remove Markdown")
        }
    }

    func testBothHaveTitlesInEveryLanguage() {
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            XCTAssertNotNil(table["ai.kind.tomarkdown"], "\(language.rawValue)")
            XCTAssertNotNil(table["ai.kind.removemarkdown"], "\(language.rawValue)")
        }
    }

    // MARK: - The AI panel with no model

    /// The panel opens on a Mac without Apple Intelligence and offers what still works,
    /// rather than an alert. Apple Intelligence needs macOS 26 and DevType's target is
    /// macOS 14, so this is the ordinary case for a large share of users.
    func testPanelFallsBackToTheLocalActionsInsteadOfRefusing() {
        let withModel = AITransformKind.palette(modelAvailable: true)
        let withoutModel = AITransformKind.palette(modelAvailable: false)

        XCTAssertEqual(withModel, AITransformKind.builtInPalette)
        XCTAssertFalse(withoutModel.isEmpty, "an empty picker is worse than the alert it replaced")
        XCTAssertEqual(withoutModel, [.removeMarkdown])

        // The narrowed list is a subset that keeps its order, so rows do not shuffle
        // between the two states.
        XCTAssertEqual(withoutModel, withModel.filter(withoutModel.contains))
        for kind in withoutModel {
            XCTAssertFalse(kind.requiresModel, "\(kind.rawValue) cannot run without the model")
        }
        // Model-backed kinds are the ones held back — `toMarkdown` among them.
        XCTAssertFalse(withoutModel.contains(.toMarkdown))
        XCTAssertFalse(withoutModel.contains(.proofread))
    }

    /// The panel's explanation for the short list, and the disabled custom field, need
    /// strings in every language or the label renders as a raw key.
    func testThePanelsLocalOnlyNoticeIsLocalized() {
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            XCTAssertNotNil(table["ai.palette.localOnly"], "\(language.rawValue)")
            XCTAssertNotNil(table["ai.palette.customUnavailable"], "\(language.rawValue)")
        }
    }

    /// `custom` needs the model, so it must never survive into the local-only list — the
    /// panel disables its instruction field on the same signal.
    func testCustomInstructionsAreNotOfferedWithoutTheModel() {
        XCTAssertTrue(AITransformKind.custom.requiresModel)
        XCTAssertFalse(AITransformKind.palette(modelAvailable: false).contains(.custom))
    }
}
