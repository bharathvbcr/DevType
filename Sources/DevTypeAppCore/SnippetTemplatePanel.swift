import AppKit
import ExpanderEngine

/// Sheet listing AI + general snippet templates. Selecting a row opens the editor pre-filled.
enum SnippetTemplatePanel {
    private static var activePanel: NSPanel?
    private static var activeController: SnippetTemplateController?

    static func present(
        from hostWindow: NSWindow?,
        loc: LocalizationManager = .shared,
        onPick: @escaping (SnippetTemplate) -> Void
    ) {
        // Same single-instance contract as MacroPalettePanel.present: a second
        // presentation while one is up would overwrite the statics, and finishing
        // the first would then nil them out from under the second.
        if activePanel != nil { return }
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Usually presented with `beginSheet`, so the host window stays main; taking
        // main-window status here is what the private subclass declined, and this
        // preserves it on both the sheet and the standalone path.
        panel.takesMainWindowStatus = false
        DevTypeTheme.styleFloatingPanel(panel)

        let controller = SnippetTemplateController(
            loc: loc,
            onFinish: { template in
                if let host = hostWindow, panel.isSheet {
                    host.endSheet(panel)
                }
                panel.close()
                activePanel = nil
                activeController = nil
                if let template {
                    onPick(template)
                }
            }
        )
        panel.contentView = controller.view

        activePanel = panel
        activeController = controller

        if let hostWindow {
            hostWindow.beginSheet(panel, completionHandler: nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.focusTable()
    }
}

// MARK: - Controller

private final class SnippetTemplateController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case header(String)
        case template(SnippetTemplate)
    }

    private let loc: LocalizationManager
    private let onFinish: (SnippetTemplate?) -> Void
    private let rows: [Row]
    private let tableView = NSTableView()

    init(loc: LocalizationManager, onFinish: @escaping (SnippetTemplate?) -> Void) {
        self.loc = loc
        self.onFinish = onFinish
        var built: [Row] = [.header(loc.s("manager.template.section.ai"))]
        built += SnippetTemplateCatalog.aiTemplates.map { .template($0) }
        built.append(.header(loc.s("manager.template.section.general")))
        built += SnippetTemplateCatalog.generalTemplates.map { .template($0) }
        self.rows = built
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let glass = GlassContainerView(
            cornerRadius: DevTypeTheme.Radius.panel,
            tint: DevTypeTheme.accent.withAlphaComponent(0.09),
            material: .popover
        )
        glass.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        let root = glass.contentView

        let badge = IconBadgeView(
            symbol: "square.on.square",
            tint: DevTypeTheme.accent,
            size: 34,
            pointSize: 15
        )
        let title = DevTypeTheme.makeLabel(
            loc.s("manager.template.title"),
            font: DevTypeTheme.font(15, .bold),
            color: DevTypeTheme.textPrimary
        )
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = DevTypeTheme.makeLabel(
            loc.s("manager.template.subtitle"),
            font: DevTypeTheme.font(11),
            color: DevTypeTheme.textSecondary,
            wrapping: true
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let aiHint = DevTypeTheme.makeLabel(
            loc.s("manager.template.ai.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        aiHint.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = false
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(useSelected)
        tableView.setAccessibilityLabel(loc.s("manager.template.title"))
        if tableView.tableColumns.isEmpty {
            tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("template")))
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = tableView

        let cancel = CapsuleButton(
            title: loc.s("common.cancel"),
            symbol: nil,
            style: .secondary,
            target: self,
            action: #selector(cancelTapped)
        )
        let use = CapsuleButton(
            title: loc.s("manager.template.use"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(useSelected)
        )
        let buttons = NSStackView(views: [cancel, use])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(badge)
        root.addSubview(title)
        root.addSubview(subtitle)
        root.addSubview(aiHint)
        root.addSubview(scroll)
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            title.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),

            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            subtitle.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 12),

            aiHint.leadingAnchor.constraint(equalTo: subtitle.leadingAnchor),
            aiHint.trailingAnchor.constraint(equalTo: subtitle.trailingAnchor),
            aiHint.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 6),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: aiHint.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])

        // Select first template row (skip AI header).
        if let first = rows.firstIndex(where: {
            if case .template = $0 { return true }
            return false
        }) {
            tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }

        view = glass
    }

    func focusTable() {
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.tableView)
        }
    }

    @objc private func cancelTapped() { onFinish(nil) }

    @objc private func useSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .template(let template) = rows[row] else { return }
        onFinish(template)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = DevTypeTheme.makeLabel(
                title.uppercased(),
                font: DevTypeTheme.font(10, .semibold),
                color: DevTypeTheme.textTertiary
            )
            label.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView()
            wrap.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -8),
                label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2)
            ])
            return wrap

        case .template(let template):
            let cell = TemplateRowView()
            cell.configure(
                title: loc.s(template.titleKey),
                trigger: template.trigger,
                symbol: template.symbol,
                isAI: template.section == .ai
            )
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .template = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 26 }
        return 38
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { // Return / keypad Enter
            useSelected()
            return
        }
        if event.keyCode == 53 { // Escape
            cancelTapped()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Row

private final class TemplateRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(12.5, .medium), color: DevTypeTheme.textPrimary)
    private let triggerPill = PillBadgeView(text: "", tint: DevTypeTheme.accent, font: DevTypeTheme.mono(10.5, .bold))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(triggerPill)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: triggerPill.leadingAnchor, constant: -8),

            triggerPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            triggerPill.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, trigger: String, symbol: String, isAI: Bool) {
        titleLabel.stringValue = title
        triggerPill.update(text: trigger, tint: isAI ? DevTypeTheme.statusBlue : DevTypeTheme.accent)
        iconView.image = DevTypeTheme.tintedSymbol(
            symbol,
            size: 12,
            weight: .semibold,
            color: isAI ? DevTypeTheme.statusBlue : DevTypeTheme.textSecondary
        )
        setAccessibilityLabel("\(title), \(trigger)")
    }
}
