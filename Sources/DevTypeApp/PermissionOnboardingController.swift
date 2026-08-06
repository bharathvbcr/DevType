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

    private let onFinished: () -> Void
    private var step: Step = .welcome

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let identityLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var primaryButton: CapsuleButton?
    private var secondaryButton: CapsuleButton?
    private let tertiaryButton = NSButton(title: "Skip for now", target: nil, action: nil)
    private var stepPill: PillBadgeView?
    private var progressSegments: [NSView] = []

    private var cdHash: String?
    private var cdHashLoadFinished = false

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
            title: "DevType Setup",
            subtitle: "Grant access to unlock instant expansion",
            logoSize: 38
        )
        mainView.addSubview(header)

        let pill = PillBadgeView(text: "Step 1 of 5", tint: DevTypeTheme.accent)
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
        let primary = CapsuleButton(title: "Continue", style: .primary, target: self, action: #selector(primaryAction))
        primaryButton = primary
        let secondary = CapsuleButton(title: "Open Settings", style: .secondary, target: self, action: #selector(secondaryAction))
        secondaryButton = secondary

        tertiaryButton.target = self
        tertiaryButton.action = #selector(skipAction)
        tertiaryButton.isBordered = false
        tertiaryButton.font = DevTypeTheme.font(11)
        tertiaryButton.contentTintColor = DevTypeTheme.textTertiary
        tertiaryButton.translatesAutoresizingMaskIntoConstraints = false

        mainView.addSubview(primary)
        mainView.addSubview(secondary)
        mainView.addSubview(tertiaryButton)

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
            scrollView.bottomAnchor.constraint(equalTo: tertiaryButton.topAnchor, constant: -12),

            tertiaryButton.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 22),
            tertiaryButton.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -18),

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
            self?.cdHash = hash
            self?.cdHashLoadFinished = true
            self?.render()
        }
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        PermissionCoordinator.shared.refresh(presentTapFailureAlert: false)
        render()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        SettingsDeepLinker.shared.cancelPendingOpen()
    }

    /// Called from AppDelegate when returning from System Settings.
    func refreshFromAppActivation() {
        DevTypeLog.permission.info("[Permission] onboarding refresh from app activation")
        PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
        render()
    }

    private func updateStepIndicator() {
        stepPill?.update(
            text: "Step \(step.rawValue + 1) of \(Step.allCases.count)",
            tint: DevTypeTheme.accent
        )
        for (index, segment) in progressSegments.enumerated() {
            segment.layer?.backgroundColor = (
                index <= step.rawValue
                    ? DevTypeTheme.accent
                    : NSColor.white.withAlphaComponent(0.10)
            ).cgColor
        }
    }

    private func render() {
        updateStepIndicator()
        let identity = ProcessIdentity.shared
        let snapshot = PermissionProbe().snapshot()
        let siblings = identity.siblingPaths()
        let appsExists = FileManager.default.fileExists(atPath: ProcessIdentity.preferredInstalledAppPath)
        // Include on-disk `.build/DevType.app` even when that copy is not running.
        let buildPresent = ProcessIdentity.developmentAppBundlePresentIncludingOnDisk(
            runningPath: identity.bundlePath,
            siblingPaths: siblings
        )
        let runningIDs = NSWorkspace.shared.runningApplications.map(\.bundleIdentifier)
        var identityLines = [
            "Bundle ID: \(identity.bundleIdentifier)",
            "Path: \(identity.bundlePath)",
            "CDHash: \(cdHashLoadFinished ? (cdHash ?? "(unavailable)") : "(loading…)")",
            PermissionCopy.livePreflightSummary(snapshot: snapshot)
        ]
        if let unpackaged = ProcessIdentity.unpackagedBinaryWarning(bundlePath: identity.bundlePath) {
            identityLines.append(unpackaged)
        }
        if let dual = ProcessIdentity.dualInstallWarning(
            runningPath: identity.bundlePath,
            applicationsExists: appsExists,
            buildBundleExists: buildPresent
        ) {
            identityLines.append(dual)
        }
        if let dup = ProcessIdentity.duplicateProcessWarning(siblingPaths: siblings) {
            identityLines.append(dup)
        }
        if let stale = ProcessIdentity.staleLegacyBundleWarning(runningBundleIDs: runningIDs) {
            identityLines.append(stale)
        }
        if !snapshot.isFullyCapable {
            identityLines.append(
                ProcessIdentity.settingsToggleMismatchGuidance(
                    executablePath: identity.executablePath,
                    cdHash: cdHash
                )
            )
            identityLines.append(PermissionCopy.staleLegacyBundleIdGuidance)
        }
        identityLabel.stringValue = identityLines.joined(separator: "\n")

        guard let primaryButton, let secondaryButton else { return }
        secondaryButton.isHidden = false
        tertiaryButton.isHidden = false
        tertiaryButton.title = "Skip for now"
        primaryButton.isEnabled = true

        switch step {
        case .welcome:
            DevTypeLog.permission.debug("[Permission] onboarding step=welcome")
            titleLabel.stringValue = "Welcome"
            bodyLabel.stringValue = """
            DevType needs three separate capabilities: Input Monitoring (listen), Accessibility (context + AX inject), and Post Events (HID paste/backspace). Request presents the macOS prompt; Open Settings is separate and never auto-runs after Request.
            """
            if identity.isPackaged && siblings.isEmpty {
                statusLabel.stringValue = "Packaged identity looks good — continue."
                statusLabel.textColor = DevTypeTheme.greenStatus
            } else if !identity.isPackaged {
                statusLabel.stringValue =
                    "Warning: unpackaged binary — prefer /Applications/DevType.app via install-app.sh. Continue is still allowed."
                statusLabel.textColor = DevTypeTheme.redBright
            } else {
                statusLabel.stringValue =
                    "Warning: sibling DevType copies detected — quit other copies for reliable TCC. Continue is still allowed."
                statusLabel.textColor = .systemOrange
            }
            primaryButton.title = "Continue"
            secondaryButton.isHidden = true
            primaryButton.isEnabled = true

        case .inputMonitoring:
            DevTypeLog.permission.debug("[Permission] onboarding step=inputMonitoring")
            titleLabel.stringValue = "Input Monitoring"
            bodyLabel.stringValue = """
            \(PermissionCopy.unlockDescription(for: .inputMonitoring))

            Click Request, answer the macOS prompt, then enable DevType under Input Monitoring (scroll or + if needed). Open Settings only deep-links — it does not register the app.
            """
            statusLabel.stringValue = snapshot.canListenTap
                ? "✓ Listen granted"
                : "Missing Input Monitoring"
            statusLabel.textColor = snapshot.canListenTap ? DevTypeTheme.greenStatus : DevTypeTheme.redBright
            primaryButton.title = snapshot.canListenTap ? "Continue" : "Request"
            secondaryButton.title = "Open Settings"
            secondaryButton.isHidden = false

        case .accessibilityAndPost:
            DevTypeLog.permission.debug("[Permission] onboarding step=accessibilityAndPost")
            titleLabel.stringValue = "Accessibility + Post Events"
            bodyLabel.stringValue = """
            \(PermissionCopy.unlockDescription(for: .accessibility))

            \(PermissionCopy.unlockDescription(for: .postEvent))

            Accessibility is required. Post Events is optional — without it DevType runs in degraded AX-only mode (no terminal paste / HID cursor). Request Accessibility first; Open Settings opens the Accessibility pane only (no Privacy_PostEvent list).
            """
            var bits: [String] = []
            bits.append(snapshot.canUseAX ? "✓ Accessibility" : "✗ Accessibility")
            bits.append(snapshot.canPostEvents ? "✓ Post Events" : "○ Post Events (optional — AX-only without it)")
            statusLabel.stringValue = bits.joined(separator: " · ")
            statusLabel.textColor = snapshot.canUseAX
                ? DevTypeTheme.greenStatus : DevTypeTheme.redBright
            if !snapshot.canUseAX {
                primaryButton.title = "Request Accessibility"
            } else if !snapshot.canPostEvents {
                // Allow advance without Post (degraded AX-only per README).
                primaryButton.title = "Continue (AX-only)"
            } else {
                primaryButton.title = "Continue"
            }
            secondaryButton.title = snapshot.canUseAX && !snapshot.canPostEvents
                ? "Request Post Events"
                : "Open Accessibility"
            secondaryButton.isHidden = false

        case .verify:
            DevTypeLog.permission.debug("[Permission] onboarding step=verify")
            titleLabel.stringValue = "Verify"
            PermissionCoordinator.shared.refresh(presentTapFailureAlert: false)
            let tap = EventTapEngine.shared.isTapRunning
            let canAdvance = ProcessIdentity.canAdvanceFromVerify(
                canListenTap: snapshot.canListenTap,
                tapRunning: tap,
                canUseAX: snapshot.canUseAX
            )
            let listenTapIncomplete = !snapshot.canListenTap || !tap
            if !snapshot.canUseAX {
                bodyLabel.stringValue = """
                Accessibility is required to continue. Input Monitoring (Listen) and a running event tap are needed for Active expansion, but they do not block Continue once Accessibility is granted.

                Use Open Settings / Request, enable DevType for this exact binary, then Relaunch if needed. Post Events remains optional (AX-only degraded).
                """
            } else {
                bodyLabel.stringValue = """
                Accessibility granted — you can continue. Start the event tap if Input Monitoring is granted so the menu can show Active.

                Open Settings targets the next missing Privacy pane (Input Monitoring or Accessibility). When only Post Events is missing, use Request Post Events + Open Accessibility.
                If Accessibility was just enabled but inject still fails, click Relaunch DevType.
                Degraded mode: AX without Post → AX-only expands (no terminal paste / HID cursor). Listen/tap incomplete → not Active until granted.
                """
            }
            var lines: [String] = []
            lines.append(snapshot.canListenTap ? "Listen: OK" : "Listen: missing (needed for Active; not required to Continue)")
            lines.append(snapshot.canUseAX ? "Accessibility: OK" : "Accessibility: missing (required)")
            lines.append(snapshot.canPostEvents ? "Post Events: OK" : "Post Events: missing (optional — AX-only)")
            lines.append(tap ? "Tap: running" : "Tap: not running (needed for Active; not required to Continue)")
            if snapshot.isDegradedInject {
                lines.append(PermissionCopy.degradedInjectTooltip(snapshot: snapshot))
            }
            if !snapshot.canUseAX {
                lines.append("Blocked: grant Accessibility before Continue. Relaunch may be required after enabling.")
            } else if listenTapIncomplete {
                lines.append("Incomplete: Listen/tap not fully ready — Continue allowed; menu will not show Active yet.")
            }
            statusLabel.stringValue = lines.joined(separator: "\n")
            statusLabel.textColor = canAdvance
                ? (listenTapIncomplete || !snapshot.canPostEvents ? .systemOrange : DevTypeTheme.greenStatus)
                : DevTypeTheme.redBright

            // Continue when AX is OK; Post optional; Listen/tap incomplete does not block.
            primaryButton.title = canAdvance
                ? (snapshot.canPostEvents ? "Continue" : "Continue (AX-only)")
                : "Continue"
            primaryButton.isEnabled = canAdvance
            if let missing = SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: snapshot.canListenTap,
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents
            ) {
                secondaryButton.title = PermissionCopy.openSettingsButtonTitle(for: missing)
                tertiaryButton.title = "Relaunch DevType"
                tertiaryButton.isHidden = false
            } else {
                secondaryButton.title = "Relaunch DevType"
                tertiaryButton.title = "Skip for now"
                tertiaryButton.isHidden = false
            }
            secondaryButton.isHidden = false

        case .done:
            DevTypeLog.permission.debug("[Permission] onboarding step=done")
            titleLabel.stringValue = "Done"
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
                bodyLabel.stringValue = """
                Setup cannot Finish without Accessibility. Listen + running tap are recommended for Active expansion but do not block Finish once Accessibility is granted.

                Use Request / Open Settings on the earlier steps, then return here. Test Expansion opens an in-app NSTextView lab and runs a real inject (not Notes). Permission Recovery (⌘⇧P) is always available.
                """
            } else if !canFinish {
                bodyLabel.stringValue = """
                Finish is blocked until Accessibility is granted and CDHash has finished loading (Post Events optional). Listen/tap incomplete is warned below but does not block Finish.

                Test Expansion opens an in-app inject lab (controlled NSTextView) — it does not require Notes. Sample live trigger after Finish: :test
                """
            } else {
                bodyLabel.stringValue = """
                Ready to Finish. Finish stores onboardingCompleted + CDHash/path so Setup will not reappear. Menu Active still requires Listen + a running tap — use Permission Recovery if expansion is quiet.

                Test Expansion opens an in-app NSTextView lab and runs a real inject. Sample live trigger in Notes/TextEdit: :test
                Permission Recovery (⌘⇧P) is always available.
                """
            }
            var doneLines = [snapshot.missingCapabilitiesSummary]
            if !cdHashLoadFinished {
                doneLines.append("Waiting for CDHash before Finish…")
            } else if cdHash == nil {
                doneLines.append("CDHash unavailable — Finish will not store a hash.")
            }
            if !canFinish {
                if !snapshot.canUseAX {
                    doneLines.append("Blocked: need Accessibility.")
                }
            } else {
                if listenTapIncomplete {
                    doneLines.append("Incomplete: Listen/tap not ready — Finish allowed; menu will not show Active until both are OK.")
                }
                if !snapshot.canPostEvents {
                    doneLines.append("Finishing in AX-only degraded mode (Post Events optional).")
                }
            }
            statusLabel.stringValue = doneLines.joined(separator: "\n")
            statusLabel.textColor = canFinish
                ? (snapshot.isFullyCapable && !listenTapIncomplete ? DevTypeTheme.greenStatus : .systemOrange)
                : DevTypeTheme.redBright
            primaryButton.title = "Finish"
            primaryButton.isEnabled = canFinish
            secondaryButton.title = "Test Expansion"
            secondaryButton.isHidden = false
            if snapshot.canListenTap && snapshot.canUseAX && !snapshot.canPostEvents {
                tertiaryButton.title = "Request Post Events"
                tertiaryButton.isHidden = false
            } else if let missing = SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: snapshot.canListenTap,
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents
            ), missing != .postEvent {
                tertiaryButton.title = PermissionCopy.openSettingsButtonTitle(for: missing)
                tertiaryButton.isHidden = false
            } else {
                tertiaryButton.isHidden = true
            }
        }
    }

    @objc private func primaryAction() {
        let snapshot = PermissionProbe().snapshot()
        switch step {
        case .welcome:
            step = .inputMonitoring
        case .inputMonitoring:
            if snapshot.canListenTap {
                step = .accessibilityAndPost
            } else {
                DevTypeLog.permission.info("[Permission] onboarding Request Input Monitoring")
                let result = PermissionRequester.shared.requestInputMonitoring()
                PermissionCoordinator.shared.noteListenRequestResult(
                    preflightGranted: result.preflightGranted
                )
                render()
                // Offer Open after settle if still denied — do not auto-open.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    if !PermissionProbe().snapshot().canListenTap {
                        DevTypeLog.permission.notice(
                            "[Permission] onboarding Input Monitoring still denied 1s after request"
                        )
                        self.statusLabel.stringValue =
                            "Still missing Input Monitoring — click Open Settings if the prompt was dismissed, then Relaunch."
                        self.statusLabel.textColor = .systemOrange
                    }
                    self.render()
                    PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
                }
                return
            }
        case .accessibilityAndPost:
            if !snapshot.canUseAX {
                DevTypeLog.permission.info("[Permission] onboarding Request Accessibility")
                let result = PermissionRequester.shared.requestAccessibility()
                PermissionCoordinator.shared.noteAccessibilityRequestResult(
                    preflightGranted: result.preflightGranted
                )
                render()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    if !PermissionProbe().snapshot().canUseAX {
                        DevTypeLog.permission.notice(
                            "[Permission] onboarding Accessibility still denied 1s after request — relaunch may be required"
                        )
                        self.statusLabel.stringValue =
                            "Still missing Accessibility — enable in Settings, then Relaunch DevType."
                        self.statusLabel.textColor = .systemOrange
                    }
                    self.render()
                    PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
                }
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
                statusLabel.stringValue =
                    "Cannot continue — Accessibility is required (Listen/tap incomplete does not block once AX is granted)."
                statusLabel.textColor = DevTypeTheme.redBright
                render()
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
                if !latest.canUseAX {
                    statusLabel.stringValue =
                        "Finish blocked: Accessibility required. Listen/tap incomplete does not block Finish once AX is granted."
                } else if !cdHashLoadFinished {
                    statusLabel.stringValue = "Finish blocked: still loading CDHash…"
                } else {
                    statusLabel.stringValue =
                        "Finish blocked: need Accessibility (Post optional; Listen/tap not required to Finish)."
                }
                statusLabel.textColor = DevTypeTheme.redBright
                render()
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
                DevTypeLog.permission.info("[Permission] onboarding Request Post Events (optional)")
                _ = PermissionRequester.shared.requestPostEvent()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.render()
                    PermissionCoordinator.shared.refresh()
                }
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
                DevTypeLog.permission.info("[Permission] onboarding Done Request Post Events")
                _ = PermissionRequester.shared.requestPostEvent()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.render()
                    PermissionCoordinator.shared.refresh()
                }
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
            if !result.didOpen {
                DevTypeLog.permission.error(
                    "[Permission] onboarding Open Settings failed kind=\(DevTypeLog.kindName(kind), privacy: .public)"
                )
                self.statusLabel.stringValue = PermissionCopy.settingsOpenFailureMessage(for: kind)
                self.statusLabel.textColor = .systemOrange
            } else {
                var hint = PermissionCopy.openSettingsWithoutRequestHint(
                    for: kind,
                    bundleID: ProcessIdentity.shared.bundleIdentifier
                )
                let snapshot = PermissionProbe().snapshot()
                if kind == .inputMonitoring, !snapshot.canUseAX {
                    hint += "\nAfter enabling Input Monitoring, click Open Settings again for Accessibility."
                } else if kind == .accessibility || kind == .postEvent {
                    hint += "\nPost Events has no Settings list — use Request if the CG prompt is still needed."
                }
                self.statusLabel.stringValue = hint
                self.statusLabel.textColor = .systemOrange
            }
            PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
            self.render()
        }
    }

    private func relaunchApp() {
        DevTypeLog.app.info("[App] relaunch from onboarding")
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                PermissionCoordinator.shared.cancelPendingWork()
                NSApp.terminate(nil)
            }
        }
    }
}
