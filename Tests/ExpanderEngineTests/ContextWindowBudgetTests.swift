import XCTest
@testable import ExpanderEngine

/// Apple's on-device model has a 4096-token context window shared between the instructions,
/// the prompt and the response. A few minutes of continuous dictation runs straight past it,
/// and an over-long request throws `.exceededContextWindowSize` — the session cannot answer
/// at all, so a long dictation would silently lose cleanup entirely.
///
/// These cases pin the budgeting and chunking that keeps that from happening. They test the
/// pure arithmetic and splitting, which run on every OS; the model call itself needs
/// macOS 26 and Apple Intelligence enabled.
final class ContextWindowBudgetTests: XCTestCase {

    private typealias Corrector = FoundationLanguageModelCorrector

    // MARK: - Estimation

    /// The estimate must never come in *under* the true token count: over-estimating costs
    /// one extra chunk, under-estimating costs the whole correction.
    func testTokenEstimateIsConservative() {
        // English averages roughly four characters per token; the estimate uses three.
        let text = String(repeating: "a", count: 300)
        XCTAssertGreaterThanOrEqual(Corrector.estimatedTokens(text), 100)
        XCTAssertGreaterThan(
            Corrector.estimatedTokens(text), text.count / 4,
            "Estimate fell below a realistic tokeniser count"
        )
    }

    func testTokenEstimateHandlesEmptyAndTinyInput() {
        XCTAssertEqual(Corrector.estimatedTokens(""), 1)
        XCTAssertGreaterThanOrEqual(Corrector.estimatedTokens("a"), 1)
    }

    // MARK: - Budget

    /// The budget must leave room for the response, which for a cleanup task is about as
    /// long as the input.
    func testBudgetReservesRoomForInstructionsAndResponse() {
        let instructions = CorrectionPromptBuilder.systemPrompt(policy: CorrectionPolicy())
        let budget = Corrector.inputTokenBudget(instructions: instructions)

        XCTAssertGreaterThan(budget, 0)
        XCTAssertLessThan(
            budget * 2 + Corrector.estimatedTokens(instructions),
            Corrector.contextWindowTokens,
            "Input + response + instructions must fit the window with headroom"
        )
    }

    /// A huge instruction block must not produce a zero or negative budget.
    func testBudgetHasAFloorForOversizedInstructions() {
        let huge = String(repeating: "instruction ", count: 5000)
        XCTAssertGreaterThan(Corrector.inputTokenBudget(instructions: huge), 0)
    }

    // MARK: - Chunking

    func testShortTranscriptIsNotChunked() {
        let text = "Deploy the gateway at three."
        XCTAssertEqual(Corrector.chunk(text, budgetTokens: 1000), [text])
    }

    /// Every chunk must fit the budget, or the request it is sent in will be refused.
    func testEveryChunkFitsTheBudget() {
        let sentence = "This is a sentence of moderate length that a person might dictate. "
        let text = String(repeating: sentence, count: 200)
        let budget = 128

        let chunks = Corrector.chunk(text, budgetTokens: budget)
        XCTAssertGreaterThan(chunks.count, 1, "A long transcript must be split")

        for chunk in chunks {
            XCTAssertLessThanOrEqual(
                Corrector.estimatedTokens(chunk), budget,
                "Chunk of \(chunk.count) chars exceeds the \(budget)-token budget"
            )
        }
    }

    /// Nothing may be dropped — the user said all of it.
    func testChunkingPreservesEveryWord() {
        let text = (0..<400).map { "word\($0)" }.joined(separator: " ") + "."
        let chunks = Corrector.chunk(text, budgetTokens: 64)

        let originalWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let chunkedWords = chunks.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }

        XCTAssertEqual(chunkedWords, originalWords, "Chunking lost or reordered words")
    }

    /// Dictation without punctuation is one enormous "sentence". It must still split.
    func testUnpunctuatedDictationStillSplits() {
        let text = (0..<600).map { "word\($0)" }.joined(separator: " ")
        XCTAssertFalse(text.contains("."))

        let budget = 64
        let chunks = Corrector.chunk(text, budgetTokens: budget)

        XCTAssertGreaterThan(chunks.count, 1, "An unpunctuated transcript was never split")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(Corrector.estimatedTokens(chunk), budget)
        }

        let rejoined = chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(rejoined, text.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    func testUnbrokenUnicodeTranscriptSplitsWithoutLosingGraphemes() {
        let text = String(repeating: "界", count: 300)
        let chunks = Corrector.chunk(text, budgetTokens: 16)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(Corrector.estimatedTokens(chunk), 16)
        }
    }

    func testNonPositiveChunkBudgetIsClampedAndTerminates() {
        let text = "abcdefghij"
        let chunks = Corrector.chunk(text, budgetTokens: 0)

        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty })
    }

    /// Chunks should land on sentence boundaries where they exist — the model needs a whole
    /// sentence to punctuate it correctly.
    func testChunksPreferSentenceBoundaries() {
        let text = String(repeating: "Alpha beta gamma delta. ", count: 60)
        let chunks = Corrector.chunk(text, budgetTokens: 64)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks.dropLast() {
            XCTAssertTrue(
                chunk.hasSuffix("."),
                "Chunk did not end on a sentence boundary: …\(chunk.suffix(30))"
            )
        }
    }

    func testChunkingIsStableForRealisticDictationLength() {
        // Roughly five minutes of speech at 150 wpm.
        let words = (0..<750).map { "word\($0)" }.joined(separator: " ")
        let instructions = CorrectionPromptBuilder.systemPrompt(policy: CorrectionPolicy())
        let budget = Corrector.inputTokenBudget(instructions: instructions)

        let chunks = Corrector.chunk(words, budgetTokens: budget)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(Corrector.estimatedTokens(chunk), budget)
        }
        XCTAssertEqual(
            chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace).count,
            750
        )
    }

    // MARK: - Fuzz

    /// Whatever the transcript, chunking never loses a word and never exceeds the budget.
    func testChunkingFuzz() {
        var rng = SplitMix64(seed: 0xB0DE)
        let fragments = ["hello", "world.", "a", "supercalifragilistic", "!", "?", "  ", "🚀", "end."]

        for _ in 0..<400 {
            let count = Int(rng.next() % 200)
            let text = (0..<count)
                .map { _ in fragments[Int(rng.next() % UInt64(fragments.count))] }
                .joined(separator: " ")
            let budget = Int(rng.next() % 120) + 16

            let chunks = Corrector.chunk(text, budgetTokens: budget)

            let before = text.split(whereSeparator: \.isWhitespace).map(String.init)
            let after = chunks.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            XCTAssertEqual(after, before, "Fuzz lost words for: \(text.prefix(60))…")

            // A single indivisible token can exceed the budget; nothing else may.
            for chunk in chunks where chunk.split(whereSeparator: \.isWhitespace).count > 1 {
                XCTAssertLessThanOrEqual(
                    Corrector.estimatedTokens(chunk), budget,
                    "Multi-word chunk exceeded budget"
                )
            }
        }
    }
}
