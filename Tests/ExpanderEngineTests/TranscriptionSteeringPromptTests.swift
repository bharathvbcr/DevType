import XCTest
@testable import ExpanderEngine

final class TranscriptionSteeringPromptTests: XCTestCase {

    func testVerbatimPrompt() {
        let prompt = TranscriptionSteeringPrompt.build(vocabulary: [:], tone: .neutral, verbatim: true)
        XCTAssertTrue(prompt.contains("Transcribe verbatim"))
        XCTAssertFalse(prompt.contains("Apply spoken self-corrections"))
    }

    func testStandardPromptIncludesSystemInstructions() {
        let prompt = TranscriptionSteeringPrompt.build(vocabulary: [:], tone: .neutral, verbatim: false)
        XCTAssertTrue(prompt.contains("Output only the transcript in written form"))
        XCTAssertTrue(prompt.contains("Apply spoken self-corrections"))
        XCTAssertTrue(prompt.contains("Remove filler words"))
    }

    func testVocabularyBlockAssembly() {
        let vocab = [
            "dev type": "DevType",
            "k8s": "Kubernetes"
        ]
        let prompt = TranscriptionSteeringPrompt.build(vocabulary: vocab, tone: .neutral, verbatim: false)
        XCTAssertTrue(prompt.contains("Spell these terms exactly"))
        XCTAssertTrue(prompt.contains("\"dev type\" → \"DevType\""))
        XCTAssertTrue(prompt.contains("\"k8s\" → \"Kubernetes\""))
    }

    func testToneCategoryBlocks() {
        let emailPrompt = TranscriptionSteeringPrompt.build(vocabulary: [:], tone: .email, verbatim: false)
        XCTAssertTrue(emailPrompt.contains("Tone: professional email"))

        let chatPrompt = TranscriptionSteeringPrompt.build(vocabulary: [:], tone: .workChat, verbatim: false)
        XCTAssertTrue(chatPrompt.contains("Tone: casual-professional chat message"))

        let codePrompt = TranscriptionSteeringPrompt.build(vocabulary: [:], tone: .code, verbatim: false)
        XCTAssertTrue(codePrompt.contains("Technical dictation"))
    }

    func testToneCategoryBundleIDMapping() {
        XCTAssertEqual(ToneCategory.category(forBundleID: "com.apple.mail"), .email)
        XCTAssertEqual(ToneCategory.category(forBundleID: "com.google.Gmail"), .email)
        XCTAssertEqual(ToneCategory.category(forBundleID: "com.tinyspeck.slackmacgap"), .workChat)
        XCTAssertEqual(ToneCategory.category(forBundleID: "com.apple.MobileSMS"), .personalChat)
        XCTAssertEqual(ToneCategory.category(forBundleID: "com.apple.dt.Xcode"), .code)
        XCTAssertEqual(ToneCategory.category(forBundleID: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(ToneCategory.category(forBundleID: "unknown.app"), .neutral)
        XCTAssertEqual(ToneCategory.category(forBundleID: nil), .neutral)
    }
}
