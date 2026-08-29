import XCTest
@testable import ExpanderEngine

/// Spoken AI commands: the wake word, the action, and what the action acts on.
///
/// The hard part is not recognising a command — it is *not* recognising one. Everything
/// here is dictation until proven otherwise, so a phrase that merely resembles a command
/// must be typed as spoken. A false positive silently discards what the user said.
final class VoiceCommandPhraseTests: XCTestCase {

    private func parse(_ transcript: String) -> VoiceAICommand? {
        VoiceAITriggerParser.parse(
            transcript: transcript,
            customTriggers: VoicePreferences.defaultVoiceTriggers,
            wakeWords: ["dev", "ai"]
        )
    }

    // MARK: - The requested phrases

    func testDevRewriteWithSpokenPayload() {
        let command = parse("dev rewrite make this shorter and clearer")
        XCTAssertEqual(command?.kind, .rewrite)
        XCTAssertEqual(command?.target, .spoken("make this shorter and clearer"))
    }

    func testDevProofreadWithSpokenPayload() {
        let command = parse("dev proofread their going to the meeting tommorow")
        XCTAssertEqual(command?.kind, .proofread)
        XCTAssertEqual(command?.target, .spoken("their going to the meeting tommorow"))
    }

    /// The third requested shape: act on what dictation just typed. Not a selection — the
    /// text is sitting in the field unselected, which is exactly why asking by voice is
    /// worth anything.
    func testProofreadFinalInsertion() {
        for phrase in [
            "proofread final insertion",
            "dev proofread final insertion",
            "ai proofread final insertion",
            "dev proofread last insertion",
            "dev proofread the last one",
        ] {
            let command = parse(phrase)
            XCTAssertEqual(command?.kind, .proofread, "Failed to parse: \(phrase)")
            XCTAssertEqual(command?.target, .lastInsertion, "Wrong target for: \(phrase)")
        }
    }

    func testRewriteFinalInsertion() {
        let command = parse("dev rewrite final insertion")
        XCTAssertEqual(command?.kind, .rewrite)
        XCTAssertEqual(command?.target, .lastInsertion)
    }

    // MARK: - Wake words

    /// A wake word is optional; the bare command still works.
    func testCommandsWorkWithAndWithoutAWakeWord() {
        for phrase in ["dev rewrite this", "ai rewrite this", "rewrite this"] {
            XCTAssertEqual(parse(phrase)?.kind, .rewrite, "Failed: \(phrase)")
            XCTAssertEqual(parse(phrase)?.target, .selection, "Failed: \(phrase)")
        }
    }

    func testWakeWordsAreConfigurable() {
        let command = VoiceAITriggerParser.parse(
            transcript: "jarvis proofread this",
            customTriggers: VoicePreferences.defaultVoiceTriggers,
            wakeWords: ["jarvis"]
        )
        XCTAssertEqual(command?.kind, .proofread)

        // And a wake word that is not configured is just a word.
        XCTAssertNil(VoiceAITriggerParser.parse(
            transcript: "jarvis proofread this",
            customTriggers: VoicePreferences.defaultVoiceTriggers,
            wakeWords: ["dev"]
        ))
    }

    /// The wake word alone is not a command — there is nothing to act on.
    func testBareWakeWordIsNotACommand() {
        XCTAssertNil(parse("dev"))
        XCTAssertNil(parse("ai"))
    }

    // MARK: - Not commands

    /// Everything here is ordinary dictation and must be typed, not executed. Each of these
    /// contains a trigger word somewhere; only a *leading* command counts.
    func testOrdinaryDictationIsNotTreatedAsACommand() {
        let dictation = [
            "the dev server is down again",
            "I asked the dev to rewrite the parser",
            "please proofread my email before I send it",
            "we should rewrite this module next quarter",
            "ask the AI team about it",
            "expand the search to include archived items",
            "the condense function takes a list",
            "development is going well",
            "devops rewrote the pipeline",
        ]

        for phrase in dictation {
            XCTAssertNil(
                parse(phrase),
                "Dictation was swallowed as a command: \(phrase.debugDescription)"
            )
        }
    }

