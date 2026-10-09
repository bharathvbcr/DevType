import AppKit
import ExpanderEngine

// MARK: - Smart Dictation options card

extension VoicePreferencesViewController {

    func makeVoiceOptionsCard() -> GlassCardView {
        // 2. Smart Dictation Options Card
        let optionsCard = makeCard(title: loc.s("prefs.voice.options.card"), symbol: "sparkles")

        voiceTonePopup.translatesAutoresizingMaskIntoConstraints = false
        voiceTonePopup.removeAllItems()
        for tone in DictationTone.allCases {
            voiceTonePopup.addItem(withTitle: loc.s(tone.localizationKey))
            voiceTonePopup.lastItem?.representedObject = tone.rawValue
        }
        voiceTonePopup.target = self
        voiceTonePopup.action = #selector(voiceTonePopupChanged(_:))
        voiceTonePopup.setAccessibilityLabel(loc.s("prefs.voice.tone"))

        let toneRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.tone"),
            control: voiceTonePopup,
            font: DevTypeTheme.font(12, .semibold)
        )

        voiceLiveDeliveryPopup.translatesAutoresizingMaskIntoConstraints = false
        voiceLiveDeliveryPopup.removeAllItems()
        for mode in VoicePreferences.LiveDeliveryMode.allCases {
            voiceLiveDeliveryPopup.addItem(withTitle: loc.s(mode.localizationKey))
            voiceLiveDeliveryPopup.lastItem?.representedObject = mode.rawValue
        }
        voiceLiveDeliveryPopup.target = self
        voiceLiveDeliveryPopup.action = #selector(voiceLiveDeliveryModeChanged(_:))
        voiceLiveDeliveryPopup.setAccessibilityLabel(loc.s("prefs.voice.liveDelivery"))
        let realTimeTypingRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.liveDelivery"),
            control: voiceLiveDeliveryPopup,
            font: DevTypeTheme.font(12, .semibold)
        )
        let disfluencyRow = makeToggleRow(
            title: loc.s("prefs.voice.removeDisfluencies"),
            toggle: voiceDisfluenciesSwitch,
            action: #selector(voiceDisfluenciesChanged)
        )
        let autoPunctuateRow = makeToggleRow(
            title: loc.s("prefs.voice.autoPunctuate"),
            toggle: voiceAutoPunctuateSwitch,
            action: #selector(voiceAutoPunctuateChanged)
        )
        let soundFeedbackRow = makeToggleRow(
            title: loc.s("prefs.voice.soundFeedback"),
            toggle: voiceSoundFeedbackSwitch,
            action: #selector(voiceSoundFeedbackChanged)
        )
        let proofreadRow = makeToggleRow(
            title: loc.s("prefs.voice.proofreadBeforeInsert"),
            toggle: voiceProofreadSwitch,
            action: #selector(voiceProofreadChanged)
        )

        let whisperRow = makeWhisperServerRow()
        let diagnostics = makeVoiceDiagnosticsRows()

        stackInCard(optionsCard, views: [
            toneRow, realTimeTypingRow, disfluencyRow, autoPunctuateRow, proofreadRow,
            soundFeedbackRow, whisperRow, diagnostics.tracingRow, diagnostics.revealRow
        ])
        return optionsCard
    }

    @objc private func voiceProofreadChanged() {
        VoicePreferences.isProofreadBeforeInsertEnabled = voiceProofreadSwitch.state == .on
    }

    @objc private func voiceLiveDeliveryModeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = VoicePreferences.LiveDeliveryMode(rawValue: raw) else { return }
        VoicePreferences.liveDeliveryMode = mode
    }

    @objc private func voiceTonePopupChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let tone = DictationTone(rawValue: raw) else { return }
        VoicePreferences.tone = tone
    }

    @objc private func voiceAutoPunctuateChanged() {
        VoicePreferences.isAutoPunctuateEnabled = voiceAutoPunctuateSwitch.state == .on
    }

    @objc private func voiceDisfluenciesChanged() {
        VoicePreferences.isRemoveDisfluenciesEnabled = voiceDisfluenciesSwitch.state == .on
    }

    @objc private func voiceSoundFeedbackChanged() {
        VoicePreferences.isSoundFeedbackEnabled = voiceSoundFeedbackSwitch.state == .on
    }

}
