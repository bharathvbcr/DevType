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
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class ShortcutReferenceViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private struct ShortcutItem: Equatable {
        let section: String
        let title: String
        let keyCaps: [String]
        let note: String?
    }

    private let loc = LocalizationManager.shared
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var allShortcuts: [ShortcutItem] = []
    private var filteredShortcuts: [ShortcutItem] = []

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        let header = DevTypeTheme.makeLabel(
            loc.s("shortcuts.window.title"),
            font: DevTypeTheme.font(16, .bold),
            color: DevTypeTheme.textPrimary
        )
        header.translatesAutoresizingMaskIntoConstraints = false

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

        root.addSubview(header)
        root.addSubview(searchField)
        root.addSubview(openHotkeysBtn)
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            openHotkeysBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            openHotkeysBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            searchField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
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

    private func buildShortcutsCatalog() {
        allShortcuts = [
            // Global
            ShortcutItem(section: loc.s("shortcuts.section.global"), title: loc.s("home.hotkeys.search"), keyCaps: ["⌘", "/"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.global"), title: loc.s("home.hotkeys.ai"), keyCaps: ["⌥", "⌘", "/"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.global"), title: loc.s("home.hotkeys.dictation"), keyCaps: ["⌥", "Space"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.global"), title: loc.s("menu.muteFrontmost"), keyCaps: ["⌥", "⌘", "M"], note: nil),

            // Manager
            ShortcutItem(section: loc.s("shortcuts.section.manager"), title: loc.s("manager.snippet.new"), keyCaps: ["⌘", "N"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.manager"), title: loc.s("manager.group.add"), keyCaps: ["⇧", "⌘", "N"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.manager"), title: loc.s("common.edit"), keyCaps: ["↩"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.manager"), title: loc.s("manager.context.duplicate"), keyCaps: ["⌘", "D"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.manager"), title: loc.s("manager.context.delete"), keyCaps: ["⌫"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.manager"), title: loc.s("edit.undo"), keyCaps: ["⌘", "Z"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.manager"), title: loc.s("edit.redo"), keyCaps: ["⇧", "⌘", "Z"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.manager"), title: loc.s("manager.bulk.selectAll"), keyCaps: ["⌘", "A"], note: nil),

            // Palette
            ShortcutItem(section: loc.s("shortcuts.section.palette"), title: loc.s("search.hint.navigate"), keyCaps: ["↑", "↓"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.palette"), title: loc.s("search.hint.expand"), keyCaps: ["↩"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.palette"), title: loc.s("search.hint.jump"), keyCaps: ["⌘", "1…9"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.palette"), title: loc.s("palette.section.commands"), keyCaps: [">"], note: "Prefix query with >"),
            ShortcutItem(section: loc.s("shortcuts.section.palette"), title: loc.s("palette.math.title"), keyCaps: ["="], note: "Prefix query with ="),
            ShortcutItem(section: loc.s("shortcuts.section.palette"), title: loc.s("search.hint.close"), keyCaps: ["⎋"], note: nil),

            // AI & Review
            ShortcutItem(section: loc.s("shortcuts.section.ai"), title: loc.s("ai.preview.action.replace"), keyCaps: ["⌘", "↩"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.ai"), title: loc.s("common.copy"), keyCaps: ["⌘", "C"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.ai"), title: loc.s("common.retry"), keyCaps: ["⌘", "R"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.ai"), title: loc.s("common.cancel"), keyCaps: ["⎋"], note: nil),

            // Dictation
            ShortcutItem(section: loc.s("shortcuts.section.dictation"), title: loc.s("voice.hud.cancel"), keyCaps: ["⎋"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.dictation"), title: loc.s("voice.hud.copy"), keyCaps: ["Click HUD"], note: nil),

            // Editor
            ShortcutItem(section: loc.s("shortcuts.section.editor"), title: loc.s("editor.save"), keyCaps: ["⌘", "S"], note: nil),
            ShortcutItem(section: loc.s("shortcuts.section.editor"), title: loc.s("editor.macroGuide"), keyCaps: ["%"], note: "Insert dynamic macro")
        ]
    }

    @objc private func searchChanged() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            filteredShortcuts = allShortcuts
        } else {
            filteredShortcuts = allShortcuts.filter {
                TokenizedFilter.matches(query: q, fields: [
                    $0.title,
                    $0.section,
                    $0.keyCaps.joined(separator: " "),
                    $0.note ?? ""
                ])
            }
        }
        tableView.reloadData()
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
