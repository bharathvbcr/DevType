import AppKit
import ExpanderEngine

/// §14: Dedicated Keyboard Shortcuts Reference Panel.
///
/// Gives users a centralized, searchable directory of all app shortcuts
/// across Global, Manager, Palette, AI, Dictation, and Editor surfaces.
final class ShortcutReferenceWindowController: NSWindowController {
    static let shared = ShortcutReferenceWindowController()

    private init() {
        let vc = ShortcutReferenceViewController()
        let window = NSWindow(contentViewController: vc)
        window.title = LocalizationManager.shared.s("shortcuts.window.title")
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 580, height: 480))
        window.minSize = NSSize(width: 480, height: 360)
        DevTypeTheme.styleWindow(window, title: LocalizationManager.shared.s("shortcuts.window.title"))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func show() {
        (shared.window?.contentViewController as? ShortcutReferenceViewController)?.refreshLocalization()
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ShortcutReferenceEntry: Equatable {
    let section: String
    let title: String
    let keyCaps: [String]
    let note: String?
}

/// Immutable search result so an unmatched query is a deliberate, testable UI state rather than
/// an unexplained blank table.
struct ShortcutReferenceProjection: Equatable {
    let entries: [ShortcutReferenceEntry]

    init(entries candidates: [ShortcutReferenceEntry], query: String) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            entries = candidates
            return
        }
        entries = candidates.filter {
            TokenizedFilter.matches(query: needle, fields: [
                $0.title,
                $0.section,
                $0.keyCaps.joined(separator: " "),
                $0.note ?? ""
            ])
        }
    }

    var showsEmptyState: Bool { entries.isEmpty }
}

