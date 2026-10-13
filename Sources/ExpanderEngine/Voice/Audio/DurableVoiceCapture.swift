import Foundation
@preconcurrency import AVFoundation

public actor DurableVoiceCapture {
    public static let shared = DurableVoiceCapture()

    private var audioEngine: AVAudioEngine?
    private var bufferPool = AudioBufferPool()
    private var writer: CAFSessionWriter?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isCapturing = false
    private var captureDirectory: URL?
    private var acceptedFrames: Int64 = 0
    private var droppedFrames: Int64 = 0
    /// A writer/converter failure must survive until `stopCapture()` so the coordinator reports
    /// the real failure instead of producing a seemingly valid artifact with missing frames.
    private var captureError: VoiceFailure?
    private var drain: PCMCaptureDrain?
    /// True while `stopCapture` is joined to the drain. `await` frees this actor, and
    /// `cancelCapture` / `startCapture` must not finalize or reset the pool out from under it.
    private var drainJoinOwned = false
    /// `cancelCapture` cannot await, and the drain must still be joined. The drain queue never
    /// takes this actor, so the bounded wait cannot deadlock the executor.
    private static let drainJoinTimeout: TimeInterval = 2

    public var onAudioLevelUpdate: (@Sendable (Float) -> Void)?
    public var onPCMBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    private init() {}

    /// Actor-isolated setters — the handlers are stored state, so they cannot be
    /// assigned from outside the actor.
    public func setOnPCMBuffer(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        onPCMBuffer = handler
        drain?.setPCMHandler(handler)
    }

    public func setOnAudioLevelUpdate(_ handler: (@Sendable (Float) -> Void)?) {
        onAudioLevelUpdate = handler
        drain?.setLevelHandler(handler)
    }

    public enum MicrophonePermissionStatus: String, Sendable, Equatable {
        case authorized
        case notDetermined
        case denied
        case restricted
    }

    public static func microphonePermissionStatus() -> MicrophonePermissionStatus {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
        #else
        return .authorized
        #endif
    }

    public static func checkMicrophonePermission() -> Bool {
        microphonePermissionStatus() == .authorized
    }

    /// Closure form for legacy/callback-driven callers. New permission flows should use the
    /// async overload so the main run loop remains available to the system prompt.
    public static func requestMicrophonePermission(completion: @escaping @Sendable (Bool) -> Void) {
        #if os(macOS)
        AVCaptureDevice.requestAccess(for: .audio) { granted in completion(granted) }
        #else
        completion(true)
        #endif
    }

    public static func requestMicrophonePermission() async -> Bool {
        #if os(macOS)
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return true
        #endif
    }

    public func startCapture(sessionDirectory: URL) throws {
        guard !isCapturing, !drainJoinOwned else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 else {
            throw VoiceFailure(
                stage: .audioCapture,
                code: .noMicrophone,
                userAction: .grantMicrophonePermission,
                redactedDetail: "Hardware input format unavailable or invalid"
            )
        }

        let outputURL = sessionDirectory.appendingPathComponent("capture.caf")
        let cafWriter = try CAFSessionWriter(outputURL: outputURL, sampleRate: 16000, channelCount: 1)
        self.writer = cafWriter
        self.targetFormat = cafWriter.targetFormat

        if let targetFormat = self.targetFormat, hwFormat != targetFormat {
            self.converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        } else {
            self.converter = nil
        }

        self.audioEngine = engine
        self.captureDirectory = sessionDirectory
        self.acceptedFrames = 0
        self.droppedFrames = 0
        self.captureError = nil
        self.bufferPool.reset()
        let pool = self.bufferPool

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { buffer, time in
            _ = pool.enqueue(buffer: buffer, sampleTime: Double(time.sampleTime))
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            audioEngine = nil
            converter = nil
            targetFormat = nil
            captureDirectory = nil
            if let writer = self.writer {
                do {
                    _ = try writer.finalize()
                } catch {
                    DevTypeLog.voice.error(
                        "[Voice] failed to close CAF after capture start failure \(DevTypeLog.errorMetadata(error), privacy: .public)"
                    )
                }
            }
            self.writer = nil
            throw error
        }
        let captureDrain = PCMCaptureDrain(
            pool: bufferPool,
            writer: cafWriter,
            converter: converter,
            targetFormat: targetFormat,
            onPCMBuffer: onPCMBuffer,
            onLevel: onAudioLevelUpdate
        )
        drain = captureDrain
        captureDrain.start()
        isCapturing = true
    }

    public func stopCapture() async throws -> AudioArtifact {
        guard isCapturing, let engine = audioEngine, let writer = self.writer, let sessionDir = captureDirectory else {
            throw VoiceFailure(stage: .audioFinalization, code: .zeroFramesCaptured, redactedDetail: "Capture was not active")
        }

        // Stay "capturing" until the drain has joined and the writer has been finalized once.
        // The await below releases this actor; start/cancel must not take the pool or the writer.
        drainJoinOwned = true
        defer {
            drainJoinOwned = false
            isCapturing = false
        }

        // Stop input tap and engine before joining the drain, so removeTap's wait for the
        // in-flight callback is the last enqueue.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil

        let captureDrain = drain
        drain = nil
        let outcome = await join(captureDrain)
        accept(outcome)

        // Finalize CAF writer before reporting a conversion/write failure, so the partial file is
        // still a valid recovery artifact and the writer cannot remain open across sessions.
        let finalStats: (totalFrames: Int64, sha256Hex: String, byteCount: Int64)
        do {
            finalStats = try writer.finalize()
        } catch {
            self.writer = nil
            self.captureDirectory = nil
            self.captureError = nil
            if let joinFailure = outcome.joinFailure {
                throw joinFailure
            }
            throw error
        }
        self.writer = nil
        self.captureDirectory = nil

        if let joinFailure = outcome.joinFailure {
            self.captureError = nil
            throw joinFailure
        }
        if let captureError {
            self.captureError = nil
            throw captureError
        }

        let cafURL = sessionDir.appendingPathComponent("capture.caf")
        let duration = finalStats.totalFrames > 0 ? Double(finalStats.totalFrames) / 16000.0 : 0.0

        guard finalStats.totalFrames > 0 else {
            throw VoiceFailure(
                stage: .audioFinalization,
                code: .zeroFramesCaptured,
                artifactState: .absent,
                userAction: .retryWithOtherProvider,
                redactedDetail: "0 frames written to audio capture"
            )
        }

        let artifact = AudioArtifact(
            fileURL: cafURL,
            format: "caf",
            sampleRate: 16000,
            channelCount: 1,
            frameCount: finalStats.totalFrames,
            durationSeconds: duration,
            byteCount: finalStats.byteCount,
            sha256Hex: finalStats.sha256Hex,
            gapCount: Self.gapCount(for: droppedFrames)
        )

        return artifact
    }

    public func cancelCapture() {
        if drainJoinOwned {
            return
        }
        isCapturing = false
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        let captureDrain = drain
        drain = nil
        if let captureDrain {
            let outcome = captureDrain.stopAndJoin(timeout: Self.drainJoinTimeout)
            if let failure = outcome.joinFailure ?? outcome.captureError {
                DevTypeLog.voice.error(
                    "[Voice] cancelled capture drain failed code=\(failure.code.rawValue, privacy: .public) detail=\(failure.redactedDetail ?? "", privacy: .public)"
                )
            }
        }
        if let writer {
            do {
                _ = try writer.finalize()
            } catch {
                DevTypeLog.voice.error(
                    "[Voice] failed to finalize cancelled CAF capture \(DevTypeLog.errorMetadata(error), privacy: .public)"
                )
            }
        }
        writer = nil
        converter = nil
        targetFormat = nil
        captureDirectory = nil
        captureError = nil
    }

    private func join(_ drain: PCMCaptureDrain?) async -> PCMCaptureDrain.Outcome {
        guard let drain else { return .idle }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: drain.stopAndJoin(timeout: Self.drainJoinTimeout))
            }
        }
    }

    private func accept(_ outcome: PCMCaptureDrain.Outcome) {
        let poolDrops = Self.int64(saturating: bufferPool.droppedFrames)
        droppedFrames = Saturating.adding(outcome.processingDrops, poolDrops)
        acceptedFrames = outcome.acceptedFrames
        captureError = outcome.captureError ?? outcome.joinFailure
    }

    private static func int64(saturating value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    private static func gapCount(for frames: Int64) -> Int {
        if frames <= 0 { return 0 }
        if frames > Int64(Int.max) { return Int.max }
        return Int(frames)
    }
}

