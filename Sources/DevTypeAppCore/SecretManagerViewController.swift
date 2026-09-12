import AppKit
import ExpanderEngine

/// A table that answers the keyboard.
///
/// Delete is handled here rather than as a button key equivalent on purpose: a key equivalent
/// fires wherever focus happens to be, so ⌫ would delete the selected secret while the user was
/// editing the search field. Bound to the table, it can only fire when the list has focus.
private final class SecretTableView: NSTableView {
    var onReturn: () -> Void = {}
    var onDelete: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn()          // Return, numpad Enter
        case 51, 117: onDelete()         // Delete, forward delete
        default: super.keyDown(with: event)
        }
    }
}

/// One secret, as two lines: what it is, and what it carries.
///
/// The value is never among the things it can render — `SecretModel` has no field holding one —
/// so the dots are a fixed mask rather than a redaction of something present.
private final class SecretRowView: NSView {
    private let titleLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(13, .semibold), color: DevTypeTheme.textPrimary)
    private let maskLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11), color: DevTypeTheme.textTertiary)
    private let detailLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11), color: DevTypeTheme.textSecondary)
    private let disabledBadge = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10, .semibold), color: DevTypeTheme.textTertiary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        disabledBadge.wantsLayer = true
        disabledBadge.layer?.cornerRadius = 4
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail

        let top = NSStackView(views: [titleLabel, disabledBadge])
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.spacing = 6
        let bottom = NSStackView(views: [maskLabel, detailLabel])
        bottom.orientation = .horizontal
        bottom.alignment = .firstBaseline
        bottom.spacing = 8
        let stack = NSStackView(views: [top, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ secret: SecretModel, loc: LocalizationManager) {
        titleLabel.stringValue = secret.displayTitle
        maskLabel.stringValue = "••••••••"
        detailLabel.stringValue = secret.tags.joined(separator: " · ")
        detailLabel.isHidden = secret.tags.isEmpty
        disabledBadge.stringValue = secret.enabled ? "" : "  " + loc.s("manager.filter.disabled") + "  "
        disabledBadge.isHidden = secret.enabled
        titleLabel.textColor = secret.enabled ? DevTypeTheme.textPrimary : DevTypeTheme.textTertiary
        toolTip = secret.displayTitle
        // One spoken string per row: VoiceOver should not make the reader assemble four labels.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            [secret.displayTitle,
             secret.tags.isEmpty ? nil : secret.tags.joined(separator: ", "),
             secret.enabled ? nil : loc.s("manager.filter.disabled")]
                .compactMap { $0 }.joined(separator: ", ")
        )
    }
}

