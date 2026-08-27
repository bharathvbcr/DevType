import XCTest
@testable import ExpanderEngine

final class VoiceModelManagerTests: XCTestCase {

    func testModelDescriptors() {
        let voxtral = VoiceModelType.voxtralMini4B.descriptor
        XCTAssertEqual(voxtral.name, "Mistral Voxtral Realtime (Mini 4B)")
        XCTAssertEqual(voxtral.vendor, "Mistral AI")
        XCTAssertTrue(voxtral.isRecommended)
        XCTAssertFalse(voxtral.expectedSha256.isEmpty)

        let funASR = VoiceModelType.funASRNano.descriptor
        XCTAssertEqual(funASR.name, "Fun-ASR-Nano (0.8B)")
        XCTAssertEqual(funASR.vendor, "Tongyi Lab (Alibaba)")
        XCTAssertFalse(funASR.expectedSha256.isEmpty)

        let apple = VoiceModelType.appleSpeech.descriptor
        XCTAssertEqual(apple.name, "Apple Speech (System)")
    }

    func testModelStatusQueries() {
        let manager = VoiceModelManager.shared

        // Apple speech is always ready
        let appleStatus = manager.status(for: .appleSpeech)
        if case .ready = appleStatus {
            XCTAssertTrue(true)
        } else {
            XCTFail("Apple Speech should always be ready")
        }
        XCTAssertTrue(manager.isModelReady(.appleSpeech))
    }

    func testStatusListenerCallbacks() {
        let manager = VoiceModelManager.shared
        let token = manager.addStatusListener { _, _ in }
        // Listener token is created
        XCTAssertNotNil(token)
        manager.removeStatusListener(token)
    }

    func testModelsStorageDirectoryExists() {
        let dir = VoiceModelManager.shared.modelsDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }
}
