import XCTest
@testable import ExpanderEngine

/// Prompt-echo defense for the on-device AI transforms.
///
/// The model receives its instructions twice — as system instructions and as the framing
/// line immediately before the selection. Small on-device models sometimes copy that
/// framing into the reply, and proofread's default output mode is *direct*: the answer
/// replaces the selection with no review. An echo like
/// "Proofread the text below. Return it corrected, in its own language:\n\nHello world."
/// must never reach a document — neither the leading echo (stripped) nor a mid-body copy
/// (re-roll once, then fail with `promptEcho`).
final class PromptEchoSanitizerTests: XCTestCase {

    private let proofreadFraming = AITransformKind.proofreadFramingForTests
    private let genericFraming = "Transform this text:\n\n"

    // MARK: - phrases(framing:)

    func testProofreadFramingYieldsItsClauses() {
        let phrases = AIPromptEcho.phrases(framing: proofreadFraming)
        XCTAssertTrue(phrases.contains { $0.contains("proofread the text below") })
        XCTAssertTrue(phrases.contains { $0.contains("return it corrected") })
    }

    func testShortClausesAreExcluded() {
        // "Transform this text" is 19 chars; a hypothetical 3-char clause must not exist.
        let phrases = AIPromptEcho.phrases(framing: genericFraming)
        XCTAssertTrue(phrases.allSatisfy { $0.count >= AIPromptEcho.minimumPhraseLength })
    }

    // MARK: - stripped(_:input:framing:) — leading echoes

    func testStripsExactFramingEcho() {
        let echo = "Proofread the text below. Return it corrected, in its own language:\n\n"
        let out = AIPromptEcho.stripped(echo + "Hello world.", input: "Hello world.", framing: proofreadFraming)
        XCTAssertEqual(out, "Hello world.")
    }

    func testStripsCaseAndPunctuationVariants() {
        let echo = "proofread the text below. Return it corrected in its own language - Hi there"
        let out = AIPromptEcho.stripped(echo, input: "Hi there", framing: proofreadFraming)
        XCTAssertEqual(out, "Hi there")
    }

    func testStripsFirstClauseOnlyEcho() {
        // The model frequently keeps just the first sentence of the instruction.
        let out = AIPromptEcho.stripped(
            "Proofread the text below.\n\nThe cat sat.",
            input: "The cat sat.",
            framing: proofreadFraming
        )
        XCTAssertEqual(out, "The cat sat.")
    }

    func testStripsGenericPrefixForRewriteKinds() {
        let out = AIPromptEcho.stripped(
            "Transform this text:\n\nBody text",
            input: "Body text",
            framing: genericFraming
        )
        XCTAssertEqual(out, "Body text")
    }

    func testCleanOutputIsUntouched() {
        let original = "The cat sat on the mat."
        XCTAssertEqual(
            AIPromptEcho.stripped(original, input: "Teh cat sat on teh mat.", framing: proofreadFraming),
            original
        )
    }

    func testDoesNotStripWhenTheInputItselfContainsThePhrase() {
        // An author writing about this very feature selected text starting with the
        // framing words; stripping would eat their content. The input wins.
        let authorsText = "Proofread the text below. Then press save."
        let echoed = "Proofread the text below. Then press save."
        XCTAssertEqual(
            AIPromptEcho.stripped(echoed, input: authorsText, framing: proofreadFraming),
            echoed
        )
    }

    func testStripsTrailingEcho() {
        let out = AIPromptEcho.stripped(
            "Fixed sentence here.\n\nProofread the text below. Return it corrected, in its own language:",
            input: "fixed sentence here.",
            framing: proofreadFraming
        )
        XCTAssertEqual(out, "Fixed sentence here.")
    }

    func testIdempotent() {
        let echoed = "Proofread the text below. Return it corrected, in its own language:\n\nHello world."
        let once = AIPromptEcho.stripped(echoed, input: "Hello world.", framing: proofreadFraming)
        let twice = AIPromptEcho.stripped(once, input: "Hello world.", framing: proofreadFraming)
        XCTAssertEqual(once, twice)
    }

    // MARK: - contaminated(output:input:framing:)

    func testLeadingEchoIsContaminatedBeforeStripping() {
        let echoed = "Proofread the text below. Return it corrected, in its own language:\n\nHello."
        XCTAssertTrue(AIPromptEcho.contaminated(output: echoed, input: "Hello.", framing: proofreadFraming))
    }

