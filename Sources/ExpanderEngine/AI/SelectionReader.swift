import ApplicationServices
import Cocoa
import Foundation

/// Synchronous AX read of the current selection for the AI hotkey / palette paths.
///
/// Reads AX attributes only — no synthetic ⌘C. Clipboard ownership belongs to
/// `PasteboardBroker`; an unmanaged copy would corrupt `changeCount` and abandon restore.
///
/// The read is deliberately a *ladder* rather than one attribute. `kAXSelectedTextAttribute` is
/// the only one AppKit apps reliably implement; web views and Electron editors frequently answer
/// it with nothing while happily answering the range-based or text-marker forms. One attribute
/// meant "no text selected" in exactly the apps people most want to enhance a prompt in.
///
/// Policy lives in `SelectionGate.swift` (`evaluate`); this file is the I/O around it.
public enum SelectionReader {
    /// Longer AX messaging timeout used for a single retry after `.cannotComplete`.
    ///
    /// The engine-wide 0.05 s timeout is right for the keystroke path, where a hung app must
    /// never stall typing. It is wrong here: copying a large selection over AX IPC routinely
    /// takes longer than that, and the timeout surfaced as "no text selected" for exactly the
    /// long selections a transform is most useful on. This path is an explicit user gesture, so
    /// paying up to half a second once is the right trade.
    public static let slowReadTimeoutSeconds: Float = 0.5

    /// WebKit / Chromium expose selection through text markers rather than character ranges.
    /// These attribute names are not in the public AX headers but are the documented behaviour
    /// of both engines' accessibility bridges, and are read-only.
    private static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let stringForTextMarkerRangeAttribute = "AXStringForTextMarkerRange"

    public struct Result: Equatable {
        public let text: String
        public let bundleID: String?
        /// True when `AXWriteCapabilityStore.seedVerdict` marks this app as unreliable AX.
        public let isWeakAX: Bool
        /// Live AX read vs. `SelectionMonitor` cache recovery. Diagnostics only.
        public let source: Source

        public init(text: String, bundleID: String?, isWeakAX: Bool, source: Source = .live) {
            self.text = text
            self.bundleID = bundleID
            self.isWeakAX = isWeakAX
            self.source = source
        }
    }

    /// Read the current selection, with a typed reason when there is none.
    ///
    /// Never returns a blank-but-non-empty selection: see `isBlankSelection`.
    public static func readSelection(
        checker: AXContextChecker = .shared,
        muteStore: AppMuteStore = .shared,
        monitor: SelectionMonitor = .shared,
        now: Date = Date(),
        diagnostics: AIDiagnosticsStore? = .shared
    ) -> Outcome {
        let axTrusted = checker.isProcessTrusted()
        let secureInput = AXContextChecker.isSecureEventInputEnabledLive()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmost?.bundleIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostIsOwnProcess = frontmost?.processIdentifier == ownPID

        var candidates: [Candidate] = []
        var focusAvailable = false

        // Skip the AX round-trips entirely when a hard block already applies — they would only
        // burn IPC time to produce a result `evaluate` is going to discard.
        if axTrusted, !secureInput {
            let elements = checker.focusedElementCandidates()
            focusAvailable = !elements.isEmpty

            // This runs on the main thread before the palette can appear, so the total AX budget
            // has to be bounded. Once a read has actually timed out the target app is stalled and
            // further probes only add latency to a result that will not improve — so the first
            // timeout downgrades every remaining read to a single fast attribute.
            var stalling = false
            for (index, element) in elements.enumerated() {
                let read = readSelectedText(
                    from: element,
                    allowSlowRetry: index == 0 && !stalling,
                    allowFallbackAttributes: !stalling
                )
                if read.timedOut { stalling = true }

                var pid: pid_t = 0
                let pidStatus = AXUIElementGetPid(element, &pid)
                let elementBundleID = pidStatus == .success
                    ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                    : nil
                candidates.append(
                    Candidate(
                        text: read.text,
                        // An unreadable pid resolves to "not ours", which prefers using the text
                        // over discarding it. Refusing on an unknown pid would reintroduce the
                        // false "no selection" this whole path exists to remove.
                        isOwnProcess: pidStatus == .success && pid == ownPID,
                        bundleID: elementBundleID
                    )
                )
            }
        }

        let outcome = evaluate(
            axTrusted: axTrusted,
            secureInputActive: secureInput,
            frontmostBundleID: frontmostBundleID,
            frontmostIsOwnProcess: frontmostIsOwnProcess,
            focusAvailable: focusAvailable,
            candidates: candidates,
            cached: monitor.rawCachedSelection(),
            now: now,
            isMuted: { muteStore.isMuted($0) },
            isWeakAX: { Self.isWeakAXApp(bundleID: $0) }
        )

        diagnostics?.recordSelectionRead(
            outcome: describe(outcome),
            bundleID: outcome.result?.bundleID ?? frontmostBundleID,
            candidateCount: candidates.count,
            characters: outcome.result?.text.count ?? 0,
            at: now
        )
        return outcome
    }

    /// Back-compat wrapper: selection or nothing, with the reason discarded.
    ///
    /// Prefer `readSelection()` — a caller that shows the user a message needs the reason, and
    /// this overload is exactly how every path came to say "no text selected" for a revoked
    /// Accessibility grant.
    public static func readSelectedText(
        checker: AXContextChecker = .shared,
        muteStore: AppMuteStore = .shared
    ) -> Result? {
        readSelection(checker: checker, muteStore: muteStore).result
    }

