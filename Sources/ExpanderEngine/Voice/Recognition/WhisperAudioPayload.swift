import Foundation
import AVFoundation

/// Converts captured audio into the format `whisper.cpp` reads natively.
///
/// Capture writes CAF, but whisper.cpp's own decoding path is 16 kHz mono 16-bit PCM WAV —
/// anything else depends on how the server was built and which decoders were linked in.
/// Converting here means the engine works against a stock `brew install whisper-cpp`
/// server rather than only against one built with extra codecs.
public enum WhisperAudioPayload {

    /// Reads `url` and returns 16 kHz mono 16-bit PCM WAV bytes.
    public static func wav16kMono(from url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw VoiceFailure(
                stage: .recognition,
                code: .audioEncodingFailed,
                redactedDetail: "Could not construct the 16 kHz mono target format"
            )
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw VoiceFailure(
                stage: .recognition,
                code: .audioEncodingFailed,
                redactedDetail: "No conversion path from the capture format to 16 kHz mono"
            )
        }

        var samples = Data()
        let sourceFrames = AVAudioFrameCount(4096)
        var reachedEnd = false

        while !reachedEnd {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(
                    Double(sourceFrames) * target.sampleRate / file.processingFormat.sampleRate + 1024
                )
            ) else { break }

            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard !reachedEnd,
                      let input = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: sourceFrames
                      ) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: sourceFrames)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }

            if let conversionError {
                throw VoiceFailure(
                    stage: .recognition,
                    code: .audioEncodingFailed,
                    redactedDetail: conversionError.localizedDescription
                )
            }

            if output.frameLength > 0, let channel = output.int16ChannelData {
                samples.append(
                    UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength))
                        .withMemoryRebound(to: UInt8.self) { Data($0) }
                )
            }

            if status == .endOfStream || (status == .inputRanDry && output.frameLength == 0) {
                break
            }
        }

        return wavContainer(pcm: samples, sampleRate: 16000, channels: 1, bitsPerSample: 16)
    }

    /// Wraps raw PCM in a canonical 44-byte RIFF/WAVE header.
    static func wavContainer(
        pcm: Data,
        sampleRate: Int32,
        channels: Int16,
        bitsPerSample: Int16
    ) -> Data {
        var header = Data()
        let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }

        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))              // PCM subchunk size
        append(UInt16(1))               // PCM format
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append(UInt16(blockAlign))
        append(UInt16(bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))

        return header + pcm
    }
}
