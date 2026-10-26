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

    /// A recognition task that ends with no text counts toward `maxConsecutiveEmptyRestarts` only if
    /// it lived shorter than this. A task that survived this long and then ended empty is a silence
    /// endpoint (a pause in the dictation), not an immediate-error loop, so it does not count and
    /// it resets the run. Without the distinction a minute's pause ends several silence-timeout
    /// tasks in a row and the live preview stays dead for the rest of the session.
    ///
    /// UNMEASURED. 2 s is a design choice, not an observation: the trace had no task-end records
    /// when it was chosen. Every task end now writes `stream.taskEnded` with `lifetimeMs=` and
    /// `produced=` (see `taskEndedNote`). To measure it, read `~/Library/Application
    /// Support/DevType/voice-trace.jsonl` (tracing must be on), keep the `stream.taskEnded` rows
    /// with `produced=false`, and look at the `lifetimeMs` distribution: an immediate-error loop is
    /// a tight cluster near zero, a silence endpoint clusters at the recognizer's idle timeout.
    /// The threshold belongs in the gap between the two clusters.
    static let minimumProductiveTaskLifetimeSeconds: TimeInterval = 2

    private let lock = UnfairLock()
    private let runtime: AppleOnDeviceSpeechRuntime?
    /// Monotonic seconds; injected so lifetimes are testable without sleeping.
    private let clock: @Sendable () -> TimeInterval
    private var taskStartedAt: TimeInterval = 0

    private let onSegment: @Sendable (SpeechSegment) -> Void
    private let onFailure: @Sendable (VoiceFailure) -> Void

    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeTask: AppleSpeechTaskHandle?
    private var pendingBuffers: [AVAudioPCMBuffer] = []

    private var taskGeneration = 0
    private var segmentIndex = 0
    private var currentRevision: UInt64 = 0
    /// Last text seen for the segment in flight, so the segment can be sealed with its
    /// best transcription when the task ends without reporting `isFinal`.
    private var currentText = ""
    private var consecutiveEmptyRestarts = 0
    private var isFinished = false

    public convenience init(
        locale: Locale = Locale.current,
        contextualStrings: [String] = [],
        onSegment: @escaping @Sendable (SpeechSegment) -> Void,
        onFailure: @escaping @Sendable (VoiceFailure) -> Void = { _ in }
    ) {
        self.init(
            runtime: AppleOnDeviceSpeechRuntime.system(
                locale: locale,
                includeEnglishFallback: true
            ),
            contextualStrings: contextualStrings,
            onSegment: onSegment,
            onFailure: onFailure
        )
    }

    init(
        runtime: AppleOnDeviceSpeechRuntime?,
        contextualStrings: [String] = [],
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onSegment: @escaping @Sendable (SpeechSegment) -> Void,
        onFailure: @escaping @Sendable (VoiceFailure) -> Void = { _ in }
    ) {
        self.onSegment = onSegment
        self.onFailure = onFailure
        self.runtime = runtime
        self.clock = clock
        self.contextualStrings = contextualStrings

        lock.withLock { startTaskLocked() }
    }

    private let contextualStrings: [String]

    // MARK: - Audio

    /// Buffers retained while no recognition request is active. Test-only; production state stays private.
    func pendingPCMBuffersForTesting() -> [AVAudioPCMBuffer] {
        lock.withLock { pendingBuffers }
    }

    /// Feeds a microphone buffer into the active recognition request.
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !isFinished else { return }
            if let request = activeRequest {
                request.append(buffer)
            } else if pendingBuffers.count < Self.maxPendingBuffers {
                guard let owned = Self.ownedCopy(of: buffer) else { return }
                pendingBuffers.append(owned)
            }
        }
    }

    /// Independent storage for the pending path. A failed allocation must not keep the caller's buffer.
    private static func ownedCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: max(frames, 1)) else {
            return nil
        }
        copy.frameLength = frames
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for (sourceBuffer, destinationBuffer) in zip(source, destination) {
            let count = Int(sourceBuffer.mDataByteSize)
            if count == 0 { continue }
            guard count <= Int(destinationBuffer.mDataByteSize),
                  let sourcePointer = sourceBuffer.mData,
                  let destinationPointer = destinationBuffer.mData
            else {
                return nil
            }
            destinationPointer.copyMemory(from: sourcePointer, byteCount: count)
        }
        return copy
    }

    /// Ends audio input. Any in-flight utterance is emitted as `.final`.
    public func finish() {
        VoiceDiagnosticsRecorder.shared.record("stream.finishAudio")
        let request: SFSpeechAudioBufferRecognitionRequest? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            // With no request in flight the live preview is already over (it gave up, was
            // disabled, or never started), so buffered audio has no recipient and is released
            // rather than held until deinit. This is harmless to the transcript: the preview is
            // optional and the final batch pass reads the durable recording, never these buffers.
            if activeRequest == nil { pendingBuffers.removeAll() }
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
        guard consecutiveEmptyRestarts < Self.maxConsecutiveEmptyRestarts else {
            // Recognition has stopped for the rest of the session; without this line that
            // is completely silent to the user and to a bug report.
            DevTypeLog.voice.info("[Voice] live recognition stopped: \(Self.maxConsecutiveEmptyRestarts) immediate empty restarts")
            VoiceDiagnosticsRecorder.shared.record(
                "stream.gaveUp", note: "emptyRestarts=\(consecutiveEmptyRestarts)"
            )
            stopRestartingLocked()
            return
        }
        guard segmentIndex < Self.maxSegments else {
            DevTypeLog.voice.info("[Voice] live recognition stopped: segment cap reached")
            VoiceDiagnosticsRecorder.shared.record("stream.gaveUp", note: "segmentCap")
            stopRestartingLocked()
            return
        }

        guard let runtime else {
            let failure = VoiceFailure(
                stage: .recognition,
                code: .endpointUnreachable,
                redactedDetail: "SFSpeechRecognizer unavailable for live capture"
            )
            let emit = onFailure
            DispatchQueue.global(qos: .userInitiated).async { emit(failure) }
            return
        }

        // This preview is optional even when the final provider is Local Whisper or
        // Gemini. If Apple would require its network service, disable preview silently
        // instead of leaking microphone buffers or aborting the independent final pass.
        guard runtime.supportsOnDeviceRecognition else {
            isFinished = true
            pendingBuffers.removeAll()
            DevTypeLog.voice.error("[Voice] live recognition disabled: on-device Apple Speech unsupported")
            VoiceDiagnosticsRecorder.shared.record(
                "stream.unavailable", note: "onDeviceRecognitionUnsupported"
            )
            return
        }

        guard runtime.isAvailable else {
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
        taskStartedAt = clock()
        VoiceDiagnosticsRecorder.shared.record(
            "stream.taskStarted",
            note: "segment=live-\(segmentIndex) taskGen=\(generation) "
                + "pendingBuffers=\(pendingBuffers.count) emptyRestarts=\(consecutiveEmptyRestarts)"
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        activeRequest = request

        // Replay buffers captured while no request was live, so the restart window
        // between two utterances does not drop audio.
        for buffer in pendingBuffers {
            request.append(buffer)
        }
        pendingBuffers.removeAll(keepingCapacity: true)

        guard let task = runtime.startOnDeviceRecognition(
            with: request,
            resultHandler: { [weak self] result, error in
                self?.handle(generation: generation, result: result, error: error)
            }
        ) else {
            // Only reachable if on-device support was withdrawn between the check above and this
            // call. The preview is over for the session, which is harmless to the transcript: it
            // is optional, and the final batch pass reads the durable recording.
            activeRequest = nil
            stopRestartingLocked()
            DevTypeLog.voice.error("[Voice] live recognition disabled: on-device policy rejected the start")
            VoiceDiagnosticsRecorder.shared.record(
                "stream.unavailable", note: "onDevicePolicyRejectedStart"
            )
            return
        }
        activeTask = task
    }

    /// Ends the live preview for the rest of the session and releases buffered audio. Caller must
    /// hold the lock. Nothing is reported through `onFailure`: the preview is optional and the final
    /// batch pass runs from the durable recording whatever happens here.
    private func stopRestartingLocked() {
        isFinished = true
        pendingBuffers.removeAll()
    }

    /// The `stream.taskEnded` trace note. Pure so the evidence the lifetime threshold depends on
    /// is testable: lifetime, whether any text was produced, how the task ended, and the error's
    /// domain and code when it ended with one. Never carries transcript text.
    static func taskEndedNote(
        segment: Int,
        taskGeneration: Int,
        lifetime: TimeInterval,
        textLength: Int,
        endedBy: String,
        error: Error?,
        countedAsEmptyRestart: Bool
    ) -> String {
        var note = "segment=live-\(segment) taskGen=\(taskGeneration) "
            + "lifetimeMs=\(Int((max(0, lifetime) * 1_000).rounded())) "
            + "produced=\(textLength > 0) textLength=\(textLength) endedBy=\(endedBy) "
            + "countedAsEmptyRestart=\(countedAsEmptyRestart)"
        if let error {
            let bridged = error as NSError
            note += " errorDomain=\(bridged.domain) errorCode=\(bridged.code)"
        }
        return note
    }

    private func handle(generation: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        var toEmit: [SpeechSegment] = []

        lock.withLock {
            guard generation == taskGeneration else { return }

            if let result {
                let text = result.bestTranscription.formattedString

                // The recognizer signals an utterance boundary by *replacing* its result
                // rather than by reporting `isFinal`, so the boundary has to be inferred.
                // Seal the finished utterance under its own id before opening the next,
                // otherwise it is simply overwritten and the text disappears.
                if UtteranceBoundaryDetector.isReset(previous: currentText, current: text) {
                    currentRevision += 1
                    toEmit.append(SpeechSegment(
                        segmentID: "live-\(segmentIndex)",
                        revision: currentRevision,
                        text: currentText,
                        finality: .final
                    ))
                    VoiceDiagnosticsRecorder.shared.record(
                        "stream.utteranceBoundary",
                        note: "sealed=live-\(segmentIndex) length=\(currentText.count) next=\(text.count)"
                    )
                    DevTypeLog.voice.info(
                        "[Voice] utterance boundary: sealed \(self.currentText.count) chars, new utterance \(text.count) chars"
                    )
                    segmentIndex += 1
                    currentRevision = 0
                    consecutiveEmptyRestarts = 0
                }

                currentRevision += 1
                currentText = text

                let isEndpoint = result.isFinal
                let segment = SpeechSegment(
                    segmentID: "live-\(segmentIndex)",
                    revision: currentRevision,
                    text: text,
                    confidence: nil,
                    finality: isEndpoint ? .final : .volatile
                )
                toEmit.append(segment)

                VoiceDiagnosticsRecorder.shared.record(
                    "stream.result",
                    segment: segment,
                    note: "isFinal=\(isEndpoint) taskGen=\(taskGeneration)"
                )

                if isEndpoint {
                    advanceSegmentLocked(
                        textLength: text.trimmingCharacters(in: .whitespacesAndNewlines).count,
                        endedBy: "final",
                        error: nil
                    )
                }
                return
            }

            if error != nil {
                // A recognition task ends on a silence timeout as well as on a real error,
                // and with a buffer request that is the *usual* way a pause surfaces —
                // `isFinal` generally only arrives after `endAudio()`. Mid-session this is
                // an endpoint, not a failure.
                //
                // The segment is sealed here with its best transcription. Without this the
                // utterance was left unlabelled, and a consumer waiting for `.final` would
                // wait forever.
                guard !isFinished else { return }

                let settled = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !settled.isEmpty {
                    currentRevision += 1
                    toEmit.append(SpeechSegment(
                        segmentID: "live-\(segmentIndex)",
                        revision: currentRevision,
                        text: settled,
                        finality: .final
                    ))
                }
                advanceSegmentLocked(textLength: settled.count, endedBy: "error", error: error)
            }
        }

        // In order: a sealing final for the finished utterance, then the new one.
        for segment in toEmit {
            onSegment(segment)
        }
    }

    /// Records how the task ended, seals the current utterance and opens the next one. Caller must
    /// hold the lock.
    ///
    /// Only an empty task that lived under `minimumProductiveTaskLifetimeSeconds` counts toward the
    /// give-up cap; any other ending shows the recognizer is alive and resets the run.
    private func advanceSegmentLocked(textLength: Int, endedBy: String, error: Error?) {
        let lifetime = clock() - taskStartedAt
        let isImmediateEmptyEnding = textLength == 0 && lifetime < Self.minimumProductiveTaskLifetimeSeconds
        VoiceDiagnosticsRecorder.shared.record(
            "stream.taskEnded",
            note: Self.taskEndedNote(
                segment: segmentIndex,
                taskGeneration: taskGeneration,
                lifetime: lifetime,
                textLength: textLength,
                endedBy: endedBy,
                error: error,
                countedAsEmptyRestart: isImmediateEmptyEnding
            )
        )
        consecutiveEmptyRestarts = isImmediateEmptyEnding ? consecutiveEmptyRestarts + 1 : 0
        segmentIndex += 1
        currentRevision = 0
        currentText = ""
        activeTask = nil
        activeRequest = nil
        guard !isFinished else { return }
        startTaskLocked()
    }
}
