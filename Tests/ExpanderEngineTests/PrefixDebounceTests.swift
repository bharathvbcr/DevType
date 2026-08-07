import XCTest
@testable import ExpanderEngine

/// Prefix debounce: hold a match briefly when a longer trigger could still win.
///
/// `AbbreviationMatcher` fires the longest trigger available *at this instant*, which is not the
/// longest trigger the user is *mid-way through typing*. After `` `slm `` the buffer holds
/// exactly `` `slm ``, so `` `slm `` fires and `` `slmabout `` is unreachable.
///
/// Two properties matter and are tested separately:
///   1. Only ambiguous triggers wait. Everything else must keep firing with zero added latency.
///   2. A held trigger is never silently lost — if no longer trigger can follow, it fires with
///      whatever was typed meanwhile, matching what immediate firing would have produced.
final class PrefixDebounceTests: XCTestCase {

    private func snippet(
        _ trigger: String,
        caseSensitive: Bool = false,
        requireWordBoundary: Bool = true,
        enabled: Bool = true
    ) -> SnippetModel {
        var s = SnippetModel(
            title: trigger,
            triggerKeyword: trigger,
            replacementText: "x",
            isCaseSensitive: caseSensitive,
            requireWordBoundary: requireWordBoundary
        )
        s.enabled = enabled
        return s
    }

    /// The library that motivated this.
    private var realLibrary: TriggerPrefixIndex {
        TriggerPrefixIndex(snippets: [
            snippet("`slm"), snippet("`slmabout"),
            snippet("`asu"), snippet("`asuid"),
            snippet("`mail"), snippet("`amail"), snippet("`imail"),
            snippet("`date"), snippet("`fdate")
        ])
    }

    // MARK: - Which triggers are ambiguous

    func testPrefixOfALongerTriggerIsAmbiguous() {
        let index = realLibrary
        XCTAssertTrue(index.isAmbiguous(trigger: "`slm", caseSensitive: false))
        XCTAssertTrue(index.isAmbiguous(trigger: "`asu", caseSensitive: false))
    }

    /// The critical performance property: everything else fires instantly.
    func testNonPrefixTriggersAreNotAmbiguous() {
        let index = realLibrary
        for trigger in ["`slmabout", "`asuid", "`mail", "`amail", "`imail", "`date", "`fdate"] {
            XCTAssertFalse(
                index.isAmbiguous(trigger: trigger, caseSensitive: false),
                "\(trigger) is extended by nothing and must not pay debounce latency."
            )
        }
    }

    func testSharedSuffixIsNotAmbiguity() {
        // `amail ends with `mail but does not start with it — no ambiguity, no delay.
        let index = TriggerPrefixIndex(snippets: [snippet("`mail"), snippet("`amail")])
        XCTAssertFalse(index.hasAnyAmbiguity)
    }

    func testEmptyLibraryHasNoAmbiguity() {
        XCTAssertFalse(TriggerPrefixIndex(snippets: []).hasAnyAmbiguity)
    }

    /// A trigger that waits for a terminator cannot shadow, so holding it would add latency for
    /// nothing.
    func testTerminatorRequiringTriggerIsNotAmbiguous() {
        let index = TriggerPrefixIndex(snippets: [
            snippet("slm", requireWordBoundary: true),
            snippet("slmabout", requireWordBoundary: true)
        ])
        XCTAssertFalse(index.isAmbiguous(trigger: "slm", caseSensitive: false))
    }

    func testWordTriggerWithoutBoundaryIsAmbiguous() {
        let index = TriggerPrefixIndex(snippets: [
            snippet("slm", requireWordBoundary: false),
            snippet("slmabout")
        ])
        XCTAssertTrue(index.isAmbiguous(trigger: "slm", caseSensitive: false))
    }

    func testDisabledLongerTriggerCreatesNoAmbiguity() {
        let index = TriggerPrefixIndex(snippets: [
            snippet("`slm"),
            snippet("`slmabout", enabled: false)
        ])
        XCTAssertFalse(
            index.isAmbiguous(trigger: "`slm", caseSensitive: false),
            "A disabled trigger can never fire, so nothing should wait for it."
        )
    }

    func testCaseInsensitiveTriggersFoldWhenDecidingAmbiguity() {
        let index = TriggerPrefixIndex(snippets: [snippet("`SLM"), snippet("`slmabout")])
        XCTAssertTrue(index.isAmbiguous(trigger: "`slm", caseSensitive: false))
        XCTAssertTrue(index.isAmbiguous(trigger: "`SLM", caseSensitive: false))
    }

    // MARK: - Viable extensions

