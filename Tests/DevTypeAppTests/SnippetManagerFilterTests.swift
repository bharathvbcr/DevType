import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// The manager's free-text filter.
///
/// It searched trigger, title and body while `SnippetSearch` searched those *and* tags, so the
/// same library answered the same query differently depending on which field you typed into.
final class SnippetManagerFilterTests: XCTestCase {

    private func matches(_ snippet: SnippetModel, query: String) -> Bool {
        SnippetManagerFilter.matchingIDs(in: [SnippetGroup(name: "G", snippets: [snippet])], query: query).contains(snippet.id)
    }

    func testStructuredFiltersSeeGroupsAndDisabledSnippetsInTheManager() {
        let enabled = snippet(title: "Client signature", tags: ["client"])
        var disabled = snippet(title: "Draft signature", tags: ["draft"])
        disabled.enabled = false
        let groups = [SnippetGroup(name: "Client Work", snippets: [enabled, disabled])]
        XCTAssertEqual(SnippetManagerFilter.matchingIDs(in: groups, query: "group:\"Client Work\" -tag:draft"), [enabled.id])
        XCTAssertEqual(SnippetManagerFilter.matchingIDs(in: groups, query: "is:disabled"), [disabled.id])
    }

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
        XCTAssertTrue(matches(snippet(), query: ""))
    }

    func testTriggerTitleAndBodyStillMatch() {
        let s = snippet()
        XCTAssertTrue(matches(s, query: "sig"))
        XCTAssertTrue(matches(s, query: "signature"))
        XCTAssertTrue(matches(s, query: "regards"))
    }

    /// The gap this closes.
    func testATagMatches() {
        let s = snippet(tags: ["invoice"])
        XCTAssertTrue(
            matches(s, query: "invoice"),
            "typing a tag in the manager must find the snippet, as it does in the palette"
        )
    }

    func testAPartialTagMatches() {
        XCTAssertTrue(matches(snippet(tags: ["invoicing"]), query: "invoic"))
    }

    func testAnyOfSeveralTagsMatches() {
        let s = snippet(tags: ["alpha", "beta", "gamma"])
        for query in ["alpha", "beta", "gamma"] {
            XCTAssertTrue(matches(s, query: query))
        }
    }

    func testANonMatchingQueryStillMatchesNothing() {
        XCTAssertFalse(matches(snippet(tags: ["invoice"]), query: "zzz"))
    }

    /// The field lowercases before calling, but a tag imported from Espanso keeps its own case.
    func testTagMatchingIsCaseInsensitiveOnTheStoredSide() {
        XCTAssertTrue(matches(snippet(tags: ["Invoice"]), query: "invoice"))
    }

    func testAnUntaggedSnippetIsUnaffected() {
        let s = snippet()
        XCTAssertTrue(matches(s, query: "sig"))
        XCTAssertFalse(matches(s, query: "invoice"))
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

    // MARK: - Secrets is a navigation chip, not a filter

    /// `.secrets` must stay in the chip row: it is the manager's signpost to the independent
    /// Secrets collection, and dropping the button would strand users who look for it here.
    func testTheSecretsChipIsStillOfferedAndLabelledInEveryLanguage() {
        XCTAssertTrue(SnippetFilterChip.allCases.contains(.secrets))
        XCTAssertEqual(SnippetFilterChip.secrets.localizationKey, "manager.filter.secrets")
        for language in AppLanguage.concreteCases {
            XCTAssertNotNil(
                LocalizationManager.stringTable(for: language)["manager.filter.secrets"],
                "\(language.rawValue) is missing the Secrets chip label"
            )
        }
    }

    /// The chip navigates; it does not narrow. `loadSnippetGroups()` never yields a secret, so a
    /// secret filter could only ever render an empty table — the state is removed rather than
    /// guarded, and `listFilter` is where that is written down.
    func testTheSecretsChipHasNoListFilterAndEveryOtherChipDoes() {
        XCTAssertNil(SnippetFilterChip.secrets.listFilter)
        for chip in SnippetFilterChip.allCases where chip != .secrets {
            XCTAssertEqual(chip.listFilter?.chip, chip, "\(chip) must round-trip through its filter")
        }
    }

    /// Every filter the list can hold is reachable from exactly one chip, and none of them is
    /// the secrets chip. This is the invariant that keeps the filter switch exhaustive without
    /// an unreachable branch.
    func testEveryListFilterMapsBackToANonSecretChip() {
        let chips = SnippetListFilter.allCases.map(\.chip)
        XCTAssertEqual(Set(chips).count, chips.count, "two filters share one chip")
        XCTAssertFalse(chips.contains(.secrets))
        XCTAssertEqual(Set(chips), Set(SnippetFilterChip.allCases).subtracting([.secrets]))
    }

    /// Reordering is only safe on the unfiltered stored order. `.all` is the sole filter that
    /// exposes it, and that must not regress as filters are added.
    func testOnlyTheAllFilterPermitsManualReordering() {
        for filter in SnippetListFilter.allCases {
            XCTAssertEqual(
                SnippetReorderEligibility.isAllowed(
                    sortMode: .manual, hasConcreteGroup: true, filterText: "", filter: filter
                ),
                filter == .all,
                "\(filter) must not claim to expose the stored order"
            )
        }
    }

    // MARK: - Parity with the palette

    /// The manager matched the whole query as one substring of one field, so a multi-word
    /// query only worked when the words happened to be adjacent in that order, in a single
    /// field. Both of these found the snippet in the palette and nothing here.
    func testWordOrderAndCrossFieldQueriesMatchLikeThePalette() {
        let s = snippet(trigger: ":sig", title: "Email Signature", body: "Best regards, Bharath")
        XCTAssertTrue(
            matches(s, query: "sig email"),
            "Word order must not decide whether the manager finds a snippet."
        )
        XCTAssertTrue(
            matches(s, query: "signature best"),
            "A query spanning title and body must match, as it does in the palette."
        )
    }

    /// Filtering stays conjunctive: every word has to land somewhere. A manager filter is a
    /// narrowing tool, and forgiving an unmatched word here would widen the list instead.
    func testEveryWordMustStillMatchSomething() {
        let s = snippet(trigger: ":sig", title: "Email Signature", body: "Best regards")
        XCTAssertFalse(
            matches(s, query: "signature zzzz"),
            "An unmatched word must still exclude the snippet."
        )
    }

    func testOverLimitExclusionCannotLeaveRowsAvailableForBulkActions() {
        let s = snippet()
        let query = Array(repeating: "signature", count: 12).joined(separator: " ") + " -title:signature"
        XCTAssertFalse(matches(s, query: query))
    }

    /// The two searches must answer the same question. This fails the moment either side
    /// grows a rule the other lacks, which is how the tag gap arrived in the first place.
    func testManagerAndPaletteAgreeOnTheSameLibrary() {
        let s = snippet(trigger: ":sig", title: "Email Signature", body: "Best regards", tags: ["work"])
        let group = SnippetGroup(name: "G", snippets: [s])
        for query in ["sig", "email", "work", "sig email", "signature best", "zzz", "email zzz"] {
            let manager = matches(s, query: query)
            let palette = !SnippetSearch.run(query: query, in: [group]).isEmpty
            XCTAssertEqual(manager, palette, "manager and palette disagree on \"\(query)\"")
        }
    }
}
