import AppKit
import ExpanderEngine

// MARK: - Preferences content

/// The Preferences tab host: sidebar, pane header, and one lazily built pane per tab.
///
/// Each tab's controls, actions and reloads belong to its own controller under `Preferences/`.
/// This controller only routes selection, reloads, the hotkey manager and the language-rebuild
/// snapshot between them.
final class PreferencesViewController: NSViewController {

    private let loc = LocalizationManager.shared
    private let store = SnippetStore.shared
    private weak var hotkeyManager: HotkeyManager?

    private var navRows: [SidebarNavRow] = []
    private var selectedTab: PreferencesTab = .home
    private var panes: [PreferencesTab: NSView] = [:]
    /// Host every pane is pinned into. Retained so panes can be built on first selection
    /// rather than all at once: General, Snippets, Hotkeys, Voice (a 639-line builder), AI,
    /// Advanced and the whole `HomeViewController` used to be constructed, constrained and
    /// left resident before the window appeared, with six of seven merely `isHidden`. Most
    /// users open one pane.
    private weak var paneHostView: NSView?
    private var paneTitleLabel: NSTextField?
    private var paneSubtitleLabel: NSTextField?
    private var paneIconBadge: IconBadgeView?
    private var tabsShownAtLeastOnce: Set<PreferencesTab> = [.home]
    /// Glanceable engine state pinned to the bottom of the sidebar.
    private var engineStatusPill: PillBadgeView?
    private var homeViewController: HomeViewController?

    // Tab controllers are created with the host, as their controls always were; each one's view
    // is built only when its tab is first selected.
    private let general = GeneralPreferencesViewController()
    private let snippets = SnippetsPreferencesViewController()
    private let hotkeys = HotkeysPreferencesViewController()
    private let voice: VoicePreferencesViewController
    private let ai = AIPreferencesViewController()
    private let advanced = AdvancedPreferencesViewController()
    /// Cleared immediately after first view load so an unsaved credential draft is not retained
    /// in a second long-lived String after it has been restored to the secure field.
    private var restorationState: PreferencesLocalizationState?

    init(
        hotkeyManager: HotkeyManager?,
        restorationState: PreferencesLocalizationState? = nil,
        onLocalizationBlockingOperationDidEnd: (() -> Void)? = nil
    ) {
        self.restorationState = restorationState
        voice = VoicePreferencesViewController(
            onLocalizationBlockingOperationDidEnd: onLocalizationBlockingOperationDidEnd
        )
        super.init(nibName: nil, bundle: nil)
        refreshHotkeyManager(hotkeyManager)
        // Resetting the library replaces what the Snippets tab shows.
        advanced.onLibraryReset = { [weak self] in
            self?.snippets.reload()
        }
    }

    /// Re-point at the live manager. Called by `PreferencesWindowController.show`
    /// on every presentation so a window that is already open never keeps acting
    /// on the manager (or absence of one) it was created with.
    func refreshHotkeyManager(_ manager: HotkeyManager?) {
        hotkeyManager = manager
        hotkeys.hotkeyManager = manager
        voice.hotkeyManager = manager
        ai.hotkeyManager = manager
        homeViewController?.refreshHotkeyManager(manager)
    }

    var blocksLocalizationReplacement: Bool {
        voice.blocksLocalizationReplacement
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        voice.retireLiveOperations()
    }

    /// The window controller gates replacement until every view-owned operation has retired.
    /// Keep the assertion here so future replacement call sites cannot silently bypass that gate;
    /// normal window teardown still invalidates through `viewWillDisappear`.
    func prepareForLocalizationReplacement() {
        precondition(
            !blocksLocalizationReplacement,
            "Preferences localization replacement cannot detach live async operations"
        )
    }