    func testPartialWordTowardALongerTriggerIsViable() {
        let index = realLibrary
        for partial in ["`slm", "`slma", "`slmab", "`slmabou"] {
            XCTAssertTrue(
                index.hasViableExtension(after: partial),
                "\(partial) is still on the way to `slmabout — the hold must continue."
            )
        }
    }

    func testCompletedTriggerHasNoViableExtension() {
        XCTAssertFalse(
            realLibrary.hasViableExtension(after: "`slmabout"),
            "Nothing extends `slmabout, so waiting longer cannot change the outcome."
        )
    }

    func testDivergentInputHasNoViableExtension() {
        XCTAssertFalse(realLibrary.hasViableExtension(after: "`slmx"))
        XCTAssertFalse(realLibrary.hasViableExtension(after: "`slm "))
        XCTAssertFalse(realLibrary.hasViableExtension(after: "`slm."))
    }

    func testEmptyTextHasNoViableExtension() {
        XCTAssertFalse(realLibrary.hasViableExtension(after: ""))
    }

    // MARK: - The held decision

    private func decide(_ trigger: String, _ typedAfter: String) -> EventTapEngine.HeldExpansionDecision {
        EventTapEngine.decideHeldExpansion(
            trigger: trigger,
            typedAfter: typedAfter,
            prefixIndex: realLibrary
        )
    }

    /// Typing toward the longer trigger keeps the hold alive, so `` `slmabout `` becomes reachable.
    func testTypingTowardTheLongerTriggerKeepsWaiting() {
        XCTAssertEqual(decide("`slm", "a"), .keepWaiting)
        XCTAssertEqual(decide("`slm", "abou"), .keepWaiting)
    }

    /// The regression this must not cause: a trigger followed by an ordinary character still
    /// expands, exactly as immediate firing would have done.
    func testDivergentCharacterFiresTheHeldTriggerWithTheCharacter() {
        XCTAssertEqual(decide("`slm", "x"), .fireNow(suffix: "x"))
        XCTAssertEqual(decide("`slm", " "), .fireNow(suffix: " "))
        XCTAssertEqual(decide("`slm", "."), .fireNow(suffix: "."))
    }

    /// Reaching the full longer trigger is handled by the matcher, not here — but if this path
    /// is reached the hold must not keep waiting forever.
    func testCompletedLongerTriggerDoesNotKeepWaiting() {
        XCTAssertEqual(decide("`slm", "about"), .fireNow(suffix: "about"))
    }

    /// Return and Tab end the word outright; nothing longer can follow, and waiting would leave
    /// the expansion stranded after the line was submitted.
    func testNewlineAndTabFireImmediately() {
        XCTAssertEqual(decide("`slm", "\n"), .fireNow(suffix: "\n"))
        XCTAssertEqual(decide("`slm", "\t"), .fireNow(suffix: "\t"))
    }

    /// Multi-character suffixes are preserved verbatim so the field ends up byte-identical to
    /// what firing immediately would have produced.
    func testSuffixIsPreservedVerbatim() {
        guard case .fireNow(let suffix) = decide("`slm", "xy") else {
            return XCTFail("Expected the held trigger to fire.")
        }
        XCTAssertEqual(suffix, "xy")
    }

    func testUnicodeSuffixSurvives() {
        XCTAssertEqual(decide("`slm", "🎓"), .fireNow(suffix: "🎓"))
    }

    // MARK: - Ambiguity and the conflict report agree

    /// Two features read the same rule. If they disagree, one of them is lying to the user:
    /// the palette would warn about a dead trigger the engine actually waits for, or vice versa.
    func testAmbiguityMatchesPrefixShadowDetection() {
        let snippets = [
            snippet("`slm"), snippet("`slmabout"),
            snippet("`asu"), snippet("`asuid"),
            snippet("`mail"), snippet("`amail")
        ]
        let index = TriggerPrefixIndex(snippets: snippets)
        let shadowers = Set(
            SnippetStore.triggerConflicts(in: [SnippetGroup(name: "G", snippets: snippets)])
                .filter { $0.kind == .prefixShadow }
                .map(\.trigger)
        )
        for trigger in snippets.map(\.triggerKeyword) {
            XCTAssertEqual(
                index.isAmbiguous(trigger: trigger, caseSensitive: false),
                shadowers.contains(trigger),
                "\(trigger): debounce and conflict detection must agree about ambiguity."
            )
        }
    }

    // MARK: - Timing

    func testDebounceIntervalIsTheRequested250ms() {
        XCTAssertEqual(EventTapEngine.prefixDebounceInterval, 0.25, accuracy: 0.0001)
    }
}
