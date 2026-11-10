import Foundation
import Speech
import XCTest
@testable import ExpanderEngine

/// Apple accepts at most 100 contextual strings. Whitespace-only entries must not take a slot.
/// These read the request objects the live and file paths hand to recognition, and the array the
/// analyzer writes onto its context. No microphone and no recognition task is started.
final class ContextualStringCapTests: XCTestCase {
    func testOneHundredOneNonEmptyTermsAssignOneHundredOnEveryAppleRequest() {
        let terms = (0..<101).map { "term-\($0)" }
        let expected = Array(terms.prefix(100))

        XCTAssertEqual(liveContextualStrings(from: terms), expected)
        XCTAssertEqual(fileContextualStrings(from: terms), expected)
        XCTAssertEqual(analyzerContextualStrings(from: terms), expected)
    }

    func testOneHundredTermsPlusOneBlankStillAssignOneHundred() {
        let real = (0..<100).map { "term-\($0)" }
        let leadingBlank = ["   "] + real
        let embeddedEmpty = Array(real.prefix(40)) + [""] + Array(real.suffix(60))
        let paddedFirst = ["  term-0  "] + Array(real.dropFirst()) + [" \n "]

        XCTAssertEqual(liveContextualStrings(from: leadingBlank), real)
        XCTAssertEqual(fileContextualStrings(from: leadingBlank), real)
        XCTAssertEqual(analyzerContextualStrings(from: leadingBlank), real)

        XCTAssertEqual(liveContextualStrings(from: embeddedEmpty), real)
        XCTAssertEqual(fileContextualStrings(from: embeddedEmpty), real)
        XCTAssertEqual(analyzerContextualStrings(from: embeddedEmpty), real)

        let trimmed = ["term-0"] + Array(real.dropFirst())
        XCTAssertEqual(liveContextualStrings(from: paddedFirst), trimmed)
        XCTAssertEqual(fileContextualStrings(from: paddedFirst), trimmed)
        XCTAssertEqual(analyzerContextualStrings(from: paddedFirst), trimmed)
    }

    func testEmptyOrWhitespaceOnlyTermsLeaveContextualStringsUnassigned() {
        for terms in [[String](), ["", "   ", "\n"]] {
            XCTAssertEqual(liveContextualStrings(from: terms), [])
            XCTAssertEqual(fileContextualStrings(from: terms), [])
            XCTAssertEqual(analyzerContextualStrings(from: terms), [])
        }
    }

    func testCountsAtZeroOneExactlyOneHundredOneHundredOneAndOneThousand() {
        assertAssigned([], equals: [])
        assertAssigned(["only"], equals: ["only"])

        let hundred = (0..<100).map { "h-\($0)" }
        assertAssigned(hundred, equals: hundred)

        let onePast = (0..<101).map { "i-\($0)" }
        assertAssigned(onePast, equals: Array(onePast.prefix(100)))
        let pastCap = liveContextualStrings(from: onePast)
        XCTAssertEqual(pastCap.first, "i-0")
        XCTAssertEqual(pastCap.last, "i-99")
        XCTAssertFalse(pastCap.contains("i-100"))

        let thousand = (0..<1000).map { String(format: "%04d", $0) }
        let firstHundred = (0..<100).map { String(format: "%04d", $0) }
        let lastHundred = (900..<1000).map { String(format: "%04d", $0) }
        assertAssigned(thousand, equals: firstHundred)
        XCTAssertNotEqual(liveContextualStrings(from: thousand), lastHundred)
        XCTAssertNotEqual(fileContextualStrings(from: thousand), lastHundred)
        XCTAssertFalse(analyzerContextualStrings(from: thousand).contains("0100"))
        XCTAssertFalse(analyzerContextualStrings(from: thousand).contains("0999"))
    }

    /// A raw `prefix(100)` keeps the leading blank and drops the 100th real term.
    func testLeadingBlankDoesNotTakeASlotTheWayRawPrefixWould() {
        let real = (0..<100).map { "kept-\($0)" }
        let raw = ["\n", " \t ", ""] + real + ["overflow"]
        let rawPrefix = Array(raw.prefix(100))
        XCTAssertEqual(rawPrefix.first, "\n")
        XCTAssertFalse(rawPrefix.contains("kept-99"))

        assertAssigned(raw, equals: real)
        XCTAssertNotEqual(liveContextualStrings(from: raw), rawPrefix)
        XCTAssertNotEqual(fileContextualStrings(from: raw), rawPrefix)
        XCTAssertNotEqual(analyzerContextualStrings(from: raw), rawPrefix)
    }