enum ShortcutReferenceCatalog {
    static func make(
        loc: LocalizationManager,
        inlineSearch: DevTypeShortcut,
        aiPalette: DevTypeShortcut,
        voice: DevTypeShortcut
    ) -> [ShortcutReferenceEntry] {
        [
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.global"), title: loc.s("home.hotkeys.search"), keyCaps: inlineSearch.keyCaps, note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.global"), title: loc.s("home.hotkeys.ai"), keyCaps: aiPalette.keyCaps, note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.global"), title: loc.s("home.hotkeys.dictation"), keyCaps: voice.keyCaps, note: nil),

            ShortcutReferenceEntry(section: loc.s("shortcuts.section.manager"), title: loc.s("common.edit"), keyCaps: ["↩"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.manager"), title: loc.s("manager.context.duplicate"), keyCaps: ["⌘", "D"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.manager"), title: loc.s("manager.context.delete"), keyCaps: ["⌫"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.manager"), title: loc.s("edit.undo"), keyCaps: ["⌘", "Z"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.manager"), title: loc.s("edit.redo"), keyCaps: ["⇧", "⌘", "Z"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.manager"), title: loc.s("manager.bulk.selectAll"), keyCaps: ["⌘", "A"], note: nil),

            ShortcutReferenceEntry(section: loc.s("shortcuts.section.palette"), title: loc.s("search.hint.navigate"), keyCaps: ["↑", "↓"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.palette"), title: loc.s("search.hint.expand"), keyCaps: ["↩"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.palette"), title: loc.s("search.hint.jump"), keyCaps: ["⌘", "1…9"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.palette"), title: loc.s("palette.section.commands"), keyCaps: [">"], note: loc.s("shortcuts.note.commandPrefix")),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.palette"), title: loc.s("palette.math.title"), keyCaps: ["="], note: loc.s("shortcuts.note.mathPrefix")),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.palette"), title: loc.s("search.hint.close"), keyCaps: ["⎋"], note: nil),

            ShortcutReferenceEntry(section: loc.s("shortcuts.section.ai"), title: loc.s("ai.preview.action.replace"), keyCaps: ["↩"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.ai"), title: loc.s("ai.preview.replaceAndCopy"), keyCaps: ["⌥", "↩"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.ai"), title: loc.s("common.copy"), keyCaps: ["⌘", "C"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.ai"), title: loc.s("common.retry"), keyCaps: ["⌘", "R"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.ai"), title: loc.s("common.cancel"), keyCaps: ["⎋"], note: nil),

            ShortcutReferenceEntry(section: loc.s("shortcuts.section.editor"), title: loc.s("editor.save"), keyCaps: ["⌘", "↩"], note: nil),
            ShortcutReferenceEntry(section: loc.s("shortcuts.section.editor"), title: loc.s("editor.macroGuide"), keyCaps: ["⇧", "⌘", "/"], note: loc.s("shortcuts.note.dynamicMacro"))
        ]
    }
}

final class ShortcutReferenceViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let loc: LocalizationManager
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let headerLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(16, .bold),
        color: DevTypeTheme.textPrimary
    )
    private let emptyState = NSView()
    private let emptyTitleLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(13, .semibold),
        color: DevTypeTheme.textSecondary
    )
    private let emptyHintLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11),
        color: DevTypeTheme.textTertiary
    )
    private var openHotkeysButton: CapsuleButton?
    private var allShortcuts: [ShortcutReferenceEntry] = []
    private var filteredShortcuts: [ShortcutReferenceEntry] = []
    private var languageObserver: NSObjectProtocol?

    init(localization: LocalizationManager = .shared) {
        self.loc = localization
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        headerLabel.stringValue = loc.s("shortcuts.window.title")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = loc.s("shortcuts.search")
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcutCol")))
        scroll.documentView = tableView

        let openHotkeysBtn = CapsuleButton(
            title: loc.s("prefs.tab.hotkeys"),
            symbol: "keyboard",
            style: .secondary,
            target: self,
            action: #selector(openHotkeysPrefs)
        )
        openHotkeysBtn.translatesAutoresizingMaskIntoConstraints = false
        openHotkeysButton = openHotkeysBtn

        root.addSubview(headerLabel)
        root.addSubview(searchField)
        root.addSubview(openHotkeysBtn)
        root.addSubview(scroll)
        setupEmptyState(in: root, over: scroll)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            openHotkeysBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            openHotkeysBtn.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),

            searchField.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])

        buildShortcutsCatalog()
        filteredShortcuts = allShortcuts
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLocalization()
        if languageObserver == nil {
            languageObserver = NotificationCenter.default.addObserver(
                forName: .devTypeLanguageChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshLocalization()
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
    }

    deinit {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    private func setupEmptyState(in root: NSView, over scroll: NSScrollView) {
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = DevTypeTheme.symbol(
            "keyboard.badge.ellipsis",
            size: 25,
            weight: .light,
            color: DevTypeTheme.accent.withAlphaComponent(0.7)
        )
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)

        emptyTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyHintLabel.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [icon, emptyTitleLabel, emptyHintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addSubview(stack)
        emptyState.setAccessibilityElement(true)
        emptyState.setAccessibilityRole(.group)
        root.addSubview(emptyState)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)
        ])
        refreshEmptyStateLocalization()
    }

    func refreshLocalization() {
        guard isViewLoaded else { return }
        headerLabel.stringValue = loc.s("shortcuts.window.title")
        searchField.placeholderString = loc.s("shortcuts.search")
        openHotkeysButton?.title = loc.s("prefs.tab.hotkeys")
        refreshEmptyStateLocalization()
        if let window = view.window {
            DevTypeTheme.styleWindow(window, title: loc.s("shortcuts.window.title"))
        }
        buildShortcutsCatalog()
        applyProjection(ShortcutReferenceProjection(
            entries: allShortcuts,
            query: searchField.stringValue
        ))
    }

    private func refreshEmptyStateLocalization() {
        emptyTitleLabel.stringValue = loc.s("shortcuts.empty")
        emptyHintLabel.stringValue = loc.s("shortcuts.emptyHint")
        emptyState.setAccessibilityLabel(loc.s("shortcuts.empty"))
        emptyState.setAccessibilityHelp(loc.s("shortcuts.emptyHint"))
    }

    private func buildShortcutsCatalog() {
        allShortcuts = ShortcutReferenceCatalog.make(
            loc: loc,
            inlineSearch: HotkeyPreferences.inlineSearchShortcut,
            aiPalette: HotkeyPreferences.aiPaletteShortcut,
            voice: HotkeyPreferences.voiceShortcut
        )
    }

    @objc private func searchChanged() {
        applyProjection(ShortcutReferenceProjection(
            entries: allShortcuts,
            query: searchField.stringValue
        ))
    }

    private func applyProjection(_ projection: ShortcutReferenceProjection) {
        filteredShortcuts = projection.entries
        tableView.reloadData()
        emptyState.isHidden = !projection.showsEmptyState
        if projection.showsEmptyState {
            tableView.deselectAll(nil)
        }
    }

    @objc private func openHotkeysPrefs() {
        view.window?.close()
        PreferencesWindowController.shared.show(tab: .hotkeys, hotkeyManager: nil)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredShortcuts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredShortcuts.indices.contains(row) else { return nil }
        let item = filteredShortcuts[row]

        let cell = NSTableCellView()
        let titleLabel = DevTypeTheme.makeLabel(item.title, font: DevTypeTheme.font(12, .medium), color: DevTypeTheme.textPrimary)
        let sectionBadge = DevTypeTheme.makeLabel(item.section, font: DevTypeTheme.font(10), color: DevTypeTheme.textTertiary)

        let leftStack = NSStackView(views: [titleLabel, sectionBadge])
        leftStack.orientation = .horizontal
        leftStack.spacing = 8
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let capsStack = NSStackView()
        capsStack.orientation = .horizontal
        capsStack.spacing = 4
        capsStack.alignment = .centerY
        capsStack.translatesAutoresizingMaskIntoConstraints = false

        for cap in item.keyCaps {
            let capView = KeyCapView(cap)
            capsStack.addArrangedSubview(capView)
        }

        if let note = item.note {
            let noteLabel = DevTypeTheme.makeLabel(note, font: DevTypeTheme.font(10), color: DevTypeTheme.textTertiary)
            capsStack.addArrangedSubview(noteLabel)
        }

        cell.addSubview(leftStack)
        cell.addSubview(capsStack)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            leftStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            capsStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            capsStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: capsStack.leadingAnchor, constant: -10)
        ])

        return cell
    }
}
