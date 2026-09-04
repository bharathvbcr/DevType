import Foundation
import Speech
import XCTest
@testable import ExpanderEngine

/// The three gaps left open after the utterance-accumulation fix.
///
/// The accumulator repaired the one provider that was losing text. These cover the layers that
/// decide what happens when *any* provider does — plus the trace noise that made the original
/// defect hard to see in the first place.
final class VoiceRecognitionEvidenceTests: XCTestCase {

    // MARK: - A completion is checked against the provider's own segments

    func testACompletionThatContradictsItsOwnSegmentsDownwardLosesToThem() {
        let segments = Self.segments([
            "Voice typing has been the most unreliable thing so badly use it",
            "Because it's bad and it needs a major revert",
            "Even the speech recognition is not that great"
        ])
        // The exact shape of the production defect: only the last utterance is claimed.
        let completion = Self.completion(text: "Even the speech recognition is not that great")

        let raw = VoiceSessionReducer.reconcileCompletion(completion, against: segments)

        XCTAssertTrue(raw.text.contains("Voice typing has been"))
        XCTAssertTrue(raw.text.contains("Because it's bad"))
        XCTAssertTrue(raw.text.contains("Even the speech recognition"))
    }

    func testAnHonestCompletionIsLeftAlone() {
        let segments = Self.segments(["The quick brown fox jumps over the lazy dog"])
        let completion = Self.completion(text: "The quick brown fox jumps over the lazy dog.")

        let raw = VoiceSessionReducer.reconcileCompletion(completion, against: segments)

        XCTAssertEqual(raw.text, "The quick brown fox jumps over the lazy dog.")
    }

    func testOrdinaryTrimmingAtTheEndpointIsNotTreatedAsLoss() {
        let segments = Self.segments(["I think we should ship the release on Friday afternoon or"])
        // The recognizer retracted a dangling word when it finalized. Well inside the shortfall.
        let completion = Self.completion(text: "I think we should ship the release on Friday afternoon")

        let raw = VoiceSessionReducer.reconcileCompletion(completion, against: segments)

        XCTAssertEqual(raw.text, "I think we should ship the release on Friday afternoon")
    }

    /// A provider that streams partials and finishes with a fuller answer is ordinary; the
    /// check must not drag it back down to its own intermediate segments.
    func testALongerCompletionIsNeverSecondGuessed() {
        let segments = Self.segments(["partial text only"])
        let completion = Self.completion(
            text: "partial text only, plus a great deal more that the final pass resolved"
        )

        let raw = VoiceSessionReducer.reconcileCompletion(completion, against: segments)

        XCTAssertEqual(raw.text, completion.rawTranscript.text)
    }

    func testProvenanceSurvivesTheSubstitution() {
        let segments = Self.segments(["one two three four five six", "seven eight nine ten"])
        let completion = Self.completion(text: "seven eight nine ten")

        let raw = VoiceSessionReducer.reconcileCompletion(completion, against: segments)

        XCTAssertEqual(raw.providerID, completion.rawTranscript.providerID)
        XCTAssertEqual(raw.audioSHA256, completion.rawTranscript.audioSHA256)
        XCTAssertEqual(raw.localeIdentifier, completion.rawTranscript.localeIdentifier)
        XCTAssertTrue(raw.isFinal)
    }

    func testNoSegmentsMeansNoEvidenceAndTheCompletionStands() {
        let completion = Self.completion(text: "whatever the provider says")

        XCTAssertEqual(
            VoiceSessionReducer.reconcileCompletion(completion, against: []).text,
            "whatever the provider says"
        )
    }

    func testAnEmptyCompletionCannotSurviveAgainstRecognizedSegments() {
        let segments = Self.segments(["there were definitely words here just now"])
        let completion = Self.completion(text: "")

        let raw = VoiceSessionReducer.reconcileCompletion(completion, against: segments)

        XCTAssertEqual(raw.text, "there were definitely words here just now")
    }

    // MARK: - The reducer wires that check up, and stops announcing non-transitions

    func testTheReducerAdoptsTheSegmentStreamWhenTheCompletionFallsShort() throws {
        var state = try Self.stateInRecognizingPhase()

        for segment in Self.segments(["first sentence spoken aloud", "second sentence spoken aloud"]) {
            _ = VoiceSessionReducer.reduce(
                state: &state,
                event: .speechSegmentReceived(segment),
                eventGeneration: state.snapshot.generation
            )
        }
        _ = VoiceSessionReducer.reduce(
            state: &state,
            event: .speechCompleted(Self.completion(text: "second sentence spoken aloud")),
            eventGeneration: state.snapshot.generation
        )

        let text = try XCTUnwrap(state.rawTranscript?.text)
        XCTAssertTrue(text.contains("first sentence spoken aloud"))
        XCTAssertTrue(text.contains("second sentence spoken aloud"))
    }

