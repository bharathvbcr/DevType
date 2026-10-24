import ApplicationServices
import Carbon.HIToolbox
import Cocoa

public final class AXContextChecker {
    public static let shared = AXContextChecker()

    /// Short AX IPC timeout so hung target apps cannot stall gates/inject (~default is multi-second).
    public static let messagingTimeoutSeconds: Float = 0.05

    /// Delay before a single focus-query retry after `.cannotComplete`. §8.3: the shared settle —
    /// the erase guard uses the same constant through the same policy.
    public static let focusQueryRetryDelaySeconds: TimeInterval = AXSettleRetry.settleDelay

    /// Budget for the *retry* attempt. Repeating a 50 ms probe that just expired asks the same
    /// question of the same busy app and mostly gets the same answer — the retry was spent
    /// without buying information. The escalated budget is paid only on the path that was
    /// otherwise about to refuse the expansion outright, so the cost lands on the rare failure
    /// rather than on every keystroke, and the ceiling stays well inside a human-noticeable
    /// pause. A refused expansion costs the user their text; 150 ms costs them nothing.
    public static let retryMessagingTimeoutSeconds: Float = 0.15

    /// Pure policy: the AX messaging budget for one focus-query attempt.
    public static func focusQueryTimeout(attemptIndex: Int) -> Float {
        attemptIndex == 0 ? messagingTimeoutSeconds : retryMessagingTimeoutSeconds
    }

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

