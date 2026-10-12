import AppKit
import ExpanderEngine

// MARK: - Transcription engine card and per-engine readiness

extension VoicePreferencesViewController {

    func makeVoiceModelsCard() -> GlassCardView {
        // 1. Models Card / Engine Configuration Card
        let modelsCard = makeCard(title: loc.s("prefs.voice.models.card"), symbol: "waveform.and.mic")
        let modelsHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.models.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        modelsHint.translatesAutoresizingMaskIntoConstraints = false

        // Active transcription engine selector row
        voiceModelPopup.translatesAutoresizingMaskIntoConstraints = false
        voiceModelPopup.removeAllItems()
        for engine in TranscriptionEngine.allCases {
            voiceModelPopup.addItem(withTitle: loc.s(engine.localizationKey))
            voiceModelPopup.lastItem?.representedObject = engine.rawValue
        }
        voiceModelPopup.target = self
        voiceModelPopup.action = #selector(voiceModelPopupChanged(_:))
        voiceModelPopup.setAccessibilityLabel(loc.s("prefs.voice.activeModel"))

        let activeModelRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.activeModel"),
            control: voiceModelPopup,
            font: DevTypeTheme.font(12, .semibold)
        )

        let speechModelsLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.speechModels"),
            font: DevTypeTheme.font(11.5, .semibold),
            color: DevTypeTheme.textPrimary
        )
        let speechModelsInventory = makeVoiceRecognitionModelInventory()

        let appleAssetRow = makeAppleSpeechAssetRow()

        let speechModelsHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.speechModels.hint"),
            font: DevTypeTheme.font(10),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )

        configureGeminiConfiguration()
        configureLocalLLMConfiguration()

        let modelCards: [NSView] = [
            modelsHint,
            activeModelRow,
            speechModelsLabel,
            speechModelsInventory,
            appleAssetRow,
            speechModelsHint,
            DevTypeTheme.makeHairline(),
            geminiConfigContainer,
            localLLMConfigContainer
        ]
        stackInCard(modelsCard, views: modelCards)
        return modelsCard
    }

    @objc private func voiceModelPopupChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let engine = TranscriptionEngine(rawValue: raw) else { return }
        VoicePreferences.transcriptionEngine = engine
        reload()
    }

    private func makeVoiceRecognitionModelInventory() -> NSView {
        let inventory = PreferenceRowView()
        inventory.translatesAutoresizingMaskIntoConstraints = false
        inventory.wantsLayer = true
        inventory.layer?.cornerRadius = DevTypeTheme.Radius.control
        inventory.layer?.backgroundColor = DevTypeTheme.contrastOverlay(0.035).cgColor
        inventory.layer?.borderWidth = 1
        inventory.layer?.borderColor = DevTypeTheme.hairline.cgColor

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        inventory.addSubview(rows)

        for (index, engine) in voiceEngines.enumerated() {
            let presentation = voiceEngineStatus(for: engine)
            let name = DevTypeTheme.makeLabel(
                loc.s(engine.localizationKey),
                font: DevTypeTheme.font(11, .medium),
                color: DevTypeTheme.textPrimary
            )
            name.lineBreakMode = .byTruncatingTail

            let source = DevTypeTheme.makeLabel(
                loc.s(Self.sourceKey(for: engine)),
                font: DevTypeTheme.font(10.5),
                color: DevTypeTheme.textSecondary
            )
            source.widthAnchor.constraint(equalToConstant: 76).isActive = true

            let status = DevTypeTheme.makeLabel(
                presentation.text,
                font: DevTypeTheme.font(10.5, .medium),
                color: presentation.color
            )
            status.lineBreakMode = .byTruncatingTail
            status.toolTip = presentation.detail
            status.widthAnchor.constraint(greaterThanOrEqualToConstant: 176).isActive = true
            voiceEngineStatusLabels[engine] = status

            let row = NSStackView(views: [name, source, status])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 32).isActive = true
            row.setAccessibilityLabel("\(name.stringValue), \(source.stringValue), \(status.stringValue)")
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            status.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true

            if index < voiceEngines.count - 1 {
                let separator = DevTypeTheme.makeHairline()
                rows.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: inventory.topAnchor, constant: 2),
            rows.leadingAnchor.constraint(equalTo: inventory.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: inventory.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: inventory.bottomAnchor, constant: -2)
        ])
        return inventory
    }

    /// Configuration readiness for each engine.
    ///
    /// Replaces an inventory of downloadable ASR models that no engine could actually use
    /// and whose download URLs no longer resolve. This reports something the user can act
    /// on: whether the selected engine will work, and what is missing if it will not.
    func voiceEngineStatus(
        for engine: TranscriptionEngine,
        speechAuthorization: SpeechAuthorization.Status = SpeechAuthorization.status(),
        geminiState: GeminiAPIKeyStore.ReadState? = nil
    ) -> (text: String, color: NSColor, detail: String?) {
        switch engine {
        case .gemini:
            switch geminiState ?? GeminiAPIKeyStore.readState() {
            case .unavailable:
                return (
                    loc.s("prefs.voice.keychain.unavailable.pill"),
                    DevTypeTheme.accentBright,
                    loc.s("prefs.voice.keychain.unavailable.message")
                )
            case .missing, .available(""):
                return (loc.s("prefs.voice.speechModels.status.needsKey"), DevTypeTheme.statusOrange, nil)
            case .available:
                break
            }
            return VoicePreferences.hasCloudAudioConsent
                ? (loc.s("prefs.voice.speechModels.status.ready"), DevTypeTheme.statusGreen, nil)
                : (loc.s("prefs.voice.speechModels.status.needsConsent"), DevTypeTheme.statusOrange, nil)

        case .whisperLocal:
            let state = WhisperReadinessPresentation.resolve(
                setupState: whisperReadinessState,
                isManagedByApp: WhisperServerController.shared.isManagedByApp,
                hasLocalModel: whisperModelStatus?.isVerified == true
            )
            let color: NSColor
            switch state.tintRole {
            case .checking: color = DevTypeTheme.statusGray
            case .ready: color = DevTypeTheme.statusGreen
            case .attention: color = DevTypeTheme.statusOrange
            }
            let detail = state.detailState.map {
                WhisperServerSetup.pendingCommands(
                    for: $0,
                    modelStatus: whisperModelStatus,
                    endpoint: VoicePreferences.whisperEndpoint
                )
            }
            return (loc.s(state.statusKey), color, detail)

        case .localLLM:
            let state = LocalAIReadinessDisplayState.resolve(
                authorization: speechAuthorization,
                speechReadiness: appleSpeechReadiness,
                selectedCorrectionProviderID: localAICorrectionProviderID
            )
            let color: NSColor
            switch state.tintRole {
            case .checking: color = DevTypeTheme.statusGray
            case .ready: color = DevTypeTheme.statusGreen
            case .attention: color = DevTypeTheme.statusOrange
            }
            let statusKey = state == .ready
                ? resolvedAppleSpeechStatusKey(default: state.statusKey)
                : state.statusKey
            return (loc.s(statusKey), color, nil)

        case .appleSpeech:
            let state = AppleSpeechReadinessDisplayState.resolve(
                authorization: speechAuthorization,
                providerReadiness: appleSpeechReadiness
            )
            let color: NSColor
            switch state.tintRole {
            case .checking: color = DevTypeTheme.statusGray
            case .ready: color = DevTypeTheme.statusGreen
            case .attention: color = DevTypeTheme.statusOrange
            }
            let statusKey = state == .ready
                ? resolvedAppleSpeechStatusKey(default: state.statusKey)
                : state.statusKey
            return (loc.s(statusKey), color, nil)
        }
    }

    private static func sourceKey(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .gemini: return "prefs.voice.speechModels.source.cloud"
        case .whisperLocal: return "prefs.voice.speechModels.source.local"
        case .localLLM, .appleSpeech: return "prefs.voice.speechModels.source.system"
        }
    }
}
