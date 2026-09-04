import ApplicationServices
import Cocoa
import Foundation

/// Synchronous AX read of the current selection for the AI hotkey / palette paths.
///
/// Reads AX attributes only — no synthetic ⌘C. Clipboard ownership belongs to
/// `PasteboardBroker`; an unmanaged copy would corrupt `changeCount` and abandon restore.
///
/// The read is deliberately a *ladder* rather than one attribute. Apple documents the whole
/// text group — `accessibilitySelectedText`, `accessibilitySelectedTextRange(s)`,
/// `accessibilityString(for:)`, `accessibilityAttributedString(for:)` — as independently
/// implementable members of `NSAccessibilityProtocol`, and apps implement wildly different
/// subsets. `kAXSelectedTextAttribute` is the only one AppKit apps reliably answer; Chromium
/// does not implement `AXStringForRange` at all and exposes the selection through text markers
/// instead. One attribute meant "no text selected" in exactly the apps people most want to
/// enhance a prompt in.
///
/// Policy lives in `SelectionGate.swift` (`evaluate`); this file is the I/O around it.
public enum SelectionReader {

    /// Internal capability for the only path allowed to synthesize copy. Keeping this private
    /// prevents ordinary selection reads from acquiring the behavior through a Boolean toggle.
    private enum ClipboardFallbackPolicy {
        case disabled
        case explicitAIAction

        var isAuthorized: Bool { self == .explicitAIAction }
    }

    // MARK: - Budgets and limits

    /// Longer AX messaging timeout used for a single retry after `.cannotComplete`.
    ///
    /// The engine-wide 0.05 s timeout is right for the keystroke path, where a hung app must
    /// never stall typing. It is wrong here: copying a large selection over AX IPC routinely
    /// takes longer than that, and the timeout surfaced as "no text selected" for exactly the
    /// long selections a transform is most useful on. This path is an explicit user gesture, so
    /// paying up to half a second once is the right trade.
    public static let slowReadTimeoutSeconds: Float = 0.5

    /// Total wall-clock budget for one explicit selection read, across every probe and rung.
    ///
    /// The ladder is long on purpose and runs on the main thread before a panel can appear.
    /// Unbounded worst case is three focused candidates × four ancestors × six attribute rungs,
    /// each able to burn the AX messaging timeout against one hung app — seconds of beachball.
    /// The budget turns that into "tried until it stopped being reasonable", and records how
    /// far it got so a report can say so.
    public static let readBudgetSeconds: TimeInterval = 1.5

    /// How far up the AX tree to look for the element that actually owns the selection.
    ///
    /// Chromium reports focus on the editable node but also exposes marker attributes on
    /// ancestors, and several native apps put the selection on the enclosing scroll/text area
    /// rather than the focused control. Four hops covers node → group → scroll area → web area
    /// without turning a failed read into a whole-tree crawl.
    public static let maxAncestorHops = 4

    /// Hard ceiling on a selection the AI path will accept.
    ///
    /// Two separate hazards, both real: `AXStringForRange` over a select-all in a large document
    /// copies the entire thing across AX IPC on the main thread, and the model then rejects it
    /// seconds later as `inputTooLarge` anyway. Refuse early, by count, with a message that
    /// names the limit — never by truncating, which would desynchronise the replacement from
    /// the range the app actually has selected.
    public static let maxSelectionCharacters = 200_000

    // MARK: - Attribute names

    /// WebKit / Chromium expose selection through text markers rather than character ranges.
    /// These attribute names are not in the public AX headers but are the documented behaviour
    /// of both engines' accessibility bridges, and are read-only.
    private static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let stringForTextMarkerRangeAttribute = "AXStringForTextMarkerRange"

    /// `accessibilitySelectedTextRanges` — the plural, discontinuous-selection form. Spelled out
    /// rather than taken from the header so the ladder reads as one list of attribute names.
    private static let selectedTextRangesAttribute = "AXSelectedTextRanges"

    public struct Result: Equatable {
        public let text: String
        public let bundleID: String?
        /// True when `AXWriteCapabilityStore.seedVerdict` marks this app as unreliable AX.
        public let isWeakAX: Bool
        /// Live AX read vs. `SelectionMonitor` cache recovery. Diagnostics only.
        public let source: Source
        /// Which rung of the ladder produced the text. Diagnostics only.
        public let via: ReadVia

