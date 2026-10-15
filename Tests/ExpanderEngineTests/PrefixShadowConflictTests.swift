import XCTest
@testable import ExpanderEngine

/// A trigger that fires without a terminator makes every longer trigger starting with it
/// unreachable — the short one fires on the keystroke that completes it, so the user never
/// gets to finish typing the long one.
///
/// This was invisible: both snippets look correct in the editor, `triggerConflicts()` reported
/// nothing, and the longer trigger simply never fired. Found in a real library where
/// `` `slm `` shadowed `` `slmabout `` and `` `asu `` shadowed `` `asuid ``.
///
/// The asymmetry matters: only the **shorter** trigger's firing rule is relevant, because the
/// longer trigger is never reached to have its own rule evaluated.
final class PrefixShadowConflictTests: XCTestCase {

    private func conflicts(_ snippets: [SnippetModel]) -> [SnippetStore.TriggerConflict] {
        SnippetStore.triggerConflicts(in: [SnippetGroup(name: "G", snippets: snippets)])
            .filter { $0.kind == .prefixShadow }
    }

    // MARK: - Punctuation-started triggers bypass requireWordBoundary

    /// The reported bug. `AbbreviationMatcher` rule (1) fires punctuation-started triggers
    /// immediately and returns **before** the `requireWordBoundary` checks — so the flag being
    /// `true` (the default) does not save you.
    func testPunctuationStartedTriggerShadowsLongerOneDespiteWordBoundaryTrue() {
        let found = conflicts([
            prefixTriggerSnippet("`slm", requireWordBoundary: true),
            prefixTriggerSnippet("`slmabout", requireWordBoundary: true)
        ])

        XCTAssertEqual(found.count, 1, "Expected `slm to be reported as shadowing `slmabout.")
        XCTAssertEqual(found.first?.trigger, "`slm")
        XCTAssertEqual(found.first?.blockedTriggers, ["`slmabout"])
    }

    /// Guards the matcher/detector agreement: a word-started trigger with the boundary rule on
    /// needs a non-word terminator, and `t` in "slmabout" is a word character — so `slm` never
    /// fires while typing it and there is nothing to report.
    func testWordStartedTriggerWithBoundaryDoesNotShadow() {
        let found = conflicts([
            prefixTriggerSnippet("slm", requireWordBoundary: true),
            prefixTriggerSnippet("slmabout", requireWordBoundary: true)
        ])
        XCTAssertTrue(
            found.isEmpty,
            "A trigger that waits for a terminator cannot shadow — reporting it would be a false alarm."
        )
    }

    /// Rule (2): boundary off means instant fire, so a word-started trigger shadows too.
    func testWordStartedTriggerWithoutBoundaryDoesShadow() {
        let found = conflicts([
            prefixTriggerSnippet("slm", requireWordBoundary: false),
            prefixTriggerSnippet("slmabout", requireWordBoundary: true)
        ])
        XCTAssertEqual(found.first?.blockedTriggers, ["slmabout"])
    }

    // MARK: - Shape of the report

    func testOneShadowerReportsEveryTriggerItBlocks() {
        let found = conflicts([
            prefixTriggerSnippet("`slm"),
            prefixTriggerSnippet("`slmabout"),
            prefixTriggerSnippet("`slmdocs")
        ])
        XCTAssertEqual(found.count, 1, "One conflict per shadower, not one per victim.")
        XCTAssertEqual(found.first?.blockedTriggers, ["`slmabout", "`slmdocs"])
        // Shadower first, then the blocked ones — the UI relies on this ordering.
        XCTAssertEqual(found.first?.snippetIDs.count, 3)
    }

    func testSummaryNamesTheDeadTriggers() {
        let found = conflicts([prefixTriggerSnippet("`asu"), prefixTriggerSnippet("`asuid")])
        XCTAssertEqual(
            found.first?.blockedTriggerSummary,
            "`asuid",
            "The warning must name the dead trigger; a group name is not actionable."
        )
    }

