import AppKit
import ApplicationServices
import Foundation

/// §8.1: the only code in DevType that touches `kAXSelectedText` / `kAXSelectedTextRange`.
///
/// Everything here is written against one hard rule: **when a write does not return `.replaced`,
/// the field and its selection must be left exactly as they were found.** The caller's fallback is
/// HID backspace + paste, which assumes an untouched field — a widened selection left behind is
/// what made backspace #1 eat the selection and the remaining backspaces eat the user's own text.
public final class AXTextWriter {
    public static let shared = AXTextWriter()

    /// Outcome of an AX selected-text replace attempt.
    ///
    /// `notAttempted` vs `unavailable` is load-bearing for the erase guard downstream: after a
    /// write that *may* have landed, an unverifiable field must refuse the expand (erasing and
    /// injecting again duplicates it), but after a return that provably never issued a write the
    /// field is untouched and the HID fallback is safe. Collapsing the two is exactly how a
    /// Chrome PWA with no readable focused element turned into "Erase precondition failed" —
    /// a refusal protecting against a write that never happened.
    public enum AXReplaceOutcome: Equatable {
        /// The field actually changed — inject is done.
        case replaced
        /// AX returned `.success` but the field is byte-identical. The app lies; condemn it.
        case falseSuccess
        /// Returned before any text write was issued — the field is provably untouched.
        /// (No focused element, learned skip, unreadable/undecodable range, failed range set:
        /// a failed `AXUIElementSetAttributeValue` leaves the selection unchanged.)
        case notAttempted(String)
        /// A `kAXSelectedText` write was issued but its effect cannot be judged. The field may
        /// have mutated.
        case unavailable(String)
        /// A write was issued and the first read showed no change. Neither a lie nor a landing
        /// yet: the selection is still widened, no verdict is recorded, and the caller owes a
        /// `confirmRangeReplace` after the host settles. The field may have mutated.
        case unconfirmed(PendingRangeReplace)

        /// True when a text write reached the field, so downstream destructive steps must treat
        /// unverifiable state as "may already contain the expansion".
        public var fieldMayHaveMutated: Bool {
            switch self {
            case .notAttempted: return false
            case .replaced, .falseSuccess, .unavailable, .unconfirmed: return true
            }
        }
    }

    /// Everything `confirmRangeReplace` needs to judge a write again later.
    public struct PendingRangeReplace: Equatable {
        let element: AXUIElement
        let text: String
        let beforeValue: String?
        let role: String
        let bundleID: String?
        /// The caret as found, before the range was widened over the trigger.
        let originalRange: CFRange

        public static func == (lhs: PendingRangeReplace, rhs: PendingRangeReplace) -> Bool {
            CFEqual(lhs.element, rhs.element) && lhs.text == rhs.text
                && lhs.beforeValue == rhs.beforeValue && lhs.role == rhs.role
                && lhs.bundleID == rhs.bundleID
                && lhs.originalRange.location == rhs.originalRange.location
                && lhs.originalRange.length == rhs.originalRange.length
        }
    }

    /// The AX attribute surface the range replace reads and writes, injectable so a host whose
    /// tree lags a real edit can be scripted without a live application.
    struct ElementAccess {
        var role: (AXUIElement) -> String?
        var selectedRange: (AXUIElement) -> CFRange?
        var setSelectedRange: (AXUIElement, CFRange) -> AXError
        var value: (AXUIElement) -> String?
        var setSelectedText: (AXUIElement, String) -> AXError
        var selectedText: (AXUIElement) -> String?