        public init(
            text: String,
            bundleID: String?,
            isWeakAX: Bool,
            source: Source = .live,
            via: ReadVia = .unknown
        ) {
            self.text = text
            self.bundleID = bundleID
            self.isWeakAX = isWeakAX
            self.source = source
            self.via = via
        }
    }

    /// Read the current selection through Accessibility, with a typed reason when there is none.
    /// This ordinary entry point can never synthesize keyboard input.
    public static func readSelection(
        checker: AXContextChecker = .shared,
        muteStore: AppMuteStore = .shared,
        monitor: SelectionMonitor = .shared,
        now: Date = Date(),
        diagnostics: AIDiagnosticsStore? = .shared,
        clipboardCapture: (() -> PasteboardBroker.CopyCaptureOutcome)? = nil
    ) -> Outcome {
        readSelectionImpl(
            checker: checker,
            muteStore: muteStore,
            monitor: monitor,
            now: now,
            diagnostics: diagnostics,
            clipboardFallbackPolicy: .disabled,
            clipboardCapture: clipboardCapture
        )
    }

    /// Read for a user-invoked AI action, permitting the brokered ⌘C tier only when AX exposes
    /// no focused element. This name is intentionally explicit: a caller cannot silently turn a
    /// general selection read into synthetic input by flipping a Boolean.
    ///
    /// A copy answer remains semantically ambiguous in AX-invisible editors: it may be selected
    /// text or the editor's copy-current-line behavior. The `.clipboard` result source preserves
    /// that provenance for diagnostics and UI; callers must not relabel it as AX-verified.
    public static func readSelectionForExplicitAIAction(
        checker: AXContextChecker = .shared,
        muteStore: AppMuteStore = .shared,
        monitor: SelectionMonitor = .shared,
        now: Date = Date(),
        diagnostics: AIDiagnosticsStore? = .shared,
        clipboardCapture: (() -> PasteboardBroker.CopyCaptureOutcome)? = nil
    ) -> Outcome {
        readSelectionImpl(
            checker: checker,
            muteStore: muteStore,
            monitor: monitor,
            now: now,
            diagnostics: diagnostics,
            clipboardFallbackPolicy: .explicitAIAction,
            clipboardCapture: clipboardCapture
        )
    }

