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

    func testMaximumUTF16LengthIsTheClaimedCeiling() {
        XCTAssertEqual(ProtectedSpanExtractor.maximumUTF16Length, 32_768)
    }

    /// Oracle is the pre-replacement path on short strings only: NSDataDetector,
    /// then the ICU email pattern compiled case-insensitively, then the other
    /// production patterns. The email pattern is never applied to a long input.
    func testLinearEmailMatchesTheICUPatternOnShortHostileStrings() throws {
        let tld64 = String(repeating: "a", count: 64)
        let tld65 = String(repeating: "a", count: 65)
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}dev@example.com"
        let grin = "\u{1F600}dev@example.com"
        let samples = [
            "a@b.co",
            "a@b.c",
            "a@.com",
            "a@-b.com",
            "a@b-.com",
            "a@b.com-",
            "user@foo.bar.com",
            "user@foo.com.a",
            "a+b@c.co",
            "a%b@c.co",
            "a..b@c.co",
            "A@B.CO",
            "see (dev@example.com).",
            "a@b.co and c@d.co",
            "foo@bar@baz",
            "notanemail@",
            "user@localhost",
            "cost is 5@home today",
            "reach me @b.co",
            "a\u{FF20}b.co",
            "dev\u{FF20}example.com",
            family,
            grin,
            "dev@example.com\u{1F600}",
            "a@b.\(tld64)",
            "a@b.\(tld65)",
            "a@b.co\nc@d.co",
            "\u{0000}a@b.co",
            "a@b.co\u{0000}",
            "a\u{0000}b@c.co",
            "a@b\u{0000}.co",
            "a@b.c\u{017F}",
            "a@b.co\u{017F}",
            "a@b.\u{017F}o",
            "a@b.co\u{212A}",
            "a@b.c\u{212A}",
            "a@b.\u{212A}o",
            "a@b.com\u{017F}",
            "\u{017F}@b.co",
            "a\u{212A}@b.co",
            "a@\u{017F}b.co",
            "a@b\u{212A}.co",
        ]
        for text in samples {
            XCTAssertLessThan((text as NSString).length, 200, text)
            let got = ProtectedSpanExtractor.extract(from: text)
            let expected = try legacyProtectedSpans(from: text)
            let gotKeys = spanKeys(got)
            let expectedKeys = spanKeys(expected)
            auditLog("EMAIL \(debugLiteral(text)) got=\(gotKeys) legacy=\(expectedKeys)")
            XCTAssertEqual(gotKeys, expectedKeys, debugLiteral(text))
            let ns = text as NSString
            for span in got {
                let range = NSRange(location: span.utf16RangeStart, length: span.utf16RangeLength)
                XCTAssertGreaterThanOrEqual(range.location, 0, debugLiteral(text))
                XCTAssertLessThanOrEqual(NSMaxRange(range), ns.length, debugLiteral(text))
                XCTAssertEqual(ns.substring(with: range), span.originalText, debugLiteral(text))
            }
        }
        for text in [family, grin] {
            let emails = ProtectedSpanExtractor.extract(from: text).filter { $0.kind == .email }
            XCTAssertEqual(emails.map(\.originalText), ["dev@example.com"], debugLiteral(text))
            let emailUTF16 = ("dev@example.com" as NSString).length
            XCTAssertEqual(emails.first?.utf16RangeStart, (text as NSString).length - emailUTF16, debugLiteral(text))
        }
    }

    func testEmptySingleCharacterNewlineAndNul() throws {
        for text in ["", "a", "\n", "\u{0000}", "@", "."] {
            let got = ProtectedSpanExtractor.extract(from: text)
            XCTAssertEqual(spanKeys(got), spanKeys(try legacyProtectedSpans(from: text)), debugLiteral(text))
        }
        let embedded = "a@b.co\u{0000}c@d.co"
        let got = ProtectedSpanExtractor.extract(from: embedded)
        XCTAssertEqual(spanKeys(got), spanKeys(try legacyProtectedSpans(from: embedded)), debugLiteral(embedded))
        let ns = embedded as NSString
        for span in got where span.kind == .email {
            let range = NSRange(location: span.utf16RangeStart, length: span.utf16RangeLength)
            XCTAssertEqual(ns.substring(with: range), span.originalText)
            XCTAssertFalse(span.originalText.contains("\u{0000}"))
        }
    }

    func testExactCeilingStillScansAndCallsTheCorrector() async {
        let email = "dev@example.com"
        let text = padded(email, utf16Length: ProtectedSpanExtractor.maximumUTF16Length)
        XCTAssertEqual((text as NSString).length, 32_768)
        let spans = ProtectedSpanExtractor.extract(from: text)
        let directEmails = spans.filter { $0.kind == .email }
        auditLog("CEILING direct \(directEmails.map { "\($0.utf16RangeStart)+\($0.utf16RangeLength) prefix=\($0.originalText.prefix(32))" })")
        XCTAssertFalse(directEmails.isEmpty, "a transcript of length 32768 that starts with an email produced no email span")
        XCTAssertTrue(directEmails.contains { $0.originalText.hasPrefix(email) })

        let corrector = StubCorrector(behavior: .transform { $0 })
        let final = await runPipeline(text, corrector: corrector)
        XCTAssertEqual(corrector.correctCallCount, 1)
        XCTAssertEqual(final.text, text)
        let requested = corrector.lastRequest?.protectedSpans ?? []
        let requestedEmails = requested.filter { $0.kind == .email }
        auditLog("CEILING request \(requestedEmails.map { "\($0.utf16RangeStart)+\($0.utf16RangeLength) prefix=\($0.originalText.prefix(32))" })")
        XCTAssertEqual(requestedEmails.map(\.originalText), directEmails.map(\.originalText))
        XCTAssertTrue(requestedEmails.contains { $0.originalText.hasPrefix(email) })
    }

    func testOnePastTheCeilingSkipsTheCorrectorEvenWhenAnEmailIsPresent() async {
        let email = "dev@example.com"
        let text = padded(email, utf16Length: ProtectedSpanExtractor.maximumUTF16Length + 1)
        XCTAssertEqual((text as NSString).length, 32_769)
        let clock = ContinuousClock()
        var spans: [ProtectedSpan] = []
        let elapsed = clock.measure {
            spans = ProtectedSpanExtractor.extract(from: text)
        }
        auditLog("TIMING over-ceiling-with-email ms=\(milliseconds(elapsed)) spans=\(spans.count)")
        XCTAssertEqual(spans, [])
        XCTAssertLessThan(elapsed, .milliseconds(50), "extract took \(elapsed)")

        let corrector = StubCorrector(behavior: .transform { $0 })
        let final = await runPipeline(text, corrector: corrector)
        XCTAssertEqual(corrector.correctCallCount, 0)
        XCTAssertEqual(final.text, text)
        XCTAssertNil(final.correctionCandidate)
        XCTAssertEqual(final.validationOutcome, .notApplicable)
    }

    func testCeilingUsesUTF16LengthNotCharacterCount() async {
        let underCharactersOverUTF16 = String(repeating: "\u{1F600}", count: 20_000)
        XCTAssertLessThan(underCharactersOverUTF16.count, ProtectedSpanExtractor.maximumUTF16Length)
        XCTAssertGreaterThan((underCharactersOverUTF16 as NSString).length, ProtectedSpanExtractor.maximumUTF16Length)
        XCTAssertEqual(ProtectedSpanExtractor.extract(from: underCharactersOverUTF16), [])
        let skipped = StubCorrector(behavior: .transform { $0 })
        let skippedFinal = await runPipeline(underCharactersOverUTF16, corrector: skipped)
        XCTAssertEqual(skipped.correctCallCount, 0)
        XCTAssertEqual(skippedFinal.validationOutcome, .notApplicable)
        XCTAssertEqual(skippedFinal.text, underCharactersOverUTF16)

        let exact = String(repeating: "\u{1F600}", count: 16_384)
        XCTAssertEqual((exact as NSString).length, 32_768)
        XCTAssertEqual(exact.count, 16_384)
        let called = StubCorrector(behavior: .transform { $0 })
        let calledFinal = await runPipeline(exact, corrector: called)
        XCTAssertEqual(called.correctCallCount, 1)
        XCTAssertEqual(calledFinal.text, exact)
    }

    func testHostileShapesJustUnderAndJustOverTheCeiling() {
        let units = [
            ("a", "a"),
            ("eacute", "\u{00E9}"),
            ("slash-a", "/a"),
            ("one-dot", "1."),
            ("version", "1.2.3"),
            ("dash", "-"),
            ("at", "@"),
            ("mini-email", "@a.bc"),
        ]
        for (name, unit) in units {
            for length in [32_767, 32_769] {
                let text = repeated(unit, utf16Length: length)
                XCTAssertEqual((text as NSString).length, length, "\(name) \(length)")
                let clock = ContinuousClock()
                var spans: [ProtectedSpan] = []
                let elapsed = clock.measure {
                    spans = ProtectedSpanExtractor.extract(from: text)
                }
                auditLog("TIMING \(name) utf16=\(length) ms=\(String(format: "%.3f", milliseconds(elapsed))) spans=\(spans.count)")
                if length > ProtectedSpanExtractor.maximumUTF16Length {
                    XCTAssertEqual(spans, [], "\(name) over the ceiling must not scan")
                    XCTAssertLessThan(elapsed, .milliseconds(50), "\(name) over the ceiling took \(elapsed)")
                } else if name == "mini-email" {
                    XCTAssertLessThan(
                        elapsed,
                        .milliseconds(250),
                        "repeated @a.bc under the ceiling took \(elapsed) spans=\(spans.count)"
                    )
                }
            }
        }
    }

    func testTwoThousandRepeatedDictionaryTermsStayUnderOneSecond() {
        let term = String(repeating: "a", count: 32)
        let terms = Array(repeating: term, count: 2_000)
        let text = String(repeating: "a", count: 32_767)
        XCTAssertEqual((text as NSString).length, 32_767)
        let clock = ContinuousClock()
        var spans: [ProtectedSpan] = []
        let elapsed = clock.measure {
            spans = ProtectedSpanExtractor.extract(from: text, dictionaryTerms: terms)
        }
        auditLog("TIMING dictionary-2000x32 utf16=32767 ms=\(String(format: "%.3f", milliseconds(elapsed))) spans=\(spans.count)")
        XCTAssertEqual(spans.count, 1_023, "expected non-overlapping 32-character hits, got \(spans.count)")
        XCTAssertLessThan(
            elapsed,
            .seconds(1),
            "2000 copies of a 32-character term against 32767 'a's took \(elapsed) and produced \(spans.count) spans"
        )
    }

    func testDictionaryTermsPastTheCeilingDoNotScan() {
        let term = String(repeating: "a", count: 32)
        let terms = Array(repeating: term, count: 2_000)
        let text = String(repeating: "a", count: 32_769)
        let clock = ContinuousClock()
        var spans: [ProtectedSpan] = []
        let elapsed = clock.measure {
            spans = ProtectedSpanExtractor.extract(from: text, dictionaryTerms: terms)
        }
        auditLog("TIMING dictionary-2000x32 utf16=32769 ms=\(String(format: "%.3f", milliseconds(elapsed))) spans=\(spans.count)")
        XCTAssertEqual(spans, [])
        XCTAssertLessThan(elapsed, .milliseconds(50), "extract took \(elapsed)")
    }

    private func runPipeline(_ text: String, corrector: StubCorrector) async -> FinalTranscript {
        await CorrectionPipeline.execute(
            rawTranscript: RawTranscript(
                text: text,
                localeIdentifier: "en_US",
                providerID: "test",
                modelVersion: "1"
            ),
            corrector: corrector,
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(30),
            privacyRoute: .onDeviceOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )
    }
}

