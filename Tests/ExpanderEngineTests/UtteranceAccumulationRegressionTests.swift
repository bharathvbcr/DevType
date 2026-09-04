import Foundation
import Speech
import XCTest
@testable import ExpanderEngine

/// Regression cover for the defect that made dictation destroy the user's text.
///
/// Reproduced from session `AC699E95-6F04-4593-B482-C645CA2727D1`: 32 seconds of speech,
/// three utterances, live typing put all 293 characters on screen — and the final delivery
/// erased them and typed back only the last sentence, 145 characters.
///
/// The cause was that `SFSpeechRecognizer` marks an utterance boundary by *replacing*
/// `bestTranscription.formattedString`, never by reporting `isFinal` mid-stream. The live
/// stream inferred that boundary; the batch adapter, whose transcript is the authoritative
/// one, did not — so its "final" result was whichever single utterance happened to be in
/// flight, and everything before it was dropped and then deleted from the document.
final class UtteranceAccumulationRegressionTests: XCTestCase {

    /// The three utterances exactly as the recognizer replaced them in the recorded session.
    private static let recordedUtterances = [
        "Voice typing has been the most unreliable thing so badly use it",
        "Because it's bad and it needs a major revert or completely re-architect how it done",
        "Even the speech recognition is not that great do you think is it because of the "
            + "Apple foundational models or do I need to use expensive models"
    ]

    // MARK: - The accumulator

    func testAccumulatorKeepsEveryUtteranceWhenRecognizerReplacesItsTranscript() {
        var accumulator = UtteranceAccumulator(idPrefix: "batch")

        for (index, utterance) in Self.recordedUtterances.enumerated() {
            // Each utterance arrives as a growing series of revisions, exactly as the
            // recognizer emits them, and then is replaced wholesale by the next one.
            for partial in Self.revisions(of: utterance) {
                _ = accumulator.ingest(text: partial, isFinal: false)
            }
            if index == Self.recordedUtterances.count - 1 {
                _ = accumulator.ingest(text: utterance, isFinal: true)
                accumulator.endpointReached()
            }
        }

        let cumulative = accumulator.cumulativeText
        for utterance in Self.recordedUtterances {
            XCTAssertTrue(
                cumulative.contains(utterance),
                "Utterance dropped from the accumulated transcript: \(utterance)"
            )
        }
        XCTAssertEqual(accumulator.sealedCount, 3, "Every utterance must be sealed exactly once")
    }

    func testAccumulatorDoesNotSealWhileTheSameUtteranceIsBeingRevised() {
        var accumulator = UtteranceAccumulator(idPrefix: "live")

        // A head rewrite inside one utterance: "What is" -> "What's the". Different first
        // word, same utterance — this must not be read as a boundary.
        _ = accumulator.ingest(text: "What is", isFinal: false)
        let step = accumulator.ingest(text: "What's the best way", isFinal: false)

        XCTAssertNil(step.sealed, "A revision of the utterance in flight must not seal it")
        XCTAssertFalse(step.openedNewUtterance)
        XCTAssertEqual(accumulator.sealedCount, 0)
        XCTAssertEqual(accumulator.cumulativeText, "What's the best way")
    }

    func testAccumulatorSealsThePreviousUtteranceUnderItsOwnIdentity() {
        var accumulator = UtteranceAccumulator(idPrefix: "live")

        _ = accumulator.ingest(text: "What's the best way?", isFinal: false)
        let step = accumulator.ingest(text: "To get there", isFinal: false)

        XCTAssertEqual(step.sealed?.text, "What's the best way?")
        XCTAssertEqual(step.sealed?.finality, .final)
        XCTAssertEqual(step.sealed?.segmentID, "live-0", "The sealed utterance keeps its own id")
        XCTAssertEqual(step.current.segmentID, "live-1", "The new utterance opens a new id")
        XCTAssertEqual(step.current.finality, .volatile)
        XCTAssertTrue(step.openedNewUtterance)
        XCTAssertEqual(accumulator.cumulativeText, "What's the best way? To get there")
    }

    func testAccumulatorDoesNotSealOnTheVeryFirstResult() {
        var accumulator = UtteranceAccumulator(idPrefix: "live")

        let step = accumulator.ingest(text: "Hello", isFinal: false)

        XCTAssertNil(step.sealed, "There is no previous utterance to seal")
        XCTAssertEqual(step.current.segmentID, "live-0")
        XCTAssertEqual(accumulator.sealedCount, 0)
    }

    func testAccumulatorNeverProducesADoubledSeparatorFromAnEmptyUtterance() {
        var accumulator = UtteranceAccumulator(idPrefix: "live")

        _ = accumulator.ingest(text: "First sentence.", isFinal: true)
        accumulator.endpointReached()
        // An endpoint that carried no speech at all.
        accumulator.endpointReached()
        _ = accumulator.ingest(text: "Second sentence.", isFinal: true)
        accumulator.endpointReached()

        XCTAssertEqual(accumulator.cumulativeText, "First sentence. Second sentence.")
        XCTAssertFalse(accumulator.cumulativeText.contains("  "))
    }

    func testAccumulatorStopsGrowingAtTheUtteranceCeiling() {
        var accumulator = UtteranceAccumulator(idPrefix: "live", maxUtterances: 4)

        for index in 0..<50 {
            _ = accumulator.ingest(text: "utterance number \(index)", isFinal: true)
            accumulator.endpointReached()
        }

        XCTAssertLessThanOrEqual(
            accumulator.sealedCount, 4,
            "A runaway session must not accumulate utterances without limit"
        )
    }

