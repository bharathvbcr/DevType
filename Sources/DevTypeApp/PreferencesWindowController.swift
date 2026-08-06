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

/// Sections, in tab order.
enum PreferencesTab: Int, CaseIterable {
    case general
    case snippets
    case hotkeys
    case advanced

    var title: String {
        switch self {
        case .general: return LocalizationManager.shared.s("prefs.tab.general")
        case .snippets: return LocalizationManager.shared.s("prefs.tab.snippets")
        case .hotkeys: return LocalizationManager.shared.s("prefs.tab.hotkeys")
        case .advanced: return LocalizationManager.shared.s("prefs.tab.advanced")
        }
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
            newWindow.setContentSize(NSSize(width: 660, height: 620))
            newWindow.minSize = NSSize(width: 620, height: 480)
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

// MARK: - Preferences content

final class PreferencesViewController: NSViewController,
                                       NSTableViewDataSource,
                                       NSTableViewDelegate {

    private let loc = LocalizationManager.shared
    private let store = SnippetStore.shared
    private weak var hotkeyManager: HotkeyManager?

    private var tabControl: NSSegmentedControl?
    private var panes: [PreferencesTab: NSView] = [:]

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

        let header = DevTypeTheme.makeBrandHeader(
            title: loc.s("prefs.title"),
            subtitle: loc.s("manager.subtitle"),
            logoSize: 34
        )
        root.addSubview(header)

        let tabs = NSSegmentedControl(
            labels: PreferencesTab.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabChanged(_:))
        )
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.segmentDistribution = .fillEqually
        tabs.selectedSegment = PreferencesTab.general.rawValue
        tabs.setAccessibilityLabel(loc.s("ax.preferences.tabs"))
        tabControl = tabs
        root.addSubview(tabs)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)

        for tab in PreferencesTab.allCases {
            let pane = makeScrollingPane(for: tab)
            pane.isHidden = tab != .general
            container.addSubview(pane)
            panes[tab] = pane
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: container.topAnchor),
                pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                pane.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),

            tabs.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            container.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
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
        tabControl?.selectedSegment = tab.rawValue
        applyTabSelection(tab)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let tab = PreferencesTab(rawValue: sender.selectedSegment) ?? .general
        applyTabSelection(tab)
    }

    private func applyTabSelection(_ tab: PreferencesTab) {
        for (candidate, pane) in panes {
            pane.isHidden = candidate != tab
        }
        if tab == .snippets { stats.refresh() }
        if tab == .advanced { reloadAdvanced() }
    }

    /// Re-pulls every value from its source of truth.
    func reloadAll() {
        guard isViewLoaded else { return }
        reloadGeneral()
        reloadSnippets()
        reloadHotkeys()
        reloadAdvanced()
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