private func padded(_ prefix: String, utf16Length: Int) -> String {
    let prefixLength = (prefix as NSString).length
    precondition(prefixLength <= utf16Length)
    return prefix + String(repeating: "a", count: utf16Length - prefixLength)
}

private func repeated(_ unit: String, utf16Length: Int) -> String {
    let nsUnit = unit as NSString
    precondition(nsUnit.length > 0)
    let copies = utf16Length / nsUnit.length
    let remainder = utf16Length % nsUnit.length
    var text = String(repeating: unit, count: copies)
    if remainder > 0 {
        text += nsUnit.substring(to: remainder)
    }
    return text
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

private func auditLog(_ line: String) {
    print(line)
    let path = "/tmp/devtype-span-audit.txt"
    let data = Data((line + "\n").utf8)
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

private func debugLiteral(_ text: String) -> String {
    text.unicodeScalars.map { scalar -> String in
        let value = scalar.value
        if value >= 32 && value < 127 && scalar != "\\" {
            return String(scalar)
        }
        return String(format: "\\u{%04X}", value)
    }.joined()
}

private func spanKeys(_ spans: [ProtectedSpan]) -> [String] {
    spans.map { span in
        "\(span.kind.rawValue)@\(span.utf16RangeStart)+\(span.utf16RangeLength)=\(span.originalText)"
    }.sorted()
}

/// Detector, then the ICU email pattern, then the other compiled patterns.
/// This is the extract path from before the linear email scan. Short strings only.
private func legacyProtectedSpans(from text: String) throws -> [ProtectedSpan] {
    let emailRegex = try NSRegularExpression(
        pattern: #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}"#,
        options: [.caseInsensitive]
    )
    let nsString = text as NSString
    let fullRange = NSRange(location: 0, length: nsString.length)
    var spans: [ProtectedSpan] = []

    if let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
        for match in urlDetector.matches(in: text, options: [], range: fullRange) {
            let matchText = nsString.substring(with: match.range)
            let isEmail = match.url?.scheme == "mailto" || (matchText.contains("@") && !matchText.contains("://"))
            spans.append(ProtectedSpan(
                kind: isEmail ? .email : .url,
                originalText: matchText,
                canonicalForm: matchText,
                utf16RangeStart: match.range.location,
                utf16RangeLength: match.range.length
            ))
        }
    }

    func appendMatches(kind: ProtectedSpanKind, regex: NSRegularExpression) {
        for match in regex.matches(in: text, options: [], range: fullRange) {
            let overlapped = spans.contains { existing in
                NSIntersectionRange(
                    match.range,
                    NSRange(location: existing.utf16RangeStart, length: existing.utf16RangeLength)
                ).length > 0
            }
            if overlapped { continue }
            let matchText = nsString.substring(with: match.range)
            spans.append(ProtectedSpan(
                kind: kind,
                originalText: matchText,
                canonicalForm: matchText,
                utf16RangeStart: match.range.location,
                utf16RangeLength: match.range.length
            ))
        }
    }

    appendMatches(kind: .email, regex: emailRegex)
    for (kind, regex) in ProtectedSpanExtractor.patterns where kind != .email {
        appendMatches(kind: kind, regex: regex)
    }
    return spans.sorted { $0.utf16RangeStart < $1.utf16RangeStart }
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