    func testSealInFlightReturnsNothingWhenTheUtteranceCarriedNoSpeech() {
        var accumulator = UtteranceAccumulator(idPrefix: "live")
        _ = accumulator.ingest(text: "   ", isFinal: false)

        XCTAssertNil(accumulator.sealInFlight(), "Whitespace is not an utterance")
    }

    // MARK: - The batch adapter, end to end

    /// The production failure, driven through the real adapter: three utterances in, the
    /// completion must carry all three rather than only the last.
    func testBatchAdapterCompletionCarriesEveryUtteranceNotOnlyTheLast() async throws {
        let adapter = LegacyAppleSpeechAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .authorized },
            runtimeFactory: { _ in Self.replayingRuntime(utterances: Self.recordedUtterances) }
        )

        var completion: SpeechCompletion?
        for try await event in adapter.transcribe(Self.makeRequest()) {
            if case .completed(let value) = event { completion = value }
        }

        let transcript = try XCTUnwrap(completion?.rawTranscript.text)
        for utterance in Self.recordedUtterances {
            XCTAssertTrue(
                transcript.contains(utterance),
                "Batch recognition dropped an utterance the recognizer had already produced: \(utterance)"
            )
        }
        XCTAssertEqual(completion?.finalSegmentCount, 3)
    }

    /// The adapter's own segment stream must describe what it recognized, so a consumer
    /// can tell that the completion is complete.
    func testBatchAdapterEmitsOneIdentityPerUtterance() async throws {
        let adapter = LegacyAppleSpeechAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .authorized },
            runtimeFactory: { _ in Self.replayingRuntime(utterances: Self.recordedUtterances) }
        )

        var segmentIDs: Set<String> = []
        for try await event in adapter.transcribe(Self.makeRequest()) {
            if case .segment(let segment) = event { segmentIDs.insert(segment.segmentID) }
        }

        XCTAssertEqual(segmentIDs.count, 3, "Three utterances must not share one segment identity")
    }

    /// A recognizer that stops on the empty-speech timeout after it has already produced
    /// utterances must not report an empty transcript over the top of them.
    func testBatchAdapterKeepsAccumulatedTextWhenRecognitionEndsOnSilenceTimeout() async throws {
        let utterances = ["First sentence here", "Totally different second one"]
        let runtime = Self.replayingRuntime(utterances: utterances, endWithSilenceTimeout: true)
        let adapter = LegacyAppleSpeechAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .authorized },
            runtimeFactory: { _ in runtime }
        )

        var completion: SpeechCompletion?
        for try await event in adapter.transcribe(Self.makeRequest()) {
            if case .completed(let value) = event { completion = value }
        }

        let transcript = try XCTUnwrap(completion?.rawTranscript.text)
        XCTAssertTrue(transcript.contains(utterances[0]))
        XCTAssertTrue(transcript.contains(utterances[1]))
    }

    // MARK: - Helpers

    /// Splits an utterance into the growing partials a recognizer emits for it.
    private static func revisions(of utterance: String) -> [String] {
        let words = utterance.split(separator: " ")
        return (1...words.count).map { words.prefix($0).joined(separator: " ") }
    }

    /// A runtime that replays utterances the way `SFSpeechRecognizer` does: growing
    /// partials, then the whole result *replaced* by the next utterance.
    private static func replayingRuntime(
        utterances: [String],
        endWithSilenceTimeout: Bool = false
    ) -> AppleOnDeviceSpeechRuntime {
        AppleOnDeviceSpeechRuntime(
            isAvailable: { true },
            supportsOnDeviceRecognition: { true },
            startRecognition: { _, resultHandler in
                for (index, utterance) in utterances.enumerated() {
                    let isLast = index == utterances.count - 1
                    for partial in revisions(of: utterance) {
                        let final = isLast && !endWithSilenceTimeout && partial == utterance
                        resultHandler(StubRecognitionResult(text: partial, isFinal: final), nil)
                    }
                }
                if endWithSilenceTimeout {
                    resultHandler(nil, NSError(domain: "kAFAssistantErrorDomain", code: 203))
                }
                return AppleSpeechTaskHandle(cancel: {})
            }
        )
    }

    private static func makeRequest() -> SpeechRequest {
        SpeechRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            audio: AudioArtifact(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("utterance-accumulation.caf"),
                format: "caf",
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: 512_000,
                durationSeconds: 32,
                byteCount: 1_028_096,
                sha256Hex: "redacted",
                gapCount: 0
            ),
            locale: Locale(identifier: "en-US"),
            deadline: Date().addingTimeInterval(30),
            privacyRoute: .onDeviceOnly
        )
    }
}

/// Apple ships no way to construct a recognition result, and the adapter's whole contract is
/// how it reacts to a sequence of them, so the two classes are subclassed with stubbed
/// accessors. Nothing here calls into the Speech framework.
private final class StubTranscription: SFTranscription {
    private let stubbed: String
    init(text: String) {
        self.stubbed = text
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var formattedString: String { stubbed }
    override var segments: [SFTranscriptionSegment] { [] }
}

private final class StubRecognitionResult: SFSpeechRecognitionResult {
    private let stubbedTranscription: SFTranscription
    private let stubbedIsFinal: Bool
    init(text: String, isFinal: Bool) {
        self.stubbedTranscription = StubTranscription(text: text)
        self.stubbedIsFinal = isFinal
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var bestTranscription: SFTranscription { stubbedTranscription }
    override var transcriptions: [SFTranscription] { [stubbedTranscription] }
    override var isFinal: Bool { stubbedIsFinal }
}
