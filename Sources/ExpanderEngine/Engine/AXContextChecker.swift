import ApplicationServices
import Carbon.HIToolbox
import Cocoa

public final class AXContextChecker {
    public static let shared = AXContextChecker()

    /// Short AX IPC timeout so hung target apps cannot stall gates/inject (~default is multi-second).
    public static let messagingTimeoutSeconds: Float = 0.05

    /// Delay before a single focus-query retry after `.cannotComplete` (main thread only).
    public static let focusQueryRetryDelaySeconds: TimeInterval = 0.03

    /// Stable refuse reason when Secure Event Input is locked.
    public static let secureInputActiveReason = "Secure Input active — expand blocked"

    /// Documented allow when every AX focus probe returns no value, Post Events is granted,
    /// and Secure Event Input is off. Secure-field / IME checks remain fail-closed whenever a
    /// focused element *is* available. Without Post Events, missing focus stays refuse.
    public static let hidWithoutAXFocusAllowReason =
        "ok (AX focus unavailable — HID allowed with Post Events)"

    /// Result of querying `kAXFocusedUIElement` (errors are not collapsed to “missing”).
    public enum FocusQueryResult {
        case available(AXUIElement)
        case missing
        case axFailure(AXError)
        case untrusted
    }

    /// Single expand-gate decision used by deferred expand, inject, and diagnostics.
    public struct ExpandGateDecision {
        public var shouldBlock: Bool
        public var reason: String
        public var snapshot: DiagnosticReport.ExpandGateSnapshot
        public var focus: FocusQueryResult

        public init(
            shouldBlock: Bool,
            reason: String,
            snapshot: DiagnosticReport.ExpandGateSnapshot,
            focus: FocusQueryResult
        ) {
            self.shouldBlock = shouldBlock
            self.reason = reason
            self.snapshot = snapshot
            self.focus = focus
        }
    }

