import XCTest
@testable import ExpanderEngine

final class VoicePreferencesTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        VoicePreferences.resetAllForTesting()
    }

    func testDefaultPreferences() {
        XCTAssertEqual(VoicePreferences.selectedModel, .voxtralMini4B)
        XCTAssertEqual(VoicePreferences.tone, .natural)
        XCTAssertTrue(VoicePreferences.isAutoPunctuateEnabled)
        XCTAssertTrue(VoicePreferences.isRemoveDisfluenciesEnabled)
        XCTAssertTrue(VoicePreferences.isSoundFeedbackEnabled)
        XCTAssertFalse(VoicePreferences.isHandsFreeModeEnabled)
    }

    func testCustomDictionaryPersistence() {
        VoicePreferences.addDictionaryEntry(spoken: "dev type", replacement: "DevType")
        let dict = VoicePreferences.customDictionary
        XCTAssertEqual(dict["dev type"], "DevType")

        VoicePreferences.removeDictionaryEntry(spoken: "dev type")
        let dictAfter = VoicePreferences.customDictionary
        XCTAssertNil(dictAfter["dev type"])
    }

    func testTonePersistence() {
        VoicePreferences.tone = .email
        XCTAssertEqual(VoicePreferences.tone, .email)

        VoicePreferences.tone = .code
        XCTAssertEqual(VoicePreferences.tone, .code)
    }

    func testModelPersistence() {
        VoicePreferences.selectedModel = .funASRNano
        XCTAssertEqual(VoicePreferences.selectedModel, .funASRNano)

        VoicePreferences.selectedModel = .appleSpeech
        XCTAssertEqual(VoicePreferences.selectedModel, .appleSpeech)
    }
}
