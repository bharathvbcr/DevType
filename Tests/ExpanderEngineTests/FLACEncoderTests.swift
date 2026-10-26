import AVFoundation
import Darwin
import XCTest
@testable import ExpanderEngine

final class FLACEncoderTests: XCTestCase {

    func testEncodePCMDataToFLAC() throws {
        // Generate 100ms of 16kHz 16-bit mono sine wave PCM data
        let sampleRate: Double = 16000.0
        let durationSeconds: Double = 0.1
        let sampleCount = Int(sampleRate * durationSeconds)
        var pcmData = Data(capacity: sampleCount * 2)

        for i in 0..<sampleCount {
            let angle = 2.0 * Double.pi * 440.0 * Double(i) / sampleRate
            let sample = Int16(sin(angle) * 30000.0)
            pcmData.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Data($0) })
        }

        let tempDir = FileManager.default.temporaryDirectory
        let flacURL = tempDir.appendingPathComponent("test_\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: flacURL) }

        let result = try FLACEncoder.encode(pcmData: pcmData, sampleRate: sampleRate, outputURL: flacURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: flacURL.path))
        XCTAssertGreaterThan(result.byteCount, 0)
        XCTAssertGreaterThanOrEqual(result.encodeSeconds, 0.0)
        XCTAssertEqual(result.url, flacURL)
    }

    /// `AVAudioConverter` withholds the resampler's filter tail until it is told the input has
    /// ended (AVAudioConverter.h: held data is emitted only on more input or end-of-stream). An
    /// encoder that never signals `.endOfStream` silently truncates every resampled upload.
    func testResampledEncodeKeepsTheConverterTail() throws {
        for inputFrames in [14_400, 48_000, 96_000] {
            let inputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("flac-tail-in-\(UUID().uuidString).wav")
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("flac-tail-out-\(UUID().uuidString).flac")
            defer {
                try? FileManager.default.removeItem(at: inputURL)
                try? FileManager.default.removeItem(at: outputURL)
            }
            var pcm = Data(capacity: inputFrames * 2)
            for index in 0..<inputFrames {
                let sample = Int16(sin(Double(index) / 20.0) * 8_000.0)
                pcm.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Data($0) })
            }
            try WavTestData.createWavData(
                fromPCM: pcm, sampleRate: 48_000, channels: 1, bitsPerSample: 16
            ).write(to: inputURL)

            _ = try FLACEncoder.encode(inputURL: inputURL, outputURL: outputURL)

            let decoded = try AVAudioFile(forReading: outputURL)
            XCTAssertEqual(decoded.fileFormat.sampleRate, 16_000)
            // 48 kHz -> 16 kHz is an exact 3:1 ratio, so the expected count is exact.
            let expectedFrames = Int64((Double(inputFrames) / 3.0).rounded(.up))
            XCTAssertEqual(
                decoded.length, expectedFrames,
                "\(inputFrames) input frames at 48 kHz must yield \(expectedFrames) frames at 16 kHz"
            )
        }
    }

    /// The system FLAC encoder leaves a 42-byte, audio-less header for a stream shorter than one
    /// block (4,608 frames) while `AVAudioFile.write` reports success, so a short dictation used
    /// to upload as an unreadable "successful" file.
    func testClipsShorterThanOneFLACBlockStillProduceAReadableFile() throws {
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-short-in-\(UUID().uuidString).wav")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-short-out-\(UUID().uuidString).flac")
        let pcmOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-short-pcm-\(UUID().uuidString).flac")
        defer {
            for url in [inputURL, outputURL, pcmOutputURL] { try? FileManager.default.removeItem(at: url) }
        }
        let inputFrames = 4_800   // 100 ms at 48 kHz -> 1,600 frames at 16 kHz
        var pcm = Data(capacity: inputFrames * 2)
        for index in 0..<inputFrames {
            let sample = Int16(sin(Double(index) / 20.0) * 8_000.0)
            pcm.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Data($0) })
        }
        try WavTestData.createWavData(
            fromPCM: pcm, sampleRate: 48_000, channels: 1, bitsPerSample: 16
        ).write(to: inputURL)

        let resampled = try FLACEncoder.encode(inputURL: inputURL, outputURL: outputURL)
        let direct = try FLACEncoder.encode(
            pcmData: Data(pcm.prefix(4_800)), sampleRate: 16_000, outputURL: pcmOutputURL
        )

        XCTAssertGreaterThan(resampled.byteCount, 64, "a header-only file is 42 bytes")
        XCTAssertGreaterThan(direct.byteCount, 64)
        XCTAssertGreaterThanOrEqual(try AVAudioFile(forReading: outputURL).length, 1_600)
        XCTAssertGreaterThanOrEqual(try AVAudioFile(forReading: pcmOutputURL).length, 2_400)
    }

    func testEncodeLeavesPreexistingOutputUntouchedWhenInputIsMissing() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preexisting-\(UUID().uuidString).flac")
        let marker = Data("unrelated-output".utf8)
        try marker.write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).caf")

        XCTAssertThrowsError(try FLACEncoder.encode(inputURL: missing, outputURL: outputURL))
        XCTAssertEqual(try Data(contentsOf: outputURL), marker)
    }

    func testCreatedOutputIsRemovedWhenALaterWriteThrowsAndInputRemains() throws {
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-input-\(UUID().uuidString).wav")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-output-\(UUID().uuidString).flac")
        let frameCount = 50_000
        var pcm = Data(capacity: frameCount * 2)
        for index in 0..<frameCount {
            let sample = Int16(sin(Double(index) / 10.0) * 8_000.0)
            pcm.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Data($0) })
        }
        let wav = WavTestData.createWavData(fromPCM: pcm, sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        try wav.write(to: inputURL)
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        // ExtAudioFile creates the output before a large write returns. A 128-byte process
        // file-size limit is what makes that later write throw; the encoder has no test seam.
        // A tiny FLAC still fits in the write buffer and does not trip the limit.
        var previousLimit = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &previousLimit), 0)
        let previousSignal = signal(SIGXFSZ, SIG_IGN)
        defer { _ = signal(SIGXFSZ, previousSignal) }
        var limited = previousLimit
        limited.rlim_cur = 128
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &limited), 0)
        defer { _ = setrlimit(RLIMIT_FSIZE, &previousLimit) }

        XCTAssertThrowsError(try FLACEncoder.encode(inputURL: inputURL, outputURL: outputURL)) { error in
            XCTAssertFalse(error is FLACEncoderError, "write never started: \(error)")
        }
        _ = setrlimit(RLIMIT_FSIZE, &previousLimit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(try Data(contentsOf: inputURL), wav)
    }
}
