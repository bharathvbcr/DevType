import Foundation
import Speech
import AVFoundation

/// Live, microphone-driven speech recognition for progressive typing.
///
/// Distinct from the `SpeechRecognizer` adapters, which transcribe a finished
/// `AudioArtifact` after capture ends. This runs *during* capture and emits
/// `SpeechSegment` values as the user speaks.
///
/// Each utterance is one segment with a stable `segmentID`. Segments are `.volatile`
/// while the recognizer is still revising them and `.final` once it reaches an endpoint
/// (a pause). Consumers seal a commit barrier on `.final`, which is what keeps a pause
/// from erasing earlier text — see `VoiceTranscriptReconciler`.
///
/// On macOS 26+ `SpeechTranscriber` supplies this volatile/final distinction natively.
/// Here it is derived from `SFSpeechRecognizer`'s endpoint behaviour, which requires
/// restarting the recognition task at each endpoint.
public final class LiveSpeechStream: @unchecked Sendable {

    /// Bounds on a single continuous session. Past these the stream stops restarting
    /// rather than spinning or accumulating without limit.
    public static let maxSegments = 512
    public static let maxPendingBuffers = 256
    public static let maxConsecutiveEmptyRestarts = 8

    private let lock = UnfairLock()
    private let recognizer: SFSpeechRecognizer?

    private let onSegment: @Sendable (SpeechSegment) -> Void
    private let onFailure: @Sendable (VoiceFailure) -> Void

    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeTask: SFSpeechRecognitionTask?
    private var pendingBuffers: [AVAudioPCMBuffer] = []

    private var taskGeneration = 0
    private var segmentIndex = 0
    private var currentRevision: UInt64 = 0
    private var consecutiveEmptyRestarts = 0
    private var isFinished = false

    public init(
        locale: Locale = Locale.current,
        contextualStrings: [String] = [],
        onSegment: @escaping @Sendable (SpeechSegment) -> Void,
        onFailure: @escaping @Sendable (VoiceFailure) -> Void = { _ in }
    ) {
        self.onSegment = onSegment
        self.onFailure = onFailure
        self.recognizer = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()
        self.contextualStrings = contextualStrings

        lock.withLock { startTaskLocked() }
    }

    private let contextualStrings: [String]

    // MARK: - Audio

    /// Feeds a microphone buffer into the active recognition request.
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !isFinished else { return }
            if let request = activeRequest {
                request.append(buffer)
            } else if pendingBuffers.count < Self.maxPendingBuffers {
                pendingBuffers.append(buffer)
            }
        }
    }

    /// Ends audio input. Any in-flight utterance is emitted as `.final`.
    public func finish() {
        let request: SFSpeechAudioBufferRecognitionRequest? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            return activeRequest
        }
        request?.endAudio()
    }

    /// Stops immediately without emitting anything further.
    public func cancel() {
        lock.withLock {
            isFinished = true
            activeTask?.cancel()
            activeTask = nil
            activeRequest = nil
            pendingBuffers.removeAll()
        }
    }

    // MARK: - Recognition

    private func startTaskLocked() {
        guard !isFinished else { return }
        guard consecutiveEmptyRestarts < Self.maxConsecutiveEmptyRestarts else { return }
        guard segmentIndex < Self.maxSegments else { return }

        guard let recognizer, recognizer.isAvailable else {
            let failure = VoiceFailure(
                stage: .recognition,
                code: .endpointUnreachable,
                redactedDetail: "SFSpeechRecognizer unavailable for live capture"
            )
            let emit = onFailure
            DispatchQueue.global(qos: .userInitiated).async { emit(failure) }
            return
        }

        taskGeneration += 1
        let generation = taskGeneration

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
        }
        activeRequest = request

        // Replay buffers captured while no request was live, so the restart window
        // between two utterances does not drop audio.
        for buffer in pendingBuffers {
            request.append(buffer)
        }
        pendingBuffers.removeAll(keepingCapacity: true)

        activeTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(generation: generation, result: result, error: error)
        }
    }

    private func handle(generation: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        var toEmit: SpeechSegment?

        lock.withLock {
            guard generation == taskGeneration else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                currentRevision += 1

                let isEndpoint = result.isFinal
                toEmit = SpeechSegment(
                    segmentID: "live-\(segmentIndex)",
                    revision: currentRevision,
                    text: text,
                    confidence: nil,
                    finality: isEndpoint ? .final : .volatile
                )

                if isEndpoint {
                    advanceSegmentLocked(hadSpeech: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                return
            }

            if error != nil {
                // A recognition task ends at a silence timeout as well as on a real error.
                // Mid-session that is an endpoint, not a failure: seal the segment and
                // continue so the user can keep talking.
                if !isFinished {
                    advanceSegmentLocked(hadSpeech: false)
                }
            }
        }

        if let toEmit {
            onSegment(toEmit)
        }
    }

    /// Seals the current utterance and opens the next one. Caller must hold the lock.
    private func advanceSegmentLocked(hadSpeech: Bool) {
        consecutiveEmptyRestarts = hadSpeech ? 0 : consecutiveEmptyRestarts + 1
        segmentIndex += 1
        currentRevision = 0
        activeTask = nil
        activeRequest = nil
        guard !isFinished else { return }
        startTaskLocked()
    }
}
