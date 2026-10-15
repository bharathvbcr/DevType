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
