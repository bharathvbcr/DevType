import AppKit
import ExpanderEngine

/// §4: Interactive Snippet Conflict Resolver Sheet.
///
/// Surfaces trigger conflicts (exact duplicates, prefix collisions, case overlap)
/// with side-by-side comparison, runtime winner explanation, and inline resolution actions.
final class SnippetConflictResolverSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    typealias TriggerConflict = SnippetStore.TriggerConflict

    public static func present(from window: NSWindow?, store: SnippetStore = .shared, completion: (() -> Void)? = nil) {
        let vc = SnippetConflictResolverSheet(store: store, completion: completion)
        let sheetWindow = NSWindow(contentViewController: vc)
        sheetWindow.title = LocalizationManager.shared.s("conflict.resolver.title")
        sheetWindow.styleMask = [.titled, .closable, .resizable]
        sheetWindow.setContentSize(NSSize(width: 680, height: 460))
        sheetWindow.minSize = NSSize(width: 540, height: 360)
        DevTypeTheme.styleWindow(sheetWindow, title: LocalizationManager.shared.s("conflict.resolver.title"))

        if let window {
            window.beginSheet(sheetWindow)
        } else {
            sheetWindow.center()
            sheetWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private let store: SnippetStore
    private let completion: (() -> Void)?
    private let loc = LocalizationManager.shared
    private let tableView = NSTableView()
    private var conflicts: [TriggerConflict] = []
    private var allSnippetsByID: [UUID: SnippetModel] = [:]

    init(store: SnippetStore = .shared, completion: (() -> Void)? = nil) {
        self.store = store
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        let header = DevTypeTheme.makeLabel(
            loc.s("conflict.resolver.title"),
            font: DevTypeTheme.font(16, .bold),
            color: DevTypeTheme.textPrimary
        )
        header.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = CapsuleButton(
            title: loc.s("common.done"),
            style: .primary,
            target: self,
            action: #selector(closeTapped)
        )
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        tableView.headerView = nil
        tableView.rowHeight = 110
        tableView.intercellSpacing = NSSize(width: 0, height: 8)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conflictCol")))
        scroll.documentView = tableView

        root.addSubview(header)
        root.addSubview(closeBtn)
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            closeBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            closeBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])

        reloadConflicts()
        view = root
    }

    private func reloadConflicts() {
        let groups = store.loadGroups()
        var map: [UUID: SnippetModel] = [:]
        for g in groups {
            for s in g.snippets {
                map[s.id] = s
            }
        }
        allSnippetsByID = map
        conflicts = store.triggerConflicts()
        tableView.reloadData()
    }

    @objc private func closeTapped() {
        if let window = view.window, let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            view.window?.close()
        }
        completion?()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        conflicts.isEmpty ? 1 : conflicts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if conflicts.isEmpty {
            let empty = NSTableCellView()
            let label = DevTypeTheme.makeLabel(
                loc.s("library.health.conflictsNone"),
                font: DevTypeTheme.font(13),
                color: DevTypeTheme.textSecondary
            )
            label.translatesAutoresizingMaskIntoConstraints = false
            empty.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: empty.centerYAnchor)
            ])
            return empty
        }

        let conflict = conflicts[row]
        let relevantSnippets = conflict.snippetIDs.compactMap { allSnippetsByID[$0] }
        let cell = ConflictRowView(conflict: conflict, snippets: relevantSnippets, store: store) { [weak self] in
            self?.reloadConflicts()
        }
        return cell
    }
}

private final class ConflictRowView: NSView {
    typealias TriggerConflict = SnippetStore.TriggerConflict
    private let conflict: TriggerConflict
    private let snippets: [SnippetModel]
    private let store: SnippetStore
    private let onRefresh: () -> Void
    private let loc = LocalizationManager.shared

