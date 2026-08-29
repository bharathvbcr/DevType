import XCTest
@testable import ExpanderEngine

/// Coverage for the unified sanitizer, ported from the two implementations it replaced
/// (`TranscriptionValidationGate.stripArtifacts` and `LocalLLMCleanupClient.sanitizeOutput`)
/// plus the cases that fell between them.
final class CorrectionOutputSanitizerTests: XCTestCase {

    private func sanitize(_ text: String) -> String {
        CorrectionOutputSanitizer.sanitize(text)
    }

    // MARK: - Reasoning blocks

    func testStripsReasoningTags() {
        XCTAssertEqual(
            sanitize("<think>\nThe user said meeting at 2pm.\nLet's clean it up.\n</think>Let's meet at 2:00 PM."),
            "Let's meet at 2:00 PM."
        )
        XCTAssertEqual(
            sanitize("<thought>Formatting as code.</thought>userProfileController"),
            "userProfileController"
        )
        XCTAssertEqual(sanitize("[think]internal[/think]Ship it."), "Ship it.")
        XCTAssertEqual(sanitize("<reasoning>weighing options</reasoning>Done."), "Done.")
    }

    // MARK: - Fences

    func testStripsCodeFences() {
        XCTAssertEqual(sanitize("```\nThis is a transcript\n```"), "This is a transcript")
        XCTAssertEqual(sanitize("```swift\nlet x = 1\n```"), "let x = 1")
        XCTAssertEqual(sanitize("```\nHere is some text\n```"), "Here is some text")
    }

    /// A fence with no trailing newline before the closing marker still unwraps. A
    /// single-line fence is read as content rather than as a bare language tag — emptying
    /// the transcript is the worse failure of the two.
    func testStripsSingleLineFence() {
        XCTAssertEqual(sanitize("```text```"), "text")
        XCTAssertEqual(sanitize("```\nhello```"), "hello")
    }

    /// Models stack wrappers: a label around a fence, quotes around a label. Unwrapping
    /// must not depend on the order they were stacked in.
    func testUnwrapsNestedWrappers() {
        XCTAssertEqual(sanitize("Result: ```code```"), "code")
        XCTAssertEqual(sanitize("```\nCleaned: hello\n```"), "hello")
        XCTAssertEqual(sanitize("\"Transcript: hello\""), "hello")
        XCTAssertEqual(sanitize("<think>x</think>Result: \"done\""), "done")
    }

    // MARK: - Preambles

    func testStripsPreambleLabels() {
        XCTAssertEqual(sanitize("CLEAN: Hello world"), "Hello world")
        XCTAssertEqual(sanitize("Clean: Hello world"), "Hello world")
        XCTAssertEqual(sanitize("Transcript: Hello world"), "Hello world")
        XCTAssertEqual(sanitize("TRANSCRIPT: Hello world"), "Hello world")
        XCTAssertEqual(sanitize("Cleaned: Hello world."), "Hello world.")
        XCTAssertEqual(sanitize("Here is the cleaned text: Let's ship it."), "Let's ship it.")
        XCTAssertEqual(sanitize("Transcript: Thank you for your email."), "Thank you for your email.")
        XCTAssertEqual(sanitize("Result: shipped"), "shipped")
    }

    /// The longest matching label wins, so the shorter one is not left behind as residue.
    func testLongestPreambleWins() {
        XCTAssertEqual(sanitize("Here is the cleaned transcript: done"), "done")
    }

    // MARK: - Quotes

    func testStripsWrappingQuotes() {
        XCTAssertEqual(sanitize("\"Hello world\""), "Hello world")
        XCTAssertEqual(sanitize("“Hello world”"), "Hello world")
    }

    /// Quotation inside the sentence means the outer marks are content, not a wrapper.
    func testKeepsQuotesThatArePartOfTheSentence() {
        let quoted = "\"Ship it\" is what she said, then \"ship it again\""
        XCTAssertEqual(sanitize(quoted), quoted)
    }

    // MARK: - Passthrough

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(sanitize("Hello world"), "Hello world")
        XCTAssertEqual(sanitize("Run kubectl apply --no-verify now"), "Run kubectl apply --no-verify now")
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(sanitize(""), "")
        XCTAssertEqual(sanitize("   \n\t "), "")
    }

    // MARK: - Idempotence

    /// Sanitising twice must equal sanitising once; the correctors and the validator both
    /// run over this text, so a non-idempotent step would compound.
    func testSanitizeIsIdempotent() {
        let inputs = [
            "```\nCleaned: \"Hello\"\n```",
            "<think>x</think>Transcript: hi",
            "plain text",
            "\"quoted\"",
            "Result: ```code```"
        ]
        for input in inputs {
            let once = sanitize(input)
            XCTAssertEqual(sanitize(once), once, "Not idempotent for: \(input)")
        }
    }

    // MARK: - Never crashes on hostile input

    func testHostileInputIsSurvivable() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let fragments = ["```", "<think>", "</think>", "\"", "'", "Transcript:", "\n", "  ", "a", "🚀", "”", "“"]

        for _ in 0..<2000 {
            let count = Int(rng.next() % 12)
            let text = (0..<count).map { _ in fragments[Int(rng.next() % UInt64(fragments.count))] }.joined()
            let out = sanitize(text)
            XCTAssertLessThanOrEqual(out.count, text.count + 1, "Sanitizer grew the input: \(text)")
        }
    }
}
