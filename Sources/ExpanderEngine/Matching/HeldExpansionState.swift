import Foundation

/// The lifetime of one held (prefix-debounced) match, as a pure value.
///
/// `AbbreviationMatcher` fires the longest trigger available *at this instant*, which is not the
/// longest trigger the user is *mid-way through typing*: after `` `slm `` the buffer holds exactly
/// `` `slm ``, so `` `slm `` fires and `` `slmabout `` can never be reached. The engine therefore
/// holds an ambiguous match for a moment and feeds each following keystroke through here.
///
/// Two things live in this type, and both are the reason it is a value type rather than fields on
/// the engine:
///
///   * **What was typed after the trigger.** Accumulated from the keystrokes themselves. Deriving
///     it from a ring-buffer length delta does not work — `CharacterRingBuffer` is fixed at 64
///     characters, so mid-paragraph its `count` is pinned at capacity and every delta reads zero,
///     which silently drops the held expansion instead of firing it.
///   * **Whether to keep waiting.** A held trigger must never be lost: if no longer trigger can
///     follow, it fires with whatever was typed meanwhile, so the field ends up exactly as
///     immediate firing would have left it.
public struct HeldExpansionState: Equatable, Sendable {
    /// Trigger exactly as it sits in the field (`SnippetMatch.fieldText`).
    public let trigger: String
    /// Characters typed after the trigger since the hold began.
    public let typedAfter: String
    /// §8.5: `trigger + typedAfter` spelled out a *complete longer trigger* at some point during
    /// this hold. Normally unreachable — the matcher expands the longer trigger itself and the
    /// hold is cancelled as `longerTriggerWon` before `advance` ever sees the keystroke — so a
    /// set flag means the matcher declined what the index recognizes (app-scoped elsewhere, case
    /// mismatch, a divergent buffer). From that point the shorter trigger may **never** fire:
    /// the user visibly typed the longer trigger, and `shorter + suffix` would fabricate an
    /// expansion they did not intend. The hold resolves by cancellation instead — the trigger
    /// stays literal, which is the failure mode this engine always prefers.
    public let passedThroughLongerTrigger: Bool

    public init(trigger: String, typedAfter: String = "", passedThroughLongerTrigger: Bool = false) {
        self.trigger = trigger
        self.typedAfter = typedAfter
        self.passedThroughLongerTrigger = passedThroughLongerTrigger
    }

    /// What one keystroke does to the hold.
    public enum Step: Equatable, Sendable {
        /// The caret moved or the trigger was edited — the record no longer describes the text
        /// in front of the caret, so it must be dropped rather than expanded.
        case cancel
        /// The buffer can still grow into a longer trigger. Re-arm with this state, so the
        /// debounce window measures the gap *between* keystrokes rather than the whole word.
        case keepWaiting(HeldExpansionState)
        /// No longer trigger can follow. Erase the trigger plus `suffix` and re-append `suffix`
        /// after the expansion.
        case fire(suffix: String)
    }

    /// Text to erase after the trigger if the hold is fired right now.
    public var pendingSuffix: String { typedAfter }

    /// Whether a debounce timeout may fire this hold.
    ///
    /// Only true before anything is typed after the trigger. Stopping on `` `slm `` means the
    /// user meant `` `slm ``. Stopping on `` `slma `` does not mean they meant `` `slm `` then
    /// `a` — they are part-way through `` `slmabout ``, and firing on a timeout there yields
    /// `ScholarLM` with `about` stranded after it.
    public var mayFireOnTimeout: Bool { typedAfter.isEmpty }

    /// Advances the hold by one keystroke.
    ///
    /// - Parameters:
    ///   - typedNow: characters this keystroke put in the field, taken from the event rather
    ///     than from the match buffer.
    ///   - isDelete: whether the keystroke was a backspace.
    public func advance(
        typedNow: String,
        isDelete: Bool,
        prefixIndex: TriggerPrefixIndex
    ) -> Step {
        // Backspace edits the trigger itself, and a key that produced no characters (arrow,
        // modifier chord) may have moved the caret.
        guard !isDelete, !typedNow.isEmpty else { return .cancel }

        // Return and Tab do not merely end the word — in a chat box or a form they *submit* it.
        // By the time the keystroke is seen the text may already be gone, and firing then would
        // erase from a field that has since been cleared, eating whatever the user types next.
        // Dropping the hold costs a literal `` `slm `` in the sent message; firing it risks
        // destroying the next message. Only reachable because the hold delayed the expansion —
        // without the debounce the trigger had already fired keystrokes earlier.
        if typedNow.contains(where: { $0.isNewline || $0 == "\t" }) {
            return .cancel
        }

        let combined = typedAfter + typedNow
        let full = trigger + combined

        // §8.5: two distinct questions about `full`, and both must keep the hold alive:
        //   * could it still GROW into a longer trigger? (mid-word — keep waiting)
        //   * did it just BECOME a longer trigger? (completion — the matcher owns expanding it;
        //     if the matcher declined, firing the shorter fabricates `shorter + suffix` over
        //     text the user typed as the longer trigger)
        // `hasViableExtension` alone answers only the first — `` `slml `` strictly extends
        // nothing, so on the final `l` it reads as a dead end and the old code fired
        // `` `slm `` + "l".
        let completedLongerTrigger = passedThroughLongerTrigger || prefixIndex.isCompleteTrigger(full)

        if prefixIndex.hasViableExtension(after: full) || prefixIndex.isCompleteTrigger(full) {
            return .keepWaiting(HeldExpansionState(
                trigger: trigger,
                typedAfter: combined,
                passedThroughLongerTrigger: completedLongerTrigger
            ))
        }

        // Diverged with no completion in sight. If a longer trigger was ever spelled out during
        // this hold, the shorter must not fire — resolve to nothing and leave the text literal.
        return passedThroughLongerTrigger ? .cancel : .fire(suffix: combined)
    }
}
