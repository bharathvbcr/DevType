import Foundation

/// A single edit the injector may apply: delete `eraseCount` grapheme clusters
/// immediately before the caret, then type `textToInject`.
public struct VoiceReconciledEdit: Equatable, Sendable {
    /// Grapheme clusters to erase. Invariant: never exceeds the volatile tail length,
    /// so it can never reach text behind the commit barrier.
    public let eraseCount: Int

    /// Text to type after erasing.
    public let textToInject: String

    /// The full dictation-owned text after this edit is applied.
    public let resultingText: String

    /// True when the recognizer tried to revise text behind the commit barrier and the
    /// revision was deliberately dropped rather than replayed destructively.
    public let suppressedCommittedRevision: Bool

    public init(
        eraseCount: Int,
        textToInject: String,
        resultingText: String,
        suppressedCommittedRevision: Bool = false
    ) {
        self.eraseCount = eraseCount
        self.textToInject = textToInject
        self.resultingText = resultingText
        self.suppressedCommittedRevision = suppressedCommittedRevision
    }

    /// An edit that changes nothing.
    public static func noop(_ owned: String, suppressed: Bool = false) -> VoiceReconciledEdit {
        VoiceReconciledEdit(
            eraseCount: 0,
            textToInject: "",
            resultingText: owned,
            suppressedCommittedRevision: suppressed
        )
    }

    public var isNoop: Bool { eraseCount == 0 && textToInject.isEmpty }
}

/// Stateful reconciler that turns a stream of *cumulative* transcripts into minimal,
/// non-destructive edits against a commit barrier.
///
/// The dictation-owned text is split in two:
///
///   ┌──────────── committed ────────────┬──── volatile ────┐
///   │ finalized utterances — IMMUTABLE  │ in-flight tail   │
///   └───────────────────────────────────┴──────────────────┘
///                                       ▲ commit barrier
///
/// Only the volatile tail is erasable. This is the structural fix for the "pausing
/// replaces my earlier text" defect: `SFSpeechRecognizer` re-cases and re-punctuates an
/// utterance when it finalizes at an endpoint, so a prefix-only (LCP) diff sees a change
/// at offset 0 and erases the entire session transcript. Here, a cosmetic revision of
/// committed text is absorbed — the committed spelling wins and the new tail is grafted
/// onto it — so `eraseCount` stays bounded by the volatile tail by construction.
///
/// Hardening: every path fails closed. When the incoming target cannot be aligned to the
/// committed text, or the required erase exceeds the budget, the reconciler emits a no-op
/// and keeps what is already on screen rather than issuing a destructive rewrite.
public final class VoiceTranscriptReconciler: @unchecked Sendable {

    /// Largest erase a single edit may request before the reconciler fails closed.
    /// A genuine in-utterance revision is a handful of words; anything larger indicates
    /// recognizer desync, and retyping it via backspaces is worse than leaving it alone.
    public static let defaultMaxEraseBudget = 512

    /// Hard ceiling on dictation-owned text for one session. Past this the reconciler
    /// degrades to append-only so a runaway session can neither stall nor mass-erase.
    public static let defaultMaxOwnedLength = 20_000

    private let lock = UnfairLock()
    private var _committed: String = ""
    private var _volatile: String = ""
    private let maxEraseBudget: Int
    private let maxOwnedLength: Int

    public init(
        maxEraseBudget: Int = VoiceTranscriptReconciler.defaultMaxEraseBudget,
        maxOwnedLength: Int = VoiceTranscriptReconciler.defaultMaxOwnedLength
    ) {
        self.maxEraseBudget = max(0, maxEraseBudget)
        self.maxOwnedLength = max(0, maxOwnedLength)
    }

    // MARK: - State

    /// Finalized text. Never erased by `reconcile`.
    public var committedText: String { lock.withLock { _committed } }

    /// In-flight tail. The only erasable region.
    public var volatileText: String { lock.withLock { _volatile } }

    /// Everything dictation believes it has typed into the document.
    public var ownedText: String { lock.withLock { _committed + _volatile } }

    // MARK: - Reconcile

    /// Computes the minimal safe edit to move the document from the currently owned text
    /// to `target`, without ever erasing behind the commit barrier.
    public func reconcile(target: String) -> VoiceReconciledEdit {
        lock.withLock {
            let owned = _committed + _volatile

            if target == owned { return .noop(owned) }

            // Append-only degradation past the session ceiling.
            if owned.count >= maxOwnedLength { return .noop(owned) }

            var suppressed = false
            let newVolatile: String

            if _committed.isEmpty {
                newVolatile = target
            } else if target.hasPrefix(_committed) {
                newVolatile = String(target.dropFirst(_committed.count))
            } else {
                // The recognizer revised text behind the barrier. Keep the committed
                // spelling and graft the target's tail onto it.
                suppressed = true
                guard let graft = Self.graftIndex(committed: _committed, target: target) else {
                    // Target does not contain our committed text at all. Fail closed.
                    return .noop(owned, suppressed: true)
                }
                newVolatile = String(target[graft...])
            }

            let common = Self.longestCommonPrefixCount(_volatile, newVolatile)
            let erase = _volatile.count - common
            let inject = String(newVolatile.dropFirst(common))

            if erase > maxEraseBudget {
                return .noop(owned, suppressed: true)
            }

            _volatile = newVolatile
            let resulting = _committed + _volatile

            return VoiceReconciledEdit(
                eraseCount: erase,
                textToInject: inject,
                resultingText: resulting,
                suppressedCommittedRevision: suppressed
            )
        }
    }