        /// The focused element when one was available.
        public var element: AXUIElement? {
            if case .available(let element) = self { return element }
            return nil
        }
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
        "com.apple.dt.Xcode",
        "com.jetbrains.",
        "com.google.android.studio",
        "dev.zed.Zed",
        "com.sublimetext.",
        "com.panic.Nova",
        "org.rstudio.",
        "com.rstudio."
    ]

    /// §8.3: the settle-and-retry policy, shared with `EraseExecutor`.
    private let settle: AXSettleRetry
    /// One focus-query attempt at a given AX messaging budget. Injected in tests so the retry
    /// policy can be exercised without a live AX tree; production is `copyFocusedElementOnce`.
    private let focusAttempt: ((Float) -> FocusQueryResult)?
    /// One round of `probeFocusedElements`' probes, and the `AXManualAccessibility` write. Injected
    /// in tests so the Chromium rescue can be driven without a live AX tree or a real target app;
    /// production is `runLiveFocusProbes` and `AXUIElementSetAttributeValue`.
    private let focusProbes: ((pid_t?) -> FocusProbeRun)?
    private let manualAccessibilityWrite: ((pid_t) -> AXError)?

    public init() {
        settle = .live
        focusAttempt = nil
        focusProbes = nil
        manualAccessibilityWrite = nil
    }

    init(settle: AXSettleRetry, focusAttempt: @escaping (Float) -> FocusQueryResult) {
        self.settle = settle
        self.focusAttempt = focusAttempt
        focusProbes = nil
        manualAccessibilityWrite = nil
    }

    init(
        settle: AXSettleRetry,
        focusProbes: @escaping (pid_t?) -> FocusProbeRun,
        manualAccessibilityWrite: @escaping (pid_t) -> AXError
    ) {
        self.settle = settle
        focusAttempt = nil
        self.focusProbes = focusProbes
        self.manualAccessibilityWrite = manualAccessibilityWrite
    }

    /// Whether this process is trusted for Accessibility (no prompt).
    public func isProcessTrusted() -> Bool {
        AccessibilityTrust.isProcessTrusted()
    }

    /// Applies `AXUIElementSetMessagingTimeout` so gates/inject fail fast on hung apps.
    public static func applyMessagingTimeout(to element: AXUIElement, seconds: Float = messagingTimeoutSeconds) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    /// §8.12: is this process servicing AX messages *right now*?
    ///
    /// `.cannotComplete` from an app-level attribute read is the OS's "this app's main run loop is
    /// not answering" — `SelectionReader` already draws exactly this line between a stalled app and
    /// an empty answer. Every other status, a hard refusal included, means the process replied.
    ///
    /// Used as a stall witness by the pasteboard residency policy: a host that has stopped
    /// answering has not processed our synthetic ⌘V either, so releasing the payload on schedule
    /// would hand it the user's restored clipboard. Answering "responding" on any doubt is
    /// deliberate — this may only ever *extend* a hold, and an extension that fires on a healthy
    /// app costs the user a stale clipboard for a fraction of a second.
    ///
    /// Costs one AX round trip bounded by `timeoutSeconds`. Never called on the keystroke path.
    public static func appRespondsToAX(
        pid: pid_t,
        timeoutSeconds: Float = messagingTimeoutSeconds
    ) -> Bool {
        guard pid > 0 else { return true }
        let appElement = AXUIElementCreateApplication(pid)
        applyMessagingTimeout(to: appElement, seconds: timeoutSeconds)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &value)
        return status != .cannotComplete
    }

    /// System-wide AX element with messaging timeout applied.
    public func systemWideElement(timeoutSeconds: Float = messagingTimeoutSeconds) -> AXUIElement {
        let systemWide = AXUIElementCreateSystemWide()
        Self.applyMessagingTimeout(to: systemWide, seconds: timeoutSeconds)
        return systemWide
    }

    /// Pure policy: retry focus query once after `.cannotComplete` on the first attempt only.
    public static func shouldRetryFocusQuery(error: AXError, attemptIndex: Int) -> Bool {
        attemptIndex == 0 && error == .cannotComplete
    }

    /// Maps a focus-query failure to a stable fail-closed reason string.
    ///
    /// `appResponding` is the corroborating witness: the same `.cannotComplete` means two very
    /// different things depending on whether the app answers AX at all. A hung host is the
    /// user's problem to notice; a host that answers `AXRole` promptly but cannot produce a
    /// focused element in the budget is *ours*, and is the case a longer retry budget fixes.
    /// The report carried neither, so both looked identical in the one line it prints.
    public static func reasonForFocusQueryFailure(
        _ error: AXError,
        appResponding: Bool? = nil
    ) -> String {
        let witness: String
        switch appResponding {
        case .some(true): witness = " (app answers AX — focus query specifically timed out)"
        case .some(false): witness = " (app is not answering AX at all)"
        case nil: witness = ""
        }
        if error == .cannotComplete {
            return "AX focus query timed out\(witness) — expand blocked (fail-closed)"
        }
        return "AX focus query failed (code \(error.rawValue))\(witness) — expand blocked (fail-closed)"
    }

    /// Maps focus query result to a fail-closed block reason, or `nil` when focus is available.
    ///
    /// `appResponding` is threaded through rather than probed here so this stays a pure
    /// function: the caller decides whether one more AX round trip is affordable, and only the
    /// refuse path pays for it.
    public static func focusBlockReason(
        for focus: FocusQueryResult,
        appResponding: Bool? = nil
    ) -> String? {
        switch focus {
        case .available:
            return nil
        case .missing:
            return "No focused AX element — expand blocked (fail-closed)"
        case .axFailure(let error):
            return reasonForFocusQueryFailure(error, appResponding: appResponding)
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

    /// Pure policy over a whole result: only a first-attempt `.cannotComplete` earns the retry.
    public static func shouldRetryFocusQuery(_ result: FocusQueryResult) -> Bool {
        guard case .axFailure(let error) = result else { return false }
        return shouldRetryFocusQuery(error: error, attemptIndex: 0)
    }

    /// One focus-query attempt, no retry, at the budget for `attemptIndex` (the retry escalates).
    /// For callers that own the retry themselves — see `AXSettleRetry`.
    public func queryFocusedElement(attempt attemptIndex: Int) -> FocusQueryResult {
        let timeout = Self.focusQueryTimeout(attemptIndex: attemptIndex)
        FocusQueryProbe.record()
        if let focusAttempt { return focusAttempt(timeout) }
        return copyFocusedElementOnce(timeoutSeconds: timeout)
    }

    /// Focused AX element query with typed errors.
    ///
    /// §8.3: retries once on `.cannotComplete` **off main only**, after the shared settle. This
    /// used to be the inverse — the retry ran only on main, by sleeping there while the event tap
    /// could not run, and off-main callers never got it. A main-thread caller that needs the
    /// retry uses `queryFocusedElement(completion:)`, which schedules it instead of blocking.
    public func queryFocusedElement(allowTimeoutRetry: Bool = true) -> FocusQueryResult {
        guard allowTimeoutRetry else { return queryFocusedElement(attempt: 0) }
        return settle.run({ queryFocusedElement(attempt: $0) }, retryIf: Self.shouldRetryFocusQuery)
    }

    /// Asynchronous form: the retry is available on main too, scheduled rather than slept.
    /// `completion` runs synchronously when the first attempt decides, otherwise on main.
    public func queryFocusedElement(completion: @escaping (FocusQueryResult) -> Void) {
        settle.run(
            { self.queryFocusedElement(attempt: $0) },
            retryIf: Self.shouldRetryFocusQuery,
            completion: completion
        )
    }

    /// Focused AX element, if available (errors collapse to `nil` for legacy callers).
    public func focusedElement() -> AXUIElement? {
        if case .available(let element) = queryFocusedElement() {
            return element
        }
        return nil
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
        // spends the whole settle window waiting for a tree that already exists and
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
        // twice. Bounded, and only ever reached in an app that had no focus at all.
        //
        // The poll waits only off main (`AXSettleRetry.poll`); `SelectionReader` runs its reads on
        // its own queue for exactly this reason. A main-thread caller gets the first answer, and
        // the summary says the poll was skipped rather than passing that off as `polls:0`.
        let settled = settle.poll(
            from: first,
            every: Self.manualAccessibilityPollSeconds,
            maxPolls: Self.manualAccessibilityMaxPolls,
            until: Self.settlePollDeadline(now: Date(), budget: deadline),
            { runFocusProbes(frontmostPID: pid) },
            stopWhen: { !$0.candidates.isEmpty }
        )
        let pollLabel = settled.skippedOnMain ? "polls:skippedOnMain" : "polls:\(settled.polls)"
        return FocusProbeResult(
            candidates: settled.last.candidates,
            summary: settled.last.summary + " manualAX:\(state.rawValue) \(pollLabel)",
            manualAccessibility: state
        )
    }

    struct FocusProbeRun {
        var candidates: [AXUIElement]
        var summary: String
    }

    private func runFocusProbes(frontmostPID: pid_t?) -> FocusProbeRun {
        if let focusProbes { return focusProbes(frontmostPID) }
        return runLiveFocusProbes(frontmostPID: frontmostPID)
    }

    private func runLiveFocusProbes(frontmostPID: pid_t?) -> FocusProbeRun {
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
    /// Count bound on the settle poll, so it ends even when the clock it reads does not advance.
    public static let manualAccessibilityMaxPolls =
        Int((manualAccessibilitySettleSeconds / manualAccessibilityPollSeconds).rounded(.up))

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
        /// A transient AX error or an activation already in flight. The owner schedules one
        /// follow-up after the cooldown; the answer is never remembered as permanent.
        case failed
        /// Not a usable target.
        case invalidPID

        /// True when the tree is published, or should be shortly.
        public var isLive: Bool { self == .activatedNow || self == .alreadyActive }
    }

    private let manualAccessibilityLock = UnfairLock()
    private enum ManualAccessibilityMemo: Equatable {
        case probing(UUID)
        case settled(ManualAccessibilityState)
        case failed(at: TimeInterval)
    }
    static let manualAccessibilityRetrySeconds: TimeInterval = 1
    /// Extra wait so the follow-up cannot land inside the cooldown and be swallowed.
    /// `DispatchQueue` delay and `systemUptime` are not the same clock.
    public static let manualAccessibilityFollowUpSlackSeconds: TimeInterval = 0.05
    private static let manualAccessibilityMemoCapacity = 256
    private var manualAccessibilityPIDs: [pid_t: ManualAccessibilityMemo] = [:]
    private var manualAccessibilityOrder: [pid_t] = []
    private var manualAccessibilityTerminationObserver: NSObjectProtocol?
    /// Test hook. Production leaves this nil and follows up on the main queue.
    var manualAccessibilityFollowUpForTesting: ((TimeInterval, @escaping () -> Void) -> Void)?

    /// Called only while holding manualAccessibilityLock.
    private func rememberManualAccessibility(_ memo: ManualAccessibilityMemo, pid: pid_t) {
        manualAccessibilityOrder.removeAll { $0 == pid }
        if manualAccessibilityPIDs[pid] == nil,
           manualAccessibilityOrder.count >= Self.manualAccessibilityMemoCapacity {
            manualAccessibilityPIDs.removeValue(forKey: manualAccessibilityOrder.removeFirst())
        }
        manualAccessibilityPIDs[pid] = memo
        manualAccessibilityOrder.append(pid)
    }

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

    /// Messaging budget for one `AXManualAccessibility` write.
    ///
    /// The first probe keeps the 50 ms gate timeout so a dead process cannot hitch an app
    /// switch. That budget is what turns "this app is not Chromium" into `.cannotComplete`
    /// while the accessibility server is still coming up (`ax=-25204` in diagnostics). The
    /// follow-up pays the longer retry budget once the process has had a second to answer.
    public static func manualAccessibilityProbeTimeout(isFollowUp: Bool) -> Float {
        isFollowUp ? retryMessagingTimeoutSeconds : messagingTimeoutSeconds
    }

    /// Delay before the single automatic retry of a fresh transient failure.
    ///
    /// `nil` unless this call itself performed the write and the write failed. A cooldown
    /// hit, an in-flight probe, and every settled answer must not schedule another wake-up
    /// — a follow-up that schedules its own follow-up retries a dead pid forever.
    public static func manualAccessibilityFollowUpDelay(
        probedFresh: Bool,
        state: ManualAccessibilityState
    ) -> TimeInterval? {
        guard probedFresh, state == .failed else { return nil }
        let delay = manualAccessibilityRetrySeconds + manualAccessibilityFollowUpSlackSeconds
        guard delay.isFinite, delay > manualAccessibilityRetrySeconds else { return nil }
        return delay
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
    /// `manualAccessibilitySettleSeconds` of polling on a gesture the user is waiting on.
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
    ///
    /// A fresh `.cannotComplete` schedules one follow-up. App activation is the only caller, so
    /// without that follow-up the tree stays off until the user switches away and back — the
    /// `failed ax=-25204` lines that filled the diagnostic, with `activatedNow` only on a later visit.
    @discardableResult
    public func ensureManualAccessibility(pid: pid_t) -> ManualAccessibilityState {
        probeManualAccessibility(
            pid: pid,
            timeout: Self.manualAccessibilityProbeTimeout(isFollowUp: false),
            allowFollowUp: true
        )
    }

    private func probeManualAccessibility(
        pid: pid_t,
        timeout: Float,
        allowFollowUp: Bool
    ) -> ManualAccessibilityState {
        ensureManualAccessibility(
            pid: pid,
            now: { ProcessInfo.processInfo.systemUptime },
            activate: { targetPID in
                self.writeManualAccessibility(pid: targetPID, timeout: timeout)
            },
            isFollowUp: !allowFollowUp,
            scheduleFollowUp: allowFollowUp ? { [weak self] failedPID in
                self?.scheduleManualAccessibilityFollowUp(pid: failedPID)
            } : nil
        )
    }

    private func writeManualAccessibility(pid: pid_t, timeout: Float) -> AXError {
        if let manualAccessibilityWrite { return manualAccessibilityWrite(pid) }
        let appElement = AXUIElementCreateApplication(pid)
        Self.applyMessagingTimeout(to: appElement, seconds: timeout)
        return AXUIElementSetAttributeValue(
            appElement,
            Self.manualAccessibilityAttribute as CFString,
            kCFBooleanTrue
        )
    }

    private func scheduleManualAccessibilityFollowUp(pid: pid_t) {
        guard let delay = Self.manualAccessibilityFollowUpDelay(probedFresh: true, state: .failed) else {
            return
        }
        let fire = manualAccessibilityFollowUpForTesting ?? { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        fire(delay) { [weak self] in
            _ = self?.probeManualAccessibility(
                pid: pid,
                timeout: Self.manualAccessibilityProbeTimeout(isFollowUp: true),
                allowFollowUp: false
            )
        }
    }

    /// Injectable AX boundary for deterministic retry and process-lifecycle checks.
    ///
    /// `scheduleFollowUp` runs only after this call itself wrote the attribute and got a
    /// transient failure. A cooldown hit returns `.failed` without invoking it.
    /// `isFollowUp` is that scheduled retry and is not subject to the cooldown.
    func ensureManualAccessibility(
        pid: pid_t,
        now: () -> TimeInterval,
        activate: (pid_t) -> AXError,
        isFollowUp: Bool = false,
        scheduleFollowUp: ((pid_t) -> Void)? = nil
    ) -> ManualAccessibilityState {
        guard pid > 0 else { return .invalidPID }

        let timestamp = now()
        let attempt = UUID()
        manualAccessibilityLock.lock()
        if let remembered = manualAccessibilityPIDs[pid] {
            switch remembered {
            case .probing:
                manualAccessibilityLock.unlock()
                return .failed
            case .settled(let state):
                manualAccessibilityLock.unlock()
                return state == .activatedNow ? .alreadyActive : state
            case .failed(let failedAt):
                // The cooldown coalesces the app-switch and selection callers that both
                // fire on one activation. The follow-up is the retry those callers did
                // not get; swallowing it puts the tree back to "wait for the next visit".
                // Dispatch and systemUptime are different clocks, so a follow-up that
                // lands inside the window must still write.
                if !isFollowUp {
                    let elapsed = timestamp - failedAt
                    if elapsed.isFinite, elapsed >= 0, elapsed < Self.manualAccessibilityRetrySeconds {
                        manualAccessibilityLock.unlock()
                        return .failed
                    }
                }
            }
        }
        rememberManualAccessibility(.probing(attempt), pid: pid)
        manualAccessibilityLock.unlock()

        installManualAccessibilityTerminationObserverIfNeeded()

        let status = activate(pid)
        let state = Self.manualAccessibilityState(forSetStatus: status)

        let completedAt = now()
        manualAccessibilityLock.lock()
        // A termination, eviction, or replacement attempt invalidates this completion.
        let isCurrent = manualAccessibilityPIDs[pid] == .probing(attempt)
        if isCurrent {
            rememberManualAccessibility(
                state == .failed ? .failed(at: completedAt) : .settled(state),
                pid: pid
            )
        }
        manualAccessibilityLock.unlock()
        guard isCurrent else { return .failed }

        // The first `.cannotComplete` is the 50 ms timeout while an app is still launching.
        // Logging it at info filled the diagnostic mirror; the follow-up records the settled answer.
        let followUp = isFollowUp ? " followUp=1" : ""
        if state == .failed && !isFollowUp {
            DevTypeLog.selection.debug(
                """
                [Selection] AXManualAccessibility pid=\(pid, privacy: .public) \
                state=\(state.rawValue, privacy: .public) ax=\(status.rawValue, privacy: .public)
                """
            )
        } else {
            DevTypeLog.selection.info(
                """
                [Selection] AXManualAccessibility pid=\(pid, privacy: .public) \
                state=\(state.rawValue, privacy: .public) ax=\(status.rawValue, privacy: .public)\(followUp, privacy: .public)
                """
            )
        }
        if state == .failed {
            scheduleFollowUp?(pid)
        }
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
        manualAccessibilityOrder.removeAll { $0 == pid }
        manualAccessibilityLock.unlock()
        if removed != nil {
            DevTypeLog.selection.debug(
                """
                [Selection] AXManualAccessibility memo evicted pid=\(pid, privacy: .public)
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
        manualAccessibilityOrder.removeAll()
        manualAccessibilityLock.unlock()
    }

    /// Test hook — seed a remembered state without an AX round-trip.
    public func seedManualAccessibilityForTesting(pid: pid_t, state: ManualAccessibilityState) {
        manualAccessibilityLock.lock()
        rememberManualAccessibility(
            state == .failed
                ? .failed(at: ProcessInfo.processInfo.systemUptime)
                : .settled(state),
            pid: pid
        )
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

    /// Screen frame from `kAXPosition` and `kAXSize`. Nil when either attribute is unreadable
    /// or the size is not a positive finite rect. A zero or non-finite frame is not evidence
    /// that two controls are the same one.
    static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionRef, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        let frame = CGRect(origin: origin, size: size)
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.size.width > 0, frame.size.height > 0 else {
            return nil
        }
        return frame
    }

    /// Text attributes whose settability distinguishes an editable field from a rendered
    /// projection. `AXValue` covers plain fields; `AXSelectedText` covers views that only accept
    /// ranged edits (most web and document editors report the latter and not the former).
    static let textMutationAttributes: [String] = [
        kAXValueAttribute as String,
        kAXSelectedTextAttribute as String
    ]

    /// Whether the element advertises any settable text attribute.
    ///
    /// - Returns: `true`/`false` when AX answered for at least one attribute, `nil` when it could
    ///   not answer at all (timeout, dead element, a process that does not implement the API).
    ///   The nil case must never be read as "not editable": an unanswered probe is the same
    ///   "AX cannot tell us" baseline as an unreadable value, and callers treat it as such.
    public func acceptsTextMutation(element: AXUIElement) -> Bool? {
        var answered = false
        var settableAny = false
        for attribute in Self.textMutationAttributes {
            var settable: DarwinBoolean = false
            switch AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) {
            case .success:
                answered = true
                if settable.boolValue { settableAny = true }
            case .attributeUnsupported, .noValue:
                // A definite answer: the element does not offer this way in.
                answered = true
            default:
                // cannotComplete / invalidUIElement / notImplemented — no answer, not a "no".
                continue
            }
        }
        return answered ? settableAny : nil
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
    ///
    /// - Parameter focus: a focus result the caller already resolved — and whose retry it owns —
    ///   so the gate does not issue a second query. `nil` queries here (synchronous form: the
    ///   retry runs only off main).
    public func evaluateExpandGate(
        canUseAX: Bool,
        canPostEvents: Bool = false,
        focus resolvedFocus: FocusQueryResult? = nil
    ) -> ExpandGateDecision {
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

        let focus = resolvedFocus ?? queryFocusedElement()
        switch focus {
        case .available(let element):
            let secure = isFocusedElementSecure(element: element)
            let ime = hasActiveIMEMarkedText(element: element)
            // One bounded round trip on a path that already made two. The erase guard branches
            // on this role, so leaving it out of the report is what makes an erase refusal
            // unreadable after the fact.
            let role = focusedElementRole(element: element)
            if secure {
                let snapshot = DiagnosticReport.ExpandGateSnapshot(
                    canUseAX: true,
                    axTrusted: true,
                    focusedAvailable: true,
                    isSecureField: true,
                    hasIMEMarkedText: ime,
                    shouldBlockExpand: true,
                    blockReason: "Focused secure text field — expand blocked",
                    focusedRole: role
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
                    blockReason: "Active IME marked text — expand blocked",
                    focusedRole: role
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
                blockReason: "ok",
                focusedRole: role
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
            // Corroborate before refusing. One bounded `AXRole` round trip on the path that is
            // already giving up costs nothing the user notices, and it is the difference
            // between "this app is hung" and "our focus budget was too small" in the report.
            var appResponding: Bool?
            if case .axFailure = focus,
               let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                appResponding = Self.appRespondsToAX(pid: pid)
            }
            let reason = Self.focusBlockReason(for: focus, appResponding: appResponding)
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
    ///
    /// §2.2: `focus` is required — an IDE's terminal check reads the focused element, and an
    /// inject must hand over the one it resolved rather than have this query behind it.
    public func isFrontmostShellLikeContext(focus: FocusedElementSource) -> Bool {
        if isFrontmostAppTerminal() { return true }
        guard let bundleID = frontmostApplicationBundleIdentifier() else { return false }
        guard isIDEBundleID(bundleID) else { return false }
        return focusedElementLooksLikeTerminal(focus: focus)
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
    /// conservative: since the payload is now identical on both sides of this decision, the only
    /// stake left is the AX direct-set attempt, which a shell-like verdict skips. A false negative
    /// costs one wasted AX write attempt against a terminal; a false positive costs a document
    /// edit the slower clipboard path it did not need.
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
    /// or an Xcode file named `Console.swift` was misread as a shell. That once meant literal
    /// escape sequences in a source file; since the payload no longer varies by verdict, it now
    /// only costs the file its AX write path. It requires **both** a terminal-ish AX role and a
    /// terminal-shaped title token.
    public func focusedElementLooksLikeTerminal(focus: FocusedElementSource) -> Bool {
        let axElement: AXUIElement
        switch focus {
        case .resolved(let element):
            guard let element else { return false }
            axElement = element
        case .live:
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

    private static func isMissingFocus(_ focus: FocusQueryResult) -> Bool {
        if case .missing = focus { return true }
        return false
    }

    // MARK: - Private

    /// Probe order: system-wide → app-scoped frontmost → focused-application chain.
    /// Fail-closed (returns last non-available result) when every path fails.
    private func copyFocusedElementOnce(
        timeoutSeconds: Float = messagingTimeoutSeconds
    ) -> FocusQueryResult {
        let systemWide = systemWideElement(timeoutSeconds: timeoutSeconds)
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
                Self.applyMessagingTimeout(to: appEl, seconds: timeoutSeconds)
                appScopedCopy = copyFocusedUIElement(from: appEl)
                appScopedMapped = mapFocusCopy(appScopedCopy)
            }
            chain = copyFocusedElementViaFocusedApplicationChain(timeoutSeconds: timeoutSeconds)
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

    private func copyFocusedElementViaFocusedApplicationChain(
        timeoutSeconds: Float = messagingTimeoutSeconds
    ) -> FocusedApplicationChainResult {
        let systemWide = systemWideElement(timeoutSeconds: timeoutSeconds)
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
        Self.applyMessagingTimeout(to: focusedApp, seconds: timeoutSeconds)
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

/// §2.2: where an AX collaborator gets the element it reads or writes.
///
/// An optional element cannot say this: `nil` would mean both "the caller holds none, query
/// now" and "the inject resolved focus and there was none". The second must not re-query —
/// whatever a fresh query found would not be the target the inject's gates approved.
public enum FocusedElementSource {
    /// Resolve focus now. For callers outside an expansion, which hold no element.
    case live
    /// The element an expansion resolved once and threads through; `nil` when focus was missing
    /// or unreadable at that resolution.
    case resolved(AXUIElement?)

    public var element: AXUIElement? {
        switch self {
        case .live: return AXContextChecker.shared.focusedElement()
        case .resolved(let element): return element
        }
    }
}

/// §2.2: counting seam at the one choke point every focus query passes through
/// (`AXContextChecker.queryFocusedElement(attempt:)`).
///
/// An expansion is meant to resolve focus once and thread that element through; the remaining
/// queries are deliberate same-element re-checks (`PasteTarget.liveMismatch`,
/// `DeliveryVerifier.verifyFocusedTextDelivery`). Counting here is how a test holds an expansion
/// to that budget without a live AX tree. Production pays one lock and a nil check per query,
/// which is noise beside the AX round trip it precedes.
enum FocusQueryProbe {
    private static let lock = UnfairLock()
    private static var count: Int?

    static func record() {
        lock.withLock {
            if let current = count { count = current + 1 }
        }
    }

    /// Counts the focus queries `body` issues, on any thread, until it returns.
    static func counting(_ body: () throws -> Void) rethrows -> Int {
        lock.withLock { count = 0 }
        defer { lock.withLock { count = nil } }
        try body()
        return lock.withLock { count ?? 0 }
    }
}
