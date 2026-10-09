import AppKit
import ExpanderEngine

// MARK: - Local transcript-cleanup model endpoint and picker

extension VoicePreferencesViewController {

    /// Fills `localLLMConfigContainer`, which the engine card shows only while Local AI is selected.
    func configureLocalLLMConfiguration() {
        // Local LLM Configuration Box
        localLLMConfigContainer.orientation = .vertical
        localLLMConfigContainer.alignment = .leading
        localLLMConfigContainer.spacing = 6
        localLLMConfigContainer.translatesAutoresizingMaskIntoConstraints = false

        let localEndpointLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.localLLM.endpointLabel"),
            font: DevTypeTheme.font(11.5, .medium),
            color: DevTypeTheme.textPrimary
        )

        localLLMEndpointField.translatesAutoresizingMaskIntoConstraints = false
        localLLMEndpointField.font = DevTypeTheme.font(12)
        localLLMEndpointField.placeholderString = "http://localhost:11434/v1/chat/completions"
        localLLMEndpointField.target = self
        localLLMEndpointField.action = #selector(localLLMEndpointChanged)
        localLLMEndpointField.delegate = self
        localLLMEndpointField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        localLLMEndpointField.setAccessibilityLabel(loc.s("prefs.voice.localLLM.endpointLabel"))
        localLLMEndpointField.setAccessibilityTitleUIElement(localEndpointLabel)

        let scanBtn = CapsuleButton(
            title: loc.s("prefs.voice.cleanupModels.scan"),
            symbol: "arrow.clockwise",
            style: .secondary,
            target: self,
            action: #selector(scanLocalModelsClicked)
        )
        localLLMScanButton = scanBtn

        let statusPill = PillBadgeView(
            text: loc.s("prefs.voice.localLLM.endpointStatus"),
            tint: DevTypeTheme.statusGray,
            showsDot: false
        )
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        localLLMStatusPill = statusPill

        let endpointRow = NSStackView(views: [localLLMEndpointField, scanBtn, statusPill])
        endpointRow.orientation = .horizontal
        endpointRow.spacing = 8
        endpointRow.alignment = .centerY
        endpointRow.translatesAutoresizingMaskIntoConstraints = false