    func testASegmentIsNotAPhaseTransitionAndAnnouncesNothing() throws {
        var state = try Self.stateInRecognizingPhase()

        let result = VoiceSessionReducer.reduce(
            state: &state,
            event: .speechSegmentReceived(Self.segments(["hello there"])[0]),
            eventGeneration: state.snapshot.generation
        )

        let commands = try result.get()
        XCTAssertFalse(
            commands.contains(where: {
                if case .notifyHUD = $0 { return true }
                return false
            }),
            "One HUD announcement per recognizer revision is what filled the trace with noise"
        )
    }

    /// Live-preview segments describe the same audio the batch pass is about to restate. Left
    /// in place they would be assembled twice, and the completion checked against a doubled
    /// transcript it could never match.
    func testLivePreviewSegmentsAreClearedWhenTheBatchPassBegins() throws {
        var state = VoiceSessionState(
            snapshot: Self.snapshot(),
            phase: .capturing(mode: .hold)
        )
        _ = VoiceSessionReducer.reduce(
            state: &state,
            event: .liveSegmentReceived(SpeechSegment(segmentID: "live-0", text: "live preview text")),
            eventGeneration: state.snapshot.generation
        )
        XCTAssertEqual(state.segments.count, 1)

        _ = VoiceSessionReducer.reduce(
            state: &state,
            event: .stopCapture,
            eventGeneration: state.snapshot.generation
        )
        _ = VoiceSessionReducer.reduce(
            state: &state,
            event: .audioFinalized(Self.artifact()),
            eventGeneration: state.snapshot.generation
        )

        XCTAssertTrue(state.segments.isEmpty)
    }

    // MARK: - Recognition that errors after producing text

    /// Throwing discarded the transcript, and nothing was persisted — which is what
    /// `recoverableUndelivered` keys on, so the saved audio never reached the user either.
    func testTextRecognizedBeforeAnErrorIsDeliveredRatherThanDiscarded() async throws {
        let adapter = LegacyAppleSpeechAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .authorized },
            runtimeFactory: { _ in
                Self.runtime(utterances: ["first thing said", "a completely different second thing"],
                             failWith: NSError(domain: "kAFAssistantErrorDomain", code: 1101))
            }
        )

        var completion: SpeechCompletion?
        for try await event in adapter.transcribe(Self.request()) {
            if case .completed(let value) = event { completion = value }
        }

        let text = try XCTUnwrap(completion?.rawTranscript.text)
        XCTAssertTrue(text.contains("first thing said"))
        XCTAssertTrue(text.contains("a completely different second thing"))
    }

    /// With nothing recognized there is no evidence to keep, and the failure must still surface
    /// as a failure rather than as an empty success.
    func testAnErrorWithNothingRecognizedStillPropagates() async {
        let adapter = LegacyAppleSpeechAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .authorized },
            runtimeFactory: { _ in
                Self.runtime(utterances: [], failWith: NSError(domain: "kAFAssistantErrorDomain", code: 1101))
            }
        )

        do {
            for try await _ in adapter.transcribe(Self.request()) {}
            XCTFail("An error with no recognized text must not complete successfully")
        } catch {
            XCTAssertEqual((error as NSError).code, 1101)
        }
    }

    // MARK: - Helpers

    private static func segments(_ utterances: [String]) -> [SpeechSegment] {
        utterances.enumerated().map { index, text in
            SpeechSegment(segmentID: "seg-\(index)", revision: 1, text: text, finality: .final)
        }
    }

    private static func completion(text: String) -> SpeechCompletion {
        SpeechCompletion(
            rawTranscript: RawTranscript(
                text: text,
                localeIdentifier: "en_US",
                confidence: 1,
                providerID: "apple.speech.legacy",
                modelVersion: "system",
                latencyMs: 1,
                audioSHA256: "abc123",
                isFinal: true
            ),
            finalSegmentCount: 1,
            totalDurationSeconds: 30
        )
    }

    private static func artifact() -> AudioArtifact {
        AudioArtifact(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("evidence.caf"),
            format: "caf",
            sampleRate: 16_000,
            channelCount: 1,
            frameCount: 480_000,
            durationSeconds: 30,
            byteCount: 960_000,
            sha256Hex: "abc123",
            gapCount: 0
        )
    }

    private static func snapshot() -> VoiceSessionSnapshot {
        VoiceSessionSnapshot(
            speechProvider: SpeechProviderDescriptor(
                id: "apple.speech.legacy",
                displayName: "Apple Speech",
                modelVersion: "system",
                privacyRoute: .onDeviceOnly
            ),
            correctionProvider: CorrectionProviderDescriptor(
                id: "deterministic.rules",
                displayName: "Rules",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly
            ),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: "com.example.Target", processIdentifier: 42)
        )
    }

    private static func stateInRecognizingPhase() throws -> VoiceSessionState {
        var state = VoiceSessionState(snapshot: snapshot(), phase: .capturing(mode: .hold))
        _ = VoiceSessionReducer.reduce(
            state: &state, event: .stopCapture, eventGeneration: state.snapshot.generation
        )
        _ = VoiceSessionReducer.reduce(
            state: &state, event: .audioFinalized(artifact()), eventGeneration: state.snapshot.generation
        )
        XCTAssertEqual(state.phase, .recognizing)
        return state
    }

    private static func request() -> SpeechRequest {
        SpeechRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            audio: artifact(),
            locale: Locale(identifier: "en-US"),
            deadline: Date().addingTimeInterval(30),
            privacyRoute: .onDeviceOnly
        )
    }

    private static func runtime(utterances: [String], failWith error: Error) -> AppleOnDeviceSpeechRuntime {
        AppleOnDeviceSpeechRuntime(
            isAvailable: { true },
            supportsOnDeviceRecognition: { true },
            startRecognition: { _, resultHandler in
                for utterance in utterances {
                    resultHandler(EvidenceStubResult(text: utterance, isFinal: false), nil)
                }
                resultHandler(nil, error)
                return AppleSpeechTaskHandle(cancel: {})
            }
        )
    }
}

