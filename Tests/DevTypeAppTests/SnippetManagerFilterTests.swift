import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// The manager's free-text filter.
///
/// It searched trigger, title and body while `SnippetSearch` searched those *and* tags, so the
/// same library answered the same query differently depending on which field you typed into.
final class SnippetManagerFilterTests: XCTestCase {

    private func snippet(
        trigger: String = ":sig",
        title: String = "Signature",
        body: String = "Regards, Bharath",
        tags: [String] = []
    ) -> SnippetModel {
        var s = SnippetModel(title: title, triggerKeyword: trigger, replacementText: body)
        s.tags = tags
        return s
    }

    func testAnEmptyQueryMatchesEverything() {
        XCTAssertTrue(SnippetManagerFilter.matches(snippet(), query: ""))
    }

    func testTriggerTitleAndBodyStillMatch() {
        let s = snippet()
        XCTAssertTrue(SnippetManagerFilter.matches(s, query: "sig"))
        XCTAssertTrue(SnippetManagerFilter.matches(s, query: "signature"))
        XCTAssertTrue(SnippetManagerFilter.matches(s, query: "regards"))
    }

    /// The gap this closes.
    func testATagMatches() {
        let s = snippet(tags: ["invoice"])
        XCTAssertTrue(
            SnippetManagerFilter.matches(s, query: "invoice"),
            "typing a tag in the manager must find the snippet, as it does in the palette"
        )
    }

    func testAPartialTagMatches() {
        XCTAssertTrue(SnippetManagerFilter.matches(snippet(tags: ["invoicing"]), query: "invoic"))
    }

    func testAnyOfSeveralTagsMatches() {
        let s = snippet(tags: ["alpha", "beta", "gamma"])
        for query in ["alpha", "beta", "gamma"] {
            XCTAssertTrue(SnippetManagerFilter.matches(s, query: query))
        }
    }

    func testANonMatchingQueryStillMatchesNothing() {
        XCTAssertFalse(SnippetManagerFilter.matches(snippet(tags: ["invoice"]), query: "zzz"))
    }

    /// The field lowercases before calling, but a tag imported from Espanso keeps its own case.
    func testTagMatchingIsCaseInsensitiveOnTheStoredSide() {
        XCTAssertTrue(SnippetManagerFilter.matches(snippet(tags: ["Invoice"]), query: "invoice"))
    }

    func testAnUntaggedSnippetIsUnaffected() {
        let s = snippet()
        XCTAssertTrue(SnippetManagerFilter.matches(s, query: "sig"))
        XCTAssertFalse(SnippetManagerFilter.matches(s, query: "invoice"))
    }

    // MARK: - The chip

    func testTheTaggedChipHasALocalizationKey() {
        XCTAssertEqual(SnippetFilterChip.tagged.localizationKey, "manager.filter.tagged")
        for language in AppLanguage.concreteCases {
            XCTAssertNotNil(
                LocalizationManager.stringTable(for: language)["manager.filter.tagged"],
                "\(language.rawValue) is missing the Tagged chip label"
            )
        }
    }

    /// Raw values are persisted as the selected chip, so a reordering would silently change
    /// which filter a returning user sees.
    func testTheNewChipWasAppendedRatherThanInserted() {
        XCTAssertEqual(SnippetFilterChip.all.rawValue, 0)
        XCTAssertEqual(SnippetFilterChip.unused.rawValue, 7)
        XCTAssertEqual(SnippetFilterChip.tagged.rawValue, 8)
    }

    // MARK: - Parity with the palette

    /// The manager matched the whole query as one substring of one field, so a multi-word
    /// query only worked when the words happened to be adjacent in that order, in a single
    /// field. Both of these found the snippet in the palette and nothing here.
    func testWordOrderAndCrossFieldQueriesMatchLikeThePalette() {
        let s = snippet(trigger: ":sig", title: "Email Signature", body: "Best regards, Bharath")
        XCTAssertTrue(
            SnippetManagerFilter.matches(s, query: "sig email"),
            "Word order must not decide whether the manager finds a snippet."
        )
        XCTAssertTrue(
            SnippetManagerFilter.matches(s, query: "signature best"),
            "A query spanning title and body must match, as it does in the palette."
        )
    }

    /// Filtering stays conjunctive: every word has to land somewhere. A manager filter is a
    /// narrowing tool, and forgiving an unmatched word here would widen the list instead.
    func testEveryWordMustStillMatchSomething() {
        let s = snippet(trigger: ":sig", title: "Email Signature", body: "Best regards")
        XCTAssertFalse(
            SnippetManagerFilter.matches(s, query: "signature zzzz"),
            "An unmatched word must still exclude the snippet."
        )
    }

    /// The two searches must answer the same question. This fails the moment either side
    /// grows a rule the other lacks, which is how the tag gap arrived in the first place.
    func testManagerAndPaletteAgreeOnTheSameLibrary() {
        let s = snippet(trigger: ":sig", title: "Email Signature", body: "Best regards", tags: ["work"])
        let group = SnippetGroup(name: "G", snippets: [s])
        for query in ["sig", "email", "work", "sig email", "signature best", "zzz", "email zzz"] {
            let manager = SnippetManagerFilter.matches(s, query: query)
            let palette = !SnippetSearch.run(query: query, in: [group]).isEmpty
            XCTAssertEqual(manager, palette, "manager and palette disagree on \"\(query)\"")
        }
    }
}