        static let live = ElementAccess(
            role: { element in
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success else {
                    return nil
                }
                return ref as? String
            },
            selectedRange: { element in
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
                      let rangeValue = ref, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
                var range = CFRange(location: 0, length: 0)
                guard AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range) else { return nil }
                return range
            },
            setSelectedRange: { element, range in
                var range = range
                guard let value = AXValueCreate(.cfRange, &range) else { return .failure }
                return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            },
            value: { element in
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else {
                    return nil
                }
                return ref as? String
            },
            setSelectedText: { element, text in
                AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            },
            selectedText: { element in
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &ref) == .success else {
                    return nil
                }
                return ref as? String
            }
        )
    }

    private let verifier: DeliveryVerifier
    private let access: ElementAccess

    public convenience init(verifier: DeliveryVerifier = DeliveryVerifier.shared) {
        self.init(verifier: verifier, access: .live)
    }

    init(verifier: DeliveryVerifier = DeliveryVerifier.shared, access: ElementAccess) {
        self.verifier = verifier
        self.access = access
    }

    // MARK: - Hostile range validation

    /// Sanity ceiling for host-reported UTF-16 ranges (~2 GB of text — no real
    /// field approaches this). NSNotFound-class sentinel answers live near
    /// `Int.max` and must be rejected before arithmetic, not after.
    public static let maxPlausibleAXUTF16Units = 1_000_000_000

    /// Whether a host-reported AX selected-text range is safe to do arithmetic on.
    ///
    /// Hosts report negative locations (kCFNotFound-class "no selection info") and
    /// huge lengths; the erase precondition checker already refuses these, but the
    /// range writer must refuse them too — widening from an unvalidated range
    /// either targets the start of the document (data destruction) or traps on
    /// overflow inside the inject path.
    public static func isUsableAXRange(_ range: CFRange) -> Bool {
        range.location >= 0 && range.length >= 0
            && range.location <= maxPlausibleAXUTF16Units
            && range.length <= maxPlausibleAXUTF16Units
    }

    /// Widens a validated selection leftwards by `eraseCount` UTF-16 units to
    /// cover the trigger. Returns nil for any input that would overflow or target
    /// an unintended region — callers must fall back to HID instead of writing.
    public static func widenedRange(from reported: CFRange, eraseCount: Int) -> CFRange? {
        guard isUsableAXRange(reported) else { return nil }
        let erase = max(0, eraseCount)
        // Both operands are non-negative and bounded, so this cannot underflow.
        let erasedFromStart = min(reported.location, erase)
        let (newLength, overflow) = erasedFromStart.addingReportingOverflow(reported.length)
        guard !overflow else { return nil }
        return CFRange(location: reported.location - erasedFromStart, length: newLength)
    }

    // MARK: - Caret

    /// Moves selection start left by `utf16OffsetFromEnd` using AX selected-text range.
    ///
    /// AX ranges are UTF-16 code units, so this path is unit-correct by construction — unlike the
    /// HID arrow fallback, which had to be taught the difference in §1.6.
    @discardableResult
    public func attemptAXCaretPosition(utf16OffsetFromEnd: Int, focus: FocusedElementSource) -> Bool {
        guard utf16OffsetFromEnd > 0 else { return true }
        guard let axElement = focus.element else { return false }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return false
        }

        let axRangeValue = unsafeBitCast(rangeValue, to: AXValue.self)
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRangeValue, .cfRange, &range) else { return false }
        // A hostile/sentinel range must not reach the subtraction below.
        guard Self.isUsableAXRange(range) else { return false }

        let newLocation = max(0, range.location - utf16OffsetFromEnd)
        var caret = CFRange(location: newLocation, length: 0)
        guard let caretValue = AXValueCreate(.cfRange, &caret) else { return false }
        return AXUIElementSetAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, caretValue) == .success
    }

    // MARK: - Range replace

    /// Transactional AX replace.
    ///
    /// Contract: when this returns `.notAttempted`, `.falseSuccess` or `.unavailable`, the
    /// field and its selection are left **exactly** as they were found. Callers fall back to
    /// HID backspace + paste, which assumes an untouched field — leaving a widened selection
    /// behind is what caused backspace #1 to eat the selection and the remaining backspaces to
    /// eat the user's preceding text.
    ///
    /// `.unconfirmed` is the one outcome that leaves both alone on purpose: the write was issued
    /// and the field showed no change on the first read, which a host that lies and a host whose
    /// AX tree has not caught up with a real edit both produce. Judging it now condemned honest
    /// but slow apps (a wrong verdict is effectively permanent), put the caret back *inside* an
    /// expansion that had landed, and sent the HID fallback at the new text. The caller waits
    /// out `AXSettleRetry.settleDelay` and asks `confirmRangeReplace`.
    public func performAXRangeReplace(
        text: String,
        eraseCount: Int,
        bundleID: String?,
        focus: FocusedElementSource
    ) -> AXReplaceOutcome {
        guard let axElement = focus.element else {
            // #region agent log
            TextInjectionPipeline.debugLogInject(
                hypothesisId: "M3",
                message: "axRangeReplace",
                location: "AXTextWriter",
                data: ["ok": false, "fail": "noFocusedElement"]
            )
            // #endregion
            return .notAttempted("no focused element")
        }

        let role = access.role(axElement) ?? ""

        // §3.3: the store is keyed on `(bundleID, role)`. The caller's pre-check only knows the
        // bundle, so this is the first point where a verdict learned for *this* control — a
        // Chromium web view rather than the same app's native NSTextField — can be honoured.
        // Returning before touching the selection keeps the no-side-effect contract. An
        // unreadable role still consults the store: it degrades to the bundle-only key, so a
        // seeded bundle-level condemnation (Chrome, Messages) is honoured without paying the
        // known-bad first write just because the role could not be read.
        if let bundleID, !bundleID.isEmpty,
           AXWriteCapabilityStore.shared.shouldSkipAXSelectedText(bundleID: bundleID, role: role.isEmpty ? nil : role) {
            // #region agent log
            TextInjectionPipeline.debugLogInject(
                hypothesisId: "M3",
                message: "axRangeReplace",
                location: "AXTextWriter",
                data: ["ok": false, "fail": "learnedFalseSuccessForRole", "role": role]
            )
            // #endregion
            return .notAttempted("learned false-success for \(bundleID) role \(role.isEmpty ? "(unreadable)" : role)")
        }

        guard let range = access.selectedRange(axElement) else {
            // #region agent log
            TextInjectionPipeline.debugLogInject(
                hypothesisId: "M3",
                message: "axRangeReplace",
                location: "AXTextWriter",
                data: ["ok": false, "fail": "selectedTextRange", "role": role]
            )
            // #endregion
            return .notAttempted("AXSelectedTextRange unreadable")
        }

        // Baseline value: the only reliable way to tell "AX reported success but did not mutate"
        // (Messages / Electron) apart from a real edit we simply cannot re-read.
        let beforeValue = access.value(axElement)

        let erase = max(0, eraseCount)
        // The erase precondition checker refuses negative/overflowing ranges ("we do not know
        // where the caret is"); the writer must refuse them too. Widening from such a range
        // previously produced {0, L-1} — the start of the document — or trapped on overflow.
        guard let expanded = Self.widenedRange(from: range, eraseCount: eraseCount) else {
            TextInjectionPipeline.debugLogInject(
                hypothesisId: "M3",
                message: "axRangeReplace",
                location: "AXTextWriter",
                data: [
                    "ok": false,
                    "fail": "unusableSelectedTextRange",
                    "loc": range.location,
                    "len": range.length,
                    "erase": erase
                ]
            )
            return .notAttempted("unusable selected-text range (\(range.location), \(range.length))")
        }

        let setRange = access.setSelectedRange(axElement, expanded)
        guard setRange == .success else {
            // #region agent log
            TextInjectionPipeline.debugLogInject(
                hypothesisId: "M3",
                message: "axRangeReplace",
                location: "AXTextWriter",
                data: [
                    "ok": false,
                    "fail": "setSelectedRange",
                    "setRangeAXError": Int(setRange.rawValue),
                    "role": role,
                    "loc": range.location,
                    "len": range.length,
                    "erase": erase
                ]
            )
            // #endregion
            // Selection unchanged (the set failed), so there is nothing to roll back.
            return .notAttempted("setSelectedTextRange failed (\(setRange.rawValue))")
        }

        let pending = PendingRangeReplace(
            element: axElement, text: text, beforeValue: beforeValue, role: role,
            bundleID: bundleID, originalRange: range
        )
        let setResult = access.setSelectedText(axElement, text)
        let outcome: AXReplaceOutcome
        if setResult != .success {
            outcome = .unavailable("setSelectedText failed (\(setResult.rawValue))")
            restoreOriginalSelection(pending)
        } else {
            // Reject false AX success: setSelectedText can return `.success` without mutating
            // (Messages, Chromium/Electron web views) — but only a *settled* read may say so.
            outcome = conclude(judgeReadback(pending), pending: pending, settled: false)
        }

        logRangeReplace(outcome, setResult: setResult, role: role, range: range, erase: erase,
                        textLength: text.utf16.count, valueLength: -1)
        return outcome
    }

    /// What a write that returned `.unconfirmed` turned out to be, read again after the host had
    /// time to settle. The final judgement `performAXRangeReplace` withheld: a field still
    /// showing no change is a lie (selection restored, verdict recorded); a changed one landed.
    /// Never returns `.unconfirmed`.
    public func confirmRangeReplace(_ pending: PendingRangeReplace) -> AXReplaceOutcome {
        let outcome = conclude(judgeReadback(pending), pending: pending, settled: true)
        logRangeReplace(outcome, setResult: .success, role: pending.role, range: pending.originalRange,
                        erase: -1, textLength: pending.text.utf16.count, valueLength: -1)
        return outcome
    }

    /// What one read of the field says about the write that was just issued.
    private enum Readback {
        /// The field changed (`learn`: the evidence is a value comparison, which may be recorded
        /// as trust for this app — a selection-only reading may not).
        case landed(learn: Bool)
        /// The field is byte-identical (or, with no baseline, lacks the text).
        case unchanged
        /// Nothing readable: applied but unverified, and nothing to learn from it.
        case unreadable
    }

    /// The test is "did the field change", NOT "can we find `text` in the value" — some hosts
    /// return a stale or virtualised AXValue right after a real edit.
    private func judgeReadback(_ pending: PendingRangeReplace) -> Readback {
        if let value = access.value(pending.element) {
            if let beforeValue = pending.beforeValue {
                return value == beforeValue ? .unchanged : .landed(learn: true)
            }
            // No baseline to compare against — fall back to containment. Compare with
            // whitespace normalized: rich-text hosts (ProseMirror in Claude Desktop) store a
            // trailing typed space as U+00A0, and a raw miss here would read a write that
            // landed as a no-op.
            return value.normalizedWhitespace.contains(pending.text.normalizedWhitespace)
                ? .landed(learn: true) : .unchanged
        }
        // AXValue is unreadable (complex document views like Word or unseeded custom editors).
        // If the write succeeded, the selection should have collapsed (empty) or become the
        // replacement text; still non-empty without the replacement means it provably did not
        // mutate.
        if let afterSelected = access.selectedText(pending.element), !afterSelected.isEmpty {
            return afterSelected.normalizedWhitespace.contains(pending.text.normalizedWhitespace)
                ? .landed(learn: false) : .unchanged
        }
        // The write claimed success and the field cannot be read back. It must not be assumed a
        // no-op (that would double-apply); applied but unverified, and nothing learned.
        return .unreadable
    }

    private func conclude(_ readback: Readback, pending: PendingRangeReplace, settled: Bool) -> AXReplaceOutcome {
        let outcome: AXReplaceOutcome
        switch readback {
        case .landed(let learn):
            outcome = .replaced
            // Only a read-back comparison is evidence about this app's AX behaviour. Assuming
            // success because the field could not be read must never be recorded as trust — that
            // would overwrite a seeded `.falseSuccess` verdict and re-enable the broken path.
            if learn, let bundleID = pending.bundleID, !bundleID.isEmpty {
                AXWriteCapabilityStore.shared.recordTrusted(bundleID: bundleID, role: pending.role)
            }
        case .unreadable:
            outcome = .replaced
        case .unchanged:
            guard settled else { return .unconfirmed(pending) }
            outcome = .falseSuccess
            restoreOriginalSelection(pending)
            if let bundleID = pending.bundleID, !bundleID.isEmpty {
                // §3.3: the role has always been read here and passed to the debug log but not
                // to the store, so a Chromium web view's lie condemned that app's native text
                // fields too.
                AXWriteCapabilityStore.shared.recordFalseSuccess(bundleID: bundleID, role: pending.role)
            }
        }
        return outcome
    }

    /// Every failure path must undo the widened selection — otherwise backspace #1 eats the
    /// selection and the rest eat preceding user text.
    private func restoreOriginalSelection(_ pending: PendingRangeReplace) {
        let status = access.setSelectedRange(pending.element, pending.originalRange)
        if status != .success {
            // A failed restore leaves the widened selection in place; the HID fallback's
            // first backspace would then eat it. Hosts whose range-set lies twice are a real
            // observed shape — surface it so field reports can identify them.
            DevTypeLog.inject.error(
                "[Inject] AX selection restore failed after range-replace attempt (\(status.rawValue, privacy: .public)) — widened selection left behind"
            )
        }
    }

    private func logRangeReplace(
        _ outcome: AXReplaceOutcome, setResult: AXError, role: String, range: CFRange,
        erase: Int, textLength: Int, valueLength: Int
    ) {
        // #region agent log
        let failLabel: String
        switch outcome {
        case .replaced: failLabel = "none"
        case .falseSuccess: failLabel = "valueVerifyFailed"
        case .unconfirmed: failLabel = "unconfirmedUnsettledRead"
        case .notAttempted(let why): failLabel = why
        case .unavailable(let why): failLabel = why
        }
        TextInjectionPipeline.debugLogInject(
            hypothesisId: "M3",
            message: "axRangeReplace",
            location: "AXTextWriter",
            data: [
                "ok": outcome == .replaced,
                "fail": failLabel,
                "setTextAXError": Int(setResult.rawValue),
                "role": role,
                "loc": range.location,
                "len": range.length,
                "erase": erase,
                "textLen": textLength,
                "valueLen": valueLength
            ]
        )
        // #endregion
    }

    // MARK: - Direct insert

    public func attemptAXDirectInjection(
        text: String,
        bundleID: String? = nil,
        focus: FocusedElementSource
    ) -> Bool {
        guard let axElement = focus.element else { return false }

        var roleRef: CFTypeRef?
        let role: String? =
            (AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef) == .success)
            ? (roleRef as? String)
            : nil

        // Same class of lie as range replace. After erase, a false AX "success" that we cannot
        // verify must not short-circuit HID paste — that reports succeeded with an empty field.
        if let bundleID, !bundleID.isEmpty,
           AXWriteCapabilityStore.shared.shouldSkipAXSelectedText(bundleID: bundleID, role: role) {
            return false
        }

        // Baseline before the write so `verifyTextDelivery` can distinguish "nothing happened" from
        // "it happened but the host reports a stale value". Without it a real insert can be judged
        // failed, and the caller then pastes the same text a second time.
        let baseline = verifier.focusedTextObservation(for: axElement)
        let result = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard result == .success else { return false }
        switch DeliveryVerifier.verifyTextDelivery(
            expectedText: text,
            baseline: baseline,
            after: verifier.focusedTextObservation(for: axElement)
        ) {
        case .failed:
            return false
        case .delivered, .unavailable:
            // `.unavailable` stays "assume delivered" for honest AX-opaque hosts so we do not
            // double-paste. Known-lying apps never reach here — they return false above.
            return true
        }
    }

    // MARK: - Selection hygiene

    /// Collapses any non-empty selection to the caret at its trailing edge.
    ///
    /// A selection sitting in the field when we are about to post backspaces is almost always our
    /// own leftover (an AX replace that widened the range then failed). Backspace #1 would consume
    /// the whole selection and every subsequent backspace would eat the user's preceding text — the
    /// "expansion deleted the previous N characters" bug. Collapsing to the trailing edge makes the
    /// backspace count mean exactly what it says.
    @discardableResult
    public func collapseSelectionToCaret(element: AXUIElement? = nil) -> Bool {
        guard let axElement = element ?? AXContextChecker.shared.focusedElement() else { return false }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return false
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range) else {
            return false
        }
        guard range.length > 0 else { return true }
        guard Self.isUsableAXRange(range) else { return false }

        DevTypeLog.inject.notice(
            "[Inject] collapsing stray selection before erase length=\(range.length, privacy: .public)"
        )
        // Trailing edge, deliberately. The selection we are cleaning up was produced by a failed AX
        // replace, which widens *backwards* from the caret to cover the trigger — so the trailing
        // edge is where the caret was before we touched it, and `backspaceCount` backspaces from
        // there remove exactly the trigger.
        // Both fields are bounded by `isUsableAXRange`, so this sum cannot overflow.
        var caret = CFRange(location: range.location + range.length, length: 0)
        guard let caretValue = AXValueCreate(.cfRange, &caret) else { return false }
        return AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextRangeAttribute as CFString,
            caretValue
        ) == .success
    }

    /// Selects `range` (UTF-16) in `element`. A range set moves no text, so a host that ignores it
    /// leaves the field untouched — the caller must still read the selection back before relying
    /// on it, because some hosts answer `.success` and keep their old selection.
    @discardableResult
    public func selectRange(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard Self.isUsableAXRange(cfRange),
              let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }
}
