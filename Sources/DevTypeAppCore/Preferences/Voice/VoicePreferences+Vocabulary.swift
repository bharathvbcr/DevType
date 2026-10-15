import AppKit
import ExpanderEngine

// MARK: - Voice shortcut, custom dictionary and voice triggers

extension VoicePreferencesViewController {

    func makeVoiceHotkeyCard() -> GlassCardView {
        // 3. Hotkey Card
        let hotkeyCard = makeCard(title: loc.s("prefs.voice.hotkey.card"), symbol: "keyboard")
        let hotkeyHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.hotkey.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        hotkeyHint.translatesAutoresizingMaskIntoConstraints = false

        let recorder = ShortcutRecorderView(shortcut: HotkeyPreferences.voiceShortcut)
        recorder.onChange = { [weak self] shortcut in
            self?.applyVoiceShortcut(shortcut)
        }
        voiceShortcutRecorder = recorder

        let resetButton = CapsuleButton(
            title: loc.s("prefs.voice.hotkey.reset"),
            symbol: "arrow.counterclockwise",
            style: .secondary,
            target: self,
            action: #selector(resetVoiceShortcut)
        )
        let recorderRow = NSStackView(views: [recorder, resetButton])
        recorderRow.orientation = .horizontal
        recorderRow.spacing = 10
        recorderRow.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(hotkeyCard, views: [hotkeyHint, recorderRow])
        return hotkeyCard
    }

    func makeVoiceDictionaryCard() -> GlassCardView {
        // 4. Custom Dictionary Card
        let dictCard = makeCard(title: loc.s("prefs.voice.dict.card"), symbol: "text.badge.plus")
        let dictHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.dict.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        dictHint.translatesAutoresizingMaskIntoConstraints = false

        let dictionaryArea = makeTableArea(
            table: voiceDictionaryTable,
            accessibilityLabel: loc.s("prefs.voice.dict.card"),
            columnIdentifier: "voiceDictSpoken",
            emptyLabel: voiceDictionaryEmptyLabel
        )
        configureVoiceDictionaryTable()

        voiceDictSpokenField.translatesAutoresizingMaskIntoConstraints = false
        voiceDictSpokenField.placeholderString = loc.s("prefs.voice.dict.spokenPlaceholder")
        voiceDictSpokenField.font = DevTypeTheme.font(12)
        voiceDictSpokenField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        voiceDictSpokenField.setAccessibilityLabel(loc.s("prefs.voice.dict.column.spoken"))

        voiceDictReplacementField.translatesAutoresizingMaskIntoConstraints = false
        voiceDictReplacementField.placeholderString = loc.s("prefs.voice.dict.replacementPlaceholder")
        voiceDictReplacementField.font = DevTypeTheme.font(12)
        voiceDictReplacementField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        voiceDictReplacementField.setAccessibilityLabel(loc.s("prefs.voice.dict.column.replacement"))

        let addDictionaryButton = CapsuleButton(
            title: loc.s("common.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(voiceDictAddEntry)
        )
        let removeDictionaryButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(voiceDictRemoveEntry)
        )
        bindRemovalButton(removeDictionaryButton, to: voiceDictionaryTable)
        let dictButtons = NSStackView(views: [
            voiceDictSpokenField,
            voiceDictReplacementField,
            addDictionaryButton,
            removeDictionaryButton
        ])
        dictButtons.orientation = .horizontal
        dictButtons.spacing = 8
        dictButtons.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(dictCard, views: [dictHint, dictionaryArea, dictButtons])
        return dictCard
    }

