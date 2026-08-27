import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

// MARK: - §4.1 — a real Preferences window
//
// Configuration used to be scattered across `AppDelegate.buildMenu()`: Open at
// Login (:332), Language (:338-349), Mute Frontmost (:361), Muted Apps (:362) —
// and ⌘, was bound to "Manage Snippets" (:313) rather than settings. This window
// collects them, plus the two features that had *no* UI at all:
//
//   • §4.2 the inline-search shortcut (was hardcoded ⌘/ with no picker)
//   • §4.3 hotkey macros (were readable only by hand-editing UserDefaults)
//
// and the two that were alert-shaped:
//
//   • §4.8 the muted-app list (was one alert button per app, decoded by index
//     arithmetic — broken past ~3 apps)
//   • §4.5 statistics (were collected and never shown)

/// Sections, in sidebar order.
enum PreferencesTab: Int, CaseIterable {
    case general
    case snippets
    case hotkeys
    case voice
    case ai
    case advanced

    var title: String {
        switch self {
        case .general: return LocalizationManager.shared.s("prefs.tab.general")
        case .snippets: return LocalizationManager.shared.s("prefs.tab.snippets")
        case .hotkeys: return LocalizationManager.shared.s("prefs.tab.hotkeys")
        case .voice: return LocalizationManager.shared.s("prefs.tab.voice")
        case .ai: return LocalizationManager.shared.s("prefs.tab.ai")
        case .advanced: return LocalizationManager.shared.s("prefs.tab.advanced")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .snippets: return "square.stack.3d.up"
        case .hotkeys: return "keyboard"
        case .voice: return "waveform.and.mic"
        case .ai: return "sparkles"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    /// AI requires macOS 26+; hide the tab on older systems.
    static var visibleCases: [PreferencesTab] {
        if #available(macOS 26.0, *) {
            return Array(allCases)
        }
        return allCases.filter { $0 != .ai }
    }
}

// MARK: - Window controller

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private var preferences: PreferencesViewController?

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Opens (or raises) Preferences, optionally jumping to a section.
    ///
    /// `hotkeyManager` is refreshed on *every* call, not only when the window is
    /// first created: the controller outlives individual callers, and pinning the
    /// manager from first show left a window opened via a nil-manager path acting
    /// on nil forever — macro edits then went to defaults instead of the live
    /// registration. Nil-safe: callers without a manager keep today's behaviour.
    func show(tab: PreferencesTab? = nil, hotkeyManager: HotkeyManager?) {
        if window == nil {
            let controller = PreferencesViewController(hotkeyManager: hotkeyManager)
            preferences = controller
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 740, height: 620))
            newWindow.minSize = NSSize(width: 680, height: 520)
            DevTypeTheme.styleWindow(newWindow, title: LocalizationManager.shared.s("window.preferences"))
            newWindow.center()
            newWindow.isReleasedWhenClosed = false
            self.window = newWindow
        }
        preferences?.refreshHotkeyManager(hotkeyManager)
        if let tab { preferences?.select(tab) }
        preferences?.reloadAll()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-read the secrets preference into its switch.
    ///
    /// The same setting is reachable from the Copy Secret menu, and a window showing the opposite
    /// of what is in force is worse than no window — the user would toggle it back and change
    /// nothing, twice.
    func refreshSecretsCard() {
        preferences?.refreshSecretsCard()
    }
}

// MARK: - Flipped scroll document

private final class PrefsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Sidebar nav row

/// System Settings–style sidebar row: icon + label, rounded selection, hover
/// wash, and a ⌘1…⌘N key equivalent so the window is keyboard-navigable.
private final class SidebarNavRow: NSButton {
    let tab: PreferencesTab
    private let symbolName: String
    var isSelectedRow = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(tab: PreferencesTab, index: Int, target: AnyObject?, action: Selector?) {
        self.tab = tab
        self.symbolName = tab.symbol
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = tab.title
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        keyEquivalent = String(index + 1)
        keyEquivalentModifierMask = [.command]
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityRole(NSAccessibility.Role.button)
        setAccessibilityLabel(tab.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        if isSelectedRow {
            DevTypeTheme.accent.withAlphaComponent(hovering ? 0.30 : 0.24).setFill()
            path.fill()
            DevTypeTheme.accent.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            DevTypeTheme.contrastOverlay(0.07).setFill()
            path.fill()
        }

        let tint: NSColor = isSelectedRow ? DevTypeTheme.accentBright : DevTypeTheme.textSecondary
        let icon = DevTypeTheme.tintedSymbol(symbolName, size: 12, weight: .semibold, color: tint)
        let iconY = (bounds.height - (icon?.size.height ?? 0)) / 2
        icon?.draw(
            in: NSRect(x: 10, y: iconY, width: icon?.size.width ?? 0, height: icon?.size.height ?? 0),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )

        let attributes: [NSAttributedString.Key: Any] = [
            .font: DevTypeTheme.font(12.5, isSelectedRow ? .semibold : .medium),
            .foregroundColor: isSelectedRow ? DevTypeTheme.textPrimary : DevTypeTheme.textSecondary
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: 34, y: (bounds.height - textSize.height) / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - Preferences content

final class PreferencesViewController: NSViewController,
                                       NSTableViewDataSource,
                                       NSTableViewDelegate {

    private let loc = LocalizationManager.shared
    private let store = SnippetStore.shared
    private weak var hotkeyManager: HotkeyManager?

    private var navRows: [SidebarNavRow] = []
    private var selectedTab: PreferencesTab = .general
    private var panes: [PreferencesTab: NSView] = [:]
    private var paneTitleLabel: NSTextField?
    /// Glanceable engine state pinned to the bottom of the sidebar.
    private var engineStatusPill: PillBadgeView?

    // General
    private let openAtLoginSwitch = NSSwitch()
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mutedTable = NSTableView()
    private let mutedEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    private var mutedApps: [String] = []

    // Snippets
    private lazy var stats = StatsViewController(store: store)
    private let libraryPathLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.mono(10.5),
        color: DevTypeTheme.textTertiary,
        wrapping: true
    )
    private let conflictsLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11),
        color: DevTypeTheme.statusOrange,
        wrapping: true
    )

    // Hotkeys
    private var inlineRecorder: ShortcutRecorderView?
    private let hotkeyWarningLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(10.5, .medium),
        color: DevTypeTheme.statusOrange,
        wrapping: true
    )
    private let macroTable = NSTableView()
    private var macros: [HotkeyMacroAction] = []
    private var macroRecorder: ShortcutRecorderView?
    private let macroKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let macroArgumentField = NSTextField()

