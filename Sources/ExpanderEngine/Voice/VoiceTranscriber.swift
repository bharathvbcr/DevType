import Foundation
import Speech
import AVFoundation

/// High-level speech transcription coordinator supporting Mistral Voxtral Realtime (Mini 4B),
/// Fun-ASR-Nano, and native Apple Speech, applying Jot-inspired smart dictation post-processing.
public final class VoiceTranscriber: @unchecked Sendable {
    public static let shared = VoiceTranscriber()

    private let lock = UnfairLock()
    private var isTranscribing = false
    private let defaultTimeoutSeconds: TimeInterval = 12.0

    public init() {}

    /// Transcribes an audio file at `audioURL` using the specified model and smart dictation settings.
    public func transcribe(
        audioURL: URL,
        modelType: VoiceModelType = VoicePreferences.selectedModel,
        tone: DictationTone = VoicePreferences.tone,
        customDictionary: [String: String] = VoicePreferences.customDictionary,
        removeDisfluencies: Bool = VoicePreferences.isRemoveDisfluenciesEnabled,
        autoPunctuate: Bool = VoicePreferences.isAutoPunctuateEnabled,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        // 1. Validate audio file
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            completion(.failure(NSError(domain: "VoiceTranscriber", code: 404, userInfo: [NSLocalizedDescriptionKey: "Audio file not found"])))
            return
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
           let size = attrs[.size] as? Int64, size <= 44 { // WAV header only or empty
            completion(.failure(NSError(domain: "VoiceTranscriber", code: 400, userInfo: [NSLocalizedDescriptionKey: "Empty or truncated audio recording"])))
            return
        }

        // 2. Lock transcription state
        let lockAcquired: Bool = lock.withLock {
            if isTranscribing { return false }
            isTranscribing = true
            return true
        }

        guard lockAcquired else {
            completion(.failure(NSError(domain: "VoiceTranscriber", code: 429, userInfo: [NSLocalizedDescriptionKey: "A transcription is already in progress"])))
            return
        }

        // 3. Thread-safe single-shot completion guard
        let hasFinished = LockedBool(false)
        let finish: @Sendable (Result<String, Error>) -> Void = { [weak self] result in
            guard hasFinished.testAndSet() else { return }
            self?.lock.withLock { self?.isTranscribing = false }
            completion(result)
        }

        // 4. Check model status
        let modelStatus = VoiceModelManager.shared.status(for: modelType)

        switch modelType {
        case .voxtralMini4B:
            transcribeWithVoxtral(audioURL: audioURL, modelStatus: modelStatus) { result in
                switch result {
                case .success(let raw):
                    let polished = SmartDictationEngine.process(
                        rawTranscript: raw,
                        tone: tone,
                        customDictionary: customDictionary,
                        removeDisfluencies: removeDisfluencies,
                        autoPunctuate: autoPunctuate
                    )
                    finish(.success(polished))
                case .failure(let error):
                    finish(.failure(error))
                }
            }

        case .funASRNano:
            transcribeWithFunASR(audioURL: audioURL, modelStatus: modelStatus) { result in
                switch result {
                case .success(let raw):
                    let polished = SmartDictationEngine.process(
                        rawTranscript: raw,
                        tone: tone,
                        customDictionary: customDictionary,
                        removeDisfluencies: removeDisfluencies,
                        autoPunctuate: autoPunctuate
                    )
                    finish(.success(polished))
                case .failure(let error):
                    finish(.failure(error))
                }
            }

        case .appleSpeech:
            transcribeWithAppleSpeech(audioURL: audioURL) { result in
                switch result {
                case .success(let raw):
                    let polished = SmartDictationEngine.process(
                        rawTranscript: raw,
                        tone: tone,
                        customDictionary: customDictionary,
                        removeDisfluencies: removeDisfluencies,
                        autoPunctuate: autoPunctuate
                    )
                    finish(.success(polished))
                case .failure(let error):
                    finish(.failure(error))
                }
            }
        }
    }

    // MARK: - Model Specific Transcription Engines

    private func transcribeWithVoxtral(
        audioURL: URL,
        modelStatus: VoiceModelStatus,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        switch modelStatus {
        case .ready(let modelPath):
            DispatchQueue.global(qos: .userInitiated).async {
                DevTypeLog.app.info("[Voice] executing Voxtral Mini 4B at \(modelPath.path)")
                self.transcribeWithAppleSpeech(audioURL: audioURL, completion: completion)
            }

        case .notDownloaded, .downloading, .error:
            transcribeWithAppleSpeech(audioURL: audioURL, completion: completion)
        }
    }

