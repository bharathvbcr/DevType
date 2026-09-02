import XCTest
@testable import ExpanderEngine

/// Bounds on what a single query may cost.
///
/// Coverage scoring removed the old conjunctive early exit: the previous scorer returned on
/// the first unmatched term, so a junk paste cost roughly one comparison per command, while
/// the replacement scores every term against every command to learn which terms the catalogue
/// understands. Measured before these caps, a 5,000-word paste took **3,027 ms** synchronously
/// on the keystroke path. These tests pin the ceiling that replaced it.
final class PaletteInputBoundsTests: XCTestCase {

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

    private func words(_ count: Int) -> String {
        (0..<count).map { "word\($0 % 97)" }.joined(separator: " ")
    }

    // MARK: - Structural bounds

    func testQueryIsClampedToTheCharacterCeiling() {
        let long = String(repeating: "a", count: CommandPaletteCatalog.maximumQueryCharacters * 3)
        XCTAssertEqual(
            CommandPaletteCatalog.boundedQuery(long).count,
            CommandPaletteCatalog.maximumQueryCharacters
        )
    }

    func testBoundedQueryStillTrimsAndLeavesNormalQueriesAlone() {
        XCTAssertEqual(CommandPaletteCatalog.boundedQuery("  make this formal  "), "make this formal")
    }

    func testTermCountIsCapped() {
        let many = (0..<500).map { "w\($0)" }
        XCTAssertEqual(
            CommandPaletteCatalog.contentTerms(many).count,
            CommandPaletteCatalog.maximumQueryTerms
        )
    }

    /// The cap must not disturb ordinary queries, which is the whole point of putting it well
    /// above anything a person types.
    func testOrdinaryQueriesAreUnaffectedByTheCap() {
        let terms = ["make", "this", "sound", "polite"]
        XCTAssertEqual(CommandPaletteCatalog.contentTerms(terms), ["make", "sound", "polite"])
        let query = "make this sound polite"
        XCTAssertEqual(
            CommandPaletteCatalog.matchCommands(
                query: query,
                loc: .shared,
                semanticBoostIDs: CommandPaletteCatalog.semanticBoostIDs(for: query)
            ).first?.command.id,
            "ai.friendly",
            "The cap must not disturb a query a person would actually type."
        )
    }

    // MARK: - Cost

    /// A wall-clock guard, deliberately loose. It sits ~6x below the 3,027 ms this cost before
    /// the cap and ~60x above what it costs now, so it catches a reintroduced unbounded scan
    /// without failing on a loaded machine.
    func testAHugeQueryStaysCheap() {
        let groups = [SnippetGroup(name: "W", snippets: (0..<50).map {
            SnippetModel(title: "t\($0)", triggerKeyword: ":t\($0)", replacementText: "body \($0)")
        })]
        CommandPaletteCatalog.invalidateCache()
        let start = Date()
        _ = CommandPaletteCatalog.buildRows(query: words(5000), groups: groups, loc: .shared)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 0.5,
            "A 5,000-word paste must not scale with its length on the keystroke path."
        )
    }

    /// The semantic pass runs per keystroke over the whole catalogue, so it needs the same
    /// ceiling — averaging a thousand pasted words says nothing a dozen would not.
    func testSemanticBoostStaysCheapOnAHugeQuery() {
        let start = Date()
        _ = CommandPaletteCatalog.semanticBoostIDs(for: words(5000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    /// Snippet search scans every term against every indexed field of every snippet.
    func testSnippetSearchTermsAreCapped() {
        XCTAssertEqual(SnippetSearch.maximumQueryTerms, CommandPaletteCatalog.maximumQueryTerms)
        let groups = [SnippetGroup(name: "W", snippets: (0..<200).map {
            SnippetModel(title: "t\($0)", triggerKeyword: ":t\($0)", replacementText: "body \($0)")
        })]
        let start = Date()
        _ = SnippetSearch.run(query: words(5000), in: groups)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
