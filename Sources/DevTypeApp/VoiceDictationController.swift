import AppKit
import ExpanderEngine

/// App-layer glue for voice dictation.
///
/// All session logic lives in `VoiceSessionCoordinator` (engine side): the reducer owns
/// state, `LiveSpeechStream` produces live segments, `VoiceInsertionService` owns what has
/// been typed. This type does only what needs AppKit — resolve the target application,
/// check microphone permission, drive the hotkey, and map session phases onto the HUD.
public final class VoiceDictationController: @unchecked Sendable {
    public static let shared = VoiceDictationController()

    private let lock = UnfairLock()
    private var lastToggleTime: DispatchTime = .now()
    private var isSessionActive = false
    private var generationCounter: UInt64 = 0
    private var currentModelName: String = ""
    private var didWireCallbacks = false

    private init() {}

    // MARK: - Launch

    /// Housekeeping for the on-disk session store, run once at launch off the main thread.
    ///
    /// Two jobs. **Prune**: every dictation writes a directory containing its audio, so
    /// without a retention policy the store grows without bound. **Recover**: a session that
    /// produced text but never delivered it (the app was killed, or the target app quit
    /// mid-insert) is the only copy of something the user said — it is recorded in the
    /// activity history so it can still be retrieved rather than silently discarded.
    public func performLaunchRecovery() {
        DispatchQueue.global(qos: .utility).async {
            let service = VoiceRecoveryService.shared

            let pending = service.recoverableUndelivered()
            for session in pending.prefix(5) {
                let text = VoiceRecoveryService.recoveredText(session)
                guard !text.isEmpty else { continue }
                ActivityHistoryStore.shared.record(
                    category: .voice,
                    title: "Recovered dictation",
                    details: text,
                    timestamp: session.snapshot.createdAt
                )
                service.discard(session)
            }

            let removed = service.prune()
            if removed > 0 || !pending.isEmpty {
                DevTypeLog.app.info(
                    "[Voice] launch recovery: recovered=\(pending.count) pruned=\(removed)"
                )
            }
        }
    }

    // MARK: - Entry points

    /// Starts dictation, or stops it if a session is already running.
    public func toggleDictation(sourceApp: NSRunningApplication? = nil) {
        let shouldProceed: Bool = lock.withLock {
            let now = DispatchTime.now()
            if now.uptimeNanoseconds - lastToggleTime.uptimeNanoseconds < 150_000_000 {
                return false // 150ms debounce against hotkey chatter
            }
            lastToggleTime = now
            return true
        }
        guard shouldProceed else { return }

        if lock.withLock({ isSessionActive }) {
            stopDictation()
        } else {
            startDictation(sourceApp: sourceApp)
        }
    }

    /// Ends capture and lets recognition, correction and delivery run.
    public func stopDictation() {
        lock.withLock { isSessionActive = false }
        Task { await VoiceSessionCoordinator.shared.stopSession() }
    }

    /// Abandons the session and erases anything progressive typing already inserted.
    public func cancelDictation() {
        lock.withLock { isSessionActive = false }
        Task {
            await VoiceSessionCoordinator.shared.cancelSession()
            await MainActor.run { VoiceHUDPanel.shared.hide() }
        }
    }

    // MARK: - Start

