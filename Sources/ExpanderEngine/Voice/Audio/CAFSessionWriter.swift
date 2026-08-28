import Foundation
import AVFoundation
import CommonCrypto

public final class CAFSessionWriter: @unchecked Sendable {
    public let outputURL: URL
    public let targetFormat: AVAudioFormat
    private var audioFile: AVAudioFile?
    private var totalFramesWritten: Int64 = 0
    private var sha256Context = CC_SHA256_CTX()
    private let serialQueue = DispatchQueue(label: "com.devtype.voice.cafwriter", qos: .userInitiated)
    private var isClosed = false

    public init(outputURL: URL, sampleRate: Double = 16000, channelCount: AVAudioChannelCount = 1) throws {
        self.outputURL = outputURL
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channelCount, interleaved: true) else {
            throw VoiceFailure(stage: .audioCapture, code: .audioEncodingFailed, redactedDetail: "Could not create target AVAudioFormat for CAF writer")
        }
        self.targetFormat = format

        // Prepare directory
        let dir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o700])

        // Remove old file if exists
        try? FileManager.default.removeItem(at: outputURL)

        // Initialize audio file for writing
        let settings = format.settings
        self.audioFile = try AVAudioFile(forWriting: outputURL, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        CC_SHA256_Init(&self.sha256Context)
    }

    public func write(buffer: AVAudioPCMBuffer) throws {
        try serialQueue.sync {
            guard !isClosed, let file = audioFile else { return }
            try file.write(from: buffer)
            totalFramesWritten += Int64(buffer.frameLength)

            // Update digest from buffer bytes
            if let int16Data = buffer.int16ChannelData {
                let byteCount = Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
                _ = CC_SHA256_Update(&sha256Context, int16Data[0], CC_LONG(byteCount))
            }
        }
    }

    public func finalize() throws -> (totalFrames: Int64, sha256Hex: String, byteCount: Int64) {
        try serialQueue.sync {
            guard !isClosed else {
                throw VoiceFailure(stage: .audioFinalization, code: .audioEncodingFailed, redactedDetail: "CAF writer already finalized")
            }
            isClosed = true
            audioFile = nil // Flushes and closes header

            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256_Final(&digest, &sha256Context)
            let sha256Hex = digest.map { String(format: "%02x", $0) }.joined()

            let attributes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)) ?? [:]
            let byteCount = (attributes[.size] as? Int64) ?? 0

            return (totalFramesWritten, sha256Hex, byteCount)
        }
    }
}