    /// Seals the current volatile tail behind the commit barrier.
    ///
    /// - Parameter finalizedText: when provided, the authoritative full text for
    ///   everything committed so far. It is accepted only if it does not contradict what
    ///   is already on screen — that is, only if the volatile tail can absorb the
    ///   difference. Otherwise the on-screen text is committed as-is.
    public func commitBoundary(finalizedText: String? = nil) {
        lock.withLock {
            if let finalizedText {
                let owned = _committed + _volatile
                if finalizedText == owned {
                    _committed = finalizedText
                } else if finalizedText.hasPrefix(_committed) {
                    // Difference lies entirely in the volatile region — safe to adopt.
                    _committed = finalizedText
                } else {
                    // Contradicts committed text; keep what the document actually shows.
                    _committed = owned
                }
            } else {
                _committed += _volatile
            }
            _volatile = ""
        }
    }

    /// Advances the barrier to cover exactly `prefix`, leaving the rest volatile.
    ///
    /// Unlike `commitBoundary`, this does not assume the whole in-flight tail is settled —
    /// the caller knows which part the recognizer has moved past and which part it is still
    /// revising. Only ever moves forward, and only when `prefix` agrees with what is
    /// actually owned, so a confused caller cannot mark text committed that is not on
    /// screen.
    public func sealPrefix(_ prefix: String) {
        lock.withLock {
            let owned = _committed + _volatile
            guard prefix.count > _committed.count,
                  prefix.count <= owned.count,
                  owned.hasPrefix(prefix) else { return }
            _committed = prefix
            _volatile = String(owned.dropFirst(prefix.count))
        }
    }

    /// Erases everything dictation owns (cancellation / undo of the whole draft).
    public func rollbackAll() -> VoiceReconciledEdit {
        lock.withLock {
            let owned = _committed + _volatile
            _committed = ""
            _volatile = ""
            return VoiceReconciledEdit(
                eraseCount: owned.count,
                textToInject: "",
                resultingText: ""
            )
        }
    }

    /// Drops all tracking without emitting an edit. Used when the document is no longer
    /// ours to edit (focus change, session handoff), so nothing is ever blind-erased.
    public func reset() {
        lock.withLock {
            _committed = ""
            _volatile = ""
        }
    }

    // MARK: - Transcript assembly

    /// Joins finalized utterances and the in-flight partial into one cumulative transcript,
    /// inserting a single separating space where the recognizer supplies none.
    public static func combineUtterances(committed: [String], activePartial: String) -> String {
        let segments = committed
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let partial = activePartial.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = ""
        for segment in segments {
            result = appendSegment(result, next: segment)
        }
        return appendSegment(result, next: partial)
    }

    private static func appendSegment(_ base: String, next: String) -> String {
        guard !next.isEmpty else { return base }
        guard !base.isEmpty else { return next }

        if base.hasSuffix(" ") || base.hasSuffix("\n") || next.hasPrefix(" ") || next.hasPrefix("\n") {
            return base + next
        }
        return base + " " + next
    }

    // MARK: - Alignment

    /// Number of matching grapheme clusters at the start of both strings.
    static func longestCommonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var iterA = a.makeIterator()
        var iterB = b.makeIterator()
        while let x = iterA.next(), let y = iterB.next(), x == y {
            count += 1
        }
        return count
    }

    /// Finds where `committed` ends inside `target`, comparing only content characters
    /// (letters and digits, case-folded) so that re-casing and re-punctuation align.
    /// Returns `nil` when `target` does not begin with the committed content.
    static func graftIndex(committed: String, target: String) -> String.Index? {
        let content = committed.compactMap(Self.contentScalar)
        guard !content.isEmpty else { return nil }

        var matched = 0
        var index = target.startIndex
        var cursor = target.startIndex

        while cursor < target.endIndex, matched < content.count {
            let character = target[cursor]
            cursor = target.index(after: cursor)

            guard let scalar = Self.contentScalar(character) else {
                continue // punctuation / whitespace is transparent to alignment
            }
            guard scalar == content[matched] else {
                return nil // genuine content divergence, not a cosmetic revision
            }
            matched += 1
            index = cursor
        }

        guard matched == content.count else { return nil }

        // Absorb trailing punctuation that belongs to the committed spelling, so the
        // grafted tail starts at the separator rather than duplicating a period.
        while index < target.endIndex, Self.isAbsorbablePunctuation(target[index]) {
            index = target.index(after: index)
        }

        return index
    }

    /// Case-folded content character, or `nil` for punctuation, whitespace and symbols.
    private static func contentScalar(_ character: Character) -> Character? {
        guard character.isLetter || character.isNumber else { return nil }
        let lowered = character.lowercased()
        return lowered.first.map { lowered.count == 1 ? $0 : character }
    }

    private static func isAbsorbablePunctuation(_ character: Character) -> Bool {
        guard character.isPunctuation || character.isSymbol else { return false }
        return !character.isWhitespace
    }
}
