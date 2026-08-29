import XCTest
@testable import ExpanderEngine

/// The contract every corrector must satisfy: **ordinary speech survives intact**.
///
/// Filler-word and self-correction heuristics fail on normal English because the same
/// tokens carry meaning in most sentences — "like" is a verb, "you know" opens a clause,
/// "sorry" is an apology, "no wait" describes a queue. A corrector that strips them
/// unconditionally silently destroys the user's words, which is worse than doing nothing.
///
/// These cases are run against whichever corrector is on the default path. When the
/// deterministic corrector is replaced by a model, this suite moves with it — the
/// invariant belongs to the correction *stage*, not to any one implementation.
final class CorrectionGoldenCorpusTests: XCTestCase {

    /// Sentences that must be returned with their words intact. Punctuation and
    /// capitalisation may change; content words may not disappear.
    private static let mustSurvive: [(input: String, requiredWords: [String])] = [
        ("I like coffee and I like tea",
         ["like", "coffee", "tea"]),
        ("You know what I mean about the parser",
         ["know", "what", "mean", "parser"]),
        ("Send the report to the team actually send it to legal",
         ["report", "team", "legal"]),
        ("I'm sorry I'll be late to the meeting",
         ["sorry", "late", "meeting"]),
        ("There is no wait time on the queue",
         ["no", "wait", "time", "queue"]),
        ("The error rate is up so take him to the ER",
         ["error", "rate", "ER"]),
        ("Let me know if that works for you",
         ["know", "works"]),
        ("Ship the umbrella logo to marketing",
         ["umbrella", "logo", "marketing"]),
        ("Uber and Amazon both use this pattern",
         ["Uber", "Amazon", "pattern"]),
    ]

    /// Cases where removal is the *correct* behaviour — a real hesitation or an explicit,
    /// punctuation-delimited spoken retraction.
    private static let mustClean: [(input: String, gone: [String], kept: [String])] = [
        ("um so I need to fix the parser bug today",
         ["um"], ["parser", "bug", "today"]),
        ("the meeting is on Tuesday, sorry, Thursday",
         ["Tuesday"], ["Thursday"]),
        ("uh I think we should ship it",
         ["uh"], ["ship"]),
        ("the value is ten, I mean, eleven",
         ["ten"], ["eleven"]),
    ]

    private func correct(_ text: String) async throws -> String {
        let corrector = DeterministicCorrector()
        let request = CorrectionRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            rawTranscript: text,
            policy: CorrectionPolicy(),
            protectedSpans: ProtectedSpanExtractor.extract(from: text),
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .onDeviceOnly
        )
        return try await corrector.correct(request).text
    }

    private func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    // MARK: - G1. Ordinary speech is never mangled

    func testOrdinarySpeechSurvivesCorrection() async throws {
        for testCase in Self.mustSurvive {
            let output = try await correct(testCase.input)
            let outputWords = words(output)

            for required in testCase.requiredWords {
                XCTAssertTrue(
                    outputWords.contains(required.lowercased()),
                    """
                    Corrector deleted the word "\(required)" from ordinary speech.
                      in : \(testCase.input)
                      out: \(output)
                    """
                )
            }
        }
    }

    // MARK: - G2. Real hesitations and explicit retractions are still cleaned

    func testGenuineDisfluenciesAreStillRemoved() async throws {
        for testCase in Self.mustClean {
            let output = try await correct(testCase.input)
            let outputWords = words(output)

            for removed in testCase.gone {
                XCTAssertFalse(
                    outputWords.contains(removed.lowercased()),
                    """
                    Corrector failed to clean "\(removed)".
                      in : \(testCase.input)
                      out: \(output)
                    """
                )
            }
            for kept in testCase.kept {
                XCTAssertTrue(
                    outputWords.contains(kept.lowercased()),
                    """
                    Cleaning "\(testCase.input)" also removed "\(kept)".
                      out: \(output)
                    """
                )
            }
        }
    }

    // MARK: - G3. Word loss is bounded even on adversarial input

    func testCorrectorNeverDropsMostOfASentence() async throws {
        for testCase in Self.mustSurvive {
            let output = try await correct(testCase.input)
            let before = words(testCase.input).count
            let after = words(output).count

            XCTAssertGreaterThanOrEqual(
                after, before - 1,
                """
                Corrector removed \(before - after) of \(before) words from ordinary speech.
                  in : \(testCase.input)
                  out: \(output)
                """
            )
        }
    }

    // MARK: - G4. Verbatim policy disables every rewriting permission

    func testVerbatimPolicyPreservesTextExactly() async throws {
        let corrector = DeterministicCorrector()
        let raw = "um so I like coffee you know"
        let request = CorrectionRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            rawTranscript: raw,
            policy: CorrectionPolicy(
                tone: .exact,
                allowDisfluencyRemoval: false,
                allowFalseStartRemoval: false,
                allowSpokenPunctuation: false,
                allowNumberFormatting: false
            ),
            protectedSpans: [],
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .onDeviceOnly
        )
        let output = try await corrector.correct(request).text
        XCTAssertEqual(
            words(output), words(raw),
            "Verbatim policy must not remove any word"
        )
    }

    // MARK: - G5. Protected spans survive correction

    func testProtectedSpansSurviveCorrection() async throws {
        let inputs = [
            "run kubectl apply --no-verify on the cluster",
            "email me at bharath@example.com about it",
            "upgrade to v2.1.0 today",
            "the file is at /usr/local/bin/devtype",
            "it costs $49.99 per seat",
            "set the timeout to 250ms please",
        ]

        for input in inputs {
            let spans = ProtectedSpanExtractor.extract(from: input)
            XCTAssertFalse(spans.isEmpty, "Expected a protected span in: \(input)")

            let output = try await correct(input)
            for span in spans {
                let strippedOut = output.filter { !$0.isWhitespace }
                let strippedSpan = span.canonicalForm.filter { !$0.isWhitespace }
                XCTAssertTrue(
                    strippedOut.localizedCaseInsensitiveContains(strippedSpan),
                    """
                    Protected span "\(span.canonicalForm)" (\(span.kind)) was altered.
                      in : \(input)
                      out: \(output)
                    """
                )
            }
        }
    }
}
