import AppKit
import ExpanderEngine

/// Secret mutations delegate to the existing atomic library and resource transactions.
/// The compatibility snippet is confined to that seam; the editor handles SecretModel only.
enum SecretLibraryEdit {
    static func applying(_ candidate: SecretModel?, replacing existing: SecretModel?,
                         to groups: inout [SnippetGroup]) -> Bool {
        var document = SnippetDocument(groups: groups)
        if let existing {
            guard let index = document.secrets.firstIndex(where: { $0.id == existing.id }),
                  document.secrets[index] == existing else { return false }
            if let candidate {
                guard candidate.id == existing.id else { return false }
                document.secrets[index] = candidate
            } else {
                document.secrets.remove(at: index)
            }
        } else {
            guard let candidate,
                  !document.snippets.contains(where: { $0.id == candidate.id }) else { return false }
            document.secrets.append(candidate)
        }
        groups = document.transactionGroups
        return true
    }
}

final class SecretEditorController: NSViewController {
    let nameField = NSTextField()
    let valueField = NSSecureTextField()
    let tagsField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let existing: SecretModel?
    private let draft: SecretModel
    private let store: SnippetStore
    private let transaction: SnippetEditTransaction
    private let loc: LocalizationManager
    private let onDismiss: () -> Void

    init(existing: SecretModel?, store: SnippetStore = .shared,
         resources: SnippetEditResourceAccess = .live, loc: LocalizationManager = .shared,
         onDismiss: @escaping () -> Void) {
        self.existing = existing
        self.draft = existing ?? SecretModel(title: "")
        self.store = store
        self.transaction = SnippetEditTransaction(resources: resources)
        self.loc = loc
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 350))
        view = root
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor
        nameField.stringValue = draft.displayTitle
        nameField.identifier = .init("secret.name")
        valueField.identifier = .init("secret.value")
        valueField.placeholderString = loc.s(existing == nil ? "editor.secret.placeholder" : "editor.secret.unchanged")
        tagsField.stringValue = draft.tags.joined(separator: ", ")
        enabledButton.title = loc.s("editor.enabled")
        enabledButton.state = draft.enabled ? .on : .off
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        let save = CapsuleButton(title: loc.s("secrets.save"), style: .primary, target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        let cancel = CapsuleButton(title: loc.s("common.cancel"), target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let heading = NSTextField(labelWithString: loc.s(existing == nil ? "secrets.add" : "secrets.edit"))
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(heading)
        for (key, field) in [("secrets.name", nameField), ("secrets.value", valueField), ("secrets.tags", tagsField)] {
            let label = NSTextField(labelWithString: loc.s(key))
            field.setAccessibilityLabel(loc.s(key))
            field.setAccessibilityTitleUIElement(label)
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(enabledButton)
        stack.addArrangedSubview(errorLabel)
        stack.addArrangedSubview(buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc func saveTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 256 else {
            errorLabel.stringValue = loc.s("secrets.name.required")
            return
        }
        let value = valueField.stringValue
        guard existing != nil || !value.isEmpty else {
            errorLabel.stringValue = loc.s("editor.secret.placeholder")
            return
        }
        var candidate = draft
        candidate.title = name
        candidate.label = ""
        candidate.tags = tagsField.stringValue.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        candidate.enabled = enabledButton.state == .on
        candidate.updatedAt = Date()
        let outcome = transaction.save(
            snippet: candidate.snippetAdapter, existing: existing?.snippetAdapter, pickedImageURL: nil,
            secretIntent: value.isEmpty ? .unchanged : .set(value), groupID: nil
        ) { [store, existing] _, _ in
            .mutating(store: store, mutation: { groups in
                SecretLibraryEdit.applying(candidate, replacing: existing, to: &groups)
            }, finalize: { _, _ in })
        }
        switch outcome {
        case .committed:
            valueField.stringValue = ""
            onDismiss()
        case .committedWithWarning:
            errorLabel.stringValue = loc.s("editor.transaction.commitWarning.message")
        case .failed(let failure):
            let key: String
            switch failure {
            case .secretRead: key = "editor.transaction.secretReadFailed"
            case .secretWrite: key = "editor.transaction.secretWriteFailed"
            case .rollback: key = "editor.transaction.rollbackFailed"
            case .persistence: key = "secrets.save.failed"
            case .imageStaging, .commitCleanup: key = "editor.transaction.commitWarning.message"
            }
            errorLabel.stringValue = loc.s(key)
        }
    }

    @objc func cancelTapped() {
        guard transaction.cancel() == .clean else {
            errorLabel.stringValue = loc.s("editor.transaction.rollbackFailed")
            return
        }
        valueField.stringValue = ""
        onDismiss()
    }
}

enum SecretEditorSheet {
    static func present(from host: NSWindow, existing: SecretModel?, store: SnippetStore = .shared) {
        guard host.attachedSheet == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 410),
                            styleMask: [.titled], backing: .buffered, defer: false)
        let controller = SecretEditorController(existing: existing, store: store) { [weak host, weak panel] in
            guard let panel else { return }
            host?.endSheet(panel)
            panel.close()
        }
        panel.contentViewController = controller
        host.beginSheet(panel)
        panel.makeFirstResponder(controller.nameField)
    }
}
