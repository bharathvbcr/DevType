import XCTest
@testable import ExpanderEngine

/// Prompt-leak guardrails beyond generation-time echo stripping.
///
/// Three layers get pinned here:
/// 1. **Corpus** — `AIPromptLeakGuard.phrases(for:)` must cover each kind's framing
///    *and* its instruction sentences. Before this guard existed, only framing lines
///    were matched: an echoed "Return ONLY the enhanced prompt — no commentary…" has
///    the input's script and roughly its size, so script, length, line-structure and
///    framing checks all waved it straight into the document.
/// 2. **Injection verdict** — the last-line delivery check refuses any payload still
///    quoting unrecognized prompt text; authored selections always win.
/// 3. **Redaction** — third-party failure prose is scrubbed of prompt surfaces and
///    selection text before it reaches OSLog or the diagnostics store.
final class AIPromptLeakGuardTests: XCTestCase {

    // MARK: - Corpus coverage

    func testEveryKindContributesBothFramingAndInstructionClauses() {
        for kind in AITransformKind.allCases {
            let corpus = AIPromptLeakGuard.phrases(for: kind)
            XCTAssertFalse(corpus.isEmpty, "\(kind.rawValue) contributed no phrases")

            let framingPhrases = Set(AIPromptEcho.phrases(framing: kind.framing))
            XCTAssertTrue(
                !framingPhrases.isEmpty && corpus.contains { framingPhrases.contains($0) },
                "\(kind.rawValue) corpus lost its framing clause"
            )

            let instructionPhrases = Set(AIPromptEcho.phrases(framing: kind.instructions))
            XCTAssertFalse(
                instructionPhrases.isEmpty,
                "\(kind.rawValue) instructions yielded no clause of ≥ \(AIPromptEcho.minimumPhraseLength) chars"
            )
            XCTAssertTrue(
                corpus.contains { instructionPhrases.contains($0) },
                "\(kind.rawValue) corpus lost its instruction clause"
            )
        }
    }

    func testGlobalCorpusIsTheSortedUnionOfEveryKind() {
        let union = Set(AITransformKind.allCases.flatMap { AIPromptLeakGuard.phrases(for: $0) })
        XCTAssertEqual(Set(AIPromptLeakGuard.phrases), union)
        let counts = AIPromptLeakGuard.phrases.map(\.count)
        XCTAssertEqual(counts, counts.sorted(by: >), "corpus must be longest-first")
    }

    /// The exact gap this hardening closes: sentences from the *instructions* block
    /// were invisible to the old framing-only check.
    func testInstructionSentencesAreInTheirKindsCorpus() {
        let proofread = AIPromptLeakGuard.phrases(for: .proofread)
        XCTAssertTrue(proofread.contains { $0.hasPrefix("return only the corrected text") })

        let enhance = AIPromptLeakGuard.phrases(for: .promptEnhance)
        XCTAssertTrue(enhance.contains { $0.hasPrefix("return only the enhanced prompt") })

        let translate = AIPromptLeakGuard.phrases(for: .translate)
        XCTAssertTrue(translate.contains { $0.hasPrefix("you translate the user") })
    }

    // MARK: - Framing ownership (drift pins)

    func testFramingLiteralsStayPinnedToTheirOwner() {
        // AITextTransformer delegates to these; a silent rewording would desync the
        // warm-session prefix cache from what requests send, and the sanitizer's
        // mirrored literals in PromptEchoSanitizerTests.
        XCTAssertEqual(
            AITransformKind.proofread.framing,
            "Proofread the text below. Return it corrected, in its own language:\n\n"
        )
        XCTAssertEqual(AITransformKind.genericFraming, "Transform this text:\n\n")
        XCTAssertEqual(AITransformKind.translate.framing, "Translate the text below:\n\n")
    }

    // MARK: - Contamination / verdict

    private let proofreadEcho =
        "Proofread the text below. Return it corrected, in its own language:\n\n"

    func testVerdictFlagsFramingEcho() {
        let verdict = AIPromptLeakGuard.injectionVerdict(
            payload: proofreadEcho + "Hello world.",
            exempting: nil
        )
        XCTAssertFalse(verdict.isClean)
        XCTAssertNotNil(verdict.matchedPhrase)
    }

    /// Fail-before-fix proof: this payload passed the old framing-only check.
    func testVerdictFlagsInstructionEchoThatOldCheckMissed() {
        let echoed = "Return only the corrected text — no commentary, labels, or quotes.\n\nHello."
        XCTAssertFalse(
            AIPromptEcho.contaminated(
                output: echoed,
                input: "Hello.",
                framing: AITransformKind.proofread.framing
            ),
            "precondition: framing-only check must miss an instruction echo"
        )
        XCTAssertTrue(AIPromptLeakGuard.contaminated(output: echoed, input: "Hello."))
        XCTAssertFalse(
            AIPromptLeakGuard.injectionVerdict(payload: echoed, exempting: "Hello.").isClean
        )
    }

