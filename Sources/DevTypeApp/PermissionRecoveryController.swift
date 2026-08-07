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
    private var statusScrollView: NSScrollView?
    private var tabControl: NSSegmentedControl?
    private let diagnostics = PermissionDiagnosticsController()
    /// Menu-bar "Diagnostics…" asks for the evidence tab before the view exists.
    private var pendingTab: Tab?

    private var cdHash: String?
    private var lastLoggedAccessibilityReset: Bool?
    private var lastLoggedIdentityChanged: Bool?

    // §6.1: 1,028 lines with zero `loc.s` calls — one of the two screens a
    // Korean or Japanese user hits *before* the app works at all.
    private let loc = LocalizationManager.shared

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

        // Header + tab switcher stay pinned at the top; only the Status pane
        // scrolls. The Diagnostics pane owns the rest of the window so its log
        // view grows with the window instead of sitting in a fixed-height box.
        let headerView = DevTypeTheme.makeBrandHeader(
            title: loc.s("recovery.title"),
            subtitle: loc.s("recovery.subtitle"),
            logoSize: 40
        )

        let tabs = NSSegmentedControl(
            labels: [loc.s("recovery.tab.status"), loc.s("recovery.tab.diagnostics")],
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabChanged)
        )
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.selectedSegment = Tab.status.rawValue
        tabs.segmentDistribution = .fillEqually
        tabs.setAccessibilityLabel(loc.s("recovery.title"))
        tabControl = tabs

        let paneContainer = NSView()
        paneContainer.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        statusScrollView = scrollView

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        buildStatusPane()
        document.addSubview(statusPane)

        addChild(diagnostics)
        let diagnosticsPane = diagnostics.view
        diagnosticsPane.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsPane.isHidden = true

        mainView.addSubview(headerView)
        mainView.addSubview(tabs)
        mainView.addSubview(paneContainer)
        paneContainer.addSubview(scrollView)
        paneContainer.addSubview(diagnosticsPane)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: mainView.topAnchor, constant: 46),
            headerView.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 22),
            headerView.trailingAnchor.constraint(lessThanOrEqualTo: mainView.trailingAnchor, constant: -22),

            tabs.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 14),
            tabs.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 22),
            tabs.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -22),

            paneContainer.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 14),
            paneContainer.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),

            statusPane.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            statusPane.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            statusPane.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            statusPane.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -22),

            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            diagnosticsPane.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            diagnosticsPane.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor, constant: 22),
            diagnosticsPane.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor, constant: -22),
            diagnosticsPane.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor, constant: -16)
        ])
        if let pendingTab {
            self.pendingTab = nil
            tabs.selectedSegment = pendingTab.rawValue
            applyTab(pendingTab)
        }
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
            title: loc.s("recovery.cap.accessibility"),
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
            title: loc.s("recovery.cap.inputMonitoring"),
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
            title: loc.s("recovery.cap.postEvents"),
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
            title: loc.s("recovery.relaunch"),
            symbol: "arrow.clockwise",
            style: .primary,
            target: self,
            action: #selector(relaunchApp)
        )
        relaunchButton = relaunchBtn
        let refreshBtn = CapsuleButton(
            title: loc.s("recovery.recheck"),
            symbol: "arrow.triangle.2.circlepath",
            style: .secondary,
            target: self,
            action: #selector(refreshPermissions)
        )
        let testExpandBtn = CapsuleButton(
            title: loc.s("recovery.testExpansion"),
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
            title: loc.s("recovery.more"),
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
        // Spotlight-backed dual-install detection resolves off-main; re-render when it lands.
        ProcessIdentity.shared.refreshDevelopmentBundlePresenceAsync { [weak self] _ in
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
        applyTab(Tab(rawValue: sender.selectedSegment) ?? .status)
    }

    private func applyTab(_ tab: Tab) {
        let showDiagnostics = tab == .diagnostics
        statusScrollView?.isHidden = showDiagnostics
        diagnostics.view.isHidden = !showDiagnostics
        if showDiagnostics {
            DevTypeLog.permission.info("[Permission] UI Recovery → Diagnostics tab")
            diagnostics.didBecomeVisible()
        }
    }

    /// Deep link for the menu-bar "Diagnostics…" item: open straight on the
    /// evidence tab, regardless of which tab was showing last.
    func showDiagnostics() {
        guard isViewLoaded else {
            pendingTab = .diagnostics
            return
        }
        tabControl?.selectedSegment = Tab.diagnostics.rawValue
        applyTab(.diagnostics)
    }

    @objc private func toggleExtendedGuidance() {
        let showing = !extendedGuidanceLabel.isHidden
        extendedGuidanceLabel.isHidden = showing
        extendedGuidanceToggle?.title = showing ? loc.s("recovery.more") : loc.s("recovery.less")
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
            title: loc.s("recovery.request"),
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
        // §5.1: the capability row is one meaningful unit — name it so VoiceOver
        // announces "Accessibility, granted" rather than three loose labels.
        container.setAccessibilityLabel(title)
        statusLabel.setAccessibilityLabel(title)
        openButton.setAccessibilityLabel("\(openTitle) — \(title)")
        requestButton.setAccessibilityLabel("\(loc.s("recovery.request")) — \(title)")

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
        // Include on-disk `.build/DevType.app` even when that copy is not running. Read from the
        // async cache — resolving it inline would spawn `mdfind` on the main thread on every
        // re-check, and this window re-checks on activation, on every Request, and on every
        // post-request settle.
        let buildPresent = identity.cachedDevelopmentBundlePresent
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
                relaunchButton.title = loc.s("recovery.relaunchRecommended")
                relaunchButton.buttonStyle = .primary
                relaunchButton.setSymbol("arrow.clockwise")
            } else {
                relaunchButton.title = loc.s("recovery.relaunch")
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

        // §6.1: every one of these was an interpolated English literal.
        let tapWord = tapRunning ? loc.s("recovery.tap.running") : loc.s("recovery.tap.notRunning")
        if snapshot.canListenTap && tapRunning && snapshot.isFullyCapable {
            summaryLabel.stringValue = loc.s("recovery.summary.allGood", engineLabel)
            summaryLabel.textColor = DevTypeTheme.statusGreen
            guidanceLabel.stringValue = loc.s("recovery.guidance.allGood", bundleID)
            guidanceLabel.textColor = DevTypeTheme.statusGreen
        } else if snapshot.canListenTap && tapRunning && snapshot.isDegradedInject {
            summaryLabel.stringValue = loc.s("recovery.summary.degraded", engineLabel)
            summaryLabel.textColor = DevTypeTheme.statusOrange
            guidanceLabel.stringValue = PermissionCopy.degradedInjectTooltip(snapshot: snapshot)
            guidanceLabel.textColor = DevTypeTheme.statusOrange
        } else if snapshot.canListenTap && snapshot.canUseAX && !tapRunning {
            // Distinct from "permissions denied": Listen+AX OK but tapCreate failed.
            summaryLabel.stringValue = loc.s("recovery.summary.tapCreateFailed", engineLabel)
            summaryLabel.textColor = DevTypeTheme.statusOrange
            guidanceLabel.stringValue = PermissionCopy.tapCreateFailedDespiteListenGuidance
            guidanceLabel.textColor = DevTypeTheme.statusOrange
        } else {
            var summary = loc.s(
                "recovery.summary.missing",
                snapshot.missingCapabilitiesSummary,
                tapWord,
                engineLabel
            )
            if snapshot.blocksDefaultEventTap {
                summary += loc.s("recovery.suffix.listenAXRequired")
            }
            if accessibilityReset {
                summary += loc.s("recovery.suffix.axReset")
            }
            if identityChanged {
                summary += loc.s("recovery.suffix.identityChanged")
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
                guidanceLabel.stringValue = loc.s("recovery.guidance.finishGranting")
                guidanceLabel.textColor = DevTypeTheme.textSecondary
            }
        }

        if !siblingPaths.isEmpty {
            guidanceLabel.stringValue += "\n" + loc.s(
                "recovery.guidance.siblings",
                ProcessIdentity.preferredInstalledAppPath
            )
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
                guidanceLabel.stringValue = loc.s("recovery.inject.postedUnverified")
            case .refused(let reason):
                summaryLabel.textColor = DevTypeTheme.accentBright
                if snapshot.canListenTap && tapRunning {
                    summaryLabel.stringValue = loc.s("recovery.inject.refusedSummary", engineLabel)
                    guidanceLabel.stringValue = Self.guidanceForInjectRefuse(
                        reason: reason,
                        canUseAX: snapshot.canUseAX
                    )
                    guidanceLabel.textColor = DevTypeTheme.statusOrange
                }
            case .failedSilent:
                summaryLabel.stringValue = loc.s(
                    "recovery.inject.failedSummary",
                    tapWord,
                    engineLabel
                )
                summaryLabel.textColor = DevTypeTheme.accentBright
                guidanceLabel.stringValue = loc.s("recovery.inject.failedGuidance")
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
            extendedGuidanceToggle?.title = loc.s("recovery.more")
            extendedGuidanceToggle?.setSymbol("chevron.down")
        }
    }

    /// One-line inject/tap health for the Diagnostics tab.
    private func injectHealthSummary(snapshot: PermissionSnapshot, tapRunning: Bool) -> String {
        var parts: [String] = []
        if !tapRunning && snapshot.canListenTap {
            parts.append(loc.s("recovery.health.tapExpected"))
        }
        if snapshot.isDegradedInject {
            parts.append(PermissionCopy.degradedInjectTooltip(snapshot: snapshot))
        }
        if snapshot.canListenTap && snapshot.canUseAX && snapshot.canPostEvents && tapRunning {
            parts.append(loc.s("recovery.health.full"))
        } else if snapshot.canListenTap && snapshot.canUseAX && !snapshot.canPostEvents {
            parts.append(loc.s("recovery.health.axOnly"))
        } else if snapshot.canListenTap && !snapshot.canUseAX {
            parts.append(loc.s("recovery.health.refused"))
        }
        var health = parts.isEmpty ? loc.s("recovery.health.idle") : parts.joined(separator: " ")
        if let outcome = PermissionCoordinator.shared.lastRecordedInjectOutcome {
            switch outcome {
            case .succeeded:
                health += loc.s("recovery.health.last.succeeded")
            case .postedUnverified:
                health += loc.s("recovery.health.last.posted")
            case .refused(let reason):
                health += loc.s("recovery.health.last.refused", reason)
            case .degradedAXOnly:
                health += loc.s("recovery.health.last.degraded")
            case .failedSilent:
                health += loc.s("recovery.health.last.failed")
            }
        }
        return health
    }

    /// Honest Recovery copy: do not blame Accessibility when AX is already granted.
    ///
    /// The `reason` strings come from `PermissionCopy` / the inject pipeline and
    /// stay English (they are engine diagnostics, matched on here); the guidance
    /// wrapped around them is localized.
    private static func guidanceForInjectRefuse(reason: String, canUseAX: Bool) -> String {
        let loc = LocalizationManager.shared
        if !canUseAX
            || reason.contains("Accessibility unavailable")
            || reason.contains("AXIsProcessTrusted false") {
            return loc.s("recovery.refuse.ax", reason)
        }
        if reason.contains("Secure Input") {
            return loc.s("recovery.refuse.secureInput")
        }
        if reason.localizedCaseInsensitiveContains("secure text field") {
            return loc.s("recovery.refuse.secureField")
        }
        if reason.contains("IME") {
            return loc.s("recovery.refuse.ime")
        }
        if reason.contains("timed out")
            || reason.contains("No focused")
            || reason.contains("focus query failed") {
            return loc.s("recovery.refuse.focus")
        }
        return loc.s("recovery.refuse.generic", reason)
    }

    private func updateStatusLabel(_ label: NSTextField, isGranted: Bool) {
        // §5.2: the ✓ / ⚠️ glyph is the non-colour channel; the AX value below
        // makes the state audible.
        label.stringValue = isGranted
            ? loc.s("recovery.status.granted")
            : loc.s("recovery.status.missing")
        label.textColor = isGranted ? DevTypeTheme.statusGreen : DevTypeTheme.accentBright
        label.font = DevTypeTheme.font(11, .bold)
        label.setAccessibilityValue(label.stringValue)
    }

    private func styleRequestButton(_ button: CapsuleButton?, isGranted: Bool) {
        guard let button else { return }
        if isGranted {
            button.title = loc.s("recovery.granted")
            button.isEnabled = false
            button.buttonStyle = .secondary
            button.setSymbol("checkmark")
        } else {
            button.title = loc.s("recovery.request")
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

    private static var openSettingsThenRelaunchHint: String {
        LocalizationManager.shared.s("recovery.stillMissing")
    }

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
            stillMissingHint: loc.s("recovery.stillMissingPost")
        )
    }

    @objc private func relaunchApp() {
        DevTypeLog.app.info("[App] relaunch from Permission Recovery")
        // A failed spawn must not become an unrequested quit — say so and stay running.
        guard AppRelauncher.relaunch() else {
            guidanceLabel.stringValue = loc.s("recovery.relaunchFailed")
            guidanceLabel.textColor = DevTypeTheme.redBright
            return
        }
    }

    /// In-app Test Expansion — real inject into a controlled NSTextView lab (not Notes).
    @objc private func runTestExpansion() {
        TestExpansionLab.run(from: view.window)
    }
}
