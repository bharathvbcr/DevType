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
}
