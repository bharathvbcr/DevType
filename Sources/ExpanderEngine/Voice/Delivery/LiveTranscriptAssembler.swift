import Foundation

/// Turns a stream of `SpeechSegment`s into the cumulative transcript that should be on
/// screen right now.
///
/// Split out of `VoiceInsertionService` so the bookkeeping can be tested on its own: the
/// service also injects into the user's document, which a test cannot exercise. What
/// remains here is a pure function of the segments received so far, and it is where the
/// recognizer's messier behaviours are absorbed:
///
/// - a segment is revised many times before it finalizes (`revision` increases),
/// - revisions can arrive out of order, and an older one must not overwrite a newer one,
/// - a finalized segment can be re-sent, and must not be appended twice,
/// - an utterance can finalize empty (silence at an endpoint) and must not become a gap.
public struct LiveTranscriptAssembler: Sendable, Equatable {

    /// Guards against an unbounded session; past this, further new segments are ignored
    /// rather than growing the transcript without limit.
    public static let maxSegments = 512

    private struct Entry: Equatable {
        var text: String
        var revision: UInt64
        var isFinal: Bool
    }

    /// Finalized and in-flight segments, in arrival order.
    private var entries: [(id: String, entry: Entry)] = []

    public init() {}

    public static func == (lhs: LiveTranscriptAssembler, rhs: LiveTranscriptAssembler) -> Bool {
        lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy { $0.id == $1.id && $0.entry == $1.entry }
    }

    /// Ingests one segment. Returns `true` when it changed the transcript.
    @discardableResult
    public mutating func ingest(_ segment: SpeechSegment) -> Bool {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = entries.firstIndex(where: { $0.id == segment.segmentID }) {
            let existing = entries[index].entry

            // A finalized segment is settled; only a later revision of that same
            // finalization may touch it, never a stray volatile update arriving afterwards.
            if existing.isFinal && segment.finality == .volatile { return false }
            if segment.revision < existing.revision { return false }

            let updated = Entry(text: text, revision: segment.revision, isFinal: segment.finality == .final)
            guard updated != existing else { return false }
            entries[index].entry = updated
            return true
        }

        // A new segment id means the recognizer moved on, so everything before it is
        // settled — whether or not it ever reported `isFinal`.
        //
        // This is the invariant the whole design rests on, and it must not be conditional
        // on the recognizer's cooperation. `SFSpeechRecognizer` fed from an audio buffer
        // generally reports `isFinal` only after `endAudio()`; a mid-stream pause just ends
        // the task. Waiting for a flag that never arrives left every utterance volatile and
        // erasable, which is exactly how a pause came to wipe earlier text.
        for index in entries.indices where !entries[index].entry.isFinal {
            entries[index].entry.isFinal = true
        }

        guard entries.count < Self.maxSegments else { return false }

        // An utterance that finalizes with no speech carries no text; recording it would
        // add an empty slot that shows up as a doubled separator.
        if text.isEmpty && segment.finality == .final { return false }

        entries.append((
            id: segment.segmentID,
            entry: Entry(text: text, revision: segment.revision, isFinal: segment.finality == .final)
        ))
        return true
    }

    /// Everything the recognizer has settled: all segments except a trailing one that is
    /// still being revised. This is the text the commit barrier may safely be advanced to.
    public var settledText: String {
        let settled = entries.last?.entry.isFinal == true ? entries : Array(entries.dropLast())
        return VoiceTranscriptReconciler.combineUtterances(
            committed: settled.map(\.entry.text),
            activePartial: ""
        )
    }

    /// The utterance still being revised, if any.
    public var activeText: String {
        guard let last = entries.last, !last.entry.isFinal else { return "" }
        return last.entry.text
    }

    /// The full transcript implied by everything received so far.
    ///
    /// Every segment contributes. An earlier version only counted segments explicitly
    /// marked final plus the trailing one, so an utterance that was superseded without ever
    /// being finalised vanished from the transcript — and the reconciler, seeing the text
    /// shrink, erased it from the document.
    public var cumulativeText: String {
        let last = entries.last
        let committed = last?.entry.isFinal == true ? entries : Array(entries.dropLast())
        return VoiceTranscriptReconciler.combineUtterances(
            committed: committed.map(\.entry.text),
            activePartial: activeText
        )
    }

    /// Whether the most recent segment sealed an utterance, meaning the caller should
    /// advance the commit barrier.
    public var lastSegmentWasFinal: Bool {
        entries.last?.entry.isFinal ?? false
    }

    public var segmentCount: Int { entries.count }

    public mutating func reset() {
        entries.removeAll()
    }
}
