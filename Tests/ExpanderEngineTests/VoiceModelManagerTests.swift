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

    func testInvalidArtifactIsNotReportedAsMerelyMissing() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeVoiceModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let manager = VoiceModelManager(baseDirectory: baseDirectory)
        let modelURL = manager.modelFileURL(for: .voxtralMini4B)
        try FileManager.default.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("Invalid username or password.".utf8).write(to: modelURL)

        guard case .error(let message) = manager.status(for: .voxtralMini4B) else {
            return XCTFail("A present but invalid artifact must be distinguished from a model that was never downloaded.")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("invalid"))
        XCTAssertThrowsError(try manager.installLocalModel(from: modelURL, for: .funASRNano)) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("invalid"))
        }
    }
}