    // MARK: Layout

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        // MARK: Sidebar — brand, nav rows, engine status.
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.layer?.backgroundColor = DevTypeTheme.cardBackground.cgColor

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let brand = DevTypeTheme.makeBrandHeader(
            title: "DevType",
            subtitle: "v\(version)",
            logoSize: 32
        )

        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 3
        navStack.translatesAutoresizingMaskIntoConstraints = false
        navStack.setAccessibilityRole(NSAccessibility.Role.tabGroup)
        navStack.setAccessibilityLabel(loc.s("ax.preferences.tabs"))
        for (index, tab) in PreferencesTab.visibleCases.enumerated() {
            let row = SidebarNavRow(tab: tab, index: index, target: self, action: #selector(navRowTapped(_:)))
            row.isSelectedRow = tab == selectedTab
            navRows.append(row)
            navStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: navStack.widthAnchor).isActive = true
        }

        let sidebarHairline = DevTypeTheme.makeHairline()
        let engineCaption = DevTypeTheme.makeLabel(
            loc.s("prefs.advanced.engine"),
            font: DevTypeTheme.font(10, .semibold),
            color: DevTypeTheme.textTertiary
        )
        engineCaption.translatesAutoresizingMaskIntoConstraints = false
        let statusPill = PillBadgeView(
            text: loc.s("status.active"),
            tint: DevTypeTheme.statusGreen,
            showsDot: true
        )
        engineStatusPill = statusPill

        sidebar.addSubview(brand)
        sidebar.addSubview(navStack)
        sidebar.addSubview(sidebarHairline)
        sidebar.addSubview(engineCaption)
        sidebar.addSubview(statusPill)

        // MARK: Content — section title + swappable pane host.
        // Vertical rule — `makeHairline()` carries a fixed 1pt *height*, so a
        // plain layer-backed view is used for the vertical variant instead.
        let separator = NSView()
        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.layer?.backgroundColor = DevTypeTheme.hairline.cgColor
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let paneIcon = IconBadgeView(
            symbol: selectedTab.symbol,
            tint: DevTypeTheme.accent,
            size: 34,
            pointSize: 15
        )
        paneIconBadge = paneIcon

        let paneTitle = DevTypeTheme.makeLabel(
            selectedTab.title,
            font: DevTypeTheme.font(21, .bold),
            color: DevTypeTheme.textPrimary
        )
        paneTitleLabel = paneTitle

        let paneSubtitle = DevTypeTheme.makeLabel(
            selectedTab.subtitle,
            font: DevTypeTheme.font(11.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        paneSubtitleLabel = paneSubtitle

        let paneHeadingText = NSStackView(views: [paneTitle, paneSubtitle])
        paneHeadingText.orientation = .vertical
        paneHeadingText.alignment = .leading
        paneHeadingText.spacing = 2
        paneHeadingText.translatesAutoresizingMaskIntoConstraints = false

        let paneHeader = NSStackView(views: [paneIcon, paneHeadingText])
        paneHeader.orientation = .horizontal
        paneHeader.alignment = .centerY
        paneHeader.spacing = 11
        paneHeader.translatesAutoresizingMaskIntoConstraints = false
        paneHeadingText.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let paneHost = NSView()
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(paneHeader)
        content.addSubview(paneHost)

        paneHostView = paneHost
        // Only the pane about to be shown. The rest are built by `ensurePane(_:)` the first
        // time they are selected.
        _ = ensurePane(selectedTab)

        root.addSubview(sidebar)
        root.addSubview(separator)
        root.addSubview(content)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 196),

            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            brand.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -12),

