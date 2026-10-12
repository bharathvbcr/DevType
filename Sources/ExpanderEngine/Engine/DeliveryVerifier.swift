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

        public init(
            value: String?, selectedText: String?, caretLocation: Int? = nil,
            selectedRange: NSRange? = nil, target: AXUIElement? = nil
        ) {
            self.value = value
            self.selectedText = selectedText
            self.caretLocation = selectedRange?.location ?? caretLocation
            self.selectedRange = selectedRange
            self.target = target
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
            observation: { DeliveryVerifier.fullObservation(for: $0) }
        )
    }

    private let access: TextAccess

    public init() { access = .live }

    init(access: TextAccess) { self.access = access }

    // MARK: - Observation

    public func captureFocusedTextObservation(focus: FocusedElementSource) -> FocusedTextObservation? {
        guard let axElement = focus.element else { return nil }
        return focusedTextObservation(for: axElement)
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

    /// §2.2: a documented re-check. The live focus is compared (`CFEqual`) against the baseline's
    /// target on every call — this runs on each paste-hold tick precisely to notice the user
    /// moving, so it must never be handed a threaded element.
    public func verifyFocusedTextDelivery(
        expectedText: String,
        baseline: FocusedTextObservation?,
        staleProbe: String? = nil,
        staleProbeCaseInsensitive: Bool = false
    ) -> TextDeliveryVerification {
        guard let target = baseline?.target,
              let current = access.focusedElement(), CFEqual(target, current) else {
            return .unavailable
        }
        if let windowed = verifyDeliveryByWindow(expectedText: expectedText, baseline: baseline, target: target) {
            return windowed
        }
        return Self.verifyTextDelivery(
            expectedText: expectedText, baseline: baseline,
            after: focusedTextObservation(for: target), staleProbe: staleProbe,
            staleProbeCaseInsensitive: staleProbeCaseInsensitive
        )
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
              let baseline, let beforeValue = baseline.value, let insertion = baseline.selectedRange,
              let count = access.numberOfCharacters(target) else { return nil }
        let beforeLength = beforeValue.utf16.count
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
