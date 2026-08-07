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
    case ai
    case advanced

    var title: String {
        switch self {
        case .general: return LocalizationManager.shared.s("prefs.tab.general")
        case .snippets: return LocalizationManager.shared.s("prefs.tab.snippets")
        case .hotkeys: return LocalizationManager.shared.s("prefs.tab.hotkeys")
        case .ai: return LocalizationManager.shared.s("prefs.tab.ai")
        case .advanced: return LocalizationManager.shared.s("prefs.tab.advanced")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .snippets: return "square.stack.3d.up"
        case .hotkeys: return "keyboard"
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
        if let tab { preferences?.select(tab) }
        preferences?.reloadAll()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    init(hotkeyManager: HotkeyManager?) {
        self.hotkeyManager = hotkeyManager
        super.init(nibName: nil, bundle: nil)
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

    private func buildSnippets(into stack: NSStackView) {
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
        hotkeyManager?.applyMacros(macros)
        if hotkeyManager == nil { HotkeyPreferences.saveMacros(macros) }
        macroArgumentField.stringValue = ""
        macroRecorder?.setShortcut(nil)
        reloadHotkeys()
    }

    @objc private func removeMacro() {
        let row = macroTable.selectedRow
        guard macros.indices.contains(row) else { return }
        macros.remove(at: row)
        hotkeyManager?.applyMacros(macros)
        if hotkeyManager == nil { HotkeyPreferences.saveMacros(macros) }
        reloadHotkeys()
    }

    // MARK: AI

    private func buildAI(into stack: NSStackView) {
        let featureAvailable: Bool
        if #available(macOS 26.0, *) {
            featureAvailable = true
        } else {
            featureAvailable = false
        }

        if !featureAvailable {
            let unsupportedCard = makeCard(title: loc.s("prefs.tab.ai"), symbol: "sparkles")
            let note = DevTypeTheme.makeLabel(
                loc.s("prefs.ai.unsupported.hint"),
                font: DevTypeTheme.font(11.5),
                color: DevTypeTheme.textSecondary,
                wrapping: true
            )
            note.translatesAutoresizingMaskIntoConstraints = false
            stackInCard(unsupportedCard, views: [note])
            stack.addArrangedSubview(unsupportedCard)
            pinWidth(of: [unsupportedCard], to: stack)
            return
        }

        // Enable + availability
        let enableCard = makeCard(title: loc.s("prefs.ai.enable.card"), symbol: "sparkles")
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
        stackInCard(enableCard, views: [enableRow, privacyNote, aiAvailabilityLabel])

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
