import XCTest
@testable import ExpanderEngine

/// The real recognizer behaviour, captured from a live dictation trace.
///
/// `SFSpeechRecognizer`, fed from an audio buffer, does **not** behave the way the earlier
/// fixes assumed. Across a pause it:
///
///   - keeps the **same task** (one `stream.taskStarted` for the whole session),
///   - keeps the **same segment**, revising it in place,
///   - never reports `isFinal` mid-stream, and
///   - **resets `bestTranscription.formattedString` to only the new utterance.**
///
/// That last point is the defect. The transcript shrinks from the previous utterance to the
/// new one, and anything downstream that treats `formattedString` as cumulative sees the
/// text disappear — and erases it from the document to match.
///
/// Captured sequence, from `voice-trace.jsonl`:
///
///     rev=7   "What's the best way?"    erase=0
///     rev=8   "To"                      erase=20   ← the whole utterance wiped
///     rev=9   "To describe"
///     rev=12  "To describe the problem"  isFinal=true
final class RecognizerUtteranceResetTests: XCTestCase {

    /// Verbatim from the captured trace.
    private static let capturedResults: [(revision: UInt64, text: String, isFinal: Bool)] = [
        (1,  "What", false),
        (2,  "What is", false),
        (3,  "What's the", false),
        (4,  "What's the best", false),
        (5,  "What's the best way", false),
        (6,  "What's the best way?", false),
        (7,  "What's the best way?", false),
        (8,  "To", false),                       // ← pause: the recognizer resets here
        (9,  "To describe", false),
        (10, "To describe the", false),
        (11, "To describe the problem", false),
        (12, "To describe the problem", true),
    ]

    // MARK: - Reset detection

    /// A reset is a result that shares no leading content with the one before it. Revisions
    /// — adding words, fixing case, adding punctuation, even shrinking as the acoustic
    /// model changes its mind — always keep a common word prefix.
    func testResetIsDistinguishedFromRevision() {
        // Real resets.
        XCTAssertTrue(UtteranceBoundaryDetector.isReset(previous: "What's the best way?", current: "To"))
        XCTAssertTrue(UtteranceBoundaryDetector.isReset(previous: "hello world", current: "next sentence"))

        // Growth.
        XCTAssertFalse(UtteranceBoundaryDetector.isReset(previous: "What", current: "What is"))
        XCTAssertFalse(UtteranceBoundaryDetector.isReset(previous: "To", current: "To describe"))

        // Re-casing and punctuation — the exact shape that made a prefix diff wipe the line.
        XCTAssertFalse(UtteranceBoundaryDetector.isReset(previous: "hello world", current: "Hello, world."))
        XCTAssertFalse(UtteranceBoundaryDetector.isReset(previous: "What is", current: "What's the"))

        // The acoustic model shortening its own guess is a revision, not a new utterance.
        XCTAssertFalse(UtteranceBoundaryDetector.isReset(previous: "this is a long guess", current: "this is"))

        // Degenerate input.
        XCTAssertFalse(UtteranceBoundaryDetector.isReset(previous: "", current: "anything"))
        XCTAssertFalse(UtteranceBoundaryDetector.isReset(previous: "something", current: ""))
    }

    // MARK: - The captured session, end to end

    /// Replaying the real trace must preserve both utterances.
    func testCapturedSessionKeepsBothUtterances() {
        var assembler = LiveTranscriptAssembler()
        let reconciler = VoiceTranscriptReconciler()
        var document = ""
        var maximumErase = 0

        for segment in Self.segmentStream() {
            guard assembler.ingest(segment) else { continue }
            let edit = reconciler.reconcile(target: assembler.cumulativeText)
            maximumErase = max(maximumErase, edit.eraseCount)

            XCTAssertLessThanOrEqual(edit.eraseCount, document.count)
            document.removeLast(min(edit.eraseCount, document.count))
            document += edit.textToInject

            reconciler.sealPrefix(assembler.settledText)
        }

        XCTAssertTrue(
            document.contains("What's the best way?"),
            "The first utterance was lost across the pause: \(document)"
        )
        XCTAssertTrue(document.contains("To describe the problem"))
        XCTAssertLessThan(
            maximumErase, 20,
            "Something still erased a whole utterance (max erase \(maximumErase))"
        )
    }

