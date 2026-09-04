import AppKit
import ExpanderEngine

extension SnippetStore.ImportPreview.Status {
    var localizationKey: String {
        switch self {
        case .isNew: return "import.preview.status.new"
        case .isUpdate: return "import.preview.status.update"
        case .isConflict: return "import.preview.status.conflict"
        }
    }
}

/// §15: Snippet Import Preview Sheet.
///
/// Previews incoming snippets before committing them to the library,
/// surfacing counts of new/updated/conflicting items and allowing mode selection.
final class SnippetImportPreviewSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    typealias SnippetImportMode = SnippetStore.ImportMode

    public static func present(
        from window: NSWindow?,
        preview: SnippetStore.ImportPreview,
        onConfirm: @escaping (SnippetImportMode) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        let vc = SnippetImportPreviewSheet(
            preview: preview,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
        let sheetWindow = NSWindow(contentViewController: vc)
        sheetWindow.title = LocalizationManager.shared.s("import.preview.title")
        sheetWindow.styleMask = [.titled, .closable, .resizable]
        sheetWindow.setContentSize(NSSize(width: 620, height: 480))
        sheetWindow.minSize = NSSize(width: 520, height: 380)
        DevTypeTheme.styleWindow(sheetWindow, title: LocalizationManager.shared.s("import.preview.title"))

        if let window {
            window.beginSheet(sheetWindow)
        } else {
            sheetWindow.center()
            sheetWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private let preview: SnippetStore.ImportPreview
    private let onConfirm: (SnippetImportMode) -> Void
    private let onCancel: (() -> Void)?
    private let loc = LocalizationManager.shared

    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tableView = NSTableView()
    private var didConfirm = false
    private var didCancel = false

    init(
        preview: SnippetStore.ImportPreview,
        onConfirm: @escaping (SnippetImportMode) -> Void,
        onCancel: (() -> Void)?
    ) {
        self.preview = preview
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        finishCancelledIfNeeded()
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        let header = DevTypeTheme.makeLabel(
            loc.s("import.preview.title"),
            font: DevTypeTheme.font(16, .bold),
            color: DevTypeTheme.textPrimary
        )
        header.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = DevTypeTheme.makeLabel(
            loc.s("import.preview.count", preview.plan.snippetCount, preview.plan.groupCount),
            font: DevTypeTheme.font(12),
            color: DevTypeTheme.textSecondary
        )
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        // Stat Badges Row
        let newCount = preview.newCount
        let updateCount = preview.updateCount
        let conflictCount = preview.conflictCount

        let newPill = PillBadgeView(text: loc.s("import.preview.stat.new", newCount), tint: DevTypeTheme.statusGreen)
        let updatePill = PillBadgeView(text: loc.s("import.preview.stat.updated", updateCount), tint: DevTypeTheme.statusBlue)
        let conflictPill = PillBadgeView(text: loc.s("import.preview.stat.conflicts", conflictCount), tint: conflictCount > 0 ? DevTypeTheme.statusOrange : DevTypeTheme.textTertiary)

        let statsRow = NSStackView(views: [newPill, updatePill, conflictPill])
        statsRow.orientation = .horizontal
        statsRow.spacing = 8
        statsRow.translatesAutoresizingMaskIntoConstraints = false

        // Mode Selector Row
        modePopup.removeAllItems()
        modePopup.addItem(withTitle: loc.s("import.preview.mode.merge"))
        modePopup.addItem(withTitle: loc.s("import.preview.mode.skip"))
        modePopup.addItem(withTitle: loc.s("import.preview.mode.duplicate"))
        modePopup.setAccessibilityLabel(loc.s("import.preview.mode"))
        modePopup.translatesAutoresizingMaskIntoConstraints = false

        let modeLabel = DevTypeTheme.makeLabel(
            loc.s("import.preview.mode"),
            font: DevTypeTheme.font(12, .medium),
            color: DevTypeTheme.textSecondary
        )
        let modeRow = NSStackView(views: [modeLabel, modePopup])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8
        modeRow.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("importItemCol")))
        scroll.documentView = tableView

        let cancelBtn = CapsuleButton(
            title: loc.s("common.cancel"),
            style: .secondary,
            target: self,
            action: #selector(cancelTapped)
        )

        let confirmBtn = CapsuleButton(
            title: loc.s("import.preview.confirm"),
            style: .primary,
            target: self,
            action: #selector(confirmTapped)
        )

        let buttonsRow = NSStackView(views: [cancelBtn, confirmBtn])
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 8
        buttonsRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(countLabel)
        root.addSubview(statsRow)
        root.addSubview(modeRow)
        root.addSubview(scroll)
        root.addSubview(buttonsRow)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            countLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            countLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            statsRow.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 10),
            statsRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            modeRow.leadingAnchor.constraint(greaterThanOrEqualTo: statsRow.trailingAnchor, constant: 12),
            modeRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            modeRow.centerYAnchor.constraint(equalTo: statsRow.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: statsRow.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: buttonsRow.topAnchor, constant: -12),

            buttonsRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttonsRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])

        view = root
    }

    @objc private func cancelTapped() {
        finishCancelledIfNeeded()
        closeSheet()
    }

    @objc private func confirmTapped() {
        didConfirm = true
        let mode: SnippetStore.ImportMode
        switch modePopup.indexOfSelectedItem {
        case 1: mode = .skipConflicts
        case 2: mode = .intoNewGroup
        default: mode = .merge
        }
        closeSheet()
        onConfirm(mode)
    }

    private func finishCancelledIfNeeded() {
        guard !didConfirm, !didCancel else { return }
        didCancel = true
        onCancel?()
    }

    private func closeSheet() {
        if let window = view.window, let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            view.window?.close()
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        preview.items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard preview.items.indices.contains(row) else { return nil }
        let item = preview.items[row]

        let cell = NSTableCellView()
        let pill = PillBadgeView(text: item.snippet.triggerKeyword, tint: DevTypeTheme.accent, font: DevTypeTheme.mono(11, .bold))
        let titleLabel = DevTypeTheme.makeLabel(item.snippet.displayTitle, font: DevTypeTheme.font(12, .medium), color: DevTypeTheme.textPrimary)
        let groupLabel = DevTypeTheme.makeLabel(item.groupName, font: DevTypeTheme.font(10.5), color: DevTypeTheme.textTertiary)

        let statusTint: NSColor
        switch item.status {
        case .isNew: statusTint = DevTypeTheme.statusGreen
        case .isUpdate: statusTint = DevTypeTheme.statusBlue
        case .isConflict: statusTint = DevTypeTheme.statusOrange
        }
        let statusPill = PillBadgeView(text: loc.s(item.status.localizationKey), tint: statusTint)

        let leftStack = NSStackView(views: [pill, titleLabel, groupLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = 8
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        statusPill.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(leftStack)
        cell.addSubview(statusPill)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            leftStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: statusPill.leadingAnchor, constant: -10),

            statusPill.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            statusPill.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }
}
