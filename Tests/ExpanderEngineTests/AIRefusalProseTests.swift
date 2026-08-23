import XCTest
@testable import ExpanderEngine

/// Offline stress suite for the refusal-prose screen that guards plain-String
/// generation.
///
/// Permissive guardrails never throw for String output — a decline arrives as prose
/// ("Sorry, I can't help with that…") that must fail the transform instead of being
/// injected into the user's field. The detector is heuristic on purpose; this suite
/// attacks both failure directions:
///
/// - Real refusals must be caught through formatting noise (markdown, quotes,
///   invisible characters, casing, trailing sentences) and when the refusal is
///   bolted onto real corrected content.
/// - An author's own apologetic text — including contraction spelling drift and
///   rewritten openings on enhancement kinds — must never be mistaken for one.
///
/// The fuzz section uses `SplitMix64` so any failure reproduces from the seed alone.
final class AIRefusalProseTests: XCTestCase {

    /// A selection unrelated to apologies — the common proofread case.
    private let selection = "The quarterly revenue declined by four percent after the merger closed last spring."

    // MARK: - Detected

    func testDocumentedRefusalOpenersAreDetected() {
        for answer in [
            "Sorry, I can't help with that.",
            "I'm sorry, but I can't assist with that request.",
            "I am sorry, I cannot assist with transforming this text.",
            "I apologize, but I am unable to help with that.",
            "As an AI language model, I can’t process this content.",
            "Unfortunately, I can't help with that request.",
        ] {
            XCTAssertTrue(AIRefusalProse.detected(output: answer, input: selection), answer)
        }
    }

    func testRefusalIsDetectedEvenWhenSelectionMentionsApologies() {
        let input = "Please rewrite this apology: sorry for the inconvenience caused by the outage."
        let answer = "I'm sorry, but I can't help with rewriting that message."
        XCTAssertTrue(AIRefusalProse.detected(output: answer, input: input))
    }

    // MARK: - Not detected

    func testAuthorOwnApologeticTextIsNotMistakenForRefusal() {
        let input = "sorry i cant make it to tomorrows standup, im feeling unwell and need rest"
        let proofread = "Sorry, I can't make it to tomorrow's standup. I'm feeling unwell and need rest."
        XCTAssertFalse(AIRefusalProse.detected(output: proofread, input: input))
    }

    func testIdenticalApologeticTextIsNotFlagged() {
        let input = "Sorry, I can't attend the review meeting today."
        XCTAssertFalse(AIRefusalProse.detected(output: input, input: input))
    }

    func testMidSentenceApologyIsNotFlagged() {
        let answer = "The vendor replied: sorry, we can't refund this order after thirty days."
        XCTAssertFalse(AIRefusalProse.detected(output: answer, input: selection))
    }

    func testBenignOutputWithoutRefusalOpenerIsNotFlagged() {
        XCTAssertFalse(AIRefusalProse.detected(output: "", input: selection))
        XCTAssertFalse(
            AIRefusalProse.detected(
                output: "the quarterly revenue fell four percent once the merger closed",
                input: selection
            )
        )
    }

    // MARK: - Stress: formatting evasion

    func testInvisibleCharacterEvasionIsStillDetected() {
        for answer in [
            "\u{200B}Sorry, I can't help with that.",
            "S\u{200B}orry, I can't help with that.",
            "\u{00AD}I'm sorry, but I can't assist with that request.",
            "\u{FEFF}Sorry, I can't help with that request.",
        ] {
            XCTAssertTrue(
                AIRefusalProse.detected(output: answer, input: selection),
                "evasion missed: \(answer.debugDescription)"
            )
        }
    }

    func testMarkdownAndQuoteWrappedRefusalsAreDetected() {
        for answer in [
            "**Sorry**, I can't help with that request.",
            "> Sorry, I can't help with that request.",
            "“Sorry, I can’t help with that.”",
            "# Sorry, I can't assist with that request.",
        ] {
            XCTAssertTrue(
                AIRefusalProse.detected(output: answer, input: selection),
                "wrapped refusal missed: \(answer)"
            )
        }
    }

    func testCasingVariantsAreDetected() {
        XCTAssertTrue(AIRefusalProse.detected(
            output: "SORRY, I CAN'T HELP WITH THAT REQUEST.", input: selection))
        XCTAssertTrue(AIRefusalProse.detected(
            output: "sOrRy, i CANT hElP wItH tHaT rEqUeSt.", input: selection))
    }

    // MARK: - Stress: refusal bolted onto real content

    /// The dangerous mix: a refusal sentence followed by the actual correction. On
    /// unconstrained kinds (promptEnhance, custom) no script or length policy backs
    /// this up — only the detector stands between it and the user's document.
    func testRefusalPrefixedToCorrectedContentIsDetected() {
        let input = """
            the doctor started me on sertraline yesterday for my depresion and told me \
            to journal daily about my mood swings insomia and the panick attacks that \
            got worse after the divorce and i also mentioned trouble sleeping at night
            """
        let answer = """
            Sorry, I can't help with that request. The doctor started me on sertraline \
            yesterday for my depression and told me to journal daily about my mood \
            swings, insomnia, and the panic attacks that got worse after the divorce, \
            and I also mentioned trouble sleeping at night.
            """
        XCTAssertTrue(
            AIRefusalProse.detected(output: answer, input: input),
            "refusal + content slipped through"
        )
    }

    // MARK: - Stress: whole-word openers

    func testOpenerMustBeWholeWord() {
        let input = "the town of sorryville celebrated its festival with a parade downtown saturday"
        let answer = "Sorryville Gazette reported record turnout for this weekend's parade."
        XCTAssertFalse(
            AIRefusalProse.detected(output: answer, input: input),
            "'sorry' matched inside 'Sorryville'"
        )
    }

