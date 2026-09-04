import Foundation

/// Accumulates the transcript of a recognizer that marks an utterance boundary by
/// *replacing* its result rather than by reporting one.
///
/// `SFSpeechRecognizer` reports `isFinal` only after `endAudio()`. Across a pause mid-stream
/// it keeps the same task and overwrites `bestTranscription.formattedString` with the new
/// utterance — the previous one simply vanishes from its output:
///
///     rev=7   "What's the best way?"
///     rev=8   "To"                      ← same task, same result object, new utterance
///
/// A consumer that treats that string as the whole transcript therefore keeps only whichever
/// utterance was in flight when recognition ended.
///
/// This type is the single owner of that bookkeeping. Both the live microphone stream and the
/// batch file adapter drive it. Before it existed the live stream inferred the boundary inline
/// and the batch adapter — whose transcript is the *authoritative* one, the text that is
/// persisted and delivered — did not infer it at all. A three-sentence dictation was recognized
/// correctly, typed correctly, and then replaced at delivery with its last sentence alone.
///
/// Boundary inference itself lives in `UtteranceBoundaryDetector`, and joining lives in
/// `VoiceTranscriptReconciler.combineUtterances`; this composes them and holds the state.
public struct UtteranceAccumulator: Sendable, Equatable {

    /// Bound on a single session. Past this, sealed utterances stop accumulating rather than
    /// growing without limit; the utterance in flight is still tracked, so recognition
    /// continues to work — it simply stops extending an already unreasonable transcript.
    public static let defaultMaxUtterances = 512

    /// What one recognizer result implies for the segment stream.
    public struct Ingestion: Sendable, Equatable {
        /// The previous utterance, sealed under its own identity because the recognizer
        /// moved past it. Must be emitted *before* `current` or it is lost.
        public var sealed: SpeechSegment?
        /// The utterance now in flight.
        public var current: SpeechSegment
        /// Whether this result began a new utterance rather than revising the current one.
        public var openedNewUtterance: Bool
    }

    private let idPrefix: String
    private let maxUtterances: Int

    private var sealedTexts: [String] = []
    private var currentText: String = ""
    private var index: Int = 0
    private var revision: UInt64 = 0

    public init(idPrefix: String, maxUtterances: Int = UtteranceAccumulator.defaultMaxUtterances) {
        self.idPrefix = idPrefix
        self.maxUtterances = max(1, maxUtterances)
    }

    // MARK: - State

    /// Identity of the utterance currently in flight.
    public var segmentID: String { "\(idPrefix)-\(index)" }

    /// Utterances the recognizer has moved past.
    public var sealedCount: Int { sealedTexts.count }

    /// The utterance still being revised.
    public var inFlightText: String { currentText }

    /// Everything recognized so far: every sealed utterance plus the one in flight.
    ///
    /// This — not the last result's `formattedString` — is the transcript of the session.
    public var cumulativeText: String {
        VoiceTranscriptReconciler.combineUtterances(
            committed: sealedTexts,
            activePartial: currentText
        )
    }

    // MARK: - Ingestion

    /// Absorbs one recognizer result.
    ///
    /// - Parameters:
    ///   - text: the recognizer's current `formattedString`, which may either revise the
    ///     utterance in flight or replace it with a new one.
    ///   - isFinal: whether the recognizer reported this result as final.
    ///   - durationSeconds: carried onto the emitted segments as metadata.
    public mutating func ingest(
        text: String,
        isFinal: Bool,
        durationSeconds: Double = 0
    ) -> Ingestion {
        var sealed: SpeechSegment?
        var openedNewUtterance = false

        if UtteranceBoundaryDetector.isReset(previous: currentText, current: text) {
            revision += 1
            sealed = SpeechSegment(
                segmentID: segmentID,
                revision: revision,
                durationSeconds: durationSeconds,
                text: currentText,
                finality: .final
            )
            appendSealed(currentText)
            index += 1
            revision = 0
            openedNewUtterance = true
        }

        revision += 1
        currentText = text

        return Ingestion(
            sealed: sealed,
            current: SpeechSegment(
                segmentID: segmentID,
                revision: revision,
                durationSeconds: durationSeconds,
                text: text,
                finality: isFinal ? .final : .volatile
            ),
            openedNewUtterance: openedNewUtterance
        )
    }

    /// Seals the utterance in flight and opens the next one.
    ///
    /// Called when the recognizer reaches an endpoint — `isFinal`, or a task that ended on
    /// silence. An endpoint that carried no speech seals nothing, so it cannot leave an empty
    /// slot that shows up later as a doubled separator.
    public mutating func endpointReached() {
        appendSealed(currentText)
        index += 1
        revision = 0
        currentText = ""
    }

    /// The utterance in flight, as a final segment, or `nil` when it carried no speech.
    ///
    /// For the case where a task ends without the recognizer ever reporting `isFinal`: the
    /// text it had is the utterance's best transcription and must be emitted, or a consumer
    /// waiting for `.final` waits forever.
    public mutating func sealInFlight(durationSeconds: Double = 0) -> SpeechSegment? {
        let settled = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settled.isEmpty else { return nil }
        revision += 1
        return SpeechSegment(
            segmentID: segmentID,
            revision: revision,
            durationSeconds: durationSeconds,
            text: settled,
            finality: .final
        )
    }

    // MARK: - Private

    private mutating func appendSealed(_ text: String) {
        let settled = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settled.isEmpty else { return }
        guard sealedTexts.count < maxUtterances else { return }
        sealedTexts.append(settled)
    }
}
