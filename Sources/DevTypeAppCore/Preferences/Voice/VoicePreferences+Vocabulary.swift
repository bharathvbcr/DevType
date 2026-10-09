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

    private func configureVoiceDictionaryTable() {
        guard let spokenColumn = voiceDictionaryTable.tableColumns.first else { return }
        spokenColumn.title = loc.s("prefs.voice.dict.column.spoken")
        spokenColumn.minWidth = 160
        spokenColumn.width = 250
        spokenColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        let replacementColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("voiceDictReplacement")
        )
        replacementColumn.title = loc.s("prefs.voice.dict.column.replacement")
        replacementColumn.minWidth = 160
        replacementColumn.width = 250
        replacementColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        voiceDictionaryTable.addTableColumn(replacementColumn)
        voiceDictionaryTable.headerView = NSTableHeaderView()
        voiceDictionaryTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        voiceDictionaryTable.allowsColumnReordering = false
    }

    private func configureVoiceTriggersTable() {
        guard let phraseColumn = voiceTriggersTable.tableColumns.first else { return }
        phraseColumn.title = loc.s("prefs.voice.triggers.column.phrase")
        phraseColumn.minWidth = 180
        phraseColumn.width = 260
        phraseColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        let actionColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("voiceTriggerAction")
        )
        actionColumn.title = loc.s("prefs.voice.triggers.column.action")
        actionColumn.minWidth = 160
        actionColumn.width = 240
        actionColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        voiceTriggersTable.addTableColumn(actionColumn)
        voiceTriggersTable.headerView = NSTableHeaderView()
        voiceTriggersTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        voiceTriggersTable.allowsColumnReordering = false
    }

    private func applyVoiceShortcut(_ shortcut: DevTypeShortcut?) {
        guard let shortcut else { return }
        if let manager = hotkeyManager {
            manager.applyVoiceShortcut(shortcut)
        } else {
            HotkeyPreferences.voiceShortcut = shortcut
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        }
        reload()
    }

    @objc private func resetVoiceShortcut() {
        HotkeyPreferences.resetVoiceShortcut()
        if let manager = hotkeyManager {
            manager.applyVoiceShortcut(HotkeyPreferences.voiceShortcut)
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
        let row = voiceDictionaryTable.selectedRow
        guard voiceDictEntries.indices.contains(row) else { return }
        let entry = voiceDictEntries[row]
        VoicePreferences.removeDictionaryEntry(spoken: entry.spoken)
        reload()
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
        let row = voiceTriggersTable.selectedRow
        guard voiceTriggerEntries.indices.contains(row) else { return }
        let entry = voiceTriggerEntries[row]
        VoicePreferences.removeVoiceTrigger(phrase: entry.phrase)
        reload()
    }

}
