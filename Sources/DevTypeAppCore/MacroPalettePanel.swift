import AppKit
import Carbon.HIToolbox
import ExpanderEngine

// MARK: - §2: searchable macro palette
//
// Replaces the flat `NSMenu` that `SnippetEditorController.showMacroMenu` used to
// pop. That menu had no descriptions, no examples, no search, no keyboard
// affordance, and exposed nine of the ~45 macros the engine actually understands.
//
// The interaction grammar is deliberately identical to `InlineSearchPanel`, which
// is the app's other keyboard palette: type to filter, ↑/↓ to move, Return to
// commit, Esc to dismiss. Learning one teaches the other.
//
// Presentation note: this is shown as a **sheet on the editor panel**, not as a
// free-floating window. The editor is itself a sheet, and a borderless
// `.nonactivatingPanel` layered over a document-modal session is not reliably
// able to become key. `NSOpenPanel.beginSheetModal(for:)` is already used the
// same way in this editor (the image picker), so nested sheets are a proven path
// here. `present` returns `false` when it cannot present, and the caller falls
// back to the legacy menu.

enum MacroPalettePanel {

    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private static var activePanel: NSPanel?
    private static var activeController: MacroPaletteController?
    private static var activeHost: NSWindow?

    static var isOpen: Bool { activePanel != nil }

    /// Returns `false` when the palette could not be presented, so the caller can
    /// fall back to a plain menu instead of leaving the button dead.
    @discardableResult
    static func present(
        from hostWindow: NSWindow?,
        loc: LocalizationManager = .shared,
        onInsert: @escaping (MacroDescriptor) -> Void
    ) -> Bool {
        guard let hostWindow else { return false }
        if activePanel != nil { return true }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 440),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)
        // `styleFloatingPanel` raises the level for free-floating palettes; a
        // sheet must sit at normal level or it detaches from its host.
        panel.level = .normal
        panel.isMovableByWindowBackground = false

        let controller = MacroPaletteController(
            loc: loc,
            onPick: { descriptor in
                dismiss()
                onInsert(descriptor)
            },
            onCancel: { dismiss() }
        )
        panel.contentView = controller.view

        activePanel = panel
        activeController = controller
        activeHost = hostWindow

        hostWindow.beginSheet(panel, completionHandler: nil)
        DispatchQueue.main.async { controller.focusSearch() }
        return true
    }

    static func dismiss() {
        guard let panel = activePanel else { return }
        let controller = activeController
        let host = activeHost
        activePanel = nil
        activeController = nil
        activeHost = nil

        controller?.teardown()
        host?.endSheet(panel)
        panel.close()
        // `dismiss()` is normally reached from a closure the controller owns.
        // Hold the last strong reference until the next runloop turn so the
        // closure is not deallocated while its own body is still executing.
        DispatchQueue.main.async { _ = controller }
    }
}

// MARK: - Rows

/// Flattened list model: category headers interleaved with their macros.
private enum MacroPaletteRow {
    case header(MacroCategory)
    case macro(MacroDescriptor)

    var isSelectable: Bool {
        if case .macro = self { return true }
        return false
    }
}

/// Non-selectable section caption.
private final class MacroCategoryHeaderView: NSView {
    private let label = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(10.5, .bold),
        color: DevTypeTheme.accentBright
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        label.stringValue = title
        // §4: the header is real structure, not decoration — name it, but keep
        // its children out of the tree so it speaks once.
        dtHideSubviewsFromAccessibility()
        dtApplyAccessibility(role: NSAccessibility.Role.staticText, label: title)
    }
}

