import AppKit
import ExpanderEngine

/// Flipped document so the recovery stack lays out top-to-bottom in the scroll view.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Menu ⌘⇧P recovery window. Two tabs: **Status** owns everything that fixes a
/// missing capability, **Diagnostics** owns the evidence you paste into an issue.
/// Both render from a single capability probe per refresh.
final class PermissionRecoveryController: NSViewController {
    private enum Tab: Int {
        case status = 0
        case diagnostics = 1
    }

    private let onStatusChanged: () -> Void

    private let livePreflightLabel = NSTextField(wrappingLabelWithString: "")
    private let duplicateWarningLabel = NSTextField(wrappingLabelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let guidanceLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsFallbackLabel = NSTextField(wrappingLabelWithString: "")
    private let extendedGuidanceLabel = NSTextField(wrappingLabelWithString: "")
    private var extendedGuidanceToggle: CapsuleButton?
    private var relaunchButton: CapsuleButton?

    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let inputMonitoringStatusLabel = NSTextField(labelWithString: "")
    private let postEventStatusLabel = NSTextField(labelWithString: "")

    private var accessibilityRequestButton: CapsuleButton?
    private var inputMonitoringRequestButton: CapsuleButton?
    private var postEventRequestButton: CapsuleButton?

    private var statusPane = NSStackView()
    private var tabControl: NSSegmentedControl?
    private let diagnostics = PermissionDiagnosticsController()

    private var cdHash: String?
    private var lastLoggedAccessibilityReset: Bool?
    private var lastLoggedIdentityChanged: Bool?

    init(onStatusChanged: @escaping () -> Void = {}) {
        self.onStatusChanged = onStatusChanged
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override func loadView() {
        let mainView = NSView()
        mainView.wantsLayer = true
        mainView.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

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

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        document.addSubview(stack)

        let headerView = DevTypeTheme.makeBrandHeader(
            title: "Permission Recovery",
            subtitle: "Capability split • Request ≠ Open Settings",
            logoSize: 40
        )

        let tabs = NSSegmentedControl(
            labels: ["Status & Fix", "Diagnostics"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabChanged)
        )
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.selectedSegment = Tab.status.rawValue
        tabs.segmentDistribution = .fillEqually
        tabControl = tabs

        addChild(diagnostics)
        let diagnosticsPane = diagnostics.view
        diagnosticsPane.isHidden = true

        buildStatusPane()

        stack.addArrangedSubview(headerView)
        stack.addArrangedSubview(tabs)
        stack.addArrangedSubview(statusPane)
        stack.addArrangedSubview(diagnosticsPane)

        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            statusPane.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            statusPane.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            diagnosticsPane.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            diagnosticsPane.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: mainView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 46),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22),

            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        self.view = mainView
    }

