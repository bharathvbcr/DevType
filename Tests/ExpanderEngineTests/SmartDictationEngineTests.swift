import XCTest
@testable import ExpanderEngine

final class SmartDictationEngineTests: XCTestCase {

    func testDisfluencyRemoval() {
        let raw = "I think, um, we should, uh, launch tomorrow, like, at noon."
        let cleaned = SmartDictationEngine.filterDisfluencies(raw)
        XCTAssertEqual(cleaned, "I think we should launch tomorrow at noon.")

        let raw2 = "Uh, actually, er, that is great."
        let cleaned2 = SmartDictationEngine.filterDisfluencies(raw2)
        XCTAssertEqual(cleaned2, "Actually that is great.")
    }

    func testThoughtRevisionResolution() {
        let raw = "Let us meet at 1:00 PM... actually, make it 2:00 PM."
        let revised = SmartDictationEngine.resolveSelfCorrections(raw)
        XCTAssertEqual(revised, "make it 2:00 PM.")

        let raw2 = "Send the email to Alice... no wait, send it to Bob."
        let revised2 = SmartDictationEngine.resolveSelfCorrections(raw2)
        XCTAssertEqual(revised2, "send it to Bob.")

        let normal = "I would like to order a pizza and salad."
        let unchanged = SmartDictationEngine.resolveSelfCorrections(normal)
        XCTAssertEqual(unchanged, normal)
    }

    func testConversationalDiscoursePreservedWithoutDeletion() {
        let conversational1 = "We have finished the report, actually we delivered it yesterday."
        let result1 = SmartDictationEngine.resolveSelfCorrections(conversational1)
        XCTAssertTrue(result1.contains("finished the report"), "Expected earlier clause to be preserved, got: \(result1)")

        let conversational2 = "I arrived at the office, sorry for being a few minutes late."
        let result2 = SmartDictationEngine.resolveSelfCorrections(conversational2)
        XCTAssertTrue(result2.contains("arrived at the office"), "Expected earlier clause to be preserved, got: \(result2)")

        let conversational3 = "The system is working properly, or rather it is performing even better than expected."
        let result3 = SmartDictationEngine.resolveSelfCorrections(conversational3)
        XCTAssertTrue(result3.contains("working properly"), "Expected earlier clause to be preserved, got: \(result3)")
    }

    func testCustomVocabularyReplacement() {
        let customDict = [
            "dev type": "DevType",
            "next js": "Next.js",
            "chat gpt": "ChatGPT"
        ]
        let raw = "I love using dev type and next js with chat gpt."
        let replaced = SmartDictationEngine.applyCustomDictionary(raw, dictionary: customDict)
        XCTAssertEqual(replaced, "I love using DevType and Next.js with ChatGPT.")
    }

    func testToneStylingCodeIdentifier() {
        let text1 = "user profile manager"
        let styled1 = SmartDictationEngine.applyTone(text1, tone: .code)
        XCTAssertEqual(styled1, "userProfileManager")

        let text2 = "get auth token"
        let styled2 = SmartDictationEngine.applyTone(text2, tone: .code)
        XCTAssertEqual(styled2, "getAuthToken")
    }

    func testToneStylingEmailAndChat() {
        let text = "thanks for sending the files. i will review them tomorrow"
        let email = SmartDictationEngine.applyTone(text, tone: .email)
        XCTAssertTrue(email.contains("Thanks for sending the files"))

        let chat = SmartDictationEngine.applyTone(text, tone: .chat)
        XCTAssertTrue(chat.contains("Thanks"))
    }

    func testPunctuationAndCapitalization() {
        let raw = "hello world this is a test"
        let formatted = SmartDictationEngine.formatPunctuationAndCapitalization(raw)
        XCTAssertEqual(formatted, "Hello world this is a test.")
    }

    func testFullPipelinePolish() {
        let raw = "um let us meet at 3pm... actually make it 4pm with dev type"
        let customDict = ["dev type": "DevType"]

        let result = SmartDictationEngine.process(
            rawTranscript: raw,
            tone: .natural,
            customDictionary: customDict,
            removeDisfluencies: true,
            autoPunctuate: true
        )

        XCTAssertTrue(result.contains("DevType"))
        XCTAssertFalse(result.contains("3pm"))
        XCTAssertTrue(result.contains("4pm"))
        XCTAssertFalse(result.lowercased().hasPrefix("um"))
    }

    func testVerbatimToneBypassesStyling() {
        let raw = "um like testing verbatim"
        let result = SmartDictationEngine.process(
            rawTranscript: raw,
            tone: .verbatim,
            customDictionary: [:],
            removeDisfluencies: false,
            autoPunctuate: false
        )
        XCTAssertEqual(result, raw)
    }
}
