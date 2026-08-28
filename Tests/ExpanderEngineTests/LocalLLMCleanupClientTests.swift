import XCTest
@testable import ExpanderEngine

final class LocalLLMCleanupClientTests: XCTestCase {

    func testSanitizeOutputStripsReasoningTags() {
        // DeepSeek R1 / Qwen style reasoning tags
        let rawWithThink = "<think>\nThe user said meeting at 2pm.\nLet's clean it up.\n</think>Let's meet at 2:00 PM."
        let sanitized = LocalLLMCleanupClient.sanitizeOutput(rawWithThink)
        XCTAssertEqual(sanitized, "Let's meet at 2:00 PM.")

        let rawWithThought = "<thought>Formatting as code.</thought>userProfileController"
        let sanitizedThought = LocalLLMCleanupClient.sanitizeOutput(rawWithThought)
        XCTAssertEqual(sanitizedThought, "userProfileController")
    }

    func testSanitizeOutputStripsCommonPreamblePrefixes() {
        XCTAssertEqual(
            LocalLLMCleanupClient.sanitizeOutput("Cleaned: Hello world."),
            "Hello world."
        )
        XCTAssertEqual(
            LocalLLMCleanupClient.sanitizeOutput("Here is the cleaned text: Let's ship it."),
            "Let's ship it."
        )
        XCTAssertEqual(
            LocalLLMCleanupClient.sanitizeOutput("Transcript: Thank you for your email."),
            "Thank you for your email."
        )
    }

    func testSanitizeOutputStripsCodeFences() {
        let fenced = "```\nHere is some text\n```"
        XCTAssertEqual(
            LocalLLMCleanupClient.sanitizeOutput(fenced),
            "Here is some text"
        )
    }

    func testBuildSystemPromptContainsFewShotExamples() {
        let client = LocalLLMCleanupClient()
        let prompt = client.buildSystemPrompt(tone: .email, customDictionary: ["k8s": "Kubernetes"])

        XCTAssertTrue(prompt.contains("Examples:"))
        XCTAssertTrue(prompt.contains("Raw:"))
        XCTAssertTrue(prompt.contains("Cleaned:"))
        XCTAssertTrue(prompt.contains("Tone: professional email"))
        XCTAssertTrue(prompt.contains("\"k8s\" -> \"Kubernetes\""))
    }

    func testLocalLLMCleanupFallback() async {
        let client = LocalLLMCleanupClient()
        // When local endpoint is offline, it falls back gracefully to SmartDictationEngine
        let result = await client.cleanup(
            rawTranscript: "umm let's meet at 1pm actually 2pm",
            tone: .neutral,
            customDictionary: ["dev type": "DevType"],
            timeoutSeconds: 0.1
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.contains("2pm") || result.contains("2:00 PM"))
    }
}