private final class EvidenceStubTranscription: SFTranscription {
    private let stubbed: String
    init(text: String) {
        self.stubbed = text
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var formattedString: String { stubbed }
    override var segments: [SFTranscriptionSegment] { [] }
}

private final class EvidenceStubResult: SFSpeechRecognitionResult {
    private let stubbedTranscription: SFTranscription
    private let stubbedIsFinal: Bool
    init(text: String, isFinal: Bool) {
        self.stubbedTranscription = EvidenceStubTranscription(text: text)
        self.stubbedIsFinal = isFinal
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var bestTranscription: SFTranscription { stubbedTranscription }
    override var transcriptions: [SFTranscription] { [stubbedTranscription] }
    override var isFinal: Bool { stubbedIsFinal }
}

/// The coordinator-side half of the trace-noise fix.
///
/// The reducer no longer *emits* a phase command per recognizer revision, but nineteen call sites
/// emit `notifyHUD` and any of them could reintroduce a duplicate. This is the rule that makes a
/// repeat harmless wherever it comes from.
final class VoicePhaseAnnouncementTests: XCTestCase {

    private let gen1 = SessionGeneration(rawValue: 1)
    private let gen2 = SessionGeneration(rawValue: 2)

    func testTheFirstPhaseOfASessionIsAlwaysAnnounced() {
        XCTAssertTrue(
            VoiceSessionCoordinator.shouldAnnouncePhase(.preparing, generation: gen1, lastAnnounced: nil)
        )
    }

    func testARepeatOfTheSamePhaseSaysNothingAndIsSuppressed() {
        XCTAssertFalse(
            VoiceSessionCoordinator.shouldAnnouncePhase(
                .recognizing, generation: gen1, lastAnnounced: (gen1, .recognizing)
            ),
            "Eighty identical `recognizing` lines is what buried the real transitions"
        )
    }

    func testAGenuineTransitionIsAlwaysAnnounced() {
        XCTAssertTrue(
            VoiceSessionCoordinator.shouldAnnouncePhase(
                .correcting, generation: gen1, lastAnnounced: (gen1, .recognizing)
            )
        )
    }

    /// Suppression must never cross sessions: a new attempt that happens to begin in the phase the
    /// last one ended in still has to announce itself, or its HUD never updates.
    func testANewGenerationAnnouncesEvenAnIdenticalPhase() {
        XCTAssertTrue(
            VoiceSessionCoordinator.shouldAnnouncePhase(
                .recognizing, generation: gen2, lastAnnounced: (gen1, .recognizing)
            )
        )
    }

    /// Capture phases carry a mode, and locking hands-free mid-session is a real transition the
    /// HUD must see even though the case is the same.
    func testAModeChangeWithinCapturingIsATransition() {
        XCTAssertTrue(
            VoiceSessionCoordinator.shouldAnnouncePhase(
                .capturing(mode: .handsFree),
                generation: gen1,
                lastAnnounced: (gen1, .capturing(mode: .hold))
            )
        )
        XCTAssertFalse(
            VoiceSessionCoordinator.shouldAnnouncePhase(
                .capturing(mode: .hold),
                generation: gen1,
                lastAnnounced: (gen1, .capturing(mode: .hold))
            )
        )
    }

    /// Terminal phases must never be swallowed — they are what retires the session in the app.
    func testTerminalPhasesAreAnnouncedWhenTheyFollowAnythingElse() {
        let failure = VoiceFailure(stage: .recognition, code: .endpointUnreachable)
        XCTAssertTrue(
            VoiceSessionCoordinator.shouldAnnouncePhase(
                .failed(failure), generation: gen1, lastAnnounced: (gen1, .recognizing)
            )
        )
        XCTAssertTrue(
            VoiceSessionCoordinator.shouldAnnouncePhase(
                .cancelled, generation: gen1, lastAnnounced: (gen1, .capturing(mode: .hold))
            )
        )
    }
}
