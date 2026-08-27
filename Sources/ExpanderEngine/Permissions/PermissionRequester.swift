import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation

/// Per-kind CG/AX request. Never auto-opens Settings. Uses temp `.regular` for LSUIElement prompts.
public final class PermissionRequester {
    public static let shared = PermissionRequester()

    /// Request never auto-opens Settings — Open is always a separate explicit user action.
    public static let autoOpensSettingsAfterRequest = false

    /// How long to keep `.regular` after Request so TCC sheets are not killed by an immediate `.accessory` restore.
    public static let activationPolicySettleInterval: TimeInterval = 1.5

    public struct RequestResult: Equatable {
        public let kind: PermissionKind
        public let apiReturnedTrue: Bool
        public let preflightGranted: Bool
        public let usedListenOnlyProbe: Bool

        public init(
            kind: PermissionKind,
            apiReturnedTrue: Bool,
            preflightGranted: Bool,
            usedListenOnlyProbe: Bool = false
        ) {
            self.kind = kind
            self.apiReturnedTrue = apiReturnedTrue
            self.preflightGranted = preflightGranted
            self.usedListenOnlyProbe = usedListenOnlyProbe
        }
    }

    private let probe = PermissionProbe()
    /// Intended non-regular policy to restore (usually `.accessory`). Survives stacked Requests
    /// that observe `.regular` as the current policy and would otherwise "restore" to `.regular`.
    private var intendedRestorePolicy: NSApplication.ActivationPolicy = .accessory
    /// When Setup is presented, keep `.regular` so TCC prompts work; Request must not flip back to accessory mid-wizard.
    private var setupHoldsRegular = false
    private var restoreWorkItem: DispatchWorkItem?
    private var resignObserver: NSObjectProtocol?

    public init() {}

    /// Hold `.regular` for the Setup window lifetime (SnipKey-style Dock prompts without accessory-only Request dance).
    public func beginSetupActivation() {
        setupHoldsRegular = true
        cancelPendingActivationRestore()
        guard let app = NSApp else {
            // No NSApplication yet (tests, very early launch) — nothing to promote. Fail closed
            // rather than trap; Setup presentation itself will re-run this once the app exists.
            DevTypeLog.permission.notice("[Permission] beginSetupActivation without NSApplication — skipped")
            return
        }
        let current = app.activationPolicy()
        if current != .regular {
            app.setActivationPolicy(.regular)
            DevTypeLog.permission.info(
                "[Permission] activationPolicy \(String(describing: current), privacy: .public) → .regular for Setup"
            )
        }
        app.activate(ignoringOtherApps: true)
    }

    /// Restore menu-bar `.accessory` when Setup closes / Finish / skip / dismiss.
    public func endSetupActivation() {
        guard setupHoldsRegular else { return }
        setupHoldsRegular = false
        cancelPendingActivationRestore()
        intendedRestorePolicy = .accessory
        guard let app = NSApp else {
            DevTypeLog.permission.notice("[Permission] endSetupActivation without NSApplication — skipped")
            return
        }
        let current = app.activationPolicy()
        if current != .accessory {
            app.setActivationPolicy(.accessory)
            DevTypeLog.permission.info(
                "[Permission] activationPolicy \(String(describing: current), privacy: .public) → .accessory after Setup"
            )
        }
    }

