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
    case home
    case general
    case snippets
    case hotkeys
    case voice
    case ai
    case advanced

    var title: String {
        switch self {
        case .home: return LocalizationManager.shared.s("prefs.tab.home")
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
        case .home: return "house"
        case .general: return "gearshape"
        case .snippets: return "square.stack.3d.up"
        case .hotkeys: return "keyboard"
        case .voice: return "waveform.and.mic"
        case .ai: return "sparkles"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    var subtitle: String {
        switch self {
        case .home: return LocalizationManager.shared.s("prefs.tab.home.subtitle")
        case .general: return LocalizationManager.shared.s("prefs.tab.general.subtitle")
        case .snippets: return LocalizationManager.shared.s("prefs.tab.snippets.subtitle")
        case .hotkeys: return LocalizationManager.shared.s("prefs.tab.hotkeys.subtitle")
        case .voice: return LocalizationManager.shared.s("prefs.tab.voice.subtitle")
        case .ai: return LocalizationManager.shared.s("prefs.tab.ai.subtitle")
        case .advanced: return LocalizationManager.shared.s("prefs.tab.advanced.subtitle")
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
            newWindow.setContentSize(NSSize(width: 800, height: 680))
            newWindow.minSize = NSSize(width: 720, height: 560)
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

/// Marker views let the shared card stack stretch rows and table areas while
/// preserving intrinsic widths for individual controls and buttons.
private final class PreferenceRowView: NSView {}
private final class PreferenceTableAreaView: NSView {}

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
    private var selectedTab: PreferencesTab = .home
    private var panes: [PreferencesTab: NSView] = [:]
    private var paneTitleLabel: NSTextField?
    private var paneSubtitleLabel: NSTextField?
    private var paneIconBadge: IconBadgeView?
    private var tabsShownAtLeastOnce: Set<PreferencesTab> = [.home]
    private var removalButtons: [ObjectIdentifier: CapsuleButton] = [:]
    /// Glanceable engine state pinned to the bottom of the sidebar.
    private var engineStatusPill: PillBadgeView?
    private var homeViewController: HomeViewController?

    // General
    private let openAtLoginSwitch = NSSwitch()
    private let automaticUpdateSwitch = NSSwitch()
    private let updateStatusLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(10.5),
        color: DevTypeTheme.textTertiary,
        wrapping: true
    )
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
    private let macroEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
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
    private let aiRemoveMarkdownSwitch = NSSwitch()
    private let aiTagSuggestionsSwitch = NSSwitch()
    private let repetitionSwitch = NSSwitch()
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
    private let voiceEngines = TranscriptionEngine.allCases
    private let voiceTonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voiceRealTimeTypingSwitch = NSSwitch()
    private let voiceTracingSwitch = NSSwitch()
    private let voiceProofreadSwitch = NSSwitch()
    private let whisperServerButton = NSButton()
    private let whisperModelButton = NSButton()
    private let voiceAutoPunctuateSwitch = NSSwitch()
    private let voiceDisfluenciesSwitch = NSSwitch()
    private let voiceSoundFeedbackSwitch = NSSwitch()
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
    private var voiceMicPermissionPill: PillBadgeView?

    // Voice Engine & API Settings
    private let geminiAPIKeyField = NSSecureTextField()
    private var geminiKeyStatusPill: PillBadgeView?
    private var geminiKeySaveButton: CapsuleButton?
    private var geminiKeyDeleteButton: CapsuleButton?
    private let geminiConfigContainer = NSStackView()
    private let localLLMEndpointField = NSTextField()
    private let localLLMModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let localLLMModelField = NSTextField()
    private var localLLMScanButton: CapsuleButton?
    private var localLLMStatusPill: PillBadgeView?
    private let localLLMConfigContainer = NSStackView()

    init(hotkeyManager: HotkeyManager?) {
        self.hotkeyManager = hotkeyManager
        super.init(nibName: nil, bundle: nil)
    }

    /// Re-point at the live manager. Called by `PreferencesWindowController.show`
    /// on every presentation so a window that is already open never keeps acting
    /// on the manager (or absence of one) it was created with.
    func refreshHotkeyManager(_ manager: HotkeyManager?) {
        hotkeyManager = manager
        homeViewController?.refreshHotkeyManager(manager)
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
        let isFirstPresentation = tabsShownAtLeastOnce.insert(tab).inserted
        selectedTab = tab
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
        if tab == .snippets { stats.refresh() }
        if tab == .advanced { reloadAdvanced() }
        if tab == .ai { reloadAI() }
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
        homeViewController?.refresh()
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
        if tab == .home {
            let homeVC = HomeViewController(store: store, hotkeyManager: hotkeyManager)
            homeViewController = homeVC
            let homeView = homeVC.view
            // The Home controller owns an NSScrollView, but its view is embedded in this
            // constraint-managed host just like every other Preferences pane.
            homeView.translatesAutoresizingMaskIntoConstraints = false
            return homeView
        }

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
        case .home: break
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

        let mutedArea = makeTableArea(
            table: mutedTable,
            accessibilityLabel: loc.s("prefs.general.mutedApps"),
            columnIdentifier: "muted",
            emptyLabel: mutedEmptyLabel,
            allowsMultipleSelection: true
        )

        let muteFrontmostButton = CapsuleButton(
            title: loc.s("prefs.general.muteFrontmost"),
            symbol: "speaker.slash",
            style: .secondary,
            target: self,
            action: #selector(muteFrontmost)
        )
        let unmuteButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(unmuteSelected)
        )
        bindRemovalButton(unmuteButton, to: mutedTable)
        let mutedButtons = NSStackView(views: [muteFrontmostButton, unmuteButton])
        mutedButtons.orientation = .horizontal
        mutedButtons.spacing = 8
        mutedButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(mutedCard, views: [mutedHint, mutedArea, mutedButtons])

        // Updates (§7.5). Off by default — the toggle governs only whether DevType checks on
        // its own; the menu bar's "Check for Updates…" works regardless.
        let updatesCard = makeCard(title: loc.s("prefs.general.updates"), symbol: "arrow.down.circle")
        let updatesRow = makeToggleRow(
            title: loc.s("prefs.general.updates.auto"),
            toggle: automaticUpdateSwitch,
            action: #selector(automaticUpdateCheckChanged)
        )
        let updatesNote = DevTypeTheme.makeLabel(
            loc.s("prefs.general.updates.note"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        updatesNote.translatesAutoresizingMaskIntoConstraints = false
        updateStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        let checkNowButton = CapsuleButton(
            title: loc.s("prefs.general.updates.checkNow"),
            symbol: "arrow.clockwise",
            style: .secondary,
            target: self,
            action: #selector(checkForUpdatesNow)
        )
        let updatesButtons = NSStackView(views: [checkNowButton])
        updatesButtons.orientation = .horizontal
        updatesButtons.spacing = 8
        updatesButtons.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(updatesCard, views: [updatesRow, updatesNote, updateStatusLabel, updatesButtons])

        stack.addArrangedSubview(startupCard)
        stack.addArrangedSubview(languageCard)
        stack.addArrangedSubview(updatesCard)
        stack.addArrangedSubview(mutedCard)
        pinWidth(of: [startupCard, languageCard, updatesCard, mutedCard], to: stack)
    }

    private func reloadGeneral() {
        openAtLoginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        automaticUpdateSwitch.state = UpdatePreferences.automaticCheckEnabled ? .on : .off
        refreshUpdateStatusLabel()
        let current = loc.language.rawValue
        for (index, language) in AppLanguage.allCases.enumerated()
        where language.rawValue == current {
            languagePopup.selectItem(at: index)
        }
        mutedApps = AppMuteStore.shared.allMuted().sorted()
        mutedTable.reloadData()
        mutedEmptyLabel.stringValue = mutedApps.isEmpty ? loc.s("prefs.general.mutedApps.empty") : ""
        mutedEmptyLabel.isHidden = !mutedApps.isEmpty
        refreshRemovalButton(for: mutedTable)
    }

    @objc private func automaticUpdateCheckChanged() {
        UpdatePreferences.automaticCheckEnabled = automaticUpdateSwitch.state == .on
        refreshUpdateStatusLabel()
    }

    @objc private func checkForUpdatesNow() {
        // Reports every outcome, including failures — the user asked.
        UpdateFlow.checkManually(window: view.window)
        // The check is async; refresh once it has had a chance to write its timestamp.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshUpdateStatusLabel()
        }
    }

    /// Shows the running version plus when a check last *succeeded*.
    ///
    /// "Never checked" is shown until one completes, so a run of failed checks never renders as
    /// a recent successful one.
    private func refreshUpdateStatusLabel() {
        let version = AppVersion.current()?.rawValue ?? "—"
        var lines = [loc.s("prefs.general.updates.currentVersion", version)]
        if let last = UpdatePreferences.lastSuccessfulCheck {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append(loc.s("prefs.general.updates.lastChecked", formatter.string(from: last)))
        } else {
            lines.append(loc.s("prefs.general.updates.never"))
        }
        updateStatusLabel.stringValue = lines.joined(separator: " · ")
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
        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
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

        let macroArea = makeTableArea(
            table: macroTable,
            accessibilityLabel: loc.s("prefs.hotkeys.macros"),
            columnIdentifier: "macro",
            emptyLabel: macroEmptyLabel,
            rowHeight: 24
        )

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

        let addMacroButton = CapsuleButton(
            title: loc.s("prefs.hotkeys.macros.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(addMacro)
        )
        let removeMacroButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(removeMacro)
        )
        bindRemovalButton(removeMacroButton, to: macroTable)
        let macroButtons = NSStackView(views: [addMacroButton, removeMacroButton])
        macroButtons.orientation = .horizontal
        macroButtons.spacing = 8
        macroButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(macroCard, views: [macroHint, macroArea, editorRow, macroButtons])

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
        macroEmptyLabel.stringValue = macros.isEmpty ? loc.s("prefs.hotkeys.macros.empty") : ""
        macroEmptyLabel.isHidden = !macros.isEmpty
        refreshRemovalButton(for: macroTable)
    }

    private func applyInlineShortcut(_ shortcut: DevTypeShortcut?) {
        guard let shortcut else { return }
        guard let manager = hotkeyManager else {
            HotkeyPreferences.inlineSearchShortcut = shortcut
            reloadHotkeys()
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
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
        if hotkeyManager == nil {
            HotkeyPreferences.saveMacros(macros)
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
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
        if hotkeyManager == nil {
            HotkeyPreferences.saveMacros(macros)
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
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

        // 1. Models Card / Engine Configuration Card
        let modelsCard = makeCard(title: loc.s("prefs.voice.models.card"), symbol: "waveform.and.mic")
        let modelsHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.models.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        modelsHint.translatesAutoresizingMaskIntoConstraints = false

        // Active transcription engine selector row
        voiceModelPopup.translatesAutoresizingMaskIntoConstraints = false
        voiceModelPopup.removeAllItems()
        for engine in TranscriptionEngine.allCases {
            voiceModelPopup.addItem(withTitle: engine.displayName)
            voiceModelPopup.lastItem?.representedObject = engine.rawValue
        }
        voiceModelPopup.target = self
        voiceModelPopup.action = #selector(voiceModelPopupChanged(_:))
        voiceModelPopup.setAccessibilityLabel(loc.s("prefs.voice.activeModel"))

        let activeModelRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.activeModel"),
            control: voiceModelPopup,
            font: DevTypeTheme.font(12, .semibold)
        )

        let speechModelsLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.speechModels"),
            font: DevTypeTheme.font(11.5, .semibold),
            color: DevTypeTheme.textPrimary
        )
        let speechModelsInventory = makeVoiceRecognitionModelInventory()

        let speechModelsHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.speechModels.hint"),
            font: DevTypeTheme.font(10),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )

        // Gemini API Configuration Box
        geminiConfigContainer.orientation = .vertical
        geminiConfigContainer.alignment = .leading
        geminiConfigContainer.spacing = 6
        geminiConfigContainer.translatesAutoresizingMaskIntoConstraints = false

        let geminiLabel = DevTypeTheme.makeLabel("Gemini API Key (Securely stored in macOS Keychain):", font: DevTypeTheme.font(11.5, .medium), color: DevTypeTheme.textPrimary)

        geminiAPIKeyField.translatesAutoresizingMaskIntoConstraints = false
        geminiAPIKeyField.font = DevTypeTheme.font(12)
        geminiAPIKeyField.placeholderString = GeminiAPIKeyStore.hasKey ? "Key Saved (••••••••••••••••)" : "Paste Gemini API Key (AIzaSy...)"
        geminiAPIKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let keyPill = PillBadgeView(text: GeminiAPIKeyStore.hasKey ? "Key Configured" : "No Key Set", tint: GeminiAPIKeyStore.hasKey ? DevTypeTheme.statusGreen : DevTypeTheme.statusOrange, showsDot: true)
        keyPill.translatesAutoresizingMaskIntoConstraints = false
        geminiKeyStatusPill = keyPill

        let saveBtn = CapsuleButton(
            title: "Save & Validate",
            symbol: "key.fill",
            style: .primary,
            target: self,
            action: #selector(geminiKeySaveClicked)
        )
        geminiKeySaveButton = saveBtn

        let deleteBtn = CapsuleButton(
            title: "Delete",
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(geminiKeyDeleteClicked)
        )
        geminiKeyDeleteButton = deleteBtn

        let geminiActionsRow = NSStackView(views: [geminiAPIKeyField, keyPill, saveBtn, deleteBtn])
        geminiActionsRow.orientation = .horizontal
        geminiActionsRow.spacing = 8
        geminiActionsRow.alignment = .centerY
        geminiActionsRow.translatesAutoresizingMaskIntoConstraints = false

        let geminiSubHint = DevTypeTheme.makeLabel(
            "Uses gemini-3.5-transcribe via streaming URLSession. Get an API key from Google AI Studio (aistudio.google.com).",
            font: DevTypeTheme.font(10),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )

        geminiConfigContainer.addArrangedSubview(geminiLabel)
        geminiConfigContainer.addArrangedSubview(geminiActionsRow)
        geminiConfigContainer.addArrangedSubview(geminiSubHint)

        // Local LLM Configuration Box
        localLLMConfigContainer.orientation = .vertical
        localLLMConfigContainer.alignment = .leading
        localLLMConfigContainer.spacing = 6
        localLLMConfigContainer.translatesAutoresizingMaskIntoConstraints = false

        let localEndpointLabel = DevTypeTheme.makeLabel("Local LLM Server Endpoint:", font: DevTypeTheme.font(11.5, .medium), color: DevTypeTheme.textPrimary)

        localLLMEndpointField.translatesAutoresizingMaskIntoConstraints = false
        localLLMEndpointField.font = DevTypeTheme.font(12)
        localLLMEndpointField.placeholderString = "http://localhost:11434/v1/chat/completions"
        localLLMEndpointField.target = self
        localLLMEndpointField.action = #selector(localLLMEndpointChanged)
        localLLMEndpointField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let scanBtn = CapsuleButton(
            title: loc.s("prefs.voice.cleanupModels.scan"),
            symbol: "arrow.clockwise",
            style: .secondary,
            target: self,
            action: #selector(scanLocalModelsClicked)
        )
        localLLMScanButton = scanBtn

        let statusPill = PillBadgeView(text: "Local Endpoint", tint: DevTypeTheme.statusGray, showsDot: false)
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        localLLMStatusPill = statusPill

        let endpointRow = NSStackView(views: [localLLMEndpointField, scanBtn, statusPill])
        endpointRow.orientation = .horizontal
        endpointRow.spacing = 8
        endpointRow.alignment = .centerY
        endpointRow.translatesAutoresizingMaskIntoConstraints = false

        let localModelLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.cleanupModels"),
            font: DevTypeTheme.font(11.5, .medium),
            color: DevTypeTheme.textPrimary
        )

        localLLMModelPopup.translatesAutoresizingMaskIntoConstraints = false
        localLLMModelPopup.target = self
        localLLMModelPopup.action = #selector(localLLMModelPopupChanged(_:))
        localLLMModelPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        localLLMModelField.translatesAutoresizingMaskIntoConstraints = false
        localLLMModelField.font = DevTypeTheme.font(12)
        localLLMModelField.placeholderString = "Custom model identifier"
        localLLMModelField.target = self
        localLLMModelField.action = #selector(localLLMModelChanged)
        localLLMModelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        localLLMModelField.isHidden = true

        let modelPickerRow = NSStackView(views: [localLLMModelPopup, localLLMModelField])
        modelPickerRow.orientation = .horizontal
        modelPickerRow.spacing = 8
        modelPickerRow.alignment = .centerY
        modelPickerRow.translatesAutoresizingMaskIntoConstraints = false

        let localSubHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.cleanupModels.hint"),
            font: DevTypeTheme.font(10),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )

        localLLMConfigContainer.addArrangedSubview(localEndpointLabel)
        localLLMConfigContainer.addArrangedSubview(endpointRow)
        localLLMConfigContainer.addArrangedSubview(localModelLabel)
        localLLMConfigContainer.addArrangedSubview(modelPickerRow)
        localLLMConfigContainer.addArrangedSubview(localSubHint)

        let modelCards: [NSView] = [
            modelsHint,
            activeModelRow,
            speechModelsLabel,
            speechModelsInventory,
            speechModelsHint,
            DevTypeTheme.makeHairline(),
            geminiConfigContainer,
            localLLMConfigContainer
        ]
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

        let toneRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.tone"),
            control: voiceTonePopup,
            font: DevTypeTheme.font(12, .semibold)
        )

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
        let proofreadRow = makeToggleRow(
            title: loc.s("prefs.voice.proofreadBeforeInsert"),
            toggle: voiceProofreadSwitch,
            action: #selector(voiceProofreadChanged)
        )

        // Diagnostics. Off by default and last in the card, because switching it on starts
        // recording what the user dictates — it exists to capture a problem, not to run.
        let tracingRow = makeToggleRow(
            title: loc.s("prefs.voice.tracing"),
            toggle: voiceTracingSwitch,
            action: #selector(voiceTracingChanged)
        )
        // Local Whisper server control. Placed with the other voice controls rather than
        // buried in a sheet: it is something the user starts before dictating and stops
        // afterwards, not a one-time setup step.
        whisperServerButton.title = loc.s("prefs.voice.whisper.start")
        whisperServerButton.bezelStyle = .rounded
        whisperServerButton.controlSize = .small
        whisperServerButton.target = self
        whisperServerButton.action = #selector(toggleWhisperServer)
        whisperServerButton.translatesAutoresizingMaskIntoConstraints = false

        whisperModelButton.title = loc.s("prefs.voice.whisper.getModel")
        whisperModelButton.bezelStyle = .rounded
        whisperModelButton.controlSize = .small
        whisperModelButton.target = self
        whisperModelButton.action = #selector(downloadWhisperModel)
        whisperModelButton.translatesAutoresizingMaskIntoConstraints = false

        let whisperRow = PreferenceRowView()
        whisperRow.translatesAutoresizingMaskIntoConstraints = false
        let whisperLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.whisper.server"),
            font: DevTypeTheme.font(12.5, .medium),
            color: DevTypeTheme.textPrimary,
            wrapping: true
        )
        whisperLabel.translatesAutoresizingMaskIntoConstraints = false
        whisperRow.addSubview(whisperLabel)
        whisperRow.addSubview(whisperModelButton)
        whisperRow.addSubview(whisperServerButton)
        NSLayoutConstraint.activate([
            whisperLabel.leadingAnchor.constraint(equalTo: whisperRow.leadingAnchor),
            whisperLabel.centerYAnchor.constraint(equalTo: whisperRow.centerYAnchor),
            whisperLabel.trailingAnchor.constraint(lessThanOrEqualTo: whisperModelButton.leadingAnchor, constant: -12),
            whisperModelButton.trailingAnchor.constraint(equalTo: whisperServerButton.leadingAnchor, constant: -8),
            whisperModelButton.centerYAnchor.constraint(equalTo: whisperRow.centerYAnchor),
            whisperServerButton.trailingAnchor.constraint(equalTo: whisperRow.trailingAnchor),
            whisperServerButton.topAnchor.constraint(equalTo: whisperRow.topAnchor, constant: 2),
            whisperServerButton.bottomAnchor.constraint(equalTo: whisperRow.bottomAnchor, constant: -2)
        ])

        let revealTraceButton = NSButton(
            title: loc.s("prefs.voice.tracing.reveal"),
            target: self,
            action: #selector(revealVoiceTrace)
        )
        revealTraceButton.bezelStyle = .rounded
        revealTraceButton.controlSize = .small
        revealTraceButton.translatesAutoresizingMaskIntoConstraints = false

        let revealRow = PreferenceRowView()
        revealRow.translatesAutoresizingMaskIntoConstraints = false
        revealRow.addSubview(revealTraceButton)
        NSLayoutConstraint.activate([
            revealTraceButton.leadingAnchor.constraint(equalTo: revealRow.leadingAnchor),
            revealTraceButton.topAnchor.constraint(equalTo: revealRow.topAnchor, constant: 2),
            revealTraceButton.bottomAnchor.constraint(equalTo: revealRow.bottomAnchor, constant: -2)
        ])

        stackInCard(optionsCard, views: [
            toneRow, realTimeTypingRow, disfluencyRow, autoPunctuateRow, proofreadRow,
            soundFeedbackRow, whisperRow, tracingRow, revealRow
        ])
        refreshWhisperServerButton()

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

        let dictionaryArea = makeTableArea(
            table: voiceDictionaryTable,
            accessibilityLabel: loc.s("prefs.voice.dict.card"),
            columnIdentifier: "voiceDictSpoken",
            emptyLabel: voiceDictionaryEmptyLabel
        )
        configureVoiceDictionaryTable()

        voiceDictSpokenField.translatesAutoresizingMaskIntoConstraints = false
        voiceDictSpokenField.placeholderString = loc.s("prefs.voice.dict.spokenPlaceholder")
        voiceDictSpokenField.font = DevTypeTheme.font(12)
        voiceDictSpokenField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        voiceDictReplacementField.translatesAutoresizingMaskIntoConstraints = false
        voiceDictReplacementField.placeholderString = loc.s("prefs.voice.dict.replacementPlaceholder")
        voiceDictReplacementField.font = DevTypeTheme.font(12)
        voiceDictReplacementField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        let addDictionaryButton = CapsuleButton(
            title: loc.s("common.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(voiceDictAddEntry)
        )
        let removeDictionaryButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(voiceDictRemoveEntry)
        )
        bindRemovalButton(removeDictionaryButton, to: voiceDictionaryTable)
        let dictButtons = NSStackView(views: [
            voiceDictSpokenField,
            voiceDictReplacementField,
            addDictionaryButton,
            removeDictionaryButton
        ])
        dictButtons.orientation = .horizontal
        dictButtons.spacing = 8
        dictButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(dictCard, views: [dictHint, dictionaryArea, dictButtons])

        // 5. AI Voice Triggers & Rewrites Card
        let triggersCard = makeCard(title: loc.s("prefs.voice.triggers.card"), symbol: "wand.and.stars")

        let disclaimerPill = PillBadgeView(text: "Apple Intelligence", tint: DevTypeTheme.accent, showsDot: true)
        disclaimerPill.translatesAutoresizingMaskIntoConstraints = false

        let disclaimerText = DevTypeTheme.makeLabel(
            loc.s("ai.availability.requirement"),
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.textSecondary,
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

        let triggersArea = makeTableArea(
            table: voiceTriggersTable,
            accessibilityLabel: loc.s("prefs.voice.triggers.card"),
            columnIdentifier: "voiceTriggerPhrase",
            emptyLabel: voiceTriggersEmptyLabel,
            height: 120
        )
        configureVoiceTriggersTable()

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

        let addTriggerButton = CapsuleButton(
            title: loc.s("common.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(voiceTriggerAddEntry)
        )
        let removeTriggerButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(voiceTriggerRemoveEntry)
        )
        bindRemovalButton(removeTriggerButton, to: voiceTriggersTable)
        let triggerControls = NSStackView(views: [
            voiceTriggerPhraseField,
            voiceTriggerActionPopup,
            addTriggerButton,
            removeTriggerButton
        ])
        triggerControls.orientation = .horizontal
        triggerControls.spacing = 8
        triggerControls.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(triggersCard, views: [disclaimerBox, triggersHint, triggersArea, triggerControls])

        for card in [permCard, modelsCard, optionsCard, hotkeyCard, dictCard, triggersCard] {
            stack.addArrangedSubview(card)
        }
        pinWidth(of: [permCard, modelsCard, optionsCard, hotkeyCard, dictCard, triggersCard], to: stack)
    }

    private func configureVoiceDictionaryTable() {
        guard let spokenColumn = voiceDictionaryTable.tableColumns.first else { return }
        spokenColumn.title = loc.s("prefs.voice.dict.column.spoken")
        spokenColumn.minWidth = 160
        spokenColumn.width = 250
        spokenColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        let replacementColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("voiceDictReplacement")
        )
        replacementColumn.title = loc.s("prefs.voice.dict.column.replacement")
        replacementColumn.minWidth = 160
        replacementColumn.width = 250
        replacementColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        voiceDictionaryTable.addTableColumn(replacementColumn)
        voiceDictionaryTable.headerView = NSTableHeaderView()
        voiceDictionaryTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        voiceDictionaryTable.allowsColumnReordering = false
    }

    private func configureVoiceTriggersTable() {
        guard let phraseColumn = voiceTriggersTable.tableColumns.first else { return }
        phraseColumn.title = loc.s("prefs.voice.triggers.column.phrase")
        phraseColumn.minWidth = 180
        phraseColumn.width = 260
        phraseColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        let actionColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("voiceTriggerAction")
        )
        actionColumn.title = loc.s("prefs.voice.triggers.column.action")
        actionColumn.minWidth = 160
        actionColumn.width = 240
        actionColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        voiceTriggersTable.addTableColumn(actionColumn)
        voiceTriggersTable.headerView = NSTableHeaderView()
        voiceTriggersTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        voiceTriggersTable.allowsColumnReordering = false
    }

    private func makeVoiceRecognitionModelInventory() -> NSView {
        let inventory = PreferenceRowView()
        inventory.translatesAutoresizingMaskIntoConstraints = false
        inventory.wantsLayer = true
        inventory.layer?.cornerRadius = DevTypeTheme.Radius.control
        inventory.layer?.backgroundColor = DevTypeTheme.contrastOverlay(0.035).cgColor
        inventory.layer?.borderWidth = 1
        inventory.layer?.borderColor = DevTypeTheme.hairline.cgColor

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        inventory.addSubview(rows)

        for (index, engine) in voiceEngines.enumerated() {
            let presentation = voiceEngineStatus(for: engine)
            let name = DevTypeTheme.makeLabel(
                engine.displayName,
                font: DevTypeTheme.font(11, .medium),
                color: DevTypeTheme.textPrimary
            )
            name.lineBreakMode = .byTruncatingTail

            let source = DevTypeTheme.makeLabel(
                loc.s(Self.sourceKey(for: engine)),
                font: DevTypeTheme.font(10.5),
                color: DevTypeTheme.textSecondary
            )
            source.widthAnchor.constraint(equalToConstant: 76).isActive = true

            let status = DevTypeTheme.makeLabel(
                presentation.text,
                font: DevTypeTheme.font(10.5, .medium),
                color: presentation.color
            )
            status.lineBreakMode = .byTruncatingTail
            status.toolTip = presentation.detail
            status.widthAnchor.constraint(greaterThanOrEqualToConstant: 176).isActive = true

            let row = NSStackView(views: [name, source, status])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 32).isActive = true
            row.setAccessibilityLabel("\(name.stringValue), \(source.stringValue), \(status.stringValue)")
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            status.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true

            if index < voiceEngines.count - 1 {
                let separator = DevTypeTheme.makeHairline()
                rows.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: inventory.topAnchor, constant: 2),
            rows.leadingAnchor.constraint(equalTo: inventory.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: inventory.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: inventory.bottomAnchor, constant: -2)
        ])
        return inventory
    }

    private func reloadVoice() {
        guard panes[.voice] != nil else { return }

        let micGranted = DurableVoiceCapture.checkMicrophonePermission()
        voiceMicPermissionPill?.update(
            text: micGranted ? loc.s("status.active") : loc.s("status.needsPermissions"),
            tint: micGranted ? DevTypeTheme.statusGreen : DevTypeTheme.accent
        )

        let currentEngine = VoicePreferences.transcriptionEngine
        if let index = TranscriptionEngine.allCases.firstIndex(of: currentEngine) {
            voiceModelPopup.selectItem(at: index)
        }

        let hasGeminiKey = GeminiAPIKeyStore.hasKey
        geminiKeyStatusPill?.update(
            text: hasGeminiKey ? "Key Configured" : "No Key Set",
            tint: hasGeminiKey ? DevTypeTheme.statusGreen : DevTypeTheme.statusOrange
        )
        if hasGeminiKey && geminiAPIKeyField.stringValue.isEmpty {
            geminiAPIKeyField.placeholderString = "Key Saved (••••••••••••••••)"
        } else if !hasGeminiKey {
            geminiAPIKeyField.placeholderString = "Paste Gemini API Key (AIzaSy...)"
        }

        geminiConfigContainer.isHidden = currentEngine != .gemini
        localLLMConfigContainer.isHidden = currentEngine != .localLLM

        if localLLMEndpointField.stringValue.isEmpty {
            localLLMEndpointField.stringValue = VoicePreferences.localLLMEndpoint.absoluteString
        }
        refreshLocalLLMModelsPopup()

        let currentTone = VoicePreferences.tone
        if let index = DictationTone.allCases.firstIndex(of: currentTone) {
            voiceTonePopup.selectItem(at: index)
        }

        voiceRealTimeTypingSwitch.state = VoicePreferences.isRealTimeTypingEnabled ? .on : .off
        voiceTracingSwitch.state = VoicePreferences.isVoiceTracingEnabled ? .on : .off
        voiceProofreadSwitch.state = VoicePreferences.isProofreadBeforeInsertEnabled ? .on : .off
        voiceAutoPunctuateSwitch.state = VoicePreferences.isAutoPunctuateEnabled ? .on : .off
        voiceDisfluenciesSwitch.state = VoicePreferences.isRemoveDisfluenciesEnabled ? .on : .off
        voiceSoundFeedbackSwitch.state = VoicePreferences.isSoundFeedbackEnabled ? .on : .off

        voiceShortcutRecorder?.setShortcut(HotkeyPreferences.voiceShortcut)

        let dict = VoicePreferences.customDictionary
        voiceDictEntries = dict.map { (spoken: $0.key, replacement: $0.value) }.sorted { $0.spoken < $1.spoken }
        voiceDictionaryTable.reloadData()
        voiceDictionaryEmptyLabel.stringValue = voiceDictEntries.isEmpty ? loc.s("prefs.voice.dict.empty") : ""
        voiceDictionaryEmptyLabel.isHidden = !voiceDictEntries.isEmpty
        refreshRemovalButton(for: voiceDictionaryTable)

        let triggers = VoicePreferences.customVoiceTriggers
        voiceTriggerEntries = triggers.map { (phrase: $0.key, action: $0.value) }.sorted { $0.phrase < $1.phrase }
        voiceTriggersTable.reloadData()
        voiceTriggersEmptyLabel.stringValue = voiceTriggerEntries.isEmpty ? loc.s("prefs.voice.triggers.empty") : ""
        voiceTriggersEmptyLabel.isHidden = !voiceTriggerEntries.isEmpty
        refreshRemovalButton(for: voiceTriggersTable)
    }

    /// Reflects who owns the running server, if anyone. Three states, because they need
    /// three different actions: ours (stop it), someone else's (leave it alone), none
    /// (start one).
    private func refreshWhisperServerButton() {
        // The model is the prerequisite: without it Start can only report why it failed.
        let hasModel = WhisperServerSetup.hasModel()
        whisperModelButton.isHidden = hasModel
        whisperModelButton.isEnabled = !hasModel
        if !hasModel { whisperModelButton.title = loc.s("prefs.voice.whisper.getModel") }

        if WhisperServerController.shared.isManagedByApp {
            whisperServerButton.title = loc.s("prefs.voice.whisper.stop")
            whisperServerButton.isEnabled = true
            return
        }
        whisperServerButton.title = loc.s("prefs.voice.whisper.start")
        whisperServerButton.isEnabled = true

        Task { @MainActor in
            let external = await WhisperServerSetup.isReachable()
            guard !WhisperServerController.shared.isManagedByApp else { return }
            if external {
                // Started outside DevType — usable, but not ours to stop.
                self.whisperServerButton.title = self.loc.s("prefs.voice.whisper.external")
                self.whisperServerButton.isEnabled = false
            }
        }
    }

    @objc private func downloadWhisperModel() {
        whisperModelButton.isEnabled = false
        whisperModelButton.title = loc.s("prefs.voice.whisper.downloading")

        Task { @MainActor in
            let result = await WhisperServerController.shared.downloadModel { fraction in
                DispatchQueue.main.async {
                    self.whisperModelButton.title = "\(Int(fraction * 100))%"
                }
            }
            switch result {
            case .success:
                break
            case .failure(let failure):
                DevTypeAlert.warn(
                    title: self.loc.s("prefs.voice.whisper.modelFailed"),
                    message: failure.userMessage,
                    window: self.view.window
                )
            }
            self.refreshWhisperServerButton()
        }
    }

    @objc private func toggleWhisperServer() {
        if WhisperServerController.shared.isManagedByApp {
            WhisperServerController.shared.stop()
            refreshWhisperServerButton()
            return
        }

        whisperServerButton.isEnabled = false
        whisperServerButton.title = loc.s("prefs.voice.whisper.starting")

        Task { @MainActor in
            let result = await WhisperServerController.shared.start()
            switch result {
            case .success:
                break
            case .failure(let failure):
                DevTypeAlert.warn(
                    title: self.loc.s("prefs.voice.whisper.failed"),
                    message: failure.userMessage,
                    window: self.view.window
                )
            }
            self.refreshWhisperServerButton()
        }
    }

    @objc private func voiceProofreadChanged() {
        VoicePreferences.isProofreadBeforeInsertEnabled = voiceProofreadSwitch.state == .on
    }

    @objc private func voiceTracingChanged() {
        let enabled = voiceTracingSwitch.state == .on
        VoicePreferences.isVoiceTracingEnabled = enabled
        // Starting a fresh capture is the point; a trace mixed with an earlier run is far
        // harder to read.
        if enabled { VoiceDiagnosticsRecorder.shared.clear() }
    }

    @objc private func revealVoiceTrace() {
        let url = VoiceDiagnosticsRecorder.traceURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            DevTypeAlert.info(
                title: loc.s("prefs.voice.tracing.empty.title"),
                message: loc.s("prefs.voice.tracing.empty.message"),
                window: view.window
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
        DurableVoiceCapture.requestMicrophonePermission { [weak self] _ in
            DispatchQueue.main.async {
                self?.reloadVoice()
            }
        }
    }

    @objc private func openMicrophoneSettingsClicked() {
        SettingsDeepLinker.shared.open(for: .microphone)
    }

    @objc private func voiceModelPopupChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let engine = TranscriptionEngine(rawValue: raw) else { return }
        VoicePreferences.transcriptionEngine = engine
        reloadVoice()
    }

    @objc private func geminiKeySaveClicked() {
        let key = geminiAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        geminiKeySaveButton?.isEnabled = false
        geminiKeySaveButton?.title = "Validating..."
        geminiKeyStatusPill?.update(text: "Validating Key...", tint: DevTypeTheme.accent)

        Task {
            let result = await GeminiTranscriptionClient.shared.validateAPIKeyDetailed(key)
            await MainActor.run {
                if result.isValid {
                    try? GeminiAPIKeyStore.save(key)
                    self.geminiAPIKeyField.stringValue = ""
                    self.geminiAPIKeyField.placeholderString = "Key Saved (••••••••••••••••)"
                    self.geminiKeyStatusPill?.update(text: result.userMessage, tint: DevTypeTheme.statusGreen)
                } else {
                    self.geminiKeyStatusPill?.update(text: result.userMessage, tint: DevTypeTheme.statusOrange)
                }
                self.geminiKeySaveButton?.title = "Save & Validate"
                self.geminiKeySaveButton?.isEnabled = true
                self.reloadVoice()
            }
        }
    }

    @objc private func geminiKeyDeleteClicked() {
        try? GeminiAPIKeyStore.delete()
        geminiAPIKeyField.stringValue = ""
        geminiAPIKeyField.placeholderString = "Paste Gemini API Key (AIzaSy...)"
        reloadVoice()
    }

    @objc private func localLLMEndpointChanged() {
        let text = localLLMEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, let url = URL(string: text) {
            VoicePreferences.localLLMEndpoint = url
        }
    }

    @objc private func localLLMModelChanged() {
        let text = localLLMModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            VoicePreferences.localLLMModel = text
        }
    }

    @objc private func localLLMModelPopupChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        if raw == "__custom__" {
            localLLMModelField.isHidden = false
            localLLMModelField.stringValue = VoicePreferences.localLLMModel
        } else {
            localLLMModelField.isHidden = true
            VoicePreferences.localLLMModel = raw
            localLLMModelField.stringValue = raw
        }
    }

    @objc private func scanLocalModelsClicked() {
        localLLMScanButton?.isEnabled = false
        localLLMScanButton?.title = loc.s("prefs.voice.cleanupModels.scanning")
        localLLMStatusPill?.update(
            text: loc.s("prefs.voice.cleanupModels.scanning"),
            tint: DevTypeTheme.accent
        )

        let endpoint = VoicePreferences.localLLMEndpoint
        Task {
            let discovered = await LocalLLMModelCatalog.shared.fetchAvailableLocalModels(endpoint: endpoint)
            await MainActor.run {
                self.localLLMScanButton?.isEnabled = true
                self.localLLMScanButton?.title = self.loc.s("prefs.voice.cleanupModels.scan")
                if discovered.isEmpty {
                    self.localLLMStatusPill?.update(
                        text: self.loc.s("prefs.voice.cleanupModels.none"),
                        tint: DevTypeTheme.statusOrange
                    )
                } else {
                    self.localLLMStatusPill?.update(
                        text: self.loc.s("prefs.voice.cleanupModels.found", discovered.count),
                        tint: DevTypeTheme.statusGreen
                    )
                }
                self.refreshLocalLLMModelsPopup(additionalDiscoveredModels: discovered)
            }
        }
    }

    private func refreshLocalLLMModelsPopup(additionalDiscoveredModels: [String] = []) {
        let currentSelectedModel = VoicePreferences.localLLMModel
        localLLMModelPopup.removeAllItems()

        // 1. Preset recommended models
        let presets: [(title: String, id: String)] = [
            ("Llama 3.2 (3B - Fast & Recommended)", "llama3.2"),
            ("Llama 3.2 1B (1B - Ultra Fast)", "llama3.2:1b"),
            ("Qwen 2.5 (3B)", "qwen2.5:3b"),
            ("Qwen 2.5 (7B)", "qwen2.5:7b"),
            ("Phi-3.5 (3.8B)", "phi3.5"),
            ("Mistral (7B)", "mistral"),
            ("Gemma 2 (2B)", "gemma2:2b"),
            ("DeepSeek R1 (1.5B)", "deepseek-r1:1.5b"),
            ("DeepSeek R1 (7B)", "deepseek-r1:7b")
        ]

        for p in presets {
            localLLMModelPopup.addItem(withTitle: p.title)
            localLLMModelPopup.lastItem?.representedObject = p.id
        }

        // 2. Add dynamically discovered models from Ollama / LM Studio (if not already in presets)
        var addedSeparator = false
        for modelName in additionalDiscoveredModels {
            if !presets.contains(where: { $0.id == modelName }) {
                if !addedSeparator {
                    localLLMModelPopup.menu?.addItem(NSMenuItem.separator())
                    addedSeparator = true
                }
                localLLMModelPopup.addItem(withTitle: "\(modelName) (Installed)")
                localLLMModelPopup.lastItem?.representedObject = modelName
            }
        }

        // 3. Custom model option
        localLLMModelPopup.menu?.addItem(NSMenuItem.separator())
        localLLMModelPopup.addItem(withTitle: "Custom Model Identifier...")
        localLLMModelPopup.lastItem?.representedObject = "__custom__"

        // Select the active model
        if let matchIndex = localLLMModelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == currentSelectedModel }) {
            localLLMModelPopup.selectItem(at: matchIndex)
            localLLMModelField.isHidden = true
        } else {
            // It's a custom model
            localLLMModelPopup.selectItem(at: localLLMModelPopup.numberOfItems - 1)
            localLLMModelField.isHidden = false
            localLLMModelField.stringValue = currentSelectedModel
        }
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

    private func applyVoiceShortcut(_ shortcut: DevTypeShortcut?) {
        guard let shortcut else { return }
        if let manager = hotkeyManager {
            manager.applyVoiceShortcut(shortcut)
        } else {
            HotkeyPreferences.voiceShortcut = shortcut
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
        reloadVoice()
    }

    @objc private func resetVoiceShortcut() {
        HotkeyPreferences.resetVoiceShortcut()
        if let manager = hotkeyManager {
            manager.applyVoiceShortcut(HotkeyPreferences.voiceShortcut)
        } else {
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
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
            let disclaimerPill = PillBadgeView(text: "Apple Intelligence", tint: DevTypeTheme.statusOrange, showsDot: true)
            disclaimerPill.translatesAutoresizingMaskIntoConstraints = false

            let note = DevTypeTheme.makeLabel(
                loc.s("ai.availability.requirement"),
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
        let disclaimerPill = PillBadgeView(text: "Apple Intelligence", tint: DevTypeTheme.accent, showsDot: true)
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
        let markdownRow = makeToggleRow(
            title: loc.s("prefs.ai.removeMarkdown"),
            toggle: aiRemoveMarkdownSwitch,
            action: #selector(aiRemoveMarkdownChanged)
        )
        let markdownHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.removeMarkdown.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        markdownHint.translatesAutoresizingMaskIntoConstraints = false
        let tagRow = makeToggleRow(
            title: loc.s("prefs.ai.tagSuggestions"),
            toggle: aiTagSuggestionsSwitch,
            action: #selector(aiTagSuggestionsChanged)
        )
        let tagHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.tagSuggestions.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        tagHint.translatesAutoresizingMaskIntoConstraints = false
        let repetitionRow = makeToggleRow(
            title: loc.s("prefs.repetition"),
            toggle: repetitionSwitch,
            action: #selector(repetitionChanged)
        )
        let repetitionHint = DevTypeTheme.makeLabel(
            loc.s("prefs.repetition.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        repetitionHint.translatesAutoresizingMaskIntoConstraints = false
        let forgetButton = NSButton(
            title: loc.s("prefs.repetition.forget"),
            target: self,
            action: #selector(repetitionForget)
        )
        forgetButton.translatesAutoresizingMaskIntoConstraints = false
        forgetButton.bezelStyle = .rounded
        var modeRows: [NSView] = [
            modesHint, markdownRow, markdownHint, tagRow, tagHint,
            repetitionRow, repetitionHint, forgetButton,
        ]
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

            let row = makeLabeledControlRow(
                title: loc.s(kind.localizationKey),
                control: popup
            )
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

        let allowlistArea = makeTableArea(
            table: aiAllowlistTable,
            accessibilityLabel: loc.s("prefs.ai.allowlist"),
            columnIdentifier: "aiAllow",
            emptyLabel: aiAllowlistEmptyLabel,
            allowsMultipleSelection: true
        )

        aiAllowlistField.translatesAutoresizingMaskIntoConstraints = false
        aiAllowlistField.placeholderString = loc.s("prefs.ai.allowlist.bundleID")
        aiAllowlistField.font = DevTypeTheme.font(12)
        aiAllowlistField.setAccessibilityLabel(loc.s("prefs.ai.allowlist.bundleID"))
        aiAllowlistField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let addFrontmostButton = CapsuleButton(
            title: loc.s("prefs.ai.allowlist.addFrontmost"),
            symbol: "plus.app",
            style: .secondary,
            target: self,
            action: #selector(aiAllowlistAddFrontmost)
        )
        let addAllowlistButton = CapsuleButton(
            title: loc.s("common.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(aiAllowlistAddTyped)
        )
        let removeAllowlistButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(aiAllowlistRemove)
        )
        bindRemovalButton(removeAllowlistButton, to: aiAllowlistTable)
        let allowButtons = NSStackView(views: [
            addFrontmostButton,
            addAllowlistButton,
            removeAllowlistButton
        ])
        allowButtons.orientation = .horizontal
        allowButtons.spacing = 8
        allowButtons.translatesAutoresizingMaskIntoConstraints = false

        let editorRow = NSStackView(views: [aiAllowlistField])
        editorRow.orientation = .horizontal
        editorRow.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(allowCard, views: [allowHint, allowlistArea, editorRow, allowButtons])

        for card in [enableCard, hotkeyCard, modesCard, allowCard] {
            stack.addArrangedSubview(card)
        }
        pinWidth(of: [enableCard, hotkeyCard, modesCard, allowCard], to: stack)
    }

    private func reloadAI() {
        guard panes[.ai] != nil else { return }
        aiEnabledSwitch.state = AIPreferences.isEnabled ? .on : .off
        aiRemoveMarkdownSwitch.state = AIPreferences.removesMarkdown ? .on : .off
        aiTagSuggestionsSwitch.state = SnippetTagSuggester.isEnabled ? .on : .off
        repetitionSwitch.state = TypedRepetitionPreferences.isActive ? .on : .off
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
        refreshRemovalButton(for: aiAllowlistTable)
    }

    @objc private func aiEnabledChanged() {
        AIPreferences.isEnabled = aiEnabledSwitch.state == .on
        reloadAI()
    }

    @objc private func aiRemoveMarkdownChanged() {
        AIPreferences.removesMarkdown = aiRemoveMarkdownSwitch.state == .on
    }

    @objc private func aiTagSuggestionsChanged() {
        SnippetTagSuggester.isEnabled = aiTagSuggestionsSwitch.state == .on
    }

    /// Turning this on is a consent decision, not a preference toggle, so the switch does not
    /// take effect until the prompt is confirmed — and springs back if it is not. Turning it
    /// off revokes consent and forgets everything rather than merely pausing.
    @objc private func repetitionChanged() {
        guard repetitionSwitch.state == .on else {
            TypedRepetitionPreferences.revokeConsent()
            return
        }
        if TypedRepetitionPreferences.hasCurrentConsent {
            TypedRepetitionPreferences.isEnabled = true
            return
        }
        repetitionSwitch.state = .off
        DevTypeAlert.confirm(
            title: loc.s("prefs.repetition.consent.title"),
            message: loc.s("prefs.repetition.consent.body"),
            confirmTitle: loc.s("prefs.repetition.consent.confirm"),
            cancelTitle: loc.s("common.cancel"),
            style: .informational,
            window: view.window
        ) { [weak self] in
            TypedRepetitionPreferences.grantedConsentVersion =
                TypedRepetitionPreferences.currentConsentVersion
            TypedRepetitionPreferences.isEnabled = true
            self?.repetitionSwitch.state = .on
        }
    }

    @objc private func repetitionForget() {
        TypedRepetitionDetector.shared.forgetAll()
        DevTypeAlert.info(
            title: loc.s("prefs.repetition.forget"),
            message: loc.s("prefs.repetition.forget.done"),
            window: view.window
        )
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
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
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
            switch tableColumn?.identifier.rawValue {
            case "voiceDictSpoken": text = entry.spoken
            case "voiceDictReplacement": text = entry.replacement
            default: return nil
            }
        } else if tableView === voiceTriggersTable {
            guard voiceTriggerEntries.indices.contains(row) else { return nil }
            let entry = voiceTriggerEntries[row]
            switch tableColumn?.identifier.rawValue {
            case "voiceTriggerPhrase": text = entry.phrase
            case "voiceTriggerAction": text = loc.s("ai.kind.\(entry.action)")
            default: return nil
            }
        } else {
            return nil
        }

        let columnIdentifier = tableColumn?.identifier.rawValue ?? "single"
        let identifier = NSUserInterfaceItemIdentifier("prefsRow.\(columnIdentifier)")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.lineBreakMode = .byTruncatingTail
        }
        label.font = (tableView === voiceDictionaryTable || tableView === voiceTriggersTable)
            ? DevTypeTheme.font(11)
            : DevTypeTheme.mono(11)
        label.stringValue = text
        label.textColor = DevTypeTheme.textPrimary
        // §5.1: rows read as their content instead of "row N".
        label.setAccessibilityLabel(text)
        return label
    }

    /// Configuration readiness for each engine.
    ///
    /// Replaces an inventory of downloadable ASR models that no engine could actually use
    /// and whose download URLs no longer resolve. This reports something the user can act
    /// on: whether the selected engine will work, and what is missing if it will not.
    private func voiceEngineStatus(
        for engine: TranscriptionEngine
    ) -> (text: String, color: NSColor, detail: String?) {
        switch engine {
        case .gemini:
            return GeminiAPIKeyStore.hasKey
                ? (loc.s("prefs.voice.speechModels.status.ready"), DevTypeTheme.statusGreen, nil)
                : (loc.s("prefs.voice.speechModels.status.needsKey"), DevTypeTheme.statusOrange, nil)

        case .whisperLocal:
            // Detection is filesystem-only and synchronous here; the reachability probe is
            // async and runs when the user opens the setup sheet. Distinguishing "not
            // installed" from "installed but not started" is what makes the next step
            // obvious rather than leaving the user with a dead endpoint field.
            if let binaryPath = WhisperServerSetup.installedBinaryPath() {
                return (
                    loc.s("prefs.voice.speechModels.status.needsServer"),
                    DevTypeTheme.statusOrange,
                    WhisperServerSetup.pendingCommands(for: .installedNotRunning(binaryPath: binaryPath))
                )
            }
            return (
                loc.s("prefs.voice.speechModels.status.needsSetup"),
                DevTypeTheme.textTertiary,
                WhisperServerSetup.pendingCommands(for: .notInstalled)
            )

        case .localLLM, .appleSpeech:
            // On-device recognition needs no configuration; correction degrades to
            // deterministic rules on its own when no model is reachable.
            return (loc.s("prefs.voice.speechModels.status.ready"), DevTypeTheme.statusGreen, nil)
        }
    }

    private static func sourceKey(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .gemini: return "prefs.voice.speechModels.source.cloud"
        case .whisperLocal: return "prefs.voice.speechModels.source.local"
        case .localLLM, .appleSpeech: return "prefs.voice.speechModels.source.system"
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = RoundedSelectionRowView()
        rowView.selectionRadius = 5
        rowView.selectionInset = NSEdgeInsets(top: 1, left: 2, bottom: 1, right: 2)
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        refreshRemovalButton(for: tableView)
    }

    // MARK: Small layout helpers

    /// One canonical list surface for every table-shaped preference. Empty
    /// messages sit inside the list bounds, so zero rows read as an intentional
    /// state rather than an unexplained blank card.
    private func makeTableArea(
        table: NSTableView,
        accessibilityLabel: String,
        columnIdentifier: String,
        emptyLabel: NSTextField,
        rowHeight: CGFloat = 22,
        height: CGFloat = 110,
        allowsMultipleSelection: Bool = false
    ) -> NSView {
        table.headerView = nil
        table.rowHeight = rowHeight
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = allowsMultipleSelection
        table.dataSource = self
        table.delegate = self
        if table.tableColumns.isEmpty {
            table.addTableColumn(NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(columnIdentifier)
            ))
        }
        table.setAccessibilityLabel(accessibilityLabel)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = table

        let area = PreferenceTableAreaView()
        area.translatesAutoresizingMaskIntoConstraints = false
        area.wantsLayer = true
        area.layer?.cornerRadius = DevTypeTheme.Radius.control
        area.layer?.backgroundColor = DevTypeTheme.contrastOverlay(0.035).cgColor
        area.layer?.borderWidth = 1
        area.layer?.borderColor = DevTypeTheme.hairline.cgColor

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        area.addSubview(scroll)
        area.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            area.heightAnchor.constraint(equalToConstant: height),
            scroll.topAnchor.constraint(equalTo: area.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: area.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: area.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: area.bottomAnchor, constant: -4),
            emptyLabel.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: area.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: area.trailingAnchor, constant: -16),
            emptyLabel.centerXAnchor.constraint(equalTo: area.centerXAnchor)
        ])
        return area
    }

    private func bindRemovalButton(_ button: CapsuleButton, to tableView: NSTableView) {
        removalButtons[ObjectIdentifier(tableView)] = button
        refreshRemovalButton(for: tableView)
    }

    private func refreshRemovalButton(for tableView: NSTableView) {
        removalButtons[ObjectIdentifier(tableView)]?.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

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
            if subview is NSTextField
                || subview is NSScrollView
                || subview is PreferenceRowView
                || subview is PreferenceTableAreaView
                || (subview as? NSStackView)?.orientation == .horizontal {
                subview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else {
                subview.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            }
        }
    }

    private func makeToggleRow(title: String, toggle: NSSwitch, action: Selector) -> NSView {
        let row = PreferenceRowView()
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
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2)
        ])
        return row
    }

    private func makeLabeledControlRow(
        title: String,
        control: NSView,
        font: NSFont = DevTypeTheme.font(12.5, .medium)
    ) -> NSView {
        let row = PreferenceRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        let label = DevTypeTheme.makeLabel(title, font: font, color: DevTypeTheme.textPrimary)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
            control.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 26)
        ])
        return row
    }

    private func pinWidth(of views: [NSView], to stack: NSStackView) {
        for subview in views {
            subview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}