    /// Status tab: what is wrong, followed by every control that can fix it.
    private func buildStatusPane() {
        let pane = NSStackView()
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 14
        pane.translatesAutoresizingMaskIntoConstraints = false
        statusPane = pane

        // MARK: Status card
        livePreflightLabel.font = DevTypeTheme.mono(11, .semibold)
        livePreflightLabel.textColor = DevTypeTheme.accentBright
        livePreflightLabel.preferredMaxLayoutWidth = 540
        summaryLabel.font = DevTypeTheme.font(12, .bold)
        summaryLabel.preferredMaxLayoutWidth = 540
        guidanceLabel.font = DevTypeTheme.font(11)
        guidanceLabel.preferredMaxLayoutWidth = 540
        guidanceLabel.textColor = DevTypeTheme.textSecondary
        duplicateWarningLabel.font = DevTypeTheme.font(11, .semibold)
        duplicateWarningLabel.textColor = DevTypeTheme.statusOrange
        duplicateWarningLabel.preferredMaxLayoutWidth = 540
        duplicateWarningLabel.isHidden = true
        settingsFallbackLabel.font = DevTypeTheme.font(11)
        settingsFallbackLabel.preferredMaxLayoutWidth = 560
        settingsFallbackLabel.textColor = DevTypeTheme.statusOrange
        settingsFallbackLabel.isHidden = true

        let statusCard = makeCard()
        let statusStack = NSStackView(views: [
            summaryLabel, livePreflightLabel, guidanceLabel, duplicateWarningLabel
        ])
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 6
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusCard.contentView.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.topAnchor.constraint(equalTo: statusCard.contentView.topAnchor, constant: 14),
            statusStack.leadingAnchor.constraint(equalTo: statusCard.contentView.leadingAnchor, constant: 16),
            statusStack.trailingAnchor.constraint(equalTo: statusCard.contentView.trailingAnchor, constant: -16),
            statusCard.heightAnchor.constraint(equalTo: statusStack.heightAnchor, constant: 28)
        ])

        // MARK: Capability cards
        var accessRequest: CapsuleButton?
        let accessCard = createPermissionRow(
            symbol: "accessibility",
            title: "Accessibility",
            description: PermissionCopy.unlockDescription(for: .accessibility),
            statusLabel: accessibilityStatusLabel,
            openTitle: PermissionCopy.openSettingsButtonTitle(for: .accessibility),
            openAction: #selector(openAccessibilitySettings),
            requestAction: #selector(requestAccessibility),
            requestButtonOut: &accessRequest
        )
        accessibilityRequestButton = accessRequest

        var inputRequest: CapsuleButton?
        let inputCard = createPermissionRow(
            symbol: "keyboard",
            title: "Input Monitoring",
            description: PermissionCopy.unlockDescription(for: .inputMonitoring),
            statusLabel: inputMonitoringStatusLabel,
            openTitle: PermissionCopy.openSettingsButtonTitle(for: .inputMonitoring),
            openAction: #selector(openInputMonitoringSettings),
            requestAction: #selector(requestInputMonitoring),
            requestButtonOut: &inputRequest
        )
        inputMonitoringRequestButton = inputRequest

        var postRequest: CapsuleButton?
        let postCard = createPermissionRow(
            symbol: "cursorarrow.rays",
            title: "Post Events",
            description: PermissionCopy.unlockDescription(for: .postEvent),
            statusLabel: postEventStatusLabel,
            openTitle: PermissionCopy.openSettingsButtonTitle(for: .postEvent),
            openAction: #selector(openPostEventSettings),
            requestAction: #selector(requestPostEvent),
            requestButtonOut: &postRequest
        )
        postEventRequestButton = postRequest

        // MARK: Action row
        let relaunchBtn = CapsuleButton(
            title: "Relaunch DevType",
            symbol: "arrow.clockwise",
            style: .primary,
            target: self,
            action: #selector(relaunchApp)
        )
        relaunchButton = relaunchBtn
        let refreshBtn = CapsuleButton(
            title: "Re-check",
            symbol: "arrow.triangle.2.circlepath",
            style: .secondary,
            target: self,
            action: #selector(refreshPermissions)
        )
        let testExpandBtn = CapsuleButton(
            title: "Test Expansion",
            symbol: "bolt.fill",
            style: .secondary,
            target: self,
            action: #selector(runTestExpansion)
        )
        let actionRow = NSStackView(views: [relaunchBtn, refreshBtn, testExpandBtn])
        actionRow.orientation = .horizontal
        actionRow.spacing = 10
        actionRow.distribution = .fillEqually
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Long-tail troubleshooting, collapsed by default
        let toggle = CapsuleButton(
            title: "More troubleshooting",
            symbol: "chevron.down",
            style: .secondary,
            target: self,
            action: #selector(toggleExtendedGuidance)
        )
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.isHidden = true
        extendedGuidanceToggle = toggle
        extendedGuidanceLabel.font = DevTypeTheme.font(11)
        extendedGuidanceLabel.textColor = DevTypeTheme.textSecondary
        extendedGuidanceLabel.preferredMaxLayoutWidth = 560
        extendedGuidanceLabel.isHidden = true

        pane.addArrangedSubview(statusCard)
        pane.addArrangedSubview(settingsFallbackLabel)
        pane.addArrangedSubview(accessCard)
        pane.addArrangedSubview(inputCard)
        pane.addArrangedSubview(postCard)
        pane.addArrangedSubview(actionRow)
        pane.addArrangedSubview(toggle)
        pane.addArrangedSubview(extendedGuidanceLabel)

        for card in [statusCard, accessCard, inputCard, postCard] {
            card.trailingAnchor.constraint(equalTo: pane.trailingAnchor).isActive = true
        }
        actionRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor).isActive = true
        extendedGuidanceLabel.trailingAnchor.constraint(equalTo: pane.trailingAnchor).isActive = true
    }

    private func makeCard() -> GlassCardView {
        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.05))
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ProcessIdentity.shared.refreshCDHashAsync { [weak self] hash in
            self?.cdHash = hash
            self?.refreshPermissions()
        }
        refreshPermissions()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeKeyAndOrderFront(nil)
        refreshPermissions()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        SettingsDeepLinker.shared.cancelPendingOpen()
    }

    /// Called from AppDelegate when returning from System Settings.
    func refreshFromAppActivation() {
        DevTypeLog.permission.info("[Permission] UI Recovery refresh from app activation")
        refreshPermissions()
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let tab = Tab(rawValue: sender.selectedSegment) ?? .status
        statusPane.isHidden = tab != .status
        diagnostics.view.isHidden = tab != .diagnostics
        if tab == .diagnostics {
            DevTypeLog.permission.info("[Permission] UI Recovery → Diagnostics tab")
            diagnostics.didBecomeVisible()
        }
    }

    @objc private func toggleExtendedGuidance() {
        let showing = !extendedGuidanceLabel.isHidden
        extendedGuidanceLabel.isHidden = showing
        extendedGuidanceToggle?.title = showing ? "More troubleshooting" : "Hide troubleshooting"
        extendedGuidanceToggle?.setSymbol(showing ? "chevron.down" : "chevron.up")
    }

    private func createPermissionRow(
        symbol: String,
        title: String,
        description: String,
        statusLabel: NSTextField,
        openTitle: String,
        openAction: Selector,
        requestAction: Selector,
        requestButtonOut: inout CapsuleButton?
    ) -> NSView {
        let container = makeCard()

        let badge = IconBadgeView(symbol: symbol, tint: DevTypeTheme.accent, size: 34, pointSize: 15)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let titleField = DevTypeTheme.makeLabel(title, font: DevTypeTheme.font(13, .bold), color: DevTypeTheme.textPrimary)
        let descField = NSTextField(wrappingLabelWithString: description)
        descField.font = DevTypeTheme.font(11)
        descField.textColor = DevTypeTheme.textSecondary
        descField.preferredMaxLayoutWidth = 250

        textStack.addArrangedSubview(titleField)
        textStack.addArrangedSubview(descField)

        let openButton = CapsuleButton(
            title: openTitle,
            symbol: "gearshape",
            style: .secondary,
            target: self,
            action: openAction
        )
        let requestButton = CapsuleButton(
            title: "Request",
            symbol: "hand.raised",
            style: .primary,
            target: self,
            action: requestAction
        )
        requestButtonOut = requestButton

        let buttonStack = NSStackView(views: [openButton, requestButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let rowStack = NSStackView(views: [badge, textStack, statusLabel, buttonStack])
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 12
        container.contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: container.contentView.topAnchor, constant: 12),
            rowStack.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 14),
            rowStack.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -14),
            container.heightAnchor.constraint(equalTo: rowStack.heightAnchor, constant: 24)
        ])
        return container
    }

    // MARK: - Capability refresh

    @objc private func refreshPermissions() {
        DevTypeLog.permission.info("[Permission] UI Recovery re-check capabilities")
        let identity = ProcessIdentity.shared
        let bundleID = identity.bundleIdentifier
        let appPath = identity.bundlePath

        let siblings = identity.siblingPaths()
        let appsExists = FileManager.default.fileExists(atPath: ProcessIdentity.preferredInstalledAppPath)
        // Include on-disk `.build/DevType.app` even when that copy is not running.
        let buildPresent = ProcessIdentity.developmentAppBundlePresentIncludingOnDisk(
            runningPath: appPath,
            siblingPaths: siblings
        )
        let runningIDs = NSWorkspace.shared.runningApplications.map(\.bundleIdentifier)
        var warningBits: [String] = []
        if let unpackaged = ProcessIdentity.unpackagedBinaryWarning(bundlePath: appPath) {
            warningBits.append(unpackaged)
        }
        if let dual = ProcessIdentity.dualInstallWarning(
            runningPath: appPath,
            applicationsExists: appsExists,
            buildBundleExists: buildPresent
        ) {
            warningBits.append(dual)
        }
        if let dup = ProcessIdentity.duplicateProcessWarning(siblingPaths: siblings) {
            warningBits.append(dup)
        }
        if let stale = ProcessIdentity.staleLegacyBundleWarning(runningBundleIDs: runningIDs) {
            warningBits.append(stale)
        }
        if warningBits.isEmpty {
            duplicateWarningLabel.stringValue = ""
            duplicateWarningLabel.isHidden = true
        } else {
            duplicateWarningLabel.stringValue = warningBits.joined(separator: "\n")
            duplicateWarningLabel.isHidden = false
        }

        // Force observer + tap lifecycle; alert only when Listen looks granted but tapCreate fails.
        let snapshotBefore = PermissionProbe().snapshot()
        let shouldAlertTap =
            snapshotBefore.canListenTap && !EventTapEngine.shared.isTapRunning
        PermissionCoordinator.shared.refresh(presentTapFailureAlert: shouldAlertTap)
        let snapshot = PermissionProbe().snapshot()
        livePreflightLabel.stringValue = PermissionCopy.livePreflightSummary(snapshot: snapshot)
        livePreflightLabel.textColor = snapshot.isFullyCapable
            ? DevTypeTheme.statusGreen : DevTypeTheme.accentBright
        ProcessIdentity.rememberAccessibilityGranted(
            snapshot.canUseAX,
            cdHash: cdHash ?? identity.cachedCodeDirectoryHash
        )

        updateStatusLabel(accessibilityStatusLabel, isGranted: snapshot.canUseAX)
        updateStatusLabel(inputMonitoringStatusLabel, isGranted: snapshot.canListenTap)
        updateStatusLabel(postEventStatusLabel, isGranted: snapshot.canPostEvents)
        styleRequestButton(accessibilityRequestButton, isGranted: snapshot.canUseAX)
        styleRequestButton(inputMonitoringRequestButton, isGranted: snapshot.canListenTap)
        styleRequestButton(postEventRequestButton, isGranted: snapshot.canPostEvents)

        let needsRelaunch = !snapshot.isFullyCapable
            || PermissionCoordinator.shared.recommendsRelaunch
        if let relaunchButton {
            if needsRelaunch {
                relaunchButton.title = "Relaunch DevType (recommended)"
                relaunchButton.buttonStyle = .primary
                relaunchButton.setSymbol("arrow.clockwise")
            } else {
                relaunchButton.title = "Relaunch DevType"
                relaunchButton.buttonStyle = .secondary
                relaunchButton.setSymbol("arrow.clockwise")
            }
        }

        let tapRunning = EventTapEngine.shared.isTapRunning
        let display = EngineDisplayStatus.resolve(
            snapshot: snapshot,
            isTapRunning: tapRunning,
            isEnabled: EventTapEngine.shared.isEnabled,
            isSecureInputActive: EventTapEngine.shared.isSecureInputActive
        )
        let identityChanged = ProcessIdentity.shouldReOnboardForIdentityChange(
            currentCDHash: cdHash,
            currentPath: appPath
        )
        updateSummaryAndGuidance(
            snapshot: snapshot,
            display: display,
            tapRunning: tapRunning,
            bundleID: bundleID,
            appPath: appPath,
            siblingPaths: siblings,
            identityChanged: identityChanged
        )

        diagnostics.apply(
            PermissionDiagnosticsController.Evidence(
                bundleID: bundleID,
                appPath: appPath,
                cdHash: cdHash ?? identity.cachedCodeDirectoryHash,
                designatedRequirement: identity.cachedDesignatedRequirementString,
                siblingPaths: siblings,
                injectHealth: injectHealthSummary(snapshot: snapshot, tapRunning: tapRunning)
            )
        )

        // After successful re-grant for a new binary identity, update stored onboarding
        // CDHash/path so Recovery does not reopen forever on every launch.
        // CDHash must be non-nil before writing — if it is still loading, defer the update
        // via a ProcessIdentity callback so the stored hash is always consistent with the
        // path even when the Recovery window closes before the async codesign read finishes.
        if identityChanged, snapshot.canListenTap, tapRunning, snapshot.canUseAX {
            let resolvedHash = cdHash ?? identity.cachedCodeDirectoryHash
            if let resolvedHash {
                ProcessIdentity.updateOnboardingIdentity(cdHash: resolvedHash, path: appPath)
                DevTypeLog.identity.info(
                    "[Identity] Recovery re-grant succeeded — stored onboarding identity updated"
                )
            } else {
                // CDHash still loading: schedule a self-contained update via ProcessIdentity
                // so the write happens even if this view controller is deallocated first.
                let pathSnapshot = appPath
                DevTypeLog.identity.info(
                    "[Identity] Recovery re-grant succeeded — CDHash pending; scheduling deferred identity update for path=\(pathSnapshot, privacy: .public)"
                )
                ProcessIdentity.shared.refreshCDHashAsync { deferredHash in
                    ProcessIdentity.updateOnboardingIdentity(cdHash: deferredHash, path: pathSnapshot)
                    DevTypeLog.identity.info(
                        "[Identity] Deferred identity update completed cdHash=\(deferredHash ?? "nil", privacy: .public) path=\(pathSnapshot, privacy: .public)"
                    )
                }
            }
        }

        onStatusChanged()
    }

    private func updateSummaryAndGuidance(
        snapshot: PermissionSnapshot,
        display: EngineDisplayStatus,
        tapRunning: Bool,
        bundleID: String,
        appPath: String,
        siblingPaths: [String],
        identityChanged: Bool
    ) {
        let engineLabel = display.menuTitle.replacingOccurrences(of: "Status: ", with: "")
        let grantedHash = UserDefaults.standard.string(
            forKey: ProcessIdentity.accessibilityGrantedCDHashDefaultsKey
        )
        let accessibilityReset = ProcessIdentity.accessibilityAppearsReset(
            grantedCDHash: grantedHash,
            currentCDHash: cdHash ?? ProcessIdentity.shared.cachedCodeDirectoryHash,
            isCurrentlyGranted: snapshot.canUseAX
        )

        if accessibilityReset != lastLoggedAccessibilityReset {
            if accessibilityReset {
                DevTypeLog.identity.notice(
                    "[Identity] Accessibility appears reset grantedCDHash=\(grantedHash ?? "nil", privacy: .public) currentCDHash=\(self.cdHash ?? ProcessIdentity.shared.cachedCodeDirectoryHash ?? "nil", privacy: .public)"
                )
            }
            lastLoggedAccessibilityReset = accessibilityReset
        }
        if identityChanged != lastLoggedIdentityChanged {
            if identityChanged {
                DevTypeLog.identity.notice(
                    "[Identity] onboarding binary identity mismatch path=\(appPath, privacy: .public) cdHash=\(self.cdHash ?? "nil", privacy: .public)"
                )
            }
            lastLoggedIdentityChanged = identityChanged
        }

        // Long-tail advice collects here and lands behind the disclosure, so the
        // card above stays one readable instruction instead of four paragraphs.
        var extended: [String] = []

        if snapshot.canListenTap && tapRunning && snapshot.isFullyCapable {
            summaryLabel.stringValue = "✓ All capabilities · Tap running · Engine: \(engineLabel)"
            summaryLabel.textColor = DevTypeTheme.statusGreen
            guidanceLabel.stringValue = "You're set — text expansions are active for \(bundleID)."
            guidanceLabel.textColor = DevTypeTheme.statusGreen
        } else if snapshot.canListenTap && tapRunning && snapshot.isDegradedInject {
            summaryLabel.stringValue = "Tap running · Inject degraded · Engine: \(engineLabel)"
            summaryLabel.textColor = DevTypeTheme.statusOrange
            guidanceLabel.stringValue = PermissionCopy.degradedInjectTooltip(snapshot: snapshot)
            guidanceLabel.textColor = DevTypeTheme.statusOrange
        } else if snapshot.canListenTap && snapshot.canUseAX && !tapRunning {
            // Distinct from "permissions denied": Listen+AX OK but tapCreate failed.
            summaryLabel.stringValue = "Listen+AX granted · Tap create failed · Engine: \(engineLabel)"
            summaryLabel.textColor = DevTypeTheme.statusOrange
            guidanceLabel.stringValue = PermissionCopy.tapCreateFailedDespiteListenGuidance
            guidanceLabel.textColor = DevTypeTheme.statusOrange
        } else {
            var summary = "\(snapshot.missingCapabilitiesSummary) · Tap \(tapRunning ? "running" : "not running") · Engine: \(engineLabel)"
            if snapshot.blocksDefaultEventTap {
                summary += " · Listen+AX required for event tap"
            }
            if accessibilityReset {
                summary += " · Accessibility reset"
            }
            if identityChanged {
                summary += " · Binary identity changed"
            }
            summaryLabel.stringValue = summary
            summaryLabel.textColor = DevTypeTheme.accentBright

            if identityChanged || accessibilityReset {
                guidanceLabel.stringValue = PermissionCopy.binaryChangedGuidance(
                    appPath: appPath,
                    cdHash: cdHash
                )
                guidanceLabel.textColor = DevTypeTheme.statusOrange
            } else if snapshot.inputMonitoringBlocksEventTap || !snapshot.canUseAX || !snapshot.canPostEvents {
                // Settings-on / preflight-off is the common stuck state after wrong-copy grants.
                guidanceLabel.stringValue = ProcessIdentity.settingsToggleMismatchGuidance(
                    executablePath: ProcessIdentity.shared.executablePath,
                    cdHash: cdHash
                )
                guidanceLabel.textColor = DevTypeTheme.statusOrange
                if PermissionCoordinator.shared.recommendsRelaunch || !snapshot.isFullyCapable {
                    extended.append(
                        PermissionCopy.relaunchAfterSettingsGuidance(
                            missingNames: snapshot.missingCapabilityNames
                        )
                    )
                }
                extended.append(PermissionCopy.staleLegacyBundleIdGuidance)
                extended.append(PermissionCopy.staleTCCRecordGuidance)
            } else {
                guidanceLabel.stringValue = "Finish granting missing capabilities above."
                guidanceLabel.textColor = DevTypeTheme.textSecondary
            }
        }

        if !siblingPaths.isEmpty {
            guidanceLabel.stringValue += "\nQuit other DevType copies (especially .build) so Settings toggles apply to \(ProcessIdentity.preferredInstalledAppPath)."
            guidanceLabel.textColor = DevTypeTheme.statusOrange
        }

        // Failed inject outcomes bump urgency (not a quiet Active).
        if let outcome = PermissionCoordinator.shared.lastRecordedInjectOutcome {
            switch outcome {
            case .succeeded, .degradedAXOnly:
                break
            case .postedUnverified:
                // Informational only — Cmd+V was sent, but AX can't confirm (normal for Chrome,
                // Electron, and apps that hide accessibility values). Do not override summary color.
                guidanceLabel.stringValue =
                    "Last expand posted the paste shortcut but DevType could not confirm the text landed. This is expected for Chrome, Electron, and similar apps. If text appears in the field, the expand is working. Use Test Expansion to verify delivery in a controlled AppKit field."
            case .refused(let reason):
                summaryLabel.textColor = DevTypeTheme.accentBright
                if snapshot.canListenTap && tapRunning {
                    summaryLabel.stringValue =
                        "Inject refused · Tap running · Engine: \(engineLabel)"
                    guidanceLabel.stringValue = Self.guidanceForInjectRefuse(
                        reason: reason,
                        canUseAX: snapshot.canUseAX
                    )
                    guidanceLabel.textColor = DevTypeTheme.statusOrange
                }
            case .failedSilent:
                summaryLabel.stringValue =
                    "Inject failed · Tap \(tapRunning ? "running" : "not running") · Engine: \(engineLabel)"
                summaryLabel.textColor = DevTypeTheme.accentBright
                guidanceLabel.stringValue =
                    "Last expand erased the abbreviation but the paste did not land (or Post Events/HID failed). DevType tried to restore the trigger. Retry the expand, or use Test Expansion in a plain text field. If this keeps happening, click Request Post Events then Re-check."
                guidanceLabel.textColor = DevTypeTheme.statusOrange
            }
        }

        updateExtendedGuidance(extended)
    }

    private func updateExtendedGuidance(_ blocks: [String]) {
        let text = blocks.joined(separator: "\n\n")
        extendedGuidanceLabel.stringValue = text
        let hasContent = !text.isEmpty
        extendedGuidanceToggle?.isHidden = !hasContent
        if !hasContent {
            extendedGuidanceLabel.isHidden = true
            extendedGuidanceToggle?.title = "More troubleshooting"
            extendedGuidanceToggle?.setSymbol("chevron.down")
        }
    }

    /// One-line inject/tap health for the Diagnostics tab.
    private func injectHealthSummary(snapshot: PermissionSnapshot, tapRunning: Bool) -> String {
        var parts: [String] = []
        if !tapRunning && snapshot.canListenTap {
            parts.append("Tap expected but not running — UI will not show stale Active.")
        }
        if snapshot.isDegradedInject {
            parts.append(PermissionCopy.degradedInjectTooltip(snapshot: snapshot))
        }
        if snapshot.canListenTap && snapshot.canUseAX && snapshot.canPostEvents && tapRunning {
            parts.append("Inject path: full (AX + HID).")
        } else if snapshot.canListenTap && snapshot.canUseAX && !snapshot.canPostEvents {
            parts.append("Inject path: AX-only (no HID paste/cursor).")
        } else if snapshot.canListenTap && !snapshot.canUseAX {
            parts.append("Inject path: refused (Accessibility fail-closed).")
        }
        var health = parts.isEmpty ? "Inject health: idle" : parts.joined(separator: " ")
        if let outcome = PermissionCoordinator.shared.lastRecordedInjectOutcome {
            switch outcome {
            case .succeeded:
                health += " · Last inject: succeeded"
            case .postedUnverified:
                health += " · Last inject: posted (unverified — target app may not expose AX value)"
            case .refused(let reason):
                health += " · Last inject: refused — \(reason)"
            case .degradedAXOnly:
                health += " · Last inject: AX-only (degraded)"
            case .failedSilent:
                health += " · Last inject: failed (paste did not land)"
            }
        }
        return health
    }

    /// Honest Recovery copy: do not blame Accessibility when AX is already granted.
    private static func guidanceForInjectRefuse(reason: String, canUseAX: Bool) -> String {
        if !canUseAX
            || reason.contains("Accessibility unavailable")
            || reason.contains("AXIsProcessTrusted false") {
            return "Last expand was blocked (\(reason)). Fix Accessibility, then Re-check."
        }
        if reason.contains("Secure Input") {
            return "Last expand was blocked by Secure Input. Typed abbreviations cannot expand in password fields — use ⌘/ (Inline Search) or a hotkey to paste instead."
        }
        if reason.localizedCaseInsensitiveContains("secure text field") {
            return "Last expand was blocked in a password/secure field. Use ⌘/ (Inline Search) or a hotkey to paste — typing the abbreviation cannot work there."
        }
        if reason.contains("IME") {
            return "Last expand was blocked during IME composition. Finish or cancel the composition, then retry."
        }
        if reason.contains("timed out")
            || reason.contains("No focused")
            || reason.contains("focus query failed") {
            return "Last expand was blocked because focus could not be verified. Click into a normal text field and retry after focus settles."
        }
        return "Last expand was blocked (\(reason)). Click into a normal text field (not a password field), then retry."
    }

    private func updateStatusLabel(_ label: NSTextField, isGranted: Bool) {
        if isGranted {
            label.stringValue = "✓ Granted"
            label.textColor = DevTypeTheme.statusGreen
            label.font = DevTypeTheme.font(11, .bold)
        } else {
            label.stringValue = "⚠️ Missing"
            label.textColor = DevTypeTheme.accentBright
            label.font = DevTypeTheme.font(11, .bold)
        }
    }

    private func styleRequestButton(_ button: CapsuleButton?, isGranted: Bool) {
        guard let button else { return }
        if isGranted {
            button.title = "Granted"
            button.isEnabled = false
            button.buttonStyle = .secondary
            button.setSymbol("checkmark")
        } else {
            button.title = "Request"
            button.isEnabled = true
            button.buttonStyle = .primary
            button.setSymbol("hand.raised")
        }
    }

    // MARK: - Settings / request actions

    private func presentOpenResult(
        _ result: SettingsDeepLinker.OpenResult,
        kind: PermissionKind,
        didRequest: Bool
    ) {
        let identity = ProcessIdentity.shared
        let siblings = identity.siblingPaths()

        if !result.didOpen {
            DevTypeLog.permission.error(
                "[Permission] UI Recovery Settings open failed kind=\(DevTypeLog.kindName(kind), privacy: .public)"
            )
            settingsFallbackLabel.stringValue = PermissionCopy.settingsOpenFailureMessage(for: kind)
                + "\n"
                + PermissionCopy.notListedInSettingsGuidance(
                    for: kind,
                    bundleID: identity.bundleIdentifier,
                    appPath: identity.bundlePath,
                    siblingPaths: siblings,
                    binaryPath: identity.executablePath
                )
            settingsFallbackLabel.isHidden = false
            return
        }

        DevTypeLog.permission.info(
            "[Permission] UI Recovery Settings opened kind=\(DevTypeLog.kindName(kind), privacy: .public) afterRequest=\(didRequest, privacy: .public)"
        )
        if didRequest {
            settingsFallbackLabel.stringValue = PermissionCopy.notListedInSettingsGuidance(
                for: kind,
                bundleID: identity.bundleIdentifier,
                appPath: identity.bundlePath,
                siblingPaths: siblings,
                binaryPath: identity.executablePath
            )
        } else {
            settingsFallbackLabel.stringValue = PermissionCopy.openSettingsWithoutRequestHint(
                for: kind,
                bundleID: identity.bundleIdentifier
            )
        }
        settingsFallbackLabel.isHidden = false
        refreshPermissions()
    }

    private func openSettings(for kind: PermissionKind) {
        SettingsDeepLinker.shared.open(for: kind) { [weak self] result in
            self?.presentOpenResult(result, kind: kind, didRequest: false)
        }
    }

    @objc private func openAccessibilitySettings() {
        openSettings(for: .accessibility)
    }

    @objc private func openInputMonitoringSettings() {
        openSettings(for: .inputMonitoring)
    }

    @objc private func openPostEventSettings() {
        openSettings(for: .postEvent)
    }

    /// Shared shape for all three Request buttons: show the "not listed?" hint up
    /// front, fire the real request, then re-check once TCC has had time to settle.
    private func request(
        kind: PermissionKind,
        logLabel: String,
        perform: () -> Void,
        stillMissing: @escaping () -> Bool,
        stillMissingHint: String
    ) {
        DevTypeLog.permission.info("[Permission] UI Recovery Request \(logLabel, privacy: .public)")
        let identity = ProcessIdentity.shared
        settingsFallbackLabel.stringValue = PermissionCopy.notListedInSettingsGuidance(
            for: kind,
            bundleID: identity.bundleIdentifier,
            appPath: identity.bundlePath,
            siblingPaths: identity.siblingPaths(),
            binaryPath: identity.executablePath
        )
        settingsFallbackLabel.isHidden = false

        perform()
        refreshPermissions()
        // Do NOT auto-open Settings. Offer Open if still denied after settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if stillMissing() {
                DevTypeLog.permission.notice(
                    "[Permission] UI Recovery \(logLabel, privacy: .public) still denied 1s after request"
                )
                self.settingsFallbackLabel.stringValue += "\n" + stillMissingHint
            }
            self.refreshPermissions()
        }
    }

    private static let openSettingsThenRelaunchHint =
        "Still missing — click Open Settings if the prompt was dismissed, then Relaunch DevType."

    @objc private func requestAccessibility() {
        request(
            kind: .accessibility,
            logLabel: "Accessibility",
            perform: {
                let result = PermissionRequester.shared.requestAccessibility()
                PermissionCoordinator.shared.noteAccessibilityRequestResult(
                    preflightGranted: result.preflightGranted
                )
            },
            stillMissing: { !PermissionProbe().snapshot().canUseAX },
            stillMissingHint: Self.openSettingsThenRelaunchHint
        )
    }

    @objc private func requestInputMonitoring() {
        request(
            kind: .inputMonitoring,
            logLabel: "Input Monitoring",
            perform: {
                let result = PermissionRequester.shared.requestInputMonitoring()
                PermissionCoordinator.shared.noteListenRequestResult(
                    preflightGranted: result.preflightGranted
                )
            },
            stillMissing: { !PermissionProbe().snapshot().canListenTap },
            stillMissingHint: Self.openSettingsThenRelaunchHint
        )
    }

    @objc private func requestPostEvent() {
        request(
            kind: .postEvent,
            logLabel: "Post Events",
            perform: { _ = PermissionRequester.shared.requestPostEvent() },
            stillMissing: { !PermissionProbe().snapshot().canPostEvents },
            stillMissingHint: "Still missing — click Request again; Post Events has no dedicated Settings list."
        )
    }

    @objc private func relaunchApp() {
        DevTypeLog.app.info("[App] relaunch from Permission Recovery")
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                PermissionCoordinator.shared.cancelPendingWork()
                NSApp.terminate(nil)
            }
        }
    }

    /// In-app Test Expansion — real inject into a controlled NSTextView lab (not Notes).
    @objc private func runTestExpansion() {
        TestExpansionLab.run(from: view.window)
    }
}
