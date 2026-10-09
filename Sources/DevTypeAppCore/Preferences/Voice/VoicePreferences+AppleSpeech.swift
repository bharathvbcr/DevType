import AppKit
import ExpanderEngine

// MARK: - Apple Speech readiness and on-device asset install

extension VoicePreferencesViewController {

    func makeAppleSpeechAssetRow() -> NSView {
        appleSpeechAssetButton.title = loc.s("status.checking")
        appleSpeechAssetButton.bezelStyle = .rounded
        appleSpeechAssetButton.controlSize = .small
        appleSpeechAssetButton.target = self
        appleSpeechAssetButton.action = #selector(installAppleSpeechAssets)
        appleSpeechAssetButton.translatesAutoresizingMaskIntoConstraints = false
        appleSpeechAssetButton.setAccessibilityLabel(loc.s("prefs.voice.appleAssets.install"))
        let appleAssetRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.appleAssets.label"),
            control: appleSpeechAssetButton,
            font: DevTypeTheme.font(11.5, .medium)
        )
        appleSpeechAssetRow = appleAssetRow
        return appleAssetRow
    }

    func refreshAppleSpeechReadiness() {
        let generation = appleSpeechReadinessRefresh.begin()
        appleSpeechReadinessTask?.cancel()
        appleSpeechReadiness = nil
        appleSpeechAnalyzerReadiness = nil
        resolvedAppleSpeechProviderID = nil
        applyAppleSpeechAssetPresentation()

        let locale = Locale.current
        let analyzer = AppleSpeechAnalyzerAdapter(locale: locale)
        let legacy = LegacyAppleSpeechAdapter(locale: locale)
        let platformSupportsAnalyzer: Bool
        if #available(macOS 26.0, *) {
            platformSupportsAnalyzer = true
        } else {
            platformSupportsAnalyzer = false
        }
        let endpoint = VoicePreferences.localLLMEndpoint
        let model = VoicePreferences.localLLMModel
        let preferAppleFoundationModels: Bool
        if #available(macOS 26.0, *) {
            preferAppleFoundationModels = true
        } else {
            preferAppleFoundationModels = false
        }
        let correctionIDs = VoiceSessionSnapshotFactory.localCorrectionProviderIDs(
            for: endpoint,
            preferAppleFoundationModels: preferAppleFoundationModels
        )
        let correctionRegistry = CorrectionProviderRegistry(providers: [
            FoundationLanguageModelCorrector(),
            OllamaCorrector(endpointURL: endpoint, modelName: model),
            OpenAICompatibleCorrector(endpointURL: endpoint, modelName: model),
            DeterministicCorrector(),
        ])
        appleSpeechReadinessTask = Task { [weak self] in
            async let analyzerProbe = analyzer.probe()
            async let legacyProbe = legacy.probe()
            async let correctionProbe = correctionRegistry.resolveActiveCorrector(
                preferredID: correctionIDs.first,
                fallbackIDs: Array(correctionIDs.dropFirst()),
                privacyRoute: .localNetworkOnly
            )
            let (analyzerReadiness, legacyReadiness, correction) = await (
                analyzerProbe,
                legacyProbe,
                correctionProbe
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.appleSpeechReadinessRefresh.claim(generation) else { return }
                let resolution = AppleSpeechPreferencesResolution.resolve(
                    platformSupportsAnalyzer: platformSupportsAnalyzer,
                    analyzerReadiness: analyzerReadiness,
                    legacyReadiness: legacyReadiness
                )
                self.appleSpeechReadiness = resolution.readiness
                self.appleSpeechAnalyzerReadiness = analyzerReadiness
                self.resolvedAppleSpeechProviderID = resolution.providerID
                self.localAICorrectionProviderID = correction?.descriptor.id
                self.appleSpeechReadinessTask = nil
                self.applyAppleSpeechAssetPresentation()
                let authorization = SpeechAuthorization.status()
                for engine in [TranscriptionEngine.localLLM, .appleSpeech] {
                    let presentation = self.voiceEngineStatus(
                        for: engine,
                        speechAuthorization: authorization
                    )
                    self.voiceEngineStatusLabels[engine]?.stringValue = presentation.text
                    self.voiceEngineStatusLabels[engine]?.textColor = presentation.color
                    self.voiceEngineStatusLabels[engine]?.toolTip = presentation.detail
                    self.voiceEngineStatusLabels[engine]?.setAccessibilityLabel(presentation.text)
                }
            }
        }
    }

    func resolvedAppleSpeechStatusKey(default defaultKey: String) -> String {
        switch resolvedAppleSpeechProviderID {
        case VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer:
            return "prefs.voice.speechModels.status.readyAnalyzer"
        case VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy:
            return "prefs.voice.speechModels.status.readyLegacy"
        default:
            return defaultKey
        }
    }

    private var platformSupportsAppleSpeechAnalyzer: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private func applyAppleSpeechAssetPresentation() {
        let presentation = AppleSpeechAssetControlsPresentation.resolve(
            platformSupportsAnalyzer: platformSupportsAppleSpeechAnalyzer,
            analyzerReadiness: appleSpeechAnalyzerReadiness,
            isInstalling: appleSpeechAssetInstallLifecycle.isActive
        )
        appleSpeechAssetRow?.isHidden = presentation.isHidden
        appleSpeechAssetButton.title = loc.s(presentation.titleKey)
        appleSpeechAssetButton.isEnabled = presentation.isEnabled
        appleSpeechAssetButton.setAccessibilityLabel(loc.s(presentation.titleKey))
    }

    @objc private func installAppleSpeechAssets() {
        guard platformSupportsAppleSpeechAnalyzer,
              let request = appleSpeechAssetInstallLifecycle.begin() else { return }
        applyAppleSpeechAssetPresentation()

        let locale = Locale.current
        let adapter = AppleSpeechAnalyzerAdapter(locale: locale)
        appleSpeechAssetInstallTask = Task { @MainActor [weak self] in
            let succeeded: Bool
            do {
                _ = try await adapter.installAssets(
                    for: locale,
                    deadline: Date().addingTimeInterval(15 * 60)
                )
                succeeded = true
            } catch is CancellationError {
                guard let self else { return }
                switch self.appleSpeechAssetInstallLifecycle.claimCancellation(
                    request,
                    taskIsCancelled: Task.isCancelled
                ) {
                case .ignore:
                    return
                case .retireSilently:
                    self.finishAppleSpeechAssetInstall(showFailure: false)
                case .reportFailure:
                    self.finishAppleSpeechAssetInstall(showFailure: true)
                }
                return
            } catch {
                succeeded = false
            }

            guard !Task.isCancelled,
                  let self,
                  self.appleSpeechAssetInstallLifecycle.claimCompletion(request) else { return }
            self.finishAppleSpeechAssetInstall(showFailure: !succeeded)
        }
    }

    private func finishAppleSpeechAssetInstall(showFailure: Bool) {
        appleSpeechAssetInstallTask = nil
        defer { onLocalizationBlockingOperationDidEnd?() }
        if showFailure {
            DevTypeAlert.warn(
                title: loc.s("prefs.voice.appleAssets.failed.title"),
                message: loc.s("prefs.voice.appleAssets.failed.message"),
                window: view.window
            )
        }
        refreshAppleSpeechReadiness()
    }

    func invalidateAppleSpeechAssetInstall() {
        let wasActive = appleSpeechAssetInstallLifecycle.isActive
        appleSpeechAssetInstallTask?.cancel()
        appleSpeechAssetInstallTask = nil
        appleSpeechAssetInstallLifecycle.invalidate()
        if wasActive {
            onLocalizationBlockingOperationDidEnd?()
        }
    }

}