/// One macro row: name + description on the left, raw token + live example right.
private final class MacroPaletteCellView: NSView {
    private let nameLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(13, .semibold),
        color: DevTypeTheme.textPrimary
    )
    private let detailLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11),
        color: DevTypeTheme.textSecondary
    )
    private let tokenLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.mono(11, .medium),
        color: DevTypeTheme.accentBright
    )
    private let exampleLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.mono(11),
        color: DevTypeTheme.textTertiary
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [nameLabel, detailLabel, tokenLabel, exampleLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
        }
        tokenLabel.alignment = .right
        exampleLabel.alignment = .right

        addSubview(nameLabel)
        addSubview(detailLabel)
        addSubview(tokenLabel)
        addSubview(exampleLabel)

        NSLayoutConstraint.activate([
            // Fixed-width right column keeps names aligned across every row,
            // exactly like the trigger/group columns in InlineSearchPanel.
            tokenLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            tokenLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            tokenLabel.widthAnchor.constraint(equalToConstant: 210),

            exampleLabel.trailingAnchor.constraint(equalTo: tokenLabel.trailingAnchor),
            exampleLabel.topAnchor.constraint(equalTo: tokenLabel.bottomAnchor, constant: 2),
            exampleLabel.widthAnchor.constraint(equalToConstant: 210),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(equalTo: tokenLabel.leadingAnchor, constant: -12),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with descriptor: MacroDescriptor, loc: LocalizationManager) {
        let name = descriptor.name(using: loc)
        let detail = descriptor.detail(using: loc)
        // The example is produced by the live engine every time the row is drawn,
        // so it can never drift from actual expansion behaviour.
        let example = descriptor.example
        // Multi-line tokens (the fillpart pair) would blow the row height apart.
        let flatToken = descriptor.token
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\t", with: "⇥")

        nameLabel.stringValue = name
        detailLabel.stringValue = detail
        tokenLabel.stringValue = flatToken
        exampleLabel.stringValue = example
        tokenLabel.toolTip = flatToken
        detailLabel.toolTip = detail
        exampleLabel.toolTip = example.isEmpty ? nil : example

        // §4: four bare NSTextFields in a plain NSView announce nothing. Collapse
        // the row into a single labelled element carrying the token and example.
        dtHideSubviewsFromAccessibility()
        dtApplyAccessibility(
            role: NSAccessibility.Role.row,
            label: loc.s("ax.macroRow", name, flatToken),
            value: example.isEmpty ? detail : loc.s("ax.macroRow.example", example),
            help: loc.s("ax.macroRow.help")
        )
    }
}

// MARK: - Controller

