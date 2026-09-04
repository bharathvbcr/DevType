import AppKit
import ExpanderEngine

/// Flipped document so the step card lays out top-to-bottom inside the scroll view.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// First-run guided wizard: Welcome → Input Monitoring → Accessibility+Post → Verify → Done.
final class PermissionOnboardingController: NSViewController {
    enum Step: Int, CaseIterable {
        case welcome
        case inputMonitoring
        case accessibilityAndPost
        case verify
        case done
    }

    /// Longest the wizard waits for `codesign` before it stops gating Finish on the hash.
    ///
    /// `BoundedProcess` already caps each `codesign` invocation, so this is the second line of
    /// defence: whatever goes wrong upstream — saturated global queue, a completion that never
    /// fires — the user must not end up staring at a permanently disabled Finish button with no
    /// way to complete setup.
    static let cdHashWatchdogInterval: TimeInterval = 15.0

    /// Cadence for re-rendering while the window is open. Grants can land without the app ever
    /// deactivating (a TCC prompt answered in place, `tccutil`, another window flipping a
    /// toggle), and `applicationDidBecomeActive` never fires for those.
    static let liveRefreshInterval: TimeInterval = 1.5

    /// Settle before re-reading TCC after a Request — the daemon updates asynchronously.
    static let requestSettleInterval: TimeInterval = 1.0

    private let onFinished: () -> Void
    private var step: Step = .welcome

