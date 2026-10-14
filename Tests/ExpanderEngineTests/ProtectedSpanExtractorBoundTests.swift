import XCTest
@testable import ExpanderEngine

/// The ICU email pattern is quadratic on a long run of local-part characters.
/// These tests pin the ceiling and the linear scan that replaced it.
final class ProtectedSpanExtractorBoundTests: XCTestCase {

    func testNineHundredThousandRepeatedLettersReturnWithinOneSecond() {
        let text = String(repeating: "a", count: 900_000)
        let clock = ContinuousClock()
        var spans: [ProtectedSpan] = []
        let elapsed = clock.measure {
            spans = ProtectedSpanExtractor.extract(from: text)
        }
        XCTAssertEqual(spans, [])
        XCTAssertLessThan(elapsed, .seconds(1), "extract took \(elapsed)")
    }

    func testRepeatedLettersJustUnderTheCeilingReturnWithinAQuarterSecond() {
        let count = ProtectedSpanExtractor.maximumUTF16Length - 1
        let text = String(repeating: "a", count: count)
        let clock = ContinuousClock()
        var spans: [ProtectedSpan] = []
        let elapsed = clock.measure {
            spans = ProtectedSpanExtractor.extract(from: text)
        }
        XCTAssertEqual(spans, [])
        XCTAssertLessThan(elapsed, .milliseconds(250), "extract took \(elapsed)")
    }

    func testTwentyThousandRepeatedLettersStayUnderAQuarterSecond() {
        let text = String(repeating: "a", count: 20_000)
        let clock = ContinuousClock()
        var spans: [ProtectedSpan] = []
        let elapsed = clock.measure {
            spans = ProtectedSpanExtractor.extract(from: text)
        }
        XCTAssertEqual(spans, [])
        XCTAssertLessThan(elapsed, .milliseconds(250), "extract took \(elapsed)")
    }

    func testLongAccentedRunUnderTheCeilingIsNotSpecialCasedToAsciiA() {
        let count = ProtectedSpanExtractor.maximumUTF16Length - 1
        let text = String(repeating: "\u{00E9}", count: count)
        XCTAssertEqual((text as NSString).length, count)
        let clock = ContinuousClock()
        var spans: [ProtectedSpan] = []
        let elapsed = clock.measure {
            spans = ProtectedSpanExtractor.extract(from: text)
        }
        XCTAssertEqual(spans, [])
        XCTAssertLessThan(elapsed, .milliseconds(250), "extract took \(elapsed)")
    }

    func testPipelineSkipsTheCorrectorWhenTheTranscriptExceedsTheCeiling() async {
        let text = String(repeating: "a", count: 900_000)
        let raw = RawTranscript(
            text: text,
            localeIdentifier: "en_US",
            providerID: "test",
            modelVersion: "1"
        )
        let corrector = ExplodingIfCalledCorrector()
        let final = await CorrectionPipeline.execute(
            rawTranscript: raw,
            corrector: corrector,
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: .distantPast,
            privacyRoute: .onDeviceOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )
        XCTAssertEqual(corrector.correctCallCount, 0)
        XCTAssertEqual(final.text, text)
        XCTAssertEqual(final.rawTranscript, raw)
        XCTAssertNil(final.correctionCandidate)
        XCTAssertEqual(final.validationOutcome, .notApplicable)
    }

    func testNormalSentenceStillExtractsEmailPathFlagVersionAndCurrency() {
        // `$50` rather than `$12.50`: the version pattern matches `12.50` first, and the
        // existing overlap check then drops the currency span. `$50` is what the extractor
        // already reports as currency (see the session redesign fixture).
        let text = "Email me at dev@example.com about ~/src/app --force v2.1.0 and $50"
        let spans = ProtectedSpanExtractor.extract(from: text)
        XCTAssertTrue(spans.contains { $0.kind == .email && $0.originalText == "dev@example.com" })
        XCTAssertTrue(spans.contains { $0.kind == .filePath && $0.originalText == "~/src/app" })
        XCTAssertTrue(spans.contains { $0.kind == .shellFlag && $0.originalText == "--force" })
        XCTAssertTrue(spans.contains { $0.kind == .versionNumber && $0.originalText == "v2.1.0" })
        XCTAssertTrue(spans.contains { $0.kind == .currency && $0.originalText == "$50" })
    }

    func testAdversarialInputsDoNotInventSpans() {
        XCTAssertEqual(ProtectedSpanExtractor.extract(from: ""), [])
        XCTAssertEqual(ProtectedSpanExtractor.extract(from: "@"), [])
        XCTAssertEqual(ProtectedSpanExtractor.extract(from: String(repeating: "@", count: 100)), [])

        let marked = "hi 👨‍👩‍👧‍👦 cafe\u{0301}"
        XCTAssertEqual(ProtectedSpanExtractor.extract(from: marked), [])

        let spaced = "see /tmp/my file.txt please"
        let spacedSpans = ProtectedSpanExtractor.extract(from: spaced)
        XCTAssertEqual(
            spacedSpans.filter { $0.kind == .filePath }.map(\.originalText),
            ["/tmp/my"]
        )
        XCTAssertFalse(spacedSpans.contains { $0.originalText.contains(" ") })

        let short = "hi"
        let longerThanText = String(repeating: "z", count: (short as NSString).length + 8)
        let shortSpans = ProtectedSpanExtractor.extract(from: short, dictionaryTerms: [longerThanText])
        XCTAssertFalse(shortSpans.contains { $0.kind == .customDictionary })

        let overlapped = "ping dev@example.com now"
        let overlappedSpans = ProtectedSpanExtractor.extract(
            from: overlapped,
            dictionaryTerms: ["example.com"]
        )
        XCTAssertTrue(overlappedSpans.contains { $0.kind == .email && $0.originalText == "dev@example.com" })
        XCTAssertFalse(overlappedSpans.contains { $0.kind == .customDictionary })
    }
}

private final class ExplodingIfCalledCorrector: TranscriptCorrector, @unchecked Sendable {
    let descriptor = CorrectionProviderDescriptor(
        id: "explode.if.called",
        displayName: "Explode",
        modelVersion: "1",
        privacyRoute: .onDeviceOnly
    )
    private(set) var correctCallCount = 0

    func probe() async -> ProviderReadiness {
        .ready(ProviderEvidence(
            providerID: descriptor.id,
            modelVersion: "1",
            probeTimestamp: Date(),
            capabilities: []
        ))
    }

    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        correctCallCount += 1
        XCTFail("correct() must not run for a transcript over the protected-span ceiling")
        return CorrectionCandidate(text: "rewritten", providerID: descriptor.id, modelVersion: "1")
    }

    func cancel(sessionID: VoiceSessionID) async {}
}