    /// Canonical implementation for both public capabilities. Never returns a blank-but-non-empty
    /// selection; see `isBlankSelection`.
    private static func readSelectionImpl(
        checker: AXContextChecker,
        muteStore: AppMuteStore,
        monitor: SelectionMonitor,
        now: Date,
        diagnostics: AIDiagnosticsStore?,
        clipboardFallbackPolicy: ClipboardFallbackPolicy,
        clipboardCapture: (() -> PasteboardBroker.CopyCaptureOutcome)?
    ) -> Outcome {
        let started = Date()
        let deadline = started.addingTimeInterval(readBudgetSeconds)

        let axTrusted = checker.isProcessTrusted()
        let secureInput = AXContextChecker.isSecureEventInputEnabledLive()

        // Resolve the frontmost app exactly once and thread it through. Reading it separately in
        // each probe let a hotkey pressed mid app-switch wake one app, probe a second, and be
        // reported against a third — which is unfalsifiable from the diagnostic report.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmost?.bundleIdentifier
        let frontmostPID = frontmost?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostIsOwnProcess = frontmostPID == ownPID

        var candidates: [Candidate] = []
        var focusAvailable = false
        var probeSummary = "skipped"

        // Skip the AX round-trips entirely when a hard block already applies — they would only
        // burn IPC time to produce a result `evaluate` is going to discard.
        if axTrusted, !secureInput {
            // `activateManualAccessibilityIfEmpty`: a Chromium app that has never published its
            // accessibility tree answers every focus probe with nothing. Switching it on and
            // re-probing is the difference between reading the selection and reporting that the
            // user has not made one.
            let probe = checker.probeFocusedElements(
                activateManualAccessibilityIfEmpty: true,
                frontmostPID: frontmostPID,
                deadline: deadline
            )
            let elements = probe.candidates
            probeSummary = probe.summary
            focusAvailable = !elements.isEmpty

            var budgetExhausted = false
            // Once a read has actually timed out the target app is stalled and further probes
            // only add latency to a result that will not improve — so the first timeout
            // downgrades every remaining read to a single fast attribute.
            var stalling = false
            for (index, element) in elements.enumerated() {
                guard Date() < deadline else { budgetExhausted = true; break }

                let read = readSelectedText(
                    from: element,
                    allowSlowRetry: index == 0 && !stalling,
                    allowFallbackAttributes: !stalling,
                    deadline: deadline
                )
                if read.timedOut { stalling = true }
                candidates.append(
                    makeCandidate(text: read.text, via: read.via, element: element, ownPID: ownPID)
                )
                // Deliberately no early exit on the first non-blank read. Whether a candidate is
                // *usable* is `evaluate`'s call, not ours: mid app-switch the system-wide probe
                // resolves into the app the user just left, and stopping there would hand the
                // gate a muted app's text as the only option — walking straight around a mute,
                // or refusing while the real selection sat unread on the next probe.
            }

            // Nothing on any focused element. Widen before giving up: the focused node is often
            // not the element that owns the selection — Chromium keeps marker attributes on the
            // enclosing web area, and several native apps answer on the scroll/text area.
            //
            // Not when `stalling`: the target app has already blown one AX timeout, so every
            // extra hop is latency spent on an answer that is not coming. Not when we are
            // frontmost either — widening from our own panel would surface our own UI text, and
            // the cache is the correct recovery for that case.
            if !budgetExhausted,
               !stalling,
               !frontmostIsOwnProcess,
               candidates.allSatisfy({ isBlankSelection($0.text) }),
               Date() < deadline {
                let widened = readFromRelatedElements(
                    of: elements,
                    frontmostPID: frontmostPID,
                    deadline: deadline
                )
                if let widened {
                    candidates.append(
                        makeCandidate(
                            text: widened.text,
                            via: widened.via,
                            element: widened.element,
                            ownPID: ownPID
                        )
                    )
                    focusAvailable = true
                    probeSummary += " widened:\(widened.via.rawValue)"
                }
            }
            if budgetExhausted || Date() >= deadline {
                probeSummary += " budget:exhausted"
            }
        }

        var outcome = evaluate(
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

        // Tier of last resort: a brokered ⌘C, only when the app published no focused element at
        // all and the caller explicitly opted in. Secure Input is re-checked live — it can have
        // been engaged in the time the AX ladder spent failing.
        if clipboardFallbackPolicy.isAuthorized,
           case .failure(let failure) = outcome,
           let frontmostPID,
           shouldAttemptClipboardFallback(
               failure: failure,
               frontmostIsOwnProcess: frontmostIsOwnProcess,
               canPostEvents: CGPreflightPostEventAccess(),
               secureInputActive: AXContextChecker.isSecureEventInputEnabledLive(),
               sourceAppStillFrontmost: PasteboardBroker.frontmostProcessMatches(
                   expectedPID: frontmostPID,
                   actualPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
               )
           ) {
            let capture = clipboardCapture?()
                ?? PasteboardBroker.shared.captureSelectionViaCopy(
                    expectedFrontmostPID: frontmostPID
                )
            probeSummary += " clipboard:\(capture.diagnosticLabel)"
            if case .captured(let text) = capture,
               let rescued = outcomeForClipboardCapture(text: text, bundleID: frontmostBundleID) {
                outcome = rescued
            }
        }

        let elapsedMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        let label = describe(outcome)
        let resolvedBundleID = outcome.result?.bundleID ?? frontmostBundleID
        let via = outcome.result?.via ?? .unknown
        let safeBundleID = DevTypeLog.boundedPublicIdentifier(
            resolvedBundleID,
            label: "bundleID"
        )
        let safeProbeSummary = DevTypeLog.boundedPublicIdentifier(
            probeSummary,
            label: "selectionProbes"
        )

        diagnostics?.recordSelectionRead(
            outcome: label,
            bundleID: resolvedBundleID,
            candidateCount: candidates.count,
            characters: outcome.result?.text.count ?? 0,
            probeSummary: probeSummary,
            via: via.rawValue,
            elapsedMilliseconds: elapsedMilliseconds,
            at: now
        )

        // Privacy: outcome, app, attribute, and length. Never the text.
        let logLine = """
            [Selection] read outcome=\(label) \
            app=\(safeBundleID) \
            via=\(via.rawValue) \
            candidates=\(candidates.count) \
            chars=\(outcome.result?.text.count ?? 0) \
            elapsedMs=\(elapsedMilliseconds) \
            probes=\(safeProbeSummary)
            """
        if outcome.result == nil {
            DevTypeLog.selection.error("\(logLine, privacy: .public)")
        } else {
            DevTypeLog.selection.info("\(logLine, privacy: .public)")
        }
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

    private static func makeCandidate(
        text: String?,
        via: ReadVia,
        element: AXUIElement,
        ownPID: pid_t
    ) -> Candidate {
        var pid: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &pid)
        let elementBundleID = pidStatus == .success
            ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            : nil
        return Candidate(
            text: text,
            // An unreadable pid resolves to "not ours", which prefers using the text over
            // discarding it. Refusing on an unknown pid would reintroduce the false "no
            // selection" this whole path exists to remove.
            isOwnProcess: pidStatus == .success && pid == ownPID,
            bundleID: elementBundleID,
            via: via
        )
    }

    // MARK: - Widening past the focused element

    struct WidenedRead {
        let text: String
        let via: ReadVia
        let element: AXUIElement
    }

    /// Bounded search outward from the focused elements: ancestors first, then the app element.
    ///
    /// Only ever runs when every focused element reported nothing, so its cost is paid on a read
    /// that would otherwise have failed outright.
    private static func readFromRelatedElements(
        of elements: [AXUIElement],
        frontmostPID: pid_t?,
        deadline: Date
    ) -> WidenedRead? {
        for element in elements {
            for (hop, ancestor) in ancestors(of: element).enumerated() {
                guard Date() < deadline else { return nil }
                let read = readSelectedText(
                    from: ancestor,
                    allowSlowRetry: false,
                    allowFallbackAttributes: true,
                    deadline: deadline
                )
                if let text = read.text, !isBlankSelection(text) {
                    return WidenedRead(text: text, via: .ancestor(hop + 1), element: ancestor)
                }
            }
        }

        // Last resort: the application element itself. Chromium answers the marker attributes
        // here even when no focused node does, which is the difference between a working Prompt
        // Enhance in an Electron app and a "no selection" alert.
        guard let frontmostPID, frontmostPID > 0, Date() < deadline else { return nil }
        let appElement = AXUIElementCreateApplication(frontmostPID)
        AXContextChecker.applyMessagingTimeout(to: appElement)
        let read = readSelectedText(
            from: appElement,
            allowSlowRetry: false,
            allowFallbackAttributes: true,
            deadline: deadline
        )
        guard let text = read.text, !isBlankSelection(text) else { return nil }
        return WidenedRead(text: text, via: .applicationElement, element: appElement)
    }

    /// Up to `limit` `AXParent` hops, with a cycle guard.
    ///
    /// The guard is not theoretical: a malformed AX tree that reports itself (or a sibling
    /// already visited) as its own parent would otherwise walk the same node `limit` times and
    /// pay a full attribute ladder for each.
    static func ancestors(of element: AXUIElement, limit: Int = maxAncestorHops) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var current = element
        for _ in 0..<max(0, limit) {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current,
                kAXParentAttribute as CFString,
                &parentRef
            ) == .success,
                let parentRef,
                CFGetTypeID(parentRef) == AXUIElementGetTypeID() else {
                break
            }
            let parent = unsafeBitCast(parentRef, to: AXUIElement.self)
            if CFEqual(parent, element) || result.contains(where: { CFEqual($0, parent) }) {
                break
            }
            AXContextChecker.applyMessagingTimeout(to: parent)
            result.append(parent)
            current = parent
        }
        return result
    }

    // MARK: - AX read ladder

    /// One element's selection read: the text, how it was obtained, and whether AX timed out.
    ///
    /// The timeout flag matters on its own: `.cannotComplete` is a stalled app, not an empty
    /// selection, and the two used to be indistinguishable at the call site.
    public struct ElementRead: Equatable {
        public let text: String?
        public let timedOut: Bool
        public let via: ReadVia

        public init(text: String?, timedOut: Bool, via: ReadVia = .unknown) {
            self.text = text
            self.timedOut = timedOut
            self.via = via
        }
    }

    /// Shared AX attribute read used by `SelectionMonitor` and the explicit command paths.
    ///
    /// Returns `nil` rather than a blank string so callers cannot mistake "the app answered with
    /// a space" for a real selection.
    ///
    /// - Parameter allowFallbackAttributes: try the range, attributed, value-substring, plural
    ///   and text-marker forms when the primary attribute reports nothing. **Off for
    ///   high-frequency callers**, which pay for the extra IPC on every keystroke.
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
        allowFallbackAttributes: Bool,
        deadline: Date? = nil
    ) -> ElementRead {
        AXContextChecker.applyMessagingTimeout(to: element)

        let (text, status) = copyAttributeString(element, kAXSelectedTextAttribute as String)
        if let text, !isBlankSelection(text) {
            return ElementRead(text: text, timedOut: false, via: .selectedText)
        }

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
                return ElementRead(text: retry, timedOut: false, via: .selectedTextSlow)
            }
        }

        guard allowFallbackAttributes else {
            return ElementRead(text: nil, timedOut: timedOut, via: .unknown)
        }

        // `AXSelectedTextRange` is read once and reused by the three rungs that need it: an app
        // that does not implement it drops out of all three after a single round-trip.
        if let rangeValue = copySelectedRangeValue(element) {
            if let ranged = copyStringForRange(element, rangeValue, attributed: false),
               !isBlankSelection(ranged) {
                return ElementRead(text: ranged, timedOut: false, via: .stringForRange)
            }
            guard deadline.map({ Date() < $0 }) ?? true else {
                return ElementRead(text: nil, timedOut: timedOut, via: .unknown)
            }
            // Apple documents `accessibilityAttributedString(for:)` separately from
            // `accessibilityString(for:)`, and rich-text views (Mail, Notes, TextEdit RTF)
            // routinely implement only the attributed one.
            if let attributed = copyStringForRange(element, rangeValue, attributed: true),
               !isBlankSelection(attributed) {
                return ElementRead(text: attributed, timedOut: false, via: .attributedStringForRange)
            }
            // Neither parameterized form implemented, but the element still exposes its whole
            // value: slice it with the selected range. UTF-16 offsets, so this goes through
            // NSString — `String.Index` arithmetic would corrupt any selection containing an
            // emoji or a combining mark.
            if let sliced = copyValueSubstring(element, rangeValue), !isBlankSelection(sliced) {
                return ElementRead(text: sliced, timedOut: false, via: .valueSubstring)
            }
        }

        guard deadline.map({ Date() < $0 }) ?? true else {
            return ElementRead(text: nil, timedOut: timedOut, via: .unknown)
        }

        if let plural = copySelectedTextByRanges(element), !isBlankSelection(plural) {
            return ElementRead(text: plural, timedOut: false, via: .selectedTextRanges)
        }

        guard deadline.map({ Date() < $0 }) ?? true else {
            return ElementRead(text: nil, timedOut: timedOut, via: .unknown)
        }

        if let marked = copySelectedTextByTextMarker(element), !isBlankSelection(marked) {
            return ElementRead(text: marked, timedOut: false, via: .textMarker)
        }
        return ElementRead(text: nil, timedOut: timedOut, via: .unknown)
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

    /// `kAXSelectedTextRange` as an `AXValue`, rejecting carets and absurd ranges.
    private static func copySelectedRangeValue(_ element: AXUIElement) -> AXValue? {
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
        guard isUsableSelectedRange(axValue) else { return nil }
        return axValue
    }

    /// A zero-length range is a caret, not a selection: asking for the string of an empty range
    /// returns "" in some apps and the *whole document* in others. A negative location is a
    /// malformed answer, and a length past `maxSelectionCharacters` is a select-all we refuse to
    /// drag across AX IPC on the main thread.
    private static func isUsableSelectedRange(_ value: AXValue) -> Bool {
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range) else { return false }
        return range.location >= 0 && range.length > 0 && range.length <= maxSelectionCharacters
    }

    /// `kAXStringForRange` / `kAXAttributedStringForRange`.
    ///
    /// Standard `NSTextView`-backed elements and several IDE text areas implement one of these
    /// while leaving `kAXSelectedText` unimplemented.
    private static func copyStringForRange(
        _ element: AXUIElement,
        _ range: AXValue,
        attributed: Bool
    ) -> String? {
        let attribute = attributed
            ? kAXAttributedStringForRangeParameterizedAttribute
            : kAXStringForRangeParameterizedAttribute
        var stringRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute as CFString,
            range,
            &stringRef
        ) == .success, let stringRef else {
            return nil
        }
        if attributed {
            return (stringRef as? NSAttributedString)?.string
        }
        return stringRef as? String
    }

    /// Documents past this length are not sliced client-side.
    ///
    /// `copyValueSubstring` has to pull the element's *whole* value across AX IPC to cut a
    /// selection out of it. The range guard bounds the selection; nothing bounds the document.
    /// Selecting one line in a 50 MB log would otherwise drag all 50 MB onto the main thread —
    /// the pathological case for a rung that only exists as a third fallback anyway.
    static let maxSliceableDocumentCharacters = 2_000_000

    /// `kAXValue` sliced by the selected range, for elements implementing neither parameterized
    /// string attribute.
    private static func copyValueSubstring(_ element: AXUIElement, _ range: AXValue) -> String? {
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(range, .cfRange, &cfRange) else { return nil }

        // One cheap integer read decides whether the expensive one is worth making.
        var countRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &countRef
        ) == .success, let count = countRef as? Int, count > maxSliceableDocumentCharacters {
            return nil
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success, let valueRef else {
            return nil
        }
        let string: String?
        if let plain = valueRef as? String {
            string = plain
        } else if let attributed = valueRef as? NSAttributedString {
            string = attributed.string
        } else {
            string = nil
        }
        guard let string else { return nil }
        return substring(of: string, utf16Range: cfRange)
    }

    /// UTF-16-safe slice, bounds-checked against the value the app just handed us.
    ///
    /// AX ranges are UTF-16 offsets and apps do return stale ones — a range captured before the
    /// document shrank would trap `NSString.substring(with:)` outright.
    static func substring(of string: String, utf16Range range: CFRange) -> String? {
        let ns = string as NSString
        guard range.location >= 0,
              range.length > 0,
              range.location <= ns.length,
              range.location + range.length <= ns.length else {
            return nil
        }
        return ns.substring(with: NSRange(location: range.location, length: range.length))
    }

    /// `accessibilitySelectedTextRanges` — the discontinuous-selection form.
    ///
    /// Apple documents it alongside the singular attribute, and multi-cursor editors answer it
    /// when the singular range reports only the last caret. Pieces are joined with newlines,
    /// which is what a multi-cursor copy produces in every editor that supports one.
    private static func copySelectedTextByRanges(_ element: AXUIElement) -> String? {
        var rangesRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            selectedTextRangesAttribute as CFString,
            &rangesRef
        ) == .success,
            let values = rangesRef as? [AnyObject], !values.isEmpty else {
            return nil
        }

        var pieces: [String] = []
        var total = 0
        for value in values {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { continue }
            let axValue = unsafeBitCast(value, to: AXValue.self)
            guard isUsableSelectedRange(axValue) else { continue }
            guard let piece = copyStringForRange(element, axValue, attributed: false)
                ?? copyStringForRange(element, axValue, attributed: true)
                ?? copyValueSubstring(element, axValue) else {
                continue
            }
            total += piece.count
            // The per-range guard bounds each piece; this bounds their sum.
            guard total <= maxSelectionCharacters else { return nil }
            pieces.append(piece)
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    /// WebKit / Chromium text-marker selection (Safari, Chrome, Electron web content).
    ///
    /// Chromium does not implement `AXStringForRange` at all, so for the entire Electron
    /// ecosystem this rung is not a fallback — it is the only one that ever answers.
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
        if let plain = stringRef as? String { return plain }
        return (stringRef as? NSAttributedString)?.string
    }
}