    func testBlankAndTrimmedEmptyTermsDoNotConsumeSlotsAheadOfLaterRealTerms() {
        let junk = ["", " ", "\n", "\r", "\r\n", "\t", " \n\t ", "\u{000B}", "\u{000C}", "  \n\t  "]
        let real = (0..<100).map { "r-\($0)" }
        let overflow = (0..<20).map { "overflow-\($0)" }
        var mixed: [String] = []
        for (index, term) in real.enumerated() {
            if index.isMultiple(of: 7) {
                mixed.append(junk[index % junk.count])
            }
            mixed.append(index == 3 ? "  \(term)  " : term)
        }
        mixed.append(contentsOf: junk)
        mixed.append(contentsOf: overflow)

        assertAssigned(mixed, equals: real)
        let assigned = fileContextualStrings(from: mixed)
        XCTAssertEqual(assigned.count, 100)
        XCTAssertEqual(assigned.last, "r-99")
        XCTAssertFalse(assigned.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertFalse(assigned.contains(where: { $0.hasPrefix("overflow-") }))
    }

    func testOrderIsTheFirstHundredAfterFilteringNotTheLastHundred() {
        let blanks = ["", "\n", "   "]
        let head = (0..<100).map { "head-\($0)" }
        let tail = (0..<100).map { "tail-\($0)" }
        let input = blanks + head + blanks + tail

        assertAssigned(input, equals: head)
        XCTAssertNotEqual(liveContextualStrings(from: input), tail)
        XCTAssertEqual(fileContextualStrings(from: input).first, "head-0")
        XCTAssertEqual(analyzerContextualStrings(from: input).last, "head-99")
    }

    func testUnicodeCombiningMarksZWJAndRTLCountAsOneTermWithoutALengthCap() {
        let combining = "e\u{0301}"
        let zwj = "👩\u{200D}💻"
        let zwjAlone = "\u{200D}"
        let rtl = "مرحبا"
        let bidi = "\u{202E}abc"
        let spaced = "  café  "
        let embeddedNewline = "  alpha\nbeta  "
        let long = String(repeating: "你", count: 50_000)
        let fillers = (0..<92).map { "fill-\($0)" }
        let input = ["\n", combining, zwj, zwjAlone, rtl, bidi, spaced, embeddedNewline, long] + fillers + ["past-cap"]

        let expected = [combining, zwj, zwjAlone, rtl, bidi, "café", "alpha\nbeta", long] + fillers
        assertAssigned(input, equals: expected)

        let live = liveContextualStrings(from: input)
        XCTAssertEqual(live.count, 100)
        XCTAssertEqual(live[0].unicodeScalars.count, combining.unicodeScalars.count)
        XCTAssertEqual(live[1], zwj)
        XCTAssertEqual(live[7].count, 50_000)
        XCTAssertFalse(live.contains("past-cap"))
        XCTAssertEqual(fileContextualStrings(from: [long]), [long])
    }

    func testDuplicateTermsAreKeptRatherThanUniqued() {
        assertAssigned(Array(repeating: "same", count: 150), equals: Array(repeating: "same", count: 100))
        assertAssigned(
            ["dup", "  ", "dup", "\n", "dup", " \t "],
            equals: ["dup", "dup", "dup"]
        )
        let alternating = (0..<120).flatMap { index in ["dup-\(index % 3)", index.isMultiple(of: 2) ? "\n" : " "] }
        let filtered = alternating.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        assertAssigned(alternating, equals: Array(filtered.prefix(100)))
        XCTAssertGreaterThan(liveContextualStrings(from: alternating).filter { $0 == "dup-0" }.count, 1)
    }

    private func assertAssigned(
        _ terms: [String],
        equals expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let live = liveContextualStrings(from: terms)
        let fileRequest = fileContextualStrings(from: terms)
        let analyzer = analyzerContextualStrings(from: terms)
        XCTAssertEqual(live, expected, "live request", file: file, line: line)
        XCTAssertEqual(fileRequest, expected, "file request", file: file, line: line)
        XCTAssertEqual(analyzer, expected, "analyzer contextualTerms", file: file, line: line)
        XCTAssertEqual(live, analyzer, "live builder diverged from contextualTerms", file: file, line: line)
        XCTAssertEqual(fileRequest, analyzer, "file builder diverged from contextualTerms", file: file, line: line)
    }

    private func liveContextualStrings(from terms: [String]) -> [String] {
        LiveSpeechStream.audioBufferRecognitionRequest(contextualStrings: terms).contextualStrings
    }

    private func fileContextualStrings(from terms: [String]) -> [String] {
        LegacyAppleSpeechAdapter.urlRecognitionRequest(for: Self.speechRequest(terms: terms)).contextualStrings
    }

    /// `SystemAppleSpeechAnalyzerRuntime` assigns this array to `AnalysisContext.contextualStrings`.
    /// Building that context would start the system speech stack, so the shared helper is the request value.
    private func analyzerContextualStrings(from terms: [String]) -> [String] {
        AppleSpeechAnalyzerRuntime.contextualTerms(from: terms)
    }

    private static func speechRequest(terms: [String]) -> SpeechRequest {
        SpeechRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            audio: AudioArtifact(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("contextual-cap-probe.caf"),
                format: "caf",
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: 1,
                durationSeconds: 0.001,
                byteCount: 2,
                sha256Hex: "contextual-cap",
                gapCount: 0
            ),
            locale: Locale(identifier: "en-US"),
            vocabulary: VocabularySnapshot(terms: terms),
            deadline: Date().addingTimeInterval(1),
            privacyRoute: .onDeviceOnly
        )
    }
}