    /// Apps seeded as AX false-success (Chrome, Slack, Electron, …) — treat selection
    /// as untrustworthy for the typed-path staleness gate.
    public static func isWeakAXApp(bundleID: String) -> Bool {
        AXWriteCapabilityStore.seedVerdict(bundleID: bundleID) == .falseSuccess
    }

    /// Stable one-word outcome label for the diagnostic report.
    public static func describe(_ outcome: Outcome) -> String {
        switch outcome {
        case .selection(let result): return result.source.rawValue
        case .failure(let failure): return failure.diagnosticLabel
        }
    }

    // MARK: - AX read ladder

    /// One element's selection read plus whether AX actually timed out getting it.
    ///
    /// The distinction matters: `.cannotComplete` is a stalled app, not an empty selection, and
    /// the two used to be indistinguishable at the call site.
    public struct ElementRead: Equatable {
        public let text: String?
        public let timedOut: Bool

        public init(text: String?, timedOut: Bool) {
            self.text = text
            self.timedOut = timedOut
        }
    }

    /// Shared AX attribute read used by `SelectionMonitor` and the explicit command paths.
    ///
    /// Returns `nil` rather than a blank string so callers cannot mistake "the app answered with
    /// a space" for a real selection.
    ///
    /// - Parameter allowFallbackAttributes: try the range and text-marker forms when the primary
    ///   attribute reports nothing. **Off for high-frequency callers.** `SelectionMonitor` runs
    ///   this from an AX notification that many apps fire on every keystroke; paying two extra
    ///   IPC round-trips there — precisely when there is no selection, which is the common case
    ///   while typing — would put up to 0.1 s of main-thread stall on the typing path.
    public static func copySelectedText(
        from element: AXUIElement,
        allowSlowRetry: Bool = false,
        allowFallbackAttributes: Bool = true
    ) -> String? {
        readSelectedText(
            from: element,
            allowSlowRetry: allowSlowRetry,
            allowFallbackAttributes: allowFallbackAttributes
        ).text
    }

    static func readSelectedText(
        from element: AXUIElement,
        allowSlowRetry: Bool,
        allowFallbackAttributes: Bool
    ) -> ElementRead {
        AXContextChecker.applyMessagingTimeout(to: element)

        let (text, status) = copyAttributeString(element, kAXSelectedTextAttribute as String)
        if let text, !isBlankSelection(text) { return ElementRead(text: text, timedOut: false) }

        var timedOut = status == .cannotComplete

        // A timed-out read is not an empty selection — it is the large-selection case, where the
        // 0.05 s engine-wide timeout is simply too short to copy the string across. Retry once on
        // a longer budget, then put the timeout straight back so the fallback attributes below
        // cannot each cost another half second.
        if allowSlowRetry, status == .cannotComplete {
            AXContextChecker.applyMessagingTimeout(to: element, seconds: slowReadTimeoutSeconds)
            let (retry, retryStatus) = copyAttributeString(element, kAXSelectedTextAttribute as String)
            AXContextChecker.applyMessagingTimeout(to: element)
            timedOut = retryStatus == .cannotComplete
            if let retry, !isBlankSelection(retry) {
                return ElementRead(text: retry, timedOut: false)
            }
        }

        guard allowFallbackAttributes else { return ElementRead(text: nil, timedOut: timedOut) }

        if let ranged = copySelectedTextByRange(element), !isBlankSelection(ranged) {
            return ElementRead(text: ranged, timedOut: false)
        }
        if let marked = copySelectedTextByTextMarker(element), !isBlankSelection(marked) {
            return ElementRead(text: marked, timedOut: false)
        }
        return ElementRead(text: nil, timedOut: timedOut)
    }

    private static func copyAttributeString(
        _ element: AXUIElement,
        _ attribute: String
    ) -> (String?, AXError) {
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard status == .success else { return (nil, status) }
        return (ref as? String, status)
    }

    /// `kAXSelectedTextRange` + `kAXStringForRange`.
    ///
    /// Standard `NSTextView` / `UITextView`-backed elements and several IDE text areas implement
    /// the range pair while leaving `kAXSelectedText` unimplemented.
    private static func copySelectedTextByRange(_ element: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
            let rangeRef,
            CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(rangeRef, to: AXValue.self)
        var range = CFRange(location: 0, length: 0)
        // A zero-length range is a caret, not a selection. Asking for the string of an empty
        // range returns "" in some apps and the *whole document* in others.
        guard AXValueGetValue(axValue, .cfRange, &range), range.length > 0 else { return nil }

        var stringRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axValue,
            &stringRef
        ) == .success else {
            return nil
        }
        return stringRef as? String
    }

    /// WebKit / Chromium text-marker selection (Safari, Chrome, Electron web content).
    private static func copySelectedTextByTextMarker(_ element: AXUIElement) -> String? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            selectedTextMarkerRangeAttribute as CFString,
            &markerRange
        ) == .success, let markerRange else {
            return nil
        }
        var stringRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            stringForTextMarkerRangeAttribute as CFString,
            markerRange,
            &stringRef
        ) == .success else {
            return nil
        }
        return stringRef as? String
    }
}
