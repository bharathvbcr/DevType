import XCTest
@testable import ExpanderEngine

/// `mergeRewrite`: several overlapping fragments in, one coherent piece out.
///
/// Distinct from `condense`, which tightens a single passage. Merge deduplicates *across*
/// fragments — the resume-bullet and scattered-notes case — so its contract differs in the
/// places that matter: it cannot be chunked, and it must not lose specifics.
final class MergeRewriteTransformTests: XCTestCase {

    // MARK: - Reachability

    func testItIsOfferedInThePalette() {
        XCTAssertTrue(AITransformKind.builtInPalette.contains(.mergeRewrite))
        XCTAssertTrue(
            CommandPaletteCatalog.commands.contains { $0.id == "ai.mergerewrite" },
            "The kind must exist as a palette row, not just as an enum case."
        )
    }

    func testItIsReachableByTheWordsSomeoneWouldActuallyType() {
        for query in [
            "merge", "merge and rewrite", "combine", "consolidate",
            "merge bullets", "resume points", "resume bullets", "merge notes"
        ] {
            let hits = CommandPaletteCatalog.matchCommands(query: query, loc: .shared)
            XCTAssertEqual(
                hits.first?.command.id, "ai.mergerewrite",
                "\"\(query)\" should reach merge, got \(hits.first?.command.id ?? "nothing")."
            )
        }
    }

    /// Merge and condense answer different questions, so the words for one must not drag in
    /// the other. `condense`/`summarize` stay condense's.
    /// `dedupe` and `remove duplicates` name `tool.dedupeLines` — instant, local, exact.
    /// An AI merge must not compete for the words that name a deterministic tool.
    func testItDoesNotStealTheDeterministicDedupeTool() {
        for query in ["dedupe", "remove duplicates", "unique lines"] {
            XCTAssertEqual(
                CommandPaletteCatalog.matchCommands(query: query, loc: .shared).first?.command.id,
                "tool.dedupeLines",
                "\"\(query)\" must still reach the local line deduplicator."
            )
        }
    }

    func testItDoesNotStealCondensesVocabulary() {
        for query in ["condense", "summarize", "shorten", "make it shorter"] {
            let hits = CommandPaletteCatalog.matchCommands(query: query, loc: .shared)
            XCTAssertEqual(
                hits.first?.command.id, "ai.condense",
                "\"\(query)\" must still mean condense."
            )
        }
    }

    /// Its whole use case is "several bullets are selected", so it has to be one of the
    /// rows offered the moment the palette opens on a selection — not something you have to
    /// already know the name of.
    func testItIsOfferedTheMomentTextIsSelected() {
        XCTAssertTrue(CommandPaletteCatalog.selectionSuggestionIDs.contains("ai.mergerewrite"))
        let rows = CommandPaletteCatalog.buildRows(
            query: "", groups: [], loc: .shared, context: .selection
        )
        let offered = rows.compactMap { row -> String? in
            if case .command(let hit) = row { return hit.command.id } else { return nil }
        }
        XCTAssertTrue(offered.contains("ai.mergerewrite"), "Merge must be offered on a selection.")
        XCTAssertFalse(
            CommandPaletteCatalog.idleSuggestionIDs.contains("ai.mergerewrite"),
            "With nothing selected there are no fragments to merge."
        )
    }

    func testItIsReachableByVoice() {
        XCTAssertEqual(VoicePreferences.defaultVoiceTriggers["merge"], "mergerewrite")
        XCTAssertEqual(AITransformKind.named("mergerewrite"), .mergeRewrite)
    }

    // MARK: - Contract

    /// The load-bearing one. A chunk cannot deduplicate against fragments it never saw, so
    /// oversized input must be refused rather than split — the same rule `condense` and
    /// `expand` follow, for the same reason.
    func testItRefusesToBeChunked() {
        XCTAssertFalse(
            AITransformKind.mergeRewrite.isChunkSafe,
            "Merging paragraph-by-paragraph would deduplicate against nothing."
        )
    }

    /// It shortens, but not as hard as `condense`: every distinct fact still has to survive.
    func testItBudgetsBelowInputButAboveCondense() {
        let merge = AITransformKind.mergeRewrite.tokenBudgetMultiplier
        XCTAssertLessThan(merge, 1.0, "Merging overlapping fragments must shorten them.")
        XCTAssertGreaterThan(
            merge, AITransformKind.condense.tokenBudgetMultiplier,
            "Merge keeps more than condense does — it carries every distinct fact through."
        )
    }

    /// Fewer lines out than in is the entire point, so the line-structure contract must not
    /// be applied to it.
    func testItIsNotHeldToTheInputsLineCount() {
        XCTAssertFalse(AITransformKind.mergeRewrite.preservesLineStructure)
    }

    /// Bullets in, bullets out — so emphasis comes off but the list markers stay.
    func testItKeepsTheFormTheInputArrivedIn() {
        XCTAssertEqual(AITransformKind.mergeRewrite.markdownPolicy, .stripPreservingLayout)
    }

    /// It restructures the whole selection, so it is reviewed before it replaces anything.
    func testItIsReviewedBeforeItReplacesAnything() {
        XCTAssertEqual(AITransformKind.mergeRewrite.defaultOutputMode, .preview)
        XCTAssertTrue(AITransformKind.mergeRewrite.requiresModel)
    }

    /// Many valid phrasings, so Retry must be able to produce a different one.
    func testRetryCanReRoll() {
        XCTAssertFalse(AITransformKind.mergeRewrite.isDeterministic)
    }

    /// The prompt has to say what separates merging from summarizing, or the model will
    /// summarize — which for a resume bullet means dropping the metric that made it worth
    /// keeping.
    func testThePromptForbidsLosingSpecifics() {
        let instructions = AITransformKind.mergeRewrite.instructions.lowercased()
        XCTAssertTrue(instructions.contains("not summarizing"))
        for specific in ["numbers", "metrics", "names", "dates"] {
            XCTAssertTrue(
                instructions.contains(specific),
                "The prompt should name \(specific) among what must survive."
            )
        }
    }
}
