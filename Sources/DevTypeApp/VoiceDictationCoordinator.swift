import AppKit
import ExpanderEngine

/// Coordinates audio recording, HUD transitions, transcription execution,
/// and direct text injection for Smart Dictation into focused macOS fields.
public final class VoiceDictationCoordinator: @unchecked Sendable {
    public static let shared = VoiceDictationCoordinator()

    private let lock = UnfairLock()
    private var isRecording = false
    private var targetApp: NSRunningApplication?
    private var lastToggleTime: DispatchTime = .now()
    private let recorder = VoiceAudioRecorder.shared
    private let transcriber = VoiceTranscriber.shared

    private init() {
        // Wire live audio meter levels to HUD
        recorder.onAudioLevelUpdate = { level in
            DispatchQueue.main.async {
                VoiceHUDPanel.shared.updateAudioLevel(level)
            }
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

            let modelType = VoicePreferences.selectedModel
            let modelName = modelType.descriptor.shortName

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

                    VoiceHUDPanel.shared.updateState(.success(text: polishedText))
                    self.injectText(polishedText, sourceApp: appToRestore)

                case .failure(let error):
                    VoiceHUDPanel.shared.updateState(.error(message: error.localizedDescription))
                }
            }
        }
    }

    /// Cancels recording and dismisses the HUD without injecting text.
    public func cancelDictation() {
        lock.withLock { isRecording = false }
        recorder.cancelRecording()
        DispatchQueue.main.async {
            VoiceHUDPanel.shared.hide()
        }
    }

    // MARK: - Text Injection

    private func injectText(_ text: String, sourceApp: NSRunningApplication?) {
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
                eraseCountOverride: 0,
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