    init(conflict: TriggerConflict, snippets: [SnippetModel], store: SnippetStore, onRefresh: @escaping () -> Void) {
        self.conflict = conflict
        self.snippets = snippets
        self.store = store
        self.onRefresh = onRefresh
        super.init(frame: .zero)

        let card = GlassCardView(tint: DevTypeTheme.statusOrange.withAlphaComponent(0.06))
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let content = card.contentView

        // Winner explanation badge
        let explanationText: String
        switch conflict.kind {
        case .emptyTrigger:
            explanationText = loc.s("snippets.filter.empty")
        case .duplicateTrigger:
            explanationText = loc.s("conflict.winner.exact")
        case .caseShadow:
            explanationText = loc.s("conflict.winner.case")
        case .prefixShadow:
            explanationText = loc.s("conflict.winner.shorter")
        }

        let winnerBadge = PillBadgeView(text: explanationText, tint: DevTypeTheme.statusOrange, showsDot: true)
        winnerBadge.translatesAutoresizingMaskIntoConstraints = false

        let hStack = NSStackView()
        hStack.orientation = .horizontal
        hStack.distribution = .fillEqually
        hStack.spacing = 10
        hStack.translatesAutoresizingMaskIntoConstraints = false

        for (index, snippet) in snippets.prefix(3).enumerated() {
            let summary = makeSnippetSummary(snippet, isWinner: index == 0)
            hStack.addArrangedSubview(summary)
        }

        content.addSubview(winnerBadge)
        content.addSubview(hStack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            winnerBadge.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            winnerBadge.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),

            hStack.topAnchor.constraint(equalTo: winnerBadge.bottomAnchor, constant: 8),
            hStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeSnippetSummary(_ snippet: SnippetModel, isWinner: Bool) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = (isWinner ? DevTypeTheme.accent.withAlphaComponent(0.4) : NSColor.white.withAlphaComponent(0.08)).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = DevTypeTheme.makeLabel(snippet.displayTitle, font: DevTypeTheme.font(12, .semibold), color: DevTypeTheme.textPrimary)
        let triggerLabel = DevTypeTheme.makeLabel(snippet.triggerKeyword.isEmpty ? "(none)" : snippet.triggerKeyword, font: DevTypeTheme.mono(11, .bold), color: DevTypeTheme.accent)
        let previewLabel = DevTypeTheme.makeLabel(snippet.replacementText.replacingOccurrences(of: "\n", with: " "), font: DevTypeTheme.font(10.5), color: DevTypeTheme.textSecondary)

        let toggleBtn = CapsuleButton(
            title: snippet.enabled ? loc.s("manager.disable") : loc.s("manager.enable"),
            style: .secondary,
            target: self,
            action: #selector(toggleSnippet(_:))
        )
        toggleBtn.tag = snippet.id.hashValue
        toggleBtn.controlSize = .small

        let deleteBtn = CapsuleButton(
            title: loc.s("common.delete"),
            style: .destructive,
            target: self,
            action: #selector(deleteSnippet(_:))
        )
        deleteBtn.tag = snippet.id.hashValue
        deleteBtn.controlSize = .small

        let btnRow = NSStackView(views: [toggleBtn, deleteBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 6

        let stack = NSStackView(views: [titleLabel, triggerLabel, previewLabel, btnRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])

        return container
    }

    @objc private func toggleSnippet(_ sender: NSButton) {
        guard let snippet = snippets.first(where: { $0.id.hashValue == sender.tag }) else { return }
        var groups = store.loadGroups()
        for gi in groups.indices {
            if let si = groups[gi].snippets.firstIndex(where: { $0.id == snippet.id }) {
                groups[gi].snippets[si].enabled.toggle()
                break
            }
        }
        _ = store.saveGroups(groups)
        onRefresh()
    }

    @objc private func deleteSnippet(_ sender: NSButton) {
        guard let snippet = snippets.first(where: { $0.id.hashValue == sender.tag }) else { return }
        var groups = store.loadGroups()
        for gi in groups.indices {
            groups[gi].snippets.removeAll(where: { $0.id == snippet.id })
        }
        _ = store.saveGroups(groups)
        onRefresh()
    }
}
