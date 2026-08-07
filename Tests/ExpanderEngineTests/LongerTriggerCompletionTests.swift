import XCTest
@testable import ExpanderEngine

/// §8.5 — a longer trigger *completing* must never be resolved as the shorter trigger firing.
///
/// Field incident (2026-08-07, the user's real library: `` `slm `` → "ScholarLM" and
/// `` `slml `` → a URL, both case-sensitive, both punctuation-started): a hold armed at
/// `` `slm `` was resolved by the next `l` as "dead end — fire `` `slm `` + suffix", printing
/// `ScholarLMl` instead of the URL. Root cause: `hasViableExtension` counts only *strictly
/// longer* triggers, so text that has just spelled a longer trigger **exactly** read as a dead
/// end, and `advance` had no concept of completion.
///
/// Two layers own the answer, tested in this order:
///  1. The matcher is the authority: on the completing keystroke it matches the longer trigger,
///     the hold is cancelled `longerTriggerWon`, and the longer expansion runs. (The primary
///     path — this is what the walk tests pin.)
///  2. If the matcher declines what the index recognizes (degraded path — case mismatch,
///     app-scoped snippet, divergent buffer), the hold must keep waiting and then resolve to
///     *nothing*: the trigger stays literal. It must never fabricate `shorter + suffix` over
///     text the user visibly typed as the longer trigger.
final class LongerTriggerCompletionTests: XCTestCase {

    private func snippet(
        _ trigger: String,
        replacement: String = "x",
        caseSensitive: Bool = false,
        requireWordBoundary: Bool = true
    ) -> SnippetModel {
        var s = SnippetModel(
            title: trigger,
            triggerKeyword: trigger,
            replacementText: replacement,
            isCaseSensitive: caseSensitive,
            requireWordBoundary: requireWordBoundary
        )
        s.enabled = true
        return s
    }

    /// The user's actual library shape at the time of the incident.
    private var scholarLibrary: [SnippetModel] {
        [
            snippet("`slm", replacement: "ScholarLM", caseSensitive: true),
            snippet("`slml", replacement: "https://scholarlm.dev/", caseSensitive: true),
            snippet("`aboutslm", replacement: "https://scholarlm.dev/about", caseSensitive: false)
        ]
    }

    // MARK: - Walk harness (mirrors the tap callback's order exactly)

    private enum WalkEvent: Equatable {
        case expandedImmediately(trigger: String)
        case held(trigger: String)
        case holdFired(trigger: String, suffix: String)
        case holdCancelled(HeldExpansionCoordinator<Int>.CancelReason)
    }

    /// Feeds keystrokes through the same sequence the engine uses: append to buffer → match →
    /// (longer-won cancel + hold-or-expand) on match, resolve the hold on no-match.
    private func walk(
        keys: [String],
        snippets: [SnippetModel]
    ) -> [WalkEvent] {
        let matcher = AbbreviationMatcher(snippets: snippets)
        let index = TriggerPrefixIndex(snippets: snippets)
        let coordinator = HeldExpansionCoordinator<Int>()
        var buffer: [Character] = []
        var events: [WalkEvent] = []

        for key in keys {
            buffer.append(contentsOf: key)
            if let match = matcher.match(characters: buffer) {
                if coordinator.cancelAll(reason: .longerTriggerWon) {
                    events.append(.holdCancelled(.longerTriggerWon))
                }
                if index.isAmbiguous(
                    trigger: match.matchedText,
                    caseSensitive: match.snippet.isCaseSensitive
                ) {
                    coordinator.arm(payload: 0, trigger: match.matchedText, focusPID: nil)
                    events.append(.held(trigger: match.matchedText))
                } else {
                    events.append(.expandedImmediately(trigger: match.snippet.triggerKeyword))
                    buffer.removeAll()   // endExpansion clears the ring buffer
                }
            } else {
                switch coordinator.resolveKeystroke(
                    typedNow: key,
                    isDelete: false,
                    prefixIndex: index
                ) {
                case .noHold:
                    break
                case .cancelled(let reason):
                    events.append(.holdCancelled(reason))
                case .rearmed:
                    break
                case .fire(let hold, let suffix):
                    events.append(.holdFired(trigger: hold.state.trigger, suffix: suffix))
                    buffer.removeAll()
                }
            }
        }
        return events
    }