    /// Temporarily become `.regular`, activate, run `body`, then restore prior policy after settle
    /// or when the app resigns active (whichever first) — not immediately in `defer`.
    /// While Setup holds `.regular`, restore stays at `.regular` (does not undo Setup).
    public func withPromptActivation<T>(_ body: () -> T) -> T {
        // No NSApplication yet (tests, very early launch): skip the activation dance entirely and
        // just run the body — the prompt still happens, only the Dock/focus choreography is lost.
        guard let app = NSApp else {
            DevTypeLog.permission.notice("[Permission] withPromptActivation without NSApplication — running body without activation")
            return body()
        }
        let current = app.activationPolicy()
        cancelPendingActivationRestore()

        // Capture the real accessory/prior once; never overwrite with `.regular` from a prior Request.
        // During Setup, keep intended restore as `.regular` until endSetupActivation.
        if !setupHoldsRegular, current != .regular {
            intendedRestorePolicy = current
        }

        if current != .regular {
            app.setActivationPolicy(.regular)
            DevTypeLog.permission.debug(
                "[Permission] activationPolicy \(String(describing: current), privacy: .public) → .regular for TCC prompt"
            )
        } else {
            DevTypeLog.permission.debug(
                "[Permission] activationPolicy already .regular — keeping; will restore to \(String(describing: self.setupHoldsRegular ? .regular : self.intendedRestorePolicy), privacy: .public)"
            )
        }
        app.activate(ignoringOtherApps: true)
        let result = body()
        let restoreTo: NSApplication.ActivationPolicy = setupHoldsRegular ? .regular : intendedRestorePolicy
        scheduleActivationPolicyRestore(to: restoreTo)
        return result
    }