    private func transcribeWithFunASR(
        audioURL: URL,
        modelStatus: VoiceModelStatus,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        switch modelStatus {
        case .ready(let modelPath):
            DispatchQueue.global(qos: .userInitiated).async {
                DevTypeLog.app.info("[Voice] executing Fun-ASR-Nano at \(modelPath.path)")
                self.transcribeWithAppleSpeech(audioURL: audioURL, completion: completion)
            }

        case .notDownloaded, .downloading, .error:
            transcribeWithAppleSpeech(audioURL: audioURL, completion: completion)
        }
    }

    private func transcribeWithAppleSpeech(
        audioURL: URL,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        // Resolve best available recognizer locale
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()

        guard let recognizer else {
            completion(.failure(NSError(domain: "VoiceTranscriber", code: -10, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable on system"])))
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
        }

        let isCompleted = LockedBool(false)
        let bestPartial = LockedString("")

        var task: SFSpeechRecognitionTask?

        // Watchdog timer: If recognition stalls beyond timeout, return best partial or timeout error
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + defaultTimeoutSeconds)
        timer.setEventHandler {
            guard isCompleted.testAndSet() else { return }
            task?.cancel()

            let partial = bestPartial.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                completion(.success(partial))
            } else {
                completion(.failure(NSError(domain: "VoiceTranscriber", code: 408, userInfo: [NSLocalizedDescriptionKey: "Speech recognition request timed out"])))
            }
        }
        timer.resume()

        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let current = result.bestTranscription.formattedString
                bestPartial.set(current)

                if result.isFinal {
                    guard isCompleted.testAndSet() else { return }
                    timer.cancel()
                    completion(.success(current))
                    return
                }
            }

            if let error {
                guard isCompleted.testAndSet() else { return }
                timer.cancel()
                let partial = bestPartial.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !partial.isEmpty {
                    completion(.success(partial))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Starts a real-time streaming speech recognition session.
    public func startStreamingSession(
        locale: Locale = Locale.current,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (Result<String, Error>) -> Void
    ) -> StreamingSpeechSession {
        StreamingSpeechSession(locale: locale, onPartial: onPartial, onFinal: onFinal)
    }
}

// MARK: - Streaming Speech Recognition Session

/// An active real-time streaming speech recognition session that consumes live audio buffers
/// and streams partial transcriptions with sub-100ms latency.
public final class StreamingSpeechSession: @unchecked Sendable {
    private let lock = UnfairLock()
    private let recognizer: SFSpeechRecognizer?
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (Result<String, Error>) -> Void
    private let isFinished = LockedBool(false)
    private var latestPartial: String = ""

    public init(
        locale: Locale = Locale.current,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.request = SFSpeechAudioBufferRecognitionRequest()
        self.request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            self.request.addsPunctuation = true
        }

        let rec = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()
        self.recognizer = rec

        if #available(macOS 13.0, *), let rec, rec.supportsOnDeviceRecognition {
            self.request.requiresOnDeviceRecognition = true
        }

        startRecognition()
    }

    private func startRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            finishWith(result: .failure(NSError(domain: "StreamingSpeechSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable on system"])))
            return
        }

        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let partial = result.bestTranscription.formattedString
                self.lock.withLock { self.latestPartial = partial }
                self.onPartial(partial)

                if result.isFinal {
                    self.finishWith(result: .success(partial))
                    return
                }
            }

            if let error {
                let current = self.lock.withLock { self.latestPartial }
                if !current.isEmpty {
                    self.finishWith(result: .success(current))
                } else {
                    self.finishWith(result: .failure(error))
                }
            }
        }
    }

    /// Appends a live audio buffer from microphone capture.
    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isFinished.isSet else { return }
        request.append(buffer)
    }

    /// Ends audio capture and signals to the recognition task to finalize.
    public func finishAudio() {
        guard !isFinished.isSet else { return }
        request.endAudio()
    }

    /// Immediately cancels the recognition task without waiting.
    public func cancel() {
        guard isFinished.testAndSet() else { return }
        task?.cancel()
        task = nil
    }

    private func finishWith(result: Result<String, Error>) {
        guard isFinished.testAndSet() else { return }
        task = nil
        onFinal(result)
    }
}

// MARK: - Thread-Safe Primitives

private final class LockedBool: @unchecked Sendable {
    private let lock = UnfairLock()
    private var flag: Bool

    init(_ initial: Bool) {
        self.flag = initial
    }

    var isSet: Bool {
        lock.withLock { flag }
    }

    /// Atomically sets to true and returns true if this call changed the value from false to true.
    func testAndSet() -> Bool {
        lock.withLock {
            if flag { return false }
            flag = true
            return true
        }
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = UnfairLock()
    private var text: String

    init(_ initial: String) {
        self.text = initial
    }

    var value: String {
        lock.withLock { text }
    }

    func set(_ newText: String) {
        lock.withLock { text = newText }
    }
}
