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
/// and streams partial transcriptions with sub-100ms latency across speech pauses and multiple utterances.
public final class StreamingSpeechSession: @unchecked Sendable {
    private let lock = UnfairLock()
    private let locale: Locale
    private let recognizer: SFSpeechRecognizer?
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeTask: SFSpeechRecognitionTask?
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (Result<String, Error>) -> Void
    private let isFinished = LockedBool(false)

    // Multi-utterance continuous transcription state
    private var committedSegments: [String] = []
    private var currentSegmentPartial: String = ""
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var taskGeneration: Int = 0

    public init(
        locale: Locale = Locale.current,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        self.locale = locale
        self.onPartial = onPartial
        self.onFinal = onFinal

        let rec = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()
        self.recognizer = rec

        lock.withLock {
            startNewRecognitionTaskLocked()
        }
    }

    private func startNewRecognitionTaskLocked() {
        guard !isFinished.isSet else { return }
        guard let recognizer, recognizer.isAvailable else {
            if committedSegments.isEmpty {
                finishWith(result: .failure(NSError(domain: "StreamingSpeechSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable on system"])))
            }
            return
        }

        taskGeneration += 1
        let currentGen = taskGeneration

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
        }

        self.activeRequest = request

        // Flush any buffered frames from pause / restart window into new request
        for buffer in pendingBuffers {
            request.append(buffer)
        }
        pendingBuffers.removeAll(keepingCapacity: true)

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognitionCallback(generation: currentGen, result: result, error: error)
        }
        self.activeTask = task
    }

    private func handleRecognitionCallback(generation: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        var cumulativeToEmit: String?
        var finalResultToEmit: Result<String, Error>?

        lock.withLock {
            guard generation == self.taskGeneration else { return }

            if let result {
                let partial = result.bestTranscription.formattedString
                self.currentSegmentPartial = partial
                let cumulative = VoiceProgressiveTypingEngine.combineUtterances(
                    committed: self.committedSegments,
                    activePartial: partial
                )
                cumulativeToEmit = cumulative

                if result.isFinal {
                    if self.isFinished.isSet {
                        finalResultToEmit = .success(cumulative)
                    } else {
                        // Pause / endpoint silence reached mid-recording: commit and seamlessly restart task
                        if !partial.isEmpty {
                            self.committedSegments.append(partial)
                        }
                        self.currentSegmentPartial = ""
                        self.startNewRecognitionTaskLocked()
                    }
                    return
                }
            }

            if let error {
                if self.isFinished.isSet {
                    let cumulative = VoiceProgressiveTypingEngine.combineUtterances(
                        committed: self.committedSegments,
                        activePartial: self.currentSegmentPartial
                    )
                    if !cumulative.isEmpty {
                        finalResultToEmit = .success(cumulative)
                    } else {
                        finalResultToEmit = .failure(error)
                    }
                } else {
                    // Task ended due to silence timeout or recoverable stream boundary: preserve transcript & continue
                    if !self.currentSegmentPartial.isEmpty {
                        self.committedSegments.append(self.currentSegmentPartial)
                    }
                    self.currentSegmentPartial = ""
                    self.startNewRecognitionTaskLocked()
                }
            }
        }

        if let cumulativeToEmit {
            self.onPartial(cumulativeToEmit)
        }
        if let finalResultToEmit {
            self.finishWith(result: finalResultToEmit)
        }
    }

    /// Appends a live audio buffer from microphone capture.
    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !isFinished.isSet else { return }
            if let request = activeRequest {
                request.append(buffer)
            } else {
                pendingBuffers.append(buffer)
            }
        }
    }

    /// Ends audio capture and signals to the recognition task to finalize.
    public func finishAudio() {
        guard isFinished.testAndSet() else { return }

        var shouldFinishImmediately = false
        var cumulative = ""

        lock.withLock {
            if let request = activeRequest {
                request.endAudio()
            } else {
                shouldFinishImmediately = true
                cumulative = VoiceProgressiveTypingEngine.combineUtterances(
                    committed: committedSegments,
                    activePartial: currentSegmentPartial
                )
            }
        }

        if shouldFinishImmediately {
            finishWith(result: .success(cumulative))
        }
    }

    /// Immediately cancels the recognition task without waiting.
    public func cancel() {
        guard isFinished.testAndSet() else { return }
        lock.withLock {
            activeTask?.cancel()
            activeTask = nil
            activeRequest = nil
            pendingBuffers.removeAll()
        }
    }

    private func finishWith(result: Result<String, Error>) {
        lock.withLock {
            activeTask = nil
            activeRequest = nil
            pendingBuffers.removeAll()
        }
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
