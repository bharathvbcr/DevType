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

    public init(trigger: String, typedAfter: String = "") {
        self.trigger = trigger
        self.typedAfter = typedAfter
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

    /// Text to erase after the trigger if the debounce timer fires right now, i.e. the user
    /// stopped typing part-way toward a longer trigger.
    public var pendingSuffix: String { typedAfter }

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

        let combined = typedAfter + typedNow

        // A newline or tab ends the word outright; nothing longer can follow, and waiting would
        // strand the expansion after the line was already submitted.
        if combined.contains(where: { $0.isNewline || $0 == "\t" }) {
            return .fire(suffix: combined)
        }

        return prefixIndex.hasViableExtension(after: trigger + combined)
            ? .keepWaiting(HeldExpansionState(trigger: trigger, typedAfter: combined))
            : .fire(suffix: combined)
    }
}
