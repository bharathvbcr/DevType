import XCTest
@testable import ExpanderEngine

final class StructuredSnippetSearchTests: XCTestCase {
    private func groups() -> [SnippetGroup] {
        [SnippetGroup(name: "Client Work", snippets: [
            SnippetModel(title: "Email signature", triggerKeyword: ";sig", replacementText: "Best regards, Ada", tags: ["billing", "client"]),
            SnippetModel(title: "Signature draft", triggerKeyword: ";draft", replacementText: "Regards best", enabled: false, tags: ["draft"]),
            SnippetModel(title: "Receipt image", triggerKeyword: ";receipt", replacementText: "", imagePath: "receipt.png")
        ])]
    }

    func testQuotedPhrasesStayContiguousAndPreserveHighlights() throws {
        let hits = SnippetSearch.run(query: "\"best regards\"", in: groups())
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertTrue(hit.highlights.contains(SearchHighlight(field: .content, ranges: [0..<12])))
        XCTAssertEqual(SnippetSearch.run(query: "best regards", in: groups()).count, 2)
    }

    func testFieldsComposeAcrossTitleGroupTagAndTrigger() {
        let cases = ["title:signature tag:billing", "group:\"Client Work\" trigger:sig", "content:\"best regards\"", "tag:CLIENT -tag:draft"]
        for query in cases {
            XCTAssertEqual(SnippetSearch.run(query: query, in: groups()).map(\.snippet.triggerKeyword), [";sig"], query)
        }
        XCTAssertTrue(SnippetSearch.run(query: "title:billing", in: groups()).isEmpty)
        XCTAssertTrue(SnippetSearch.run(query: "title:", in: groups()).isEmpty)
    }

    func testExclusionsAreLiteralAndCanStandAlone() {
        XCTAssertEqual(SnippetSearch.run(query: "signature -draft", in: groups()).map(\.snippet.triggerKeyword), [";sig"])
        XCTAssertEqual(SnippetSearch.run(query: "-is:disabled -is:image", in: groups()).map(\.snippet.triggerKeyword), [";sig"])
        XCTAssertEqual(SnippetSearch.run(query: "signature -sgn", in: groups()).count, 2, "negative fuzzy subsequences must not remove rows")
    }

    func testStateFiltersHonorGroupEnablementAndThePaletteAdmissionRule() {
        var library = groups()
        library[0].enabled = false
        XCTAssertEqual(SnippetSearch.run(query: "is:disabled", in: library).count, 3)
        XCTAssertTrue(SnippetSearch.run(query: "is:enabled", in: library).isEmpty)
        XCTAssertTrue(SnippetSearch.run(query: "is:disabled", in: library, includeDisabled: false).isEmpty)
        XCTAssertTrue(SnippetSearch.run(query: "is:unknown", in: library).isEmpty)
    }

    func testUnknownPrefixesRemainLiteralAndUnicodeFoldingStillWorks() {
        let library = [SnippetGroup(name: "G", snippets: [
            SnippetModel(title: "Résumé", triggerKeyword: ";resume", replacementText: "https://example.com \"hello\"", tags: ["仕事"])
        ])]
        for query in ["title:resume", "tag:仕事", "https://example.com", "\"\\\"hello\\\"\""] {
            XCTAssertEqual(SnippetSearch.run(query: query, in: library).count, 1, query)
        }
    }

    func testParserStressHandlesIncompleteQuotesEscapesAndOversizedUnicode() {
        let index = SnippetSearch.makeIndex(for: groups())
        let fragments = ["\"", "\\", "-", "tag:", "is:", "-group:", "仕事", "👩🏽‍💻", "\n", "sig"]
        for seed in 0..<2_000 {
            let query = (0..<(seed % 32)).map { fragments[(seed + $0 * 7) % fragments.count] }.joined(separator: " ")
            let first = SnippetSearch.run(query: query, index: index)
            XCTAssertEqual(first, SnippetSearch.run(query: query, index: index))
            XCTAssertLessThanOrEqual(first.count, 3)
        }
        let huge = "title:sig " + String(repeating: "a\u{301}", count: 50_000)
        _ = SnippetSearch.run(query: huge, index: index)
        XCTAssertLessThanOrEqual(SnippetSearch.cachedQueryCountForTesting, 128)
        XCTAssertLessThanOrEqual(SnippetSearch.queryCacheRingSizeForTesting, 256)
    }