    // MARK: - The incident, replayed

    /// Typing `` `slml `` must expand `` `slml `` — the hold at `` `slm `` steps aside when the
    /// final `l` completes the longer trigger.
    func testTypingTheLongerTriggerExpandsTheLongerTrigger() {
        let events = walk(keys: ["`", "s", "l", "m", "l"], snippets: scholarLibrary)
        XCTAssertEqual(
            events,
            [
                .held(trigger: "`slm"),
                .holdCancelled(.longerTriggerWon),
                .expandedImmediately(trigger: "`slml")
            ],
            "The `l` completes `` `slml `` — the matcher expands it and the shorter hold stands"
                + " down. `ScholarLMl` is the incident, not an acceptable outcome."
        )
    }

    /// Typing `` `slm `` then a space is the shorter trigger's legitimate keystroke-fire.
    func testShorterTriggerStillFiresOnADecisiveTerminator() {
        let events = walk(keys: ["`", "s", "l", "m", " "], snippets: scholarLibrary)
        XCTAssertEqual(
            events,
            [.held(trigger: "`slm"), .holdFired(trigger: "`slm", suffix: " ")]
        )
    }

    /// `` `aboutslm `` shares no prefix with `` `slm `` — it must expand instantly, no hold.
    func testUnrelatedLongerTriggerExpandsImmediately() {
        let events = walk(
            keys: ["`", "a", "b", "o", "u", "t", "s", "l", "m"],
            snippets: scholarLibrary
        )
        XCTAssertEqual(events, [.expandedImmediately(trigger: "`aboutslm")])
    }

    /// Dead-key style input: one event delivering two characters ("`s" composed together) must
    /// walk identically to two separate keystrokes.
    func testMultiCharacterEventsWalkTheSamePath() {
        let events = walk(keys: ["`s", "l", "m", "l"], snippets: scholarLibrary)
        XCTAssertEqual(
            events,
            [
                .held(trigger: "`slm"),
                .holdCancelled(.longerTriggerWon),
                .expandedImmediately(trigger: "`slml")
            ]
        )
    }

    // MARK: - The degraded path (matcher declines, index recognizes)

    /// If the completing keystroke reaches `resolveKeystroke` — the matcher missed for any
    /// reason — the hold must keep waiting, and a timeout may not fire it half-typed.
    func testCompletionReachingResolveKeepsTheHoldInsteadOfFiringTheShorter() {
        let index = TriggerPrefixIndex(snippets: scholarLibrary)
        let coordinator = HeldExpansionCoordinator<Int>()
        let armed = coordinator.arm(payload: 7, trigger: "`slm", focusPID: nil)

        switch coordinator.resolveKeystroke(typedNow: "l", isDelete: false, prefixIndex: index) {
        case .rearmed(let hold):
            XCTAssertTrue(hold.state.passedThroughLongerTrigger)
            XCTAssertNil(
                coordinator.claimForTimeout(generation: armed.generation),
                "The old generation is dead; nothing half-typed may fire on a timer."
            )
            XCTAssertNil(
                coordinator.claimForTimeout(generation: hold.generation),
                "typedAfter is non-empty — the completion hold may never fire by timeout either."
            )
        case let other:
            XCTFail("Completion must keep the hold waiting, got \(other)")
        }
    }

    /// After passing through a completed longer trigger, divergence resolves to *cancellation* —
    /// the shorter trigger must never fire with a suffix over it.
    func testDivergenceAfterCompletionCancelsRatherThanFiringTheShorter() {
        let index = TriggerPrefixIndex(snippets: scholarLibrary)
        let coordinator = HeldExpansionCoordinator<Int>()
        coordinator.arm(payload: 7, trigger: "`slm", focusPID: nil)

        guard case .rearmed = coordinator.resolveKeystroke(
            typedNow: "l", isDelete: false, prefixIndex: index
        ) else {
            return XCTFail("Completion must rearm")
        }
        switch coordinator.resolveKeystroke(typedNow: "q", isDelete: false, prefixIndex: index) {
        case .cancelled(let reason):
            XCTAssertEqual(reason, .editOrCaretMove)
        case let other:
            XCTFail("Post-completion divergence must cancel (literal text), got \(other)")
        }
        XCTAssertEqual(coordinator.telemetry.firedByKeystroke, 0)
    }

