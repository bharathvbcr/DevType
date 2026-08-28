import Foundation
import AVFoundation

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
    private var drainTimer: Task<Void, Never>?

    public var onAudioLevelUpdate: (@Sendable (Float) -> Void)?
    public var onPCMBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    private init() {}

    public static func checkMicrophonePermission() -> Bool {
        #if os(macOS)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .authorized
        #else
        return true
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
        self.bufferPool.reset()

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
            Task {
                await self.handleAudioCallback(buffer: buffer, sampleTime: Double(time.sampleTime))
            }
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
    }

    private func handleAudioCallback(buffer: AVAudioPCMBuffer, sampleTime: Double) {
        guard isCapturing else { return }

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
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

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

            if error == nil && outputBuffer.frameLength > 0 {
                acceptedFrames += Int64(outputBuffer.frameLength)
                try? writer?.write(buffer: outputBuffer)
                onPCMBuffer?(outputBuffer)
            }
        } else {
            acceptedFrames += Int64(buffer.frameLength)
            try? writer?.write(buffer: buffer)
            onPCMBuffer?(buffer)
        }
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

        // Finalize CAF writer
        let finalStats = try writer.finalize()
        self.writer = nil

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
        _ = try? writer?.finalize()
        writer = nil
    }
}
