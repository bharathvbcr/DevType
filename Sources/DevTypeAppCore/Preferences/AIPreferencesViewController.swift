import AppKit
import Carbon
import ExpanderEngine

// MARK: - AI

/// Apple Intelligence transforms: enablement, the palette shortcut, per-action output modes,
/// Lappi routing, typed-repetition consent and the typed-path allowlist.
final class AIPreferencesViewController: PreferencesPaneViewController {

    weak var hotkeyManager: HotkeyManager?
    private let aiEnabledSwitch = NSSwitch()
    private let aiRemoveMarkdownSwitch = NSSwitch()
    private let aiTagSuggestionsSwitch = NSSwitch()
    private let aiSemanticRoutingSwitch = NSSwitch()
    private let lappiAskSwitch = NSSwitch()
    private let lappiRecordSwitch = NSSwitch()
    private let repetitionSwitch = NSSwitch()
    private let aiAvailabilityLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11),
        color: DevTypeTheme.textSecondary,
        wrapping: true
    )
    private var aiPaletteRecorder: ShortcutRecorderView?
    private var aiOutputModePopups: [AITransformKind: NSPopUpButton] = [:]
    private let aiAllowlistTable = NSTableView()
    private let aiAllowlistEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    let aiAllowlistField = NSTextField()
    private var aiAllowlist: [String] = []

    override func build(into stack: NSStackView) {
        let featureAvailable = AITextTransformSupport.isRunningOnCompatibleOS

        if !featureAvailable {
            let unsupportedCard = makeCard(title: loc.s("prefs.tab.ai"), symbol: "sparkles")
            let disclaimerPill = PillBadgeView(text: "Apple Intelligence", tint: DevTypeTheme.statusOrange, showsDot: true)
            disclaimerPill.translatesAutoresizingMaskIntoConstraints = false

            let note = DevTypeTheme.makeLabel(
                loc.s("ai.availability.requirement"),
                font: DevTypeTheme.font(11.5),
                color: DevTypeTheme.textSecondary,
                wrapping: true
            )
            note.translatesAutoresizingMaskIntoConstraints = false
            stackInCard(unsupportedCard, views: [disclaimerPill, note])
            stack.addArrangedSubview(unsupportedCard)
            pinWidth(of: [unsupportedCard], to: stack)
            return
        }

        // Enable + availability
        let enableCard = makeCard(title: loc.s("prefs.ai.enable.card"), symbol: "sparkles")
        let disclaimerPill = PillBadgeView(text: "Apple Intelligence", tint: DevTypeTheme.accent, showsDot: true)
        disclaimerPill.translatesAutoresizingMaskIntoConstraints = false

        let enableRow = makeToggleRow(
            title: loc.s("prefs.ai.enable"),
            toggle: aiEnabledSwitch,
            action: #selector(aiEnabledChanged)
        )
        let privacyNote = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.privacy"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        privacyNote.translatesAutoresizingMaskIntoConstraints = false
        aiAvailabilityLabel.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(enableCard, views: [disclaimerPill, enableRow, privacyNote, aiAvailabilityLabel])

        // Palette hotkey
        let hotkeyCard = makeCard(title: loc.s("prefs.ai.hotkey"), symbol: "keyboard")
        let hotkeyHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.hotkey.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        hotkeyHint.translatesAutoresizingMaskIntoConstraints = false
        let recorder = ShortcutRecorderView(shortcut: HotkeyPreferences.aiPaletteShortcut)
        recorder.onChange = { [weak self] shortcut in
            self?.applyAIPaletteShortcut(shortcut)
        }
        aiPaletteRecorder = recorder
        let resetButton = CapsuleButton(
            title: loc.s("prefs.ai.hotkey.reset"),
            symbol: "arrow.counterclockwise",
            style: .secondary,
            target: self,
            action: #selector(resetAIPaletteShortcut)
        )
        let recorderRow = NSStackView(views: [recorder, resetButton])
        recorderRow.orientation = .horizontal
        recorderRow.spacing = 10
        recorderRow.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(hotkeyCard, views: [hotkeyHint, recorderRow])

        // Per-action output modes
        let modesCard = makeCard(title: loc.s("prefs.ai.outputModes"), symbol: "arrow.left.arrow.right")
        let modesHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.outputModes.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        modesHint.translatesAutoresizingMaskIntoConstraints = false
        let markdownRow = makeToggleRow(
            title: loc.s("prefs.ai.removeMarkdown"),
            toggle: aiRemoveMarkdownSwitch,
            action: #selector(aiRemoveMarkdownChanged)
        )
        let markdownHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.removeMarkdown.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        markdownHint.translatesAutoresizingMaskIntoConstraints = false
        let routingRow = makeToggleRow(
            title: loc.s("prefs.ai.semanticRouting"),
            toggle: aiSemanticRoutingSwitch,
            action: #selector(aiSemanticRoutingChanged)
        )
        let routingHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.semanticRouting.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        routingHint.translatesAutoresizingMaskIntoConstraints = false
        let lappiAskRow = makeToggleRow(
            title: loc.s("prefs.ai.lappiAsk"),
            toggle: lappiAskSwitch,
            action: #selector(lappiAskChanged)
        )
        let lappiAskHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.lappiAsk.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        lappiAskHint.translatesAutoresizingMaskIntoConstraints = false
        let lappiRecordRow = makeToggleRow(
            title: loc.s("prefs.ai.lappiRecord"),
            toggle: lappiRecordSwitch,
            action: #selector(lappiRecordChanged)
        )
        let lappiRecordHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.lappiRecord.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        lappiRecordHint.translatesAutoresizingMaskIntoConstraints = false
        let tagRow = makeToggleRow(
            title: loc.s("prefs.ai.tagSuggestions"),
            toggle: aiTagSuggestionsSwitch,
            action: #selector(aiTagSuggestionsChanged)
        )
        let tagHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.tagSuggestions.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        tagHint.translatesAutoresizingMaskIntoConstraints = false
        let repetitionRow = makeToggleRow(
            title: loc.s("prefs.repetition"),
            toggle: repetitionSwitch,
            action: #selector(repetitionChanged)
        )
        let repetitionHint = DevTypeTheme.makeLabel(
            loc.s("prefs.repetition.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        repetitionHint.translatesAutoresizingMaskIntoConstraints = false
        let forgetButton = NSButton(
            title: loc.s("prefs.repetition.forget"),
            target: self,
            action: #selector(repetitionForget)
        )
        forgetButton.translatesAutoresizingMaskIntoConstraints = false
        forgetButton.bezelStyle = .rounded
        var modeRows: [NSView] = [
            modesHint, markdownRow, markdownHint, routingRow, routingHint,
            lappiAskRow, lappiAskHint, lappiRecordRow, lappiRecordHint, tagRow, tagHint,
            repetitionRow, repetitionHint, forgetButton,
        ]
        aiOutputModePopups.removeAll()
        for kind in AITransformKind.builtInPalette {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.removeAllItems()
            popup.addItem(withTitle: loc.s("prefs.ai.output.direct"))
            popup.lastItem?.representedObject = AIOutputMode.direct.rawValue
            popup.addItem(withTitle: loc.s("prefs.ai.output.preview"))
            popup.lastItem?.representedObject = AIOutputMode.preview.rawValue
            popup.target = self
            popup.action = #selector(aiOutputModeChanged(_:))
            popup.setAccessibilityLabel(loc.s(kind.localizationKey))
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
            aiOutputModePopups[kind] = popup

            let row = makeLabeledControlRow(
                title: loc.s(kind.localizationKey),
                control: popup
            )
            modeRows.append(row)
        }

        // Every popup above writes a per-kind override; without this there is no way back to
        // the built-in default short of knowing which mode each kind shipped with.
        let resetModesButton = CapsuleButton(
            title: loc.s("prefs.ai.output.restoreDefaults"),
            style: .secondary,
            target: self,
            action: #selector(aiOutputModeRestoreDefaultsClicked)
        )
        resetModesButton.translatesAutoresizingMaskIntoConstraints = false
        let resetRow = NSStackView(views: [resetModesButton])
        resetRow.orientation = .horizontal
        resetRow.alignment = .centerY
        resetRow.translatesAutoresizingMaskIntoConstraints = false
        modeRows.append(resetRow)

        stackInCard(modesCard, views: modeRows)

        // Typed-path allowlist
        let allowCard = makeCard(title: loc.s("prefs.ai.allowlist"), symbol: "checkmark.seal")
        let allowHint = DevTypeTheme.makeLabel(
            loc.s("prefs.ai.allowlist.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        allowHint.translatesAutoresizingMaskIntoConstraints = false

        let allowlistArea = makeTableArea(
            table: aiAllowlistTable,
            accessibilityLabel: loc.s("prefs.ai.allowlist"),
            columnIdentifier: "aiAllow",
            emptyLabel: aiAllowlistEmptyLabel,
            allowsMultipleSelection: true
        )

        aiAllowlistField.translatesAutoresizingMaskIntoConstraints = false
        aiAllowlistField.placeholderString = loc.s("prefs.ai.allowlist.bundleID")
        aiAllowlistField.font = DevTypeTheme.font(12)
        aiAllowlistField.setAccessibilityLabel(loc.s("prefs.ai.allowlist.bundleID"))
        aiAllowlistField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let addFrontmostButton = CapsuleButton(
            title: loc.s("prefs.ai.allowlist.addFrontmost"),
            symbol: "plus.app",
            style: .secondary,
            target: self,
            action: #selector(aiAllowlistAddFrontmost)
        )
        let addAllowlistButton = CapsuleButton(
            title: loc.s("common.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(aiAllowlistAddTyped)
        )
        let removeAllowlistButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(aiAllowlistRemove)
        )
        bindRemovalButton(removeAllowlistButton, to: aiAllowlistTable)
        let allowButtons = NSStackView(views: [
            addFrontmostButton,
            addAllowlistButton,
            removeAllowlistButton
        ])
        allowButtons.orientation = .horizontal
        allowButtons.spacing = 8
        allowButtons.translatesAutoresizingMaskIntoConstraints = false

        let editorRow = NSStackView(views: [aiAllowlistField])
        editorRow.orientation = .horizontal
        editorRow.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(allowCard, views: [allowHint, allowlistArea, editorRow, allowButtons])

        for card in [enableCard, hotkeyCard, modesCard, allowCard] {
            stack.addArrangedSubview(card)
        }
        pinWidth(of: [enableCard, hotkeyCard, modesCard, allowCard], to: stack)
    }

    override func reload() {
        guard isViewLoaded else { return }
        aiEnabledSwitch.state = AIPreferences.isEnabled ? .on : .off
        aiRemoveMarkdownSwitch.state = AIPreferences.removesMarkdown ? .on : .off
        aiTagSuggestionsSwitch.state = SnippetTagSuggester.isEnabled ? .on : .off
        aiSemanticRoutingSwitch.state = AIPreferences.isSemanticRoutingEnabled ? .on : .off
        lappiAskSwitch.state = LappiPreferences.isAskEnabled ? .on : .off
        lappiRecordSwitch.state = LappiPreferences.isRecordEnabled ? .on : .off
        repetitionSwitch.state = TypedRepetitionPreferences.isActive ? .on : .off
        aiAvailabilityLabel.stringValue = loc.s(
            "prefs.ai.availability",
            loc.s(AITextTransformSupport.availability.localizationKey)
        )
        switch AITextTransformSupport.availability {
        case .available:
            aiAvailabilityLabel.textColor = DevTypeTheme.statusGreen
        case .unavailable:
            aiAvailabilityLabel.textColor = DevTypeTheme.statusOrange
        }
        aiPaletteRecorder?.setShortcut(HotkeyPreferences.aiPaletteShortcut)
        for (kind, popup) in aiOutputModePopups {
            let mode = AIPreferences.outputMode(for: kind)
            let index = mode == .direct ? 0 : 1
            popup.selectItem(at: index)
        }
        aiAllowlist = AIPreferences.typedPathAllowlist
        aiAllowlistTable.reloadData()
        aiAllowlistEmptyLabel.stringValue = aiAllowlist.isEmpty
            ? loc.s("prefs.ai.allowlist.empty")
            : ""
        aiAllowlistEmptyLabel.isHidden = !aiAllowlist.isEmpty
        refreshRemovalButton(for: aiAllowlistTable)
    }

    override func didSelect() {
        reload()
    }

    @objc private func aiEnabledChanged() {
        AIPreferences.isEnabled = aiEnabledSwitch.state == .on
        reload()
    }

    @objc private func aiRemoveMarkdownChanged() {
        AIPreferences.removesMarkdown = aiRemoveMarkdownSwitch.state == .on
    }

    @objc private func aiTagSuggestionsChanged() {
        SnippetTagSuggester.isEnabled = aiTagSuggestionsSwitch.state == .on
    }

    @objc private func aiSemanticRoutingChanged() {
        AIPreferences.isSemanticRoutingEnabled = aiSemanticRoutingSwitch.state == .on
    }

    @objc private func lappiAskChanged() {
        LappiPreferences.isAskEnabled = lappiAskSwitch.state == .on
    }

    @objc private func lappiRecordChanged() {
        LappiPreferences.isRecordEnabled = lappiRecordSwitch.state == .on
    }

    /// Turning this on is a consent decision, not a preference toggle, so the switch does not
    /// take effect until the prompt is confirmed — and springs back if it is not. Turning it
    /// off revokes consent and forgets everything rather than merely pausing.
    @objc private func repetitionChanged() {
        guard repetitionSwitch.state == .on else {
            TypedRepetitionPreferences.revokeConsent()
            return
        }
        if TypedRepetitionPreferences.hasCurrentConsent {
            TypedRepetitionPreferences.isEnabled = true
            return
        }
        repetitionSwitch.state = .off
        DevTypeAlert.confirm(
            title: loc.s("prefs.repetition.consent.title"),
            message: loc.s("prefs.repetition.consent.body"),
            confirmTitle: loc.s("prefs.repetition.consent.confirm"),
            cancelTitle: loc.s("common.cancel"),
            style: .informational,
            window: view.window
        ) { [weak self] in
            TypedRepetitionPreferences.grantedConsentVersion =
                TypedRepetitionPreferences.currentConsentVersion
            TypedRepetitionPreferences.isEnabled = true
            self?.repetitionSwitch.state = .on
        }
    }

    @objc private func repetitionForget() {
        TypedRepetitionDetector.shared.forgetAll()
        DevTypeAlert.info(
            title: loc.s("prefs.repetition.forget"),
            message: loc.s("prefs.repetition.forget.done"),
            window: view.window
        )
    }

    /// Clears every per-kind output-mode override so each transform falls back to the
    /// built-in default. `resetOutputMode` removes the key rather than writing a value, so
    /// a later change to a default reaches users who never touched the setting.
    @objc private func aiOutputModeRestoreDefaultsClicked() {
        for kind in AITransformKind.builtInPalette {
            AIPreferences.resetOutputMode(for: kind)
        }
        reload()
    }

    @objc private func aiOutputModeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = AIOutputMode(rawValue: raw) else { return }
        guard let kind = aiOutputModePopups.first(where: { $0.value === sender })?.key else { return }
        AIPreferences.setOutputMode(mode, for: kind)
    }

    private func applyAIPaletteShortcut(_ shortcut: DevTypeShortcut?) {
        guard let shortcut else { return }
        guard let manager = hotkeyManager else {
            HotkeyPreferences.aiPaletteShortcut = shortcut
            reload()
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
            return
        }
        let status = manager.applyAIPaletteShortcut(shortcut)
        if status != noErr {
            DevTypeAlert.warn(
                title: loc.s("prefs.hotkeys.failed.title"),
                message: loc.s("prefs.hotkeys.failed.message", shortcut.displayString, Int(status)),
                window: view.window
            )
        }
        reload()
    }

    @objc private func resetAIPaletteShortcut() {
        HotkeyPreferences.resetAIPaletteShortcut()
        applyAIPaletteShortcut(.aiPaletteDefault)
    }

    @objc private func aiAllowlistAddFrontmost() {
        guard let bundleID = AXContextChecker.shared.frontmostApplicationBundleIdentifier(),
              !bundleID.isEmpty else {
            DevTypeAlert.warn(
                title: loc.s("alert.muteFrontmost.failed.title"),
                message: loc.s("alert.muteFrontmost.failed.message"),
                window: view.window
            )
            return
        }
        AIPreferences.addTypedPathApp(bundleID)
        reload()
    }

    @objc private func aiAllowlistAddTyped() {
        let bundleID = aiAllowlistField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        AIPreferences.addTypedPathApp(bundleID)
        aiAllowlistField.stringValue = ""
        reload()
    }

    @objc private func aiAllowlistRemove() {
        let selected = aiAllowlistTable.selectedRowIndexes
        guard !selected.isEmpty else { return }
        let ids = selected.compactMap { aiAllowlist.indices.contains($0) ? aiAllowlist[$0] : nil }
        AIPreferences.removeTypedPathApps(ids)
        reload()
    }

    // MARK: Allowlist

    override func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === aiAllowlistTable ? aiAllowlist.count : 0
    }

    override func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === aiAllowlistTable, aiAllowlist.indices.contains(row) else { return nil }
        return makeRowLabel(in: tableView, column: tableColumn, text: aiAllowlist[row])
    }
}
