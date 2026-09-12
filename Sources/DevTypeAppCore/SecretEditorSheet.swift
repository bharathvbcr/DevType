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
    /// Fetching a stored secret so it can be shown is a read of secret material, so it takes the
    /// same Touch ID gate as the copy flow. Injected only so tests can drive the gate's outcomes
    /// without a prompt — the default is the one gated resolver, never `SecretStore` directly.
    typealias GatedSecretRead =
        (SnippetModel, @escaping (Result<String, SecretMenuFlow.ResolveFailure>) -> Void) -> Void

    let nameField = NSTextField()
    /// The concealed field. `revealedField` is its plain-text twin; exactly one of the two is in
    /// the view hierarchy at any moment, so the editor always presents three editable text
    /// fields — name, value, tags — and never four.
    let valueField = NSSecureTextField()
    let revealedField = NSTextField()
    let tagsField = NSTextField()
    private let revealButton = CapsuleButton(title: "", symbol: "eye", style: .secondary, target: nil, action: nil)
    private var isRevealed = false
    private let valueRow = NSStackView()
    private let revealNotice = NSTextField(wrappingLabelWithString: "")
    private let unchangedHint = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let existing: SecretModel?
    private let draft: SecretModel
    private let store: SnippetStore
    private let transaction: SnippetEditTransaction
    private let loc: LocalizationManager
    private let revealStoredValue: GatedSecretRead
    private let onDismiss: () -> Void
    /// Fetched at most once per editor: a second Show must not ask for Touch ID again, and
    /// clearing the field is an edit rather than a request to re-read what is stored.
    private var hasLoadedStoredValue = false
    /// A prompt is already on screen; a second click must not stack another one behind it.
    private var isAuthenticating = false

    init(existing: SecretModel?, store: SnippetStore = .shared,
         resources: SnippetEditResourceAccess = .live, loc: LocalizationManager = .shared,
         revealStoredValue: @escaping GatedSecretRead = { SecretMenuFlow.resolve($0, completion: $1) },
         onDismiss: @escaping () -> Void) {
        self.existing = existing
        self.draft = existing ?? SecretModel(title: "")
        self.store = store
        self.transaction = SnippetEditTransaction(resources: resources)
        self.loc = loc
        self.revealStoredValue = revealStoredValue
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// The field currently presenting the value. Exactly one of the twins is ever installed.
    private var activeValueField: NSTextField { isRevealed ? revealedField : valueField }

    /// What the user has typed, whichever twin is showing it.
    var secretValue: String { activeValueField.stringValue }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 390))
        view = root
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        nameField.stringValue = draft.displayTitle
        nameField.identifier = .init("secret.name")
        valueField.identifier = .init("secret.value")
        revealedField.identifier = .init("secret.value.revealed")
        let valuePlaceholder = loc.s(existing == nil ? "editor.secret.placeholder" : "editor.secret.unchanged")
        valueField.placeholderString = valuePlaceholder
        revealedField.placeholderString = valuePlaceholder
        tagsField.stringValue = draft.tags.joined(separator: ", ")
        enabledButton.title = loc.s("editor.enabled")
        enabledButton.state = draft.enabled ? .on : .off

        errorLabel.textColor = .systemRed
        errorLabel.font = DevTypeTheme.font(11)
        errorLabel.maximumNumberOfLines = 3

        // Shown only while the value is on screen, so the state is never ambiguous.
        revealNotice.stringValue = loc.s("secrets.value.revealed")
        revealNotice.font = DevTypeTheme.font(11)
        revealNotice.textColor = DevTypeTheme.textTertiary
        revealNotice.isHidden = true

        // Editing never prefills a value, so say what blank means rather than letting the user
        // guess whether saving wipes the stored one.
        unchangedHint.stringValue = loc.s("secrets.value.keep")
        unchangedHint.font = DevTypeTheme.font(11)
        unchangedHint.textColor = DevTypeTheme.textTertiary
        unchangedHint.isHidden = existing == nil

        revealButton.target = self
        revealButton.action = #selector(toggleReveal)
        applyRevealState()

        let save = CapsuleButton(title: loc.s("secrets.save"), style: .primary, target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        let cancel = CapsuleButton(title: loc.s("common.cancel"), target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let buttonSpacer = NSView()
        buttonSpacer.translatesAutoresizingMaskIntoConstraints = false
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [buttonSpacer, cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let badge = IconBadgeView(symbol: "key.fill", tint: DevTypeTheme.accent, size: 34, pointSize: 15)
        let heading = DevTypeTheme.makeLabel(loc.s(existing == nil ? "secrets.add" : "secrets.edit"),
                                             font: DevTypeTheme.font(17, .semibold), color: DevTypeTheme.textPrimary)
        let subtitle = DevTypeTheme.makeLabel(loc.s("secrets.editor.subtitle"),
                                              font: DevTypeTheme.font(11), color: DevTypeTheme.textTertiary,
                                              wrapping: true)
        let headingText = NSStackView(views: [heading, subtitle])
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 2
        let header = NSStackView(views: [badge, headingText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        valueRow.orientation = .horizontal
        valueRow.alignment = .firstBaseline
        valueRow.spacing = 8
        valueRow.addArrangedSubview(valueField)
        valueRow.addArrangedSubview(revealButton)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)
        revealButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(16, after: header)

        // Caption and accessibility wiring in one pass, so a field cannot gain a caption without
        // the association VoiceOver reads it by. Both value twins share the one caption: they are
        // two presentations of a single field, not two fields. `P1UICompletionTests` pins this.
        var captions: [String: NSTextField] = [:]
        for (key, field) in [("secrets.name", nameField), ("secrets.value", valueField),
                             ("secrets.value", revealedField), ("secrets.tags", tagsField)] {
            let label = captions[key] ?? DevTypeTheme.makeFieldCaption(loc.s(key))
            captions[key] = label
            field.setAccessibilityLabel(loc.s(key))
            field.setAccessibilityTitleUIElement(label)
        }
        func caption(_ key: String) -> NSTextField {
            captions[key] ?? DevTypeTheme.makeFieldCaption(loc.s(key))
        }

        stack.addArrangedSubview(caption("secrets.name"))
        stack.addArrangedSubview(nameField)
        stack.setCustomSpacing(14, after: nameField)

        stack.addArrangedSubview(caption("secrets.value"))
        stack.addArrangedSubview(valueRow)
        stack.addArrangedSubview(unchangedHint)
        stack.addArrangedSubview(revealNotice)
        stack.setCustomSpacing(14, after: revealNotice)

        stack.addArrangedSubview(caption("secrets.tags"))
        stack.addArrangedSubview(tagsField)
        stack.setCustomSpacing(14, after: tagsField)

        stack.addArrangedSubview(enabledButton)
        stack.addArrangedSubview(errorLabel)
        stack.setCustomSpacing(14, after: errorLabel)
        stack.addArrangedSubview(buttons)

        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tagsField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            valueRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 380)
        ])
    }

    /// Editing an existing secret never prefills its value, so Show had nothing to swap in: it
    /// flipped the caption over a blank field and claimed the value was on screen. Fetch it
    /// first — through the one gated resolver, so this surface cannot become the path around
    /// Touch ID that the next one copies.
    @objc private func toggleReveal() {
        if !isRevealed, needsStoredValue {
            authenticateThenReveal()
            return
        }
        swapValueTwins()
    }

    /// True only when Show would otherwise present an empty field: the secret is already stored,
    /// its value has not been fetched yet, and the user has not typed a replacement over it.
    private var needsStoredValue: Bool {
        existing != nil && !hasLoadedStoredValue && secretValue.isEmpty
    }

    /// Nothing reaches the screen until the gate says so: on cancellation or failure the value
    /// stays concealed, so a refused prompt can never be mistaken for an empty secret.
    private func authenticateThenReveal() {
        guard let existing, !isAuthenticating else { return }
        isAuthenticating = true
        revealButton.isEnabled = false
        errorLabel.stringValue = ""
        revealStoredValue(existing.snippetAdapter) { [weak self] result in
            guard let self else { return }
            self.isAuthenticating = false
            self.revealButton.isEnabled = true
            switch result {
            case .success(let value):
                self.hasLoadedStoredValue = true
                // The concealed twin is the installed one here, so the swap carries it across.
                self.valueField.stringValue = value
                self.swapValueTwins()
            case .failure(let failure):
                // A dismissed prompt is the user's own decision, already visible to them.
                guard !failure.isSilent else { return }
                self.errorLabel.stringValue = self.revealFailureMessage(failure)
            }
        }
    }

    /// Why the value could not be shown, in the words the copy flow already uses for the same
    /// failures — a reveal blocked by a locked keychain must not say "no secret stored", because
    /// that sends the user to re-enter a value they have not lost.
    private func revealFailureMessage(_ failure: SecretMenuFlow.ResolveFailure) -> String {
        switch failure {
        case .secretUnavailable:
            return loc.s("secret.missing.message", draft.displayTitle)
        case .keychainLocked:
            return loc.s("secret.keychainLocked.message")
        case .migrationRequired(let pendingCount):
            return loc.s("secret.migrate.message", "\(pendingCount)")
        case .authenticationFailed(let reason):
            // The system's own wording for a lockout is more accurate than anything we invent.
            return reason.isEmpty ? loc.s("secret.auth.failed") : reason
        case .selectionChanged:
            return loc.s("manager.action.stale.message")
        case .authenticationCancelled, .emptySnippet, .imageSnippet, .macroFailed:
            // A secret resolves inside the resolver's `isSecret` branch and never reaches the
            // snippet failures; a cancellation is answered silently before this is reached.
            return loc.s("editor.transaction.secretReadFailed")
        }
    }

    /// Swaps the concealed and plain twins in place rather than keeping both installed, so the
    /// editor never presents a fourth editable field and the hidden twin cannot be read by
    /// anything walking the view tree.
    private func swapValueTwins() {
        let carried = activeValueField.stringValue
        let outgoing = activeValueField
        isRevealed.toggle()
        let incoming = activeValueField
        incoming.stringValue = carried
        outgoing.stringValue = ""
        valueRow.removeArrangedSubview(outgoing)
        outgoing.removeFromSuperview()
        valueRow.insertArrangedSubview(incoming, at: 0)
        applyRevealState()
        view.window?.makeFirstResponder(incoming)
        if let editor = incoming.currentEditor() {
            editor.selectedRange = NSRange(location: carried.count, length: 0)
        }
    }

    private func applyRevealState() {
        revealButton.title = loc.s(isRevealed ? "secrets.value.hide" : "secrets.value.show")
        revealButton.setSymbol(isRevealed ? "eye.slash" : "eye")
        revealNotice.isHidden = !isRevealed
    }

    @objc func saveTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 256 else {
            errorLabel.stringValue = loc.s("secrets.name.required")
            return
        }
        let value = secretValue
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
            clearValueFields()
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
        clearValueFields()
        onDismiss()
    }

    /// Both twins, always: the hidden one still holds whatever was typed before the last toggle
    /// if it is not cleared, and a dismissed editor must not leave a value anywhere in the view
    /// tree for a later reader to find.
    private func clearValueFields() {
        valueField.stringValue = ""
        revealedField.stringValue = ""
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
