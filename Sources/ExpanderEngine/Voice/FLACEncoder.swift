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
            guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
                throw FLACEncoderError.invalidFormat("Cannot convert from \(inputFormat) to 16kHz mono")
            }
            
            let ratio = 16000.0 / inputFormat.sampleRate
            let targetCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: targetCapacity) else {
                throw FLACEncoderError.conversionFailed("Failed to allocate converted buffer")
            }
            
            var error: NSError?
            var isDone = false
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if isDone {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                isDone = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            
            if let error {
                throw FLACEncoderError.conversionFailed(error.localizedDescription)
            }
            bufferToWrite = convertedBuffer
        }
        
        return try finishOutputFile(
            outputURL: outputURL,
            inputURL: inputURL,
            startTime: startTime
        ) {
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            try outputFile.write(from: bufferToWrite)
        }
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
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            try outputFile.write(from: buffer)
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