    /// Completion while a still-longer trigger also remains viable: the flag must stick, so a
    /// later divergence cancels instead of firing the shortest.
    func testCompletionFlagSurvivesContinuedViability() {
        let library = [
            snippet("`slm", caseSensitive: true),
            snippet("`slml", caseSensitive: true),
            snippet("`slmlong", caseSensitive: true)
        ]
        let index = TriggerPrefixIndex(snippets: library)
        let coordinator = HeldExpansionCoordinator<Int>()
        coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)

        guard case .rearmed(let afterL) = coordinator.resolveKeystroke(
            typedNow: "l", isDelete: false, prefixIndex: index
        ) else { return XCTFail("`slml completes and `slmlong stays viable — must rearm") }
        XCTAssertTrue(afterL.state.passedThroughLongerTrigger)

        guard case .rearmed(let afterO) = coordinator.resolveKeystroke(
            typedNow: "o", isDelete: false, prefixIndex: index
        ) else { return XCTFail("`slmlo is still viable toward `slmlong — must rearm") }
        XCTAssertTrue(afterO.state.passedThroughLongerTrigger, "The pass-through flag must stick.")

        switch coordinator.resolveKeystroke(typedNow: "x", isDelete: false, prefixIndex: index) {
        case .cancelled:
            break
        case let other:
            XCTFail("Diverging after passing `slml must cancel, got \(other)")
        }
    }

    /// Backspace after completion still cancels (the pre-existing rule outranks everything).
    func testBackspaceAfterCompletionCancels() {
        let index = TriggerPrefixIndex(snippets: scholarLibrary)
        let coordinator = HeldExpansionCoordinator<Int>()
        coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)
        _ = coordinator.resolveKeystroke(typedNow: "l", isDelete: false, prefixIndex: index)
        guard case .cancelled = coordinator.resolveKeystroke(
            typedNow: "", isDelete: true, prefixIndex: index
        ) else {
            return XCTFail("Backspace must cancel a completion hold")
        }
    }

    // MARK: - isCompleteTrigger semantics

    func testIsCompleteTriggerFoldsLikeTheMatcher() {
        let index = TriggerPrefixIndex(snippets: scholarLibrary)
        XCTAssertTrue(index.isCompleteTrigger("`slml"))
        XCTAssertTrue(index.isCompleteTrigger("`aboutslm"))
        XCTAssertTrue(
            index.isCompleteTrigger("`ABOUTSLM"),
            "Case-insensitive triggers are stored folded — any casing completes them."
        )
        XCTAssertFalse(index.isCompleteTrigger("`slmx"))
        XCTAssertFalse(index.isCompleteTrigger("slml"), "The backtick is part of the trigger.")
        XCTAssertFalse(index.isCompleteTrigger(""))
    }

    /// Telemetry decode contract for field reports: a longer trigger winning is its own bucket,
    /// no longer folded into `reset`.
    func testLongerTriggerWinsAreCountedSeparately() {
        let coordinator = HeldExpansionCoordinator<Int>()
        coordinator.arm(payload: 1, trigger: "`slm", focusPID: nil)
        coordinator.cancelAll(reason: .longerTriggerWon)
        coordinator.arm(payload: 2, trigger: "`slm", focusPID: nil)
        coordinator.cancelAll(reason: .bufferReset)

        let telemetry = coordinator.telemetry
        XCTAssertEqual(telemetry.cancelledLongerWon, 1)
        XCTAssertEqual(telemetry.cancelledByReset, 1)
        XCTAssertTrue(telemetry.summaryLine.contains("longer-won=1"))
    }
}
