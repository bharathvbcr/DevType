import Foundation

/// Single source of truth for "what is about to be deleted from the user's field".
///
/// Two unit systems are involved and they are **not** interchangeable:
///
/// * AX selected-text ranges are measured in **UTF-16 code units**.
/// * A posted backspace (`kVK_Delete`) removes one **grapheme cluster**.
///
/// Feeding a UTF-16 count to the HID backspace path over-deletes for any trigger containing
/// emoji, astral-plane characters, or combining marks. `ErasePlan` carries both counts plus the
/// exact text we expect to find left of the caret so the erase can be *verified* before it runs.
public struct ErasePlan: Equatable {
    /// Exact text expected immediately left of the caret. `nil` when the match came from a path
    /// that cannot reconstruct it (physical Hangul fallback) — verification is then skipped.
    public let expectedText: String?
    /// UTF-16 code units to remove — AX selection width.
    public let utf16Count: Int
    /// Grapheme clusters to remove — number of backspaces to post.
    public let backspaceCount: Int
    /// Compare `expectedText` case-insensitively (case-insensitive snippets: user casing varies).
    public let caseInsensitive: Bool

    public init(
        expectedText: String?,
        utf16Count: Int,
        backspaceCount: Int,
        caseInsensitive: Bool = false
    ) {
        self.expectedText = expectedText
        self.utf16Count = max(0, utf16Count)
        self.backspaceCount = max(0, backspaceCount)
        self.caseInsensitive = caseInsensitive
    }

    /// Plan derived from known text — both counts stay consistent by construction.
    public init(text: String, caseInsensitive: Bool = false) {
        self.expectedText = text
        self.utf16Count = text.utf16.count
        self.backspaceCount = text.count
        self.caseInsensitive = caseInsensitive
    }

    /// Plan for paths that only know a count (physical Hangul fallback, explicit overrides).
    /// `expectedText` is nil, so the precondition check degrades to `.unavailable` rather than
    /// blocking the expand.
    public static func counted(_ count: Int) -> ErasePlan {
        ErasePlan(expectedText: nil, utf16Count: count, backspaceCount: count)
    }

    /// Nothing to erase. Deliberately **not** named `none` — `ErasePlan.none` would silently
    /// resolve to `Optional.none` at any call site expecting `ErasePlan?`.
    public static let empty = ErasePlan(expectedText: "", utf16Count: 0, backspaceCount: 0)

    public var isEmpty: Bool { utf16Count == 0 && backspaceCount == 0 }

    /// Builds the plan from the text the user actually typed.
    ///
    /// DevType swallows the final trigger key, so that key never reaches the field:
    ///
    /// * `terminator` non-empty — the swallowed key *was* the terminator, so the field still holds
    ///   the whole trigger. Erase the trigger.
    /// * `terminator` empty and the final key was swallowed — the swallowed key was the last
    ///   character of the trigger itself. Erase the trigger minus that trailing key.
    /// * nothing swallowed — erase the whole trigger.
    public static func forMatch(
        matchedTrigger: String,
        terminator: String,
        swallowedFinalKey: Bool,
        swallowedUnicode: String,
        caseInsensitive: Bool = false
    ) -> ErasePlan {
        guard !matchedTrigger.isEmpty else { return .empty }
        if !terminator.isEmpty {
            return ErasePlan(text: matchedTrigger, caseInsensitive: caseInsensitive)
        }
        guard swallowedFinalKey else {
            return ErasePlan(text: matchedTrigger, caseInsensitive: caseInsensitive)
        }
        // Drop the swallowed key from the tail. Trim by UTF-16 length so surrogate pairs and
        // multi-unit IME commits are removed whole.
        let swallowedUTF16 = max(1, swallowedUnicode.utf16.count)
        let units = Array(matchedTrigger.utf16)
        guard units.count > swallowedUTF16 else { return .empty }
        let keptUnits = Array(units.prefix(units.count - swallowedUTF16))
        let remaining = String(utf16CodeUnits: keptUnits, count: keptUnits.count)
        guard !remaining.isEmpty else { return .empty }
        return ErasePlan(text: remaining, caseInsensitive: caseInsensitive)
    }
}

/// Result of checking the field against an `ErasePlan` *before* anything destructive runs.
public enum ErasePreconditionResult: Equatable {
    /// The expected text is sitting left of the caret — safe to erase.
    case ok
    /// AX could not tell us enough to judge (unreadable value / range, or no expected text).
    /// Proceed best-effort; this is the pre-existing behaviour for AX-opaque hosts.
    case unavailable(String)
    /// AX *could* tell us, and the field does not hold what we expect. Erasing here would delete
    /// the user's own text — refuse the expand instead.
    case mismatch(String)

    public var blocksErase: Bool {
        if case .mismatch = self { return true }
        return false
    }

    /// A best-effort erase must use the app's real insertion point, never the AX range
    /// that could not be verified. An empty erase already evaluates to `.ok`.
    public var requiresHID: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

public enum ErasePreconditionChecker {
    /// Escape hatch. The guard trades "expansion silently corrupts text" for "expansion refuses and
    /// says why"; if a host turns out to report text in a way the guard cannot model, a user can
    /// disable it without waiting for a build:
    /// `defaults write com.devtype.app DevTypeDisableErasePrecondition -bool YES`
    public static let disableDefaultsKey = "DevTypeDisableErasePrecondition"

    public static var isEnabled: Bool {
        !UserDefaults.standard.bool(forKey: disableDefaultsKey)
    }