    func testTermsBeyondTheLimitCannotSilentlyDropAnExclusion() {
        let prefix = Array(repeating: "signature", count: SnippetSearch.maximumQueryTerms).joined(separator: " ")
        XCTAssertEqual(SnippetSearch.run(query: prefix, in: groups()).count, 2)
        let query = prefix + " -title:signature"
        XCTAssertTrue(SnippetSearch.run(query: query, in: groups()).isEmpty)
        XCTAssertNil(SnippetSearch.score(snippet: groups()[0].snippets[0], needle: query))
    }

    func testBytesBeyondTheLimitCannotSilentlyDropAnExclusion() {
        let prefix = "signature" + String(repeating: " ", count: SnippetSearch.maximumQueryUTF8Bytes - 9)
        XCTAssertEqual(SnippetSearch.run(query: prefix, in: groups()).count, 2)
        let query = prefix + " -title:signature"
        XCTAssertTrue(SnippetSearch.run(query: query, in: groups()).isEmpty)
        XCTAssertNil(SnippetSearch.score(snippet: groups()[0].snippets[0], needle: query))
    }

    func testIncompleteExclusionsCannotWidenTheResults() {
        for query in ["-title:", "signature -tag:", "-is:", "-group:\"\""] {
            XCTAssertTrue(SnippetSearch.run(query: query, in: groups()).isEmpty, query)
        }
    }

    func testPaletteRejectsLongQueriesBeforeCacheLookupOrTruncation() {
        let library = groups()
        XCTAssertFalse(CommandPaletteCatalog.buildRows(query: "signature", groups: library, commandLimit: 0).isEmpty)
        let prefix = "signature" + String(repeating: " ", count: CommandPaletteCatalog.maximumQueryCharacters - 9)
        let query = prefix + " -title:signature"
        XCTAssertTrue(CommandPaletteCatalog.buildRows(query: query, groups: library, commandLimit: 0).isEmpty)
    }

    func testQueryIssuesRespectUnicodeByteAndTermBoundaries() {
        let exact = String(repeating: "é", count: SnippetSearch.maximumQueryUTF8Bytes / 2)
        XCTAssertNil(SnippetSearch.queryIssue(for: exact))
        XCTAssertEqual(SnippetSearch.queryIssue(for: exact + "é"), .tooLong)
        XCTAssertNil(SnippetSearch.queryIssue(for: "\"" + Array(repeating: "word", count: 20).joined(separator: " ") + "\""))
        XCTAssertEqual(SnippetSearch.queryIssue(for: Array(repeating: "word", count: 13).joined(separator: " ")), .tooManyTerms)
        XCTAssertEqual(SnippetSearch.queryIssue(for: "-tag:"), .incompleteFilter)
        XCTAssertNil(CommandPaletteCatalog.queryIssue(for: "> title:"), "Explicit command queries do not parse snippet filters")
        for language in AppLanguage.concreteCases {
            for key in ["search.issue.title", "search.issue.tooLong", "search.issue.tooManyTerms", "search.issue.incompleteFilter"] {
                XCTAssertNotNil(LocalizationManager.stringTable(for: language)[key])
            }
        }
    }

    func testAdversarialExclusionsNeverBroadenAcceptedQueries() {
        let index = SnippetSearch.makeIndex(for: groups())
        for seed in 0..<2_000 {
            let count = seed % 14 + 1
            let separator = [" ", "\t", "\n", "\u{3000}"][seed % 4]
            let query = Array(repeating: "is:enabled", count: count).joined(separator: separator)
                + separator + ["-tag:billing", "-tag:\"billing\""][seed % 2]
            let expected = count < SnippetSearch.maximumQueryTerms ? [";receipt"] : []
            XCTAssertEqual(SnippetSearch.run(query: query, index: index).map(\.snippet.triggerKeyword), expected)
        }
    }
}
