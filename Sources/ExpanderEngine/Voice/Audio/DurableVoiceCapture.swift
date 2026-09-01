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
    private var drainTimer: Task<Void, Never>?

    public var onAudioLevelUpdate: (@Sendable (Float) -> Void)?
    public var onPCMBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    private init() {}

    /// Actor-isolated setters — the handlers are stored state, so they cannot be
    /// assigned from outside the actor.
    public func setOnPCMBuffer(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        onPCMBuffer = handler
    }

    public func setOnAudioLevelUpdate(_ handler: (@Sendable (Float) -> Void)?) {
        onAudioLevelUpdate = handler
    }

    public static func checkMicrophonePermission() -> Bool {
        #if os(macOS)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .authorized
        #else
        return true
        #endif
    }

    /// Closure form for callers that cannot await — notably `PermissionRequester`, which
    /// runs inside a synchronous permission audit.
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
        guard !isCapturing else { return }

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

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
            Task {
                await self.handleAudioCallback(buffer: buffer, sampleTime: Double(time.sampleTime))
            }
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
                        "[Voice] failed to close CAF after capture start failure: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            self.writer = nil
            throw error
        }
        isCapturing = true
    }

    private func handleAudioCallback(buffer: AVAudioPCMBuffer, sampleTime: Double) {
        guard isCapturing, captureError == nil else { return }

        // Level calculation for HUD
        if let floatData = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let length = Int(buffer.frameLength)
            var sum: Float = 0
            for channel in 0..<channelCount {
                let ptr = floatData[channel]
                for i in 0..<length {
                    sum += ptr[i] * ptr[i]
                }
            }
            let rms = length > 0 ? sqrt(sum / Float(length * channelCount)) : 0
            let level = min(max(rms * 5.0, 0.0), 1.0)
            onAudioLevelUpdate?(level)
        }

        // Convert if needed and write to CAF
        if let converter = self.converter, let targetFormat = self.targetFormat {
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 100)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                recordCaptureError(
                    VoiceFailure(
                        stage: .audioCapture,
                        code: .audioEncodingFailed,
                        retryClass: .afterUserAction,
                        artifactState: .partial,
                        userAction: .retryWithOtherProvider,
                        redactedDetail: "Could not allocate the converted audio buffer"
                    ),
                    droppedFrames: Int64(buffer.frameLength)
                )
                return
            }

            var error: NSError?
            var allConsumed = false
            converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                if allConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                allConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if let conversionError = error {
                recordCaptureError(
                    VoiceFailure(
                        stage: .audioCapture,
                        code: .audioEncodingFailed,
                        retryClass: .afterUserAction,
                        artifactState: .partial,
                        userAction: .retryWithOtherProvider,
                        redactedDetail: "Audio conversion failed: \(conversionError.localizedDescription)"
                    ),
                    droppedFrames: Int64(buffer.frameLength)
                )
                return
            }
            guard outputBuffer.frameLength > 0 else { return }
            writeAndPublish(outputBuffer)
        } else {
            writeAndPublish(buffer)
        }
    }

    private func writeAndPublish(_ buffer: AVAudioPCMBuffer) {
        guard let writer else {
            recordCaptureError(
                VoiceFailure(
                    stage: .audioCapture,
                    code: .audioEncodingFailed,
                    retryClass: .afterUserAction,
                    artifactState: .partial,
                    userAction: .retryWithOtherProvider,
                    redactedDetail: "CAF writer unavailable while capture was active"
                ),
                droppedFrames: Int64(buffer.frameLength)
            )
            return
        }

        do {
            try writer.write(buffer: buffer)
            acceptedFrames += Int64(buffer.frameLength)
            onPCMBuffer?(buffer)
        } catch {
            recordCaptureError(
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

    private func recordCaptureError(_ error: VoiceFailure, droppedFrames: Int64) {
        self.droppedFrames += max(0, droppedFrames)
        guard captureError == nil else { return }
        captureError = error
        DevTypeLog.voice.error(
            "[Voice] capture stopped accepting audio code=\(error.code.rawValue, privacy: .public) droppedFrames=\(self.droppedFrames, privacy: .public)"
        )
    }

    public func stopCapture() async throws -> AudioArtifact {
        guard isCapturing, let engine = audioEngine, let writer = self.writer, let sessionDir = captureDirectory else {
            throw VoiceFailure(stage: .audioFinalization, code: .zeroFramesCaptured, redactedDetail: "Capture was not active")
        }

        isCapturing = false

        // Stop input tap and engine
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil

        // Finalize CAF writer before reporting a conversion/write failure, so the partial file is
        // still a valid recovery artifact and the writer cannot remain open across sessions.
        let finalStats: (totalFrames: Int64, sha256Hex: String, byteCount: Int64)
        do {
            finalStats = try writer.finalize()
        } catch {
            self.writer = nil
            self.captureDirectory = nil
            self.captureError = nil
            throw error
        }
        self.writer = nil
        self.captureDirectory = nil

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
            gapCount: Int(droppedFrames)
        )

        return artifact
    }

    public func cancelCapture() {
        isCapturing = false
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        if let writer {
            do {
                _ = try writer.finalize()
            } catch {
                DevTypeLog.voice.error(
                    "[Voice] failed to finalize cancelled CAF capture: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        writer = nil
        converter = nil
        targetFormat = nil
        captureDirectory = nil
        captureError = nil
    }
}