            navStack.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 20),
            navStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            navStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            sidebarHairline.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            sidebarHairline.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            sidebarHairline.bottomAnchor.constraint(equalTo: engineCaption.topAnchor, constant: -10),

            engineCaption.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            engineCaption.bottomAnchor.constraint(equalTo: statusPill.topAnchor, constant: -6),

            statusPill.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            statusPill.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),

            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            paneHeader.topAnchor.constraint(equalTo: content.topAnchor, constant: 42),
            paneHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            paneHeader.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),

            paneHost.topAnchor.constraint(equalTo: paneHeader.bottomAnchor, constant: 16),
            paneHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            paneHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paneHost.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadAll()
        if let restorationState {
            self.restorationState = nil
            restoreLocalizationState(restorationState)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadAll()
    }

    func select(_ tab: PreferencesTab) {
        let resolved = PreferencesTab.visibleCases.contains(tab) ? tab : .general
        applyTabSelection(resolved, animated: false)
    }

    @objc private func navRowTapped(_ sender: SidebarNavRow) {
        applyTabSelection(sender.tab, animated: true)
    }

    /// Returns the pane for `tab`, building and installing it on first use.
    @discardableResult
    private func ensurePane(_ tab: PreferencesTab) -> NSView? {
        if let existing = panes[tab] { return existing }
        guard let host = paneHostView else { return nil }
        let pane = makeScrollingPane(for: tab)
        pane.isHidden = tab != selectedTab
        host.addSubview(pane)
        panes[tab] = pane
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: host.topAnchor),
            pane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        // A pane built after `reloadAll()` has already run would otherwise show whatever its
        // builder happened to set rather than current preferences. Populate it now — the
        // reloads are idempotent, and the Voice and AI `reload()`s already guard on their
        // view being loaded, which it is by this point.
        reload(tab)
        return pane
    }

    /// Repopulates one pane's controls from current preferences.
    private func reload(_ tab: PreferencesTab) {
        if tab == .home {
            homeViewController?.refresh()
        } else {
            paneController(for: tab)?.reload()
        }
    }

    /// The controller that owns `tab`'s pane. Home is the one tab without one: it embeds the
    /// standalone `HomeViewController`.
    private func paneController(for tab: PreferencesTab) -> PreferencesPaneViewController? {
        switch tab {
        case .home: return nil
        case .general: return general
        case .snippets: return snippets
        case .hotkeys: return hotkeys
        case .voice: return voice
        case .ai: return ai
        case .advanced: return advanced
        }
    }

    private func applyTabSelection(_ tab: PreferencesTab, animated: Bool) {
        let isFirstPresentation = tabsShownAtLeastOnce.insert(tab).inserted
        selectedTab = tab
        // Must precede the reload/refresh calls below, which read the pane's controls.
        ensurePane(tab)
        for row in navRows {
            let selected = row.tab == tab
            row.isSelectedRow = selected
            row.setAccessibilityValue(selected)
        }
        paneTitleLabel?.stringValue = tab.title
        paneSubtitleLabel?.stringValue = tab.subtitle
        paneIconBadge?.setSymbol(tab.symbol, tint: DevTypeTheme.accent)
        for (candidate, pane) in panes {
            pane.isHidden = candidate != tab
        }
        // Gentle cross-fade on the incoming pane; suppressed under Reduce Motion.
        if animated, !DevTypeAccessibility.reduceMotion, let pane = panes[tab] {
            pane.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                pane.animator().alphaValue = 1
            }
        } else {
            panes[tab]?.alphaValue = 1
        }
        paneController(for: tab)?.didSelect()
        // Reloading controls (especially popups) can make AppKit reveal their
        // row. Reset after all pane work so first presentation still starts at
        // the page header rather than at the last selected action.
        if isFirstPresentation {
            resetScrollPosition(for: tab)
        }
    }

    /// Auto Layout sizes hidden scroll documents lazily. Their clip view can
    /// therefore inherit a non-zero origin before first display, which made long
    /// panes open in the middle. Reset once, after revealing and laying out; later
    /// visits preserve the user's own scroll position.
    private func resetScrollPosition(for tab: PreferencesTab) {
        guard let scroll = panes[tab] as? NSScrollView else { return }
        let scrollToTop = { [weak scroll] in
            guard let scroll else { return }
            scroll.documentView?.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        DispatchQueue.main.async(execute: scrollToTop)
    }

    /// Sidebar footer: one glance answers "is it on?" without opening the menu.
    private func refreshEngineStatus() {
        let snapshot = PermissionProbe().snapshot()
        let display = EngineDisplayStatus.resolve(
            snapshot: snapshot,
            isTapRunning: EventTapEngine.shared.isTapRunning,
            isEnabled: EventTapEngine.shared.isEnabled,
            isSecureInputActive: EventTapEngine.shared.isSecureInputActive,
            hasAttemptedTapStart: EventTapEngine.shared.hasAttemptedTapStart
        )
        let text: String
        let tint: NSColor
        switch display {
        case .active:
            text = loc.s("status.active")
            tint = DevTypeTheme.statusGreen
        case .secure:
            text = loc.s("status.secure")
            tint = DevTypeTheme.statusBlue
        case .paused:
            text = loc.s("status.paused")
            tint = DevTypeTheme.statusGray
        case .needsPermissions:
            text = loc.s("status.needsPermissions")
            tint = DevTypeTheme.accent
        case .tapFailed:
            text = loc.s("status.tapFailed")
            tint = DevTypeTheme.accent
        }
        engineStatusPill?.update(text: text, tint: tint)
    }

    /// Re-pulls every value from its source of truth.
    func reloadAll() {
        guard isViewLoaded else { return }
        homeViewController?.refresh()
        for tab in PreferencesTab.allCases {
            paneController(for: tab)?.reload()
        }
        refreshEngineStatus()
    }

    /// Snapshot only state that is not already committed to a canonical preference store.
    func localizationState() -> PreferencesLocalizationState {
        var scrollOrigins: [PreferencesTab: NSPoint] = [:]
        for (tab, pane) in panes {
            guard let scroll = pane as? NSScrollView else { continue }
            scrollOrigins[tab] = scroll.contentView.bounds.origin
        }
        return PreferencesLocalizationState(
            selectedTab: selectedTab,
            macroArgument: hotkeys.macroArgumentField.transientValue,
            aiAllowlistBundleID: ai.aiAllowlistField.transientValue,
            voiceDictionarySpoken: voice.voiceDictSpokenField.transientValue,
            voiceDictionaryReplacement: voice.voiceDictReplacementField.transientValue,
            voiceTriggerPhrase: voice.voiceTriggerPhraseField.transientValue,
            geminiAPIKey: voice.geminiAPIKeyField.transientValue,
            localLLMEndpoint: voice.localLLMEndpointField.transientValue,
            localLLMModel: voice.localLLMModelField.transientValue,
            scrollOrigins: scrollOrigins
        )
    }

    private func restoreLocalizationState(_ state: PreferencesLocalizationState) {
        hotkeys.macroArgumentField.stringValue = state.macroArgument
        ai.aiAllowlistField.stringValue = state.aiAllowlistBundleID
        voice.voiceDictSpokenField.stringValue = state.voiceDictionarySpoken
        voice.voiceDictReplacementField.stringValue = state.voiceDictionaryReplacement
        voice.voiceTriggerPhraseField.stringValue = state.voiceTriggerPhrase
        voice.geminiAPIKeyField.stringValue = state.geminiAPIKey
        voice.localLLMEndpointField.stringValue = state.localLLMEndpoint
        voice.localLLMModelField.stringValue = state.localLLMModel
        select(state.selectedTab)

        let scrollOrigins = state.scrollOrigins
        // Rebuild every pane the previous controller had. Panes are built on first selection, so
        // a pane carrying a scroll origin is one the user had opened — recreating it is what
        // makes their position survive the language change rather than silently resetting.
        for tab in scrollOrigins.keys { ensurePane(tab) }
        let restoreScrollPositions = { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            for (tab, origin) in scrollOrigins {
                guard let scroll = self.panes[tab] as? NSScrollView else { continue }
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        restoreScrollPositions()
        DispatchQueue.main.async(execute: restoreScrollPositions)
    }

    /// Re-read the secrets preference into its switch, whether or not its pane is built.
    func refreshSecretsCard() {
        snippets.refreshSecretsCard()
    }

    func refreshPermissionState() {
        guard isViewLoaded else { return }
        voice.reload()
        refreshEngineStatus()
    }

    func refreshMaintenanceState() {
        guard isViewLoaded else { return }
        advanced.reload()
    }

    // MARK: Pane construction

    private func makeScrollingPane(for tab: PreferencesTab) -> NSView {
        guard let controller = paneController(for: tab) else {
            let homeVC = HomeViewController(store: store, hotkeyManager: hotkeyManager)
            homeViewController = homeVC
            let homeView = homeVC.view
            // The Home controller owns an NSScrollView, but its view is embedded in this
            // constraint-managed host just like every other Preferences pane.
            homeView.translatesAutoresizingMaskIntoConstraints = false
            return homeView
        }
        // Each tab controller's view is its own scrolling document.
        addChild(controller)
        return controller.view
    }
}