    // Advanced
    private let tapThreadSwitch = NSSwitch()
    private let advancedReadout = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.mono(10.5),
        color: DevTypeTheme.textSecondary,
        wrapping: true
    )
    private let maintenanceStatus = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11),
        color: DevTypeTheme.statusGreen,
        wrapping: true
    )

    // AI
    private let aiEnabledSwitch = NSSwitch()
    private let requireBiometrySwitch = NSSwitch()
    private let aiAvailabilityLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11),
        color: DevTypeTheme.textSecondary,
        wrapping: true
    )
    private var aiPaletteRecorder: ShortcutRecorderView?
    private var aiOutputModePopups: [AITransformKind: NSPopUpButton] = [:]
    private let aiAllowlistTable = NSTableView()
    private let aiAllowlistEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    private let aiAllowlistField = NSTextField()
    private var aiAllowlist: [String] = []

    // Voice & Smart Dictation
    private let voiceModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voiceTonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voiceRealTimeTypingSwitch = NSSwitch()
    private let voiceAutoPunctuateSwitch = NSSwitch()
    private let voiceDisfluenciesSwitch = NSSwitch()
    private let voiceSoundFeedbackSwitch = NSSwitch()
    private let voiceHandsFreeSwitch = NSSwitch()
    private var voiceShortcutRecorder: ShortcutRecorderView?
    private let voiceDictionaryTable = NSTableView()
    private let voiceDictionaryEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    private let voiceDictSpokenField = NSTextField()
    private let voiceDictReplacementField = NSTextField()
    private var voiceDictEntries: [(spoken: String, replacement: String)] = []
    private let voiceTriggersTable = NSTableView()
    private let voiceTriggersEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    private let voiceTriggerPhraseField = NSTextField()
    private let voiceTriggerActionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var voiceTriggerEntries: [(phrase: String, action: String)] = []
    private var voiceModelDownloadProgressBars: [VoiceModelType: NSProgressIndicator] = [:]
    private var voiceModelStatusLabels: [VoiceModelType: NSTextField] = [:]
    private var voiceModelActionButtons: [VoiceModelType: CapsuleButton] = [:]
    private var voiceModelDeleteButtons: [VoiceModelType: CapsuleButton] = [:]
    private var voiceModelListenerToken: UUID?
    private var voiceMicPermissionPill: PillBadgeView?

    init(hotkeyManager: HotkeyManager?) {
        self.hotkeyManager = hotkeyManager
        super.init(nibName: nil, bundle: nil)
        setupVoiceModelListener()
    }

    deinit {
        if let token = voiceModelListenerToken {
            VoiceModelManager.shared.removeStatusListener(token)
        }
    }

    private func setupVoiceModelListener() {
        voiceModelListenerToken = VoiceModelManager.shared.addStatusListener { [weak self] type, status in
            DispatchQueue.main.async {
                self?.updateVoiceModelUI(type: type, status: status)
            }
        }
    }

    /// Re-point at the live manager. Called by `PreferencesWindowController.show`
    /// on every presentation so a window that is already open never keeps acting
    /// on the manager (or absence of one) it was created with.
    func refreshHotkeyManager(_ manager: HotkeyManager?) {
        hotkeyManager = manager
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

        let paneTitle = DevTypeTheme.makeLabel(
            selectedTab.title,
            font: DevTypeTheme.font(20, .bold),
            color: DevTypeTheme.textPrimary
        )
        paneTitle.translatesAutoresizingMaskIntoConstraints = false
        paneTitleLabel = paneTitle

        let paneHost = NSView()
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(paneTitle)
        content.addSubview(paneHost)

        for tab in PreferencesTab.visibleCases {
            let pane = makeScrollingPane(for: tab)
            pane.isHidden = tab != selectedTab
            paneHost.addSubview(pane)
            panes[tab] = pane
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: paneHost.topAnchor),
                pane.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
                pane.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor)
            ])
        }

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

            paneTitle.topAnchor.constraint(equalTo: content.topAnchor, constant: 46),
            paneTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            paneTitle.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),

            paneHost.topAnchor.constraint(equalTo: paneTitle.bottomAnchor, constant: 10),
            paneHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            paneHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paneHost.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadAll()
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

    private func applyTabSelection(_ tab: PreferencesTab, animated: Bool) {
        selectedTab = tab
        for row in navRows {
            let selected = row.tab == tab
            row.isSelectedRow = selected
            row.setAccessibilityValue(selected)
        }
        paneTitleLabel?.stringValue = tab.title
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
        if tab == .snippets { stats.refresh() }
        if tab == .advanced { reloadAdvanced() }
        if tab == .ai { reloadAI() }
    }

    /// Sidebar footer: one glance answers "is it on?" without opening the menu.
    private func refreshEngineStatus() {
        let snapshot = PermissionProbe().snapshot()
        let display = EngineDisplayStatus.resolve(
            snapshot: snapshot,
            isTapRunning: EventTapEngine.shared.isTapRunning,
            isEnabled: EventTapEngine.shared.isEnabled,
            isSecureInputActive: EventTapEngine.shared.isSecureInputActive
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
        reloadGeneral()
        reloadSnippets()
        reloadHotkeys()
        reloadVoice()
        reloadAI()
        reloadAdvanced()
        refreshEngineStatus()
    }

    // MARK: Pane construction

    private func makeScrollingPane(for tab: PreferencesTab) -> NSView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let document = PrefsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        switch tab {
        case .general: buildGeneral(into: stack)
        case .snippets: buildSnippets(into: stack)
        case .hotkeys: buildHotkeys(into: stack)
        case .voice: buildVoice(into: stack)
        case .ai: buildAI(into: stack)
        case .advanced: buildAdvanced(into: stack)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    // MARK: General (§4.1 / §4.8)

    private func buildGeneral(into stack: NSStackView) {
        // Startup
        let startupCard = makeCard(title: loc.s("prefs.general.startup"), symbol: "sunrise")
        let loginRow = makeToggleRow(
            title: loc.s("menu.openAtLogin"),
            toggle: openAtLoginSwitch,
            action: #selector(openAtLoginChanged)
        )
        let appearanceNote = DevTypeTheme.makeLabel(
            loc.s("prefs.general.appearanceNote"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        appearanceNote.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(startupCard, views: [loginRow, appearanceNote])

        // Language (§4.1: was a menu submenu)
        let languageCard = makeCard(title: loc.s("prefs.general.language"), symbol: "globe")
        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        languagePopup.removeAllItems()
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.endonym)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.setAccessibilityLabel(loc.s("prefs.general.language"))
        let languageNote = DevTypeTheme.makeLabel(
            loc.s("prefs.general.languageNote"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        languageNote.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(languageCard, views: [languagePopup, languageNote])

        // Muted apps (§4.8: replaces the index-arithmetic alert)
        let mutedCard = makeCard(title: loc.s("prefs.general.mutedApps"), symbol: "speaker.slash.fill")
        let mutedHint = DevTypeTheme.makeLabel(
            loc.s("prefs.general.mutedApps.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        mutedHint.translatesAutoresizingMaskIntoConstraints = false

        mutedTable.headerView = nil
        mutedTable.rowHeight = 22
        mutedTable.backgroundColor = .clear
        mutedTable.gridStyleMask = []
        mutedTable.usesAlternatingRowBackgroundColors = false
        mutedTable.allowsMultipleSelection = true
        mutedTable.dataSource = self
        mutedTable.delegate = self
        mutedTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("muted")))
        mutedTable.setAccessibilityLabel(loc.s("prefs.general.mutedApps"))

        let mutedScroll = NSScrollView()
        mutedScroll.translatesAutoresizingMaskIntoConstraints = false
        mutedScroll.hasVerticalScroller = true
        mutedScroll.borderType = .noBorder
        mutedScroll.drawsBackground = false
        mutedScroll.documentView = mutedTable
        mutedScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        mutedEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let mutedButtons = NSStackView(views: [
            CapsuleButton(
                title: loc.s("prefs.general.muteFrontmost"),
                symbol: "speaker.slash",
                style: .secondary,
                target: self,
                action: #selector(muteFrontmost)
            ),
            CapsuleButton(
                title: loc.s("common.remove"),
                symbol: "trash",
                style: .destructive,
                target: self,
                action: #selector(unmuteSelected)
            )
        ])
        mutedButtons.orientation = .horizontal
        mutedButtons.spacing = 8
        mutedButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(mutedCard, views: [mutedHint, mutedScroll, mutedEmptyLabel, mutedButtons])

        stack.addArrangedSubview(startupCard)
        stack.addArrangedSubview(languageCard)
        stack.addArrangedSubview(mutedCard)
        pinWidth(of: [startupCard, languageCard, mutedCard], to: stack)
    }

    private func reloadGeneral() {
        openAtLoginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let current = loc.language.rawValue
        for (index, language) in AppLanguage.allCases.enumerated()
        where language.rawValue == current {
            languagePopup.selectItem(at: index)
        }
        mutedApps = AppMuteStore.shared.allMuted().sorted()
        mutedTable.reloadData()
        mutedEmptyLabel.stringValue = mutedApps.isEmpty ? loc.s("prefs.general.mutedApps.empty") : ""
        mutedEmptyLabel.isHidden = !mutedApps.isEmpty
    }

    @objc private func openAtLoginChanged() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            DevTypeAlert.warn(
                title: loc.s("alert.openAtLogin.title"),
                message: loc.s("alert.openAtLogin.message", error.localizedDescription),
                window: view.window
            )
        }
        reloadGeneral()
    }

    @objc private func languageChanged() {
        guard let raw = languagePopup.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        loc.language = language
    }

    @objc private func muteFrontmost() {
        guard let bundleID = AppMuteStore.shared.muteFrontmost() else {
            DevTypeAlert.warn(
                title: loc.s("alert.muteFrontmost.failed.title"),
                message: loc.s("alert.muteFrontmost.failed.message"),
                window: view.window
            )
            return
        }
        DevTypeLog.app.info("[Prefs] muted \(bundleID, privacy: .public)")
        reloadGeneral()
    }

    @objc private func unmuteSelected() {
        let selected = mutedTable.selectedRowIndexes
        guard !selected.isEmpty else { return }
        for row in selected where mutedApps.indices.contains(row) {
            AppMuteStore.shared.unmute(mutedApps[row])
        }
        reloadGeneral()
    }

    // MARK: Snippets (§4.5 / §0.4 / §1.9)

    /// Touch ID gate for secrets, on the tab that owns snippets.
    ///
    /// The note under the switch says what the check is *worth*, not just what it does. A security
    /// control whose limits are not stated invites the user to rely on it for more than it covers.
    private func buildSecretsCard(into stack: NSStackView) {
        let availability = BiometricGate.shared.availability()
        let card = makeCard(title: loc.s("prefs.secrets.card"), symbol: "key.fill")

        requireBiometrySwitch.state =
            SecretPreferences.requireBiometry(availability: availability) ? .on : .off
        requireBiometrySwitch.isEnabled = availability.canGate

        let row = makeToggleRow(
            title: loc.s("prefs.secrets.requireBiometry"),
            toggle: requireBiometrySwitch,
            action: #selector(requireBiometryChanged)
        )

        let detail: String
        switch availability {
        case .biometry(let name): detail = loc.s("prefs.secrets.note.biometry", name)
        case .passwordOnly: detail = loc.s("prefs.secrets.note.password")
        case .unavailable: detail = loc.s("prefs.secrets.note.unavailable")
        }
        let note = DevTypeTheme.makeLabel(
            detail,
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        note.translatesAutoresizingMaskIntoConstraints = false

        let scope = DevTypeTheme.makeLabel(
            loc.s("prefs.secrets.note.scope"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        scope.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(card, views: [row, note, scope])
        stack.addArrangedSubview(card)
        pinWidth(of: [card], to: stack)
    }

    func refreshSecretsCard() {
        let availability = BiometricGate.shared.availability()
        requireBiometrySwitch.state =
            SecretPreferences.requireBiometry(availability: availability) ? .on : .off
        requireBiometrySwitch.isEnabled = availability.canGate
    }

    @objc private func requireBiometryChanged() {
        SecretPreferences.setRequireBiometry(requireBiometrySwitch.state == .on)
        // Turning it on must take effect now, not after the current reuse window expires.
        BiometricGate.shared.invalidate()
    }

    private func buildSnippets(into stack: NSStackView) {
        buildSecretsCard(into: stack)

        addChild(stats)
        let statsView = stats.view
        statsView.translatesAutoresizingMaskIntoConstraints = false

        let libraryCard = makeCard(title: loc.s("manager.title"), symbol: "square.stack.3d.up")
        libraryPathLabel.translatesAutoresizingMaskIntoConstraints = false
        let ioButtons = NSStackView(views: [
            CapsuleButton(
                title: loc.s("manager.import"),
                symbol: "square.and.arrow.down",
                style: .secondary,
                target: self,
                action: #selector(importLibrary)
            ),
            CapsuleButton(
                title: loc.s("manager.export"),
                symbol: "square.and.arrow.up",
                style: .primary,
                target: self,
                action: #selector(exportLibrary)
            )
        ])
        ioButtons.orientation = .horizontal
        ioButtons.spacing = 8
        ioButtons.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(libraryCard, views: [libraryPathLabel, ioButtons])

        // §1.9: `SnippetSearch.conflictingTriggers` was dead code. Surfacing the
        // store's `triggerConflicts()` is how the user learns that `:Hi` and `:hi`
        // both live on disk while only one can ever fire.
        let conflictCard = makeCard(title: loc.s("prefs.snippets.conflicts"), symbol: "exclamationmark.triangle.fill")
        conflictsLabel.translatesAutoresizingMaskIntoConstraints = false
        let rescan = CapsuleButton(
            title: loc.s("prefs.snippets.rescan"),
            symbol: "arrow.triangle.2.circlepath",
            style: .secondary,
            target: self,
            action: #selector(rescanConflicts)
        )
        stackInCard(conflictCard, views: [conflictsLabel, rescan])

        stack.addArrangedSubview(statsView)
        stack.addArrangedSubview(libraryCard)
        stack.addArrangedSubview(conflictCard)
        pinWidth(of: [statsView, libraryCard, conflictCard], to: stack)
    }

    private func reloadSnippets() {
        libraryPathLabel.stringValue = loc.s("prefs.snippets.libraryPath", store.activeLocationURL.path)
        rescanConflicts()
    }

    @objc private func rescanConflicts() {
        let conflicts = store.triggerConflicts()
        guard !conflicts.isEmpty else {
            conflictsLabel.stringValue = loc.s("prefs.snippets.conflicts.none")
            conflictsLabel.textColor = DevTypeTheme.statusGreen
            return
        }
        var lines: [String] = []
        for conflict in conflicts.prefix(20) {
            let groups = conflict.groupNames.joined(separator: ", ")
            switch conflict.kind {
            case .emptyTrigger:
                lines.append(loc.s("prefs.snippets.conflict.empty", groups))
            case .duplicateTrigger:
                lines.append(loc.s("prefs.snippets.conflict.duplicate", conflict.trigger, groups))
            case .caseShadow:
                lines.append(loc.s("prefs.snippets.conflict.caseShadow", conflict.trigger, groups))
            case .prefixShadow:
                // snippetIDs[0] / groupNames[0] are the shadowing trigger; the rest are the
                // triggers it makes unreachable. Name them — "some snippet is shadowed" is
                // not actionable, "`slmabout can never fire" is.
                let blocked = conflict.blockedTriggerSummary ?? groups
                lines.append(loc.s("prefs.snippets.conflict.prefixShadow", conflict.trigger, blocked))
            }
        }
        conflictsLabel.stringValue = lines.joined(separator: "\n")
        conflictsLabel.textColor = DevTypeTheme.statusOrange
    }

    @objc private func exportLibrary() {
        LibraryExporter.present(from: view.window, store: store)
    }

    @objc private func importLibrary() {
        SnippetImportFlow.present(from: view.window) { [weak self] in
            self?.reloadSnippets()
        }
    }

    // MARK: Hotkeys (§4.2 / §4.3)

    private func buildHotkeys(into stack: NSStackView) {
        let searchCard = makeCard(title: loc.s("prefs.hotkeys.inlineSearch"), symbol: "magnifyingglass")
        let hint = DevTypeTheme.makeLabel(
            loc.s("prefs.hotkeys.inlineSearch.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        hint.translatesAutoresizingMaskIntoConstraints = false

        let recorder = ShortcutRecorderView(shortcut: HotkeyPreferences.inlineSearchShortcut)
        recorder.onChange = { [weak self] shortcut in
            self?.applyInlineShortcut(shortcut)
        }
        inlineRecorder = recorder

        let resetButton = CapsuleButton(
            title: loc.s("prefs.hotkeys.reset"),
            symbol: "arrow.counterclockwise",
            style: .secondary,
            target: self,
            action: #selector(resetInlineShortcut)
        )
        let recorderRow = NSStackView(views: [recorder, resetButton])
        recorderRow.orientation = .horizontal
        recorderRow.spacing = 10
        recorderRow.translatesAutoresizingMaskIntoConstraints = false

        hotkeyWarningLabel.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(searchCard, views: [hint, recorderRow, hotkeyWarningLabel])

        // §4.3: the macro list that had no UI.
        let macroCard = makeCard(title: loc.s("prefs.hotkeys.macros"), symbol: "text.insert")
        let macroHint = DevTypeTheme.makeLabel(
            loc.s("prefs.hotkeys.macros.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        macroHint.translatesAutoresizingMaskIntoConstraints = false

        macroTable.headerView = nil
        macroTable.rowHeight = 24
        macroTable.backgroundColor = .clear
        macroTable.gridStyleMask = []
        macroTable.usesAlternatingRowBackgroundColors = false
        macroTable.dataSource = self
        macroTable.delegate = self
        macroTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("macro")))
        macroTable.setAccessibilityLabel(loc.s("prefs.hotkeys.macros"))

        let macroScroll = NSScrollView()
        macroScroll.translatesAutoresizingMaskIntoConstraints = false
        macroScroll.hasVerticalScroller = true
        macroScroll.borderType = .noBorder
        macroScroll.drawsBackground = false
        macroScroll.documentView = macroTable
        macroScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        let newRecorder = ShortcutRecorderView(shortcut: nil)
        macroRecorder = newRecorder

        macroKindPopup.translatesAutoresizingMaskIntoConstraints = false
        macroKindPopup.removeAllItems()
        macroKindPopup.addItem(withTitle: loc.s("prefs.hotkeys.macros.kind.insertText"))
        macroKindPopup.lastItem?.representedObject = HotkeyMacroAction.Kind.insertText.rawValue
        macroKindPopup.addItem(withTitle: loc.s("prefs.hotkeys.macros.kind.openURL"))
        macroKindPopup.lastItem?.representedObject = HotkeyMacroAction.Kind.openURL.rawValue
        macroKindPopup.setAccessibilityLabel(loc.s("prefs.hotkeys.macros.kind"))

        macroArgumentField.translatesAutoresizingMaskIntoConstraints = false
        macroArgumentField.placeholderString = loc.s("prefs.hotkeys.macros.argument")
        macroArgumentField.font = DevTypeTheme.font(12)
        macroArgumentField.setAccessibilityLabel(loc.s("prefs.hotkeys.macros.argument"))
        macroArgumentField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let editorRow = NSStackView(views: [newRecorder, macroKindPopup, macroArgumentField])
        editorRow.orientation = .horizontal
        editorRow.spacing = 8
        editorRow.translatesAutoresizingMaskIntoConstraints = false

        let macroButtons = NSStackView(views: [
            CapsuleButton(
                title: loc.s("prefs.hotkeys.macros.add"),
                symbol: "plus",
                style: .primary,
                target: self,
                action: #selector(addMacro)
            ),
            CapsuleButton(
                title: loc.s("common.remove"),
                symbol: "trash",
                style: .destructive,
                target: self,
                action: #selector(removeMacro)
            )
        ])
        macroButtons.orientation = .horizontal
        macroButtons.spacing = 8
        macroButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(macroCard, views: [macroHint, macroScroll, editorRow, macroButtons])

        stack.addArrangedSubview(searchCard)
        stack.addArrangedSubview(macroCard)
        pinWidth(of: [searchCard, macroCard], to: stack)
    }

    private func reloadHotkeys() {
        let shortcut = HotkeyPreferences.inlineSearchShortcut
        inlineRecorder?.setShortcut(shortcut)
        hotkeyWarningLabel.stringValue = shortcut.isDefaultInlineSearch
            ? loc.s("prefs.hotkeys.conflictWarning")
            : ""
        hotkeyWarningLabel.isHidden = !shortcut.isDefaultInlineSearch
        macros = hotkeyManager?.macros ?? HotkeyManager.loadMacros()
        macroTable.reloadData()
    }

    private func applyInlineShortcut(_ shortcut: DevTypeShortcut?) {
        guard let shortcut else { return }
        guard let manager = hotkeyManager else {
            HotkeyPreferences.inlineSearchShortcut = shortcut
            reloadHotkeys()
            return
        }
        let status = manager.applyInlineSearchShortcut(shortcut)
        if status != noErr {
            // §4.2: registration failure is surfaced, not silently logged.
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.failed.title"),
                message: loc.s("prefs.hotkeys.failed.message", shortcut.displayString, Int(status)),
                window: view.window
            )
        }
        reloadHotkeys()
    }

    @objc private func resetInlineShortcut() {
        HotkeyPreferences.resetInlineSearchShortcut()
        applyInlineShortcut(.inlineSearchDefault)
    }

    @objc private func addMacro() {
        guard let shortcut = macroRecorder?.shortcut else {
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.macros.add"),
                message: loc.s("shortcut.needsModifier"),
                window: view.window
            )
            return
        }
        let argument = macroArgumentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else {
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.macros.add"),
                message: loc.s("prefs.hotkeys.macros.argument"),
                window: view.window
            )
            return
        }
        let rawKind = macroKindPopup.selectedItem?.representedObject as? String
        let kind = HotkeyMacroAction.Kind(rawValue: rawKind ?? "") ?? .insertText
        macros.append(
            HotkeyMacroAction(
                id: 0,
                keyCode: shortcut.keyCode,
                modifiers: shortcut.carbonModifiers,
                kind: kind,
                argument: argument
            )
        )
        let failures = hotkeyManager?.applyMacros(macros) ?? []
        if hotkeyManager == nil { HotkeyPreferences.saveMacros(macros) }
        reportRegistrationFailures(failures)
        macroArgumentField.stringValue = ""
        macroRecorder?.setShortcut(nil)
        reloadHotkeys()
    }

    /// §4.2 parity for macros: a chord owned by another app must not produce a
    /// table row that silently does nothing forever. The app delegate suppresses
    /// its own alert while Preferences is visible, so this is the one channel
    /// that reaches the user here.
    private func reportRegistrationFailures(_ failures: [(label: String, status: OSStatus)]) {
        guard let first = failures.first else { return }
        DevTypeAlert.warn(
            title: loc.s("prefs.hotkeys.failed.title"),
            message: loc.s("prefs.hotkeys.failed.message", first.label, Int(first.status)),
            window: view.window
        )
    }

    @objc private func removeMacro() {
        let row = macroTable.selectedRow
        guard macros.indices.contains(row) else { return }
        macros.remove(at: row)
        hotkeyManager?.applyMacros(macros)
        if hotkeyManager == nil { HotkeyPreferences.saveMacros(macros) }
        reloadHotkeys()
    }

    // MARK: Voice & Smart Dictation

    private func buildVoice(into stack: NSStackView) {
        // 0. Permission Card
        let permCard = makeCard(title: loc.s("prefs.voice.permission.card"), symbol: "mic.badge.shield")
        let permHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.permission.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        permHint.translatesAutoresizingMaskIntoConstraints = false

        let micPill = PillBadgeView(text: "Checking...", tint: DevTypeTheme.statusGray, showsDot: true)
        voiceMicPermissionPill = micPill

        let permActionsRow = NSStackView(views: [
            micPill,
            CapsuleButton(
                title: loc.s("prefs.voice.requestMic"),
                symbol: "mic.fill",
                style: .primary,
                target: self,
                action: #selector(requestMicrophoneAccessClicked)
            ),
            CapsuleButton(
                title: loc.s("prefs.voice.openSettings"),
                symbol: "gearshape",
                style: .secondary,
                target: self,
                action: #selector(openMicrophoneSettingsClicked)
            )
        ])
        permActionsRow.orientation = .horizontal
        permActionsRow.spacing = 10
        permActionsRow.alignment = .centerY
        permActionsRow.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(permCard, views: [permHint, permActionsRow])

        // 1. Models Card
        let modelsCard = makeCard(title: loc.s("prefs.voice.models.card"), symbol: "waveform.and.mic")
        let modelsHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.models.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        modelsHint.translatesAutoresizingMaskIntoConstraints = false

        // Active model selector row
        voiceModelPopup.translatesAutoresizingMaskIntoConstraints = false
        voiceModelPopup.removeAllItems()
        for model in VoiceModelType.allCases {
            voiceModelPopup.addItem(withTitle: model.descriptor.name)
            voiceModelPopup.lastItem?.representedObject = model.rawValue
        }
        voiceModelPopup.target = self
        voiceModelPopup.action = #selector(voiceModelPopupChanged(_:))
        voiceModelPopup.setAccessibilityLabel(loc.s("prefs.voice.activeModel"))

        let activeModelLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.activeModel"),
            font: DevTypeTheme.font(12, .semibold),
            color: DevTypeTheme.textPrimary
        )
        activeModelLabel.translatesAutoresizingMaskIntoConstraints = false
        let activeModelRow = NSStackView(views: [activeModelLabel, voiceModelPopup])
        activeModelRow.orientation = .horizontal
        activeModelRow.spacing = 10
        activeModelRow.alignment = .centerY
        activeModelRow.translatesAutoresizingMaskIntoConstraints = false

        var modelCards: [NSView] = [modelsHint, activeModelRow, DevTypeTheme.makeHairline()]

        for type in [VoiceModelType.voxtralMini4B, VoiceModelType.funASRNano] {
            let desc = type.descriptor
            let container = NSStackView()
            container.orientation = .vertical
            container.alignment = .leading
            container.spacing = 4
            container.translatesAutoresizingMaskIntoConstraints = false

            let headerRow = NSStackView()
            headerRow.orientation = .horizontal
            headerRow.alignment = .centerY
            headerRow.spacing = 8
            headerRow.translatesAutoresizingMaskIntoConstraints = false

            let nameLabel = DevTypeTheme.makeLabel(desc.name, font: DevTypeTheme.font(12.5, .bold), color: DevTypeTheme.textPrimary)
            let badge = PillBadgeView(text: desc.modelSizeFormatted, tint: desc.isRecommended ? DevTypeTheme.accent : DevTypeTheme.statusGray, showsDot: false)
            let paramLabel = DevTypeTheme.makeLabel(desc.parameterCount, font: DevTypeTheme.font(10.5), color: DevTypeTheme.textTertiary)

            headerRow.addArrangedSubview(nameLabel)
            headerRow.addArrangedSubview(badge)
            headerRow.addArrangedSubview(paramLabel)

            let descLabel = DevTypeTheme.makeLabel(desc.description, font: DevTypeTheme.font(10.5), color: DevTypeTheme.textSecondary, wrapping: true)
            descLabel.translatesAutoresizingMaskIntoConstraints = false

            let progressBar = NSProgressIndicator()
            progressBar.translatesAutoresizingMaskIntoConstraints = false
            progressBar.isIndeterminate = false
            progressBar.minValue = 0.0
            progressBar.maxValue = 1.0
            progressBar.doubleValue = 0.0
            progressBar.style = .bar
            progressBar.isHidden = true
            progressBar.controlSize = .small
            voiceModelDownloadProgressBars[type] = progressBar

            let statusLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10.5, .medium), color: DevTypeTheme.textSecondary)
            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            voiceModelStatusLabels[type] = statusLabel

            let actionButton = CapsuleButton(
                title: loc.s("common.download"),
                symbol: "arrow.down.circle",
                style: .primary,
                target: self,
                action: #selector(voiceModelActionButtonClicked(_:))
            )
            voiceModelActionButtons[type] = actionButton

            let deleteButton = CapsuleButton(
                title: loc.s("common.remove"),
                symbol: "trash",
                style: .destructive,
                target: self,
                action: #selector(voiceModelDeleteButtonClicked(_:))
            )
            voiceModelDeleteButtons[type] = deleteButton

            let actionsRow = NSStackView()
            actionsRow.orientation = .horizontal
            actionsRow.spacing = 8
            actionsRow.alignment = .centerY
            actionsRow.translatesAutoresizingMaskIntoConstraints = false
            actionsRow.addArrangedSubview(actionButton)
            actionsRow.addArrangedSubview(deleteButton)
            actionsRow.addArrangedSubview(statusLabel)

            container.addArrangedSubview(headerRow)
            container.addArrangedSubview(descLabel)
            container.addArrangedSubview(progressBar)
            container.addArrangedSubview(actionsRow)

            progressBar.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            modelCards.append(container)
            modelCards.append(DevTypeTheme.makeHairline())
        }

        stackInCard(modelsCard, views: modelCards)

        // 2. Smart Dictation Options Card
        let optionsCard = makeCard(title: loc.s("prefs.voice.options.card"), symbol: "sparkles")

        voiceTonePopup.translatesAutoresizingMaskIntoConstraints = false
        voiceTonePopup.removeAllItems()
        for tone in DictationTone.allCases {
            voiceTonePopup.addItem(withTitle: loc.s(tone.localizationKey))
            voiceTonePopup.lastItem?.representedObject = tone.rawValue
        }
        voiceTonePopup.target = self
        voiceTonePopup.action = #selector(voiceTonePopupChanged(_:))
        voiceTonePopup.setAccessibilityLabel(loc.s("prefs.voice.tone"))

        let toneLabel = DevTypeTheme.makeLabel(loc.s("prefs.voice.tone"), font: DevTypeTheme.font(12, .semibold), color: DevTypeTheme.textPrimary)
        let toneRow = NSStackView(views: [toneLabel, voiceTonePopup])
        toneRow.orientation = .horizontal
        toneRow.spacing = 10
        toneRow.alignment = .centerY
        toneRow.translatesAutoresizingMaskIntoConstraints = false

        let realTimeTypingRow = makeToggleRow(
            title: loc.s("prefs.voice.realTimeTyping"),
            toggle: voiceRealTimeTypingSwitch,
            action: #selector(voiceRealTimeTypingChanged)
        )
        let disfluencyRow = makeToggleRow(
            title: loc.s("prefs.voice.removeDisfluencies"),
            toggle: voiceDisfluenciesSwitch,
            action: #selector(voiceDisfluenciesChanged)
        )
        let autoPunctuateRow = makeToggleRow(
            title: loc.s("prefs.voice.autoPunctuate"),
            toggle: voiceAutoPunctuateSwitch,
            action: #selector(voiceAutoPunctuateChanged)
        )
        let soundFeedbackRow = makeToggleRow(
            title: loc.s("prefs.voice.soundFeedback"),
            toggle: voiceSoundFeedbackSwitch,
            action: #selector(voiceSoundFeedbackChanged)
        )
        let handsFreeRow = makeToggleRow(
            title: loc.s("prefs.voice.handsFree"),
            toggle: voiceHandsFreeSwitch,
            action: #selector(voiceHandsFreeChanged)
        )

        stackInCard(optionsCard, views: [toneRow, realTimeTypingRow, disfluencyRow, autoPunctuateRow, soundFeedbackRow, handsFreeRow])

        // 3. Hotkey Card
        let hotkeyCard = makeCard(title: loc.s("prefs.voice.hotkey.card"), symbol: "keyboard")
        let hotkeyHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.hotkey.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        hotkeyHint.translatesAutoresizingMaskIntoConstraints = false

        let recorder = ShortcutRecorderView(shortcut: HotkeyPreferences.voiceShortcut)
        recorder.onChange = { [weak self] shortcut in
            self?.applyVoiceShortcut(shortcut)
        }
        voiceShortcutRecorder = recorder

        let resetButton = CapsuleButton(
            title: loc.s("prefs.voice.hotkey.reset"),
            symbol: "arrow.counterclockwise",
            style: .secondary,
            target: self,
            action: #selector(resetVoiceShortcut)
        )
        let recorderRow = NSStackView(views: [recorder, resetButton])
        recorderRow.orientation = .horizontal
        recorderRow.spacing = 10
        recorderRow.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(hotkeyCard, views: [hotkeyHint, recorderRow])

        // 4. Custom Dictionary Card
        let dictCard = makeCard(title: loc.s("prefs.voice.dict.card"), symbol: "text.badge.plus")
        let dictHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.dict.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        dictHint.translatesAutoresizingMaskIntoConstraints = false

        voiceDictionaryTable.headerView = nil
        voiceDictionaryTable.rowHeight = 22
        voiceDictionaryTable.backgroundColor = .clear
        voiceDictionaryTable.gridStyleMask = []
        voiceDictionaryTable.usesAlternatingRowBackgroundColors = false
        voiceDictionaryTable.dataSource = self
        voiceDictionaryTable.delegate = self
        if voiceDictionaryTable.tableColumns.isEmpty {
            voiceDictionaryTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("voiceDict")))
        }
        voiceDictionaryTable.setAccessibilityLabel(loc.s("prefs.voice.dict.card"))

        let dictScroll = NSScrollView()
        dictScroll.translatesAutoresizingMaskIntoConstraints = false
        dictScroll.hasVerticalScroller = true
        dictScroll.borderType = .noBorder
        dictScroll.drawsBackground = false
        dictScroll.documentView = voiceDictionaryTable
        dictScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        voiceDictionaryEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        voiceDictSpokenField.translatesAutoresizingMaskIntoConstraints = false
        voiceDictSpokenField.placeholderString = loc.s("prefs.voice.dict.spokenPlaceholder")
        voiceDictSpokenField.font = DevTypeTheme.font(12)
        voiceDictSpokenField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        voiceDictReplacementField.translatesAutoresizingMaskIntoConstraints = false
        voiceDictReplacementField.placeholderString = loc.s("prefs.voice.dict.replacementPlaceholder")
        voiceDictReplacementField.font = DevTypeTheme.font(12)
        voiceDictReplacementField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        let dictButtons = NSStackView(views: [
            voiceDictSpokenField,
            voiceDictReplacementField,
            CapsuleButton(
                title: loc.s("common.add"),
                symbol: "plus",
                style: .primary,
                target: self,
                action: #selector(voiceDictAddEntry)
            ),
            CapsuleButton(
                title: loc.s("common.remove"),
                symbol: "trash",
                style: .destructive,
                target: self,
                action: #selector(voiceDictRemoveEntry)
            )
        ])
        dictButtons.orientation = .horizontal
        dictButtons.spacing = 8
        dictButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(dictCard, views: [dictHint, dictScroll, voiceDictionaryEmptyLabel, dictButtons])

        // 5. AI Voice Triggers & Rewrites Card
        let triggersCard = makeCard(title: loc.s("prefs.voice.triggers.card"), symbol: "wand.and.stars")

        let disclaimerPill = PillBadgeView(text: "macOS 27 Required", tint: DevTypeTheme.statusOrange, showsDot: true)
        disclaimerPill.translatesAutoresizingMaskIntoConstraints = false

        let disclaimerText = DevTypeTheme.makeLabel(
            "Disclaimer: AI rewrite and developer-type tools require macOS 27 to function properly (tested on macOS 26 where AI features are not operational).",
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.accentBright,
            wrapping: true
        )
        disclaimerText.translatesAutoresizingMaskIntoConstraints = false

        let disclaimerBox = NSStackView(views: [disclaimerPill, disclaimerText])
        disclaimerBox.orientation = .vertical
        disclaimerBox.alignment = .leading
        disclaimerBox.spacing = 3
        disclaimerBox.translatesAutoresizingMaskIntoConstraints = false

        let triggersHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.triggers.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        triggersHint.translatesAutoresizingMaskIntoConstraints = false

        voiceTriggersTable.headerView = nil
        voiceTriggersTable.rowHeight = 22
        voiceTriggersTable.backgroundColor = .clear
        voiceTriggersTable.gridStyleMask = []
        voiceTriggersTable.usesAlternatingRowBackgroundColors = false
        voiceTriggersTable.dataSource = self
        voiceTriggersTable.delegate = self
        if voiceTriggersTable.tableColumns.isEmpty {
            voiceTriggersTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("voiceTriggers")))
        }
        voiceTriggersTable.setAccessibilityLabel(loc.s("prefs.voice.triggers.card"))

        let triggersScroll = NSScrollView()
        triggersScroll.translatesAutoresizingMaskIntoConstraints = false
        triggersScroll.hasVerticalScroller = true
        triggersScroll.borderType = .noBorder
        triggersScroll.drawsBackground = false
        triggersScroll.documentView = voiceTriggersTable
        triggersScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        voiceTriggersEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        voiceTriggerPhraseField.translatesAutoresizingMaskIntoConstraints = false
        voiceTriggerPhraseField.placeholderString = loc.s("prefs.voice.triggers.phrasePlaceholder")
        voiceTriggerPhraseField.font = DevTypeTheme.font(12)
        voiceTriggerPhraseField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        voiceTriggerActionPopup.translatesAutoresizingMaskIntoConstraints = false
        voiceTriggerActionPopup.removeAllItems()
        for kind in AITransformKind.builtInPalette {
            voiceTriggerActionPopup.addItem(withTitle: loc.s(kind.localizationKey))
            voiceTriggerActionPopup.lastItem?.representedObject = kind.rawValue
        }

        let triggerControls = NSStackView(views: [
            voiceTriggerPhraseField,
            voiceTriggerActionPopup,
            CapsuleButton(
                title: loc.s("common.add"),
                symbol: "plus",
                style: .primary,
                target: self,
                action: #selector(voiceTriggerAddEntry)
            ),
            CapsuleButton(
                title: loc.s("common.remove"),
                symbol: "trash",
                style: .destructive,
                target: self,
                action: #selector(voiceTriggerRemoveEntry)
            )
        ])
        triggerControls.orientation = .horizontal
        triggerControls.spacing = 8
        triggerControls.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(triggersCard, views: [disclaimerBox, triggersHint, triggersScroll, voiceTriggersEmptyLabel, triggerControls])

        for card in [permCard, modelsCard, optionsCard, hotkeyCard, dictCard, triggersCard] {
            stack.addArrangedSubview(card)
        }
        pinWidth(of: [permCard, modelsCard, optionsCard, hotkeyCard, dictCard, triggersCard], to: stack)
    }

    private func reloadVoice() {
        guard panes[.voice] != nil else { return }

        let micGranted = VoiceAudioRecorder.checkMicrophonePermission()
        voiceMicPermissionPill?.update(
            text: micGranted ? loc.s("status.active") : loc.s("status.needsPermissions"),
            tint: micGranted ? DevTypeTheme.statusGreen : DevTypeTheme.accent
        )

        let currentModel = VoicePreferences.selectedModel
        if let index = VoiceModelType.allCases.firstIndex(of: currentModel) {
            voiceModelPopup.selectItem(at: index)
        }

        let currentTone = VoicePreferences.tone
        if let index = DictationTone.allCases.firstIndex(of: currentTone) {
            voiceTonePopup.selectItem(at: index)
        }

        voiceRealTimeTypingSwitch.state = VoicePreferences.isRealTimeTypingEnabled ? .on : .off
        voiceAutoPunctuateSwitch.state = VoicePreferences.isAutoPunctuateEnabled ? .on : .off
        voiceDisfluenciesSwitch.state = VoicePreferences.isRemoveDisfluenciesEnabled ? .on : .off
        voiceSoundFeedbackSwitch.state = VoicePreferences.isSoundFeedbackEnabled ? .on : .off
        voiceHandsFreeSwitch.state = VoicePreferences.isHandsFreeModeEnabled ? .on : .off

        voiceShortcutRecorder?.setShortcut(HotkeyPreferences.voiceShortcut)

        for type in [VoiceModelType.voxtralMini4B, VoiceModelType.funASRNano] {
            let status = VoiceModelManager.shared.status(for: type)
            updateVoiceModelUI(type: type, status: status)
        }

        let dict = VoicePreferences.customDictionary
        voiceDictEntries = dict.map { (spoken: $0.key, replacement: $0.value) }.sorted { $0.spoken < $1.spoken }
        voiceDictionaryTable.reloadData()
        voiceDictionaryEmptyLabel.stringValue = voiceDictEntries.isEmpty ? loc.s("prefs.voice.dict.empty") : ""
        voiceDictionaryEmptyLabel.isHidden = !voiceDictEntries.isEmpty

        let triggers = VoicePreferences.customVoiceTriggers
        voiceTriggerEntries = triggers.map { (phrase: $0.key, action: $0.value) }.sorted { $0.phrase < $1.phrase }
        voiceTriggersTable.reloadData()
        voiceTriggersEmptyLabel.stringValue = voiceTriggerEntries.isEmpty ? loc.s("prefs.voice.triggers.empty") : ""
        voiceTriggersEmptyLabel.isHidden = !voiceTriggerEntries.isEmpty
    }

    @objc private func voiceRealTimeTypingChanged() {
        VoicePreferences.isRealTimeTypingEnabled = voiceRealTimeTypingSwitch.state == .on
    }

    @objc private func voiceTriggerAddEntry() {
        let phrase = voiceTriggerPhraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty,
              let rawAction = voiceTriggerActionPopup.selectedItem?.representedObject as? String else { return }

        VoicePreferences.addVoiceTrigger(phrase: phrase, action: rawAction)
        voiceTriggerPhraseField.stringValue = ""
        reloadVoice()
    }

    @objc private func voiceTriggerRemoveEntry() {
        let row = voiceTriggersTable.selectedRow
        guard voiceTriggerEntries.indices.contains(row) else { return }
        let entry = voiceTriggerEntries[row]
        VoicePreferences.removeVoiceTrigger(phrase: entry.phrase)
        reloadVoice()
    }

    @objc private func requestMicrophoneAccessClicked() {
        VoiceAudioRecorder.requestMicrophonePermission { [weak self] _ in
            DispatchQueue.main.async {
                self?.reloadVoice()
            }
        }
    }

    @objc private func openMicrophoneSettingsClicked() {
        SettingsDeepLinker.shared.open(for: .microphone)
    }

    private func updateVoiceModelUI(type: VoiceModelType, status: VoiceModelStatus) {
        guard let label = voiceModelStatusLabels[type],
              let button = voiceModelActionButtons[type],
              let progress = voiceModelDownloadProgressBars[type] else { return }

        switch status {
        case .notDownloaded:
            label.stringValue = loc.s("prefs.voice.status.notDownloaded")
            label.textColor = DevTypeTheme.textTertiary
            button.title = loc.s("common.download")
            button.buttonStyle = .primary
            button.isEnabled = true
            progress.isHidden = true

        case .downloading(let p, let bytes, let total):
            let formattedMb = String(format: "%.1f MB / %.1f MB", Double(bytes) / 1_000_000, Double(total) / 1_000_000)
            label.stringValue = loc.s("prefs.voice.status.downloading", formattedMb)
            label.textColor = DevTypeTheme.accentBright
            button.title = loc.s("common.cancel")
            button.buttonStyle = .destructive
            button.isEnabled = true
            progress.isHidden = false
            progress.doubleValue = p

        case .ready:
            label.stringValue = loc.s("prefs.voice.status.ready")
            label.textColor = DevTypeTheme.statusGreen
            button.title = loc.s("prefs.voice.status.installed")
            button.buttonStyle = .secondary
            button.isEnabled = false
            progress.isHidden = true

        case .error(let msg):
            label.stringValue = loc.s("prefs.voice.status.error", msg)
            label.textColor = DevTypeTheme.statusOrange
            button.title = loc.s("common.retry")
            button.buttonStyle = .primary
            button.isEnabled = true
            progress.isHidden = true
        }
    }

    @objc private func voiceModelPopupChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let model = VoiceModelType(rawValue: raw) else { return }
        VoicePreferences.selectedModel = model
    }

    @objc private func voiceTonePopupChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let tone = DictationTone(rawValue: raw) else { return }
        VoicePreferences.tone = tone
    }

    @objc private func voiceAutoPunctuateChanged() {
        VoicePreferences.isAutoPunctuateEnabled = voiceAutoPunctuateSwitch.state == .on
    }

    @objc private func voiceDisfluenciesChanged() {
        VoicePreferences.isRemoveDisfluenciesEnabled = voiceDisfluenciesSwitch.state == .on
    }

    @objc private func voiceSoundFeedbackChanged() {
        VoicePreferences.isSoundFeedbackEnabled = voiceSoundFeedbackSwitch.state == .on
    }

    @objc private func voiceHandsFreeChanged() {
        VoicePreferences.isHandsFreeModeEnabled = voiceHandsFreeSwitch.state == .on
    }

    @objc private func voiceModelActionButtonClicked(_ sender: CapsuleButton) {
        guard let type = voiceModelActionButtons.first(where: { $0.value === sender })?.key else { return }

        let status = VoiceModelManager.shared.status(for: type)
        switch status {
        case .downloading:
            VoiceModelManager.shared.cancelDownload(for: type)
        case .notDownloaded, .error:
            VoiceModelManager.shared.startDownload(for: type)
        case .ready:
            break
        }
        reloadVoice()
    }

    @objc private func voiceModelDeleteButtonClicked(_ sender: CapsuleButton) {
        guard let type = voiceModelDeleteButtons.first(where: { $0.value === sender })?.key else { return }

        try? VoiceModelManager.shared.deleteModel(for: type)
        reloadVoice()
    }

    private func applyVoiceShortcut(_ shortcut: DevTypeShortcut?) {
        guard let shortcut else { return }
        if let manager = hotkeyManager {
            manager.applyVoiceShortcut(shortcut)
        } else {
            HotkeyPreferences.voiceShortcut = shortcut
        }
        reloadVoice()
    }

    @objc private func resetVoiceShortcut() {
        HotkeyPreferences.resetVoiceShortcut()
        if let manager = hotkeyManager {
            manager.applyVoiceShortcut(HotkeyPreferences.voiceShortcut)
        }
        reloadVoice()
    }

    @objc private func voiceDictAddEntry() {
        let spoken = voiceDictSpokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = voiceDictReplacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !replacement.isEmpty else { return }

        VoicePreferences.addDictionaryEntry(spoken: spoken, replacement: replacement)
        voiceDictSpokenField.stringValue = ""
        voiceDictReplacementField.stringValue = ""
        reloadVoice()
    }

    @objc private func voiceDictRemoveEntry() {
        let row = voiceDictionaryTable.selectedRow
        guard voiceDictEntries.indices.contains(row) else { return }
        let entry = voiceDictEntries[row]
        VoicePreferences.removeDictionaryEntry(spoken: entry.spoken)
        reloadVoice()
    }

    // MARK: AI

    private func buildAI(into stack: NSStackView) {
        let featureAvailable = AITextTransformSupport.isRunningOnCompatibleOS

        if !featureAvailable {
            let unsupportedCard = makeCard(title: loc.s("prefs.tab.ai"), symbol: "sparkles")
            let disclaimerPill = PillBadgeView(text: "macOS 27 Required", tint: DevTypeTheme.statusOrange, showsDot: true)
            disclaimerPill.translatesAutoresizingMaskIntoConstraints = false

            let note = DevTypeTheme.makeLabel(
                "Disclaimer: On-device Apple Intelligence and Foundation Models require macOS 27 to function properly (tested on macOS 26 where AI features are not operational).",
                font: DevTypeTheme.font(11.5),
                color: DevTypeTheme.textSecondary,
                wrapping: true
            )
            note.translatesAutoresizingMaskIntoConstraints = false
            stackInCard(unsupportedCard, views: [disclaimerPill, note])
            stack.addArrangedSubview(unsupportedCard)
            pinWidth(of: [unsupportedCard], to: stack)
            return
        }

        // Enable + availability
        let enableCard = makeCard(title: loc.s("prefs.ai.enable.card"), symbol: "sparkles")
        let disclaimerPill = PillBadgeView(text: "macOS 27 Intelligence", tint: DevTypeTheme.accent, showsDot: true)
        disclaimerPill.translatesAutoresizingMaskIntoConstraints = false

        let enableRow = makeToggleRow(
            title: loc.s("prefs.ai.enable"),
            toggle: aiEnabledSwitch,
            action: #selector(aiEnabledChanged)
        )
        let privacyNote = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.privacy"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        privacyNote.translatesAutoresizingMaskIntoConstraints = false
        aiAvailabilityLabel.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(enableCard, views: [disclaimerPill, enableRow, privacyNote, aiAvailabilityLabel])

        // Palette hotkey
        let hotkeyCard = makeCard(title: loc.s("prefs.ai.hotkey"), symbol: "keyboard")
        let hotkeyHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.hotkey.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        hotkeyHint.translatesAutoresizingMaskIntoConstraints = false
        let recorder = ShortcutRecorderView(shortcut: HotkeyPreferences.aiPaletteShortcut)
        recorder.onChange = { [weak self] shortcut in
            self?.applyAIPaletteShortcut(shortcut)
        }
        aiPaletteRecorder = recorder
        let resetButton = CapsuleButton(
            title: loc.s("prefs.ai.hotkey.reset"),
            symbol: "arrow.counterclockwise",
            style: .secondary,
            target: self,
            action: #selector(resetAIPaletteShortcut)
        )
        let recorderRow = NSStackView(views: [recorder, resetButton])
        recorderRow.orientation = .horizontal
        recorderRow.spacing = 10
        recorderRow.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(hotkeyCard, views: [hotkeyHint, recorderRow])

        // Per-action output modes
        let modesCard = makeCard(title: loc.s("prefs.ai.outputModes"), symbol: "arrow.left.arrow.right")
        let modesHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.outputModes.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        modesHint.translatesAutoresizingMaskIntoConstraints = false
        var modeRows: [NSView] = [modesHint]
        aiOutputModePopups.removeAll()
        for kind in AITransformKind.builtInPalette {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.removeAllItems()
            popup.addItem(withTitle: loc.s("prefs.ai.output.direct"))
            popup.lastItem?.representedObject = AIOutputMode.direct.rawValue
            popup.addItem(withTitle: loc.s("prefs.ai.output.preview"))
            popup.lastItem?.representedObject = AIOutputMode.preview.rawValue
            popup.target = self
            popup.action = #selector(aiOutputModeChanged(_:))
            popup.setAccessibilityLabel(loc.s(kind.localizationKey))
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
            aiOutputModePopups[kind] = popup

            let label = DevTypeTheme.makeLabel(
                loc.s(kind.localizationKey),
                font: DevTypeTheme.font(12.5, .medium),
                color: DevTypeTheme.textPrimary
            )
            label.translatesAutoresizingMaskIntoConstraints = false
            let row = NSStackView(views: [label, popup])
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            popup.setContentHuggingPriority(.required, for: .horizontal)
            modeRows.append(row)
        }
        stackInCard(modesCard, views: modeRows)

        // Typed-path allowlist
        let allowCard = makeCard(title: loc.s("prefs.ai.allowlist"), symbol: "checkmark.seal")
        let allowHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.allowlist.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        allowHint.translatesAutoresizingMaskIntoConstraints = false

        aiAllowlistTable.headerView = nil
        aiAllowlistTable.rowHeight = 22
        aiAllowlistTable.backgroundColor = .clear
        aiAllowlistTable.gridStyleMask = []
        aiAllowlistTable.usesAlternatingRowBackgroundColors = false
        aiAllowlistTable.allowsMultipleSelection = true
        aiAllowlistTable.dataSource = self
        aiAllowlistTable.delegate = self
        if aiAllowlistTable.tableColumns.isEmpty {
            aiAllowlistTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("aiAllow")))
        }
        aiAllowlistTable.setAccessibilityLabel(loc.s("prefs.ai.allowlist"))

        let allowScroll = NSScrollView()
        allowScroll.translatesAutoresizingMaskIntoConstraints = false
        allowScroll.hasVerticalScroller = true
        allowScroll.borderType = .noBorder
        allowScroll.drawsBackground = false
        allowScroll.documentView = aiAllowlistTable
        allowScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        aiAllowlistEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        aiAllowlistField.translatesAutoresizingMaskIntoConstraints = false
        aiAllowlistField.placeholderString = loc.s("prefs.ai.allowlist.bundleID")
        aiAllowlistField.font = DevTypeTheme.font(12)
        aiAllowlistField.setAccessibilityLabel(loc.s("prefs.ai.allowlist.bundleID"))
        aiAllowlistField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let allowButtons = NSStackView(views: [
            CapsuleButton(
                title: loc.s("prefs.ai.allowlist.addFrontmost"),
                symbol: "plus.app",
                style: .secondary,
                target: self,
                action: #selector(aiAllowlistAddFrontmost)
            ),
            CapsuleButton(
                title: loc.s("common.add"),
                symbol: "plus",
                style: .primary,
                target: self,
                action: #selector(aiAllowlistAddTyped)
            ),
            CapsuleButton(
                title: loc.s("common.remove"),
                symbol: "trash",
                style: .destructive,
                target: self,
                action: #selector(aiAllowlistRemove)
            )
        ])
        allowButtons.orientation = .horizontal
        allowButtons.spacing = 8
        allowButtons.translatesAutoresizingMaskIntoConstraints = false

        let editorRow = NSStackView(views: [aiAllowlistField])
        editorRow.orientation = .horizontal
        editorRow.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(allowCard, views: [allowHint, allowScroll, aiAllowlistEmptyLabel, editorRow, allowButtons])

        for card in [enableCard, hotkeyCard, modesCard, allowCard] {
            stack.addArrangedSubview(card)
        }
        pinWidth(of: [enableCard, hotkeyCard, modesCard, allowCard], to: stack)
    }

    private func reloadAI() {
        guard panes[.ai] != nil else { return }
        aiEnabledSwitch.state = AIPreferences.isEnabled ? .on : .off
        aiAvailabilityLabel.stringValue = loc.s(
            "prefs.ai.availability",
            loc.s(AITextTransformSupport.availability.localizationKey)
        )
        switch AITextTransformSupport.availability {
        case .available:
            aiAvailabilityLabel.textColor = DevTypeTheme.statusGreen
        case .unavailable:
            aiAvailabilityLabel.textColor = DevTypeTheme.statusOrange
        }
        aiPaletteRecorder?.setShortcut(HotkeyPreferences.aiPaletteShortcut)
        for (kind, popup) in aiOutputModePopups {
            let mode = AIPreferences.outputMode(for: kind)
            let index = mode == .direct ? 0 : 1
            popup.selectItem(at: index)
        }
        aiAllowlist = AIPreferences.typedPathAllowlist
        aiAllowlistTable.reloadData()
        aiAllowlistEmptyLabel.stringValue = aiAllowlist.isEmpty
            ? loc.s("prefs.ai.allowlist.empty")
            : ""
        aiAllowlistEmptyLabel.isHidden = !aiAllowlist.isEmpty
    }

    @objc private func aiEnabledChanged() {
        AIPreferences.isEnabled = aiEnabledSwitch.state == .on
        reloadAI()
    }

    @objc private func aiOutputModeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = AIOutputMode(rawValue: raw) else { return }
        guard let kind = aiOutputModePopups.first(where: { $0.value === sender })?.key else { return }
        AIPreferences.setOutputMode(mode, for: kind)
    }

    private func applyAIPaletteShortcut(_ shortcut: DevTypeShortcut?) {
        guard let shortcut else { return }
        guard let manager = hotkeyManager else {
            HotkeyPreferences.aiPaletteShortcut = shortcut
            reloadAI()
            return
        }
        let status = manager.applyAIPaletteShortcut(shortcut)
        if status != noErr {
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.failed.title"),
                message: loc.s("prefs.hotkeys.failed.message", shortcut.displayString, Int(status)),
                window: view.window
            )
        }
        reloadAI()
    }

    @objc private func resetAIPaletteShortcut() {
        HotkeyPreferences.resetAIPaletteShortcut()
        applyAIPaletteShortcut(.aiPaletteDefault)
    }

    @objc private func aiAllowlistAddFrontmost() {
        guard let bundleID = AXContextChecker.shared.frontmostApplicationBundleIdentifier(),
              !bundleID.isEmpty else {
            DevTypeAlert.warn(
                title: loc.s("alert.muteFrontmost.failed.title"),
                message: loc.s("alert.muteFrontmost.failed.message"),
                window: view.window
            )
            return
        }
        AIPreferences.addTypedPathApp(bundleID)
        reloadAI()
    }

    @objc private func aiAllowlistAddTyped() {
        let bundleID = aiAllowlistField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        AIPreferences.addTypedPathApp(bundleID)
        aiAllowlistField.stringValue = ""
        reloadAI()
    }

    @objc private func aiAllowlistRemove() {
        let selected = aiAllowlistTable.selectedRowIndexes
        guard !selected.isEmpty else { return }
        let ids = selected.compactMap { aiAllowlist.indices.contains($0) ? aiAllowlist[$0] : nil }
        AIPreferences.removeTypedPathApps(ids)
        reloadAI()
    }

    // MARK: Advanced (§2.10 / §3.9 / §3.2 / §3.7 readouts)

    private func buildAdvanced(into stack: NSStackView) {
        let engineCard = makeCard(title: loc.s("prefs.advanced.engine"), symbol: "bolt.fill")
        let threadRow = makeToggleRow(
            title: loc.s("prefs.advanced.tapThread"),
            toggle: tapThreadSwitch,
            action: #selector(tapThreadChanged)
        )
        let threadHint = DevTypeTheme.makeLabel(
            loc.s("prefs.advanced.tapThread.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        threadHint.translatesAutoresizingMaskIntoConstraints = false
        advancedReadout.translatesAutoresizingMaskIntoConstraints = false
        let copyButton = CapsuleButton(
            title: loc.s("prefs.advanced.copyDiagnostics"),
            symbol: "doc.on.doc",
            style: .secondary,
            target: self,
            action: #selector(copyAdvancedDiagnostics)
        )
        stackInCard(engineCard, views: [threadRow, threadHint, advancedReadout, copyButton])

        let maintenanceCard = makeCard(title: loc.s("prefs.advanced.maintenance"), symbol: "arrow.counterclockwise")
        maintenanceStatus.translatesAutoresizingMaskIntoConstraints = false
        let maintenanceButtons = NSStackView(views: [
            CapsuleButton(
                title: loc.s("prefs.advanced.orphans"),
                symbol: "trash",
                style: .secondary,
                target: self,
                action: #selector(collectOrphans)
            ),
            CapsuleButton(
                title: loc.s("prefs.advanced.reset"),
                symbol: "arrow.counterclockwise",
                style: .destructive,
                target: self,
                action: #selector(resetLibrary)
            )
        ])
        maintenanceButtons.orientation = .horizontal
        maintenanceButtons.spacing = 8
        maintenanceButtons.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(maintenanceCard, views: [maintenanceButtons, maintenanceStatus])

        stack.addArrangedSubview(engineCard)
        stack.addArrangedSubview(maintenanceCard)
        pinWidth(of: [engineCard, maintenanceCard], to: stack)
    }

    private func reloadAdvanced() {
        tapThreadSwitch.state = EventTapEngine.useDedicatedTapThread ? .on : .off
        var lines: [String] = []
        lines.append(EventTapEngine.shared.tapDisableCounters.summaryLine)
        let telemetry = PermissionCoordinator.shared.injectTelemetrySummaryLines()
        lines.append(contentsOf: telemetry)
        lines.append(EventTapEngine.shared.prefixDebounceDiagnostics())
        let overlong = EventTapEngine.shared.overlongTriggerDiagnostics()
        if overlong.isEmpty {
            lines.append(loc.s("prefs.advanced.overlong.none"))
        } else {
            lines.append(contentsOf: overlong)
        }
        advancedReadout.stringValue = lines.joined(separator: "\n")
    }

    @objc private func tapThreadChanged() {
        let enabled = tapThreadSwitch.state == .on
        EventTapEngine.useDedicatedTapThread = enabled
        UserDefaults.standard.set(enabled, forKey: EventTapEngine.useDedicatedTapThreadDefaultsKey)
        reloadAdvanced()
    }

    @objc private func copyAdvancedDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(advancedReadout.stringValue, forType: .string)
        maintenanceStatus.stringValue = loc.s("prefs.advanced.copied")
        maintenanceStatus.textColor = DevTypeTheme.statusGreen
    }

    @objc private func collectOrphans() {
        let removed = store.collectOrphanedImages(dryRun: false)
        maintenanceStatus.stringValue = removed.isEmpty
            ? loc.s("prefs.advanced.orphans.none")
            : loc.s("prefs.advanced.orphans.result", removed.count)
        maintenanceStatus.textColor = DevTypeTheme.statusGreen
    }

    @objc private func resetLibrary() {
        DevTypeAlert.confirm(
            title: loc.s("alert.reset.title"),
            message: loc.s("alert.reset.message"),
            confirmTitle: loc.s("alert.reset.confirm"),
            destructive: true,
            window: view.window
        ) { [weak self] in
            guard let self else { return }
            self.store.saveSnippets(self.store.defaultSnippets())
            self.reloadSnippets()
        }
    }

    // MARK: Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === mutedTable { return mutedApps.count }
        if tableView === macroTable { return macros.count }
        if tableView === aiAllowlistTable { return aiAllowlist.count }
        if tableView === voiceDictionaryTable { return voiceDictEntries.count }
        if tableView === voiceTriggersTable { return voiceTriggerEntries.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === mutedTable {
            guard mutedApps.indices.contains(row) else { return nil }
            text = mutedApps[row]
        } else if tableView === macroTable {
            guard macros.indices.contains(row) else { return nil }
            let macro = macros[row]
            let shortcut = DevTypeShortcut(keyCode: macro.keyCode, carbonModifiers: macro.modifiers)
            let kindTitle = macro.kind == .insertText
                ? loc.s("prefs.hotkeys.macros.kind.insertText")
                : loc.s("prefs.hotkeys.macros.kind.openURL")
            text = "\(shortcut.displayString)  ·  \(kindTitle)  ·  \(macro.argument)"
        } else if tableView === aiAllowlistTable {
            guard aiAllowlist.indices.contains(row) else { return nil }
            text = aiAllowlist[row]
        } else if tableView === voiceDictionaryTable {
            guard voiceDictEntries.indices.contains(row) else { return nil }
            let entry = voiceDictEntries[row]
            text = "\(entry.spoken)  →  \(entry.replacement)"
        } else if tableView === voiceTriggersTable {
            guard voiceTriggerEntries.indices.contains(row) else { return nil }
            let entry = voiceTriggerEntries[row]
            let actionName = loc.s("ai.kind.\(entry.action)")
            text = "“\(entry.phrase)”  →  \(actionName)"
        } else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("prefsRow")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.font = DevTypeTheme.mono(11)
            label.lineBreakMode = .byTruncatingTail
        }
        label.stringValue = text
        label.textColor = DevTypeTheme.textPrimary
        // §5.1: rows read as their content instead of "row N".
        label.setAccessibilityLabel(text)
        return label
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = RoundedSelectionRowView()
        rowView.selectionRadius = 5
        rowView.selectionInset = NSEdgeInsets(top: 1, left: 2, bottom: 1, right: 2)
        return rowView
    }

    // MARK: Small layout helpers

    private func makeCard(title: String, symbol: String) -> GlassCardView {
        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.05))
        card.translatesAutoresizingMaskIntoConstraints = false
        let badge = IconBadgeView(symbol: symbol, tint: DevTypeTheme.accent, size: 26, pointSize: 12)
        let header = DevTypeTheme.makeLabel(
            title,
            font: DevTypeTheme.font(13, .bold),
            color: DevTypeTheme.textPrimary
        )
        header.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(badge)
        card.contentView.addSubview(header)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 12),
            badge.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            header.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        card.setAccessibilityLabel(title)
        return card
    }

    /// Stacks `views` below the card header and sizes the card to fit.
    private func stackInCard(_ card: GlassCardView, views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 46),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -14),
            card.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 14)
        ])
        // Wrapping labels and scroll views need a definite width to lay out; the
        // controls (buttons, popups, recorders) keep their intrinsic size so the
        // leading-aligned stack does not stretch them across the card.
        for subview in views {
            if subview is NSTextField || subview is NSScrollView {
                subview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else {
                subview.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            }
        }
    }

    private func makeToggleRow(title: String, toggle: NSSwitch, action: Selector) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
        // §5.1: a bare NSSwitch is announced as "switch, on" with no subject.
        toggle.setAccessibilityLabel(title)

        let label = DevTypeTheme.makeLabel(
            title,
            font: DevTypeTheme.font(12.5, .medium),
            color: DevTypeTheme.textPrimary,
            wrapping: true
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(toggle)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2)
        ])
        return row
    }

    private func pinWidth(of views: [NSView], to stack: NSStackView) {
        for subview in views {
            subview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}
