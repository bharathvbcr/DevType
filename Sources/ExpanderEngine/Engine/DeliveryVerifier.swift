import AppKit
import ApplicationServices
import Foundation

/// Delivery evidence belongs to a pinned target and an observed insertion/replacement.
/// Readable absence cannot prove an asynchronous paste will never arrive; it is unverified.
public final class DeliveryVerifier {
    public static let shared = DeliveryVerifier()

    public struct FocusedTextObservation: Equatable {
        public let value: String?
        public let selectedText: String?
        public let caretLocation: Int?
        public let selectedRange: NSRange?
        public let target: AXUIElement?
        /// `kAXNumberOfCharacters` read with the baseline. The windowed hold-loop check trusts the
        /// element's count only when this equals `value`'s UTF-16 length, i.e. the host is shown
        /// to count in the same units the window offsets use.
        public let numberOfCharacters: Int?
        /// Screen frame of `target` when the baseline was taken. The only evidence that can tie a
        /// *replacement* node back to this field after WebKit swaps the element under the paste
        /// (see `readFocusedTextDelivery`). Not part of `==`: it identifies the control, it is not
        /// field content.
        public let frame: CGRect?

        public init(
            value: String?, selectedText: String?, caretLocation: Int? = nil,
            selectedRange: NSRange? = nil, target: AXUIElement? = nil, numberOfCharacters: Int? = nil,
            frame: CGRect? = nil
        ) {
            self.value = value
            self.selectedText = selectedText
            self.caretLocation = selectedRange?.location ?? caretLocation
            self.selectedRange = selectedRange
            self.target = target
            self.numberOfCharacters = numberOfCharacters
            self.frame = frame
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            let sameTarget: Bool
            switch (lhs.target, rhs.target) {
            case (nil, nil): sameTarget = true
            case (let left?, let right?): sameTarget = CFEqual(left, right)
            default: sameTarget = false
            }
            return sameTarget && lhs.value == rhs.value && lhs.selectedText == rhs.selectedText
                && lhs.caretLocation == rhs.caretLocation && lhs.selectedRange == rhs.selectedRange
        }
    }

    public enum TextDeliveryVerification: Equatable {
        case delivered
        case failed
        case unavailable
    }

    /// §2.6: `value.contains(expectedText)` is O(n·m) over the *entire* focused field and ran on
    /// every 50 ms hold-loop tick. Above this size the scan is bounded to a window around the
    /// caret; with no caret available the answer degrades to "cannot judge" rather than to a
    /// wrong `.failed` (historically used to authorize duplicate pastes; now treated as unavailable).
    public static let maxVerificationScanUTF16 = 32_768
    /// Slack around the caret when scanning a large field — hosts may place the caret a few units
    /// past the inserted text (trailing newline normalisation, autocorrect).
    public static let verificationCaretSlackUTF16 = 512

    /// The AX reads the hold-loop verification makes, injectable so unsupported attributes,
    /// field edges and surrogate offsets can be reproduced without a live AX tree.
    struct TextAccess {
        var focusedElement: () -> AXUIElement?
        /// `kAXNumberOfCharacters`; `nil` when the element does not answer it.
        var numberOfCharacters: (AXUIElement) -> Int?
        var selectedRange: (AXUIElement) -> NSRange?
        /// Parameterized `kAXStringForRange`; `nil` when unsupported or the range is refused.
        var stringForRange: (AXUIElement, NSRange) -> String?
        /// The full read the windowed path falls back to.
        var observation: (AXUIElement) -> FocusedTextObservation
        /// Screen frame, role and owning process of an element — the three facts a replaced node
        /// must share with the baseline before its text may count as this field's.
        var frame: (AXUIElement) -> CGRect? = { _ in nil }
        var role: (AXUIElement) -> String? = { _ in nil }
        var pid: (AXUIElement) -> pid_t? = { _ in nil }

