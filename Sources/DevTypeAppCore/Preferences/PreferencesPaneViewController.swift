import AppKit
import ExpanderEngine

// MARK: - Card stack markers

/// Marker views let the shared card stack stretch rows and table areas while
/// preserving intrinsic widths for individual controls and buttons.
final class PreferenceRowView: NSView {}
final class PreferenceTableAreaView: NSView {}

// MARK: - Pane controller

/// One Preferences tab: a scrolling stack of cards plus the shared card, row and list helpers
/// every tab builds with. `PreferencesViewController` owns selection and decides when each
/// hook runs; subclasses override `build(into:)`, `reload()` and, if needed, `didSelect()` or `refreshesOnSelect`.
class PreferencesPaneViewController: NSViewController,
                                     NSTableViewDataSource,
                                     NSTableViewDelegate {

    let loc = LocalizationManager.shared
    let store = SnippetStore.shared
    private var removalButtons: [ObjectIdentifier: CapsuleButton] = [:]

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The pane is its own scroll view, so the host can pin it and read its scroll origin.
    override func loadView() {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        build(into: stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        view = scroll
    }

    /// Adds this tab's cards to the pane's stack. Runs once, when the view first loads.
    func build(into stack: NSStackView) {}

    /// Repopulates this tab's controls from current preferences.
    func reload() {}

    /// Runs every time the tab is selected, after its pane has been built.
    func didSelect() {}

    /// True when the tab's values can drift while it is hidden (live diagnostics, availability),
    /// so the host reloads it on every selection. The host skips this on the selection that
    /// builds the pane, which has just been populated.
    var refreshesOnSelect: Bool { false }

    // MARK: Table data source / delegate

    /// Tabs that own lists override this and `tableView(_:viewFor:row:)` for their own tables.
    func numberOfRows(in tableView: NSTableView) -> Int { 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        nil
    }

    /// The one cell every Preferences list renders: a single truncating label whose
    /// accessibility label is its content.
    func makeRowLabel(
        in tableView: NSTableView,
        column tableColumn: NSTableColumn?,
        text: String,
        font: NSFont = DevTypeTheme.mono(11)
    ) -> NSTextField {
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
        label.font = font
        label.stringValue = text
        label.textColor = DevTypeTheme.textPrimary
        // §5.1: rows read as their content instead of "row N".
        label.setAccessibilityLabel(text)
        return label
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = RoundedSelectionRowView.dequeue(from: tableView, owner: self)
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
    func makeTableArea(
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

    func bindRemovalButton(_ button: CapsuleButton, to tableView: NSTableView) {
        removalButtons[ObjectIdentifier(tableView)] = button
        refreshRemovalButton(for: tableView)
    }

    func refreshRemovalButton(for tableView: NSTableView) {
        removalButtons[ObjectIdentifier(tableView)]?.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    func makeCard(title: String, symbol: String) -> GlassCardView {
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
    func stackInCard(_ card: GlassCardView, views: [NSView]) {
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

    func makeToggleRow(title: String, toggle: NSSwitch, action: Selector) -> NSView {
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

    func makeLabeledControlRow(
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

    func pinWidth(of views: [NSView], to stack: NSStackView) {
        for subview in views {
            subview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

extension NSTextField {
    /// The field editor owns keystrokes while a text field is active. Reading only the control's
    /// cell can lag that editor, which would drop the last uncommitted characters during a rebuild.
    var transientValue: String {
        currentEditor()?.string ?? stringValue
    }
}
