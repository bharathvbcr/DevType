import AppKit
import ExpanderEngine

final class SecretManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: SnippetStore
    private let onCopy: (SecretModel) -> Void
    private let onRepair: () -> Void
    private let loc: LocalizationManager
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var secrets: [SecretModel] = []
    private var listener: UUID?
    private var selectionButtons: [NSButton] = []
    private var copyButton: NSButton?

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
        let title = NSTextField(labelWithString: loc.s("secrets.title"))
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: loc.s("secrets.hint"))
        hint.textColor = .secondaryLabelColor
        search.placeholderString = loc.s("menu.searchSecrets.placeholder")
        search.target = self
        search.action = #selector(reload)
        search.sendsSearchStringImmediately = true
        let column = NSTableColumn(identifier: .init("secret"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editSecret)
        table.setAccessibilityLabel(loc.s("secrets.title"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for (key, action) in [("secrets.add", #selector(addSecret)), ("secrets.edit", #selector(editSecret)),
                              ("menu.copySecret", #selector(copySecret)), ("secrets.delete", #selector(deleteSecret))] {
            let button = CapsuleButton(title: loc.s(key), style: key == "secrets.delete" ? .destructive : .secondary, target: self, action: action)
            buttons.addArrangedSubview(button)
            if key != "secrets.add" { selectionButtons.append(button) }
            if key == "menu.copySecret" { copyButton = button }
        }
        let repair = CapsuleButton(title: loc.s("secrets.repair"), target: self, action: #selector(repairStorage))
        repair.toolTip = loc.s("secrets.repair.hint")
        let stack = NSStackView(views: [title, hint, search, scroll, status, buttons, repair])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        listener = store.addGroupListener { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
        reload()
    }

    deinit {
        if let listener { store.removeListener(token: listener) }
    }

    @objc private func reload() {
        let selectedID = selection?.id
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        secrets = store.loadSecrets().filter {
            query.isEmpty || ([$0.title, $0.label] + $0.tags).contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        table.reloadData()
        if let selectedID, let row = secrets.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        refreshActions()
        if store.isLibraryReadFailed {
            status.stringValue = loc.s("secrets.save.failed")
        } else if store.pendingSecretCleanupCount > 0 {
            status.stringValue = loc.s("secrets.cleanup.pending")
        } else {
            status.stringValue = secrets.isEmpty ? loc.s("secrets.empty") : ""
        }
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
        let secret = secrets[row]
        let cell = NSTextField(labelWithString: secret.displayTitle + "   ••••••••" +
            (secret.enabled ? "" : "   " + loc.s("manager.filter.disabled")))
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = secret.displayTitle
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
            }
        }
    }
}