    func makeVoiceTriggersCard() -> GlassCardView {
        // 5. AI Voice Triggers & Rewrites Card
        let triggersCard = makeCard(title: loc.s("prefs.voice.triggers.card"), symbol: "wand.and.stars")

        let disclaimerPill = PillBadgeView(text: "Apple Intelligence", tint: DevTypeTheme.accent, showsDot: true)
        disclaimerPill.translatesAutoresizingMaskIntoConstraints = false

        let disclaimerText = DevTypeTheme.makeLabel(
            loc.s("ai.availability.requirement"),
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.textSecondary,
            wrapping: true
        )
        disclaimerText.translatesAutoresizingMaskIntoConstraints = false

        let disclaimerBox = NSStackView(views: [disclaimerPill, disclaimerText])
        disclaimerBox.orientation = .vertical
        disclaimerBox.alignment = .leading
        disclaimerBox.spacing = 3
        disclaimerBox.translatesAutoresizingMaskIntoConstraints = false

        let triggersHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.triggers.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        triggersHint.translatesAutoresizingMaskIntoConstraints = false

        let triggersArea = makeTableArea(
            table: voiceTriggersTable,
            accessibilityLabel: loc.s("prefs.voice.triggers.card"),
            columnIdentifier: "voiceTriggerPhrase",
            emptyLabel: voiceTriggersEmptyLabel,
            height: 120
        )
        configureVoiceTriggersTable()

        voiceTriggerPhraseField.translatesAutoresizingMaskIntoConstraints = false
        voiceTriggerPhraseField.placeholderString = loc.s("prefs.voice.triggers.phrasePlaceholder")
        voiceTriggerPhraseField.font = DevTypeTheme.font(12)
        voiceTriggerPhraseField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        voiceTriggerPhraseField.setAccessibilityLabel(loc.s("prefs.voice.triggers.column.phrase"))

        voiceTriggerActionPopup.translatesAutoresizingMaskIntoConstraints = false
        voiceTriggerActionPopup.removeAllItems()
        for kind in AITransformKind.builtInPalette {
            voiceTriggerActionPopup.addItem(withTitle: loc.s(kind.localizationKey))
            voiceTriggerActionPopup.lastItem?.representedObject = kind.rawValue
        }
        voiceTriggerActionPopup.setAccessibilityLabel(loc.s("prefs.voice.triggers.column.action"))

        let addTriggerButton = CapsuleButton(
            title: loc.s("common.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(voiceTriggerAddEntry)
        )
        let removeTriggerButton = CapsuleButton(
            title: loc.s("common.remove"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(voiceTriggerRemoveEntry)
        )
        bindRemovalButton(removeTriggerButton, to: voiceTriggersTable)
        let triggerControls = NSStackView(views: [
            voiceTriggerPhraseField,
            voiceTriggerActionPopup,
            addTriggerButton,
            removeTriggerButton
        ])
        triggerControls.orientation = .horizontal
        triggerControls.spacing = 8
        triggerControls.translatesAutoresizingMaskIntoConstraints = false

        stackInCard(triggersCard, views: [disclaimerBox, triggersHint, triggersArea, triggerControls])
        return triggersCard
    }

    private struct VoiceColumnSpec {
        var titleKey: String
        var minWidth: CGFloat
        var width: CGFloat
        var identifier: String
    }

    private struct VoiceTableLayout {
        var first: VoiceColumnSpec
        var added: VoiceColumnSpec
        var autoresizing: NSTableView.ColumnAutoresizingStyle
    }

    private static let dictionaryLayout = VoiceTableLayout(
        first: VoiceColumnSpec(titleKey: "prefs.voice.dict.column.spoken", minWidth: 160, width: 250, identifier: "voiceDictSpoken"),
        added: VoiceColumnSpec(titleKey: "prefs.voice.dict.column.replacement", minWidth: 160, width: 250, identifier: "voiceDictReplacement"),
        autoresizing: .uniformColumnAutoresizingStyle
    )

    private static let triggerLayout = VoiceTableLayout(
        first: VoiceColumnSpec(titleKey: "prefs.voice.triggers.column.phrase", minWidth: 180, width: 260, identifier: "voiceTriggerPhrase"),
        added: VoiceColumnSpec(titleKey: "prefs.voice.triggers.column.action", minWidth: 160, width: 240, identifier: "voiceTriggerAction"),
        autoresizing: .lastColumnOnlyAutoresizingStyle
    )

    private func configureVoiceDictionaryTable() {
        configureVoiceTable(voiceDictionaryTable, layout: Self.dictionaryLayout)
    }

    private func configureVoiceTriggersTable() {
        configureVoiceTable(voiceTriggersTable, layout: Self.triggerLayout)
    }

    private func configureVoiceTable(_ table: NSTableView, layout: VoiceTableLayout) {
        guard let firstColumn = table.tableColumns.first else { return }
        styleVoiceColumn(firstColumn, spec: layout.first)
        let addedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(layout.added.identifier))
        styleVoiceColumn(addedColumn, spec: layout.added)
        table.addTableColumn(addedColumn)
        table.headerView = NSTableHeaderView()
        table.columnAutoresizingStyle = layout.autoresizing
        table.allowsColumnReordering = false
    }

    private func styleVoiceColumn(_ column: NSTableColumn, spec: VoiceColumnSpec) {
        column.title = loc.s(spec.titleKey)
        column.minWidth = spec.minWidth
        column.width = spec.width
        column.resizingMask = [.autoresizingMask, .userResizingMask]
    }

    private func applyVoiceShortcut(_ shortcut: DevTypeShortcut?) {
        HotkeyBindingApply.commit(
            shortcut, kind: .voiceDictation, manager: hotkeyManager
        ) { [weak self] in self?.reload() }
    }

    @objc private func resetVoiceShortcut() {
        HotkeyPreferences.resetVoiceShortcut()
        if let manager = hotkeyManager {
            manager.apply(HotkeyPreferences.voiceShortcut, to: .voiceDictation)
        } else {
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
        reload()
    }

    @objc private func voiceDictAddEntry() {
        let spoken = voiceDictSpokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = voiceDictReplacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !replacement.isEmpty else { return }

        VoicePreferences.addDictionaryEntry(spoken: spoken, replacement: replacement)
        voiceDictSpokenField.stringValue = ""
        voiceDictReplacementField.stringValue = ""
        reload()
    }

    @objc private func voiceDictRemoveEntry() {
        removeSelectedVoiceRow(in: voiceDictionaryTable, entries: voiceDictEntries) {
            VoicePreferences.removeDictionaryEntry(spoken: $0.spoken)
        }
    }

    @objc private func voiceTriggerAddEntry() {
        let phrase = voiceTriggerPhraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty,
              let rawAction = voiceTriggerActionPopup.selectedItem?.representedObject as? String else { return }

        VoicePreferences.addVoiceTrigger(phrase: phrase, action: rawAction)
        voiceTriggerPhraseField.stringValue = ""
        reload()
    }

    @objc private func voiceTriggerRemoveEntry() {
        removeSelectedVoiceRow(in: voiceTriggersTable, entries: voiceTriggerEntries) {
            VoicePreferences.removeVoiceTrigger(phrase: $0.phrase)
        }
    }

    private func removeSelectedVoiceRow<Entry>(
        in table: NSTableView,
        entries: [Entry],
        remove: (Entry) -> Void
    ) {
        let row = table.selectedRow
        guard entries.indices.contains(row) else { return }
        remove(entries[row])
        reload()
    }

}
