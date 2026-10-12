import AppKit
import ExpanderEngine

// MARK: - Voice & Smart Dictation

/// Permissions, transcription engines and their providers, dictation options and diagnostics,
/// the voice shortcut, and the custom dictionary and voice triggers.
///
/// The controls and the state of every asynchronous provider operation live here. Each card's
/// builder, actions and helpers live beside it in `VoicePreferences+<Card>.swift`, which is why
/// these members are internal rather than private.
final class VoicePreferencesViewController: PreferencesPaneViewController, NSTextFieldDelegate {

    weak var hotkeyManager: HotkeyManager?

    let voiceModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let voiceEngines = TranscriptionEngine.allCases
    let voiceTonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let voiceLiveDeliveryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let voiceTracingSwitch = NSSwitch()
    let voiceTraceStatusLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(10.5),
        color: DevTypeTheme.textTertiary,
        wrapping: true
    )
    let voiceProofreadSwitch = NSSwitch()
    let appleSpeechAssetButton = NSButton()
    weak var appleSpeechAssetRow: NSView?
    let whisperServerButton = NSButton()
    let whisperModelButton = NSButton()
    let voiceAutoPunctuateSwitch = NSSwitch()
    let voiceDisfluenciesSwitch = NSSwitch()
    let voiceSoundFeedbackSwitch = NSSwitch()
    var voiceShortcutRecorder: ShortcutRecorderView?
    let voiceDictionaryTable = NSTableView()
    let voiceDictionaryEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    let voiceDictSpokenField = NSTextField()
    let voiceDictReplacementField = NSTextField()
    var voiceDictEntries: [(spoken: String, replacement: String)] = []
    let voiceTriggersTable = NSTableView()
    let voiceTriggersEmptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary
    )
    let voiceTriggerPhraseField = NSTextField()
    let voiceTriggerActionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var voiceTriggerEntries: [(phrase: String, action: String)] = []
    var voiceMicPermissionPill: PillBadgeView?
    var voiceSpeechPermissionPill: PillBadgeView?
    var voiceEngineStatusLabels: [TranscriptionEngine: NSTextField] = [:]
    var appleSpeechReadiness: ProviderReadiness?
    var appleSpeechAnalyzerReadiness: ProviderReadiness?
    var resolvedAppleSpeechProviderID: String?
    var localAICorrectionProviderID: String?
    var appleSpeechReadinessRefresh = AppleSpeechReadinessRefreshLifecycle()
    var appleSpeechReadinessTask: Task<Void, Never>?
    var appleSpeechAssetInstallLifecycle = AppleSpeechAssetInstallLifecycle()
    var appleSpeechAssetInstallTask: Task<Void, Never>?
    var whisperReadinessState: WhisperServerSetup.State?
    var whisperModelStatus: WhisperModelStatus?
    var whisperReadinessRefresh = EndpointBoundRefreshLifecycle()
    var whisperReadinessTask: Task<Void, Never>?
    var whisperActionLifecycle = WhisperActionLifecycle()
    var whisperModelDownloadTask: Task<Void, Never>?
    var whisperServerStartTask: Task<Void, Never>?
    let onLocalizationBlockingOperationDidEnd: (() -> Void)?

    // Voice Engine & API Settings
    let geminiAPIKeyField = NSSecureTextField()
    let geminiCloudConsentSwitch = NSSwitch()
    var geminiKeyStatusPill: PillBadgeView?
    var geminiKeySaveButton: CapsuleButton?
    var geminiKeyDeleteButton: CapsuleButton?
    var geminiKeyValidationLifecycle = GeminiKeyValidationLifecycle()
    var geminiKeyValidationTask: Task<Void, Never>?
    let geminiConfigContainer = NSStackView()
    let localLLMEndpointField = NSTextField()
    let localLLMModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let localLLMModelField = NSTextField()
    var localLLMScanButton: CapsuleButton?
    var localLLMStatusPill: PillBadgeView?
    let localLLMConfigContainer = NSStackView()
    var localModelScanRefresh = EndpointBoundRefreshLifecycle()
    var localModelScanTask: Task<Void, Never>?

    init(onLocalizationBlockingOperationDidEnd: (() -> Void)?) {
        self.onLocalizationBlockingOperationDidEnd = onLocalizationBlockingOperationDidEnd
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        appleSpeechReadinessTask?.cancel()
        appleSpeechAssetInstallTask?.cancel()
        whisperReadinessTask?.cancel()
        whisperModelDownloadTask?.cancel()
        whisperServerStartTask?.cancel()
        localModelScanTask?.cancel()
        geminiKeyValidationTask?.cancel()
    }

    /// Cancels every provider operation this pane owns. The host calls it as the window goes
    /// away; every step is idempotent, and only an operation that was live reports its end.
    func retireLiveOperations() {
        appleSpeechReadinessTask?.cancel()
        appleSpeechReadinessTask = nil
        appleSpeechReadinessRefresh.invalidate()
        invalidateAppleSpeechAssetInstall()
        invalidateGeminiKeyValidation(resetPresentation: false)
        invalidateLocalModelScan(resetPresentation: true)
        whisperReadinessTask?.cancel()
        whisperReadinessTask = nil
        whisperReadinessRefresh.invalidate()
        whisperModelStatus = nil
        invalidateWhisperActions()
    }

    var blocksLocalizationReplacement: Bool {
        geminiKeyValidationLifecycle.isActive
            || appleSpeechAssetInstallLifecycle.isActive
            || whisperActionLifecycle.activeAction != nil
    }

    override func build(into stack: NSStackView) {
        let permCard = makeVoicePermissionCard()
        let modelsCard = makeVoiceModelsCard()
        let optionsCard = makeVoiceOptionsCard()
        let hotkeyCard = makeVoiceHotkeyCard()
        let dictCard = makeVoiceDictionaryCard()
        let triggersCard = makeVoiceTriggersCard()

        for card in [permCard, modelsCard, optionsCard, hotkeyCard, dictCard, triggersCard] {
            stack.addArrangedSubview(card)
        }
        pinWidth(of: [permCard, modelsCard, optionsCard, hotkeyCard, dictCard, triggersCard], to: stack)
    }

    override func reload() {
        guard isViewLoaded else { return }

        let micStatus = DurableVoiceCapture.microphonePermissionStatus()
        let micPresentation = voicePermissionPresentation(for: micStatus)
        voiceMicPermissionPill?.update(
            text: micPresentation.text,
            tint: micPresentation.color
        )

        let speechAuthorization = SpeechAuthorization.status()
        let speechPresentation = voicePermissionPresentation(for: speechAuthorization)
        voiceSpeechPermissionPill?.update(
            text: speechPresentation.text,
            tint: speechPresentation.color
        )

        let currentEngine = VoicePreferences.transcriptionEngine
        if let index = TranscriptionEngine.allCases.firstIndex(of: currentEngine) {
            voiceModelPopup.selectItem(at: index)
        }

        // One keychain read per reload, shared by the credential pill and the engine rows.
        let geminiState = GeminiAPIKeyStore.readState()
        refreshGeminiCredentialPresentation(state: geminiState)
        geminiCloudConsentSwitch.state = VoicePreferences.hasCloudAudioConsent ? .on : .off

        // A previous capability result may be stale after a locale/TCC/system-resource change.
        // Show Checking until this refresh's probe earns Ready again.
        appleSpeechReadiness = nil
        localAICorrectionProviderID = nil
        whisperReadinessState = nil
        whisperModelStatus = nil
        for engine in voiceEngines {
            let presentation = voiceEngineStatus(
                for: engine,
                speechAuthorization: speechAuthorization,
                geminiState: geminiState
            )
            voiceEngineStatusLabels[engine]?.stringValue = presentation.text
            voiceEngineStatusLabels[engine]?.textColor = presentation.color
            voiceEngineStatusLabels[engine]?.toolTip = presentation.detail
            voiceEngineStatusLabels[engine]?.setAccessibilityLabel(presentation.text)
        }
        refreshAppleSpeechReadiness()
        refreshWhisperReadiness()

        geminiConfigContainer.isHidden = currentEngine != .gemini
        localLLMConfigContainer.isHidden = currentEngine != .localLLM

        if localLLMEndpointField.stringValue.isEmpty {
            localLLMEndpointField.stringValue = VoicePreferences.localLLMEndpoint.absoluteString
        }
        refreshLocalLLMModelsPopup()

        let currentTone = VoicePreferences.tone
        if let index = DictationTone.allCases.firstIndex(of: currentTone) {
            voiceTonePopup.selectItem(at: index)
        }

        if let index = VoicePreferences.LiveDeliveryMode.allCases
            .firstIndex(of: VoicePreferences.liveDeliveryMode) {
            voiceLiveDeliveryPopup.selectItem(at: index)
        }
        let traceRecorder = VoiceDiagnosticsRecorder.shared
        voiceTracingSwitch.state = traceRecorder.isEnabled ? .on : .off
        let traceHealth = traceRecorder.ioHealth
        if case .failed = traceHealth.terminalDelete {
            updateVoiceTraceStatus(
                "prefs.voice.terminalDiagnostics.status.deleteFailed",
                warning: true
            )
        } else if case .failed = traceHealth.delete {
            updateVoiceTraceStatus("prefs.voice.tracing.status.deleteFailed", warning: true)
        } else if traceRecorder.isEnabled, case .failed = traceHealth.write {
            updateVoiceTraceStatus("prefs.voice.tracing.status.incomplete", warning: true)
        } else {
            updateVoiceTraceStatus(
                traceRecorder.isEnabled
                    ? "prefs.voice.tracing.status.on"
                    : "prefs.voice.tracing.status.off",
                warning: false
            )
        }
        voiceProofreadSwitch.state = VoicePreferences.isProofreadBeforeInsertEnabled ? .on : .off
        voiceAutoPunctuateSwitch.state = VoicePreferences.isAutoPunctuateEnabled ? .on : .off
        voiceDisfluenciesSwitch.state = VoicePreferences.isRemoveDisfluenciesEnabled ? .on : .off
        voiceSoundFeedbackSwitch.state = VoicePreferences.isSoundFeedbackEnabled ? .on : .off

        voiceShortcutRecorder?.setShortcut(HotkeyPreferences.voiceShortcut)

        let dict = VoicePreferences.customDictionary
        voiceDictEntries = dict.map { (spoken: $0.key, replacement: $0.value) }.sorted { $0.spoken < $1.spoken }
        voiceDictionaryTable.reloadData()
        voiceDictionaryEmptyLabel.stringValue = voiceDictEntries.isEmpty ? loc.s("prefs.voice.dict.empty") : ""
        voiceDictionaryEmptyLabel.isHidden = !voiceDictEntries.isEmpty
        refreshRemovalButton(for: voiceDictionaryTable)

        let triggers = VoicePreferences.customVoiceTriggers
        voiceTriggerEntries = triggers.map { (phrase: $0.key, action: $0.value) }.sorted { $0.phrase < $1.phrase }
        voiceTriggersTable.reloadData()
        voiceTriggersEmptyLabel.stringValue = voiceTriggerEntries.isEmpty ? loc.s("prefs.voice.triggers.empty") : ""
        voiceTriggersEmptyLabel.isHidden = !voiceTriggerEntries.isEmpty
        refreshRemovalButton(for: voiceTriggersTable)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === geminiAPIKeyField {
            // Editing the submitted draft is a newer user action. Cancellation is advisory; the
            // generation gate is what prevents the old response from saving or repainting later.
            invalidateGeminiKeyValidation(resetPresentation: true)
        } else if field === localLLMEndpointField {
            invalidateLocalModelScan(resetPresentation: true)
        }
    }

    // MARK: Dictionary and trigger lists

    override func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === voiceDictionaryTable { return voiceDictEntries.count }
        if tableView === voiceTriggersTable { return voiceTriggerEntries.count }
        return 0
    }

    override func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === voiceDictionaryTable {
            guard voiceDictEntries.indices.contains(row) else { return nil }
            let entry = voiceDictEntries[row]
            switch tableColumn?.identifier.rawValue {
            case "voiceDictSpoken": text = entry.spoken
            case "voiceDictReplacement": text = entry.replacement
            default: return nil
            }
        } else if tableView === voiceTriggersTable {
            guard voiceTriggerEntries.indices.contains(row) else { return nil }
            let entry = voiceTriggerEntries[row]
            switch tableColumn?.identifier.rawValue {
            case "voiceTriggerPhrase": text = entry.phrase
            case "voiceTriggerAction": text = loc.s("ai.kind.\(entry.action)")
            default: return nil
            }
        } else {
            return nil
        }
        return makeRowLabel(in: tableView, column: tableColumn, text: text, font: DevTypeTheme.font(11))
    }
}