final class SecretManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: SnippetStore
    private let onCopy: (SecretModel) -> Void
    private let onRepair: () -> Void
    private let loc: LocalizationManager
    private let search = NSSearchField()
    private let table = SecretTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var secrets: [SecretModel] = []
    private var listener: UUID?
    private var selectionButtons: [NSButton] = []
    private var copyButton: NSButton?
    private let emptyBadge = IconBadgeView(symbol: "key.fill", tint: DevTypeTheme.accent, size: 46, pointSize: 20)
    private let emptyTitle = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(13, .semibold), color: DevTypeTheme.textSecondary)
    private let emptySubtitle = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11), color: DevTypeTheme.textTertiary, wrapping: true)
    private let emptyCTA = CapsuleButton(title: "", symbol: "plus", style: .primary, target: nil, action: nil)
    private let emptyState = NSStackView()

    init(store: SnippetStore = .shared, loc: LocalizationManager = .shared,
         onCopy: @escaping (SecretModel) -> Void, onRepair: @escaping () -> Void) {
        self.store = store
        self.loc = loc
        self.onCopy = onCopy
        self.onRepair = onRepair
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 470))
        view.wantsLayer = true
        view.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        let badge = IconBadgeView(symbol: "key.fill", tint: DevTypeTheme.accent, size: 34, pointSize: 15)
        let title = DevTypeTheme.makeLabel(loc.s("secrets.title"),
                                           font: DevTypeTheme.font(20, .semibold), color: DevTypeTheme.textPrimary)
        let hint = DevTypeTheme.makeLabel(loc.s("secrets.hint"),
                                          font: DevTypeTheme.font(11), color: DevTypeTheme.textTertiary, wrapping: true)
        let headingText = NSStackView(views: [title, hint])
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 2
        let header = NSStackView(views: [badge, headingText])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 10

        search.placeholderString = loc.s("menu.searchSecrets.placeholder")
        search.target = self
        search.action = #selector(reload)
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel(loc.s("menu.searchSecrets.placeholder"))

        let column = NSTableColumn(identifier: .init("secret"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editSecret)
        table.onReturn = { [weak self] in self?.copySecret() }
        table.onDelete = { [weak self] in self?.deleteSecret() }
        table.setAccessibilityLabel(loc.s("secrets.title"))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.05))
        card.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(scroll)

        emptyTitle.alignment = .center
        emptySubtitle.alignment = .center
        emptyCTA.title = loc.s("secrets.add")
        emptyCTA.identifier = .init("secrets.empty.cta")
        emptyCTA.target = self
        emptyCTA.action = #selector(addSecret)
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addArrangedSubview(emptyBadge)
        emptyState.addArrangedSubview(emptyTitle)
        emptyState.addArrangedSubview(emptySubtitle)
        emptyState.addArrangedSubview(emptyCTA)
        emptyState.setCustomSpacing(12, after: emptySubtitle)
        card.contentView.addSubview(emptyState)

        status.font = DevTypeTheme.font(11)
        status.textColor = .systemOrange

        let keyboardHint = DevTypeTheme.makeLabel(loc.s("secrets.keyboard.hint"),
                                                  font: DevTypeTheme.font(10), color: DevTypeTheme.textTertiary)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        // Symbols match the snippet manager's action bar: the two windows are siblings and should
        // not read as two different apps.
        for (key, symbol, action, style) in [
            ("secrets.add", "plus", #selector(addSecret), CapsuleButton.Style.primary),
            ("secrets.edit", "pencil", #selector(editSecret), .secondary),
            ("menu.copySecret", "doc.on.doc", #selector(copySecret), .secondary),
            ("secrets.delete", "trash", #selector(deleteSecret), .destructive)
        ] {
            let button = CapsuleButton(title: loc.s(key), symbol: symbol, style: style, target: self, action: action)
            buttons.addArrangedSubview(button)
            if key != "secrets.add" { selectionButtons.append(button) }
            if key == "menu.copySecret" { copyButton = button }
            // Modifier-based only. An unmodified key equivalent fires from the search field too.
            if key == "secrets.add" { button.keyEquivalent = "n"; button.keyEquivalentModifierMask = .command }
            if key == "secrets.edit" { button.keyEquivalent = "e"; button.keyEquivalentModifierMask = .command }
        }
        let buttonSpacer = NSView()
        buttonSpacer.translatesAutoresizingMaskIntoConstraints = false
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(buttonSpacer)

        let repair = CapsuleButton(title: loc.s("secrets.repair"), target: self, action: #selector(repairStorage))
        repair.toolTip = loc.s("secrets.repair.hint")
        repair.font = DevTypeTheme.font(11, .medium)

        let footer = NSStackView(views: [keyboardHint, repair])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        let stack = NSStackView(views: [header, search, card, status, buttons, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(14, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -22),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            scroll.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -4),
            emptyState.centerXAnchor.constraint(equalTo: card.contentView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: card.contentView.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: card.contentView.widthAnchor, constant: -48)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        listener = store.addGroupListener { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The list is what this window is for; typing should filter, but arrowing should work
        // without a click first.
        view.window?.makeFirstResponder(table)
    }

    deinit {
        if let listener { store.removeListener(token: listener) }
    }

    @objc private func reload() {
        let selectedID = selection?.id
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = store.loadSecrets()
        secrets = all.filter {
            query.isEmpty || ([$0.title, $0.label] + $0.tags).contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        table.reloadData()
        if let selectedID, let row = secrets.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        refreshActions()
        applyEmptyState(hasAnySecret: !all.isEmpty, isSearching: !query.isEmpty)
        if store.isLibraryReadFailed {
            status.stringValue = loc.s("secrets.save.failed")
        } else if store.pendingSecretCleanupCount > 0 {
            status.stringValue = loc.s("secrets.cleanup.pending")
        } else {
            status.stringValue = ""
        }
        status.isHidden = status.stringValue.isEmpty
    }

    /// Two different empty lists. "You have none yet" invites adding one; "none match" invites
    /// changing the query — offering "Add Secret" to someone whose search simply missed would be
    /// answering a question they did not ask.
    private func applyEmptyState(hasAnySecret: Bool, isSearching: Bool) {
        emptyState.isHidden = !secrets.isEmpty
        guard secrets.isEmpty else { return }
        let searching = isSearching && hasAnySecret
        emptyTitle.stringValue = loc.s(searching ? "secrets.empty.noMatch.title" : "secrets.empty.title")
        emptySubtitle.stringValue = loc.s(searching ? "secrets.empty.noMatch.subtitle" : "secrets.empty.subtitle")
        emptyCTA.isHidden = searching
    }

    private func refreshActions() {
        for button in selectionButtons { button.isEnabled = selection != nil }
        copyButton?.isEnabled = selection?.enabled == true
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshActions() }

    private var selection: SecretModel? {
        secrets.indices.contains(table.selectedRow) ? secrets[table.selectedRow] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { secrets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard secrets.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("secretRow")
        let cell: SecretRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? SecretRowView {
            cell = reused
        } else {
            cell = SecretRowView()
            cell.identifier = identifier
        }
        cell.configure(secrets[row], loc: loc)
        return cell
    }

    @objc private func addSecret() {
        guard let window = view.window else { return }
        SecretEditorSheet.present(from: window, existing: nil, store: store)
    }

    @objc private func editSecret() {
        guard let secret = selection, let window = view.window else { return }
        SecretEditorSheet.present(from: window, existing: secret, store: store)
    }

    @objc private func copySecret() {
        guard let secret = selection, secret.enabled,
              store.loadSecrets().contains(secret) else { return }
        onCopy(secret)
    }

    @objc private func repairStorage() { onRepair() }

    @objc private func deleteSecret() {
        guard let secret = selection else { return }
        DevTypeAlert.present(title: loc.s("secrets.delete"),
            message: loc.s("manager.delete.confirm.secret", secret.displayTitle), style: .warning,
            buttons: [loc.s("secrets.delete"), loc.s("common.cancel")]) { [weak self] index in
            guard index == 0, let self else { return }
            let result = self.store.mutateGroups { groups in
                SecretLibraryEdit.applying(nil, replacing: secret, to: &groups)
            }
            self.reload()
            switch result {
            case .saved, .unchanged:
                self.store.requestOrphanSecretCleanupRetry { [weak self] _ in
                    DispatchQueue.main.async { self?.reload() }
                }
            case .rejected, .refused:
                self.status.stringValue = self.loc.s("secrets.save.failed")
                self.status.isHidden = false
            }
        }
    }
}
