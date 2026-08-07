import AppKit
import ApplicationServices
import Foundation

/// §8.1: "did the text actually land in the field?" — and nothing else.
///
/// This is the only evidence the pipeline ever has that a paste worked: `CGEvent.post` returning
/// is not delivery proof, and many hosts (Chrome, Electron, most terminals) cannot be read through
/// AX at all. Everything here therefore has three outcomes, never two — `.unavailable` is a
/// first-class answer and must never be collapsed into `.failed`, because `.failed` is what
/// triggers a re-paste.
public final class DeliveryVerifier {
    public static let shared = DeliveryVerifier()

    public struct FocusedTextObservation: Equatable {
        public let value: String?
        public let selectedText: String?
        /// §2.6: `AXSelectedTextRange.location`, when it was worth one extra AX round trip to read
        /// it (large fields only). Bounds the containment scan below.
        public let caretLocation: Int?

        public init(value: String?, selectedText: String?, caretLocation: Int? = nil) {
            self.value = value
            self.selectedText = selectedText
            self.caretLocation = caretLocation
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
    /// wrong `.failed` (which would re-paste and duplicate the user's text).
    public static let maxVerificationScanUTF16 = 32_768
    /// Slack around the caret when scanning a large field — hosts may place the caret a few units
    /// past the inserted text (trailing newline normalisation, autocorrect).
    public static let verificationCaretSlackUTF16 = 512

    public init() {}

    // MARK: - Observation

    public func captureFocusedTextObservation() -> FocusedTextObservation? {
        guard let axElement = AXContextChecker.shared.focusedElement() else { return nil }
        return focusedTextObservation(for: axElement)
    }

    public func focusedTextObservation(for axElement: AXUIElement) -> FocusedTextObservation {
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

        // §2.6 / §2.2: the caret read is one more AX IPC round trip (up to `messagingTimeout`), so
        // only pay for it when the field is large enough that the unbounded scan would cost more.
        var caretLocation: Int?
        if let value, value.utf16.count > Self.maxVerificationScanUTF16 {
            var rangeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
               let rangeValue = rangeRef,
               CFGetTypeID(rangeValue) == AXValueGetTypeID() {
                var range = CFRange(location: 0, length: 0)
                if AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range) {
                    caretLocation = range.location
                }
            }
        }

        return FocusedTextObservation(
            value: value,
            selectedText: selectedText,
            caretLocation: caretLocation
        )
    }

    // MARK: - Verification

    public func verifyFocusedTextDelivery(
        expectedText: String,
        baseline: FocusedTextObservation?,
        staleProbe: String? = nil,
        staleProbeCaseInsensitive: Bool = false
    ) -> TextDeliveryVerification {
        Self.verifyTextDelivery(
            expectedText: expectedText,
            baseline: baseline,
            after: captureFocusedTextObservation(),
            staleProbe: staleProbe,
            staleProbeCaseInsensitive: staleProbeCaseInsensitive
        )
    }

    public static func verifyTextDelivery(
        expectedText: String,
        baseline: FocusedTextObservation?,
        after: FocusedTextObservation?,
        staleProbe: String? = nil,
        staleProbeCaseInsensitive: Bool = false
    ) -> TextDeliveryVerification {
        guard !expectedText.isEmpty else { return .delivered }
        guard let after else { return .unavailable }
        if after.selectedText == expectedText {
            return .delivered
        }
        guard let value = after.value else {
            return .unavailable
        }
        // §2.6: bounded containment. `nil` means "too large to scan and no caret to bound it" —
        // that is not evidence of failure.
        guard let containsExpected = boundedContains(
            expectedText,
            in: value,
            caretLocation: after.caretLocation
        ) else {
            return .unavailable
        }
        guard containsExpected else {
            // The expected text is absent — but absence is only *evidence of a missed paste* if
            // the field is otherwise unchanged. If anything moved since the baseline, something
            // landed, and reporting `.failed` here makes the hold loop post a second Cmd+V that
            // duplicates it. Virtualised web views (Electron, Chromium) routinely report a
            // readable AXValue that never contains what was just pasted, which is exactly the
            // case that produced doubled expansions.
            if let baseline {
                let baselineValue = baseline.value
                if baselineValue != value || baseline.selectedText != after.selectedText {
                    return .unavailable
                }
            }
            // §8.4 staleness oracle: `staleProbe` is text the pipeline *provably removed* from
            // the field before pasting (the erased trigger, deleted by counted backspaces). A
            // read that still shows it is a stale mirror by construction — its "expected text
            // missing" answer is testimony about a field state that no longer exists, and acting
            // on it duplicates the paste. When the probe legitimately recurs elsewhere in the
            // document this errs toward `.unavailable`, which suppresses corrections — the safe
            // direction by design.
            //
            // Case-insensitive triggers carry the *snippet's* casing in the plan while the field
            // held whatever the user typed ("SLML" vs "slml"), so the scan must fold case exactly
            // like the erase-precondition comparison does — a probe the user's casing can dodge
            // protects nothing.
            if let staleProbe, !staleProbe.isEmpty {
                let probeHit: Bool
                if staleProbeCaseInsensitive {
                    probeHit = boundedContains(
                        staleProbe.lowercased(),
                        in: value.lowercased(),
                        caretLocation: after.caretLocation
                    ) == true
                } else {
                    probeHit = boundedContains(
                        staleProbe,
                        in: value,
                        caretLocation: after.caretLocation
                    ) == true
                }
                if probeHit { return .unavailable }
            }
            return .failed
        }
        guard let baseline else {
            return .delivered
        }
        let baselineContainsExpected = baseline.value.flatMap {
            boundedContains(expectedText, in: $0, caretLocation: baseline.caretLocation)
        } ?? false
        if value != baseline.value || after.selectedText != baseline.selectedText || !baselineContainsExpected {
            return .delivered
        }
        return .unavailable
    }

    /// §2.6: `needle` inside `value`, scanning at most a bounded window.
    ///
    /// Returns `nil` when the value is larger than `maxVerificationScanUTF16` and no caret is
    /// available to bound the search — the caller must treat that as `.unavailable`, never as a
    /// miss. Deliberately conservative: a wrong "missing" answer re-pastes.
    public static func boundedContains(
        _ needle: String,
        in value: String,
        caretLocation: Int?
    ) -> Bool? {
        guard !needle.isEmpty else { return true }
        let total = value.utf16.count
        if total <= maxVerificationScanUTF16 {
            return value.contains(needle)
        }
        guard let caretLocation, caretLocation >= 0, caretLocation <= total else { return nil }
        let needleUnits = needle.utf16.count
        let lower = max(0, caretLocation - needleUnits - verificationCaretSlackUTF16)
        let upper = min(total, caretLocation + verificationCaretSlackUTF16)
        guard lower < upper else { return nil }
        let lowerIndex = String.Index(utf16Offset: lower, in: value)
        let upperIndex = String.Index(utf16Offset: upper, in: value)
        guard lowerIndex < upperIndex else { return nil }
        return value[lowerIndex..<upperIndex].contains(needle)
    }
}
