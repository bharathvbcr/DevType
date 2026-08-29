import XCTest
@testable import ExpanderEngine

/// The stripper is only worth anything if it is actually on the paths that write into the
/// user's document. This suite covers the wiring rather than the algorithm: the voice
/// chokepoint, the preference that gates both chokepoints, and the single-pass rule that
/// keeps the two from stripping the same text twice.
final class AIMarkdownWiringTests: XCTestCase {

    private var savedPreference: Any?

    override func setUp() {
        super.setUp()
        savedPreference = UserDefaults.standard.object(forKey: AIPreferences.removesMarkdownKey)
        UserDefaults.standard.removeObject(forKey: AIPreferences.removesMarkdownKey)
    }

    override func tearDown() {
        if let savedPreference {
            UserDefaults.standard.set(savedPreference, forKey: AIPreferences.removesMarkdownKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AIPreferences.removesMarkdownKey)
        }
        super.tearDown()
    }

    // MARK: - The preference

    /// Off-by-default would ship the feature to nobody: `UserDefaults.bool` reads an unset
    /// key as `false`, and almost every user never opens the AI tab.
    func testRemovalIsOnForAUserWhoHasNeverOpenedPreferences() {
        XCTAssertNil(UserDefaults.standard.object(forKey: AIPreferences.removesMarkdownKey))
        XCTAssertTrue(AIPreferences.removesMarkdown)
        XCTAssertEqual(AIPreferences.voiceMarkdownPolicy, .strip)
    }

    func testTurningItOffReachesBothChokepoints() {
        AIPreferences.removesMarkdown = false
        XCTAssertEqual(AIPreferences.voiceMarkdownPolicy, .preserve, "voice path")
        for kind in AITransformKind.allCases {
            XCTAssertEqual(
                AIMarkdownStripper.policy(for: kind, enabled: AIPreferences.removesMarkdown),
                .preserve,
                "transform path, kind \(kind.rawValue)"
            )
        }

        AIPreferences.removesMarkdown = true
        XCTAssertEqual(AIPreferences.voiceMarkdownPolicy, .strip)
        XCTAssertEqual(
            AIMarkdownStripper.policy(for: .rewrite, enabled: AIPreferences.removesMarkdown),
            .strip
        )
    }

    // MARK: - The voice chokepoint

    /// Every model-backed corrector runs `CorrectionOutputSanitizer`. A local model that
    /// answers a dictation with a bulleted, emphasised summary must not put asterisks in
    /// the field the user is dictating into.
    func testDictationLosesTheMarkdownAModelAdds() {
        XCTAssertEqual(
            CorrectionOutputSanitizer.sanitize("Let's **meet** at 2 PM in the _main_ room."),
            "Let's meet at 2 PM in the main room."
        )
        XCTAssertEqual(
            CorrectionOutputSanitizer.sanitize("### Agenda\n\n* item one\n* item two"),
            "Agenda\n\n- item one\n- item two"
        )
        XCTAssertEqual(
            CorrectionOutputSanitizer.sanitize("See [the doc](https://example.com) today."),
            "See the doc today."
        )
    }

    /// A label the model hid behind emphasis. This is why the Markdown pass sits between
    /// two wrapper passes instead of after them: `**Cleaned:**` is not a recognised
    /// preamble until the asterisks are gone.
    func testAPreambleHiddenBehindEmphasisIsStillRemoved() {
        XCTAssertEqual(CorrectionOutputSanitizer.sanitize("**Cleaned:** \"ship it\""), "ship it")
        XCTAssertEqual(CorrectionOutputSanitizer.sanitize("*Transcript:* hello there"), "hello there")
    }

    /// A dictated identifier must survive the pass that is looking for emphasis.
    func testSpokenIdentifiersSurviveTheVoicePath() {
        let spoken = "set user_id and MAX_RETRY_COUNT then call __init__"
        XCTAssertEqual(CorrectionOutputSanitizer.sanitize(spoken, original: spoken), spoken)
    }

    func testVoicePathHonoursThePreserveSwitch() {
        let output = "Let's **meet** at 2 PM."
        XCTAssertEqual(CorrectionOutputSanitizer.sanitize(output, markdown: .preserve), output)
    }