    private func scheduleActivationPolicyRestore(to prior: NSApplication.ActivationPolicy) {
        // Menu-bar apps must not stay `.regular` after Recovery Request — unless Setup holds it.
        let target: NSApplication.ActivationPolicy
        if setupHoldsRegular {
            target = .regular
        } else if prior == .regular {
            target = .accessory
        } else {
            target = prior
        }

        let restore: () -> Void = { [weak self] in
            guard let self else { return }
            self.cancelPendingActivationRestore()
            // Setup may have started while a Request settle was pending.
            let effectiveTarget: NSApplication.ActivationPolicy = self.setupHoldsRegular ? .regular : target
            let now = NSApp.activationPolicy()
            if now != effectiveTarget {
                NSApp.setActivationPolicy(effectiveTarget)
                DevTypeLog.permission.debug(
                    "[Permission] activationPolicy restored \(String(describing: now), privacy: .public) → \(String(describing: effectiveTarget), privacy: .public) after settle/resign"
                )
            }
        }

        let work = DispatchWorkItem(block: restore)
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.activationPolicySettleInterval,
            execute: work
        )

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            restore()
        }
    }

    private func cancelPendingActivationRestore() {
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    @discardableResult
    public func requestAccessibility() -> RequestResult {
        precondition(!Self.autoOpensSettingsAfterRequest)
        DevTypeLog.permission.info(
            "[Permission] request begin kind=\(DevTypeLog.kindName(.accessibility), privacy: .public)"
        )
        let before = probe.canUseAX()
        DevTypeLog.permission.info(
            "[Permission] check before request kind=Accessibility result=\(DevTypeLog.grantLabel(before), privacy: .public)"
        )
        return withPromptActivation {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            let granted = probe.canUseAX()
            let result = RequestResult(
                kind: .accessibility,
                apiReturnedTrue: trusted,
                preflightGranted: granted
            )
            DevTypeLog.permission.info(
                "[Permission] request result \(DevTypeLog.requestResultSummary(result), privacy: .public) api=AXIsProcessTrustedWithOptions(prompt)"
            )
            if !granted {
                DevTypeLog.permission.notice(
                    "[Permission] Accessibility still denied after prompt — enable in Settings or relaunch if toggle was just flipped"
                )
            }
            return result
        }
    }

    /// CGRequestListenEventAccess + short listenOnly probe when still denied (registration assist only).
    @discardableResult
    public func requestInputMonitoring() -> RequestResult {
        precondition(!Self.autoOpensSettingsAfterRequest)
        DevTypeLog.permission.info(
            "[Permission] request begin kind=\(DevTypeLog.kindName(.inputMonitoring), privacy: .public)"
        )
        let before = probe.canListenTap()
        DevTypeLog.permission.info(
            "[Permission] check before request kind=InputMonitoring result=\(DevTypeLog.grantLabel(before), privacy: .public)"
        )
        return withPromptActivation {
            var apiTrue = CGRequestListenEventAccess()
            var usedProbe = false
            var probeCreated = false
            DevTypeLog.permission.info(
                "[Permission] CGRequestListenEventAccess -> \(apiTrue, privacy: .public)"
            )

            if !probe.canListenTap() {
                usedProbe = true
                probeCreated = attemptListenOnlyRegistrationProbe()
                DevTypeLog.permission.info(
                    "[Permission] listenOnly registration probe created=\(probeCreated, privacy: .public)"
                )
                if !probeCreated {
                    DevTypeLog.permission.error(
                        "[Permission] listenOnly CGEvent tap create failed — TCC may not list this process under Input Monitoring"
                    )
                }
                if !probe.canListenTap() {
                    apiTrue = CGRequestListenEventAccess() || apiTrue
                    DevTypeLog.permission.info(
                        "[Permission] CGRequestListenEventAccess (retry) -> \(apiTrue, privacy: .public)"
                    )
                }
            }

            let granted = probe.canListenTap()
            let result = RequestResult(
                kind: .inputMonitoring,
                apiReturnedTrue: apiTrue,
                preflightGranted: granted,
                usedListenOnlyProbe: usedProbe
            )
            DevTypeLog.permission.info(
                "[Permission] request result \(DevTypeLog.requestResultSummary(result), privacy: .public)"
            )
            if !granted {
                DevTypeLog.permission.notice(
                    "[Permission] Input Monitoring still denied — click Request then enable DevType under Privacy → Input Monitoring"
                )
                if usedProbe && !probeCreated {
                    DevTypeLog.permission.notice(
                        "[Permission] \(PermissionCopy.staleTCCRecordGuidance, privacy: .public)"
                    )
                }
            }
            return result
        }
    }

    @discardableResult
    public func requestPostEvent() -> RequestResult {
        precondition(!Self.autoOpensSettingsAfterRequest)
        DevTypeLog.permission.info(
            "[Permission] request begin kind=\(DevTypeLog.kindName(.postEvent), privacy: .public)"
        )
        let before = probe.canPostEvents()
        DevTypeLog.permission.info(
            "[Permission] check before request kind=PostEvents result=\(DevTypeLog.grantLabel(before), privacy: .public)"
        )
        return withPromptActivation {
            let apiTrue = CGRequestPostEventAccess()
            let granted = probe.canPostEvents()
            let result = RequestResult(
                kind: .postEvent,
                apiReturnedTrue: apiTrue,
                preflightGranted: granted
            )
            DevTypeLog.permission.info(
                "[Permission] request result \(DevTypeLog.requestResultSummary(result), privacy: .public) api=CGRequestPostEventAccess"
            )
            if !granted {
                DevTypeLog.permission.notice(
                    "[Permission] Post Events still denied — no dedicated Settings pane; re-Request or enable under Accessibility if listed"
                )
            }
            return result
        }
    }

    @discardableResult
    public func request(kind: PermissionKind) -> RequestResult {
        switch kind {
        case .accessibility:
            return requestAccessibility()
        case .inputMonitoring:
            return requestInputMonitoring()
        case .postEvent:
            return requestPostEvent()
        case .microphone:
            final class GrantBox: @unchecked Sendable { var granted = false }
            let box = GrantBox()
            let sem = DispatchSemaphore(value: 0)
            VoiceAudioRecorder.requestMicrophonePermission { result in
                box.granted = result
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 2.0)
            return RequestResult(
                kind: .microphone,
                apiReturnedTrue: box.granted,
                preflightGranted: VoiceAudioRecorder.checkMicrophonePermission()
            )
        case .speechRecognition:
            return RequestResult(
                kind: .speechRecognition,
                apiReturnedTrue: true,
                preflightGranted: true
            )
        }
    }

    /// Short-lived `.listenOnly` tap so TCC can list this process under ListenEvent.
    /// Not the production `.defaultTap` / `.cghidEventTap` engine path.
    @discardableResult
    public func attemptListenOnlyRegistrationProbe() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in
                Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )
        guard let port else {
            return false
        }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        return true
    }
}