        let localModelLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.cleanupModels"),
            font: DevTypeTheme.font(11.5, .medium),
            color: DevTypeTheme.textPrimary
        )

        localLLMModelPopup.translatesAutoresizingMaskIntoConstraints = false
        localLLMModelPopup.target = self
        localLLMModelPopup.action = #selector(localLLMModelPopupChanged(_:))
        localLLMModelPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        localLLMModelPopup.setAccessibilityLabel(loc.s("prefs.voice.cleanupModels"))
        localLLMModelPopup.setAccessibilityTitleUIElement(localModelLabel)

        localLLMModelField.translatesAutoresizingMaskIntoConstraints = false
        localLLMModelField.font = DevTypeTheme.font(12)
        localLLMModelField.placeholderString = loc.s("prefs.voice.localLLM.customPlaceholder")
        localLLMModelField.target = self
        localLLMModelField.action = #selector(localLLMModelChanged)
        localLLMModelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        localLLMModelField.isHidden = true
        localLLMModelField.setAccessibilityLabel(loc.s("prefs.voice.cleanupModels"))
        localLLMModelField.setAccessibilityTitleUIElement(localModelLabel)

        let modelPickerRow = NSStackView(views: [localLLMModelPopup, localLLMModelField])
        modelPickerRow.orientation = .horizontal
        modelPickerRow.spacing = 8
        modelPickerRow.alignment = .centerY
        modelPickerRow.translatesAutoresizingMaskIntoConstraints = false

        let localSubHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.cleanupModels.hint"),
            font: DevTypeTheme.font(10),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )

        localLLMConfigContainer.addArrangedSubview(localEndpointLabel)
        localLLMConfigContainer.addArrangedSubview(endpointRow)
        localLLMConfigContainer.addArrangedSubview(localModelLabel)
        localLLMConfigContainer.addArrangedSubview(modelPickerRow)
        localLLMConfigContainer.addArrangedSubview(localSubHint)
    }

    @objc private func localLLMEndpointChanged() {
        invalidateLocalModelScan(resetPresentation: true)
        if commitLocalLLMEndpointField() {
            refreshLocalAIReadinessAfterConfigurationChange()
        }
    }

    @discardableResult
    private func commitLocalLLMEndpointField() -> Bool {
        let text = localLLMEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URL(string: text),
              VoicePreferences.setLocalLLMEndpoint(url) else {
            localLLMEndpointField.stringValue = VoicePreferences.localLLMEndpoint.absoluteString
            localLLMStatusPill?.update(
                text: loc.s("prefs.voice.localLLM.endpointInvalid.pill"),
                tint: DevTypeTheme.statusOrange
            )
            DevTypeAlert.warn(
                title: loc.s("prefs.voice.localLLM.endpointInvalid.title"),
                message: loc.s("prefs.voice.localLLM.endpointInvalid.message"),
                window: view.window
            )
            return false
        }
        localLLMEndpointField.stringValue = url.absoluteString
        localLLMStatusPill?.update(
            text: loc.s("prefs.voice.localLLM.endpointStatus"),
            tint: DevTypeTheme.statusGray
        )
        return true
    }

    @objc private func localLLMModelChanged() {
        let text = localLLMModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            VoicePreferences.localLLMModel = text
            refreshLocalAIReadinessAfterConfigurationChange()
        }
    }

    @objc private func localLLMModelPopupChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        if raw == "__custom__" {
            localLLMModelField.isHidden = false
            localLLMModelField.stringValue = VoicePreferences.localLLMModel
        } else {
            localLLMModelField.isHidden = true
            VoicePreferences.localLLMModel = raw
            localLLMModelField.stringValue = raw
            refreshLocalAIReadinessAfterConfigurationChange()
        }
    }

    private func refreshLocalAIReadinessAfterConfigurationChange() {
        localAICorrectionProviderID = nil
        let presentation = voiceEngineStatus(for: .localLLM)
        voiceEngineStatusLabels[.localLLM]?.stringValue = presentation.text
        voiceEngineStatusLabels[.localLLM]?.textColor = presentation.color
        voiceEngineStatusLabels[.localLLM]?.toolTip = presentation.detail
        voiceEngineStatusLabels[.localLLM]?.setAccessibilityLabel(presentation.text)
        refreshAppleSpeechReadiness()
    }

    @objc private func scanLocalModelsClicked() {
        guard commitLocalLLMEndpointField() else { return }
        localLLMScanButton?.isEnabled = false
        localLLMScanButton?.title = loc.s("prefs.voice.cleanupModels.scanning")
        localLLMStatusPill?.update(
            text: loc.s("prefs.voice.cleanupModels.scanning"),
            tint: DevTypeTheme.accent
        )

        let endpoint = VoicePreferences.localLLMEndpoint
        let request = localModelScanRefresh.begin(endpoint: endpoint)
        localModelScanTask?.cancel()
        localModelScanTask = Task { [weak self] in
            let discovered = await LocalLLMModelCatalog.shared.fetchAvailableLocalModels(endpoint: endpoint)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.localModelScanRefresh.claim(
                          request,
                          currentEndpoint: VoicePreferences.localLLMEndpoint
                      ) else { return }
                self.localModelScanTask = nil
                self.localLLMScanButton?.isEnabled = true
                self.localLLMScanButton?.title = self.loc.s("prefs.voice.cleanupModels.scan")
                if discovered.isEmpty {
                    self.localLLMStatusPill?.update(
                        text: self.loc.s("prefs.voice.cleanupModels.none"),
                        tint: DevTypeTheme.statusOrange
                    )
                } else {
                    self.localLLMStatusPill?.update(
                        text: self.loc.s("prefs.voice.cleanupModels.found", discovered.count),
                        tint: DevTypeTheme.statusGreen
                    )
                }
                self.refreshLocalLLMModelsPopup(additionalDiscoveredModels: discovered)
            }
        }
    }

    func invalidateLocalModelScan(resetPresentation: Bool) {
        localModelScanTask?.cancel()
        localModelScanTask = nil
        localModelScanRefresh.invalidate()
        guard resetPresentation else { return }
        localLLMScanButton?.isEnabled = true
        localLLMScanButton?.title = loc.s("prefs.voice.cleanupModels.scan")
        localLLMStatusPill?.update(
            text: loc.s("prefs.voice.localLLM.endpointStatus"),
            tint: DevTypeTheme.statusGray
        )
    }

    func refreshLocalLLMModelsPopup(additionalDiscoveredModels: [String] = []) {
        let currentSelectedModel = VoicePreferences.localLLMModel
        localLLMModelPopup.removeAllItems()

        // 1. Preset recommended models
        let presets: [(title: String, id: String)] = [
            (loc.s("prefs.voice.localLLM.fastRecommended", "Llama 3.2"), "llama3.2"),
            (loc.s("prefs.voice.localLLM.ultraFast", "Llama 3.2 1B"), "llama3.2:1b"),
            ("Qwen 2.5 (3B)", "qwen2.5:3b"),
            ("Qwen 2.5 (7B)", "qwen2.5:7b"),
            ("Phi-3.5 (3.8B)", "phi3.5"),
            ("Mistral (7B)", "mistral"),
            ("Gemma 2 (2B)", "gemma2:2b"),
            ("DeepSeek R1 (1.5B)", "deepseek-r1:1.5b"),
            ("DeepSeek R1 (7B)", "deepseek-r1:7b")
        ]

        for p in presets {
            localLLMModelPopup.addItem(withTitle: p.title)
            localLLMModelPopup.lastItem?.representedObject = p.id
        }

        // 2. Add dynamically discovered models from Ollama / LM Studio (if not already in presets)
        var addedSeparator = false
        for modelName in additionalDiscoveredModels {
            if !presets.contains(where: { $0.id == modelName }) {
                if !addedSeparator {
                    localLLMModelPopup.menu?.addItem(NSMenuItem.separator())
                    addedSeparator = true
                }
                localLLMModelPopup.addItem(withTitle: loc.s("prefs.voice.localLLM.installed", modelName))
                localLLMModelPopup.lastItem?.representedObject = modelName
            }
        }

        // 3. Custom model option
        localLLMModelPopup.menu?.addItem(NSMenuItem.separator())
        localLLMModelPopup.addItem(withTitle: loc.s("prefs.voice.localLLM.customOption"))
        localLLMModelPopup.lastItem?.representedObject = "__custom__"

        // Select the active model
        if let matchIndex = localLLMModelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == currentSelectedModel }) {
            localLLMModelPopup.selectItem(at: matchIndex)
            localLLMModelField.isHidden = true
        } else {
            // It's a custom model
            localLLMModelPopup.selectItem(at: localLLMModelPopup.numberOfItems - 1)
            localLLMModelField.isHidden = false
            localLLMModelField.stringValue = currentSelectedModel
        }
    }

}