    /// The pre-existing sanitizer contract still holds with the Markdown pass in place.
    func testSanitizerStillNeverGrowsAndStaysStable() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let fragments = [
            "```", "<think>", "</think>", "\"", "'", "Transcript:", "\n", "  ", "a", "🚀",
            "”", "“", "**", "_", "# ", "- ", "[x](y)", "|---|"
        ]
        for _ in 0..<3000 {
            let count = Int(rng.next() % 12)
            let text = (0..<count).map { _ in fragments[Int(rng.next() % UInt64(fragments.count))] }.joined()
            let out = CorrectionOutputSanitizer.sanitize(text)
            XCTAssertLessThanOrEqual(out.count, text.count + 1, "Sanitizer grew the input: \(text.debugDescription)")
        }
    }

    // MARK: - Single-pass discipline

    /// `AITransformCorrector` feeds `CorrectionOutputSanitizer` an answer that
    /// `AITextTransformer` has already stripped, so it passes `.preserve`. If that ever
    /// regressed to `voiceMarkdownPolicy`, a `.preserve` kind's code answer would be
    /// stripped anyway, and a fence freed by the first pass would have its body read as
    /// prose by the second — the one case where the stripper is not idempotent.
    func testASecondPassOverAFreedFenceIsWhatTheCallSitesAvoid() {
        let answer = "```\nname = *value*\n```"
        let firstPass = AIMarkdownStripper.strip(answer, policy: .strip)
        XCTAssertEqual(firstPass, "name = *value*")

        // What a second, independent pass would do to it — and does not, because
        // `AITransformCorrector` hands the sanitizer `.preserve`.
        XCTAssertEqual(AIMarkdownStripper.strip(firstPass, policy: .strip), "name = value")
        XCTAssertEqual(
            CorrectionOutputSanitizer.sanitize(firstPass, original: "", markdown: .preserve),
            firstPass
        )
    }

    // MARK: - Cloud recognition

    /// `GeminiSpeechAdapter` transcribes with a general-purpose model, and with correction
    /// disabled its text is delivered verbatim — so it is a model-output-to-document path
    /// like any other, and gets the same pass. This covers the shape the adapter applies.
    func testCloudTranscriptionLosesFormattingTheModelInvented() {
        XCTAssertEqual(
            AIMarkdownStripper.strip("## Agenda\n\nDiscuss the **launch** date.", policy: .strip),
            "Agenda\n\nDiscuss the launch date."
        )
    }

    /// The adapter reports `.speechNoSpeech` when the transcript is empty. Stripping runs
    /// before that check, so a transcript that strips to nothing would be reported as
    /// silence the user never spoke. The never-empties post-condition is what rules it out.
    func testStrippingCannotTurnATranscriptIntoSilence() {
        let markdownOnly = ["**", "***", "# ", "> ", "- ", "|---|", "```", "~~~", "___", "==="]
        for text in markdownOnly {
            let stripped = AIMarkdownStripper.strip(text, policy: .strip)
            XCTAssertFalse(
                stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(text.debugDescription) stripped to silence"
            )
        }
    }

    // MARK: - The transform chokepoint's neighbours

    /// The stripper runs after `AITransformText.sanitize`, and the two must agree about a
    /// whole-answer fence: `sanitize` unwraps it, the stripper finds nothing left to do.
    func testWholeAnswerFenceIsHandledOnceByTheWrapperPass() {
        let raw = "```\nThe launch is Friday.\n```"
        let unwrapped = AITransformText.sanitize(raw, input: "the launch is friday")
        XCTAssertEqual(unwrapped, "The launch is Friday.")
        XCTAssertEqual(
            AIMarkdownStripper.strip(unwrapped, policy: .strip, original: "the launch is friday"),
            "The launch is Friday."
        )
    }

    /// Proofread is the kind that injects without review, so its answer must clear both
    /// the Markdown pass and the line-structure check the transformer runs next.
    func testProofreadAnswerClearsTheStripperAndTheLineStructureCheck() {
        let input = "the launch is friday\nthe deck is not done"
        let answer = "The **launch** is Friday.\nThe `deck` is not done."
        let stripped = AIMarkdownStripper.strip(
            answer,
            policy: AITransformKind.proofread.markdownPolicy,
            original: input
        )
        XCTAssertEqual(stripped, "The launch is Friday.\nThe deck is not done.")
        XCTAssertTrue(AITransformText.preservesLineStructure(input: input, output: stripped))
        XCTAssertFalse(AITransformKind.proofread.lengthPolicy.exceeded(input: input, output: stripped))
    }

    /// Proofreading a Markdown document gives the document back.
    func testProofreadingMarkdownReturnsMarkdown() {
        let input = "## Setup\n\nRun the **installer** first."
        let answer = "## Setup\n\nRun the **installer** first, then reboot."
        XCTAssertEqual(
            AIMarkdownStripper.strip(answer, policy: AITransformKind.proofread.markdownPolicy, original: input),
            answer
        )
    }
}
