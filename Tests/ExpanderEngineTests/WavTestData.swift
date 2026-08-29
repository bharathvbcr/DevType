import Foundation

/// PCM → WAV container, used by the FLAC encoder tests to synthesise input audio.
///
/// Lives in the test target because that is its only caller: production capture writes CAF
/// through `CAFSessionWriter`, so keeping this in `ExpanderEngine` would ship test-only
/// code in the shipping library.
enum WavTestData {
    static func createWavData(fromPCM pcmData: Data, sampleRate: Int32, channels: Int16, bitsPerSample: Int16) -> Data {
        var header = Data()
        let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let subchunk2Size = Int32(pcmData.count)
        let chunkSize = 36 + subchunk2Size

        // RIFF chunk descriptor
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
        header.append(contentsOf: "WAVE".utf8)

        // "fmt " sub-chunk
        header.append(contentsOf: "fmt ".utf8)
        let subchunk1Size: Int32 = 16
        header.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian) { Data($0) })
        let audioFormat: Int16 = 1 // PCM
        header.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // "data" sub-chunk
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: subchunk2Size.littleEndian) { Data($0) })
        header.append(pcmData)

        return header
    }
}