    // Permission-facing labels are localized through LocalizationManager so the first-run
    // recovery flow does not fall back to English-only guidance.
    private let loc = LocalizationManager.shared
    private var permissionCopy: PermissionCopy.Localized {
        PermissionCopy.localized(using: loc)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let identityLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var primaryButton: CapsuleButton?
    private var secondaryButton: CapsuleButton?
    private let tertiaryButton = NSButton(
        title: LocalizationManager.shared.s("onboarding.skip"),
        target: nil,
        action: nil
    )
    private var backButton: CapsuleButton?
    private var stepPill: PillBadgeView?
    private var progressSegments: [NSView] = []

    private var cdHash: String?
    private var cdHashLoadFinished = false
    private var cdHashWatchdog: DispatchWorkItem?

    /// Single-flight for the post-Request settle. Double-clicking Request used to stack one
    /// settle block per click, each calling `refresh(presentTapFailureAlert: true)` — which stacks
    /// one modal Tap Failed alert per click on top of the wizard.
    private var pendingRequestSettle: DispatchWorkItem?
    private var requestInFlight = false

    /// Set once the user has actually asked macOS for Input Monitoring. Lets that step advance
    /// even when the grant never materialises — see `canAdvanceFromInputMonitoring`.
    private var didAttemptInputMonitoringRequest = false

    /// Live re-render while visible, plus the state fingerprint that decides whether a tick is
    /// worth acting on. Re-rendering unconditionally would wipe the transient "still missing…"
    /// hints a moment after they appear.
    private var liveRefreshTimer: Timer?
    private var lastRenderedSignature: String?

    /// Advice that outlives a single `render()`.
    ///
    /// Every hint site set `statusLabel.stringValue` and then called `render()`, which
    /// unconditionally reassigns that label from the step branch — so "Still missing Input
    /// Monitoring…" and the whole Open Settings guidance block were written and erased in the same
    /// turn of the run loop and never reached the screen. Holding the hint here lets `render()`
    /// re-apply it, and lets a real state change clear it.
    private var transientHint: (text: String, color: NSColor)?
    private var lastAnnouncedStatus: String?

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let mainView = NSView()
        mainView.wantsLayer = true
        mainView.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        // MARK: Header + step indicator
        let header = DevTypeTheme.makeBrandHeader(
            title: loc.s("onboarding.title"),
            subtitle: loc.s("onboarding.subtitle"),
            logoSize: 38
        )
        mainView.addSubview(header)

        let pill = PillBadgeView(
            text: loc.s("onboarding.step", 1, Step.allCases.count),
            tint: DevTypeTheme.accent
        )
        stepPill = pill
        mainView.addSubview(pill)

        progressSegments = (0..<Step.allCases.count).map { _ in
            let segment = NSView()
            segment.wantsLayer = true
            segment.layer?.cornerRadius = 2
            segment.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            segment.translatesAutoresizingMaskIntoConstraints = false
            return segment
        }
        let progressStack = NSStackView(views: progressSegments)
        progressStack.orientation = .horizontal
        progressStack.spacing = 6
        progressStack.distribution = .fillEqually
        progressStack.translatesAutoresizingMaskIntoConstraints = false
        mainView.addSubview(progressStack)

        // MARK: Content card (scrollable — step text varies in length)
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        mainView.addSubview(scrollView)

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.06))
        card.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(card)
        let content = card.contentView

        titleLabel.font = DevTypeTheme.font(17, .bold)
        titleLabel.textColor = DevTypeTheme.textPrimary
        bodyLabel.font = DevTypeTheme.font(12)
        bodyLabel.textColor = DevTypeTheme.textSecondary
        bodyLabel.preferredMaxLayoutWidth = 500
        statusLabel.font = DevTypeTheme.font(11.5, .semibold)
        statusLabel.textColor = DevTypeTheme.textSecondary
        statusLabel.preferredMaxLayoutWidth = 500

        // Identity readout inside a dark inset block.
        let identityBlock = NSView()
        identityBlock.wantsLayer = true
        identityBlock.translatesAutoresizingMaskIntoConstraints = false
        identityBlock.layer?.cornerRadius = 10
        identityBlock.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.26).cgColor
        identityBlock.layer?.borderWidth = 1
        identityBlock.layer?.borderColor = DevTypeTheme.hairline.cgColor

        identityLabel.font = DevTypeTheme.mono(10.5)
        identityLabel.textColor = DevTypeTheme.accentBright
        identityLabel.preferredMaxLayoutWidth = 476
        identityLabel.translatesAutoresizingMaskIntoConstraints = false
        identityBlock.addSubview(identityLabel)

        NSLayoutConstraint.activate([
            identityLabel.topAnchor.constraint(equalTo: identityBlock.topAnchor, constant: 10),
            identityLabel.leadingAnchor.constraint(equalTo: identityBlock.leadingAnchor, constant: 12),
            identityLabel.trailingAnchor.constraint(equalTo: identityBlock.trailingAnchor, constant: -12),
            identityLabel.bottomAnchor.constraint(equalTo: identityBlock.bottomAnchor, constant: -10)
        ])

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let contentStack = NSStackView(views: [titleLabel, bodyLabel, identityBlock, statusLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentStack)

        for arranged in [titleLabel, bodyLabel, identityBlock, statusLabel] {
            arranged.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            card.heightAnchor.constraint(equalTo: contentStack.heightAnchor, constant: 36),

            card.topAnchor.constraint(equalTo: document.topAnchor),
            card.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            card.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        // MARK: Buttons
        let primary = CapsuleButton(
            title: loc.s("onboarding.continue"),
            style: .primary,
            target: self,
            action: #selector(primaryAction)
        )
        primaryButton = primary
        let secondary = CapsuleButton(
            title: loc.s("onboarding.openSettings"),
            style: .secondary,
            target: self,
            action: #selector(secondaryAction)
        )
        secondaryButton = secondary

        // Return activates the step's main action; Escape is Cancel, matching every other Mac
        // wizard. Neither key did anything before, so keyboard-only users could not advance.
        primary.keyEquivalent = "\r"
        tertiaryButton.keyEquivalent = "\u{1b}"

        let back = CapsuleButton(
            title: loc.s("onboarding.back"),
            style: .secondary,
            target: self,
            action: #selector(backAction)
        )
        backButton = back

        tertiaryButton.target = self
        tertiaryButton.action = #selector(skipAction)
        tertiaryButton.isBordered = false
        tertiaryButton.font = DevTypeTheme.font(11)
        tertiaryButton.contentTintColor = DevTypeTheme.textTertiary
        tertiaryButton.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView(views: [back, tertiaryButton])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 12
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        mainView.addSubview(primary)
        mainView.addSubview(secondary)
        mainView.addSubview(leftStack)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: mainView.topAnchor, constant: 44),
            header.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -10),

            pill.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -22),
            pill.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            progressStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            progressStack.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 22),
            progressStack.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -22),
            progressStack.heightAnchor.constraint(equalToConstant: 4),

            scrollView.topAnchor.constraint(equalTo: progressStack.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: leftStack.topAnchor, constant: -12),

            leftStack.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 22),
            leftStack.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -16),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: secondary.leadingAnchor, constant: -12),

            secondary.trailingAnchor.constraint(equalTo: primary.leadingAnchor, constant: -10),
            secondary.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -16),
            primary.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -22),
            primary.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -16)
        ])

        self.view = mainView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ProcessIdentity.shared.refreshCDHashAsync { [weak self] hash in
            guard let self else { return }
            self.cdHashWatchdog?.cancel()
            self.cdHashWatchdog = nil
            self.cdHash = hash
            self.cdHashLoadFinished = true
            self.render()
        }
        startCDHashWatchdog()
        // Dual-install detection shells out to Spotlight — resolve it off-main and re-render
        // when it lands rather than blocking every render on it.
        ProcessIdentity.shared.refreshDevelopmentBundlePresenceAsync { [weak self] _ in
            self?.render()
        }
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Return should fire Continue the moment the window opens.
        view.window?.makeFirstResponder(primaryButton)
        PermissionCoordinator.shared.refresh(presentTapFailureAlert: false)
        render()
        startLiveRefresh()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        SettingsDeepLinker.shared.cancelPendingOpen()
        stopLiveRefresh()
        pendingRequestSettle?.cancel()
        pendingRequestSettle = nil
        requestInFlight = false
        cdHashWatchdog?.cancel()
        cdHashWatchdog = nil
    }

    /// Stops gating Finish on a hash that is never going to arrive. Setup can complete without
    /// one — `markOnboardingCompleted` simply stores no hash, and the next launch backfills it.
    private func startCDHashWatchdog() {
        cdHashWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cdHashLoadFinished else { return }
            DevTypeLog.identity.error(
                "[Identity] CDHash load exceeded \(Self.cdHashWatchdogInterval, privacy: .public)s — unblocking Finish without a hash"
            )
            self.cdHashLoadFinished = true
            self.render()
        }
        cdHashWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cdHashWatchdogInterval, execute: work)
    }

    private func startLiveRefresh() {
        stopLiveRefresh()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.liveRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self, self.view.window?.isVisible == true else { return }
            // Only when something actually moved — an unconditional render would erase the
            // transient hints ("Still missing Input Monitoring…") a second after they appear.
            if self.currentRenderSignature() != self.lastRenderedSignature {
                DevTypeLog.permission.debug("[Permission] onboarding live refresh — state changed")
                // The hint described the state we just left; keeping it would contradict the
                // freshly rendered status line.
                self.transientHint = nil
                self.render()
            }
        }
        // The wizard is modal-feeling but not modal; keep ticking during menu tracking / drags.
        RunLoop.main.add(timer, forMode: .common)
        liveRefreshTimer = timer
    }

    private func stopLiveRefresh() {
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = nil
    }

    /// Fingerprint of everything `render()` branches on.
    private func currentRenderSignature() -> String {
        let snapshot = PermissionProbe().snapshot()
        return [
            String(step.rawValue),
            String(snapshot.canListenTap),
            String(snapshot.canUseAX),
            String(snapshot.canPostEvents),
            String(EventTapEngine.shared.isTapRunning),
            String(cdHashLoadFinished),
            String(ProcessIdentity.shared.cachedDevelopmentBundlePresent),
            String(requestInFlight)
        ].joined(separator: "|")
    }

    /// Called from AppDelegate when returning from System Settings.
    func refreshFromAppActivation() {
        DevTypeLog.permission.info("[Permission] onboarding refresh from app activation")
        PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
        render()
    }

    /// Re-render in the selected app language without restarting setup or dropping request state.
    func refreshLocalization() {
        guard isViewLoaded else { return }
        if let window = view.window {
            DevTypeTheme.styleWindow(window, title: loc.s("window.setup"))
        }
        transientHint = nil
        render()
    }

    private func updateStepIndicator() {
        stepPill?.update(
            text: loc.s("onboarding.step", step.rawValue + 1, Step.allCases.count),
            tint: DevTypeTheme.accent
        )
        for (index, segment) in progressSegments.enumerated() {
            // §5.3: dynamic overlay — the white track vanished in Light Mode.
            segment.layer?.backgroundColor = (
                index <= step.rawValue
                    ? DevTypeTheme.accent
                    : DevTypeTheme.contrastOverlay(0.14)
            ).cgColor
        }
    }

    private func render() {
        assertMainThread()
        lastRenderedSignature = currentRenderSignature()
        updateStepIndicator()
        let identity = ProcessIdentity.shared
        let snapshot = PermissionProbe().snapshot()
        let siblings = identity.siblingPaths()
        let appsExists = FileManager.default.fileExists(atPath: ProcessIdentity.preferredInstalledAppPath)
        // Include on-disk `.build/DevType.app` even when that copy is not running. Read from the
        // async cache — resolving it here would spawn `mdfind` on the main thread on every render.
        let buildPresent = identity.cachedDevelopmentBundlePresent
        let runningIDs = NSWorkspace.shared.runningApplications.map(\.bundleIdentifier)
        let hashText = cdHashLoadFinished
            ? (cdHash ?? loc.s("onboarding.identity.unavailable"))
            : loc.s("onboarding.identity.loading")
        var identityLines = [
            loc.s("onboarding.identity.bundleID", identity.bundleIdentifier),
            loc.s("onboarding.identity.path", identity.bundlePath),
            loc.s("onboarding.identity.cdHash", hashText),
            permissionCopy.livePreflightSummary(snapshot: snapshot)
        ]
        if let unpackaged = permissionCopy.unpackagedBinaryWarning(bundlePath: identity.bundlePath) {
            identityLines.append(unpackaged)
        }
        if let dual = permissionCopy.dualInstallWarning(
            runningPath: identity.bundlePath,
            applicationsExists: appsExists,
            buildBundleExists: buildPresent
        ) {
            identityLines.append(dual)
        }
        if let dup = permissionCopy.duplicateProcessWarning(siblingPaths: siblings) {
            identityLines.append(dup)
        }
        if let stale = permissionCopy.staleLegacyBundleWarning(runningBundleIDs: runningIDs) {
            identityLines.append(stale)
        }
        if !snapshot.isFullyCapable {
            identityLines.append(
                permissionCopy.settingsToggleMismatchGuidance(
                    executablePath: identity.executablePath,
                    cdHash: cdHash
                )
            )
            identityLines.append(permissionCopy.staleLegacyBundleIdGuidance)
        }
        identityLabel.stringValue = identityLines.joined(separator: "\n")

        guard let primaryButton, let secondaryButton else { return }
        secondaryButton.isHidden = false
        secondaryButton.isEnabled = true
        tertiaryButton.isHidden = false
        tertiaryButton.title = loc.s("onboarding.skip")
        primaryButton.isEnabled = true
        // Welcome is the first step, and Done is past the point where re-answering an earlier
        // step means anything — everything between them is revisitable.
        backButton?.isHidden = (step == .welcome || step == .done)

        switch step {
        case .welcome:
            DevTypeLog.permission.debug("[Permission] onboarding step=welcome")
            titleLabel.stringValue = loc.s("onboarding.welcome.title")
            bodyLabel.stringValue = loc.s("onboarding.welcome.body")
            if identity.isPackaged && siblings.isEmpty {
                statusLabel.stringValue = loc.s("onboarding.welcome.ok")
                statusLabel.textColor = DevTypeTheme.greenStatus
            } else if !identity.isPackaged {
                statusLabel.stringValue = loc.s("onboarding.welcome.unpackaged")
                statusLabel.textColor = DevTypeTheme.redBright
            } else {
                statusLabel.stringValue = loc.s("onboarding.welcome.siblings")
                statusLabel.textColor = DevTypeTheme.statusOrange
            }
            primaryButton.title = loc.s("onboarding.continue")
            secondaryButton.isHidden = true
            primaryButton.isEnabled = true

        case .inputMonitoring:
            DevTypeLog.permission.debug("[Permission] onboarding step=inputMonitoring")
            titleLabel.stringValue = loc.s("onboarding.im.title")
            bodyLabel.stringValue = permissionCopy.unlockDescription(for: .inputMonitoring)
                + "\n\n" + loc.s("onboarding.im.body")
            if snapshot.canListenTap {
                statusLabel.stringValue = loc.s("onboarding.im.granted")
            } else if didAttemptInputMonitoringRequest {
                // Requested and refused — say that continuing is allowed and what it costs.
                statusLabel.stringValue = loc.s("onboarding.im.missing")
                    + "\n" + loc.s("onboarding.im.blocked")
            } else {
                statusLabel.stringValue = loc.s("onboarding.im.missing")
            }
            statusLabel.textColor = snapshot.canListenTap ? DevTypeTheme.greenStatus : DevTypeTheme.redBright
            if snapshot.canListenTap {
                primaryButton.title = loc.s("onboarding.continue")
            } else if ProcessIdentity.canAdvanceFromInputMonitoring(
                canListenTap: false,
                didAttemptRequest: didAttemptInputMonitoringRequest
            ) {
                // Requested and still denied: offer to move on rather than trap the user here.
                // Verify and Done already treat a missing Listen as non-blocking.
                primaryButton.title = loc.s("onboarding.continueWithoutListen")
            } else {
                primaryButton.title = loc.s("onboarding.request")
            }
            primaryButton.isEnabled = !requestInFlight
            secondaryButton.title = loc.s("onboarding.openSettings")
            secondaryButton.isHidden = false

        case .accessibilityAndPost:
            DevTypeLog.permission.debug("[Permission] onboarding step=accessibilityAndPost")
            titleLabel.stringValue = loc.s("onboarding.ax.title")
            bodyLabel.stringValue = permissionCopy.unlockDescription(for: .accessibility)
                + "\n\n" + permissionCopy.unlockDescription(for: .postEvent)
                + "\n\n" + loc.s("onboarding.ax.body")
            var bits: [String] = []
            bits.append(snapshot.canUseAX ? loc.s("onboarding.ax.ok") : loc.s("onboarding.ax.missing"))
            bits.append(snapshot.canPostEvents ? loc.s("onboarding.post.ok") : loc.s("onboarding.post.optional"))
            statusLabel.stringValue = bits.joined(separator: " · ")
            statusLabel.textColor = snapshot.canUseAX
                ? DevTypeTheme.greenStatus : DevTypeTheme.redBright
            if !snapshot.canUseAX {
                primaryButton.title = loc.s("onboarding.requestAccessibility")
            } else if !snapshot.canPostEvents {
                // Allow advance without Post (degraded AX-only per README).
                primaryButton.title = loc.s("onboarding.continueAXOnly")
            } else {
                primaryButton.title = loc.s("onboarding.continue")
            }
            primaryButton.isEnabled = !requestInFlight
            secondaryButton.title = snapshot.canUseAX && !snapshot.canPostEvents
                ? loc.s("onboarding.requestPostEvents")
                : loc.s("onboarding.openAccessibility")
            secondaryButton.isEnabled = !requestInFlight
            secondaryButton.isHidden = false

        case .verify:
            DevTypeLog.permission.debug("[Permission] onboarding step=verify")
            titleLabel.stringValue = loc.s("onboarding.verify.title")
            PermissionCoordinator.shared.refresh(presentTapFailureAlert: false)
            let tap = EventTapEngine.shared.isTapRunning
            let canAdvance = ProcessIdentity.canAdvanceFromVerify(
                canListenTap: snapshot.canListenTap,
                tapRunning: tap,
                canUseAX: snapshot.canUseAX
            )
            let listenTapIncomplete = !snapshot.canListenTap || !tap
            bodyLabel.stringValue = snapshot.canUseAX
                ? loc.s("onboarding.verify.body.ok")
                : loc.s("onboarding.verify.body.blocked")
            var lines: [String] = []
            lines.append(snapshot.canListenTap
                ? loc.s("onboarding.verify.listen.ok")
                : loc.s("onboarding.verify.listen.missing"))
            lines.append(snapshot.canUseAX
                ? loc.s("onboarding.verify.ax.ok")
                : loc.s("onboarding.verify.ax.missing"))
            lines.append(snapshot.canPostEvents
                ? loc.s("onboarding.verify.post.ok")
                : loc.s("onboarding.verify.post.missing"))
            lines.append(tap
                ? loc.s("onboarding.verify.tap.running")
                : loc.s("onboarding.verify.tap.stopped"))
            if snapshot.isDegradedInject {
                lines.append(permissionCopy.degradedInjectTooltip(snapshot: snapshot))
            }
            if !snapshot.canUseAX {
                lines.append(loc.s("onboarding.verify.blocked"))
            } else if listenTapIncomplete {
                lines.append(loc.s("onboarding.verify.incomplete"))
            }
            statusLabel.stringValue = lines.joined(separator: "\n")
            statusLabel.textColor = canAdvance
                ? (listenTapIncomplete || !snapshot.canPostEvents
                    ? DevTypeTheme.statusOrange : DevTypeTheme.greenStatus)
                : DevTypeTheme.redBright

            // Continue when AX is OK; Post optional; Listen/tap incomplete does not block.
            primaryButton.title = canAdvance && !snapshot.canPostEvents
                ? loc.s("onboarding.continueAXOnly")
                : loc.s("onboarding.continue")
            primaryButton.isEnabled = canAdvance
            if let missing = SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: snapshot.canListenTap,
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents
            ) {
                secondaryButton.title = permissionCopy.openSettingsButtonTitle(for: missing)
                tertiaryButton.title = loc.s("onboarding.relaunch")
                tertiaryButton.isHidden = false
            } else {
                secondaryButton.title = loc.s("onboarding.relaunch")
                tertiaryButton.title = loc.s("onboarding.skip")
                tertiaryButton.isHidden = false
            }
            secondaryButton.isHidden = false

        case .done:
            DevTypeLog.permission.debug("[Permission] onboarding step=done")
            titleLabel.stringValue = loc.s("onboarding.done.title")
            PermissionCoordinator.shared.refresh(presentTapFailureAlert: false)
            let tap = EventTapEngine.shared.isTapRunning
            let canFinish = ProcessIdentity.canFinishOnboarding(
                canListenTap: snapshot.canListenTap,
                tapRunning: tap,
                canUseAX: snapshot.canUseAX,
                cdHash: cdHash,
                cdHashLoadFinished: cdHashLoadFinished
            )
            let listenTapIncomplete = !snapshot.canListenTap || !tap
            if !snapshot.canUseAX {
                bodyLabel.stringValue = loc.s("onboarding.done.body.blocked")
            } else if !canFinish {
                bodyLabel.stringValue = loc.s("onboarding.done.body.pending")
            } else {
                bodyLabel.stringValue = loc.s("onboarding.done.body.ready")
            }
            var doneLines = [permissionCopy.missingCapabilitiesSummary(snapshot)]
            if !cdHashLoadFinished {
                doneLines.append(loc.s("onboarding.done.waitingHash"))
            } else if cdHash == nil {
                doneLines.append(loc.s("onboarding.done.noHash"))
            }
            if !canFinish {
                if !snapshot.canUseAX {
                    doneLines.append(loc.s("onboarding.done.blockedAX"))
                }
            } else {
                if listenTapIncomplete {
                    doneLines.append(loc.s("onboarding.done.incomplete"))
                }
                if !snapshot.canPostEvents {
                    doneLines.append(loc.s("onboarding.done.axOnly"))
                }
            }
            statusLabel.stringValue = doneLines.joined(separator: "\n")
            statusLabel.textColor = canFinish
                ? (snapshot.isFullyCapable && !listenTapIncomplete
                    ? DevTypeTheme.greenStatus : DevTypeTheme.statusOrange)
                : DevTypeTheme.redBright
            primaryButton.title = loc.s("onboarding.finish")
            primaryButton.isEnabled = canFinish
            secondaryButton.title = loc.s("onboarding.testExpansion")
            secondaryButton.isHidden = false
            if snapshot.canListenTap && snapshot.canUseAX && !snapshot.canPostEvents {
                tertiaryButton.title = loc.s("onboarding.requestPostEvents")
                tertiaryButton.isHidden = false
            } else if let missing = SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: snapshot.canListenTap,
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents
            ), missing != .postEvent {
                tertiaryButton.title = permissionCopy.openSettingsButtonTitle(for: missing)
                tertiaryButton.isHidden = false
            } else {
                tertiaryButton.isHidden = true
            }
        }

        // Re-applied after the step branch, which owns `statusLabel` outright.
        if let transientHint {
            statusLabel.stringValue += "\n" + transientHint.text
            statusLabel.textColor = transientHint.color
        }
        announceStatusIfNeeded()
    }

    /// VoiceOver gets nothing from a label whose text is swapped in place, so the step title and
    /// current status are announced explicitly whenever they change.
    private func announceStatusIfNeeded() {
        let announcement = "\(titleLabel.stringValue). \(statusLabel.stringValue)"
        guard announcement != lastAnnouncedStatus else { return }
        guard let window = view.window, window.isVisible else { return }
        // Do not consume the announcement while the controller is still being laid out or is
        // hidden. `viewDidAppear` renders again; retaining the pending value lets VoiceOver hear
        // the first visible state instead of permanently losing it.
        lastAnnouncedStatus = announcement
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    /// Shows advice that survives the next `render()`.
    private func setTransientHint(_ text: String, color: NSColor) {
        transientHint = (text, color)
        render()
    }

    @objc private func backAction() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        DevTypeLog.permission.info(
            "[Permission] onboarding back \(String(describing: self.step), privacy: .public) → \(String(describing: previous), privacy: .public)"
        )
        pendingRequestSettle?.cancel()
        pendingRequestSettle = nil
        requestInFlight = false
        transientHint = nil
        step = previous
        render()
    }

    /// Runs a TCC request and schedules exactly one settle pass.
    ///
    /// Single-flight matters here: each settle ends in
    /// `refresh(presentTapFailureAlert: true)`, so N stacked settles meant N modal Tap Failed
    /// alerts queued in front of the wizard from nothing worse than an impatient double-click.
    private func performRequest(
        logLabel: String,
        request: () -> Void,
        stillMissing: @escaping () -> Bool,
        stillMissingHint: @escaping () -> String
    ) {
        guard !requestInFlight else {
            DevTypeLog.permission.debug(
                "[Permission] onboarding request already in flight — ignoring \(logLabel, privacy: .public)"
            )
            return
        }
        DevTypeLog.permission.info("[Permission] onboarding Request \(logLabel, privacy: .public)")
        requestInFlight = true
        pendingRequestSettle?.cancel()
        transientHint = nil
        request()
        render()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRequestSettle = nil
            self.requestInFlight = false
            if stillMissing() {
                DevTypeLog.permission.notice(
                    "[Permission] onboarding \(logLabel, privacy: .public) still denied \(Self.requestSettleInterval, privacy: .public)s after request"
                )
                self.setTransientHint(stillMissingHint(), color: DevTypeTheme.statusOrange)
            } else {
                self.render()
            }
            PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
        }
        pendingRequestSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestSettleInterval, execute: work)
    }

    /// Post Events is the one optional capability and has no Settings list of its own, so the
    /// only remedy is re-Requesting — which makes it the easiest button to hammer.
    private func requestPostEvents() {
        performRequest(
            logLabel: "Post Events",
            request: { _ = PermissionRequester.shared.requestPostEvent() },
            stillMissing: { !PermissionProbe().snapshot().canPostEvents },
            stillMissingHint: { [loc] in loc.s("onboarding.post.stillMissing") }
        )
    }

    @objc private func primaryAction() {
        let snapshot = PermissionProbe().snapshot()
        switch step {
        case .welcome:
            step = .inputMonitoring
        case .inputMonitoring:
            if snapshot.canListenTap {
                step = .accessibilityAndPost
            } else if ProcessIdentity.canAdvanceFromInputMonitoring(
                canListenTap: false,
                didAttemptRequest: didAttemptInputMonitoringRequest
            ) {
                // Requested once and still denied — continue to Accessibility rather than dead-end.
                // Verify/Done surface the missing Listen and the menu stays honest about it.
                DevTypeLog.permission.notice(
                    "[Permission] onboarding advancing past Input Monitoring without a grant (request already attempted)"
                )
                step = .accessibilityAndPost
            } else {
                didAttemptInputMonitoringRequest = true
                performRequest(
                    logLabel: "Input Monitoring",
                    request: {
                        let result = PermissionRequester.shared.requestInputMonitoring()
                        PermissionCoordinator.shared.noteListenRequestResult(
                            preflightGranted: result.preflightGranted
                        )
                    },
                    // Offer Open after settle if still denied — do not auto-open.
                    stillMissing: { !PermissionProbe().snapshot().canListenTap },
                    stillMissingHint: { [loc] in loc.s("onboarding.im.stillMissing") }
                )
                return
            }
        case .accessibilityAndPost:
            if !snapshot.canUseAX {
                performRequest(
                    logLabel: "Accessibility",
                    request: {
                        let result = PermissionRequester.shared.requestAccessibility()
                        PermissionCoordinator.shared.noteAccessibilityRequestResult(
                            preflightGranted: result.preflightGranted
                        )
                    },
                    stillMissing: { !PermissionProbe().snapshot().canUseAX },
                    stillMissingHint: { [loc] in loc.s("onboarding.ax.stillMissing") }
                )
                return
            }
            // AX granted — advance even without Post (degraded AX-only).
            step = .verify
        case .verify:
            PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
            let tap = EventTapEngine.shared.isTapRunning
            let latest = PermissionProbe().snapshot()
            guard ProcessIdentity.canAdvanceFromVerify(
                canListenTap: latest.canListenTap,
                tapRunning: tap,
                canUseAX: latest.canUseAX
            ) else {
                DevTypeLog.permission.notice(
                    "[Permission] onboarding Verify blocked — Accessibility missing"
                )
                setTransientHint(
                    loc.s("onboarding.verify.cannotContinue"),
                    color: DevTypeTheme.redBright
                )
                return
            }
            step = .done
        case .done:
            PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
            let tap = EventTapEngine.shared.isTapRunning
            let latest = PermissionProbe().snapshot()
            let hash = cdHash ?? ProcessIdentity.shared.cachedCodeDirectoryHash
            guard ProcessIdentity.canFinishOnboarding(
                canListenTap: latest.canListenTap,
                tapRunning: tap,
                canUseAX: latest.canUseAX,
                cdHash: hash,
                cdHashLoadFinished: cdHashLoadFinished
            ) else {
                DevTypeLog.permission.notice(
                    "[Permission] onboarding Finish blocked — Accessibility missing or CDHash still loading"
                )
                let reason: String
                if !latest.canUseAX {
                    reason = loc.s("onboarding.done.finishBlockedAX")
                } else if !cdHashLoadFinished {
                    reason = loc.s("onboarding.done.finishBlockedHash")
                } else {
                    reason = loc.s("onboarding.done.finishBlockedGeneric")
                }
                setTransientHint(reason, color: DevTypeTheme.redBright)
                return
            }
            if hash == nil {
                DevTypeLog.identity.notice(
                    "[Identity] finishing onboarding without CDHash (codesign unavailable)"
                )
            }
            DevTypeLog.permission.info(
                "[Permission] onboarding completed — persisting onboardingCompleted + CDHash/path"
            )
            ProcessIdentity.markOnboardingCompleted(
                cdHash: hash,
                path: ProcessIdentity.shared.bundlePath
            )
            onFinished()
            view.window?.close()
            return
        }
        // Only reached on a successful step transition — the previous step's advice no longer
        // describes what is on screen.
        transientHint = nil
        render()
        PermissionCoordinator.shared.refresh()
    }

    @objc private func secondaryAction() {
        let snapshot = PermissionProbe().snapshot()
        switch step {
        case .inputMonitoring:
            presentOpenSettings(for: .inputMonitoring)
            return
        case .accessibilityAndPost:
            if snapshot.canUseAX && !snapshot.canPostEvents {
                requestPostEvents()
                return
            }
            presentOpenSettings(for: .accessibility)
            return
        case .verify:
            if let missing = SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: snapshot.canListenTap,
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents
            ) {
                presentOpenSettings(for: missing)
                return
            }
            relaunchApp()
        case .done:
            runTestExpansion()
            return
        default:
            break
        }
        render()
    }

    /// In-app Test Expansion: real inject into a controlled NSTextView lab.
    private func runTestExpansion() {
        TestExpansionLab.run(from: view.window)
    }

    @objc private func skipAction() {
        // On Verify with missing permissions, tertiary is Relaunch; on Done Post-only, Request Post.
        if step == .verify {
            let snapshot = PermissionProbe().snapshot()
            if SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: snapshot.canListenTap,
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents
            ) != nil {
                relaunchApp()
                return
            }
        }
        if step == .done {
            let snapshot = PermissionProbe().snapshot()
            if snapshot.canListenTap && snapshot.canUseAX && !snapshot.canPostEvents {
                requestPostEvents()
                return
            }
            if let missing = SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: snapshot.canListenTap,
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents
            ), missing != .postEvent {
                presentOpenSettings(for: missing)
                return
            }
        }
        DevTypeLog.permission.info("[Permission] onboarding skipped")
        // Allow skipping to recovery later; do not mark onboarding completed.
        onFinished()
        view.window?.close()
    }

    private func presentOpenSettings(for kind: PermissionKind) {
        DevTypeLog.permission.info(
            "[Permission] onboarding Open Settings kind=\(DevTypeLog.kindName(kind), privacy: .public)"
        )
        SettingsDeepLinker.shared.open(for: kind) { [weak self] result in
            guard let self else { return }
            let hint: String
            if !result.didOpen {
                DevTypeLog.permission.error(
                    "[Permission] onboarding Open Settings failed kind=\(DevTypeLog.kindName(kind), privacy: .public)"
                )
                hint = self.permissionCopy.settingsOpenFailureMessage(for: kind)
            } else {
                var text = self.permissionCopy.openSettingsWithoutRequestHint(
                    for: kind,
                    bundleID: ProcessIdentity.shared.bundleIdentifier
                )
                let snapshot = PermissionProbe().snapshot()
                if kind == .inputMonitoring, !snapshot.canUseAX {
                    text += "\n" + self.loc.s("onboarding.hint.imThenAX")
                } else if kind == .accessibility || kind == .postEvent {
                    text += "\n" + self.loc.s("onboarding.hint.postNoList")
                }
                hint = text
            }
            PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
            // Via `setTransientHint`, not `statusLabel` directly: the `render()` that follows
            // reassigns that label from the step branch and would erase this guidance outright.
            self.setTransientHint(hint, color: DevTypeTheme.statusOrange)
        }
    }

    private func relaunchApp() {
        DevTypeLog.app.info("[App] relaunch from onboarding")
        // A failed spawn must not become an unrequested quit — say so and stay in the wizard.
        guard AppRelauncher.relaunch() else {
            setTransientHint(loc.s("onboarding.relaunchFailed"), color: DevTypeTheme.redBright)
            return
        }
    }
}
