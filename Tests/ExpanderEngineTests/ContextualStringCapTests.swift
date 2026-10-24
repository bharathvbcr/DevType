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
