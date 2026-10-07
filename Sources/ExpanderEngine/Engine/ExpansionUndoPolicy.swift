import Foundation

/// §3.1: the pure undo policy — when an expansion may leave an undo point, what delivery input
/// poisons a blind undo, how an undo widens over text typed after it, and when it refuses.
/// `TextInjectionPipeline` owns the record and the lock; everything here is a function of its
/// arguments, so every branch is reachable without a window server or a focused field.
public enum ExpansionUndoPolicy {

    /// §3.1: whether an expansion's end state supports an undo point at all. Every undo erase
    /// geometry rests on one premise: *the caret sits immediately after `injectedText`*. Trailing
    /// keys (Enter/Tab land after the text and may submit or move focus) and mid-text cursor
    /// placement both break that premise before the record is even written, so those expansions
    /// are not undoable. Pure for tests.
    static func undoPointAllowed(
        trailingKeys: [String],
        cursorOffset: Int?,
        totalUTF16: Int
    ) -> Bool {
        guard trailingKeys.isEmpty else { return false }
        if let cursorOffset, cursorOffset < totalUTF16 { return false }
        return true
    }

    /// Whether one pass-through key observed during delivery breaks the blind-undo premise.
    /// Pure for tests. Anything that types, deletes, or may move the caret contaminates; lone
    /// F-keys and modifier chords with no character are excluded so an innocent keypress cannot
    /// cost the user their undo in AX-opaque hosts.
    public static func deliveryPassThroughContaminatesBlindUndo(
        resetsCaret: Bool,
        isDelete: Bool,
        unicodeCount: Int
    ) -> Bool {
        resetsCaret || isDelete || unicodeCount > 0
    }

    /// §3.1d: contamination units contributed by one admitted event, pure for tests.
    ///
    /// The triggering key contributes 1 when it is field-touching on its own. A flush adds its
    /// replayed character count *even when the trigger is inert*: an F-key keyDown carries no
    /// unicode and moves no caret, but `TypeAheadBuffer.admit` still flushes the queue on it,
    /// and those replayed characters land mid-delivery at positions nothing can order against
    /// the paste. Uncounted, they broke the record's "caret sits right after the injected text"
    /// premise invisibly — the exact mis-erase shape this window exists to prevent.
    public static func deliveryInputUnits(keyContaminates: Bool, flushReplayCount: Int) -> Int {
        Saturating.adding(keyContaminates ? 1 : 0, max(0, flushReplayCount))
    }

    /// What a finished undo owes the caller's swallowed backspace. Pure for tests.
    ///
    /// The tap swallows a real backspace to attempt the undo (`return nil`). When the undo then
    /// refuses — selection active, unverifiable field, erased text gone — refusing while keeping
    /// the keystroke can turn the user's delete into a dead keypress. Preflight can return it
    /// only after checking the source context is still current; after mutation or a context
    /// change another delete would be unsafe. A programmatic undo owes no key.
    public enum UndoExit: Equatable {
        case accepted
        case refusedWithBackspaceReturned
        case refusedWithoutHeldKey
    }

    public static func classifyUndoExit(accepted: Bool, heldBackspace: SwallowedKey?) -> UndoExit {
        if accepted { return .accepted }
        return heldBackspace?.didSwallow == true
            ? .refusedWithBackspaceReturned
            : .refusedWithoutHeldKey
    }

    /// Characters the user may type after an expansion and still have undo work. Bounded so a
    /// stale record can never authorise erasing an unbounded amount of text.
    static let undoMaxTypedAfter = 16