    func testNonPrefixTriggersDoNotCollide() {
        // Common real-world shape: shared suffix, different prefixes. Must stay quiet.
        let found = conflicts([
            prefixTriggerSnippet("`mail"), prefixTriggerSnippet("`amail"), prefixTriggerSnippet("`imail"), prefixTriggerSnippet("`smail")
        ])
        XCTAssertTrue(found.isEmpty, "`amail does not start with `mail — no shadowing.")
    }

    func testIdenticalTriggersAreNotReportedAsPrefixShadow() {
        // That is `duplicateTrigger`'s job; reporting both would double-warn.
        let found = conflicts([prefixTriggerSnippet("`slm"), prefixTriggerSnippet("`slm")])
        XCTAssertTrue(found.isEmpty, "Equal-length triggers are duplicates, not prefix shadows.")
    }

    func testDisabledSnippetsNeitherShadowNorAreShadowed() {
        XCTAssertTrue(
            conflicts([prefixTriggerSnippet("`slm", enabled: false), prefixTriggerSnippet("`slmabout")]).isEmpty,
            "A disabled snippet cannot fire, so it cannot shadow."
        )
        XCTAssertTrue(
            conflicts([prefixTriggerSnippet("`slm"), prefixTriggerSnippet("`slmabout", enabled: false)]).isEmpty,
            "A disabled snippet is already unreachable; warning about it is noise."
        )
    }

    // MARK: - Case folding matches the matcher

    func testCaseInsensitiveTriggersFoldBeforeComparing() {
        let found = conflicts([
            prefixTriggerSnippet("`SLM", caseSensitive: false),
            prefixTriggerSnippet("`slmabout", caseSensitive: false)
        ])
        XCTAssertEqual(
            found.count, 1,
            "Case-insensitive keys fold to lowercase in the matcher, so `SLM shadows `slmabout."
        )
    }

    func testCaseSensitiveTriggerDoesNotShadowDifferentCasing() {
        let found = conflicts([
            prefixTriggerSnippet("`SLM", caseSensitive: true),
            prefixTriggerSnippet("`slmabout", caseSensitive: true)
        ])
        XCTAssertTrue(
            found.isEmpty,
            "Case-sensitive keys compare exactly — `SLM is not a prefix of `slmabout."
        )
    }

    // MARK: - The real library that surfaced this

    func testReproducesTheReportedLibraryShape() {
        let found = conflicts([
            prefixTriggerSnippet("`asu"), prefixTriggerSnippet("`asuid"),
            prefixTriggerSnippet("`slm"), prefixTriggerSnippet("`slmabout"),
            prefixTriggerSnippet("`lslm"), prefixTriggerSnippet("`scholarlm"), prefixTriggerSnippet("`srm"), prefixTriggerSnippet("`ssn")
        ])
        let pairs = found
            .map { "\($0.trigger)→\($0.blockedTriggers.joined(separator: ","))" }
            .sorted()
        XCTAssertEqual(pairs, ["`asu→`asuid", "`slm→`slmabout"])
    }

    /// Detection must agree with the matcher, not merely with itself: the shadowed trigger
    /// really is unreachable when typed in full.
    func testMatcherConfirmsTheShadowedTriggerNeverFires() {
        let short = prefixTriggerSnippet("`slm")
        let long = prefixTriggerSnippet("`slmabout")
        let matcher = AbbreviationMatcher(snippets: [short, long])

        // Typing the long trigger: the matcher fires the short one as soon as it completes.
        let atShort = matcher.match(buffer: "`slm")
        XCTAssertEqual(atShort?.snippet.triggerKeyword, "`slm")

        // By the time the full long trigger is present, the short one already fired and its
        // characters are gone from the field — the buffer state below can never occur in
        // practice, which is exactly why the long trigger is dead.
        XCTAssertFalse(
            conflicts([short, long]).isEmpty,
            "The matcher shadows it, so triggerConflicts() must report it."
        )
    }
}