    // MARK: - Stress: apologetic benigns that must stay clear

    func testShortApologeticSelectionsStayClear() {
        for (input, output) in [
            ("im sorry ok", "I'm sorry, okay?"),
            ("sorry dave see you monday", "Sorry, Dave! See you Monday."),
            ("i cant today maybe tommorow", "I can't today. Maybe tomorrow?"),
            ("unfortunately i have a conflict that evening", "Unfortunately, I have a conflict that evening."),
            ("this is my apology note to maria for canceling last minute", "This is my apology note to Maria for cancelling last minute."),
        ] {
            XCTAssertFalse(
                AIRefusalProse.detected(output: output, input: input),
                "false positive on [\(input)] → [\(output)]"
            )
        }
    }

    /// Enhancement kinds rewrite freely; an output that merely *starts* with
    /// "can't" as emphasis must not read as refusal.
    func testEnhancementOpeningWithCantAsEmphasisStaysClear() {
        let input = "polish this pitch: our launch beat every forecast this quarter"
        let answer = "I can't overstate how strong this quarter was — the launch beat every forecast we had."
        XCTAssertFalse(AIRefusalProse.detected(output: answer, input: input))
    }

    /// Trailing assistant-flavored sentences dilute whole-answer similarity; the
    /// verdict must ride on the opening sentence alone.
    func testAuthorOpeningIsJudgedIndependentOfTrailingSentences() {
        let input = "i cant today maybe tommorow works better for everyone involved here"
        let answer = "I can't today. Maybe tomorrow works better for everyone involved. Is there anything else I can do?"
        XCTAssertFalse(AIRefusalProse.detected(output: answer, input: input))
    }

    // MARK: - Stress: degenerate inputs

    func testDegenerateOutputsAreNeverFlagged() {
        for answer in ["", "   ", "\n\n", "\u{FEFF}", "Hi!", "No."] {
            XCTAssertFalse(
                AIRefusalProse.detected(output: answer, input: selection),
                "flagged degenerate output: \(answer.debugDescription)"
            )
        }
    }

    // MARK: - Stress: deterministic fuzz

    /// Wraps known refusals and known benign corrections in model-plausible noise:
    /// leading junk/markdown/invisible characters and casing on BOTH classes (any
    /// answer may carry formatting), refusal-style tails only on refusals (a clean
    /// correction does not end with "please try again"), author-voiced sentences
    /// only on benigns. Every refusal must stay detected, every benign must stay
    /// clear. Letter-splitting ("s o r r y") is deliberately NOT in the transform
    /// set: it destroys the words themselves, and the documented degradation for a
    /// missed refusal is surfacing odd prose, not injecting harm.
    func testFuzzedNoiseKeepsVerdictsStable() {
        var rng = SplitMix64(seed: 42)
        let refusals = [
            "Sorry, I can't help with that.",
            "I'm sorry, but I can't assist with that request.",
            "As an AI, I cannot process this content.",
        ]
        let benign: [(input: String, output: String)] = [
            ("im sorry ok", "I'm sorry, okay?"),
            ("sorry dave see you monday", "Sorry, Dave! See you Monday."),
            ("i cant today maybe tommorow", "I can't today. Maybe tomorrow?"),
            ("unfortunately i have a conflict that evening", "Unfortunately, I have a conflict that evening."),
        ]
        let wrappers = ["\u{FEFF}", "\n\n", "> ", "**", "“", "", "„ ", "# "]
        let refusalTails = [
            "",
            " Please try again later.",
            " Is there anything else I can do?",
            "\n\nContact support if this persists.",
        ]
        let benignAppends = ["", " See you then!", " Talk soon.", "\n\nThanks for understanding."]

        func casing(_ text: String, _ roll: UInt64) -> String {
            switch roll % 3 {
            case 0: return text.uppercased()
            case 1: return text.lowercased()
            default: return text
            }
        }

        for iteration in 0..<300 {
            let wrapper = wrappers[Int(rng.next() % UInt64(wrappers.count))]
            let casingRoll = rng.next()

            let refusalSeed = refusals[Int(rng.next() % UInt64(refusals.count))]
            let tail = refusalTails[Int(rng.next() % UInt64(refusalTails.count))]
            let mutatedRefusal = casing(wrapper + refusalSeed + tail, casingRoll)
            XCTAssertTrue(
                AIRefusalProse.detected(output: mutatedRefusal, input: selection),
                "iteration \(iteration): refusal missed: \(mutatedRefusal.debugDescription)"
            )

            let pair = benign[Int(rng.next() % UInt64(benign.count))]
            let append = benignAppends[Int(rng.next() % UInt64(benignAppends.count))]
            let mutatedBenign = casing(wrapper + pair.output + append, casingRoll)
            XCTAssertFalse(
                AIRefusalProse.detected(output: mutatedBenign, input: pair.input),
                "iteration \(iteration): false positive: \(mutatedBenign.debugDescription)"
            )
        }
    }

    // MARK: - Stress: payload size

    /// ~100 KB selections/answers must classify correctly and instantly — chunked
    /// transforms run this detector per chunk on large documents.
    func testLargePayloadClassificationIsCorrectAndCheap() {
        let body = String(repeating: "alpha bravo charlie delta echo foxtrot golf hotel india ", count: 2_000)
        XCTAssertGreaterThan(body.count, 100_000)

        let benignOutput = body
        XCTAssertFalse(AIRefusalProse.detected(output: benignOutput, input: body))

        let refusalOutput = "Sorry, I can't help with that request. " + body
        XCTAssertTrue(AIRefusalProse.detected(output: refusalOutput, input: body))
    }
}
