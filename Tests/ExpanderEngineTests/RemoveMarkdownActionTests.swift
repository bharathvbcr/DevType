import XCTest
@testable import ExpanderEngine

/// The `removeMarkdown` transform kind — the palette action, as opposed to the automatic
/// pass that tidies up after every other kind.
///
/// The two are deliberately different, and most of this suite is about that difference:
/// the automatic pass protects the author's own Markdown, and this one exists to delete it.
final class RemoveMarkdownActionTests: XCTestCase {

    private var savedPreference: Any?

    override func setUp() {
        super.setUp()
        savedPreference = UserDefaults.standard.object(forKey: AIPreferences.removesMarkdownKey)
    }

    override func tearDown() {
        if let savedPreference {
            UserDefaults.standard.set(savedPreference, forKey: AIPreferences.removesMarkdownKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AIPreferences.removesMarkdownKey)
        }
        super.tearDown()
    }

    // MARK: - It runs locally

    /// The whole reason this kind exists as a local transform: `AIMarkdownStripper` answers
    /// it exactly, so a model would only add latency, variance, and a refusal path.
    func testTheKindNeedsNoModel() {
        XCTAssertFalse(AITransformKind.removeMarkdown.requiresModel)
        XCTAssertTrue(AILocalTransform.handles(.removeMarkdown))

        // Its opposite number is model work, and stays that way: deciding what in a
        // paragraph deserves to be a heading is judgement, not a transformation.
        XCTAssertTrue(AITransformKind.toMarkdown.requiresModel)

        // And every other kind still does, so the short-circuit cannot swallow one.
        for kind in AITransformKind.allCases where kind != .removeMarkdown {
            XCTAssertTrue(kind.requiresModel, "\(kind.rawValue) unexpectedly became local")
            XCTAssertNil(AILocalTransform.run(kind: kind, input: "text"), "\(kind.rawValue)")
        }
    }

    func testItProducesPlainTextFromAMarkdownDocument() {
        let input = """
        # Release Notes

        The **launch** shipped. See [the deck](https://example.com/deck).

        * Revenue up `12%`
        * Latency down

        ---

        _Prepared by the team._
        """
        let expected = """
        Release Notes

        The launch shipped. See the deck.

        - Revenue up 12%
        - Latency down

        Prepared by the team.
        """
        guard case .success(let output)? = AILocalTransform.run(kind: .removeMarkdown, input: input) else {
            return XCTFail("Expected a local success")
        }
        XCTAssertEqual(output, expected)
    }

    // MARK: - How it differs from the automatic pass

    /// The automatic pass never removes a construct the source already used, so proofreading
    /// a README gives the README back. This action is the user pointing at that README and
    /// asking for it to stop being one — the ownership rule must not apply.
    func testItRemovesTheAuthorsOwnMarkdownUnlikeTheAutomaticPass() {
        let markdown = "## Setup\n\nRun the **installer** first."

        // Automatic pass, with the same text as its source: nothing is touched.
        XCTAssertEqual(
            AIMarkdownStripper.strip(markdown, policy: .strip, original: markdown),
            markdown
        )

        // Explicit action: everything goes.
        guard case .success(let output)? = AILocalTransform.run(kind: .removeMarkdown, input: markdown) else {
            return XCTFail("Expected a local success")
        }
        XCTAssertEqual(output, "Setup\n\nRun the installer first.")
    }

    /// `AIPreferences.removesMarkdown` governs whether DevType tidies up after a model on
    /// its own. It has no business overruling an action the user picked by name.
    func testItIgnoresTheAutomaticRemovalPreference() {
        let input = "The **launch** is Friday."
        for enabled in [true, false] {
            AIPreferences.removesMarkdown = enabled
            guard case .success(let output)? = AILocalTransform.run(kind: .removeMarkdown, input: input) else {
                return XCTFail("Expected a local success (preference \(enabled))")
            }
            XCTAssertEqual(output, "The launch is Friday.", "preference \(enabled)")
        }
    }

    // MARK: - Selection safety

    /// The direct path replaces the selection with this text, so a mid-sentence selection
    /// must keep the spaces that separated it from its neighbours.
    func testItRestoresTheSelectionsOwnWhitespace() {
        guard case .success(let output)? = AILocalTransform.run(kind: .removeMarkdown, input: "  **bold**  ") else {
            return XCTFail("Expected a local success")
        }
        XCTAssertEqual(output, "  bold  ")
    }

    /// Nothing to remove is a valid answer, not a failure — the text comes back unchanged
    /// rather than the action reporting an error the user cannot act on.
    func testPlainTextComesBackUnchanged() {
        let plain = "Ship the build on Friday, then update user_id in build/*.o."
        guard case .success(let output)? = AILocalTransform.run(kind: .removeMarkdown, input: plain) else {
            return XCTFail("Expected a local success")
        }
        XCTAssertEqual(output, plain)
    }

