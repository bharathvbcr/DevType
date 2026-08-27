import XCTest
@testable import ExpanderEngine

final class VoiceStreamingDiffTests: XCTestCase {

    // MARK: - 1. Monotonic Progressive Typing (Zero Erase)

    func testMonotonicAppendHasZeroErase() {
        let step1 = VoiceProgressiveTypingEngine.computeDiff(currentInjectedText: "", targetTranscript: "Hello")
        XCTAssertEqual(step1.eraseCount, 0)
        XCTAssertEqual(step1.textToInject, "Hello")
        XCTAssertEqual(step1.resultingText, "Hello")

        let step2 = VoiceProgressiveTypingEngine.computeDiff(currentInjectedText: "Hello", targetTranscript: "Hello world")
        XCTAssertEqual(step2.eraseCount, 0)
        XCTAssertEqual(step2.textToInject, " world")
        XCTAssertEqual(step2.resultingText, "Hello world")

        let step3 = VoiceProgressiveTypingEngine.computeDiff(currentInjectedText: "Hello world", targetTranscript: "Hello world, how are you?")
        XCTAssertEqual(step3.eraseCount, 0)
        XCTAssertEqual(step3.textToInject, ", how are you?")
        XCTAssertEqual(step3.resultingText, "Hello world, how are you?")
    }

    // MARK: - 2. Pause & Multi-Utterance Append (The Reported Bug)

    func testMultiUtteranceAcrossPauseNeverErasesEarlierText() {
        // Utterance 1: "We are discussing the roadmap."
        let utterance1 = "We are discussing the roadmap."
        let diff1 = VoiceProgressiveTypingEngine.computeDiff(currentInjectedText: "", targetTranscript: utterance1)
        XCTAssertEqual(diff1.eraseCount, 0)
        XCTAssertEqual(diff1.resultingText, "We are discussing the roadmap.")

        // Speaker pauses for 2 seconds...
        // Utterance 2 arrives: "Next week we deploy."
        let combined = VoiceProgressiveTypingEngine.combineUtterances(
            committed: [utterance1],
            activePartial: "Next week we deploy."
        )
        XCTAssertEqual(combined, "We are discussing the roadmap. Next week we deploy.")

        let diff2 = VoiceProgressiveTypingEngine.computeDiff(
            currentInjectedText: diff1.resultingText,
            targetTranscript: combined
        )

        // Must NOT erase utterance 1!
        XCTAssertEqual(diff2.eraseCount, 0, "Pause must not erase earlier sentence")
        XCTAssertEqual(diff2.textToInject, " Next week we deploy.")
        XCTAssertEqual(diff2.resultingText, "We are discussing the roadmap. Next week we deploy.")

        // Speaker pauses again...
        // Utterance 3 arrives: "All tests are green."
        let combined3 = VoiceProgressiveTypingEngine.combineUtterances(
            committed: [utterance1, "Next week we deploy."],
            activePartial: "All tests are green."
        )
        let diff3 = VoiceProgressiveTypingEngine.computeDiff(
            currentInjectedText: diff2.resultingText,
            targetTranscript: combined3
        )

        XCTAssertEqual(diff3.eraseCount, 0)
        XCTAssertEqual(diff3.textToInject, " All tests are green.")
        XCTAssertEqual(diff3.resultingText, "We are discussing the roadmap. Next week we deploy. All tests are green.")
    }

    // MARK: - 3. Localized Acoustic Tail Revision

    func testLocalizedAcousticRevisionOnlyErasesDivergentTail() {
        // recognizer thought "Hello world there"
        let current = "Hello world there"
        // recognizer revises acoustic model to "Hello world here"
        let revised = "Hello world here"

        let diff = VoiceProgressiveTypingEngine.computeDiff(currentInjectedText: current, targetTranscript: revised)

        // Only "there" (5 characters) should be erased, NOT the 17-character full string!
        XCTAssertEqual(diff.eraseCount, 5)
        XCTAssertEqual(diff.textToInject, "here")
        XCTAssertEqual(diff.resultingText, "Hello world here")
    }

    // MARK: - 4. Safety Invariants (Erase Bounded)

    func testEraseCountNeverExceedsCurrentInjectedLength() {
        let diff = VoiceProgressiveTypingEngine.computeDiff(
            currentInjectedText: "Short",
            targetTranscript: "Completely different text"
        )
        XCTAssertLessThanOrEqual(diff.eraseCount, "Short".count)
        XCTAssertEqual(diff.eraseCount, 5)
        XCTAssertEqual(diff.textToInject, "Completely different text")
        XCTAssertEqual(diff.resultingText, "Completely different text")
    }

    // MARK: - 5. Identical Transcript No-Op

    func testIdenticalTranscriptYieldsNoOp() {
        let text = "Exactly identical text"
        let diff = VoiceProgressiveTypingEngine.computeDiff(currentInjectedText: text, targetTranscript: text)
        XCTAssertEqual(diff.eraseCount, 0)
        XCTAssertEqual(diff.textToInject, "")
        XCTAssertEqual(diff.resultingText, text)
    }

    // MARK: - 6. Unicode & Complex Emoji Invariants

    func testUnicodeAndEmojiDiffing() {
        let current = "Status: 🚀 in progress"
        let target = "Status: 🚀 in progress and verified ✅"

        let diff = VoiceProgressiveTypingEngine.computeDiff(currentInjectedText: current, targetTranscript: target)
        XCTAssertEqual(diff.eraseCount, 0)
        XCTAssertEqual(diff.textToInject, " and verified ✅")
        XCTAssertEqual(diff.resultingText, "Status: 🚀 in progress and verified ✅")
    }

    // MARK: - 7. Utterance Combination Edge Cases

    func testUtteranceCombinationFormatting() {
        // Committed without trailing punctuation should get a space
        let res1 = VoiceProgressiveTypingEngine.combineUtterances(
            committed: ["Hello world", "How are you"],
            activePartial: "I am fine"
        )
        XCTAssertEqual(res1, "Hello world How are you I am fine")

        // Committed with trailing period should format cleanly
        let res2 = VoiceProgressiveTypingEngine.combineUtterances(
            committed: ["First sentence.", "Second sentence."],
            activePartial: "Third sentence."
        )
        XCTAssertEqual(res2, "First sentence. Second sentence. Third sentence.")

        // Empty committed
        let res3 = VoiceProgressiveTypingEngine.combineUtterances(
            committed: [],
            activePartial: "Only partial"
        )
        XCTAssertEqual(res3, "Only partial")

        // Empty active partial
        let res4 = VoiceProgressiveTypingEngine.combineUtterances(
            committed: ["First.", "Second."],
            activePartial: ""
        )
        XCTAssertEqual(res4, "First. Second.")
    }
}