/// Consumes pool copies off the actor. The tap only enqueues; this queue rebuilds an owned
/// `AVAudioPCMBuffer` for the converter, the CAF writer, and `onPCMBuffer`.
final class PCMCaptureDrain: @unchecked Sendable {
    struct Outcome: Sendable {
        var joinFailure: VoiceFailure?
        var captureError: VoiceFailure?
        var acceptedFrames: Int64
        var processingDrops: Int64

        static let idle = Outcome(joinFailure: nil, captureError: nil, acceptedFrames: 0, processingDrops: 0)
    }

    private let pool: AudioBufferPool
    private let writer: CAFSessionWriter
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "com.devtype.voice.pcm-drain", qos: .userInitiated)
    private let finished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var pcmHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var stopRequested = false
    private var didFinish = false
    private var started = false
    private var acceptedFrames: Int64 = 0
    private var processingDrops: Int64 = 0
    private var captureError: VoiceFailure?

    init(
        pool: AudioBufferPool,
        writer: CAFSessionWriter,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat?,
        onPCMBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        onLevel: (@Sendable (Float) -> Void)?
    ) {
        self.pool = pool
        self.writer = writer
        self.converter = converter
        self.targetFormat = targetFormat
        self.pcmHandler = onPCMBuffer
        self.levelHandler = onLevel
    }

    func setPCMHandler(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        stateLock.lock()
        pcmHandler = handler
        stateLock.unlock()
    }

    func setLevelHandler(_ handler: (@Sendable (Float) -> Void)?) {
        stateLock.lock()
        levelHandler = handler
        stateLock.unlock()
    }

    func start() {
        stateLock.lock()
        if started {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()
        queue.async { [weak self] in
            self?.run()
        }
    }

    func stopAndJoin(timeout: TimeInterval) -> Outcome {
        stateLock.lock()
        stopRequested = true
        let alreadyFinished = didFinish
        stateLock.unlock()
        pool.wakeWaiters()
        if !alreadyFinished {
            if finished.wait(timeout: .now() + timeout) != .success {
                return snapshot(
                    joinFailure: VoiceFailure(
                        stage: .audioFinalization,
                        code: .audioEncodingFailed,
                        retryClass: .afterUserAction,
                        artifactState: .partial,
                        userAction: .retryWithOtherProvider,
                        redactedDetail: "Audio drain did not finish before the deadline"
                    )
                )
            }
        }
        return snapshot(joinFailure: nil)
    }

    private func run() {
        while !isStopRequested() {
            _ = pool.waitForEnqueue(timeout: .now() + .milliseconds(200))
            consumeAvailable()
        }
        consumeAvailable()
        stateLock.lock()
        didFinish = true
        stateLock.unlock()
        finished.signal()
    }

    private func isStopRequested() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRequested
    }

    private func consumeAvailable() {
        for chunk in pool.dequeueAll() {
            consume(chunk)
        }
    }

    private func consume(_ chunk: AudioBufferPool.Chunk) {
        if hasCaptureError() {
            addDrops(Int64(chunk.frameCount))
            return
        }
        guard let owned = chunk.makePCMBuffer() else {
            record(
                VoiceFailure(
                    stage: .audioCapture,
                    code: .audioEncodingFailed,
                    retryClass: .afterUserAction,
                    artifactState: .partial,
                    userAction: .retryWithOtherProvider,
                    redactedDetail: "Could not rebuild an owned PCM buffer"
                ),
                droppedFrames: Int64(chunk.frameCount)
            )
            return
        }
        publishLevel(owned)
        if let converter, let targetFormat {
            let ratio = targetFormat.sampleRate / owned.format.sampleRate
            let capacity = AVAudioFrameCount(Double(owned.frameLength) * ratio + 100)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                record(
                    VoiceFailure(
                        stage: .audioCapture,
                        code: .audioEncodingFailed,
                        retryClass: .afterUserAction,
                        artifactState: .partial,
                        userAction: .retryWithOtherProvider,
                        redactedDetail: "Could not allocate the converted audio buffer"
                    ),
                    droppedFrames: Int64(owned.frameLength)
                )
                return
            }

            var error: NSError?
            var allConsumed = false
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if allConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                allConsumed = true
                outStatus.pointee = .haveData
                return owned
            }

            if let conversionError = error {
                record(
                    VoiceFailure(
                        stage: .audioCapture,
                        code: .audioEncodingFailed,
                        retryClass: .afterUserAction,
                        artifactState: .partial,
                        userAction: .retryWithOtherProvider,
                        redactedDetail: "Audio conversion failed: \(conversionError.localizedDescription)"
                    ),
                    droppedFrames: Int64(owned.frameLength)
                )
                return
            }
            guard outputBuffer.frameLength > 0 else { return }
            writeAndPublish(outputBuffer)
        } else {
            writeAndPublish(owned)
        }
    }

    private func publishLevel(_ buffer: AVAudioPCMBuffer) {
        let handler = currentLevelHandler()
        guard let handler, let floatData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let length = Int(buffer.frameLength)
        guard channelCount > 0, length > 0 else {
            handler(0)
            return
        }
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = floatData[channel]
            for index in 0..<length {
                sum += samples[index] * samples[index]
            }
        }
        let rms = sqrt(sum / Float(length * channelCount))
        handler(min(max(rms * 5.0, 0.0), 1.0))
    }

    private func writeAndPublish(_ buffer: AVAudioPCMBuffer) {
        do {
            try writer.write(buffer: buffer)
            addAccepted(Int64(buffer.frameLength))
            currentPCMHandler()?(buffer)
        } catch {
            record(
                VoiceFailure(
                    stage: .audioCapture,
                    code: .audioEncodingFailed,
                    retryClass: .afterUserAction,
                    artifactState: .partial,
                    userAction: .freeDiskSpace,
                    redactedDetail: "CAF write failed: \(error.localizedDescription)"
                ),
                droppedFrames: Int64(buffer.frameLength)
            )
        }
    }

    private func record(_ error: VoiceFailure, droppedFrames: Int64) {
        stateLock.lock()
        if droppedFrames > 0 {
            processingDrops = Saturating.adding(processingDrops, droppedFrames)
        }
        let first = captureError == nil
        if first {
            captureError = error
        }
        let totalDrops = processingDrops
        stateLock.unlock()
        guard first else { return }
        DevTypeLog.voice.error(
            "[Voice] capture stopped accepting audio code=\(error.code.rawValue, privacy: .public) droppedFrames=\(totalDrops, privacy: .public)"
        )
    }

    private func addDrops(_ frames: Int64) {
        guard frames > 0 else { return }
        stateLock.lock()
        processingDrops = Saturating.adding(processingDrops, frames)
        stateLock.unlock()
    }

    private func addAccepted(_ frames: Int64) {
        guard frames > 0 else { return }
        stateLock.lock()
        acceptedFrames = Saturating.adding(acceptedFrames, frames)
        stateLock.unlock()
    }

    private func hasCaptureError() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captureError != nil
    }

    private func currentPCMHandler() -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pcmHandler
    }

    private func currentLevelHandler() -> (@Sendable (Float) -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return levelHandler
    }

    private func snapshot(joinFailure: VoiceFailure?) -> Outcome {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Outcome(
            joinFailure: joinFailure,
            captureError: captureError,
            acceptedFrames: acceptedFrames,
            processingDrops: processingDrops
        )
    }
}