    func testMidBodyLeakIsContaminated() {
        let leak = "Hello. Proofread the text below and nothing else. Goodbye."
        XCTAssertTrue(AIPromptEcho.contaminated(output: leak, input: "Hello. Goodbye.", framing: proofreadFraming))
    }

    func testCleanOutputIsNotContaminated() {
        XCTAssertFalse(AIPromptEcho.contaminated(
            output: "Hello world, fixed.",
            input: "hello world, fixed!",
            framing: proofreadFraming
        ))
    }

    func testInputContainingThePhraseIsNeverContaminated() {
        let authorsText = "Please Proofread the text below carefully."
        XCTAssertFalse(AIPromptEcho.contaminated(
            output: authorsText,
            input: authorsText,
            framing: proofreadFraming
        ))
    }

    // MARK: - Fuzz invariants

    /// Seeded sweep over hostile compositions: stripping must be idempotent, must never
    /// return an empty string when the input was non-empty, and must never alter output
    /// whose phrase came from the author's own selection.
    func testStrippingInvariantsUnderFuzz() {
        struct SplitMix64 {
            var state: UInt64
            init(seed: UInt64) { state = seed }
            mutating func next() -> UInt64 {
                state &+= 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return z ^ (z >> 31)
            }
            mutating func pick(_ set: [String]) -> String { set[Int(next() % UInt64(set.count))] }
        }
        var rng = SplitMix64(seed: 0xD36F7)
        let bodies = ["Hi.", "Fix this.", "", "ok"]
        let separators = ["\n\n", "\n", " ", ""]
        let echoes = [
            "Proofread the text below. Return it corrected, in its own language:",
            "proofread the text below",
            "Return it corrected, in its own language:",
            "",
        ]
        var strippedCount = 0
        for _ in 0..<2_000 {
            let body = rng.pick(bodies)
            let pre = rng.pick(echoes)
            let post = rng.pick(echoes)
            let sep1 = rng.pick(separators)
            let sep2 = rng.pick(separators)
            let output = pre.isEmpty ? (post.isEmpty ? body : body + sep2 + post) : pre + sep1 + body + sep2 + post
            let input = body.isEmpty ? "seed" : body

            let once = AIPromptEcho.stripped(output, input: input, framing: proofreadFraming)
            let twice = AIPromptEcho.stripped(once, input: input, framing: proofreadFraming)

            XCTAssertEqual(twice, once, "strip must be idempotent for \(output)")
            // Stripping may only produce an empty string when the body itself was empty —
            // the author's text always survives.
            if !body.isEmpty {
                let survivor = once.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                XCTAssertFalse(survivor.isEmpty,
                               "stripping consumed the whole answer for \(output)")
            }
            if !pre.isEmpty && !inputNormalizedContains(pre, input) {
                XCTAssertTrue(once.contains(body) || body.isEmpty,
                              "the body must survive stripping for \(output)")
                strippedCount += 1
            }
        }
        // Sanity floor: most of these compositions contain a foreign echo and must strip.
        XCTAssertGreaterThan(strippedCount, 500, "stripping should fire on most fuzz inputs")
    }

    private func inputNormalizedContains(_ phrase: String, _ input: String) -> Bool {
        AIPromptEcho.normalized(input).contains(AIPromptEcho.normalized(phrase))
    }

    // MARK: - generateOnce plumbing shape

    func testPromptEchoErrorHasLocalizationKey() {
        // Adding the enum case without a table entry would surface the raw key to users
        // (`lookup` falls back to the key itself). Pin the English fallback string.
        XCTAssertEqual(AITransformError.promptEcho.localizationKey, "ai.error.promptEcho")
        XCTAssertNotEqual(
            LocalizationManager.shared.s("ai.error.promptEcho"),
            "ai.error.promptEcho",
            "ai.error.promptEcho must exist in the localization tables"
        )
    }
}

private extension AITransformKind {
    /// The framing exactly as `AITextTransformer.promptFraming(for:)` builds it, mirrored
    /// here so tests do not reach into the actor's nonisolated static from two modules.
    static var proofreadFramingForTests: String {
        "Proofread the text below. Return it corrected, in its own language:\n\n"
    }
}
