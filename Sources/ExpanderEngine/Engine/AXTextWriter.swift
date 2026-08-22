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

        /// True when a text write reached the field, so downstream destructive steps must treat
        /// unverifiable state as "may already contain the expansion".
        public var fieldMayHaveMutated: Bool {
            switch self {
            case .notAttempted: return false
            case .replaced, .falseSuccess, .unavailable: return true
            }
        }
    }

    private let verifier: DeliveryVerifier

    public init(verifier: DeliveryVerifier = DeliveryVerifier.shared) {
        self.verifier = verifier
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
    public func attemptAXCaretPosition(utf16OffsetFromEnd: Int) -> Bool {
        guard utf16OffsetFromEnd > 0 else { return true }
        guard let axElement = AXContextChecker.shared.focusedElement() else { return false }

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
    /// Contract: when this returns anything other than `.replaced`, the field and its selection are
    /// left **exactly** as they were found. Callers fall back to HID backspace + paste, which
    /// assumes an untouched field — leaving a widened selection behind is what caused backspace #1
    /// to eat the selection and the remaining backspaces to eat the user's preceding text.
    public func performAXRangeReplace(
        text: String,
        eraseCount: Int,
        bundleID: String?
    ) -> AXReplaceOutcome {
        guard let axElement = AXContextChecker.shared.focusedElement() else {
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

        var roleRef: CFTypeRef?
        let role: String =
            (AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef) == .success)
            ? ((roleRef as? String) ?? "")
            : ""

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

        var rangeRef: CFTypeRef?
        let rangeCopy = AXUIElementCopyAttributeValue(
            axElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        )
        guard rangeCopy == .success,
              let rangeValue = rangeRef,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            // #region agent log
            TextInjectionPipeline.debugLogInject(
                hypothesisId: "M3",
                message: "axRangeReplace",
                location: "AXTextWriter",
                data: [
                    "ok": false,
                    "fail": "selectedTextRange",
                    "rangeAXError": Int(rangeCopy.rawValue),
                    "role": role
                ]
            )
            // #endregion
            return .notAttempted("AXSelectedTextRange unreadable (\(rangeCopy.rawValue))")
        }

        let axRangeValue = unsafeBitCast(rangeValue, to: AXValue.self)
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRangeValue, .cfRange, &range) else {
            // #region agent log
            TextInjectionPipeline.debugLogInject(
                hypothesisId: "M3",
                message: "axRangeReplace",
                location: "AXTextWriter",
                data: ["ok": false, "fail": "rangeDecode", "role": role]
            )
            // #endregion
            return .notAttempted("AXSelectedTextRange undecodable")
        }

        // Caller falls back to HID backspace + paste when this returns false. That fallback assumes
        // the field is untouched, so every failure path below MUST undo the widened selection —
        // otherwise backspace #1 eats the selection and the rest eat preceding user text.
        let originalRange = range
        func restoreOriginalSelection() {
            var restore = originalRange
            guard let restoreValue = AXValueCreate(.cfRange, &restore) else { return }
            let status = AXUIElementSetAttributeValue(
                axElement,
                kAXSelectedTextRangeAttribute as CFString,
                restoreValue
            )
            if status != .success {
                // A failed restore leaves the widened selection in place; the HID fallback's
                // first backspace would then eat it. Hosts whose range-set lies twice are a real
                // observed shape — surface it so field reports can identify them.
                DevTypeLog.inject.error(
                    "[Inject] AX selection restore failed after range-replace attempt (\(status.rawValue, privacy: .public)) — widened selection left behind"
                )
            }
        }

        // Baseline value: the only reliable way to tell "AX reported success but did not mutate"
        // (Messages / Electron) apart from a real edit we simply cannot re-read.
        var beforeValueRef: CFTypeRef?
        let beforeValue: String? =
            (AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &beforeValueRef) == .success)
            ? (beforeValueRef as? String)
            : nil

        let erase = max(0, eraseCount)
        // The erase precondition checker refuses negative/overflowing ranges ("we do not know
        // where the caret is"); the writer must refuse them too. Widening from such a range
        // previously produced {0, L-1} — the start of the document — or trapped on overflow.
        guard var expanded = Self.widenedRange(from: range, eraseCount: eraseCount) else {
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

        guard let newRangeValue = AXValueCreate(.cfRange, &expanded) else {
            return .notAttempted("AXValueCreate failed for widened range")
        }
        let setRange = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextRangeAttribute as CFString,
            newRangeValue
        )
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

        let setResult = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        var valueLen = -1
        /// Only a read-back comparison is evidence about this app's AX behaviour. Assuming success
        /// because we could not read the field must never be recorded as trust — that would
        /// overwrite a seeded `.falseSuccess` verdict and re-enable the broken path for the session.
        var verdictIsEvidence = false
        let outcome: AXReplaceOutcome

        if setResult != .success {
            outcome = .unavailable("setSelectedText failed (\(setResult.rawValue))")
        } else {
            // Reject false AX success: setSelectedText can return `.success` without mutating
            // (Messages, Chromium/Electron web views). The test is "did the field change", NOT
            // "can we find `text` in the value" — some hosts return a stale or virtualised AXValue
            // right after a real edit, and treating that as failure sends the HID fallback at an
            // already-mutated field, which duplicates text or deletes past the trigger.
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef) == .success,
               let value = valueRef as? String {
                valueLen = value.utf16.count
                verdictIsEvidence = true
                if let beforeValue {
                    outcome = value == beforeValue ? .falseSuccess : .replaced
                } else {
                    // No baseline to compare against — fall back to containment. Compare with
                    // whitespace normalized: rich-text hosts (ProseMirror in Claude Desktop)
                    // store a trailing typed space as U+00A0, and a raw miss here would record
                    // `.falseSuccess` for a write that actually landed — condemning the AX path
                    // and sending the HID fallback at an already-mutated field.
                    outcome = value.normalizedWhitespace.contains(text.normalizedWhitespace)
                        ? .replaced : .falseSuccess
                }
            } else {
                // AX write claimed success and we cannot read the field back. We must not assume it
                // was a no-op (that would double-apply); treat it as applied but unverified, and
                // learn nothing about the app from it.
                outcome = .replaced
            }
        }

        if outcome != .replaced {
            restoreOriginalSelection()
        }

        if let bundleID, !bundleID.isEmpty, verdictIsEvidence {
            // §3.3: the role has always been read here and passed to the debug log but not to the
            // store, so a Chromium web view's lie condemned that app's native text fields too.
            switch outcome {
            case .replaced:
                AXWriteCapabilityStore.shared.recordTrusted(bundleID: bundleID, role: role)
            case .falseSuccess:
                AXWriteCapabilityStore.shared.recordFalseSuccess(bundleID: bundleID, role: role)
            case .notAttempted, .unavailable:
                break
            }
        }

        // #region agent log
        let failLabel: String
        switch outcome {
        case .replaced: failLabel = "none"
        case .falseSuccess: failLabel = "valueVerifyFailed"
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
                "textLen": text.utf16.count,
                "valueLen": valueLen
            ]
        )
        // #endregion
        return outcome
    }

    // MARK: - Direct insert

    public func attemptAXDirectInjection(text: String, bundleID: String? = nil) -> Bool {
        guard let axElement = AXContextChecker.shared.focusedElement() else { return false }

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
}
