import AppKit
import ExpanderEngine

/// Coordinates audio recording, HUD transitions, transcription execution,
/// and direct real-time text injection for Smart Dictation into focused macOS fields.
public final class VoiceDictationCoordinator: @unchecked Sendable {
    public static let shared = VoiceDictationCoordinator()

    private let lock = UnfairLock()
    private var isRecording = false
    private var targetApp: NSRunningApplication?
    private var lastToggleTime: DispatchTime = .now()
    private let recorder = VoiceAudioRecorder.shared
    private let transcriber = VoiceTranscriber.shared
    private var activeStreamingSession: StreamingSpeechSession?
    private var liveInjectedText: String = ""

    private init() {
        // Wire live audio meter levels to HUD
        recorder.onAudioLevelUpdate = { level in
            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateAudioLevel(level)
            }
        }

        // Wire live PCM buffers to active streaming speech session
        recorder.onAudioBuffer = { [weak self] buffer in
            self?.activeStreamingSession?.appendAudioBuffer(buffer)
        }
    }

    /// Toggles smart dictation (starts if stopped, stops and transcribes if recording).
    public func toggleDictation(sourceApp: NSRunningApplication? = nil) {
        let shouldProceed: Bool = lock.withLock {
            let now = DispatchTime.now()
            let diff = now.uptimeNanoseconds - lastToggleTime.uptimeNanoseconds
            if diff < 150_000_000 { // 150ms debounce
                return false
            }
            lastToggleTime = now
            return true
        }
        guard shouldProceed else { return }

        let recording: Bool = lock.withLock { isRecording }
        if recording {
            stopDictation()
        } else {
            startDictation(sourceApp: sourceApp)
        }
    }

    /// Starts speech recording and displays the Crimson Liquid Glass HUD.
    public func startDictation(sourceApp: NSRunningApplication? = nil) {
        let alreadyRecording: Bool = lock.withLock {
            if isRecording { return true }
            isRecording = true
            targetApp = sourceApp ?? NSWorkspace.shared.frontmostApplication
            return false
        }
        guard !alreadyRecording else { return }

        // Check mic permission
        guard VoiceAudioRecorder.checkMicrophonePermission() else {
            VoiceAudioRecorder.requestMicrophonePermission { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.lock.withLock { self.isRecording = false }
                    self.startDictation(sourceApp: sourceApp)
                } else {
                    self.lock.withLock { self.isRecording = false }
                    DispatchQueue.main.async {
                        VoiceHUDPanel.shared.updateState(.error(message: "Microphone access denied in Settings"))
                    }
                }
            }
            return
        }

        do {
            try recorder.startRecording()
            self.liveInjectedText = ""

            let modelType = VoicePreferences.selectedModel
            let modelName = modelType.descriptor.shortName

            let session = transcriber.startStreamingSession(
                locale: Locale.current,
                onPartial: { [weak self] partial in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        VoiceHUDPanel.shared.updateStreamingTranscript(partial)
                        if VoicePreferences.isRealTimeTypingEnabled {
                            self.handleRealTimeTyping(partial: partial)
                        }
                    }
                },
                onFinal: { _ in }
            )
            self.activeStreamingSession = session

            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateState(.listening(modelName: modelName))
            }

            playHapticFeedback()
        } catch {
            lock.withLock { isRecording = false }
            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateState(.error(message: "Audio capture failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Stops speech recording, invokes the transcription model, and injects polished text.
    public func stopDictation() {
        let (wasRecording, appToRestore): (Bool, NSRunningApplication?) = lock.withLock {
            let state = isRecording
            isRecording = false
            return (state, targetApp)
        }
        guard wasRecording else { return }

        activeStreamingSession?.finishAudio()
        activeStreamingSession = nil

        let modelType = VoicePreferences.selectedModel
        let modelName = modelType.descriptor.shortName

        DispatchQueue.main.async {
            VoiceHUDPanel.shared.updateState(.transcribing(modelName: modelName))
        }

        guard let audioURL = recorder.stopRecording() else {
            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateState(.error(message: "No audio captured"))
            }
            return
        }

        transcriber.transcribe(
            audioURL: audioURL,
            modelType: modelType,
            tone: VoicePreferences.tone,
            customDictionary: VoicePreferences.customDictionary,
            removeDisfluencies: VoicePreferences.isRemoveDisfluenciesEnabled,
            autoPunctuate: VoicePreferences.isAutoPunctuateEnabled
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let polishedText):
                    guard !polishedText.isEmpty else {
                        VoiceHUDPanel.shared.updateState(.error(message: "No speech recognized"))
                        return
                    }

                    if let aiCommand = VoiceAITriggerParser.parse(transcript: polishedText) {
                        self.handleVoiceAICommand(aiCommand, sourceApp: appToRestore)
                    } else {
                        VoiceHUDPanel.shared.updateState(.success(text: polishedText))
                        let currentInjected = self.liveInjectedText
                        self.liveInjectedText = ""

                        let diff = VoiceProgressiveTypingEngine.computeDiff(
                            currentInjectedText: currentInjected,
                            targetTranscript: polishedText
                        )

                        if diff.eraseCount == 0 && diff.textToInject.isEmpty {
                            // Polished text exactly matches live stream on screen — zero flicker / no-op
                            DevTypeLog.app.info("[Voice] dictation perfectly matches live stream chars=\(polishedText.count)")
                        } else {
                            self.injectText(diff.textToInject, eraseCount: diff.eraseCount, sourceApp: appToRestore)
                        }
                    }

                case .failure(let error):
                    VoiceHUDPanel.shared.updateState(.error(message: error.localizedDescription))
                }
            }
        }
    }

    @MainActor
    private func handleVoiceAICommand(_ command: VoiceAICommand, sourceApp: NSRunningApplication?) {
        let previousInjectedCount = self.liveInjectedText.count
        self.liveInjectedText = ""

        if previousInjectedCount > 0 {
            replaceLiveDraft(eraseCount: previousInjectedCount, newText: "")
        }

        // Disclaimer and compatibility check for macOS 27
        guard AITextTransformSupport.isRunningOnCompatibleOS else {
            VoiceHUDPanel.shared.updateState(.error(message: "AI tools require macOS 27 (tested on macOS 26: unsupported)"))
            return
        }

        var textToTransform = command.payloadText
        if command.requiresSelectionFallback || textToTransform.isEmpty {
            switch SelectionReader.readSelectionForExplicitAIAction() {
            case .selection(let resolved):
                textToTransform = resolved.text
            case .failure(let failure):
                VoiceHUDPanel.shared.updateState(.error(message: failure.message(loc: .shared)))
                return
            }
        }

        guard !textToTransform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            VoiceHUDPanel.shared.updateState(.error(message: "No text provided for \(command.triggerPhrase)"))
            return
        }

        VoiceHUDPanel.shared.updateState(.transcribing(modelName: "AI (\(command.kind.rawValue))"))

        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            _ = AITextTransformer.shared.transform(
                kind: command.kind,
                input: textToTransform,
                completionQueue: .main
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let output):
                        guard !output.isEmpty else {
                            VoiceHUDPanel.shared.updateState(.error(message: "AI produced empty output"))
                            return
                        }
                        VoiceHUDPanel.shared.updateState(.success(text: output))
                        self.injectText(output, eraseCount: 0, sourceApp: sourceApp)

                    case .failure(let error):
                        VoiceHUDPanel.shared.updateState(.error(message: "AI failed: \(error.localizedDescription)"))
                    }
                }
            }
            return
        }
        #endif

        VoiceHUDPanel.shared.updateState(.error(message: "AI Foundation Models require macOS 27"))
    }

    /// Cancels recording and dismisses the HUD without injecting text.
    public func cancelDictation() {
        lock.withLock { isRecording = false }
        activeStreamingSession?.cancel()
        activeStreamingSession = nil
        recorder.cancelRecording()

        let previousInjectedCount = self.liveInjectedText.count
        self.liveInjectedText = ""
        if previousInjectedCount > 0 {
            replaceLiveDraft(eraseCount: previousInjectedCount, newText: "")
        }

        DispatchQueue.main.async {
            VoiceHUDPanel.shared.hide()
        }
    }

    // MARK: - Real-Time Live Progressive Typing

    private func handleRealTimeTyping(partial: String) {
        guard !partial.isEmpty else { return }
        let diff = VoiceProgressiveTypingEngine.computeDiff(
            currentInjectedText: liveInjectedText,
            targetTranscript: partial
        )
        guard diff.eraseCount > 0 || !diff.textToInject.isEmpty else { return }

        liveInjectedText = diff.resultingText

        if diff.eraseCount == 0 {
            injectProgressiveChunk(diff.textToInject)
        } else {
            replaceLiveDraft(eraseCount: diff.eraseCount, newText: diff.textToInject)
        }
    }

    private func injectProgressiveChunk(_ text: String) {
        guard !text.isEmpty else { return }
        let snippet = SnippetModel(
            title: "Voice Live Dictation",
            triggerKeyword: "",
            replacementText: text
        )
        TextInjectionPipeline.shared.inject(
            snippet: snippet,
            triggerLength: 0,
            swallowedFinalKey: false,
            eraseCountOverride: 0,
            preResolvedText: text,
            secureClipboardPaste: false
        )
    }

    private func replaceLiveDraft(eraseCount: Int, newText: String) {
        let snippet = SnippetModel(
            title: "Voice Live Dictation",
            triggerKeyword: "",
            replacementText: newText
        )
        TextInjectionPipeline.shared.inject(
            snippet: snippet,
            triggerLength: 0,
            swallowedFinalKey: false,
            eraseCountOverride: eraseCount,
            preResolvedText: newText,
            secureClipboardPaste: false
        )
    }

    // MARK: - Text Injection

    private func injectText(_ text: String, eraseCount: Int, sourceApp: NSRunningApplication?) {
        // Re-activate target app before injection
        sourceApp?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let snippet = SnippetModel(
                title: "Voice Dictation",
                triggerKeyword: "",
                replacementText: text
            )

            TextInjectionPipeline.shared.inject(
                snippet: snippet,
                triggerLength: 0,
                swallowedFinalKey: false,
                eraseCountOverride: eraseCount,
                preResolvedText: text,
                secureClipboardPaste: false
            ) {
                DevTypeLog.app.info("[Voice] dictation injected chars=\(text.count)")
            }
        }
    }

    private func playHapticFeedback() {
        if VoicePreferences.isSoundFeedbackEnabled {
            NSSound.beep()
        }
    }
}