    /// Widens the undo to cover text typed *after* the expansion.
    ///
    /// The naive plan erases exactly `injectedText` from the caret backwards, which assumes the
    /// caret is still where injection left it. Type one more character and the window shifts:
    /// for an injected "ScholarLM" followed by a typed "l", the check reads "cholarLMl" and
    /// refuses. Correct (erasing there would eat the wrong nine characters and strand an "S"),
    /// but the user's undo silently does nothing.
    ///
    /// So locate the injected text at its real offset, allowing up to `undoMaxTypedAfter`
    /// trailing characters, and undo the whole span — restoring the trigger *plus* what was
    /// typed after it, which is exactly what the field would hold had the expansion never run.
    ///
    /// Returns `nil` when the field is unreadable or the injected text is not found, leaving the
    /// caller on the original fail-closed path.
    static func widenedUndo(
        injectedText: String,
        triggerText: String,
        value: String?,
        caretLocation: Int?,
        maxTypedAfter: Int = undoMaxTypedAfter,
        originalCaretLocation: Int? = nil
    ) -> (plan: ErasePlan, restore: String)? {
        guard let value, let caret = caretLocation, caret >= 0, maxTypedAfter > 0 else { return nil }
        let limit = min(maxTypedAfter, undoMaxTypedAfter)
        let injected = Array(injectedText.utf16.prefix(DeliveryVerifier.maxVerificationScanUTF16 + 1))
        guard !injected.isEmpty, injected.count <= DeliveryVerifier.maxVerificationScanUTF16 else { return nil }
        let field = value.utf16
        guard caret <= field.count else { return nil }
        let lower = field.index(field.startIndex, offsetBy: max(0, caret - injected.count - limit))
        let upper = field.index(field.startIndex, offsetBy: caret)
        guard String.Index(upper, within: value) != nil else { return nil }
        let units = Array(field[lower..<upper])
        let localCaret = units.count

        let distances: ClosedRange<Int>
        if let originalCaretLocation {
            guard originalCaretLocation >= 0, originalCaretLocation < caret,
                  caret - originalCaretLocation <= limit else { return nil }
            let distance = caret - originalCaretLocation
            distances = distance...distance
        } else {
            distances = 1...limit
        }
        var match: (plan: ErasePlan, restore: String)?
        for k in distances {
            let end = localCaret - k
            let start = end - injected.count
            guard start >= 0, end <= units.count else { break }
            // Fold whitespace unit-by-unit: the host may have stored the injected text's spaces
            // as NBSP variants (Claude Desktop), and a raw unit comparison would never locate
            // the match — the undo would silently refuse in exactly the hosts it exists for.
            guard units[start..<end].elementsEqual(
                injected,
                by: { String.foldedWhitespaceUnit($0) == String.foldedWhitespaceUnit($1) }
            ) else { continue }
            let eraseStart = field.index(lower, offsetBy: start)
            guard String.Index(eraseStart, within: value) != nil else { continue }

            let tailSlice = Array(units[end..<localCaret])
            let typedAfter = String(utf16CodeUnits: tailSlice, count: tailSlice.count)
            // A newline may have submitted a form or moved focus; the text after it is not
            // safely ours to re-type.
            guard !typedAfter.contains(where: \.isNewline) else { return nil }
            guard match == nil else { return nil }
            match = (plan: ErasePlan(text: injectedText + typedAfter), restore: triggerText + typedAfter)
        }
        return match
    }

    enum UndoRefusal: String {
        case verification = "undo"
        case unreadable = "undoUnverifiable"
        case selection = "undoSelection"
        case originalPosition = "undoOriginalPosition"
    }

    enum UndoPreparation: Equatable {
        case replacement(ErasePlan, String)
        case refused(UndoRefusal)
    }

    /// After intervening input, only the recorded insertion boundary can identify which
    /// occurrence belongs to this expansion. Searching for the nearest equal substring can
    /// erase newly typed text (for example expanding to "aa", then typing another "aa").
    static func prepareUndo(
        record: TextInjectionPipeline.LastExpansion, originalRange: NSRange?, inputEvents: Int,
        field: (value: String?, caret: Int?, selection: Int?)
    ) -> UndoPreparation {
        if let selection = field.selection, selection > 0 { return .refused(.selection) }
        guard inputEvents >= 0 else { return .refused(.verification) }
        var plan = ErasePlan(text: record.injectedText)
        var restore = record.triggerText
        if inputEvents > 0 {
            guard let originalRange, originalRange.length == 0, originalRange.location >= 0 else {
                return .refused(.originalPosition)
            }
            guard let caret = field.caret, field.value != nil, field.selection == 0 else {
                return .refused(.unreadable)
            }
            if caret != originalRange.location {
                guard let widened = widenedUndo(
                    injectedText: record.injectedText, triggerText: record.triggerText,
                    value: field.value, caretLocation: caret, originalCaretLocation: originalRange.location
                ) else { return .refused(.verification) }
                plan = widened.plan
                restore = widened.restore
            }
        }
        let result = ErasePreconditionChecker.evaluate(
            plan: plan, value: field.value, caretLocation: field.caret, selectionLength: field.selection,
            insertionPointFollowsExpectedText: false
        )
        if undoEraseRefusalReason(result: result, inputEventsSinceExpansion: inputEvents) != nil {
            if case .unavailable = result { return .refused(.unreadable) }
            return .refused(.verification)
        }
        return .replacement(plan, restore)
    }

    /// §3.1: the undo erase policy, pure for tests. `nil` means proceed; a string is the refusal
    /// reason. `.mismatch` always refuses (readable field disagrees). `.unavailable` refuses only
    /// when input landed after the expansion — an opaque field plus a moved caret is exactly the
    /// blind mis-erase the "Sch`slm" incident proved, and no read can catch it downstream.
    static func undoEraseRefusalReason(
        result: ErasePreconditionResult,
        inputEventsSinceExpansion: Int
    ) -> String? {
        EraseExecutor.Intent.undo(inputEventsSinceExpansion: inputEventsSinceExpansion).refusalReason(result)
    }
}