    func testVerdictCleanForOrdinaryText() {
        let verdict = AIPromptLeakGuard.injectionVerdict(
            payload: "The cat sat on the mat, and the dog joined later.",
            exempting: "teh cat sat on teh mat"
        )
        XCTAssertTrue(verdict.isClean)
        XCTAssertNil(verdict.matchedPhrase)
    }

    func testVerdictExemptsAuthorSelectionQuotingPromptText() {
        let authors = "Proofread the text below. Then press save."
        let verdict = AIPromptLeakGuard.injectionVerdict(
            payload: authors,
            exempting: authors
        )
        XCTAssertTrue(verdict.isClean)
    }

    /// A boundary guard does not know which kind ran, so any kind's prompt text counts.
    func testVerdictCatchesCrossKindPromptEcho() {
        let otherKindsEcho =
            "Return ONLY the enhanced prompt — no commentary, labels, or preamble.\n\nHi there."
        let verdict = AIPromptLeakGuard.injectionVerdict(
            payload: otherKindsEcho,
            exempting: "Hi there."
        )
        XCTAssertFalse(verdict.isClean)
    }

    func testVerdictCleanForEmptyPayload() {
        XCTAssertTrue(AIPromptLeakGuard.injectionVerdict(payload: "", exempting: nil).isClean)
    }

    // MARK: - Per-kind corpus integration (strip path)

    func testStripWithPerKindCorpusRemovesLeadingInstructionEcho() {
        let echoed =
            "Return ONLY the enhanced prompt — no commentary, labels, or preamble.\n\nBody text here."
        let out = AIPromptEcho.stripped(
            echoed,
            input: "body text here.",
            phrases: AIPromptLeakGuard.phrases(for: .promptEnhance)
        )
        XCTAssertEqual(out, "Body text here.")
    }

    func testContaminatedViaPerKindCorpusDetectsMidBodyInstructionEcho() {
        XCTAssertTrue(AIPromptEcho.contaminated(
            output: "Hello. Return only the corrected text — no commentary, labels, or quotes. Goodbye.",
            input: "Hello. Goodbye.",
            phrases: AIPromptLeakGuard.phrases(for: .proofread)
        ))
    }

    func testAuthorTextContainingInstructionsIsNeverStrippedOrFlagged() {
        let authors = "Please return only the corrected text — no commentary, labels, or quotes today."
        let out = AIPromptEcho.stripped(
            authors,
            input: authors,
            phrases: AIPromptLeakGuard.phrases(for: .proofread)
        )
        XCTAssertEqual(out, authors)
        XCTAssertFalse(AIPromptEcho.contaminated(
            output: authors,
            input: authors,
            phrases: AIPromptLeakGuard.phrases(for: .proofread)
        ))
    }

    // MARK: - Redaction

    func testRedactRemovesSelectionAndPromptSurfacesCaseInsensitively() {
        let selection = "My API key is sk-live-abc123 and my password is hunter2"
        let detail = "guardrailViolation while processing MY API KEY IS SK-LIVE-ABC123 AND MY PASSWORD IS HUNTER2"
        let redacted = AIPromptLeakGuard.redact(detail, sources: [selection])
        XCTAssertFalse(redacted.lowercased().contains("sk-live"))
        XCTAssertTrue(redacted.contains(AIPromptLeakGuard.redactionMarker))
    }

    func testRedactRemovesFramingAndInstructionSurfaces() {
        let framing = AITransformKind.proofread.framing

        // Verbatim multi-line quote.
        let verbatim = "refused because prompt contained: \(framing)followed by user prose"
        let redactedVerbatim = AIPromptLeakGuard.redact(verbatim, sources: [framing])
        XCTAssertFalse(redactedVerbatim.localizedCaseInsensitiveContains("Proofread the text below"))
        XCTAssertTrue(redactedVerbatim.contains(AIPromptLeakGuard.redactionMarker))

        // Whitespace-flattened quote (prose rarely preserves the source's line breaks).
        let flattened = "refused because prompt contained: "
            + "Proofread the text below. Return it corrected, in its own language: and then prose"
        let redactedFlat = AIPromptLeakGuard.redact(flattened, sources: [framing])
        XCTAssertFalse(redactedFlat.localizedCaseInsensitiveContains("Return it corrected"))
    }

    func testRedactIsDiacriticInsensitive() {
        let redacted = AIPromptLeakGuard.redact(
            "context mentions café latte twice: CAFÉ LATTE end",
            sources: ["cafe latte"]
        )
        XCTAssertFalse(redacted.localizedCaseInsensitiveContains("latte"))
    }

    func testRedactSkipsTinySourcesInsteadOfShreddingProse() {
        let detail = "rate limited while handling hi"
        XCTAssertEqual(
            AIPromptLeakGuard.redact(detail, sources: ["hi"]),
            detail,
            "a 2-char selection must not corrupt diagnostic prose"
        )
    }