private final class MacroPaletteController: NSViewController,
                                            NSTableViewDataSource,
                                            NSTableViewDelegate,
                                            NSTextFieldDelegate {
    private let loc: LocalizationManager
    private let onPick: (MacroDescriptor) -> Void
    private let onCancel: () -> Void

    private var rows: [MacroPaletteRow] = []
    private var selection = 0
    private var keyMonitor: Any?

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let countLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(10.5, .medium),
        color: DevTypeTheme.textTertiary
    )
    private let emptyState = NSView()

    private static let headerRowHeight: CGFloat = 26
    private static let macroRowHeight: CGFloat = 46

    init(
        loc: LocalizationManager,
        onPick: @escaping (MacroDescriptor) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.loc = loc
        self.onPick = onPick
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit { removeKeyMonitor() }

    /// Called by the panel before dismissal so the local monitor can never
    /// outlive the palette and swallow arrow keys in the editor behind it.
    func teardown() { removeKeyMonitor() }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    override func loadView() {
        let glass = GlassContainerView(
            cornerRadius: DevTypeTheme.Radius.panel,
            tint: DevTypeTheme.accent.withAlphaComponent(0.10),
            material: .popover
        )
        glass.frame = NSRect(x: 0, y: 0, width: 580, height: 440)
        let root = glass.contentView

        // MARK: Search row
        let badge = IconBadgeView(symbol: "curlybraces", tint: DevTypeTheme.accent, size: 30, pointSize: 14)
        let titleLabel = DevTypeTheme.makeLabel(
            loc.s("macro.palette.title"),
            font: DevTypeTheme.font(14, .bold),
            color: DevTypeTheme.textPrimary
        )
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderAttributedString = NSAttributedString(
            string: loc.s("macro.palette.search"),
            attributes: [
                .foregroundColor: DevTypeTheme.textTertiary,
                .font: DevTypeTheme.font(15, .light)
            ]
        )
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = DevTypeTheme.font(15, .light)
        searchField.textColor = DevTypeTheme.textPrimary
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        // §4: the visual caption is a separate view, so VoiceOver cannot infer it.
        searchField.setAccessibilityLabel(loc.s("ax.macroPalette.search"))

        root.addSubview(badge)
        root.addSubview(titleLabel)
        root.addSubview(searchField)

        let divider = DevTypeTheme.makeHairline()
        root.addSubview(divider)

        // MARK: Results
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.headerView = nil
        tableView.rowHeight = Self.macroRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(insertSelected)
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("macro")))
        tableView.setAccessibilityLabel(loc.s("ax.macroPalette"))
        scrollView.documentView = tableView
        root.addSubview(scrollView)

        setupEmptyState(in: root)

        // MARK: Footer — same key-cap grammar as InlineSearchPanel
        let footerDivider = DevTypeTheme.makeHairline()
        root.addSubview(footerDivider)

        let navigateCap = KeyCapView("↑↓")
        let navigateLabel = DevTypeTheme.makeLabel(
            loc.s("macro.palette.hint.navigate"),
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.textTertiary
        )
        let insertCap = KeyCapView("↩")
        let insertLabel = DevTypeTheme.makeLabel(
            loc.s("macro.palette.hint.insert"),
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.textTertiary
        )
        let closeCap = KeyCapView("esc")
        let closeLabel = DevTypeTheme.makeLabel(
            loc.s("macro.palette.hint.close"),
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.textTertiary
        )

        let footerStack = NSStackView(views: [
            navigateCap, navigateLabel, insertCap, insertLabel, closeCap, closeLabel
        ])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 6
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footerStack)
        root.addSubview(countLabel)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),

            searchField.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -4),

            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footerDivider.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -8),

            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            countLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: footerStack.centerYAnchor)
        ])

        view = glass
    }

    private func setupEmptyState(in root: NSView) {
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = DevTypeTheme.symbol(
            "text.magnifyingglass",
            size: 26,
            weight: .light,
            color: DevTypeTheme.accent.withAlphaComponent(0.7)
        )
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)

        let title = DevTypeTheme.makeLabel(
            loc.s("macro.palette.empty"),
            font: DevTypeTheme.font(13, .semibold),
            color: DevTypeTheme.textSecondary
        )
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = DevTypeTheme.makeLabel(
            loc.s("macro.palette.emptyHint"),
            font: DevTypeTheme.font(11),
            color: DevTypeTheme.textTertiary
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addSubview(stack)
        root.addSubview(emptyState)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        rebuild()
        installKeyMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeKeyMonitor()
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: Filtering

    func controlTextDidChange(_ obj: Notification) {
        rebuild()
    }

    private func rebuild() {
        let sections = MacroPaletteRanking.rank(query: searchField.stringValue, loc: loc)
        var newRows: [MacroPaletteRow] = []
        var matchCount = 0
        for section in sections {
            newRows.append(.header(section.category))
            for match in section.matches {
                newRows.append(.macro(match.descriptor))
            }
            matchCount += section.matches.count
        }

        rows = newRows
        tableView.reloadData()
        selection = firstSelectableIndex(from: 0, step: 1) ?? -1
        applySelection(scroll: true)
        emptyState.isHidden = matchCount > 0
        countLabel.stringValue = loc.s("macro.palette.count", matchCount, MacroCatalog.all.count)
    }

    // MARK: Selection

    private func firstSelectableIndex(from start: Int, step: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        var index = start
        while index >= 0 && index < rows.count {
            if rows[index].isSelectable { return index }
            index += step
        }
        return nil
    }

    private func applySelection(scroll: Bool) {
        guard rows.indices.contains(selection) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        if scroll { tableView.scrollRowToVisible(selection) }
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let start = selection < 0 ? (delta > 0 ? 0 : rows.count - 1) : selection + delta
        guard let next = firstSelectableIndex(from: start, step: delta > 0 ? 1 : -1) else { return }
        selection = next
        applySelection(scroll: true)
    }

    private var selectedDescriptor: MacroDescriptor? {
        guard rows.indices.contains(selection), case .macro(let descriptor) = rows[selection] else {
            return nil
        }
        return descriptor
    }

    // MARK: Keyboard — identical grammar to InlineSearchPanel

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch Int(event.keyCode) {
            case kVK_UpArrow:
                self.moveSelection(-1)
                return nil
            case kVK_DownArrow:
                self.moveSelection(1)
                return nil
            case kVK_Escape:
                self.onCancel()
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    self.insertSelected()
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    @objc private func insertSelected() {
        guard let descriptor = selectedDescriptor else { return }
        CommandUsageStatsStore.shared.recordUsage(for: MacroPaletteRanking.usageID(descriptor))
        onPick(descriptor)
    }

    // MARK: Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return Self.macroRowHeight }
        switch rows[row] {
        case .header: return Self.headerRowHeight
        case .macro: return Self.macroRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let category):
            let identifier = NSUserInterfaceItemIdentifier("macroHeader")
            let cell: MacroCategoryHeaderView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? MacroCategoryHeaderView {
                cell = reused
            } else {
                cell = MacroCategoryHeaderView()
                cell.identifier = identifier
            }
            cell.configure(title: loc.s(category.titleKey))
            return cell
        case .macro(let descriptor):
            let identifier = NSUserInterfaceItemIdentifier("macroCell")
            let cell: MacroPaletteCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? MacroPaletteCellView {
                cell = reused
            } else {
                cell = MacroPaletteCellView()
                cell.identifier = identifier
            }
            cell.configure(with: descriptor, loc: loc)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard rows.indices.contains(row), rows[row].isSelectable else { return NSTableRowView() }
        return RoundedSelectionRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = tableView.selectedRow
        guard selected >= 0 else { return }
        selection = selected
    }
}
