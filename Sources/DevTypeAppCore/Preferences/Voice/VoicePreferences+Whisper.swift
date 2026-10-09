import AppKit
import ExpanderEngine

// MARK: - Local Whisper server and model

extension VoicePreferencesViewController {

    func makeWhisperServerRow() -> NSView {
        // Local Whisper server control. Placed with the other voice controls rather than
        // buried in a sheet: it is something the user starts before dictating and stops
        // afterwards, not a one-time setup step.
        whisperServerButton.title = loc.s("prefs.voice.whisper.start")
        whisperServerButton.bezelStyle = .rounded
        whisperServerButton.controlSize = .small
        whisperServerButton.target = self
        whisperServerButton.action = #selector(toggleWhisperServer)
        whisperServerButton.translatesAutoresizingMaskIntoConstraints = false

        whisperModelButton.title = loc.s("prefs.voice.whisper.getModel")
        whisperModelButton.bezelStyle = .rounded
        whisperModelButton.controlSize = .small
        whisperModelButton.target = self
        whisperModelButton.action = #selector(downloadWhisperModel)
        whisperModelButton.translatesAutoresizingMaskIntoConstraints = false

        let whisperRow = PreferenceRowView()
        whisperRow.translatesAutoresizingMaskIntoConstraints = false
        let whisperLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.whisper.server"),
            font: DevTypeTheme.font(12.5, .medium),
            color: DevTypeTheme.textPrimary,
            wrapping: true
        )
        whisperLabel.translatesAutoresizingMaskIntoConstraints = false
        whisperRow.addSubview(whisperLabel)
        whisperRow.addSubview(whisperModelButton)
        whisperRow.addSubview(whisperServerButton)
        NSLayoutConstraint.activate([
            whisperLabel.leadingAnchor.constraint(equalTo: whisperRow.leadingAnchor),
            whisperLabel.centerYAnchor.constraint(equalTo: whisperRow.centerYAnchor),
            whisperLabel.trailingAnchor.constraint(lessThanOrEqualTo: whisperModelButton.leadingAnchor, constant: -12),
            whisperModelButton.trailingAnchor.constraint(equalTo: whisperServerButton.leadingAnchor, constant: -8),
            whisperModelButton.centerYAnchor.constraint(equalTo: whisperRow.centerYAnchor),
            whisperServerButton.trailingAnchor.constraint(equalTo: whisperRow.trailingAnchor),
            whisperServerButton.topAnchor.constraint(equalTo: whisperRow.topAnchor, constant: 2),
            whisperServerButton.bottomAnchor.constraint(equalTo: whisperRow.bottomAnchor, constant: -2)
        ])
        return whisperRow
    }

    /// Reflects who owns the running server, if anyone. Three states, because they need
    /// three different actions: ours (stop it), someone else's (leave it alone), none
    /// (start one).
    func refreshWhisperReadiness() {
        let endpoint = VoicePreferences.whisperEndpoint
        let request = whisperReadinessRefresh.begin(endpoint: endpoint)
        whisperReadinessTask?.cancel()
        whisperReadinessState = nil
        whisperModelStatus = nil
        applyWhisperReadinessPresentation()

        whisperReadinessTask = Task { [weak self] in
            async let state = WhisperServerSetup.detect(endpoint: endpoint)
            async let modelStatus = WhisperServerSetup.inspectModel()
            let (resolvedState, resolvedModelStatus) = await (state, modelStatus)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.whisperReadinessRefresh.claim(
                          request,
                          currentEndpoint: VoicePreferences.whisperEndpoint
                      ) else { return }
                self.whisperReadinessState = resolvedState
                self.whisperModelStatus = resolvedModelStatus
                self.whisperReadinessTask = nil
                self.applyWhisperReadinessPresentation()
            }
        }
    }

    private func applyWhisperReadinessPresentation() {
        let presentation = WhisperReadinessPresentation.resolve(
            setupState: whisperReadinessState,
            isManagedByApp: WhisperServerController.shared.isManagedByApp,
            hasLocalModel: whisperModelStatus?.isVerified == true
        )
        let controls = WhisperControlsPresentation.resolve(
            readiness: presentation,
            activeAction: whisperActionLifecycle.activeAction
        )
        let tint: NSColor
        switch presentation.tintRole {
        case .checking: tint = DevTypeTheme.statusGray
        case .ready: tint = DevTypeTheme.statusGreen
        case .attention: tint = DevTypeTheme.statusOrange
        }
        let detail = presentation.detailState.map {
            WhisperServerSetup.pendingCommands(
                for: $0,
                modelStatus: whisperModelStatus,
                endpoint: VoicePreferences.whisperEndpoint
            )
        }
        let statusText = loc.s(presentation.statusKey)
        voiceEngineStatusLabels[.whisperLocal]?.stringValue = statusText
        voiceEngineStatusLabels[.whisperLocal]?.textColor = tint
        voiceEngineStatusLabels[.whisperLocal]?.toolTip = detail
        voiceEngineStatusLabels[.whisperLocal]?.setAccessibilityLabel(statusText)
        whisperServerButton.title = loc.s(controls.serverButtonTitleKey)
        whisperServerButton.isEnabled = controls.isServerButtonEnabled
        whisperModelButton.isHidden = controls.isModelButtonHidden
        whisperModelButton.isEnabled = controls.isModelButtonEnabled
        if let modelButtonTitleKey = controls.modelButtonTitleKey {
            whisperModelButton.title = loc.s(modelButtonTitleKey)
        }
    }

    @objc private func downloadWhisperModel() {
        guard let request = whisperActionLifecycle.begin(.modelDownload) else { return }
        whisperModelButton.isEnabled = false
        whisperModelButton.title = loc.s("prefs.voice.whisper.downloading")

        let controller = WhisperServerController.shared
        whisperModelDownloadTask = Task { @MainActor [weak self] in
            let result = await controller.downloadModel { [weak self] fraction in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.whisperActionLifecycle.allowsProgress(request) else { return }
                    self.whisperModelButton.title = "\(Int(fraction * 100))%"
                }
            }
            guard !Task.isCancelled,
                  let self,
                  self.whisperActionLifecycle.claimCompletion(request) else { return }
            self.whisperModelDownloadTask = nil
            defer { self.onLocalizationBlockingOperationDidEnd?() }
            switch result {
            case .success:
                break
            case .failure(let failure):
                DevTypeAlert.warn(
                    title: self.loc.s("prefs.voice.whisper.modelFailed"),
                    message: failure.userMessage,
                    window: self.view.window
                )
            }
            self.refreshWhisperReadiness()
        }
    }

    @objc private func toggleWhisperServer() {
        let controller = WhisperServerController.shared
        switch WhisperServerToggleDecision.resolve(
            activeAction: whisperActionLifecycle.activeAction,
            isManagedByApp: controller.isManagedByApp
        ) {
        case .cancelPendingStart:
            cancelPendingWhisperServerStart()
            controller.stop()
            refreshWhisperReadiness()
            return
        case .ignoreWhileDownloading:
            return
        case .stopManagedServer:
            controller.stop()
            refreshWhisperReadiness()
            return
        case .startServer:
            break
        }

        guard let request = whisperActionLifecycle.begin(.serverStart) else { return }
        applyWhisperReadinessPresentation()

        whisperServerStartTask = Task { @MainActor [weak self] in
            let result = await controller.start()
            guard !Task.isCancelled,
                  let self,
                  self.whisperActionLifecycle.claimCompletion(request) else { return }
            self.whisperServerStartTask = nil
            defer { self.onLocalizationBlockingOperationDidEnd?() }
            switch result {
            case .success:
                break
            case .failure(let failure):
                DevTypeAlert.warn(
                    title: self.loc.s("prefs.voice.whisper.failed"),
                    message: failure.userMessage,
                    window: self.view.window
                )
            }
            self.refreshWhisperReadiness()
        }
    }

    private func cancelPendingWhisperServerStart() {
        whisperServerStartTask?.cancel()
        whisperServerStartTask = nil
        if whisperActionLifecycle.cancel(.serverStart) {
            onLocalizationBlockingOperationDidEnd?()
        }
    }

    func invalidateWhisperActions() {
        let hadActiveAction = whisperActionLifecycle.activeAction != nil
        whisperModelDownloadTask?.cancel()
        whisperModelDownloadTask = nil
        whisperServerStartTask?.cancel()
        whisperServerStartTask = nil
        whisperActionLifecycle.invalidate()
        if hadActiveAction {
            onLocalizationBlockingOperationDidEnd?()
        }
    }

}