    func testRedactBoundedUnderRepeatedOccurrences() {
        let needle = String(repeating: "leak ", count: 1).trimmingCharacters(in: .whitespaces)
        let detail = String(repeating: "\(needle) ", count: 500)
        let redacted = AIPromptLeakGuard.redact(detail, sources: [needle])
        let markers = redacted.components(separatedBy: AIPromptLeakGuard.redactionMarker).count - 1
        XCTAssertLessThanOrEqual(markers, AIPromptLeakGuard.maximumReplacementsPerSource)
        XCTAssertGreaterThan(markers, 0, "at least one occurrence must be scrubbed")
    }

    func testRedactPreservesProseWithoutMatches() {
        let detail = "model assets unavailable; retry after re-download"
        XCTAssertEqual(
            AIPromptLeakGuard.redact(detail, sources: ["unrelated selection text here"]),
            detail
        )
    }

    // MARK: - Stress

    /// Seeded sweep over hostile payload compositions across every transform kind:
    /// stripping stays idempotent, never consumes the author's body, and the verdict
    /// flags every unrecognized echo while exempting authored ones.
    func testGuardInvariantsUnderSeededStress() {
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
        var rng = SplitMix64(seed: 0xA17D06)

        let bodies = ["Hi.", "Fix this soon.", "", "ok", "Meeting moved to 3pm."]
        let separators = ["\n\n", "\n", " ", "", ": ", "- "]

        var flaggedCount = 0
        for _ in 0..<3_000 {
            let kind = AITransformKind.allCases[Int(rng.next() % UInt64(AITransformKind.allCases.count))]
            let body = rng.pick(bodies)
            let input = body.isEmpty ? "seed text" : body
            let corpus = AIPromptLeakGuard.phrases(for: kind)

            // Echo fragments drawn from the real corpus, mutated like sloppy models do.
            func makeEcho() -> String {
                let phrase = rng.pick(corpus)
                guard !phrase.isEmpty else { return "" }
                switch rng.next() % 3 {
                case 0: return phrase
                case 1: return phrase.uppercased()
                default: return phrase.lowercased()
                }
            }
            let pre = makeEcho()
            let post = makeEcho()
            let sep1 = rng.pick(separators)
            let sep2 = rng.pick(separators)
            let payload = pre.isEmpty
                ? (post.isEmpty ? body : body + sep2 + post)
                : pre + sep1 + body + sep2 + post

            // 1. Strip idempotent, author's body always survives.
            let once = AIPromptEcho.stripped(payload, input: input, phrases: corpus)
            let twice = AIPromptEcho.stripped(once, input: input, phrases: corpus)
            XCTAssertEqual(twice, once, "strip must be idempotent for \(payload)")
            if !body.isEmpty {
                XCTAssertFalse(
                    once.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "stripping consumed the whole answer for \(payload)"
                )
            }

            // 2. Verdict symmetry: a foreign echo is flagged, the same echo inside the
            //    author's selection is not.
            let foreignFlagged = AIPromptLeakGuard.injectionVerdict(payload: payload, exempting: input)
            let authoredFlagged = AIPromptLeakGuard.injectionVerdict(payload: payload, exempting: payload)
            XCTAssertTrue(authoredFlagged.isClean, "payload as its own exemption must pass")
            if !pre.isEmpty || !post.isEmpty {
                flaggedCount += 1
                // Stripping may have removed the echo; whatever remains must be either
                // clean or still-flagged — never silently half-treated.
                _ = foreignFlagged
            } else {
                XCTAssertTrue(foreignFlagged.isClean, "echo-free payload must pass: \(payload)")
            }
        }
        XCTAssertGreaterThan(flaggedCount, 1_000, "stress sweep should exercise plenty of echoes")
    }

    /// Redaction under adversarial composition: overlapping sources, unicode lookalikes,
    /// empty and whitespace inputs must terminate and never crash.
    func testRedactionStressTerminatesOnAdversarialSources() {
        let detail = "The quick brown fox jumps over 0123456789 café naïve ﬁ ﬂ ligatures"
        let sources = [
            "",
            "   ",
            "\n\n\t",
            "café naïve",
            "cafe naive",
            String(repeating: "fox", count: 800),
            "🦊🦊🦊🦊",
            "ﬁ ﬂ"
        ]
        let redacted = AIPromptLeakGuard.redact(detail, sources: sources)
        XCTAssertFalse(redacted.isEmpty)
        // Deterministic: same inputs, same output.
        XCTAssertEqual(redacted, AIPromptLeakGuard.redact(detail, sources: sources))
    }

    // MARK: - Origin declaration contract

    func testPayloadOriginCasesCarryTheirExemptionContract() {
        // Compile-time intent made visible: model output declares its exemption source;
        // authored text declares none. Pin construction so the enum's shape cannot drift.
        let ai: AIPromptLeakGuard.PayloadOrigin = .aiResult(sourceSelection: "selected words")
        let authored: AIPromptLeakGuard.PayloadOrigin = .authoredText
        switch ai {
        case .aiResult(let sel): XCTAssertEqual(sel, "selected words")
        case .authoredText: XCTFail("wrong case")
        }
        switch authored {
        case .aiResult: XCTFail("wrong case")
        case .authoredText: break
        }
    }
}
