import AppKit
import ExpanderEngine

/// Coordinates audio recording, HUD transitions, transcription execution,
/// and direct real-time text injection for Smart Dictation into focused macOS fields.
///
/// Redesigned to use `DictationStateMachine` for formal state management and
/// `GeminiTranscriptionClient` as the primary transcription engine, with Apple
/// `SFSpeechRecognizer` as an offline/free fallback.
public final class VoiceDictationCoordinator: @unchecked Sendable {
    public static let shared = VoiceDictationCoordinator()

    private let lock = UnfairLock()
    private var dictationState: DictationState = .idle
    private var activeSession: DictationSession?
    private var targetApp: NSRunningApplication?
    private var lastToggleTime: DispatchTime = .now()
    private let recorder = VoiceAudioRecorder.shared
    private let transcriber = VoiceTranscriber.shared
    private let geminiClient = GeminiTranscriptionClient()
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

    // MARK: - State Machine

    private func transitionState(on event: DictationEvent) {
        lock.withLock {
            dictationState = DictationStateMachine.transition(dictationState, on: event)
        }
    }

    private var currentState: DictationState {
        lock.withLock { dictationState }
    }

    // MARK: - Toggle

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

        let state = currentState
        switch state {
        case .recording:
            stopDictation()
        case .idle, .success, .failed, .cancelled:
            startDictation(sourceApp: sourceApp)
        default:
            break
        }
    }

    // MARK: - Start Recording

    /// Starts speech recording and displays the Voice HUD.
    public func startDictation(sourceApp: NSRunningApplication? = nil) {
        let app = sourceApp ?? NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier

        // Determine engine and create session
        let engine = VoicePreferences.effectiveEngine

        // Check API key for Gemini
        if engine == .gemini && !GeminiAPIKeyStore.hasKey {
            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateState(.error(message: "Gemini API key not configured. Set it in Preferences → Voice, or switch to Apple Speech."))
            }
            return
        }

        // Check mic permission
        guard VoiceAudioRecorder.checkMicrophonePermission() else {
            VoiceAudioRecorder.requestMicrophonePermission { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.startDictation(sourceApp: sourceApp)
                } else {
                    DispatchQueue.main.async {
                        VoiceHUDPanel.shared.updateState(.error(message: "Microphone access denied in Settings"))
                    }
                }
            }
            return
        }

        // Transition to recording
        transitionState(on: .hotkeyDown)

        let session = DictationSession.begin(
            mode: .hold,
            bundleID: bundleID,
            engine: engine
        )
        lock.withLock {
            activeSession = session
            targetApp = app
        }

        do {
            try recorder.startRecording()
            self.liveInjectedText = ""

            // Start Apple Speech streaming for live partials (both engines)
            let streamingSession = transcriber.startStreamingSession(
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
            self.activeStreamingSession = streamingSession

            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateState(.listening(modelName: engine.displayName))
            }

            playHapticFeedback()
        } catch {
            transitionState(on: .error(.audio))
            lock.withLock { activeSession = nil }
            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateState(.error(message: "Audio capture failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Stop Recording & Transcribe

    /// Stops speech recording, invokes the transcription engine, and injects polished text.
    public func stopDictation() {
        let state = currentState
        guard case .recording = state else { return }

        // Transition: recording → encoding
        transitionState(on: .hotkeyUp)

        activeStreamingSession?.finishAudio()
        activeStreamingSession = nil

        let (session, appToRestore): (DictationSession?, NSRunningApplication?) = lock.withLock {
            return (activeSession, targetApp)
        }
        guard let session else { return }

        let engine = session.transcriptionEngine

        DispatchQueue.main.async {
            VoiceHUDPanel.shared.updateState(.transcribing(modelName: engine.displayName))
        }

        guard let audioURL = recorder.stopRecording() else {
            transitionState(on: .error(.noAudio))
            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateState(.error(message: "No audio captured"))
            }
            return
        }

        lock.withLock { activeSession?.audioURL = audioURL }

        switch engine {
        case .gemini:
            transcribeWithGemini(audioURL: audioURL, session: session, appToRestore: appToRestore)
        case .localLLM:
            transcribeWithLocalLLM(audioURL: audioURL, session: session, appToRestore: appToRestore)
        case .appleSpeech:
            transcribeWithAppleSpeech(audioURL: audioURL, session: session, appToRestore: appToRestore)
        }
    }

    // MARK: - Gemini Transcription Pipeline

    private func transcribeWithGemini(audioURL: URL, session: DictationSession, appToRestore: NSRunningApplication?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // 1. FLAC encode
            let flacURL = audioURL.deletingLastPathComponent().appendingPathComponent("session_\(session.id.uuidString).flac")
            let flacResult: FLACEncoder.EncodingResult
            do {
                flacResult = try FLACEncoder.encode(inputURL: audioURL, outputURL: flacURL)
                DevTypeLog.app.info("[Voice] FLAC encoded: \(flacResult.byteCount) bytes in \(Int(flacResult.encodeSeconds * 1000))ms")
            } catch {
                DevTypeLog.app.error("[Voice] FLAC encoding failed, using WAV fallback: \(error)")
                // Fall back to sending WAV directly
                self.sendToGemini(audioURL: audioURL, mimeType: "audio/wav", session: session, appToRestore: appToRestore)
                return
            }

            self.sendToGemini(audioURL: flacResult.url, mimeType: "audio/flac", session: session, appToRestore: appToRestore)

            // Clean up FLAC (derived data, WAV/journal is the persistent artifact)
            try? FileManager.default.removeItem(at: flacURL)
        }
    }

    private func sendToGemini(audioURL: URL, mimeType: String, session: DictationSession, appToRestore: NSRunningApplication?) {
        guard let apiKey = GeminiAPIKeyStore.load() else {
            transitionState(on: .error(.noAPIKey))
            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateState(.error(message: "Gemini API key not found"))
            }
            return
        }

        guard let audioData = try? Data(contentsOf: audioURL) else {
            transitionState(on: .error(.audio))
            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateState(.error(message: "Failed to read audio file"))
            }
            return
        }

        // Build steering prompt
        let vocabulary = VoicePreferences.customDictionary
        let tone = VoicePreferences.effectiveToneCategory(forBundleID: session.insertionTargetBundleID)
        let verbatim = VoicePreferences.isVerbatimModeEnabled
        let steeringPrompt = TranscriptionSteeringPrompt.build(vocabulary: vocabulary, tone: tone, verbatim: verbatim)

        let audioDuration = session.timestamps.audioDuration ?? 10.0

        // Transition: encoding → transcribing
        transitionState(on: .encodingComplete(audioURL))

        Task {
            do {
                let result = try await geminiClient.transcribe(
                    audioData: audioData,
                    mimeType: mimeType,
                    audioDurationSeconds: audioDuration,
                    steeringPrompt: steeringPrompt,
                    apiKey: apiKey
                )

                let transcribedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !transcribedText.isEmpty else {
                    self.transitionState(on: .error(.noAudio))
                    await MainActor.run {
                        VoiceHUDPanel.shared.updateState(.error(message: "No speech recognized"))
                    }
                    return
                }

                // Validation gate: never insert garbage
                let rawText = result.rawText
                if !rawText.isEmpty && rawText != transcribedText {
                    let verdict = TranscriptionValidationGate.validate(raw: rawText, cleaned: transcribedText)
                    if !verdict.accepted {
                        DevTypeLog.app.info("[Voice] ValidationGate rejected cleaned transcript: \(verdict.reason ?? "unknown"). Using raw.")
                        // Fall back to raw transcript (which Gemini already punctuates well)
                        self.handleFinalTranscript(rawText, session: session, appToRestore: appToRestore)
                        return
                    }
                }

                var mutableSession = session
                mutableSession.rawTranscript = rawText

                // Apply deterministic custom dictionary replacements as a post-step
                // (the model mostly handles this via the steering prompt, but regex-exact replacements are guaranteed here)
                let finalText = SmartDictationEngine.applyCustomDictionary(transcribedText, dictionary: VoicePreferences.customDictionary)

                self.handleFinalTranscript(finalText, session: mutableSession, appToRestore: appToRestore)

            } catch let error as GeminiTranscriptionError {
                let failure = self.mapGeminiError(error)
                self.transitionState(on: .error(failure))
                await MainActor.run {
                    VoiceHUDPanel.shared.updateState(.error(message: self.userMessage(for: failure)))
                }
            } catch {
                self.transitionState(on: .error(.network(error.localizedDescription)))
                await MainActor.run {
                    VoiceHUDPanel.shared.updateState(.error(message: error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Local LLM Transcription Pipeline

    private func transcribeWithLocalLLM(audioURL: URL, session: DictationSession, appToRestore: NSRunningApplication?) {
        transitionState(on: .encodingComplete(audioURL))

        // Step 1: Transcribe on-device using Apple Speech
        transcriber.transcribe(
            audioURL: audioURL,
            modelType: .appleSpeech,
            tone: .verbatim,
            customDictionary: [:],
            removeDisfluencies: false,
            autoPunctuate: true
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let rawTranscript):
                guard !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.handleFinalTranscript("", session: session, appToRestore: appToRestore)
                    return
                }

                // Step 2: Clean and format via Local LLM (Apple Intelligence or local Ollama / LM Studio)
                let tone = VoicePreferences.effectiveToneCategory(forBundleID: session.insertionTargetBundleID)
                let customDict = VoicePreferences.customDictionary

                Task {
                    let cleaned = await LocalLLMCleanupClient.shared.cleanup(
                        rawTranscript: rawTranscript,
                        tone: tone,
                        customDictionary: customDict
                    )

                    // Step 3: Run ValidationGate
                    let verdict = TranscriptionValidationGate.validate(raw: rawTranscript, cleaned: cleaned)
                    let textToDeliver = verdict.accepted ? cleaned : rawTranscript

                    // Step 4: Apply custom dictionary deterministic exact-matches
                    let finalText = SmartDictationEngine.applyCustomDictionary(textToDeliver, dictionary: customDict)

                    var mutableSession = session
                    mutableSession.rawTranscript = rawTranscript

                    self.handleFinalTranscript(finalText, session: mutableSession, appToRestore: appToRestore)
                }

            case .failure(let error):
                self.transitionState(on: .error(.network(error.localizedDescription)))
                DispatchQueue.main.async {
                    VoiceHUDPanel.shared.updateState(.error(message: error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Apple Speech Fallback Pipeline

    private func transcribeWithAppleSpeech(audioURL: URL, session: DictationSession, appToRestore: NSRunningApplication?) {
        // Skip encoding step for Apple Speech (it reads WAV directly)
        transitionState(on: .encodingComplete(audioURL))

        transcriber.transcribe(
            audioURL: audioURL,
            modelType: .appleSpeech,
            tone: VoicePreferences.tone,
            customDictionary: VoicePreferences.customDictionary,
            removeDisfluencies: VoicePreferences.isRemoveDisfluenciesEnabled,
            autoPunctuate: VoicePreferences.isAutoPunctuateEnabled
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let polishedText):
                self.handleFinalTranscript(polishedText, session: session, appToRestore: appToRestore)
            case .failure(let error):
                self.transitionState(on: .error(.network(error.localizedDescription)))
                DispatchQueue.main.async {
                    VoiceHUDPanel.shared.updateState(.error(message: error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Final Transcript Handling

    private func handleFinalTranscript(_ text: String, session: DictationSession, appToRestore: NSRunningApplication?) {
        transitionState(on: .transcriptReady(text))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard !text.isEmpty else {
                VoiceHUDPanel.shared.updateState(.error(message: "No speech recognized"))
                return
            }

            // Check for AI voice commands
            if let aiCommand = VoiceAITriggerParser.parse(transcript: text) {
                self.handleVoiceAICommand(aiCommand, sourceApp: appToRestore)
                return
            }

            let diffSegments: [TranscriptDiffEngine.Segment]?
            if let raw = session.rawTranscript, !raw.isEmpty, raw != text {
                diffSegments = TranscriptDiffEngine.segments(verbatim: raw, cleaned: text)
            } else {
                diffSegments = nil
            }

            VoiceHUDPanel.shared.updateState(.success(text: text, diffSegments: diffSegments))

            let currentInjected = self.liveInjectedText
            self.liveInjectedText = ""

            let diff = VoiceProgressiveTypingEngine.computeDiff(
                currentInjectedText: currentInjected,
                targetTranscript: text
            )

            if diff.eraseCount == 0 && diff.textToInject.isEmpty {
                DevTypeLog.app.info("[Voice] dictation perfectly matches live stream chars=\(text.count)")
            } else {
                self.injectText(diff.textToInject, eraseCount: diff.eraseCount, sourceApp: appToRestore)
            }

            self.transitionState(on: .insertionComplete(.inserted))
            self.lock.withLock { self.activeSession = nil }
        }
    }

    // MARK: - AI Command Handling

    @MainActor
    private func handleVoiceAICommand(_ command: VoiceAICommand, sourceApp: NSRunningApplication?) {
        let previousInjectedCount = self.liveInjectedText.count
        self.liveInjectedText = ""

        if previousInjectedCount > 0 {
            replaceLiveDraft(eraseCount: previousInjectedCount, newText: "")
        }

        // Disclaimer and compatibility check for macOS AI support
        guard AITextTransformSupport.isRunningOnCompatibleOS else {
            VoiceHUDPanel.shared.updateState(.error(message: LocalizationManager.shared.s("ai.availability.unsupportedOS")))
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
        if #available(macOS 26.0, *) {
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

        VoiceHUDPanel.shared.updateState(.error(message: LocalizationManager.shared.s("ai.availability.unsupportedOS")))
    }

    // MARK: - Cancel

    /// Cancels recording and dismisses the HUD without injecting text.
    public func cancelDictation() {
        transitionState(on: .cancel)
        activeStreamingSession?.cancel()
        activeStreamingSession = nil
        recorder.cancelRecording()

        let previousInjectedCount = self.liveInjectedText.count
        self.liveInjectedText = ""
        if previousInjectedCount > 0 {
            replaceLiveDraft(eraseCount: previousInjectedCount, newText: "")
        }

        lock.withLock { activeSession = nil }

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

    // MARK: - Error Mapping

    private func mapGeminiError(_ error: GeminiTranscriptionError) -> DictationFailure {
        switch error {
        case .noAPIKey: return .noAPIKey
        case .invalidAPIKey: return .auth
        case .modelAccessDenied: return .modelAccess
        case .rateLimited: return .rateLimited
        case .quotaExhausted: return .quotaExhausted
        case .timeout: return .timeout
        case .networkError(let msg): return .network(msg)
        case .safetyBlocked: return .safetyBlocked
        case .emptyTranscript: return .noAudio
        case .payloadTooLarge: return .network("Audio recording exceeded maximum limit (25MB)")
        case .invalidResponse(let msg): return .network(msg)
        }
    }

    private func userMessage(for failure: DictationFailure) -> String {
        switch failure {
        case .audio: return "Audio engine failed"
        case .noMicrophone: return "No microphone found"
        case .noAudio: return "No speech detected"
        case .network(let msg): return "Network error: \(msg)"
        case .auth: return "Invalid API key. Check Preferences → Voice."
        case .modelAccess: return "Model access denied. Check API key permissions."
        case .rateLimited: return "Rate limited — try again in a moment"
        case .quotaExhausted: return "API quota exhausted for today"
        case .timeout: return "Transcription timed out"
        case .validation: return "Transcription validation failed"
        case .safetyBlocked: return "Content blocked by safety filter"
        case .noAPIKey: return "Gemini API key not configured"
        }
    }

    private func playHapticFeedback() {
        if VoicePreferences.isSoundFeedbackEnabled {
            NSSound.beep()
        }
    }
}