        static let live = TextAccess(
            focusedElement: { AXContextChecker.shared.focusedElement() },
            numberOfCharacters: { element in
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    element, kAXNumberOfCharactersAttribute as CFString, &ref
                ) == .success else { return nil }
                return (ref as? NSNumber)?.intValue
            },
            selectedRange: DeliveryVerifier.selectedRange,
            stringForRange: { element, range in
                var cfRange = CFRange(location: range.location, length: range.length)
                guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
                return SelectionReader.copyStringForRange(element, parameter, attributed: false)
            },
            observation: { DeliveryVerifier.fullObservation(for: $0) },
            frame: { AXContextChecker.elementFrame($0) },
            role: { AXContextChecker.shared.focusedElementRole(element: $0) },
            pid: { element in
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
                return pid
            }
        )
    }

    private let access: TextAccess

    public init() { access = .live }

    init(access: TextAccess) { self.access = access }

    // MARK: - Observation

    public func captureFocusedTextObservation(focus: FocusedElementSource) -> FocusedTextObservation? {
        guard let axElement = focus.element else { return nil }
        let observed = focusedTextObservation(for: axElement)
        return FocusedTextObservation(
            value: observed.value, selectedText: observed.selectedText,
            caretLocation: observed.caretLocation, selectedRange: observed.selectedRange,
            target: observed.target, numberOfCharacters: access.numberOfCharacters(axElement),
            frame: access.frame(axElement)
        )
    }

    public func focusedTextObservation(for axElement: AXUIElement) -> FocusedTextObservation {
        access.observation(axElement)
    }

    static func fullObservation(for axElement: AXUIElement) -> FocusedTextObservation {
        var value: String?
        var selectedText: String?

        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef) == .success {
            value = valueRef as? String
        }

        var selectedTextRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success {
            selectedText = selectedTextRef as? String
        }

        let selectedRange = Self.selectedRange(for: axElement)

        return FocusedTextObservation(
            value: value,
            selectedText: selectedText,
            selectedRange: selectedRange,
            target: axElement
        )
    }

    static func selectedRange(for axElement: AXUIElement) -> NSRange? {
        // Attribution needs the range even for short fields. A matching string
        // elsewhere in the field or an unrelated selection is not delivery evidence.
        var selectedRange: NSRange?
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range),
               range.location >= 0, range.length >= 0 {
                selectedRange = NSRange(location: range.location, length: range.length)
            }
        }

        return selectedRange
    }

    // MARK: - Verification

    /// Why a focused-field read produced no verdict. `.unavailable` alone conflated four different
    /// facts, and the one that matters to a WebKit field — the element was *replaced* under the
    /// paste — printed as "field unreadable".
    public enum UnavailableReason: String, Equatable {
        /// The baseline never captured a target element, so there is nothing to compare.
        case noBaselineTarget
        /// The focus query returned nothing now.
        case noFocusedElement
        /// A different element is focused and was not vouched as the same control. It may be a
        /// field the user clicked into, so it is never evidence either way.
        case focusReplaced
        /// The baseline element (or its vouched replacement) is focused but its value, caret or
        /// range could not prove the insertion.
        case fieldUnreadable
    }

    public struct FocusedDeliveryReading {
        public let verification: TextDeliveryVerification
        /// Non-nil exactly when `verification` is `.unavailable`.
        public let unavailableReason: UnavailableReason?
        /// Set only when delivery was proven on a node that replaced the baseline target.
        public let replacementElement: AXUIElement?
    }

    /// Whether `live` may stand in for the baseline field after a node swap. Every condition must
    /// hold: same owning process, a text-entry role (never a secure field, combo box or web
    /// area), and the same on-screen control by `EraseContinuation`'s own frame rule. A missing
    /// answer for any of them fails closed — "could not tell" is not "same field".
    static func replacementIsSameControl(
        baselineFrame: CGRect?, liveFrame: CGRect?,
        baselinePID: pid_t?, livePID: pid_t?, liveRole: String?
    ) -> Bool {
        guard let baselinePID, let livePID, baselinePID == livePID else { return false }
        guard EraseContinuation.roleAllowsInsertionRetarget(liveRole) else { return false }
        guard let baselineFrame, let liveFrame else { return false }
        return EraseContinuation.framesIdentifySameControl(baselineFrame, liveFrame)
    }

    /// §2.2: a documented re-check. The live focus is compared (`CFEqual`) against the baseline's
    /// target on every call — this runs on each paste-hold tick precisely to notice the user
    /// moving, so it must never be handed a threaded element.
    public func verifyFocusedTextDelivery(
        expectedText: String,
        baseline: FocusedTextObservation?,
        staleProbe: String? = nil,
        staleProbeCaseInsensitive: Bool = false
    ) -> TextDeliveryVerification {
        readFocusedTextDelivery(
            expectedText: expectedText, baseline: baseline,
            staleProbe: staleProbe, staleProbeCaseInsensitive: staleProbeCaseInsensitive
        ).verification
    }

    /// `verifyFocusedTextDelivery` with the reason an answer was unavailable kept.
    ///
    /// - Parameter vouchingReplacement: WebKit can replace the focused text node when a paste
    ///   lands, so the baseline's element is no longer `CFEqual` to focus even though the text is
    ///   in the field. With this set, a replacement that is the same control
    ///   (`replacementIsSameControl`) is read in the baseline's place; the comparison against the
    ///   baseline value, insertion window and caret is unchanged, so a different field cannot
    ///   verify. Off by default: the paste-hold tick keeps its strict identity gate, and only the
    ///   deferred, observation-only re-verification — which writes nothing — opts in.
    public func readFocusedTextDelivery(
        expectedText: String,
        baseline: FocusedTextObservation?,
        staleProbe: String? = nil,
        staleProbeCaseInsensitive: Bool = false,
        vouchingReplacement: Bool = false
    ) -> FocusedDeliveryReading {
        func unavailable(_ reason: UnavailableReason) -> FocusedDeliveryReading {
            FocusedDeliveryReading(verification: .unavailable, unavailableReason: reason, replacementElement: nil)
        }
        guard let baseline, let target = baseline.target else { return unavailable(.noBaselineTarget) }
        guard let current = access.focusedElement() else { return unavailable(.noFocusedElement) }

        guard CFEqual(target, current) else {
            guard vouchingReplacement,
                  Self.replacementIsSameControl(
                    baselineFrame: baseline.frame, liveFrame: access.frame(current),
                    baselinePID: access.pid(target), livePID: access.pid(current),
                    liveRole: access.role(current)
                  ) else {
                return unavailable(.focusReplaced)
            }
            // Re-pin the read to the baseline target: `verifyTextDelivery` demands the same
            // element, and the vouch above is what licenses reading the replacement as it.
            let observed = focusedTextObservation(for: current)
            let rebound = FocusedTextObservation(
                value: observed.value, selectedText: observed.selectedText,
                selectedRange: observed.selectedRange, target: target
            )
            let verdict = Self.verifyTextDelivery(
                expectedText: expectedText, baseline: baseline, after: rebound,
                staleProbe: staleProbe, staleProbeCaseInsensitive: staleProbeCaseInsensitive
            )
            return FocusedDeliveryReading(
                verification: verdict,
                unavailableReason: verdict == .unavailable ? .fieldUnreadable : nil,
                replacementElement: verdict == .delivered ? current : nil
            )
        }

        let verdict: TextDeliveryVerification
        if let windowed = verifyDeliveryByWindow(expectedText: expectedText, baseline: baseline, target: target) {
            verdict = windowed
        } else {
            verdict = Self.verifyTextDelivery(
                expectedText: expectedText, baseline: baseline,
                after: focusedTextObservation(for: target), staleProbe: staleProbe,
                staleProbeCaseInsensitive: staleProbeCaseInsensitive
            )
        }
        return FocusedDeliveryReading(
            verification: verdict,
            unavailableReason: verdict == .unavailable ? .fieldUnreadable : nil,
            replacementElement: nil
        )
    }

    /// What the field says about a selection replace, after the ⌘V was posted.
    public enum ReplacementOutcome: Equatable {
        /// The field holds the result where the selection was (a node swap is vouched, as in
        /// `readFocusedTextDelivery`).
        case landed
        /// The baseline's own field was read, and it is exactly as it was before the paste: the
        /// original text is still where the result belonged. Positive evidence about the field,
        /// not an absence read through whatever happens to be focused.
        case notLanded
        /// Anything else — unreadable, changed in some other way, a different field focused with
        /// nothing to compare. The caller stays where it was before this read existed.
        case unverified
    }

    /// Judges a selection replace, read-only. `readFocusedTextDelivery` can only say "delivered",
    /// so a paste that went nowhere and a field AX cannot read were the same `.unavailable`; the
    /// second half of this tells them apart.
    ///
    /// The miss is read on the baseline's **target element directly**, never through focus. The
    /// case this exists for is focus slipping to the window after the selection was confirmed:
    /// the focused element is then the window, which fails the `CFEqual` and the same-control
    /// vouch, so a focus-based read has nothing to say — while the field itself still answers, and
    /// still holds the original.
    ///
    /// Fails closed to `.unverified` where an unchanged field would prove nothing:
    /// - `mirrorTrusted` is false (a host whose AX value lags its own edits reads unchanged for a
    ///   paste that landed — `AXWriteCapabilityStore.canConfirmDelivery`);
    /// - the baseline never read the field's value or selection;
    /// - the result reads the same as the text it replaces, so a paste that landed leaves the
    ///   field as it was;
    /// - the field's value is unreadable now, or is anything but the baseline's, byte for byte.
    public func readReplacementOutcome(
        expectedText: String,
        baseline: FocusedTextObservation,
        mirrorTrusted: Bool
    ) -> ReplacementOutcome {
        let reading = readFocusedTextDelivery(
            expectedText: expectedText, baseline: baseline, vouchingReplacement: true
        )
        if reading.verification == .delivered { return .landed }
        guard mirrorTrusted, !expectedText.isEmpty,
              let target = baseline.target,
              let beforeValue = baseline.value, let selection = baseline.selectedRange else {
            return .unverified
        }
        let before = beforeValue as NSString
        guard Self.validRange(selection, length: before.length) else { return .unverified }
        if selection.length > 0,
           before.substring(with: selection).normalizedWhitespace == expectedText.normalizedWhitespace {
            return .unverified
        }
        guard let now = focusedTextObservation(for: target).value, now == beforeValue else {
            return .unverified
        }
        return .notLanded
    }

    /// Verifies against `kAXNumberOfCharacters` plus a `kAXStringForRange` read over the insertion
    /// window instead of the whole field — this runs on every 50 ms hold-loop tick.
    ///
    /// It answers only where the answer is the same one the full read gives, and returns `nil`
    /// ("read the whole field") everywhere else, so an element that lacks either attribute, a
    /// count that disagrees with the baseline's UTF-16 units, or a refused range reads exactly as
    /// before. The one answer it gives without a window read is "nothing has landed yet": the
    /// field still has the baseline's length while the expected final length differs.
    private func verifyDeliveryByWindow(
        expectedText: String,
        baseline: FocusedTextObservation?,
        target: AXUIElement
    ) -> TextDeliveryVerification? {
        guard !expectedText.isEmpty,
              let baseline, let beforeValue = baseline.value, let insertion = baseline.selectedRange else { return nil }
        let beforeLength = beforeValue.utf16.count
        // A host counting composed characters (or anything but UTF-16) can report the baseline's
        // length after a paste has landed, which would read as "nothing landed yet".
        guard baseline.numberOfCharacters == beforeLength,
              let count = access.numberOfCharacters(target) else { return nil }
        let (finalLength, overflow) = (beforeLength - insertion.length).addingReportingOverflow(expectedText.utf16.count)
        guard !overflow, insertion.length >= 0, insertion.length <= beforeLength else { return nil }
        if count != finalLength {
            return count == beforeLength ? .unavailable : nil
        }
        guard let finalSelection = access.selectedRange(target) else { return nil }
        let verdict = Self.verifyCore(
            expectedText: expectedText, baseline: baseline, observedLength: count,
            finalSelection: finalSelection, afterValue: nil,
            observedWindow: { [access] window in access.stringForRange(target, window) }
        )
        // A refused or short window read is an unreadable window, not a verdict.
        return verdict == .delivered ? .delivered : nil
    }

    public static func verifyTextDelivery(
        expectedText: String,
        baseline: FocusedTextObservation?,
        after: FocusedTextObservation?,
        staleProbe: String? = nil,
        staleProbeCaseInsensitive: Bool = false
    ) -> TextDeliveryVerification {
        guard !expectedText.isEmpty else { return .delivered }
        guard let baseline, let after,
              let beforeTarget = baseline.target, let afterTarget = after.target,
              CFEqual(beforeTarget, afterTarget),
              let afterValue = after.value, let finalSelection = after.selectedRange else {
            return .unavailable
        }
        let observed = afterValue as NSString
        return verifyCore(
            expectedText: expectedText, baseline: baseline, observedLength: observed.length,
            finalSelection: finalSelection, afterValue: afterValue,
            observedWindow: { observed.substring(with: $0) }
        )
    }

    /// The comparison both reads share. `observedWindow` yields the observed text over a UTF-16
    /// range inside `observedLength`, from the whole value or from a ranged AX read; `afterValue`
    /// is present only when the whole value was read, to check the selection sits on scalar
    /// boundaries.
    private static func verifyCore(
        expectedText: String,
        baseline: FocusedTextObservation,
        observedLength: Int,
        finalSelection: NSRange,
        afterValue: String?,
        observedWindow: (NSRange) -> String?
    ) -> TextDeliveryVerification {
        guard let beforeValue = baseline.value, let insertion = baseline.selectedRange else {
            return .unavailable
        }
        let before = beforeValue as NSString
        guard validRange(insertion, length: before.length),
              validRange(finalSelection, length: observedLength),
              Range(insertion, in: beforeValue) != nil,
              afterValue.map({ Range(finalSelection, in: $0) != nil }) ?? true else { return .unavailable }

        let payloadUnits = expectedText.utf16.count
        let (finalLength, overflow) = (before.length - insertion.length).addingReportingOverflow(payloadUnits)
        guard !overflow, observedLength == finalLength else { return .unavailable }
        let (insertionEnd, endOverflow) = insertion.location.addingReportingOverflow(payloadUnits)
        guard !endOverflow else { return .unavailable }
        let collapsedAfterInsert = finalSelection.location == insertionEnd && finalSelection.length == 0
        let insertedSelection = finalSelection.location == insertion.location && finalSelection.length == payloadUnits
        guard collapsedAfterInsert || insertedSelection else { return .unavailable }

        // Bound in the original UTF-16 coordinates before any normalization. No
        // whole-field lowercasing or occurrence search can move this insertion window.
        let prefixUnits = min(insertion.location, verificationCaretSlackUTF16)
        let suffixUnits = min(before.length - insertion.location - insertion.length, verificationCaretSlackUTF16)
        guard payloadUnits <= maxVerificationScanUTF16 - prefixUnits - suffixUnits else { return .unavailable }
        let lower = insertion.location - prefixUnits
        let prefix = before.substring(with: NSRange(location: lower, length: prefixUnits))
        let suffix = before.substring(with: NSRange(location: insertion.location + insertion.length, length: suffixUnits))
        let requiredWindow = (prefix + expectedText + suffix).normalizedWhitespace
        if insertion.length == payloadUnits {
            let oldWindow = before.substring(with: NSRange(location: lower, length: prefixUnits + insertion.length + suffixUnits))
            guard oldWindow.normalizedWhitespace != requiredWindow else { return .unavailable }
        }
        guard let observedText = observedWindow(
            NSRange(location: lower, length: prefixUnits + payloadUnits + suffixUnits)
        ), observedText.normalizedWhitespace == requiredWindow else { return .unavailable }
        return .delivered
    }

    private static func validRange(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= length
            && range.length <= length - range.location
    }

    /// §2.6: `needle` inside `value`, scanning at most a bounded window.
    ///
    /// Returns `nil` when the value is larger than `maxVerificationScanUTF16` and no caret is
    /// available to bound the search — the caller must treat that as `.unavailable`, never as a
    /// miss. Deliberately conservative: a wrong "missing" answer re-pastes.
    public static func boundedContains(
        _ needle: String,
        in value: String,
        caretLocation: Int?,
        caseInsensitive: Bool = false
    ) -> Bool? {
        guard !needle.isEmpty else { return true }
        let total = value.utf16.count
        let searchValue: String
        if total <= maxVerificationScanUTF16 {
            searchValue = value
        } else {
            // Bound FIRST, fold the window only. Whitespace folding is 1:1 in UTF-16 units (see
            // WhitespaceFolding.swift), so offsets computed on the raw value are valid on folded
            // text — folding the whole value here would reintroduce the full-field O(n) copy this
            // bound exists to prevent, on every 50 ms hold-loop tick.
            guard let caretLocation, caretLocation >= 0, caretLocation <= total else { return nil }
            let needleUnits = needle.utf16.count
            let lower = max(0, caretLocation - needleUnits - verificationCaretSlackUTF16)
            let upper = min(total, caretLocation + verificationCaretSlackUTF16)
            guard lower < upper else { return nil }
            // Mid-surrogate offsets round to scalar boundaries when slicing (verified behaviour) —
            // the slack absorbs the at-most-one-unit shrink at each edge.
            let lowerIndex = String.Index(utf16Offset: lower, in: value)
            let upperIndex = String.Index(utf16Offset: upper, in: value)
            guard lowerIndex < upperIndex else { return nil }
            searchValue = String(value[lowerIndex..<upperIndex])
        }
        // Fold after selecting the window: lowercasing can change UTF-16 length, and
        // applying it to the full value would both move the caret and bypass the bound.
        let haystack = searchValue.normalizedWhitespace
        let expected = needle.normalizedWhitespace
        return caseInsensitive
            ? haystack.lowercased().contains(expected.lowercased())
            : haystack.contains(expected)
    }
}