    /// Pure evaluation so the guard is unit-testable without a live AX element.
    ///
    /// - Parameters:
    ///   - plan: what we intend to delete.
    ///   - value: full `AXValue` of the focused field, if readable.
    ///   - caretLocation: `AXSelectedTextRange.location` (UTF-16), if readable.
    ///   - selectionLength: `AXSelectedTextRange.length` (UTF-16), if readable.
    ///   - insertionPointFollowsExpectedText: whether the caller can vouch that the app's real
    ///     insertion point sits immediately after the expected text. True on the expand path —
    ///     the tap just observed the trigger keystrokes land at the caret — which licenses the
    ///     §8.6 mismatch→unavailable downgrade below. The undo path cannot vouch (the user may
    ///     have typed since the expansion) and passes false, taking the honest `.mismatch` so it
    ///     can widen over the typed tail or refuse — never blind-erase at the caret. That blind
    ///     erase is the "Sch`slm" incident: undo ate `injectedText.count` units of the wrong
    ///     text and then restored the trigger on top of the remnant.
    public static func evaluate(
        plan: ErasePlan,
        value: String?,
        caretLocation: Int?,
        selectionLength: Int?,
        insertionPointFollowsExpectedText: Bool = true
    ) -> ErasePreconditionResult {
        if plan.utf16Count == 0 {
            return .ok
        }
        guard let expected = plan.expectedText, !expected.isEmpty else {
            return .unavailable("no expected text for this match path")
        }
        guard let value else {
            return .unavailable("AXValue unreadable")
        }
        guard let caretLocation else {
            return .unavailable("AXSelectedTextRange unreadable")
        }
        // A negative caret (CFRange kCFNotFound — "no selection info") or negative selection
        // length is not AX telling us the field holds the wrong text; it is an answer that could
        // not be parsed. `.mismatch` is reserved for "AX *could* tell us, and the field
        // disagrees" — garbage geometry degrades to the same best-effort baseline as an
        // unreadable range, instead of refusing every expansion in hosts that report it.
        guard caretLocation >= 0 else {
            return .unavailable("negative caret \(caretLocation) — no selection info from host")
        }
        if let selectionLength, selectionLength < 0 {
            return .unavailable("negative selection length \(selectionLength) — unparseable range")
        }

        // The trigger sits immediately before the selection start. A pre-existing user selection is
        // allowed — the AX replace path already widens from `location`.
        let units = value.utf16
        let end = caretLocation
        let start = end - plan.utf16Count

        // A value that cannot cover the caret, or cannot even hold the trigger, is a partial /
        // virtualised AX snapshot — common in Chromium and Electron text views, which report an
        // empty AXValue with a caret at 0. That is not evidence the field holds the wrong text, so
        // degrade instead of refusing every expand in those apps.
        guard end <= units.count else {
            return .unavailable(
                "AXValue (\(units.count) units) is shorter than caret \(end) — virtualised field"
            )
        }
        guard units.count >= plan.utf16Count else {
            return .unavailable(
                "AXValue (\(units.count) units) cannot hold a \(plan.utf16Count)-unit trigger — virtualised field"
            )
        }
        let disagreement: String
        if start < 0 {
            disagreement = "caret \(end) leaves no room for a \(plan.utf16Count)-unit erase in a \(units.count)-unit field"
        } else {
            // Copy only the trigger window, not the entire AXValue.
            let lower = units.index(units.startIndex, offsetBy: start)
            let upper = units.index(lower, offsetBy: plan.utf16Count)
            let rawActual = String(decoding: units[lower..<upper], as: UTF16.self)
            let actual = rawActual.normalizedWhitespace
            let normExpected = expected.normalizedWhitespace
            let matches = plan.caseInsensitive
                ? actual.lowercased() == normExpected.lowercased()
                : actual == normExpected
            if matches { return .ok }
            disagreement = "field holds \(debugQuote(rawActual)), expected \(debugQuote(expected))"
        }

        // AXValue and AXSelectedTextRange can use inconsistent coordinates, including a
        // zero caret in a nonempty Claude field. Both disagreement paths need the same
        // bounded corroboration. This authorises HID recovery, never an AX range write.
        let containsExpected = DeliveryVerifier.boundedContains(
            expected, in: value, caretLocation: end, caseInsensitive: plan.caseInsensitive
        )
        let presence = containsExpected.map { $0 ? "present" : "absent" } ?? "unavailable"
        let scan = units.count <= DeliveryVerifier.maxVerificationScanUTF16 ? "full" : "caretWindow"
        let evidence = "caret=\(end) selection=\(selectionLength.map(String.init) ?? "unavailable")"
            + " valueUTF16=\(units.count) expectedTextInScan=\(presence) scan=\(scan)"
        if insertionPointFollowsExpectedText, selectionLength == 0, containsExpected == true {
            return .unavailable(
                "\(disagreement) — caret geometry untrusted, proceeding best-effort; \(evidence)"
            )
        }
        return .mismatch("\(disagreement); \(evidence)")
    }

    /// Short, redaction-friendly rendering for logs — length plus a bounded prefix. Exotic
    /// whitespace is escaped so a mismatch involving an NBSP variant cannot print two
    /// identical-looking strings ("field holds \"`slm \", expected \"`slm \"" — the field
    /// actually held U+00A0).
    private static func debugQuote(_ text: String) -> String {
        let limit = 12
        var rendered = ""
        for scalar in text.prefix(limit).unicodeScalars {
            let isExoticWhitespace = scalar.properties.isWhitespace
                && scalar != " " && scalar != "\n" && scalar != "\t"
            let isInvisibleFormat = scalar.properties.generalCategory == .format
            if isExoticWhitespace || isInvisibleFormat {
                rendered += String(format: "\\u{%X}", scalar.value)
            } else {
                rendered.unicodeScalars.append(scalar)
            }
        }
        guard text.count > limit else { return "\"\(rendered)\"" }
        return "\"\(rendered)…\"(\(text.count))"
    }
}
