import XCTest
import NaturalLanguage
@testable import ExpanderEngine

/// Coverage-based command ranking.
///
/// The palette used to score conjunctively: one unmatched word rejected the command outright,
/// so every natural-language query returned an empty list and the semantic index and
/// `conversationalBoost` — both applied only to commands that already scored — could never
/// run. These tests pin the replacement, including the rule that keeps it honest.
final class PaletteConversationalRankingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CommandUsageStatsStore.shared.resetAll()
        CommandPaletteCatalog.invalidateCache()
    }

    override func tearDown() {
        CommandUsageStatsStore.shared.resetAll()
        CommandPaletteCatalog.invalidateCache()
        super.tearDown()
    }

    // MARK: - The defect

    /// Each of these returned *zero* hits under conjunctive scoring.
    func testConversationalPhrasingsReachTheirCommand() {
        let cases: [(String, String)] = [
            ("make this sound polite", "ai.friendly"),
            ("tidy up my writing", "ai.rewrite"),
            ("shorten this a bit", "ai.condense"),
            ("make it nicer", "ai.friendly"),
            ("get rid of the typos", "ai.proofread"),
            ("turn this into a list", "ai.bulletize")
        ]
        for (query, expected) in cases {
            let hits = CommandPaletteCatalog.matchCommands(
                query: query,
                loc: .shared,
                semanticBoostIDs: CommandPaletteCatalog.semanticBoostIDs(for: query)
            )
            XCTAssertFalse(hits.isEmpty, "\"\(query)\" must return something.")
            XCTAssertEqual(
                hits.first?.command.id, expected,
                "\"\(query)\" should rank \(expected) first, got \(hits.first?.command.id ?? "none")."
            )
        }
    }

    // MARK: - The rule that keeps it honest

    /// An unmatched word is forgiven only when no command in the catalogue understands it.
    /// `polite` is a word nothing claims, so it costs coverage; `telugu` names a capability,
    /// so a command lacking it is not a candidate at all.
    func testCapabilityWordsVetoPartialMatchesButUnknownWordsDoNot() {
        let polite = CommandPaletteCatalog.matchCommands(query: "make this sound polite", loc: .shared)
        XCTAssertTrue(
            polite.contains { $0.command.id == "ai.formal" },
            "An unknown word like 'polite' must not veto a command that matched 'make'."
        )

        let telugu = CommandPaletteCatalog.matchCommands(query: "fix telugu", loc: .shared)
        XCTAssertFalse(
            telugu.contains { $0.command.id == "ai.proofread" },
            "Proofread must not advertise a language it cannot handle."
        )
    }

    /// The veto has to hold on the rescue path too, or the semantic pass reopens the door
    /// the lexical pass just closed.
    func testSemanticRescueCannotBypassTheCapabilityVeto() {
        let hits = CommandPaletteCatalog.matchCommands(
            query: "fix telugu",
            loc: .shared,
            semanticBoostIDs: ["ai.proofread", "ai.fixcode"]
        )
        XCTAssertFalse(
            hits.contains { $0.command.id == "ai.proofread" },
            "A rescued row must clear the same capability veto as a lexical one."
        )
    }

    // MARK: - Scoring shape

    /// Full coverage must score exactly what it scored before the change, so relaxing the
    /// gate could only *add* lower-ranked hits and never reorder existing ones.
    func testFullCoverageIsThePlainAverageAndOutranksPartial() {
        let full = CommandPaletteCatalog.combinedScore(
            termScores: [900, 800],
            discriminating: [false, false]
        )
        XCTAssertEqual(full, 850, "Full coverage must stay the plain mean of matched terms.")

        let partial = CommandPaletteCatalog.combinedScore(
            termScores: [900, nil],
            discriminating: [false, false]
        )
        XCTAssertNotNil(partial)
        XCTAssertLessThan(partial!, full!, "A partial match must never outrank a full one.")
        XCTAssertEqual(partial, 697, "coverage 0.5 → 900 * (0.55 + 0.45 * 0.5)")
    }

    /// A partial match needs one genuinely strong term. A lone weak blob hit is not evidence.
    func testWeakLoneTermDoesNotAdmitAPartialMatch() {
        XCTAssertNil(
            CommandPaletteCatalog.combinedScore(
                termScores: [400, nil],
                discriminating: [false, false]
            ),
            "A sub-threshold lone match must not admit the command."
        )
    }

    func testMissingADiscriminatingTermIsFatal() {
        XCTAssertNil(
            CommandPaletteCatalog.combinedScore(
                termScores: [1000, nil],
                discriminating: [false, true]
            ),
            "Missing a term the catalogue understands must veto, however strong the rest."
        )
    }

    // MARK: - Semantic rescue

    /// Before this, `semanticBoostIDs` could only reorder commands the lexical pass had
    /// already admitted — so a semantically obvious command sharing no token with the query
    /// was unreachable no matter how close it sat in embedding space.
    func testSemanticRescueSurfacesACommandWithNoSharedToken() {
        let query = "zzzz qqqq"
        let unrescued = CommandPaletteCatalog.matchCommands(query: query, loc: .shared)
        XCTAssertTrue(unrescued.isEmpty, "Precondition: nothing matches this lexically.")

        let rescued = CommandPaletteCatalog.matchCommands(
            query: query,
            loc: .shared,
            semanticBoostIDs: ["ai.condense"]
        )
        XCTAssertEqual(rescued.first?.command.id, "ai.condense")
    }

    /// A rescued row must sit below the weakest possible lexical hit, so it fills the tail
    /// rather than displacing a command the user actually spelled.
    func testRescueScoreStaysBelowTheWeakestLexicalHit() {
        let weakestLexical = Int(
            Double(CommandPaletteCatalog.minimumPartialTermScore)
                * CommandPaletteCatalog.partialCoverageFloor
        )
        XCTAssertLessThan(
            CommandPaletteCatalog.semanticRescueBaseScore,
            weakestLexical,
            "Rescue must not outrank a real lexical match."
        )
    }

    // MARK: - Personalization weighting

    /// The typed-query path used to apply usage weight only when a caller injected the
    /// closure, while the empty-query path fell back to the shared store. A caller that
    /// forgot the closure silently lost personalization with no symptom.
    func testTypedQueryAppliesUsageWeightWithoutAnInjectedClosure() {
        let before = CommandPaletteCatalog.matchCommands(query: "formal", loc: .shared)
            .first { $0.command.id == "ai.formal" }?.score
        XCTAssertNotNil(before)

        for _ in 0..<20 { CommandUsageStatsStore.shared.recordUsage(for: "ai.formal") }
        CommandPaletteCatalog.invalidateCache()

        let after = CommandPaletteCatalog.matchCommands(query: "formal", loc: .shared)
            .first { $0.command.id == "ai.formal" }?.score
        XCTAssertNotNil(after)
        XCTAssertGreaterThan(
            after!, before!,
            "Usage must weight a typed query even with no injected boost closure."
        )
    }

    /// An injected closure still wins, so a caller can scope personalization to its own store.
    func testInjectedBoostClosureOverridesTheSharedStore() {
        for _ in 0..<20 { CommandUsageStatsStore.shared.recordUsage(for: "ai.formal") }
        CommandPaletteCatalog.invalidateCache()

        let shared = CommandPaletteCatalog.matchCommands(query: "formal", loc: .shared)
            .first { $0.command.id == "ai.formal" }?.score
        let zeroed = CommandPaletteCatalog.matchCommands(
            query: "formal", loc: .shared, commandUsageBoost: { _ in 0 }
        ).first { $0.command.id == "ai.formal" }?.score

        XCTAssertNotNil(shared)
        XCTAssertNotNil(zeroed)
        XCTAssertGreaterThan(shared!, zeroed!, "An injected closure must take precedence.")
    }

    /// Habit was the weakest signal in the palette: capped at 12 against a semantic boost of
    /// up to 80. The ceiling now sits in the same range as similarity.
    func testUsageWeightCeilingIsComparableToTheSemanticBoost() {
        XCTAssertEqual(CommandUsageStatsStore.maximumRankBoost, 24)
        for _ in 0..<4096 { CommandUsageStatsStore.shared.recordUsage(for: "tool.uuid") }
        XCTAssertEqual(
            CommandUsageStatsStore.shared.rankBoost(for: "tool.uuid"),
            CommandUsageStatsStore.maximumRankBoost,
            "Heavy use must reach the ceiling."
        )
        XCTAssertLessThanOrEqual(
            CommandPaletteCatalog.semanticBoostWeight,
            CommandUsageStatsStore.maximumRankBoost * 2,
            "Similarity must not dwarf habit the way 80-vs-12 did."
        )
    }

    // MARK: - Semantic index

    /// Vectors are only comparable inside the space that produced them, so the index must
    /// pick one space for both the query and the commands — never mix them.
    func testEmbeddingSpaceIsChosenPerQueryLanguage() {
        XCTAssertNotNil(
            PaletteSemanticIndex.embedding(for: "make this shorter"),
            "An English query must resolve an embedding space."
        )
        // Whatever a non-Latin query resolves to, it must not silently borrow the English
        // space: a vector from one space scored against another is a meaningless number.
        if let (_, key) = PaletteSemanticIndex.embedding(for: "これを短くして") {
            XCTAssertNotEqual(key, NLLanguage.english.rawValue)
        }
    }

    /// Stopwords pulled every query toward the centroid of the language, which is how three
    /// unrelated queries all came back with `ai.explainregex` as the nearest command.
    func testSemanticNeighboursAreNoLongerDominatedByOneCommand() {
        let queries = ["tidy up my writing", "shorten this a bit", "make this sound polite"]
        let firsts = queries.compactMap {
            CommandPaletteCatalog.semanticBoostIDs(for: $0).first
        }
        XCTAssertEqual(firsts.count, queries.count, "Every query should have a neighbour.")
        XCTAssertGreaterThan(
            Set(firsts).count, 1,
            "Distinct queries must not all collapse to the same nearest command."
        )
    }
}
