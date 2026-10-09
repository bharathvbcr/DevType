import AppKit
import ExpanderEngine

// MARK: - Snippets (§4.5 / §0.4 / §1.9)

/// The secrets gate, library statistics, where the library lives, and trigger conflicts.
final class SnippetsPreferencesViewController: PreferencesPaneViewController {

    private let requireBiometrySwitch = NSSwitch()
    private lazy var stats = StatsViewController(store: store)
    /// Only meaningful while the library lives somewhere the user chose; disabled otherwise.
    private var libraryStopSyncButton: CapsuleButton?
    private let libraryPathLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.mono(10.5),
        color: DevTypeTheme.textTertiary,
        wrapping: true
    )
    private let conflictsLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11),
        color: DevTypeTheme.statusOrange,
        wrapping: true
    )

    override func build(into stack: NSStackView) {
        buildSecretsCard(into: stack)

        addChild(stats)
        let statsView = stats.view
        statsView.translatesAutoresizingMaskIntoConstraints = false

        let libraryCard = makeCard(title: loc.s("manager.title"), symbol: "square.stack.3d.up")
        libraryPathLabel.translatesAutoresizingMaskIntoConstraints = false
        let ioButtons = NSStackView(views: [
            CapsuleButton(
                title: loc.s("manager.import"),
                symbol: "square.and.arrow.down",
                style: .secondary,
                target: self,
                action: #selector(importLibrary)
            ),
            CapsuleButton(
                title: loc.s("manager.export"),
                symbol: "square.and.arrow.up",
                style: .primary,
                target: self,
                action: #selector(exportLibrary)
            )
        ])
        ioButtons.orientation = .horizontal
        ioButtons.spacing = 8
        ioButtons.translatesAutoresizingMaskIntoConstraints = false

        // Where the library lives. `SnippetStore.saveSnippetsAs` / `linkToSnippets` /
        // `stopSyncing` have always persisted the choice under `storeLocationPath` and been
        // read back by `resolveLocation` on launch — this row is the door to them. It belongs
        // beside the path label that already names the active location rather than in its own
        // card somewhere else.
        let locationNote = DevTypeTheme.makeLabel(
            loc.s("prefs.snippets.library.note"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        locationNote.translatesAutoresizingMaskIntoConstraints = false
        libraryStopSyncButton = CapsuleButton(
            title: loc.s("prefs.snippets.library.stop"),
            symbol: "xmark.circle",
            style: .secondary,
            target: self,
            action: #selector(libraryStopSyncingClicked)
        )
        let locationButtons = NSStackView(views: [
            CapsuleButton(
                title: loc.s("prefs.snippets.library.move"),
                symbol: "externaldrive",
                style: .secondary,
                target: self,
                action: #selector(libraryMoveClicked)
            ),
            CapsuleButton(
                title: loc.s("prefs.snippets.library.link"),
                symbol: "link",
                style: .secondary,
                target: self,
                action: #selector(libraryLinkClicked)
            ),
            libraryStopSyncButton!
        ])
        locationButtons.orientation = .horizontal
        locationButtons.spacing = 8
        locationButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(libraryCard, views: [libraryPathLabel, ioButtons, locationNote, locationButtons])

        // §1.9: `SnippetSearch.conflictingTriggers` was dead code. Surfacing the
        // store's `triggerConflicts()` is how the user learns that `:Hi` and `:hi`
        // both live on disk while only one can ever fire.
        let conflictCard = makeCard(title: loc.s("prefs.snippets.conflicts"), symbol: "exclamationmark.triangle.fill")
        conflictsLabel.translatesAutoresizingMaskIntoConstraints = false
        let rescan = CapsuleButton(
            title: loc.s("prefs.snippets.rescan"),
            symbol: "arrow.triangle.2.circlepath",
            style: .secondary,
            target: self,
            action: #selector(rescanConflicts)
        )
        stackInCard(conflictCard, views: [conflictsLabel, rescan])

        stack.addArrangedSubview(statsView)
        stack.addArrangedSubview(libraryCard)
        stack.addArrangedSubview(conflictCard)
        pinWidth(of: [statsView, libraryCard, conflictCard], to: stack)
    }

    override func reload() {
        refreshLibraryLocation()
        rescanConflicts()
    }

    override func didSelect() {
        stats.refresh()
    }

    /// Touch ID gate for secrets, on the tab that owns snippets.
    ///
    /// The note under the switch says what the check is *worth*, not just what it does. A security
    /// control whose limits are not stated invites the user to rely on it for more than it covers.
    private func buildSecretsCard(into stack: NSStackView) {
        let availability = BiometricGate.shared.availability()
        let card = makeCard(title: loc.s("prefs.secrets.card"), symbol: "key.fill")

        requireBiometrySwitch.state =
            SecretPreferences.requireBiometry(availability: availability) ? .on : .off
        requireBiometrySwitch.isEnabled = availability.canGate

        let row = makeToggleRow(
            title: loc.s("prefs.secrets.requireBiometry"),
            toggle: requireBiometrySwitch,
            action: #selector(requireBiometryChanged)
        )

        let detail: String
        switch availability {
        case .biometry(let name): detail = loc.s("prefs.secrets.note.biometry", name)
        case .passwordOnly: detail = loc.s("prefs.secrets.note.password")
        case .unavailable: detail = loc.s("prefs.secrets.note.unavailable")
        }
        let note = DevTypeTheme.makeLabel(
            detail,
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        note.translatesAutoresizingMaskIntoConstraints = false

        let scope = DevTypeTheme.makeLabel(
            loc.s("prefs.secrets.note.scope"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        scope.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(card, views: [row, note, scope])
        stack.addArrangedSubview(card)
        pinWidth(of: [card], to: stack)
    }

    func refreshSecretsCard() {
        let availability = BiometricGate.shared.availability()
        requireBiometrySwitch.state =
            SecretPreferences.requireBiometry(availability: availability) ? .on : .off
        requireBiometrySwitch.isEnabled = availability.canGate
    }

    @objc private func requireBiometryChanged() {
        SecretPreferences.requestRequireBiometry(requireBiometrySwitch.state == .on) { [weak self] inForce in
            guard let self else { return }
            // The switch shows what is in force, not what was clicked: a downgrade the user
            // failed or declined has to spring back rather than sit there claiming the gate is
            // off while every read still prompts.
            self.requireBiometrySwitch.state = inForce ? .on : .off
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
    }

    /// "Stop Syncing" is enabled only when there is something to stop — while the library is
    /// already at the default local path the button would be a no-op that still moves files.
    private func refreshLibraryLocation() {
        libraryPathLabel.stringValue = loc.s("prefs.snippets.libraryPath", store.activeLocationURL.path)
        let isCustom = UserDefaults.standard
            .string(forKey: SnippetStore.DeviceStateKey.storeLocationPath)?
            .isEmpty == false
        libraryStopSyncButton?.isEnabled = isCustom
    }

    /// Copies the library into a folder the user picks (an iCloud/Dropbox folder, typically)
    /// and switches to it. `saveSnippetsAs` backs up anything it overwrites there.
    @objc private func libraryMoveClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = loc.s("prefs.snippets.library.move")
        panel.message = loc.s("prefs.snippets.library.move.message")
        panel.prompt = loc.s("prefs.snippets.library.move")
        presentLibraryPanel(panel) { url in
            SnippetStore.shared.saveSnippetsAs(toDirectory: url)
        }
    }

    /// Adopts a library that already exists at the chosen file, backing up the local one first.
    /// This *replaces* what is on screen, so the confirmation says so before anything moves.
    @objc private func libraryLinkClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.title = loc.s("prefs.snippets.library.link")
        panel.message = loc.s("prefs.snippets.library.link.message")
        panel.prompt = loc.s("prefs.snippets.library.link")
        presentLibraryPanel(panel) { url in
            SnippetStore.shared.linkToSnippets(at: url)
        }
    }

    @objc private func libraryStopSyncingClicked() {
        let alert = NSAlert()
        alert.messageText = loc.s("prefs.snippets.library.stop")
        alert.informativeText = loc.s("prefs.snippets.library.stop.message")
        alert.addButton(withTitle: loc.s("prefs.snippets.library.stop"))
        alert.addButton(withTitle: loc.s("common.cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.reportRelocation(SnippetStore.shared.stopSyncing())
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func presentLibraryPanel(
        _ panel: NSOpenPanel,
        perform: @escaping (URL) -> SnippetStore.RelocationResult
    ) {
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.reportRelocation(perform(url))
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Always names the backup on success: a relocation the user cannot undo by hand is one
    /// they have to trust blindly, and the store already wrote the copy that makes it undoable.
    private func reportRelocation(_ result: SnippetStore.RelocationResult) {
        refreshLibraryLocation()
        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        if result.success {
            var message = loc.s("prefs.snippets.library.done.body", result.activeLocation.path)
            if let backup = result.backupURL {
                message += "\n\n" + loc.s("prefs.snippets.library.done.backup", backup.path)
            }
            DevTypeAlert.info(
                title: loc.s("prefs.snippets.library.done.title"),
                message: message,
                window: view.window
            )
        } else {
            DevTypeAlert.warn(
                title: loc.s("prefs.snippets.library.failed.title"),
                message: result.message ?? loc.s("prefs.snippets.library.failed.title"),
                window: view.window
            )
        }
    }

    @objc private func rescanConflicts() {
        let conflicts = store.triggerConflicts()
        guard !conflicts.isEmpty else {
            conflictsLabel.stringValue = loc.s("prefs.snippets.conflicts.none")
            conflictsLabel.textColor = DevTypeTheme.statusGreen
            return
        }
        var lines: [String] = []
        for conflict in conflicts.prefix(20) {
            let groups = conflict.groupNames.joined(separator: ", ")
            switch conflict.kind {
            case .emptyTrigger:
                lines.append(loc.s("prefs.snippets.conflict.empty", groups))
            case .duplicateTrigger:
                lines.append(loc.s("prefs.snippets.conflict.duplicate", conflict.trigger, groups))
            case .caseShadow:
                lines.append(loc.s("prefs.snippets.conflict.caseShadow", conflict.trigger, groups))
            case .prefixShadow:
                // snippetIDs[0] / groupNames[0] are the shadowing trigger; the rest are the
                // triggers it makes unreachable. Name them — "some snippet is shadowed" is
                // not actionable, "`slmabout can never fire" is.
                let blocked = conflict.blockedTriggerSummary ?? groups
                lines.append(loc.s("prefs.snippets.conflict.prefixShadow", conflict.trigger, blocked))
            }
        }
        conflictsLabel.stringValue = lines.joined(separator: "\n")
        conflictsLabel.textColor = DevTypeTheme.statusOrange
    }

    @objc private func exportLibrary() {
        LibraryExporter.present(from: view.window, store: store)
    }

    @objc private func importLibrary() {
        SnippetImportFlow.present(from: view.window) { [weak self] in
            self?.reload()
        }
    }
}
