import XCTest
@testable import ExpanderEngine

/// §4.7 / §2.8 — the old scorer was a fixed `==` / `hasPrefix` / `contains` ladder that lowercased
/// the trigger, the title **and the full body** for every snippet on every keystroke. `sgn` could
/// not find `:signature`, `resume` could not find `résumé`, group names were display-only, and
/// there was no multi-term AND and no match ranges to highlight with.
final class SnippetSearchRankingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SnippetSearch.invalidateIndexCache()
    }

    override func tearDown() {
        SnippetSearch.invalidateIndexCache()
        super.tearDown()
    }

    // MARK: - Fixture

    private func snippet(
        _ trigger: String,
        title: String,
        body: String = "body",
        enabled: Bool = true
    ) -> SnippetModel {
        SnippetModel(
            title: title,
            triggerKeyword: trigger,
            replacementText: body,
            enabled: enabled
        )
    }

    private lazy var signature = snippet(":signature", title: "Email Signature", body: "Best regards")
    private lazy var resume = snippet(":resume", title: "Résumé Link", body: "https://example.com/cv")
    private lazy var clearWarnings = snippet(":cw", title: "Clear Warnings", body: "swiftlint --fix")
    private lazy var address = snippet(":addr", title: "Home Address", body: "1 Infinite Loop")
    private lazy var disabled = snippet(":off", title: "Disabled One", enabled: false)

    private lazy var groups: [SnippetGroup] = [
        SnippetGroup(name: "Work", snippets: [signature, clearWarnings, disabled]),
        SnippetGroup(name: "Personal", snippets: [resume, address]),
    ]

    private func hits(_ query: String, includeDisabled: Bool = true) -> [SearchHit] {
        SnippetSearch.run(query: query, in: groups, includeDisabled: includeDisabled, limit: nil)
    }

    private func triggers(_ query: String, includeDisabled: Bool = true) -> [String] {
        hits(query, includeDisabled: includeDisabled).map(\.snippet.triggerKeyword)
    }

    // MARK: - Exact / prefix behaviour still holds

    func testExactTriggerOutranksEverythingElse() {
        XCTAssertEqual(triggers(":signature").first, ":signature")
    }

    func testBareTriggerMatchesWithoutTheSigil() {
        // `sig` should find `:signature` — the leading `:` is a sigil, not part of the word.
        XCTAssertTrue(triggers("sig").contains(":signature"))
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(hits("").isEmpty)
        XCTAssertTrue(hits("   ").isEmpty)
    }

    func testNoMatchReturnsNothing() {
        XCTAssertTrue(hits("zzzzqqq").isEmpty)
    }

    // MARK: - §4.7 fuzzy subsequence

    func testFuzzySubsequenceFindsSignature() {
        // The headline example from the audit: `sgn` must find `:signature`.
        XCTAssertTrue(
            triggers("sgn").contains(":signature"),
            "Fuzzy subsequence matching is what makes `sgn` → `:signature` work"
        )
    }

    func testFuzzyIsStillOrderSensitive() {
        // A subsequence must appear left-to-right; `nsg` is not a subsequence of `signature`.
        XCTAssertFalse(triggers("nsg").contains(":signature"))
    }

    func testTitleAcronymMatch() {
        // Alfred / Raycast style: `cw` → "Clear Warnings".
        XCTAssertTrue(triggers("cw").contains(":cw"))
        let acronym = SnippetSearch.run(
            query: "clwa",
            in: [SnippetGroup(name: "Work", snippets: [clearWarnings])],
            includeDisabled: true
        )
        XCTAssertEqual(acronym.first?.snippet.triggerKeyword, ":cw")
    }

    // MARK: - §4.7 diacritic / case / width insensitivity

    func testDiacriticInsensitiveSearch() {
        XCTAssertTrue(
            triggers("resume").contains(":resume"),
            "`resume` must find the `Résumé Link` snippet"
        )
        XCTAssertTrue(triggers("résumé").contains(":resume"))
        XCTAssertTrue(triggers("RESUME").contains(":resume"))
    }

    func testDiacriticInsensitiveTitleMatch() {
        let onlyTitle = [SnippetGroup(name: "Personal", snippets: [
            snippet(":cv", title: "Résumé"),
        ])]
        let found = SnippetSearch.run(query: "resume", in: onlyTitle, includeDisabled: true)
        XCTAssertEqual(found.first?.snippet.triggerKeyword, ":cv")
    }

    func testWidthInsensitiveSearch() {
        // Full-width Latin, as produced by a Japanese IME.
        XCTAssertTrue(triggers("\u{FF53}\u{FF49}\u{FF47}").contains(":signature"))
    }

    // MARK: - §4.7 group names and multi-term AND

    func testGroupNameIsSearchable() {
        let found = triggers("personal")
        XCTAssertTrue(found.contains(":resume"))
        XCTAssertTrue(found.contains(":addr"))
        XCTAssertFalse(found.contains(":signature"))
    }

    func testMultipleTermsAreANDed() {
        // "home" matches the title, "personal" matches the group — both must hold.
        let both = triggers("home personal")
        XCTAssertEqual(both, [":addr"])

        // "home" + "work" cannot both hold for any snippet.
        XCTAssertTrue(hits("home work").isEmpty)
    }

    func testMultiTermIsWhitespaceTolerant() {
        XCTAssertEqual(triggers("  home    personal  "), [":addr"])
    }

    // MARK: - Body matches are last and weakest

    func testBodyMatchesRankBelowTriggerMatches() {
        let found = hits("infinite")
        XCTAssertEqual(found.first?.snippet.triggerKeyword, ":addr")
        XCTAssertEqual(found.first?.highlights.first?.field, .content)
    }

    // MARK: - Enabled filtering

    func testIncludeDisabledFlagIsHonoured() {
        XCTAssertTrue(triggers(":off", includeDisabled: true).contains(":off"))
        XCTAssertFalse(triggers(":off", includeDisabled: false).contains(":off"))
    }

    // MARK: - §4.7 highlights

    func testHighlightsPointAtTheOriginalUnfoldedText() {
        let hit = SnippetSearch.run(
            query: "resume",
            in: [SnippetGroup(name: "Personal", snippets: [resume])],
            includeDisabled: true
        ).first
        XCTAssertNotNil(hit)
        let highlight = hit?.highlights.first { $0.field == .trigger }
        XCTAssertNotNil(highlight, "A trigger match must carry a trigger highlight")
        XCTAssertEqual(highlight?.ranges.isEmpty, false)
        for range in highlight?.ranges ?? [] {
            XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
            XCTAssertLessThanOrEqual(range.upperBound, ":resume".count)
        }
    }

    func testUTF16RangeConversionAccountsForAstralCharacters() {
        let text = "😀abc"
        // Character range 1..<4 ("abc") starts after a 2-unit surrogate pair.
        let converted = SnippetSearch.utf16Ranges([1..<4], in: text)
        XCTAssertEqual(converted.count, 1)
        XCTAssertEqual(converted.first?.location, 2)
        XCTAssertEqual(converted.first?.length, 3)
    }

    func testUTF16RangeConversionDropsOutOfBoundsAndEmptyRanges() {
        XCTAssertTrue(SnippetSearch.utf16Ranges([], in: "abc").isEmpty)
        XCTAssertTrue(SnippetSearch.utf16Ranges([2..<2], in: "abc").isEmpty)
        XCTAssertTrue(SnippetSearch.utf16Ranges([0..<9], in: "abc").isEmpty)
    }

    // MARK: - §4.5 usage boost

    func testUsageBoostReordersTiesWithoutBeatingAnExactMatch() {
        let a = snippet(":dup1", title: "Alpha Note")
        let b = snippet(":dup2", title: "Alpha Note")
        let library = [SnippetGroup(name: "G", snippets: [a, b])]

        let unboosted = SnippetSearch.run(query: "alpha", in: library, includeDisabled: true)
        XCTAssertEqual(unboosted.count, 2)

        SnippetSearch.invalidateIndexCache()
        let boosted = SnippetSearch.run(
            query: "alpha",
            in: library,
            includeDisabled: true,
            limit: nil,
            boost: { $0 == b.id ? 50 : 0 }
        )
        XCTAssertEqual(boosted.first?.snippet.id, b.id, "The more-used snippet wins the tie")

        // …but an exact trigger match (1000) must still outrank any boost.
        SnippetSearch.invalidateIndexCache()
        let exact = SnippetSearch.run(
            query: ":dup1",
            in: library,
            includeDisabled: true,
            limit: nil,
            boost: { $0 == b.id ? 500 : 0 }
        )
        XCTAssertEqual(exact.first?.snippet.id, a.id)
    }

    // MARK: - Limits

    func testLimitTruncatesTheRankedList() {
        XCTAssertEqual(SnippetSearch.run(query: "e", in: groups, includeDisabled: true, limit: 1).count, 1)
    }

    // MARK: - §2.8 index caching must not leak between libraries

    func testCachedIndexIsInvalidatedWhenTheLibraryChanges() {
        let before = [SnippetGroup(name: "G", snippets: [snippet(":one", title: "One")])]
        XCTAssertEqual(SnippetSearch.run(query: "one", in: before, includeDisabled: true).count, 1)

        let after = [SnippetGroup(name: "G", snippets: [snippet(":two", title: "Two")])]
        XCTAssertTrue(
            SnippetSearch.run(query: "one", in: after, includeDisabled: true).isEmpty,
            "A stale cached index would still answer with the old library"
        )
    }

    // MARK: - Query-level caching

    func testQueryCacheReturnsCachedHitsForRepeatedQuery() {
        SnippetSearch.invalidateIndexCache()
        let group = [SnippetGroup(name: "G", snippets: [signature, resume])]

        let first = SnippetSearch.run(query: "sig", in: group, includeDisabled: true)
        let second = SnippetSearch.run(query: "sig", in: group, includeDisabled: true)
        XCTAssertEqual(first, second)

        // Invalidating cache drops cached query results too
        SnippetSearch.invalidateIndexCache()
        let third = SnippetSearch.run(query: "sig", in: group, includeDisabled: true)
        XCTAssertEqual(first, third)
    }
}
