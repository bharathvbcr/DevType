import AppKit
import Carbon
import ExpanderEngine

// MARK: - Hotkeys (§4.2 / §4.3)

/// The inline-search shortcut and hotkey macros.
final class HotkeysPreferencesViewController: PreferencesPaneViewController {

    weak var hotkeyManager: HotkeyManager?
    private var inlineRecorder: ShortcutRecorderView?
    private let hotkeyWarningLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(10.5, .medium),
        color: DevTypeTheme.statusOrange,
        wrapping: true
    )
    private let macroTable = NSTableView()
    private let macroEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    private var macros: [HotkeyMacroAction] = []
    private var macroRecorder: ShortcutRecorderView?
    private let macroKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let macroArgumentField = NSTextField()

    override func build(into stack: NSStackView) {
        let searchCard = makeCard(title: loc.s("prefs.hotkeys.inlineSearch"), symbol: "magnifyingglass")
        let hint = DevTypeTheme.makeLabel(
            loc.s("prefs.hotkeys.inlineSearch.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        hint.translatesAutoresizingMaskIntoConstraints = false

        let recorder = ShortcutRecorderView(shortcut: HotkeyPreferences.inlineSearchShortcut)
        recorder.onChange = { [weak self] shortcut in
            self?.applyInlineShortcut(shortcut)
        }
        inlineRecorder = recorder

        let resetButton = CapsuleButton(
            title: loc.s("prefs.hotkeys.reset"),
            symbol: "arrow.counterclockwise",
            style: .secondary,
            target: self,
            action: #selector(resetInlineShortcut)
        )
        let recorderRow = NSStackView(views: [recorder, resetButton])
        recorderRow.orientation = .horizontal
        recorderRow.spacing = 10
        recorderRow.translatesAutoresizingMaskIntoConstraints = false

        hotkeyWarningLabel.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(searchCard, views: [hint, recorderRow, hotkeyWarningLabel])

        // §4.3: the macro list that had no UI.
        let macroCard = makeCard(title: loc.s("prefs.hotkeys.macros"), symbol: "text.insert")
        let macroHint = DevTypeTheme.makeLabel(
            loc.s("prefs.hotkeys.macros.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        macroHint.translatesAutoresizingMaskIntoConstraints = false

        let macroArea = makeTableArea(
            table: macroTable,
            accessibilityLabel: loc.s("prefs.hotkeys.macros"),
            columnIdentifier: "macro",
            emptyLabel: macroEmptyLabel,
            rowHeight: 24
        )

        let newRecorder = ShortcutRecorderView(shortcut: nil)
        macroRecorder = newRecorder

        macroKindPopup.translatesAutoresizingMaskIntoConstraints = false
        macroKindPopup.removeAllItems()
        macroKindPopup.addItem(withTitle: loc.s("prefs.hotkeys.macros.kind.insertText"))
        macroKindPopup.lastItem?.representedObject = HotkeyMacroAction.Kind.insertText.rawValue
        macroKindPopup.addItem(withTitle: loc.s("prefs.hotkeys.macros.kind.openURL"))
        macroKindPopup.lastItem?.representedObject = HotkeyMacroAction.Kind.openURL.rawValue
        macroKindPopup.setAccessibilityLabel(loc.s("prefs.hotkeys.macros.kind"))

        macroArgumentField.translatesAutoresizingMaskIntoConstraints = false
        macroArgumentField.placeholderString = loc.s("prefs.hotkeys.macros.argument")
        macroArgumentField.font = DevTypeTheme.font(12)
        macroArgumentField.setAccessibilityLabel(loc.s("prefs.hotkeys.macros.argument"))
        macroArgumentField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let editorRow = NSStackView(views: [newRecorder, macroKindPopup, macroArgumentField])
        editorRow.orientation = .horizontal
        editorRow.spacing = 8
        editorRow.translatesAutoresizingMaskIntoConstraints = false

        let addMacroButton = CapsuleButton(
            title: loc.s("prefs.hotkeys.macros.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(addMacro)
        )
        let removeMacroButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(removeMacro)
        )
        bindRemovalButton(removeMacroButton, to: macroTable)
        let macroButtons = NSStackView(views: [addMacroButton, removeMacroButton])
        macroButtons.orientation = .horizontal
        macroButtons.spacing = 8
        macroButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(macroCard, views: [macroHint, macroArea, editorRow, macroButtons])

        stack.addArrangedSubview(searchCard)
        stack.addArrangedSubview(macroCard)
        pinWidth(of: [searchCard, macroCard], to: stack)
    }

    override func reload() {
        let shortcut = HotkeyPreferences.inlineSearchShortcut
        inlineRecorder?.setShortcut(shortcut)
        hotkeyWarningLabel.stringValue = shortcut.isDefaultInlineSearch
            ? loc.s("prefs.hotkeys.conflictWarning")
            : ""
        hotkeyWarningLabel.isHidden = !shortcut.isDefaultInlineSearch
        macros = hotkeyManager?.macros ?? HotkeyManager.loadMacros()
        macroTable.reloadData()
        macroEmptyLabel.stringValue = macros.isEmpty ? loc.s("prefs.hotkeys.macros.empty") : ""
        macroEmptyLabel.isHidden = !macros.isEmpty
        refreshRemovalButton(for: macroTable)
    }

    private func applyInlineShortcut(_ shortcut: DevTypeShortcut?) {
        guard let shortcut else { return }
        guard let manager = hotkeyManager else {
            HotkeyPreferences.inlineSearchShortcut = shortcut
            reload()
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
            return
        }
        let status = manager.applyInlineSearchShortcut(shortcut)
        if status != noErr {
            // §4.2: registration failure is surfaced, not silently logged.
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.failed.title"),
                message: loc.s("prefs.hotkeys.failed.message", shortcut.displayString, Int(status)),
                window: view.window
            )
        }
        reload()
    }

    @objc private func resetInlineShortcut() {
        HotkeyPreferences.resetInlineSearchShortcut()
        applyInlineShortcut(.inlineSearchDefault)
    }

    @objc private func addMacro() {
        guard let shortcut = macroRecorder?.shortcut else {
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.macros.add"),
                message: loc.s("shortcut.needsModifier"),
                window: view.window
            )
            return
        }
        let argument = macroArgumentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else {
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.macros.add"),
                message: loc.s("prefs.hotkeys.macros.argument"),
                window: view.window
            )
            return
        }
        let rawKind = macroKindPopup.selectedItem?.representedObject as? String
        let kind = HotkeyMacroAction.Kind(rawValue: rawKind ?? "") ?? .insertText
        macros.append(
            HotkeyMacroAction(
                id: 0,
                keyCode: shortcut.keyCode,
                modifiers: shortcut.carbonModifiers,
                kind: kind,
                argument: argument
            )
        )
        let failures = hotkeyManager?.applyMacros(macros) ?? []
        if hotkeyManager == nil {
            HotkeyPreferences.saveMacros(macros)
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
        reportRegistrationFailures(failures)
        macroArgumentField.stringValue = ""
        macroRecorder?.setShortcut(nil)
        reload()
    }

    /// §4.2 parity for macros: a chord owned by another app must not produce a
    /// table row that silently does nothing forever. The app delegate suppresses
    /// its own alert while Preferences is visible, so this is the one channel
    /// that reaches the user here.
    private func reportRegistrationFailures(_ failures: [(label: String, status: OSStatus)]) {
        guard let first = failures.first else { return }
        DevTypeAlert.warn(
            title: loc.s("prefs.hotkeys.failed.title"),
            message: loc.s("prefs.hotkeys.failed.message", first.label, Int(first.status)),
            window: view.window
        )
    }

    @objc private func removeMacro() {
        let row = macroTable.selectedRow
        guard macros.indices.contains(row) else { return }
        macros.remove(at: row)
        hotkeyManager?.applyMacros(macros)
        if hotkeyManager == nil {
            HotkeyPreferences.saveMacros(macros)
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
        reload()
    }

    // MARK: Macro list

    override func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === macroTable ? macros.count : 0
    }

    override func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === macroTable, macros.indices.contains(row) else { return nil }
        let macro = macros[row]
        let shortcut = DevTypeShortcut(keyCode: macro.keyCode, carbonModifiers: macro.modifiers)
        let kindTitle = macro.kind == .insertText
            ? loc.s("prefs.hotkeys.macros.kind.insertText")
            : loc.s("prefs.hotkeys.macros.kind.openURL")
        let text = "\(shortcut.displayString)  ·  \(kindTitle)  ·  \(macro.argument)"
        return makeRowLabel(in: tableView, column: tableColumn, text: text)
    }
}
