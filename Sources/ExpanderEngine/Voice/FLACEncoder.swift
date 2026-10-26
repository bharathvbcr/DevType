import Foundation
import AVFoundation

/// Errors that can occur during FLAC encoding.
public enum FLACEncoderError: Error, Equatable, Sendable {
    case emptyAudio
    case invalidFormat(String)
    case conversionFailed(String)
    case fileWriteFailed(String)
}

/// FLACEncoder handles encoding of audio data to FLAC format with automatic sample rate/channel conversion.
public enum FLACEncoder {
    
    /// Result of an encoding operation
    public struct EncodingResult: Sendable {
        public let url: URL
        public let byteCount: Int64
        public let encodeSeconds: TimeInterval
        
        public init(url: URL, byteCount: Int64, encodeSeconds: TimeInterval) {
            self.url = url
            self.byteCount = byteCount
            self.encodeSeconds = encodeSeconds
        }
    }
    
    /// Target format: 16kHz Mono 16-bit PCM for FLAC container.
    public static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000.0, channels: 1, interleaved: false)!
    }
    
    /// Encodes an existing audio file to FLAC
    public static func encode(inputURL: URL, outputURL: URL) throws -> EncodingResult {
        let startTime = Date()
        
        let inputFile = try AVAudioFile(forReading: inputURL)
        guard inputFile.length > 0 else {
            throw FLACEncoderError.emptyAudio
        }
        
        let inputFormat = inputFile.processingFormat
        let target = targetFormat
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1
        ]
        
        let frameCapacity = AVAudioFrameCount(inputFile.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity) else {
            throw FLACEncoderError.conversionFailed("Failed to allocate input buffer")
        }
        
        try inputFile.read(into: inputBuffer)
        
        // Convert to target 16kHz mono format if necessary
        let bufferToWrite: AVAudioPCMBuffer
        if inputFormat.sampleRate == 16000.0 && inputFormat.channelCount == 1 && inputFormat.commonFormat == .pcmFormatInt16 {
            bufferToWrite = inputBuffer
        } else {
            bufferToWrite = try resample(inputBuffer, from: inputFormat, to: target)
        }

        return try finishOutputFile(
            outputURL: outputURL,
            inputURL: inputURL,
            startTime: startTime
        ) {
            try writeFLAC(bufferToWrite, to: outputURL, settings: outputSettings)
        }
    }

    /// Converts one whole in-memory buffer to `target`, including the converter's held tail.
    ///
    /// A sample-rate converter withholds its filter tail until it is given more input or told the
    /// input has ended (`AVAudioConverter.h`). Answering the second input request with
    /// `.noDataNow` leaves that tail inside the converter and silently shortens every resampled
    /// upload, so the second request reports `.endOfStream`.
    private static func resample(
        _ input: AVAudioPCMBuffer,
        from inputFormat: AVAudioFormat,
        to target: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw FLACEncoderError.invalidFormat("Cannot convert from \(inputFormat) to 16kHz mono")
        }

        let ratio = target.sampleRate / inputFormat.sampleRate
        // Round up and leave headroom: the flush emits the converter's priming/filter tail on top
        // of the proportional output.
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw FLACEncoderError.conversionFailed("Failed to allocate converted buffer")
        }

        var error: NSError?
        var suppliedInput = false
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            throw FLACEncoderError.conversionFailed(error.localizedDescription)
        }
        guard status != .error else {
            throw FLACEncoderError.conversionFailed("AVAudioConverter reported an error without detail")
        }
        return converted
    }

    /// The system FLAC encoder emits nothing for a stream shorter than one block: the file it
    /// leaves behind is a 42-byte header with no audio (verified on macOS 27: 4,607 frames at
    /// 16 kHz produce it, 4,608 produce a valid file), yet `AVAudioFile.write` reports success.
    /// Pad a short buffer with trailing digital silence up to one block, then read the file back so
    /// an unreadable or short result is an error instead of a "successful" empty upload.
    private static let minimumFLACFrames: AVAudioFrameCount = 4_608

    private static func writeFLAC(
        _ buffer: AVAudioPCMBuffer,
        to outputURL: URL,
        settings: [String: Any]
    ) throws {
        let toWrite = try paddedToMinimumBlock(buffer)
        let expectedFrames = AVAudioFramePosition(toWrite.frameLength)
        do {
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            try outputFile.write(from: toWrite)
        }
        // The writer is released at the end of the scope above, which finalizes the stream.
        let written: AVAudioFramePosition
        do {
            written = try AVAudioFile(forReading: outputURL).length
        } catch {
            throw FLACEncoderError.fileWriteFailed("FLAC output is unreadable: \(error.localizedDescription)")
        }
        guard written >= expectedFrames else {
            throw FLACEncoderError.fileWriteFailed(
                "FLAC output holds \(written) of \(expectedFrames) frames"
            )
        }
    }

    private static func paddedToMinimumBlock(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard buffer.frameLength < minimumFLACFrames else { return buffer }
        guard let padded = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: minimumFLACFrames),
              let source = buffer.int16ChannelData,
              let destination = padded.int16ChannelData else {
            throw FLACEncoderError.conversionFailed("Failed to allocate padded buffer")
        }
        padded.frameLength = minimumFLACFrames
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(repeating: 0, count: Int(minimumFLACFrames))
            destination[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        return padded
    }
    
    /// Encodes raw PCM data to FLAC
    public static func encode(pcmData: Data, sampleRate: Double, outputURL: URL) throws -> EncodingResult {
        guard !pcmData.isEmpty else {
            throw FLACEncoderError.emptyAudio
        }
        
        let startTime = Date()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw FLACEncoderError.invalidFormat("Failed to create PCM format with sample rate \(sampleRate)")
        }
        
        let frameCount = AVAudioFrameCount(pcmData.count / 2) // Int16 is 2 bytes
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw FLACEncoderError.emptyAudio
        }
        buffer.frameLength = frameCount
        
        pcmData.withUnsafeBytes { rawBufferPointer in
            if let int16Pointer = rawBufferPointer.bindMemory(to: Int16.self).baseAddress,
               let channelData = buffer.int16ChannelData?[0] {
                channelData.update(from: int16Pointer, count: Int(frameCount))
            }
        }
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1
        ]
        
        return try finishOutputFile(
            outputURL: outputURL,
            inputURL: nil,
            startTime: startTime
        ) {
            try writeFLAC(buffer, to: outputURL, settings: outputSettings)
        }
    }

    /// Deletes an output file this call created when a later step throws. A throw before the file
    /// exists leaves a pre-existing path alone, and the input URL is never deleted.
    private static func finishOutputFile(
        outputURL: URL,
        inputURL: URL?,
        startTime: Date,
        write: () throws -> Void
    ) throws -> EncodingResult {
        let existedBefore = FileManager.default.fileExists(atPath: outputURL.path)
        do {
            try write()
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let byteCount = (attributes[.size] as? Int64) ?? Int64((try? Data(contentsOf: outputURL).count) ?? 0)
            return EncodingResult(
                url: outputURL,
                byteCount: byteCount,
                encodeSeconds: Date().timeIntervalSince(startTime)
            )
        } catch {
            let created = !existedBefore && FileManager.default.fileExists(atPath: outputURL.path)
            let isInput = inputURL.map { sameFile($0, outputURL) } ?? false
            if created && !isInput {
                try? FileManager.default.removeItem(at: outputURL)
            }
            throw error
        }
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