    /// The boundary must produce a *new* segment, so the finished utterance can be sealed.
    func testResetOpensANewSegment() {
        let stream = Self.segmentStream()
        let ids = Set(stream.map(\.segmentID))

        XCTAssertEqual(ids.count, 2, "Expected one segment per utterance, got \(ids.sorted())")

        // The first utterance must be sealed, or it stays erasable forever.
        let firstID = stream[0].segmentID
        XCTAssertTrue(
            stream.contains { $0.segmentID == firstID && $0.finality == .final },
            "The first utterance was never finalised"
        )
    }

    /// Whatever the recognizer does, no spoken word may be dropped.
    func testNoSpokenWordsAreLost() {
        var assembler = LiveTranscriptAssembler()
        for segment in Self.segmentStream() {
            _ = assembler.ingest(segment)
        }
        for word in ["What's", "best", "way", "describe", "problem"] {
            XCTAssertTrue(
                assembler.cumulativeText.contains(word),
                "Lost \"\(word)\" from: \(assembler.cumulativeText)"
            )
        }
    }

    // MARK: - False boundaries

    /// The costlier error is the opposite one: calling a boundary mid-utterance seals text
    /// the recognizer is still editing, so later corrections can no longer be applied.
    /// Growing a phrase word by word, with the case and punctuation churn the recognizer
    /// actually produces, must never look like a boundary.
    func testGrowingAnUtteranceNeverLooksLikeABoundary() {
        var rng = SplitMix64(seed: 0xA11CE)
        let vocabulary = ["the", "deploy", "gateway", "parser", "latency", "review", "today", "problem"]

        for _ in 0..<500 {
            var words: [String] = []
            var previous = ""

            for _ in 0..<Int(rng.next() % 12 + 2) {
                words.append(vocabulary[Int(rng.next() % UInt64(vocabulary.count))])
                var current = words.joined(separator: " ")

                // The recognizer re-cases and re-punctuates as it goes.
                if rng.next() % 2 == 0 { current = current.prefix(1).uppercased() + current.dropFirst() }
                if rng.next() % 3 == 0 { current += "." }
                if rng.next() % 4 == 0 { current = current.replacingOccurrences(of: " ", with: ", ") }

                XCTAssertFalse(
                    UtteranceBoundaryDetector.isReset(previous: previous, current: current),
                    "False boundary while growing: \(previous.debugDescription) → \(current.debugDescription)"
                )
                previous = current
            }
        }
    }

    /// The acoustic model shortening its own guess is a revision. Only a genuinely
    /// different phrase is a boundary.
    func testShrinkingRevisionIsNotABoundary() {
        let phrase = "deploy the gateway at three tomorrow"
        let words = phrase.split(separator: " ").map(String.init)

        for count in 1..<words.count {
            let shortened = words.prefix(count).joined(separator: " ")
            XCTAssertFalse(
                UtteranceBoundaryDetector.isReset(previous: phrase, current: shortened),
                "Shortening to \(shortened.debugDescription) was read as a new utterance"
            )
        }
    }

    /// Two genuinely different utterances are always a boundary, whatever they are.
    func testUnrelatedPhrasesAreAlwaysBoundaries() {
        let pairs = [
            ("What's the best way?", "To describe the problem"),
            ("Ship it on Friday.", "Actually let me check"),
            ("Deploy the gateway", "Roll it back"),
            ("Hello there", "Goodbye now"),
        ]
        for (previous, current) in pairs {
            XCTAssertTrue(
                UtteranceBoundaryDetector.isReset(previous: previous, current: current),
                "Missed a boundary: \(previous.debugDescription) → \(current.debugDescription)"
            )
        }
    }

    // MARK: - Helper

    /// Runs the captured results through the same boundary logic `LiveSpeechStream` uses.
    private static func segmentStream() -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        var index = 0
        var revision: UInt64 = 0
        var previous = ""

        for captured in capturedResults {
            if UtteranceBoundaryDetector.isReset(previous: previous, current: captured.text) {
                // Seal what came before under its own id, then open the next utterance.
                revision += 1
                segments.append(SpeechSegment(
                    segmentID: "live-\(index)", revision: revision, text: previous, finality: .final
                ))
                index += 1
                revision = 0
            }
            revision += 1
            segments.append(SpeechSegment(
                segmentID: "live-\(index)",
                revision: revision,
                text: captured.text,
                finality: captured.isFinal ? .final : .volatile
            ))
            previous = captured.text
        }
        return segments
    }
}
