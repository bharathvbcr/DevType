import AppKit
import ExpanderEngine
import ServiceManagement

// MARK: - General (§4.1 / §4.8)

/// Startup, typing undo, language, update checks and muted apps.
final class GeneralPreferencesViewController: PreferencesPaneViewController {

    private let openAtLoginSwitch = NSSwitch()
    private let automaticUpdateSwitch = NSSwitch()
    private let expansionUndoSwitch = NSSwitch()
    private let updateStatusLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(10.5),
        color: DevTypeTheme.textTertiary,
        wrapping: true
    )
    private var updateStatusObserver: NSObjectProtocol?
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mutedTable = NSTableView()
    private let mutedEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    private var mutedApps: [String] = []

    override init() {
        super.init()
        updateStatusObserver = NotificationCenter.default.addObserver(
            forName: UpdatePreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshUpdateStatusLabel()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let updateStatusObserver {
            NotificationCenter.default.removeObserver(updateStatusObserver)
        }
    }

    override func build(into stack: NSStackView) {
        // Startup
        let startupCard = makeCard(title: loc.s("prefs.general.startup"), symbol: "sunrise")
        let loginRow = makeToggleRow(
            title: loc.s("menu.openAtLogin"),
            toggle: openAtLoginSwitch,
            action: #selector(openAtLoginChanged)
        )
        let appearanceNote = DevTypeTheme.makeLabel(
            loc.s("prefs.general.appearanceNote"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        appearanceNote.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(startupCard, views: [loginRow, appearanceNote])

        let undoCard = makeCard(title: loc.s("prefs.general.typing"), symbol: "keyboard")
        let undoRow = makeToggleRow(
            title: loc.s("prefs.general.undo"), toggle: expansionUndoSwitch,
            action: #selector(expansionUndoChanged)
        )
        let undoHint = DevTypeTheme.makeLabel(
            loc.s("prefs.general.undo.hint"), font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary, wrapping: true
        )
        undoHint.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(undoCard, views: [undoRow, undoHint])

        // Language (§4.1: was a menu submenu)
        let languageCard = makeCard(title: loc.s("prefs.general.language"), symbol: "globe")
        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        languagePopup.removeAllItems()
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.endonym)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.setAccessibilityLabel(loc.s("prefs.general.language"))
        let languageNote = DevTypeTheme.makeLabel(
            loc.s("prefs.general.languageNote"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        languageNote.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(languageCard, views: [languagePopup, languageNote])

        // Muted apps (§4.8: replaces the index-arithmetic alert)
        let mutedCard = makeCard(title: loc.s("prefs.general.mutedApps"), symbol: "speaker.slash.fill")
        let mutedHint = DevTypeTheme.makeLabel(
            loc.s("prefs.general.mutedApps.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        mutedHint.translatesAutoresizingMaskIntoConstraints = false

        let mutedArea = makeTableArea(
            table: mutedTable,
            accessibilityLabel: loc.s("prefs.general.mutedApps"),
            columnIdentifier: "muted",
            emptyLabel: mutedEmptyLabel,
            allowsMultipleSelection: true
        )

        let muteFrontmostButton = CapsuleButton(
            title: loc.s("prefs.general.muteFrontmost"),
            symbol: "speaker.slash",
            style: .secondary,
            target: self,
            action: #selector(muteFrontmost)
        )
        let unmuteButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(unmuteSelected)
        )
        bindRemovalButton(unmuteButton, to: mutedTable)
        let mutedButtons = NSStackView(views: [muteFrontmostButton, unmuteButton])
        mutedButtons.orientation = .horizontal
        mutedButtons.spacing = 8
        mutedButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(mutedCard, views: [mutedHint, mutedArea, mutedButtons])

        // Updates (§7.5). Off by default — the toggle governs only whether DevType checks on
        // its own; the menu bar's "Check for Updates…" works regardless.
        let updatesCard = makeCard(title: loc.s("prefs.general.updates"), symbol: "arrow.down.circle")
        let updatesRow = makeToggleRow(
            title: loc.s("prefs.general.updates.auto"),
            toggle: automaticUpdateSwitch,
            action: #selector(automaticUpdateCheckChanged)
        )
        let updatesNote = DevTypeTheme.makeLabel(
            loc.s("prefs.general.updates.note"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        updatesNote.translatesAutoresizingMaskIntoConstraints = false
        updateStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        let checkNowButton = CapsuleButton(
            title: loc.s("prefs.general.updates.checkNow"),
            symbol: "arrow.clockwise",
            style: .secondary,
            target: self,
            action: #selector(checkForUpdatesNow)
        )
        let updatesButtons = NSStackView(views: [checkNowButton])
        updatesButtons.orientation = .horizontal
        updatesButtons.spacing = 8
        updatesButtons.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(updatesCard, views: [updatesRow, updatesNote, updateStatusLabel, updatesButtons])

        stack.addArrangedSubview(startupCard)
        stack.addArrangedSubview(undoCard)
        stack.addArrangedSubview(languageCard)
        stack.addArrangedSubview(updatesCard)
        stack.addArrangedSubview(mutedCard)
        pinWidth(of: [startupCard, undoCard, languageCard, updatesCard, mutedCard], to: stack)
    }

    @objc private func expansionUndoChanged() {
        TextInjectionPipeline.shared.expansionUndoEnabled = expansionUndoSwitch.state == .on
    }

    override func reload() {
        openAtLoginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        automaticUpdateSwitch.state = UpdatePreferences.automaticCheckEnabled ? .on : .off
        expansionUndoSwitch.state = TextInjectionPipeline.shared.expansionUndoEnabled ? .on : .off
        refreshUpdateStatusLabel()
        let current = loc.language.rawValue
        for (index, language) in AppLanguage.allCases.enumerated()
        where language.rawValue == current {
            languagePopup.selectItem(at: index)
        }
        mutedApps = AppMuteStore.shared.allMuted().sorted()
        mutedTable.reloadData()
        mutedEmptyLabel.stringValue = mutedApps.isEmpty ? loc.s("prefs.general.mutedApps.empty") : ""
        mutedEmptyLabel.isHidden = !mutedApps.isEmpty
        refreshRemovalButton(for: mutedTable)
    }

    @objc private func automaticUpdateCheckChanged() {
        UpdatePreferences.automaticCheckEnabled = automaticUpdateSwitch.state == .on
        refreshUpdateStatusLabel()
    }

    @objc private func checkForUpdatesNow() {
        // Reports every outcome, including failures — the user asked.
        UpdateFlow.checkManually(window: view.window)
    }

    /// Shows the running version plus when a check last *succeeded*.
    ///
    /// "Never checked" is shown until one completes, so a run of failed checks never renders as
    /// a recent successful one.
    private func refreshUpdateStatusLabel() {
        let version = AppVersion.current()?.rawValue ?? "—"
        var lines = [loc.s("prefs.general.updates.currentVersion", version)]
        if let last = UpdatePreferences.lastSuccessfulCheck {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append(loc.s("prefs.general.updates.lastChecked", formatter.string(from: last)))
        } else {
            lines.append(loc.s("prefs.general.updates.never"))
        }
        updateStatusLabel.stringValue = lines.joined(separator: " · ")
    }

    @objc private func openAtLoginChanged() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            DevTypeAlert.warn(
                title: loc.s("alert.openAtLogin.title"),
                message: loc.s("alert.openAtLogin.message", error.localizedDescription),
                window: view.window
            )
        }
        reload()
    }

    @objc private func languageChanged() {
        guard let raw = languagePopup.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        loc.language = language
    }

    @objc private func muteFrontmost() {
        guard let bundleID = AppMuteStore.shared.muteFrontmost() else {
            DevTypeAlert.warn(
                title: loc.s("alert.muteFrontmost.failed.title"),
                message: loc.s("alert.muteFrontmost.failed.message"),
                window: view.window
            )
            return
        }
        DevTypeLog.app.info(
            "[Prefs] muted \(DevTypeLog.boundedPublicIdentifier(bundleID, label: "bundleID"), privacy: .public)"
        )
        reload()
    }

    @objc private func unmuteSelected() {
        let selected = mutedTable.selectedRowIndexes
        guard !selected.isEmpty else { return }
        for row in selected where mutedApps.indices.contains(row) {
            AppMuteStore.shared.unmute(mutedApps[row])
        }
        reload()
    }

    // MARK: Muted apps list

    override func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === mutedTable ? mutedApps.count : 0
    }

    override func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === mutedTable, mutedApps.indices.contains(row) else { return nil }
        return makeRowLabel(in: tableView, column: tableColumn, text: mutedApps[row])
    }
}
