import XCTest
@testable import ExpanderEngine

final class VoiceAudioRecorderTests: XCTestCase {

    func testTargetAudioFormat() {
        let recorder = VoiceAudioRecorder.shared
        let format = recorder.targetAudioFormat

        XCTAssertEqual(format.sampleRate, 16000.0)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
    }

    func testVoiceCacheDirectoryCreation() {
        let recorder = VoiceAudioRecorder.shared
        let cacheDir = recorder.voiceCacheDirectory

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.path))
    }

    func testCleanupOldJournalsDoesNotCrash() {
        let recorder = VoiceAudioRecorder.shared
        // Ensure calling cleanupOldJournals runs smoothly
        recorder.cleanupOldJournals()
    }

    func testAudioBufferHandlerRegistration() {
        let recorder = VoiceAudioRecorder.shared
        var received = false
        recorder.onAudioBuffer = { _ in
            received = true
        }
        XCTAssertNotNil(recorder.onAudioBuffer)
        recorder.onAudioBuffer = nil
        XCTAssertNil(recorder.onAudioBuffer)
        _ = received
    }
}