    private func startDictation(sourceApp: NSRunningApplication?) {
        let app = sourceApp ?? NSWorkspace.shared.frontmostApplication
        let engine = VoicePreferences.effectiveEngine

        // Fail before recording rather than after, so the user is not left speaking into
        // a session that cannot possibly produce a transcript.
        if engine == .gemini && !GeminiAPIKeyStore.hasKey {
            showError("Gemini API key not configured. Set it in Preferences → Voice, or switch to Apple Speech.")
            return
        }

        guard DurableVoiceCapture.checkMicrophonePermission() else {
            Task {
                let granted = await DurableVoiceCapture.requestMicrophonePermission()
                if granted {
                    self.startDictation(sourceApp: sourceApp)
                } else {
                    self.showError("Microphone access denied in Settings")
                }
            }
            return
        }

        // Speech recognition is a separate grant from the microphone. Asked here, where the
        // user has just asked to dictate — never from a readiness check, which would prompt
        // out of nowhere while they were only looking at Preferences.
        switch SpeechAuthorization.status() {
        case .authorized:
            break
        case .notDetermined:
            Task {
                if await SpeechAuthorization.request() == .authorized {
                    self.startDictation(sourceApp: sourceApp)
                } else {
                    self.showError("Speech recognition access denied in Settings")
                }
            }
            return
        case .unavailable:
            showError("Speech recognition access denied in Settings")
            return
        }

        let generation = lock.withLock { () -> SessionGeneration in
            generationCounter += 1
            isSessionActive = true
            currentModelName = engine.displayName
            return SessionGeneration(rawValue: generationCounter)
        }

        let snapshot = VoiceSessionSnapshotFactory.make(
            bundleIdentifier: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier ?? 0,
            generation: generation
        )

        Task {
            await self.wireCallbacksIfNeeded()
            do {
                // Every entry point (hotkey, menu, palette) is a toggle: press to start,
                // press again to stop. `HotkeyManager` has no key-up path, so there is no
                // hold-to-talk gesture to record. Adding one means key-up plumbing in the
                // event tap; until then, claiming `.hold` here would just be untrue.
                try await VoiceSessionCoordinator.shared.startSession(snapshot: snapshot, mode: .handsFree)
                if VoicePreferences.isSoundFeedbackEnabled {
                    await MainActor.run { NSSound.beep() }
                }
            } catch {
                self.lock.withLock { self.isSessionActive = false }
                self.showError("Audio capture failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Session callbacks

    /// Installs the phase, segment and audio-level handlers exactly once. They are
    /// long-lived and session-independent — each callback reads the current session.
    private func wireCallbacksIfNeeded() async {
        let needsWiring = lock.withLock { () -> Bool in
            if didWireCallbacks { return false }
            didWireCallbacks = true
            return true
        }
        guard needsWiring else { return }

        await VoiceSessionCoordinator.shared.setOnPhaseChange { [weak self] phase in
            self?.handlePhase(phase)
        }
        await VoiceSessionCoordinator.shared.setOnAudioLevel { level in
            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateAudioLevel(level)
            }
        }
        await VoiceSessionCoordinator.shared.setOnDeliveryIntercept { transcript in
            await VoiceDictationController.shared.interceptVoiceCommand(transcript)
        }
        await VoiceSessionCoordinator.shared.setOnLiveSegment { segment in
            // The delivery layer already typed this; the HUD shows the running transcript.
            DispatchQueue.main.async {
                let transcript = VoiceInsertionService.shared.ownedText
                if !transcript.isEmpty {
                    VoiceHUDPanel.shared.updateStreamingTranscript(transcript)
                }
                _ = segment
            }
        }
    }

    private func handlePhase(_ phase: SessionPhase) {
        let modelName = lock.withLock { currentModelName }

        DispatchQueue.main.async {
            switch phase {
            case .preparing, .capturing:
                VoiceHUDPanel.shared.updateState(.listening(modelName: modelName))

            case .finalizingAudio, .recognizing, .validatingRaw, .correcting, .validatingCorrection:
                VoiceHUDPanel.shared.updateState(.transcribing(modelName: modelName))

            case .readyForDelivery, .delivering:
                break

            case .completed(let outcome):
                self.lock.withLock { self.isSessionActive = false }
                switch outcome {
                case .inserted:
                    let text = VoiceInsertionService.shared.ownedText
                    if text.isEmpty {
                        VoiceHUDPanel.shared.updateState(.error(message: "No speech recognized"))
                    } else {
                        VoiceHUDPanel.shared.updateState(.success(text: text))
                        self.showCorrectionDiff(for: text)
                    }
                case .savedButNotInserted(let reason):
                    VoiceHUDPanel.shared.updateState(.error(message: reason))
                case .copiedToClipboard(let count):
                    VoiceHUDPanel.shared.updateState(.success(text: "Copied \(count) characters"))
                case .voiceCommandExecuted(let command):
                    VoiceHUDPanel.shared.updateState(.success(text: command))
                }

            case .failed(let failure):
                self.lock.withLock { self.isSessionActive = false }
                VoiceHUDPanel.shared.updateState(.error(message: Self.message(for: failure)))

            case .cancelled:
                self.lock.withLock { self.isSessionActive = false }
                VoiceHUDPanel.shared.hide()

            case .recoverable:
                break
            }
        }
    }

    /// Shows which words cleanup removed, so a bad correction is visible rather than
    /// silent. Fetched after the success state is already on screen: the diff is a
    /// refinement, and waiting on the actor for it would delay the result the user cares
    /// about.
    private func showCorrectionDiff(for finalText: String) {
        Task {
            guard let transcripts = await VoiceSessionCoordinator.shared.transcripts() else { return }
            let raw = transcripts.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, raw != finalText else { return }

            let segments = TranscriptDiffEngine.segments(verbatim: raw, cleaned: finalText)
            guard segments.contains(where: { $0.isCut }) else { return }

            await MainActor.run {
                VoiceHUDPanel.shared.updateState(.success(text: finalText, diffSegments: segments))
            }
        }
    }

    // MARK: - Spoken AI commands

    /// Claims the transcript when it opens with an AI trigger phrase ("rewrite this",
    /// "summarise this", …). Returns `true` when the command was handled, so the session
    /// completes without typing the transcript verbatim.
    fileprivate func interceptVoiceCommand(_ transcript: String) async -> Bool {
        guard let command = VoiceAITriggerParser.parse(transcript: transcript) else {
            return false
        }

        return await MainActor.run {
            // Anything progressive typing already inserted was the spoken command, not
            // content the user wants kept.
            VoiceInsertionService.shared.rollback()

            guard AITextTransformSupport.isRunningOnCompatibleOS else {
                VoiceHUDPanel.shared.updateState(
                    .error(message: LocalizationManager.shared.s("ai.availability.unsupportedOS"))
                )
                return true
            }

            var input = command.payloadText
            if command.requiresSelectionFallback || input.isEmpty {
                switch SelectionReader.readSelectionForExplicitAIAction() {
                case .selection(let resolved):
                    input = resolved.text
                case .failure(let failure):
                    VoiceHUDPanel.shared.updateState(.error(message: failure.message(loc: .shared)))
                    return true
                }
            }

            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                VoiceHUDPanel.shared.updateState(
                    .error(message: "No text provided for \(command.triggerPhrase)")
                )
                return true
            }

            self.runAITransform(command, input: input)
            return true
        }
    }

    @MainActor
    private func runAITransform(_ command: VoiceAICommand, input: String) {
        VoiceHUDPanel.shared.updateState(.transcribing(modelName: "AI (\(command.kind.rawValue))"))

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            _ = AITextTransformer.shared.transform(
                kind: command.kind,
                input: input,
                completionQueue: .main
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let output) where !output.isEmpty:
                        VoiceHUDPanel.shared.updateState(.success(text: output))
                        let snippet = SnippetModel(
                            title: "Voice AI",
                            triggerKeyword: "",
                            replacementText: output
                        )
                        TextInjectionPipeline.shared.inject(
                            snippet: snippet,
                            triggerLength: 0,
                            swallowedFinalKey: false,
                            eraseCountOverride: 0,
                            preResolvedText: output,
                            secureClipboardPaste: false
                        )
                    case .success:
                        VoiceHUDPanel.shared.updateState(.error(message: "AI produced empty output"))
                    case .failure(let error):
                        VoiceHUDPanel.shared.updateState(
                            .error(message: "AI failed: \(error.localizedDescription)")
                        )
                    }
                }
            }
            return
        }
        #endif

        VoiceHUDPanel.shared.updateState(
            .error(message: LocalizationManager.shared.s("ai.availability.unsupportedOS"))
        )
    }

    // MARK: - Messaging

    private func showError(_ message: String) {
        DispatchQueue.main.async {
            VoiceHUDPanel.shared.updateState(.error(message: message))
        }
    }

    /// Maps a structured failure to something the user can act on. The failure already
    /// carries a `userAction`, so the message names the fix rather than the fault.
    static func message(for failure: VoiceFailure) -> String {
        switch failure.code {
        case .noMicrophone: return "No microphone found"
        case .microphonePermissionDenied: return "Microphone access denied in Settings"
        case .accessibilityPermissionDenied: return "Accessibility access needed to insert text"
        case .zeroFramesCaptured, .speechNoSpeech: return "No speech detected"
        case .captureBackpressure, .deviceChangeInterrupted: return "Audio input was interrupted"
        case .diskFull: return "Not enough disk space to record"
        case .audioEncodingFailed: return "Could not encode the recording"
        case .missingAPIKey: return "API key not configured. Check Preferences → Voice."
        case .authFailed: return "Invalid API key. Check Preferences → Voice."
        case .endpointUnreachable: return "Could not reach the transcription service"
        case .modelNotFound, .modelLoadFailed: return "Model unavailable — check Preferences → Voice"
        case .modelDigestMismatch: return "Model failed its integrity check and was not used"
        case .rateLimited: return "Rate limited — try again in a moment"
        case .quotaExhausted: return "API quota exhausted"
        case .requestTimeout, .correctionTimeout: return "Transcription timed out"
        case .speechCoverageGap, .speechRepeatedLoop, .speechProtocolViolation:
            return "Transcription failed validation"
        case .correctionRefusal, .correctionHallucination,
             .correctionProtectedSpanAltered, .correctionUnsupportedEdit:
            return "Cleanup was rejected — inserted the raw transcript"
        case .targetLeaseExpired, .targetAppTerminated: return "The target app changed before insertion"
        case .secureInputActive: return "Secure input is active — text cannot be inserted here"
        case .manifestWriteFailed: return "Could not save the session"
        case .staleGeneration: return "Session superseded"
        }
    }
}
