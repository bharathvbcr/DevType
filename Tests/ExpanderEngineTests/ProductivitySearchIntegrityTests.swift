import XCTest
@testable import ExpanderEngine

final class ProductivitySearchIntegrityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SnippetSearch.invalidateIndexCache()
    }

    private func library(_ body: String = "alpha") -> [SnippetGroup] {
        [SnippetGroup(name: "Work", snippets: [
            SnippetModel(title: "Example", triggerKeyword: ";example", replacementText: body)
        ])]
    }

    func testIndependentLibrariesWithEqualRevisionsNeverShareResults() {
        let a = library("alpha")
        let b = library("omega")
        XCTAssertEqual(SnippetSearch.run(query: "alpha", in: a, revision: 1).count, 1)
        XCTAssertTrue(SnippetSearch.run(query: "alpha", in: b, revision: 1).isEmpty)
        XCTAssertEqual(SnippetSearch.run(query: "omega", in: b, revision: 1).first?.id, b[0].snippets[0].id)
    }

    func testSameLengthBodyEditWithoutTimestampChangeInvalidatesCache() {
        var groups = library()
        XCTAssertEqual(SnippetSearch.run(query: "alpha", in: groups).count, 1)
        groups[0].snippets[0].replacementText = "omega"
        XCTAssertTrue(SnippetSearch.run(query: "alpha", in: groups).isEmpty)
        XCTAssertEqual(SnippetSearch.run(query: "omega", in: groups).count, 1)
    }

    func testSearchResultsRefreshDeliveryMetadataEvenWhenSearchFieldsMatch() {
        var groups = library()
        _ = SnippetSearch.run(query: "example", in: groups)
        groups[0].snippets[0].includeApps = ["com.example.editor"]
        groups[0].snippets[0].isPlainText = false
        XCTAssertEqual(SnippetSearch.run(query: "example", in: groups).first?.snippet, groups[0].snippets[0])
    }

    func testCustomBoostFunctionsCannotReuseAnotherCallersRanking() {
        var groups = library()
        groups[0].snippets.append(SnippetModel(title: "Example", triggerKeyword: ";second", replacementText: "alpha"))
        let first = groups[0].snippets[0].id
        let second = groups[0].snippets[1].id
        let index = SnippetSearch.makeIndex(for: groups)
        XCTAssertEqual(SnippetSearch.run(query: "alpha", index: index, boost: { $0 == first ? 50 : 0 }, boostRevision: 1).first?.id, first)
        XCTAssertEqual(SnippetSearch.run(query: "alpha", index: index, boost: { $0 == second ? 50 : 0 }, boostRevision: 1).first?.id, second)
    }

    func testZeroLimitReturnsNoResults() {
        XCTAssertTrue(SnippetSearch.run(query: "example", in: library(), limit: 0).isEmpty)
    }

    func testConcurrentSearchIsIsolatedAcrossLibrariesAndCustomRankings() {
        let groups = (0..<8).map { library("body-\($0)") }
        DispatchQueue.concurrentPerform(iterations: 2_000) { iteration in
            let group = groups[iteration % groups.count]
            let hits = SnippetSearch.run(query: "example", in: group, boost: { _ in iteration % 2 == 0 ? Int.max : Int.min }, revision: 1)
            XCTAssertEqual(hits.first?.snippet, group[0].snippets[0])
            XCTAssertGreaterThanOrEqual(hits.first?.score ?? -1, 0)
        }
        XCTAssertLessThanOrEqual(SnippetSearch.cachedQueryCountForTesting, 128)
        XCTAssertLessThanOrEqual(SnippetSearch.queryCacheRingSizeForTesting, 256)
    }

    func testCallerOwnedIndexUsesItsOwnLocaleForQueries() {
        let groups = library("I")
        let index = SnippetSearch.makeIndex(for: groups, locale: Locale(identifier: "tr_TR"))
        XCTAssertEqual(SnippetSearch.run(query: "I", index: index).count, 1)
    }
}

// Kept separate so pre-fix traps can be demonstrated in isolated XCTest processes.
final class ProductivityNumericBoundaryTests: XCTestCase {
    func testNegativeSearchLimitReturnsNoResults() {
        let groups = [SnippetGroup(name: "G", snippets: [SnippetModel(title: "Example", triggerKeyword: ";example", replacementText: "alpha")])]
        XCTAssertTrue(SnippetSearch.run(query: "example", in: groups, limit: -1).isEmpty)
    }

    func testCalculatorAcceptsTheRoundedDoubleAboveIntMax() {
        XCTAssertFalse(PaletteTextOps.formatMathResult(Double(Int.max)).isEmpty)
    }

    func testExtremeCommandBoostDoesNotOverflow() {
        for query in ["", "upper", "change case"] {
            XCTAssertFalse(CommandPaletteCatalog.matchCommands(query: query, commandUsageBoost: { _ in Int.max }).isEmpty)
        }
    }
}
