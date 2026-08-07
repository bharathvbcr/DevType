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

    /// One keystroke against a fresh hold on `trigger`.
    private func decide(_ trigger: String, _ typedNow: String) -> HeldExpansionState.Step {
        HeldExpansionState(trigger: trigger)
            .advance(typedNow: typedNow, isDelete: false, prefixIndex: realLibrary)
    }

    /// Typing toward the longer trigger keeps the hold alive, so `` `slmabout `` becomes reachable.
    func testTypingTowardTheLongerTriggerKeepsWaiting() {
        XCTAssertEqual(
            decide("`slm", "a"),
            .keepWaiting(HeldExpansionState(trigger: "`slm", typedAfter: "a"))
        )
    }

    /// The regression this must not cause: a trigger followed by an ordinary character still
    /// expands, exactly as immediate firing would have done.
    func testDivergentCharacterFiresTheHeldTriggerWithTheCharacter() {
        XCTAssertEqual(decide("`slm", "x"), .fire(suffix: "x"))
        XCTAssertEqual(decide("`slm", " "), .fire(suffix: " "))
        XCTAssertEqual(decide("`slm", "."), .fire(suffix: "."))
    }

    /// Return and Tab may have *submitted* the field, not just ended the word. Firing then
    /// erases from a field that has since been cleared, eating the next thing typed — so the
    /// hold is dropped instead. The cost is a literal trigger in the sent text; the alternative
    /// is destroying the next message.
    func testReturnAndTabDropTheHoldRatherThanFiringIntoASubmittedField() {
        XCTAssertEqual(decide("`slm", "\n"), .cancel)
        XCTAssertEqual(decide("`slm", "\r"), .cancel)
        XCTAssertEqual(decide("`slm", "\t"), .cancel)
    }

    /// Even part-way toward the longer trigger — `` `slmab `` + Return is still a submit.
    func testReturnDropsAHoldTypedPartWayTowardTheLongerTrigger() {
        XCTAssertEqual(
            HeldExpansionState(trigger: "`slm", typedAfter: "ab")
                .advance(typedNow: "\n", isDelete: false, prefixIndex: realLibrary),
            .cancel
        )
    }

    func testUnicodeSuffixSurvives() {
        XCTAssertEqual(decide("`slm", "🎓"), .fire(suffix: "🎓"))
    }

    /// Backspace edits the trigger itself, so the record no longer describes the field.
    /// The engine signals it via `isDelete` — a delete key contributes no characters.
    func testBackspaceCancelsTheHold() {
        XCTAssertEqual(
            HeldExpansionState(trigger: "`slm")
                .advance(typedNow: "", isDelete: true, prefixIndex: realLibrary),
            .cancel
        )
        XCTAssertEqual(
            HeldExpansionState(trigger: "`slm", typedAfter: "ab")
                .advance(typedNow: "", isDelete: true, prefixIndex: realLibrary),
            .cancel,
            "Backspacing part-way toward `slmabout must drop the hold, not expand it."
        )
    }

    /// A key that produced no characters (arrow, modifier chord) may have moved the caret;
    /// expanding afterwards would erase whatever now sits in front of it.
    func testKeystrokeWithNoCharactersCancelsTheHold() {
        XCTAssertEqual(
            HeldExpansionState(trigger: "`slm")
                .advance(typedNow: "", isDelete: false, prefixIndex: realLibrary),
            .cancel
        )
    }

    // MARK: - Accumulating across keystrokes

    /// Types `` `slm `` + `a`,`b`,`o`,`u`,`t` one keystroke at a time and returns each step.
    private func typeAfterHold(_ trigger: String, _ characters: [String]) -> [HeldExpansionState.Step] {
        var state = HeldExpansionState(trigger: trigger)
        var steps: [HeldExpansionState.Step] = []
        for character in characters {
            let step = state.advance(typedNow: character, isDelete: false, prefixIndex: realLibrary)
            steps.append(step)
            if case .keepWaiting(let next) = step { state = next }
        }
        return steps
    }

    /// The bug this guards: the hold used to recover "what was typed since" from a ring-buffer
    /// length delta. `CharacterRingBuffer` is fixed at 64 characters, so mid-paragraph the count
    /// is pinned at capacity, every delta read zero, and `` `slm `` silently never expanded.
    /// Accumulation must come from the keystrokes themselves.
    func testTypedCharactersAccumulateAcrossKeystrokes() {
        let steps = typeAfterHold("`slm", ["a", "b", "o", "u"])
        XCTAssertEqual(steps, [
            .keepWaiting(HeldExpansionState(trigger: "`slm", typedAfter: "a")),
            .keepWaiting(HeldExpansionState(trigger: "`slm", typedAfter: "ab")),
            .keepWaiting(HeldExpansionState(trigger: "`slm", typedAfter: "abo")),
            .keepWaiting(HeldExpansionState(trigger: "`slm", typedAfter: "abou"))
        ])
    }

    /// Diverging several characters in must still fire with every character typed meanwhile,
    /// or the user loses text that was already on screen.
    func testDivergingAfterSeveralKeystrokesFiresWithTheWholeSuffix() {
        let steps = typeAfterHold("`slm", ["a", "b", "!"])
        XCTAssertEqual(steps.last, .fire(suffix: "ab!"))
    }

    // MARK: - When a timeout may fire

    /// Stopping on `` `slm `` means the user meant `` `slm ``.
    func testAFreshHoldFiresOnTimeout() {
        XCTAssertTrue(HeldExpansionState(trigger: "`slm").mayFireOnTimeout)
    }

    /// The regression the user hit: typing `` `slmabout `` needed every keystroke inside the
    /// 250 ms window, so one hesitation mid-word fired `` `slm `` and left `about` stranded —
    /// the field read `ScholarLMabout`. Once characters are typed toward a longer trigger, no
    /// timeout may fire; the hold waits for a keystroke that actually decides.
    func testAHoldTypedOnwardNeverFiresOnTimeout() {
        for partial in ["a", "ab", "abou"] {
            XCTAssertFalse(
                HeldExpansionState(trigger: "`slm", typedAfter: partial).mayFireOnTimeout,
                "`slm\(partial) is on the way to `slmabout — a timeout must not fire `slm."
            )
        }
    }

    /// Pausing part-way through a longer trigger must leave the hold alive rather than
    /// resolving it, so resuming still reaches `` `slmabout ``.
    func testPausingMidWordKeepsTheHoldAliveAndResumable() {
        var state = HeldExpansionState(trigger: "`slm")
        guard case .keepWaiting(let afterA) = state.advance(
            typedNow: "a",
            isDelete: false,
            prefixIndex: realLibrary
        ) else {
            return XCTFail("`slma should still be on the way to `slmabout.")
        }
        state = afterA
        XCTAssertFalse(state.mayFireOnTimeout, "A pause here must not fire `slm.")

        // …the user resumes after any length of pause.
        guard case .keepWaiting(let afterB) = state.advance(
            typedNow: "b",
            isDelete: false,
            prefixIndex: realLibrary
        ) else {
            return XCTFail("`slmab should still be on the way to `slmabout.")
        }
        XCTAssertEqual(afterB.typedAfter, "ab")
    }

    /// A held expansion fired by a decisive keystroke must still erase everything typed
    /// during the hold — erasing only the trigger would leave the erase text mismatched
    /// against the field and the expansion would be refused.
    func testPendingSuffixCoversAFiredHold() {
        var state = HeldExpansionState(trigger: "`slm")
        XCTAssertEqual(state.pendingSuffix, "")
        for character in ["a", "b"] {
            guard case .keepWaiting(let next) = state.advance(
                typedNow: character,
                isDelete: false,
                prefixIndex: realLibrary
            ) else {
                return XCTFail("`slm\(character) should still be on the way to `slmabout.")
            }
            state = next
        }
        XCTAssertEqual(
            state.pendingSuffix,
            "ab",
            "A timer firing on `slmab must erase `slmab, not just `slm."
        )
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

    // MARK: - Where holding is safe at all

    /// A hold leaves the trigger in the field while the user keeps typing, so the erase must be
    /// *verifiable* when it finally runs. In an app whose AX cannot be believed the precondition
    /// degrades to a blind count-based backspace, which would eat the characters typed during
    /// the hold. Those apps must not debounce at all.
    func testAXOpaqueAppsDoNotHold() {
        for bundleID in [
            "com.tinyspeck.slackmacgap",   // Slack
            "com.google.Chrome",
            "com.microsoft.VSCode",
            "net.whatsapp.WhatsApp",
            "com.hnc.Discord",
            "com.anthropic.claudefordesktop"
        ] {
            XCTAssertFalse(
                EventTapEngine.canHoldMatch(bundleID: bundleID),
                "\(bundleID) cannot verify an erase, so it must not debounce."
            )
        }
    }

    /// An app with no known AX problem keeps the feature.
    func testAXTrustworthyAppsHold() {
        XCTAssertTrue(EventTapEngine.canHoldMatch(bundleID: "com.apple.TextEdit"))
    }

    /// Without a bundle ID the verdict cannot even be looked up, so holding is not safe.
    func testUnknownAppDoesNotHold() {
        XCTAssertFalse(EventTapEngine.canHoldMatch(bundleID: nil))
        XCTAssertFalse(EventTapEngine.canHoldMatch(bundleID: ""))
    }

    // MARK: - Timing

    /// 250 ms was tighter than an ordinary pause-and-continue: hesitating before the `a` of
    /// `` `slmabout `` fired `` `slm `` instead. The window has to comfortably exceed a natural
    /// mid-word pause, while staying short enough that `` `slm `` alone still feels instant.
    func testDebounceIntervalToleratesANaturalMidWordPause() {
        XCTAssertGreaterThanOrEqual(
            EventTapEngine.prefixDebounceInterval,
            0.5,
            "Below ~0.5 s a normal hesitation makes the longer trigger unreachable."
        )
        XCTAssertLessThanOrEqual(
            EventTapEngine.prefixDebounceInterval,
            0.75,
            "Past ~0.75 s the shorter trigger feels broken rather than merely delayed."
        )
    }

    /// A hold with no firing timer must still be bounded, or it outlives the context it was
    /// recorded against. Expiry cancels — it must never be long enough to be mistaken for a
    /// firing delay, nor short enough to interrupt someone mid-word.
    func testStaleHoldTimeoutIsBoundedAndCancelOnly() {
        XCTAssertGreaterThan(
            EventTapEngine.heldExpansionStaleTimeout,
            EventTapEngine.prefixDebounceInterval * 4,
            "Expiry must not race the debounce window."
        )
        XCTAssertLessThanOrEqual(EventTapEngine.heldExpansionStaleTimeout, 60)
    }
}