    /// The direct path refuses to inject a blank result, so this must never produce one.
    func testItNeverEmptiesASelection() {
        for input in ["**", "***", "# ", "> ", "- ", "|---|", "```", "~~~", "___", "===", "  "] {
            guard case .success(let output)? = AILocalTransform.run(kind: .removeMarkdown, input: input) else {
                return XCTFail("Expected a local success for \(input.debugDescription)")
            }
            XCTAssertFalse(output.isEmpty, "\(input.debugDescription) emptied the selection")
        }
    }

    /// Selecting a code block and asking for plain text should give back the code, not a
    /// version of it with the underscores filed off.
    func testFencedCodeSurvivesAsCode() {
        let input = "```swift\nlet user_id = fetch(*pointer)\n```"
        guard case .success(let output)? = AILocalTransform.run(kind: .removeMarkdown, input: input) else {
            return XCTFail("Expected a local success")
        }
        XCTAssertEqual(output, "let user_id = fetch(*pointer)")
    }

    // MARK: - Discoverability

    /// The point of making it a kind: it shows up everywhere the others do.
    func testItIsSearchableInTheCommandPalette() {
        let command = CommandPaletteCatalog.commands.first { $0.id == "ai.removemarkdown" }
        guard let command else { return XCTFail("Not registered in the palette catalogue") }

        XCTAssertEqual(command.section, .ai)
        XCTAssertEqual(command.titleKey, "ai.kind.removemarkdown")
        for term in ["remove markdown", "strip markdown", "markdown", "plain text", "unformat"] {
            XCTAssertTrue(command.aliases.contains(term), "missing alias: \(term)")
        }
    }

    func testItIsOfferedByEveryKindDrivenSurface() {
        XCTAssertTrue(AITransformKind.builtInPalette.contains(.removeMarkdown), "AI action panel")
        XCTAssertEqual(AITransformKind.named("removemarkdown"), .removeMarkdown, "snippet aiTransform / voice trigger")
        XCTAssertEqual(AITransformKind.named("RemoveMarkdown"), .removeMarkdown, "lookup is case-insensitive")
    }

    /// Typing what a user would actually type has to find it. Aliases in a list prove
    /// nothing until they go through the ranker.
    func testTypingForItFindsIt() {
        let queries = [
            "markdown", "remove markdown", "strip markdown", "md", "plain text",
            "unformat", "remove formatting", "markdown removal"
        ]
        for query in queries {
            let hits = CommandPaletteCatalog.matchCommands(query: query, limit: 40)
            XCTAssertTrue(
                hits.contains { $0.command.id == "ai.removemarkdown" },
                "\(query.debugDescription) did not surface Remove Markdown"
            )
        }
    }

    /// The row must stay usable on a Mac with no Apple Intelligence — which is most Macs
    /// DevType runs on, since the deployment target is macOS 14 and the model needs 26.
    func testItStaysEnabledWhenTheModelIsUnavailable() {
        let hits = CommandPaletteCatalog.matchCommands(
            query: "markdown",
            aiDisabledReason: "Apple Intelligence is unavailable",
            limit: 40
        )
        guard let hit = hits.first(where: { $0.command.id == "ai.removemarkdown" }) else {
            return XCTFail("Remove Markdown missing from results")
        }
        XCTAssertTrue(hit.isEnabled, "disabled for want of a model it never uses")
        XCTAssertNil(hit.disabledReason)

        // A model-backed row in the same result set is still disabled, so the exemption is
        // scoped to the local kind rather than defeating the gate.
        let modelHits = CommandPaletteCatalog.matchCommands(
            query: "proofread",
            aiDisabledReason: "Apple Intelligence is unavailable",
            limit: 40
        )
        let proofread = modelHits.first { $0.command.id == "ai.proofread" }
        XCTAssertEqual(proofread?.disabledReason, "Apple Intelligence is unavailable")
    }

    /// Its palette row carries the local subtitle rather than the on-device-model one, and
    /// every language has both strings.
    func testItsPaletteRowSaysItRunsLocally() {
        let command = CommandPaletteCatalog.commands.first { $0.id == "ai.removemarkdown" }
        XCTAssertEqual(command?.subtitleKey, "palette.ai.local.subtitle")

        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            XCTAssertNotNil(table["palette.ai.local.subtitle"], "\(language.rawValue)")
            XCTAssertNotNil(table["ai.kind.removemarkdown"], "\(language.rawValue)")
        }
    }
}