    /// A wake word mid-sentence is dictation, not a command.
    func testWakeWordOnlyCountsAtTheStart() {
        XCTAssertNil(parse("tell the dev rewrite the docs"))
        XCTAssertNil(parse("send it to ai rewrite team"))
    }

    // MARK: - Payload handling

    /// "this" and "that" name the selection rather than being the text to transform.
    func testDemonstrativesResolveToTheSelection() {
        XCTAssertEqual(parse("dev rewrite this")?.target, .selection)
        XCTAssertEqual(parse("dev proofread that")?.target, .selection)
    }

    func testColonSeparatedPayloadStillWorks() {
        let command = parse("dev rewrite: make it formal")
        XCTAssertEqual(command?.kind, .rewrite)
        XCTAssertEqual(command?.target, .spoken("make it formal"))
    }

    /// Payload casing and punctuation belong to the user, not the parser.
    func testPayloadIsPreservedVerbatim() {
        let command = parse("dev rewrite Ship It On Friday, Please.")
        XCTAssertEqual(command?.target, .spoken("Ship It On Friday, Please."))
    }

    // MARK: - Coverage of the developer tools

    /// The transform set already covers the developer actions; they should all be reachable
    /// by voice with the same wake word.
    func testDeveloperToolsAreReachableByVoice() {
        let expectations: [(String, AITransformKind)] = [
            ("dev proofread this", .proofread),
            ("dev rewrite this", .rewrite),
            ("dev rephrase this", .paraphrase),
            ("dev expand this", .expand),
            ("dev condense this", .condense),
            ("dev prompt enhance this", .promptEnhance),
        ]

        for (phrase, expected) in expectations {
            XCTAssertEqual(parse(phrase)?.kind, expected, "Failed: \(phrase)")
        }
    }

    // MARK: - Contract with the delivery layer

    /// `.lastInsertion` is the one target whose text is destroyed before the transform runs
    /// — the dictated text is rolled back off screen first. The controller therefore has to
    /// hold it and put it back if the AI declines, so a refusal costs the user nothing.
    ///
    /// This pins the distinction the controller branches on; the restore itself needs a live
    /// text field.
    func testOnlyLastInsertionConsumesTextThatMustBeRestorable() {
        XCTAssertEqual(parse("dev proofread final insertion")?.target, .lastInsertion)

        // These read their input from somewhere the rollback did not touch.
        XCTAssertEqual(parse("dev proofread this")?.target, .selection)
        XCTAssertEqual(parse("dev proofread their going tommorow")?.target,
                       .spoken("their going tommorow"))
    }

    /// `requiresSelectionFallback` is what older call sites branch on; it must still agree
    /// with the richer target.
    func testLegacyFieldsAgreeWithTheTarget() {
        let spoken = parse("dev rewrite make it shorter")
        XCTAssertEqual(spoken?.payloadText, "make it shorter")
        XCTAssertFalse(spoken?.requiresSelectionFallback ?? true)

        let selection = parse("dev rewrite this")
        XCTAssertTrue(selection?.payloadText.isEmpty ?? false)
        XCTAssertTrue(selection?.requiresSelectionFallback ?? false)

        let last = parse("proofread final insertion")
        XCTAssertTrue(last?.payloadText.isEmpty ?? false)
        XCTAssertTrue(last?.requiresSelectionFallback ?? false)
    }

    // MARK: - Robustness

    func testEmptyAndWhitespaceInputIsNotACommand() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("   \n\t "))
    }

    /// Parsing runs on every finished dictation, so it must never be the thing that fails.
    func testHostileInputIsSurvivable() {
        var rng = SplitMix64(seed: 0xFEED)
        let fragments = ["dev", "ai", "rewrite", "proofread", ":", "  ", "final insertion", "🚀", "this", "\n"]

        for _ in 0..<2000 {
            let count = Int(rng.next() % 8)
            let phrase = (0..<count)
                .map { _ in fragments[Int(rng.next() % UInt64(fragments.count))] }
                .joined(separator: " ")
            _ = parse(phrase)   // must not crash or hang
        }
    }
}