    private let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "co.zeit.hyper",
        "org.tabby",
        "com.raphaelamorim.rio",
        "org.contourterminal.Contour",
        "com.cmuxterm.app",
    ]

    /// Editors that host integrated terminals (treat as shell-like when AX role looks terminal-ish).
    private let ideBundleIDPrefixes: [String] = [
        "com.todesktop.",           // Cursor
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code",
        "com.apple.dt.Xcode"
    ]

    public init() {}

    /// Whether this process is trusted for Accessibility (no prompt).
    public func isProcessTrusted() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Applies `AXUIElementSetMessagingTimeout` so gates/inject fail fast on hung apps.
    public static func applyMessagingTimeout(to element: AXUIElement, seconds: Float = messagingTimeoutSeconds) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    /// System-wide AX element with messaging timeout applied.
    public func systemWideElement() -> AXUIElement {
        let systemWide = AXUIElementCreateSystemWide()
        Self.applyMessagingTimeout(to: systemWide)
        return systemWide
    }

    /// Pure policy: retry focus query once after `.cannotComplete` on the first attempt only.
    public static func shouldRetryFocusQuery(error: AXError, attemptIndex: Int) -> Bool {
        attemptIndex == 0 && error == .cannotComplete
    }

    /// Maps a focus-query failure to a stable fail-closed reason string.
    public static func reasonForFocusQueryFailure(_ error: AXError) -> String {
        if error == .cannotComplete {
            return "AX focus query timed out — expand blocked (fail-closed)"
        }
        return "AX focus query failed (code \(error.rawValue)) — expand blocked (fail-closed)"
    }

    /// Maps focus query result to a fail-closed block reason, or `nil` when focus is available.
    public static func focusBlockReason(for focus: FocusQueryResult) -> String? {
        switch focus {
        case .available:
            return nil
        case .missing:
            return "No focused AX element — expand blocked (fail-closed)"
        case .axFailure(let error):
            return reasonForFocusQueryFailure(error)
        case .untrusted:
            return "AXIsProcessTrusted false — expand blocked (fail-closed)"
        }
    }

    /// Pure policy: allow HID expand without AX focus when every probe returned `.missing`,
    /// Post Events is granted, and Secure Event Input is off (any frontmost app).
    /// Does **not** apply to `.axFailure` / `.untrusted` (those stay fail-closed).
    public static func mayAllowHIDExpandWithoutAXFocus(
        focus: FocusQueryResult,
        canPostEvents: Bool,
        secureInputEnabled: Bool
    ) -> Bool {
        guard case .missing = focus else { return false }
        return canPostEvents && !secureInputEnabled
    }

    /// Pure policy: Inline Search / hotkey may attempt HID clipboard paste into a password field.
    /// Requires explicit intent, Post Events, nothing to erase, and no active IME.
    /// Callers still force HID-only (never AX) and may bypass live Secure Input / secure-field refuses.
    public static func mayAllowSecureClipboardPaste(
        intent: Bool,
        canPostEvents: Bool,
        eraseEmpty: Bool,
        hasIME: Bool
    ) -> Bool {
        intent && canPostEvents && eraseEmpty && !hasIME
    }

    /// Live Secure Event Input check (not the polled tap flag).
    public static func isSecureEventInputEnabledLive() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// Focused AX element query with typed errors. Retries once on `.cannotComplete` when on the main thread.
    public func queryFocusedElement(allowTimeoutRetry: Bool = true) -> FocusQueryResult {
        let first = copyFocusedElementOnce()
        guard allowTimeoutRetry,
              case .axFailure(let error) = first,
              Self.shouldRetryFocusQuery(error: error, attemptIndex: 0),
              Thread.isMainThread else {
            return first
        }
        Thread.sleep(forTimeInterval: Self.focusQueryRetryDelaySeconds)
        return copyFocusedElementOnce()
    }

    /// Focused AX element, if available (errors collapse to `nil` for legacy callers).
    public func focusedElement() -> AXUIElement? {
        if case .available(let element) = queryFocusedElement() {
            return element
        }
        return nil
    }

    /// Every distinct focused element the three AX probes can resolve, in probe order.
    ///
    /// `focusedElement()` returns the *first* probe that answers, which is right for the
    /// keystroke path (cheapest wins) but wrong when the question is "where is the user's
    /// selection?". The system-wide probe and the app-scoped probe routinely resolve to
    /// different elements — a browser window vs. the web area inside it — and only one of them
    /// reports the selection. Trying only the winner is how a real selection reads as none.
    ///
    /// Costs up to three AX round-trips, so this is for explicit user gestures (AI hotkey,
    /// palette) and never for the per-keystroke gate.
    public func focusedElementCandidates() -> [AXUIElement] {
        probeFocusedElements(activateManualAccessibilityIfEmpty: false).candidates
    }

    /// Focus probe with the per-probe outcome kept, and an optional Chromium wake-up.
    public struct FocusProbeResult {
        public let candidates: [AXUIElement]
        /// Per-probe status in probe order, e.g. `systemWide:noValue appScoped:noValue chain:noValue`.
        /// Recorded verbatim in the diagnostic report — "no candidates" alone cannot tell a
        /// silent app apart from a timing out one.
        public let summary: String
        /// Manual-accessibility state observed on the rescue attempt; `nil` when no rescue ran.
        public let manualAccessibility: ManualAccessibilityState?

        /// True when `AXManualAccessibility` was switched on for the target during this call.
        public var activatedManualAccessibility: Bool {
            manualAccessibility == .activatedNow
        }

        public init(
            candidates: [AXUIElement],
            summary: String,
            manualAccessibility: ManualAccessibilityState?
        ) {
            self.candidates = candidates
            self.summary = summary
            self.manualAccessibility = manualAccessibility
        }
    }

    /// Resolve every focused-element candidate, waking a Chromium tree if nothing answered.
    ///
    /// - Parameters:
    ///   - frontmostPID: the app to scope the probes to. **Pass this.** Resolving
    ///     `NSWorkspace.frontmostApplication` separately inside each probe means a read taken
    ///     while the window server is mid-switch can wake one app, probe a second, and be
    ///     reported against a third.
    ///   - deadline: caller's overall budget; the settle poll never runs past it.
    public func probeFocusedElements(
        activateManualAccessibilityIfEmpty: Bool,
        frontmostPID: pid_t? = nil,
        deadline: Date? = nil
    ) -> FocusProbeResult {
        let pid = frontmostPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let first = runFocusProbes(frontmostPID: pid)
        guard first.candidates.isEmpty, activateManualAccessibilityIfEmpty else {
            return FocusProbeResult(
                candidates: first.candidates,
                summary: first.summary,
                manualAccessibility: nil
            )
        }
        guard let pid, pid > 0 else {
            return FocusProbeResult(
                candidates: [],
                summary: first.summary + " manualAX:noFrontmost",
                manualAccessibility: nil
            )
        }

        // §8.8: never run the rescue against ourselves. The wake-up is Chromium's opt-in switch and
        // DevType is not Chromium — it answers `attributeUnsupported` — and the settle poll then
        // sleeps the main thread for the whole budget waiting for a tree that already exists and
        // has no focused element in it. Field report: `manualAX:unsupported polls:10`, 332 ms, for
        // a `noFocus` that was decided before the first poll. When we are frontmost the answer the
        // explicit paths want comes from `SelectionMonitor`'s cache, not from our own UI: an
        // own-process element only ever wins the gate as a last resort, and if our app had a
        // focused one the first probe would already have returned it.
        guard Self.mayRescueFocus(pid: pid) else {
            return FocusProbeResult(
                candidates: [],
                summary: first.summary + " manualAX:ownProcess",
                manualAccessibility: nil
            )
        }

        let state = ensureManualAccessibility(pid: pid)
        guard Self.shouldSettlePollAfterManualAccessibility(state) else {
            return FocusProbeResult(
                candidates: [],
                summary: first.summary + " manualAX:\(state.rawValue)",
                manualAccessibility: state
            )
        }

        // Chromium builds the tree asynchronously after the switch is flipped, so the very next
        // read still answers nothing. Poll briefly rather than making the user press the hotkey
        // twice. Bounded, and only ever reached on an explicit gesture in an app that had no
        // focus at all.
        let settleDeadline = Self.settlePollDeadline(now: Date(), budget: deadline)
        var last = first
        var polls = 0
        while Date() < settleDeadline {
            Thread.sleep(forTimeInterval: Self.manualAccessibilityPollSeconds)
            polls += 1
            last = runFocusProbes(frontmostPID: pid)
            if !last.candidates.isEmpty { break }
        }
        return FocusProbeResult(
            candidates: last.candidates,
            summary: last.summary + " manualAX:\(state.rawValue) polls:\(polls)",
            manualAccessibility: state
        )
    }

    private struct FocusProbeRun {
        var candidates: [AXUIElement]
        var summary: String
    }

    private func runFocusProbes(frontmostPID: pid_t?) -> FocusProbeRun {
        var candidates: [AXUIElement] = []
        var parts: [String] = []

        func append(_ label: String, _ result: FocusQueryResult) {
            switch result {
            case .available(let element):
                parts.append("\(label):available")
                guard !candidates.contains(where: { CFEqual($0, element) }) else { return }
                candidates.append(element)
            case .missing:
                parts.append("\(label):noValue")
            case .axFailure(let error):
                parts.append("\(label):err\(error.rawValue)")
            case .untrusted:
                parts.append("\(label):untrusted")
            }
        }

        append("systemWide", mapFocusCopy(copyFocusedUIElement(from: systemWideElement())))

        if let frontmostPID, frontmostPID > 0 {
            let appElement = AXUIElementCreateApplication(frontmostPID)
            Self.applyMessagingTimeout(to: appElement)
            append("appScoped", mapFocusCopy(copyFocusedUIElement(from: appElement)))
        } else {
            parts.append("appScoped:noFrontmost")
        }

        append("chain", copyFocusedElementViaFocusedApplicationChain().mapped)
        return FocusProbeRun(candidates: candidates, summary: parts.joined(separator: " "))
    }

    // MARK: - Chromium / Electron manual accessibility

    /// Chromium's opt-in switch for publishing its accessibility tree to a client.
    ///
    /// Chromium keeps the tree off until an assistive client asks for it, because building and
    /// maintaining it is expensive. Until then the app answers *every* focus query with nothing,
    /// which is exactly the `axCandidates=0 outcome=noFocus` a Claude Desktop selection produced:
    /// not an empty selection, not a timeout — an accessibility tree that was never turned on.
    /// This affects every Electron app (Claude Desktop, Slack, Discord, VS Code, …) and Chrome
    /// itself, i.e. much of where people want to enhance a prompt.
    ///
    /// VoiceOver instead relies on `AXEnhancedUserInterface`, which we deliberately do **not**
    /// set: several AppKit apps treat it as "a screen reader is running" and rearrange or resize
    /// their windows in response. `AXManualAccessibility` exists precisely so a non-VoiceOver
    /// client can opt in without that blast radius.
    public static let manualAccessibilityAttribute = "AXManualAccessibility"

    /// How long to wait for the tree after switching it on, and the poll step.
    public static let manualAccessibilitySettleSeconds: TimeInterval = 0.30
    public static let manualAccessibilityPollSeconds: TimeInterval = 0.03

    /// What asking an app to publish its accessibility tree actually achieved.
    ///
    /// The distinction that matters is `alreadyActive` vs everything else. This used to be a
    /// plain `Bool` meaning "did I set the attribute *on this call*", and the rescue path in
    /// `probeFocusedElements` read that as "is the tree available now". `SelectionMonitor` pokes
    /// every app it registers on, i.e. every app the user switches to — so by the time the AI
    /// hotkey ran, the answer was already `false`, the rescue bailed out before its settle poll,
    /// and the whole Chromium wake-up was dead code in production. That is precisely the
    /// `axCandidates=0 outcome=noFocus systemWide:noValue appScoped:noValue chain:noValue`
    /// field report: the wake-up had worked and the code meant to wait for it never ran.
    public enum ManualAccessibilityState: String, Equatable, Sendable {
        /// The attribute was set successfully on this call.
        case activatedNow
        /// Set successfully earlier this session; the tree should already be published.
        case alreadyActive
        /// The app does not implement the attribute (any non-Chromium app). Memoized — the
        /// answer cannot change for the life of the process.
        case unsupported
        /// A transient AX error (timeout, app still launching). **Never memoized**: one unlucky
        /// round-trip must not disable the wake-up for that process forever.
        case failed
        /// Not a usable target.
        case invalidPID

        /// True when the tree is published, or should be shortly.
        public var isLive: Bool { self == .activatedNow || self == .alreadyActive }
    }

    private let manualAccessibilityLock = UnfairLock()
    private var manualAccessibilityPIDs: [pid_t: ManualAccessibilityState] = [:]
    private var manualAccessibilityTerminationObserver: NSObjectProtocol?

    /// Pure policy: a pid is worth poking once per process lifetime.
    ///
    /// Repeating it is not harmful but is not free either — it is an AX round-trip on a path the
    /// user is waiting on, and the answer cannot change once the tree is up.
    public static func shouldActivateManualAccessibility(
        pid: pid_t,
        alreadyActivated: Set<pid_t>
    ) -> Bool {
        pid > 0 && !alreadyActivated.contains(pid)
    }

    /// Pure policy: map the AX status of the `AXManualAccessibility` write to a state.
    ///
    /// `attributeUnsupported` is a settled answer (this app is not Chromium). Everything else
    /// that is not success is transient and must stay retryable — `.cannotComplete` in
    /// particular is just an app that was busy launching when we asked.
    public static func manualAccessibilityState(forSetStatus status: AXError) -> ManualAccessibilityState {
        switch status {
        case .success:
            return .activatedNow
        case .attributeUnsupported, .noValue:
            return .unsupported
        default:
            return .failed
        }
    }

    /// Pure policy: should the caller wait for the tree after a wake-up attempt?
    ///
    /// Everything except an unusable pid earns the wait. `alreadyActive` above all: that is the
    /// state a Chromium app is in for every hotkey press after the first, and skipping the wait
    /// there is exactly the regression this enum exists to prevent. `unsupported` and `failed`
    /// also poll — an AppKit app that answered *nothing* to all three focus probes is abnormal
    /// (mid-window-transition, still launching), and the alternative is a false "no selection"
    /// on a gesture that is about to fail anyway.
    public static func shouldSettlePollAfterManualAccessibility(
        _ state: ManualAccessibilityState
    ) -> Bool {
        state != .invalidPID
    }

    /// Pure policy: is this pid a target the focus rescue (wake-up + settle poll) may run against?
    ///
    /// Our own process never is. The rescue exists to wake another app's accessibility tree and
    /// wait for it; against ourselves it is a guaranteed `unsupported` round-trip followed by up to
    /// `manualAccessibilitySettleSeconds` of main-thread sleep on a gesture the user is waiting on.
    public static func mayRescueFocus(
        pid: pid_t,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        pid > 0 && pid != ownPID
    }

    /// Pure: settle-poll deadline, never past the caller's overall read budget.
    public static func settlePollDeadline(now: Date, budget: Date?) -> Date {
        let natural = now.addingTimeInterval(manualAccessibilitySettleSeconds)
        guard let budget else { return natural }
        return min(natural, budget)
    }

    /// Ensure `AXManualAccessibility` is on for `pid`, reporting what was already true.
    ///
    /// Prefer this over `activateManualAccessibility(pid:)`: callers almost always want to know
    /// whether the tree is *live*, not whether this particular call is the one that switched it on.
    @discardableResult
    public func ensureManualAccessibility(pid: pid_t) -> ManualAccessibilityState {
        guard pid > 0 else { return .invalidPID }

        manualAccessibilityLock.lock()
        let remembered = manualAccessibilityPIDs[pid]
        manualAccessibilityLock.unlock()
        if let remembered {
            return remembered == .activatedNow ? .alreadyActive : remembered
        }

        installManualAccessibilityTerminationObserverIfNeeded()

        let appElement = AXUIElementCreateApplication(pid)
        Self.applyMessagingTimeout(to: appElement)
        let status = AXUIElementSetAttributeValue(
            appElement,
            Self.manualAccessibilityAttribute as CFString,
            kCFBooleanTrue
        )
        let state = Self.manualAccessibilityState(forSetStatus: status)

        if state != .failed {
            manualAccessibilityLock.lock()
            manualAccessibilityPIDs[pid] = state
            manualAccessibilityLock.unlock()
        }

        DevTypeLog.selection.info(
            """
            [Selection] AXManualAccessibility pid=\(pid, privacy: .public) \
            state=\(state.rawValue, privacy: .public) ax=\(status.rawValue, privacy: .public)
            """
        )
        return state
    }

    /// Legacy shim: true only when this call flipped the switch.
    @discardableResult
    public func activateManualAccessibility(pid: pid_t) -> Bool {
        ensureManualAccessibility(pid: pid) == .activatedNow
    }

    /// Drop a remembered pid.
    ///
    /// macOS reuses pids. Without this, an Electron app that quits and is replaced by an AppKit
    /// app on the same pid inherits `alreadyActive` — or, worse, the reverse: a Chromium app
    /// launched onto a pid we recorded as `unsupported` never gets its tree switched on and
    /// reports "no selection" for the rest of the session.
    public func forgetManualAccessibility(pid: pid_t) {
        manualAccessibilityLock.lock()
        let removed = manualAccessibilityPIDs.removeValue(forKey: pid)
        manualAccessibilityLock.unlock()
        if let removed {
            DevTypeLog.selection.debug(
                """
                [Selection] AXManualAccessibility memo evicted pid=\(pid, privacy: .public) \
                was=\(removed.rawValue, privacy: .public)
                """
            )
        }
    }

    private func installManualAccessibilityTerminationObserverIfNeeded() {
        manualAccessibilityLock.lock()
        let needsInstall = manualAccessibilityTerminationObserver == nil
        manualAccessibilityLock.unlock()
        guard needsInstall else { return }

        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            self?.forgetManualAccessibility(pid: app.processIdentifier)
        }

        // Two threads can race to here; the loser removes its own duplicate rather than leaking
        // a second subscription that would evict twice per quit.
        manualAccessibilityLock.lock()
        let won = manualAccessibilityTerminationObserver == nil
        if won { manualAccessibilityTerminationObserver = observer }
        manualAccessibilityLock.unlock()
        if !won {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Test hook — process-scoped memo, so a test that seeds a pid must be able to clear it.
    public func resetManualAccessibilityMemoForTesting() {
        manualAccessibilityLock.lock()
        manualAccessibilityPIDs.removeAll()
        manualAccessibilityLock.unlock()
    }

    /// Test hook — seed a remembered state without an AX round-trip.
    public func seedManualAccessibilityForTesting(pid: pid_t, state: ManualAccessibilityState) {
        manualAccessibilityLock.lock()
        manualAccessibilityPIDs[pid] = state
        manualAccessibilityLock.unlock()
    }

    /// Focused element's `kAXRoleAttribute`, when readable.
    ///
    /// Used by inject to consult `AXWriteCapabilityStore` with a `(bundleID, role)` key so a
    /// Chromium web view's false-success does not dictate the same app's native fields — and so a
    /// role already condemned this session skips AX write / AX direct without re-paying the cost.
    public func focusedElementRole(element: AXUIElement? = nil) -> String? {
        let axElement: AXUIElement
        if let element {
            axElement = element
        } else {
            guard let fetched = focusedElement() else { return nil }
            axElement = fetched
        }
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String, !role.isEmpty else {
            return nil
        }
        return role
    }

    /// Pure fail-closed policy: AX unavailable or no focused element ⇒ treat as unsafe.
    public static func mustRefuseExpandWhenFocusedUnknown(
        axTrusted: Bool,
        focusedElementAvailable: Bool
    ) -> Bool {
        !axTrusted || !focusedElementAvailable
    }

    /// True when expand must be refused for password/secure context (fail-closed).
    public func isFocusedElementSecure(element: AXUIElement? = nil) -> Bool {
        let axElement: AXUIElement
        if let element {
            axElement = element
        } else {
            guard isProcessTrusted(), let fetched = focusedElement() else { return true }
            axElement = fetched
        }

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == "AXSecureTextField" {
            return true
        }

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == "AXSecureTextField" {
            return true
        }

        return false
    }

    /// Active CJK / IME marked text — fail-closed when AX/focus unavailable.
    public func hasActiveIMEMarkedText(element: AXUIElement? = nil) -> Bool {
        let axElement: AXUIElement
        if let element {
            axElement = element
        } else {
            guard isProcessTrusted(), let fetched = focusedElement() else { return true }
            axElement = fetched
        }

        let markedAttributes = [
            "AXMarkedText",
            "AXMarkedTextRange",
            "AXTextInputMarkedRange"
        ]

        for attr in markedAttributes {
            var valueRef: CFTypeRef?
            let markedResult = AXUIElementCopyAttributeValue(axElement, attr as CFString, &valueRef)
            guard markedResult == .success, let value = valueRef else { continue }

            if let string = value as? String, !string.isEmpty {
                return true
            }

            if CFGetTypeID(value) == AXValueGetTypeID() {
                let axValue = unsafeBitCast(value, to: AXValue.self)
                var range = CFRange(location: 0, length: 0)
                if AXValueGetValue(axValue, .cfRange, &range), range.length > 0 {
                    return true
                }
            }
        }

        return false
    }

    /// Sole expand-gate policy implementation (fail-closed). Prefer this over duplicated branching.
    public func evaluateExpandGate(canUseAX: Bool, canPostEvents: Bool = false) -> ExpandGateDecision {
        if !canUseAX {
            let snapshot = DiagnosticReport.ExpandGateSnapshot(
                canUseAX: false,
                axTrusted: isProcessTrusted(),
                focusedAvailable: false,
                isSecureField: nil,
                hasIMEMarkedText: nil,
                shouldBlockExpand: true,
                blockReason: "Accessibility unavailable — expand blocked (fail-closed)"
            )
            return ExpandGateDecision(
                shouldBlock: true,
                reason: snapshot.blockReason,
                snapshot: snapshot,
                focus: .untrusted
            )
        }

        let trusted = isProcessTrusted()
        guard trusted else {
            let snapshot = DiagnosticReport.ExpandGateSnapshot(
                canUseAX: true,
                axTrusted: false,
                focusedAvailable: false,
                isSecureField: nil,
                hasIMEMarkedText: nil,
                shouldBlockExpand: true,
                blockReason: "AXIsProcessTrusted false — expand blocked (fail-closed)"
            )
            return ExpandGateDecision(
                shouldBlock: true,
                reason: snapshot.blockReason,
                snapshot: snapshot,
                focus: .untrusted
            )
        }

        let focus = queryFocusedElement()
        switch focus {
        case .available(let element):
            let secure = isFocusedElementSecure(element: element)
            let ime = hasActiveIMEMarkedText(element: element)
            if secure {
                let snapshot = DiagnosticReport.ExpandGateSnapshot(
                    canUseAX: true,
                    axTrusted: true,
                    focusedAvailable: true,
                    isSecureField: true,
                    hasIMEMarkedText: ime,
                    shouldBlockExpand: true,
                    blockReason: "Focused secure text field — expand blocked"
                )
                return ExpandGateDecision(
                    shouldBlock: true,
                    reason: snapshot.blockReason,
                    snapshot: snapshot,
                    focus: focus
                )
            }
            if ime {
                let snapshot = DiagnosticReport.ExpandGateSnapshot(
                    canUseAX: true,
                    axTrusted: true,
                    focusedAvailable: true,
                    isSecureField: false,
                    hasIMEMarkedText: true,
                    shouldBlockExpand: true,
                    blockReason: "Active IME marked text — expand blocked"
                )
                return ExpandGateDecision(
                    shouldBlock: true,
                    reason: snapshot.blockReason,
                    snapshot: snapshot,
                    focus: focus
                )
            }
            let snapshot = DiagnosticReport.ExpandGateSnapshot(
                canUseAX: true,
                axTrusted: true,
                focusedAvailable: true,
                isSecureField: false,
                hasIMEMarkedText: false,
                shouldBlockExpand: false,
                blockReason: "ok"
            )
            return ExpandGateDecision(
                shouldBlock: false,
                reason: snapshot.blockReason,
                snapshot: snapshot,
                focus: focus
            )

        case .missing, .axFailure, .untrusted:
            // Chrome / Cursor / Electron often expose no AX focused element while the user types.
            // With Post Events + Secure Input off, allow HID expand for any frontmost app.
            // Password fields stay fail-closed whenever focus *is* available (handled above);
            // Secure Input still blocks when locked.
            if Self.mayAllowHIDExpandWithoutAXFocus(
                focus: focus,
                canPostEvents: canPostEvents,
                secureInputEnabled: Self.isSecureEventInputEnabledLive()
            ) {
                let reason = Self.hidWithoutAXFocusAllowReason
                let snapshot = DiagnosticReport.ExpandGateSnapshot(
                    canUseAX: true,
                    axTrusted: true,
                    focusedAvailable: false,
                    isSecureField: nil,
                    hasIMEMarkedText: nil,
                    shouldBlockExpand: false,
                    blockReason: reason
                )
                return ExpandGateDecision(
                    shouldBlock: false,
                    reason: reason,
                    snapshot: snapshot,
                    focus: focus
                )
            }
            let reason = Self.focusBlockReason(for: focus)
                ?? "No focused AX element — expand blocked (fail-closed)"
            let snapshot = DiagnosticReport.ExpandGateSnapshot(
                canUseAX: true,
                axTrusted: true,
                focusedAvailable: false,
                isSecureField: nil,
                hasIMEMarkedText: nil,
                shouldBlockExpand: true,
                blockReason: reason
            )
            return ExpandGateDecision(
                shouldBlock: true,
                reason: reason,
                snapshot: snapshot,
                focus: focus
            )
        }
    }

    /// Combined expand gate used by the event tap (fail-closed).
    public func shouldBlockExpand(canUseAX: Bool, canPostEvents: Bool = false) -> Bool {
        evaluateExpandGate(canUseAX: canUseAX, canPostEvents: canPostEvents).shouldBlock
    }

    /// Diagnostic breakdown of the expand gate (honest focus/secure/IME — not fail-closed defaults).
    public func expandGateSnapshot(canUseAX: Bool, canPostEvents: Bool = false) -> DiagnosticReport.ExpandGateSnapshot {
        evaluateExpandGate(canUseAX: canUseAX, canPostEvents: canPostEvents).snapshot
    }

    public func isTerminalBundleID(_ bundleID: String) -> Bool {
        terminalBundleIDs.contains(bundleID)
    }

    /// True for dedicated terminal apps.
    public func isFrontmostAppTerminal() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let bundleID = frontApp.bundleIdentifier ?? ""
        return isTerminalBundleID(bundleID)
    }

    /// True when frontmost is a terminal app, or an IDE with a terminal-like focused AX element.
    public func isFrontmostShellLikeContext(element: AXUIElement? = nil) -> Bool {
        if isFrontmostAppTerminal() { return true }
        guard let bundleID = frontmostApplicationBundleIdentifier() else { return false }
        guard isIDEBundleID(bundleID) else { return false }
        return focusedElementLooksLikeTerminal(element: element)
    }

    public func isIDEBundleID(_ bundleID: String) -> Bool {
        if terminalBundleIDs.contains(bundleID) { return false }
        for prefix in ideBundleIDPrefixes {
            if bundleID == prefix || bundleID.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    /// §3.10: AX roles an integrated terminal can plausibly expose for its focused element.
    /// Electron terminals report `AXTextArea` / `AXGroup` / `AXScrollArea`; some report nothing
    /// useful at all, which is why the empty role is *not* in this set — a missing role is not
    /// evidence of a terminal.
    public static let terminalLikeAXRoles: Set<String> = [
        "AXTextArea", "AXGroup", "AXScrollArea", "AXWebArea",
    ]

    /// §3.10: words that identify a terminal when they stand alone as a token.
    private static let terminalTitleWords: Set<String> = [
        "terminal", "terminals", "console", "shell", "powershell", "xterm",
        "pty", "tty", "repl", "bash", "zsh", "fish",
    ]

    /// §3.10: filename-shaped titles are documents, not terminals. A VS Code tab named
    /// `terminal.ts` and an Xcode file named `Console.swift` both tokenize to a terminal word,
    /// so the extension is what tells them apart.
    private static let documentFileExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt",
        "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "bash", "zsh", "fish",
        "json", "yml", "yaml", "toml", "xml", "md", "markdown", "txt", "log", "html", "htm",
        "css", "scss", "less", "vue", "svelte", "sql", "lua", "pl", "r", "scala", "dart", "ex",
        "exs", "hs", "clj", "erl", "jl", "proto", "gradle", "plist", "cfg", "ini", "conf",
    ]

    /// §3.10: `true` when a title / description / identifier names a terminal.
    ///
    /// Pure and public so the heuristic can be tested without a window server. Deliberately
    /// conservative: a false negative only means a normal paste into a terminal (safe), while a
    /// false positive injects literal `ESC[200~` into the user's source file (not safe).
    public static func axTitleLooksLikeTerminal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return false }

        // Anything shaped like `name.ext` where `ext` is a source/document extension is a
        // document title, never a terminal.
        if let dot = lowered.lastIndex(of: "."), dot != lowered.startIndex {
            let ext = String(lowered[lowered.index(after: dot)...])
            if !ext.isEmpty, documentFileExtensions.contains(ext) { return false }
        }

        // Whole-token match. `terminal.ts` used to match on a bare `contains`.
        let tokens = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for token in tokens where terminalTitleWords.contains(String(token)) {
            return true
        }
        return false
    }

    /// §3.10: best-effort AX heuristic for integrated terminals.
    ///
    /// This used to be a bare substring match for `terminal`/`console`/`shell`/`term`/`pty` over
    /// the *joined* title + description + identifier + role, so a VS Code tab named `terminal.ts`
    /// or an Xcode file named `Console.swift` was routed through bracketed paste and received
    /// literal escape sequences. It now requires **both** a terminal-ish AX role and a
    /// terminal-shaped title token.
    public func focusedElementLooksLikeTerminal(element: AXUIElement? = nil) -> Bool {
        let axElement: AXUIElement
        if let element {
            axElement = element
        } else {
            guard isProcessTrusted(), let fetched = focusedElement() else { return false }
            axElement = fetched
        }

        var roleRef: CFTypeRef?
        let role: String
        if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef) == .success,
           let r = roleRef as? String {
            role = r
        } else {
            role = ""
        }
        guard Self.terminalLikeAXRoles.contains(role) else { return false }

        for attr in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXIdentifierAttribute as String] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, attr as CFString, &ref) == .success,
               let s = ref as? String, !s.isEmpty,
               Self.axTitleLooksLikeTerminal(s) {
                return true
            }
        }
        return false
    }

    public func frontmostApplicationBundleIdentifier() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// True when the frontmost app is a known IDE (Cursor / VS Code / Xcode, …).
    public func frontmostIsIDEBundle() -> Bool {
        guard let bundleID = frontmostApplicationBundleIdentifier() else { return false }
        return isIDEBundleID(bundleID)
    }

    private static func isMissingFocus(_ focus: FocusQueryResult) -> Bool {
        if case .missing = focus { return true }
        return false
    }

    // MARK: - Private

    /// Probe order: system-wide → app-scoped frontmost → focused-application chain.
    /// Fail-closed (returns last non-available result) when every path fails.
    private func copyFocusedElementOnce() -> FocusQueryResult {
        let systemWide = systemWideElement()
        let systemWideCopy = copyFocusedUIElement(from: systemWide)
        let systemWideMapped = mapFocusCopy(systemWideCopy)

        // §2.2: the two fallback probes each cost up to `messagingTimeoutSeconds` (0.05 s) of AX
        // IPC. When the system-wide probe already returned `.available` the winner is decided —
        // the *only* remaining consumer of the losing probes is `debugLogFocusProbe`, which bails
        // immediately unless `DebugTrace.isEnabled`. Shipping builds used to pay both probes on
        // every keystroke-triggered focus resolution for nothing.
        let primaryAvailable: Bool
        if case .available = systemWideMapped {
            primaryAvailable = true
        } else {
            primaryAvailable = false
        }
        let needsFallbackProbes = !primaryAvailable || DebugTrace.isEnabled

        var appScopedCopy = FocusAttributeCopy(error: .invalidUIElement, focusedRefNil: true)
        var appScopedMapped: FocusQueryResult = .missing
        var chain = FocusedApplicationChainResult(
            mapped: .missing,
            focusedAppError: .invalidUIElement,
            uiKind: "skipped"
        )

        if needsFallbackProbes {
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                let appEl = AXUIElementCreateApplication(pid)
                Self.applyMessagingTimeout(to: appEl)
                appScopedCopy = copyFocusedUIElement(from: appEl)
                appScopedMapped = mapFocusCopy(appScopedCopy)
            }
            chain = copyFocusedElementViaFocusedApplicationChain()
        }

        let chainMapped = chain.mapped

        let mapped: FocusQueryResult
        let winningPath: String
        if case .available = systemWideMapped {
            mapped = systemWideMapped
            winningPath = "systemWide"
        } else if case .available = appScopedMapped {
            mapped = appScopedMapped
            winningPath = "appScoped"
        } else if case .available = chainMapped {
            mapped = chainMapped
            winningPath = "focusedApplication"
        } else {
            // Prefer honest `.missing` when any probe saw noValue; else keep system-wide failure.
            let anyMissing =
                Self.isMissingFocus(systemWideMapped)
                || Self.isMissingFocus(appScopedMapped)
                || Self.isMissingFocus(chainMapped)
            mapped = anyMissing ? .missing : systemWideMapped
            winningPath = "none"
        }

        // #region agent log
        Self.debugLogFocusProbe(
            systemWideResult: systemWideCopy.error,
            systemWideMapped: systemWideMapped,
            systemWideFocusedRefNil: systemWideCopy.focusedRefNil,
            appScopedAXError: appScopedCopy.error,
            appScopedMapped: appScopedMapped,
            focusedAppAXError: chain.focusedAppError,
            focusedAppThenUI: chain.uiKind,
            finalMapped: mapped,
            winningPath: winningPath
        )
        // #endregion
        return mapped
    }

    private struct FocusAttributeCopy {
        var error: AXError
        var element: AXUIElement?
        var focusedRefNil: Bool
    }

    private func copyFocusedUIElement(from element: AXUIElement) -> FocusAttributeCopy {
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard result == .success else {
            return FocusAttributeCopy(error: result, element: nil, focusedRefNil: focusedElement == nil)
        }
        guard let focusedElement else {
            return FocusAttributeCopy(error: .success, element: nil, focusedRefNil: true)
        }
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return FocusAttributeCopy(error: .success, element: nil, focusedRefNil: false)
        }
        let focused = unsafeBitCast(focusedElement, to: AXUIElement.self)
        Self.applyMessagingTimeout(to: focused)
        return FocusAttributeCopy(error: .success, element: focused, focusedRefNil: false)
    }

    private func mapFocusCopy(_ copy: FocusAttributeCopy) -> FocusQueryResult {
        switch copy.error {
        case .success:
            if let element = copy.element {
                return .available(element)
            }
            return .missing
        case .noValue:
            return .missing
        default:
            return .axFailure(copy.error)
        }
    }

    private struct FocusedApplicationChainResult {
        var mapped: FocusQueryResult
        var focusedAppError: AXError
        var uiKind: String
    }

    private func copyFocusedElementViaFocusedApplicationChain() -> FocusedApplicationChainResult {
        let systemWide = systemWideElement()
        var appRef: CFTypeRef?
        let appAttr = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &appRef
        )
        guard appAttr == .success,
              let appRef,
              CFGetTypeID(appRef) == AXUIElementGetTypeID() else {
            let kind: String
            if appAttr == .noValue {
                kind = "focusedAppNoValue"
            } else if appAttr == .success {
                kind = "focusedAppBadType"
            } else {
                kind = "focusedAppFail"
            }
            let mapped: FocusQueryResult =
                (appAttr == .noValue || appAttr == .success) ? .missing : .axFailure(appAttr)
            return FocusedApplicationChainResult(
                mapped: mapped,
                focusedAppError: appAttr,
                uiKind: kind
            )
        }

        let focusedApp = unsafeBitCast(appRef, to: AXUIElement.self)
        Self.applyMessagingTimeout(to: focusedApp)
        let uiCopy = copyFocusedUIElement(from: focusedApp)
        let mapped = mapFocusCopy(uiCopy)
        let uiKind: String
        switch mapped {
        case .available:
            uiKind = "available"
        case .missing:
            uiKind = uiCopy.error == .noValue ? "noValue" : "successNilOrBadType"
        case .axFailure(let error):
            uiKind = "uiFail:\(error.rawValue)"
        case .untrusted:
            uiKind = "untrusted"
        }
        return FocusedApplicationChainResult(
            mapped: mapped,
            focusedAppError: appAttr,
            uiKind: uiKind
        )
    }

    // #region agent log
    private static func debugLogFocusProbe(
        systemWideResult: AXError,
        systemWideMapped: FocusQueryResult,
        systemWideFocusedRefNil: Bool,
        appScopedAXError: AXError,
        appScopedMapped: FocusQueryResult,
        focusedAppAXError: AXError,
        focusedAppThenUI: String,
        finalMapped: FocusQueryResult,
        winningPath: String
    ) {
        // This runs on every focus probe — i.e. on the keystroke path. Bail before doing any work
        // unless tracing was explicitly turned on. See `DebugTrace`.
        guard DebugTrace.isEnabled else { return }

        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.processIdentifier
        let bundle = front?.bundleIdentifier ?? "nil"

        func kind(_ result: FocusQueryResult) -> String {
            switch result {
            case .available: return "available"
            case .missing: return "missing"
            case .axFailure(let e): return "axFailure:\(e.rawValue)"
            case .untrusted: return "untrusted"
            }
        }

        let systemWideMappedKind = kind(systemWideMapped)
        let appScopedKind = kind(appScopedMapped)
        let mappedKind = kind(finalMapped)

        let hypothesisId: String
        if case .available = finalMapped, winningPath == "systemWide" {
            hypothesisId = "E"
        } else if case .available = finalMapped, winningPath == "appScoped" {
            hypothesisId = "A"
        } else if case .available = finalMapped, winningPath == "focusedApplication" {
            hypothesisId = "C"
        } else if appScopedKind == "missing"
            && (focusedAppThenUI.localizedCaseInsensitiveContains("novalue")
                || focusedAppThenUI == "successNilOrBadType")
            && (systemWideMappedKind == "missing" || systemWideMappedKind.hasPrefix("axFailure")) {
            hypothesisId = "D"
        } else if systemWideResult == .success && systemWideFocusedRefNil {
            hypothesisId = "B"
        } else {
            hypothesisId = "B"
        }

        DebugTrace.write(
            location: "AXContextChecker.copyFocusedElementOnce",
            hypothesisId: hypothesisId,
            message: "focus probe",
            data: [
                "isMainThread": Thread.isMainThread,
                "frontmostBundle": bundle,
                // Must be a bridgeable value: a bare Optional makes JSONSerialization raise an
                // ObjC exception, which `try?` cannot catch.
                "frontmostPID": pid.map(Int.init) ?? -1,
                "systemWideAXError": Int(systemWideResult.rawValue),
                "systemWideMapped": systemWideMappedKind,
                "systemWideFocusedRefNil": systemWideFocusedRefNil,
                "appScopedAXError": Int(appScopedAXError.rawValue),
                "appScopedKind": appScopedKind,
                "focusedAppAXError": Int(focusedAppAXError.rawValue),
                "focusedAppThenUI": focusedAppThenUI,
                "finalMapped": mappedKind,
                "winningPath": winningPath
            ]
        )
    }
    // #endregion
}
