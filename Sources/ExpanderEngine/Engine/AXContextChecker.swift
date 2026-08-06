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
