import Foundation
import AppKit

/// The single writer to the user's document.
///
/// Both progressive typing (live segments, while the user is still speaking) and final
/// delivery (the corrected transcript, after recognition completes) go through here, so
/// there is exactly one component that knows what dictation has put on screen.
///
/// That ownership is what makes the two safe together: without it, live typing would put
/// text down and final delivery would type the whole transcript again on top of it. Here,
/// final delivery is reconciled against the live text and usually reduces to a small edit
/// — or to nothing at all when the two already agree.
///
/// Erases are bounded by `VoiceTranscriptReconciler`'s commit barrier, so a pause, a
/// re-punctuation, or a correction can never delete text the user already sees settled.
@MainActor
public final class VoiceInsertionService {
    public static let shared = VoiceInsertionService()

    private let reconciler = VoiceTranscriptReconciler()

    /// What the segments received so far say. Pure bookkeeping, kept separate from
    /// injection so it can be tested without touching the user's document.
    private var assembler = LiveTranscriptAssembler()

    private init() {}

    // MARK: - Session lifecycle

    /// The app+field this session is dictating into. Live typing refuses to write anywhere
    /// else, exactly as `deliver` already does — see `applyLiveSegment`.
    private var targetLease: TargetLease?

    /// Pure policy: may this live segment be written?
    ///
    /// A segment that arrives after the user switched apps would be typed — and *erased from* —
    /// a different document than the one this session owns. `deliver` has always had this gate;
    /// live typing had none. Expressed as a static so the rule is table-testable rather than
    /// buried in a `@MainActor` singleton that reaches the real injection pipeline.
    ///
    /// A lease with pid 0 is "no target claimed" (the tests' and the hotkey path's shape) and
    /// withholds nothing; an unknown frontmost app is not evidence of a switch, so it also
    /// proceeds — this gate refuses only on a *positive* mismatch.
    nonisolated public static func shouldWithholdLiveSegment(
        leasePID: pid_t?,
        frontmostPID: pid_t?
    ) -> Bool {
        guard let leasePID, leasePID != 0, let frontmostPID else { return false }
        return leasePID != frontmostPID
    }

    /// Clears all ownership. Called when a dictation starts, so a new session never
    /// believes it owns text left over from the last one.
    public func beginSession(targetLease: TargetLease? = nil) {
        reconciler.reset()
        assembler.reset()
        self.targetLease = targetLease
        DevTypeLog.voice.info("[Voice] session begin realTimeTyping=\(VoicePreferences.isRealTimeTypingEnabled)")
        VoiceDiagnosticsRecorder.shared.beginSession(
            engine: VoicePreferences.effectiveEngine.rawValue,
            realTimeTyping: VoicePreferences.isRealTimeTypingEnabled
        )
    }

    /// Text dictation currently believes it has typed.
    public var ownedText: String { reconciler.ownedText }

    // MARK: - Progressive typing

    /// Applies one live segment from the recognizer.
    ///
    /// A `.volatile` segment is reconciled against the in-flight tail. A `.final` segment
    /// is reconciled and then sealed behind the commit barrier, after which no later
    /// revision can erase it — this is what stops a pause from replacing earlier text.
    public func applyLiveSegment(_ segment: SpeechSegment) {
        let changed = assembler.ingest(segment)

        VoiceDiagnosticsRecorder.shared.record(
            changed ? "segment.ingested" : "segment.ignored",
            segment: segment,
            settled: assembler.settledText,
            active: assembler.activeText,
            cumulative: assembler.cumulativeText
        )

        // With progressive typing off, nothing is on screen yet; the assembler still tracks
        // the transcript so final delivery knows it owns nothing.
        guard VoicePreferences.isRealTimeTypingEnabled else { return }
        guard changed else { return }

        // Same gate `deliver` has always had, which live typing was missing entirely: an
        // erase is posted at whatever now has focus, so a segment that arrives after the user
        // switched apps would revise a *different* document — backspacing over text this
        // session never wrote. Skip the write and leave the model untouched, so returning to
        // the real target resumes with one correct edit rather than a duplicated transcript.
        if Self.shouldWithholdLiveSegment(
            leasePID: targetLease?.processIdentifier,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) {
            DevTypeLog.voice.notice(
                "[Voice] live segment withheld — target pid \(self.targetLease?.processIdentifier ?? 0, privacy: .public) is no longer frontmost"
            )
            VoiceDiagnosticsRecorder.shared.record("segment.withheldTargetMismatch", segment: segment)
            return
        }

        let target = assembler.cumulativeText
        let tailBefore = reconciler.volatileText
        let edit = reconciler.reconcile(target: target)
        let tailAfter = reconciler.volatileText

        // The line that matters when text disappears: it names the erase and the state that
        // produced it, so a report can be diagnosed without reproducing it locally.
        if edit.eraseCount > 0 {
            DevTypeLog.voice.info(
                """
                [Voice] live edit erase=\(edit.eraseCount) inject=\(edit.textToInject.count) \
                committed=\(self.reconciler.committedText.count) volatile=\(self.reconciler.volatileText.count) \
                target=\(target.count) segment=\(segment.segmentID) rev=\(segment.revision) \
                suppressed=\(edit.suppressedCommittedRevision)
                """
            )
        }

        VoiceDiagnosticsRecorder.shared.record(
            "reconcile",
            segment: segment,
            cumulative: target,
            committedLength: reconciler.committedText.count,
            volatileLength: reconciler.volatileText.count,
            erase: edit.eraseCount,
            inject: edit.textToInject,
            suppressed: edit.suppressedCommittedRevision
        )

        inject(edit) { [reconciler] in
            // The whole repair is one call — see `recoverFromRefusedEdit`.
            reconciler.recoverFromRefusedEdit(expected: tailAfter, previous: tailBefore)
            DevTypeLog.voice.notice(
                "[Voice] tail unreachable — sealed it and resuming at the current caret"
            )
        }

        // Seal exactly what the recognizer has moved past. Driven by the assembler rather
        // than by this segment's `finality` flag, because a superseded utterance is settled
        // whether or not the recognizer ever labelled it final.
        let settled = assembler.settledText
        let before = reconciler.committedText.count
        reconciler.sealPrefix(settled)
        if reconciler.committedText.count != before {
            VoiceDiagnosticsRecorder.shared.record(
                "barrier.sealed",
                settled: settled,
                committedLength: reconciler.committedText.count,
                volatileLength: reconciler.volatileText.count
            )
        }
    }

    // MARK: - Final delivery

    /// Delivers the authoritative transcript, reconciled against whatever live typing
    /// already placed in the document.
    /// - Parameter replacingOwnedText: the transcript *supersedes* what live typing put on
    ///   screen rather than refining it — a proofread or rewrite pass legitimately changes
    ///   words the commit barrier has already sealed. The replacement is still bounded to
    ///   text dictation owns, so it can never reach the user's own content; it simply lifts
    ///   the barrier for this one deliberate edit at the end of the session.
    public func deliver(
        text: String,
        targetLease: TargetLease,
        sessionID: VoiceSessionID,
        generation: SessionGeneration,
        replacingOwnedText: Bool = false
    ) async -> DeliveryReceipt {
        let startTime = Date()

        // Target lease: refuse to type into an app that is no longer the one the user
        // was dictating into.
        if targetLease.processIdentifier != 0,
           let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != targetLease.processIdentifier {
            return receipt(
                sessionID: sessionID,
                generation: generation,
                lease: targetLease,
                length: 0,
                quality: .targetMismatch,
                startTime: startTime
            )
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if replacingOwnedText, !trimmed.isEmpty, trimmed != reconciler.ownedText {
            // One deliberate replacement of everything dictation owns. Bounded by
            // `rollbackAll`, so the erase can only ever cover text this session typed.
            let removed = reconciler.rollbackAll()
            DevTypeLog.voice.info(
                "[Voice] final transcript supersedes live text: replacing \(removed.eraseCount) chars"
            )
            VoiceDiagnosticsRecorder.shared.record(
                "deliver.replace", cumulative: trimmed, erase: removed.eraseCount
            )
            inject(VoiceReconciledEdit(
                eraseCount: removed.eraseCount,
                textToInject: trimmed,
                resultingText: trimmed,
                erasedText: removed.erasedText
            ))
            _ = reconciler.reconcile(target: trimmed)
            reconciler.commitBoundary()

            return receipt(
                sessionID: sessionID,
                generation: generation,
                lease: targetLease,
                length: trimmed.count,
                quality: .settledUnverifiedPaste,
                startTime: startTime
            )
        }

        let edit = reconciler.reconcile(target: trimmed)
        reconciler.commitBoundary()

        if edit.suppressedCommittedRevision {
            DevTypeLog.app.info(
                "[Voice] final transcript revised committed text; kept on-screen text chars=\(self.reconciler.ownedText.count)"
            )
        }

        if edit.isNoop {
            // Live typing already produced exactly this text — nothing to do.
            return receipt(
                sessionID: sessionID,
                generation: generation,
                lease: targetLease,
                length: trimmed.count,
                quality: .settledUnverifiedPaste,
                startTime: startTime
            )
        }

        DevTypeLog.voice.info(
            "[Voice] final delivery erase=\(edit.eraseCount) inject=\(edit.textToInject.count) owned=\(self.reconciler.ownedText.count)"
        )
        VoiceDiagnosticsRecorder.shared.record(
            "deliver.final",
            cumulative: trimmed,
            erase: edit.eraseCount,
            inject: edit.textToInject,
            suppressed: edit.suppressedCommittedRevision
        )
        inject(edit)

        return receipt(
            sessionID: sessionID,
            generation: generation,
            lease: targetLease,
            length: trimmed.count,
            quality: .settledUnverifiedPaste,
            startTime: startTime
        )
    }

    /// Erases everything dictation owns — cancellation, or handing the text to another
    /// flow such as a voice AI command.
    @discardableResult
    public func rollback() -> Int {
        let edit = reconciler.rollbackAll()
        if edit.eraseCount > 0 {
            DevTypeLog.voice.info("[Voice] rollback erase=\(edit.eraseCount)")
            VoiceDiagnosticsRecorder.shared.record("rollback", erase: edit.eraseCount)
        }
        assembler.reset()
        inject(edit)
        return edit.eraseCount
    }

    // MARK: - Injection

    /// Applies one edit, and reports whether the pipeline refused it.
    ///
    /// The erase goes down as a **verified** `ErasePlan` whenever the reconciler can name the
    /// text it expects to remove. A count-only plan (`expectedText: nil`) makes the erase
    /// precondition degrade to "proceed best-effort", which is only sound while the caret is
    /// still where dictation left it — with existing text in the field and a caret the user or
    /// the host moved, those backspaces land on the user's own content. A verified plan lets
    /// the precondition refuse instead, and `ErasePlan(text:)` also derives the UTF-16 width
    /// from the text rather than reusing a grapheme count for both units.
    private func inject(_ edit: VoiceReconciledEdit, onRefused: (() -> Void)? = nil) {
        guard !edit.isNoop else { return }

        let snippet = SnippetModel(
            title: "Voice Dictation",
            triggerKeyword: "",
            replacementText: edit.textToInject
        )
        let plan = edit.erasedText.map { ErasePlan(text: $0) }
        TextInjectionPipeline.shared.inject(
            snippet: snippet,
            triggerLength: 0,
            swallowed: .notSwallowed,
            eraseCountOverride: plan == nil ? edit.eraseCount : nil,
            erasePlan: plan,
            preResolvedText: edit.textToInject,
            secureClipboardPaste: false,
            eraseCaretVouched: false
        ) { outcome in
            guard case .refused(let reason) = outcome else { return }
            DevTypeLog.voice.notice(
                "[Voice] edit refused (\(reason, privacy: .public)) — restoring the tracked tail so later diffs stay aligned"
            )
            VoiceDiagnosticsRecorder.shared.record("edit.refused", erase: edit.eraseCount)
            Task { @MainActor in onRefused?() }
        }
    }

    private func receipt(
        sessionID: VoiceSessionID,
        generation: SessionGeneration,
        lease: TargetLease,
        length: Int,
        quality: DeliveryEvidenceQuality,
        startTime: Date
    ) -> DeliveryReceipt {
        DeliveryReceipt(
            sessionID: sessionID,
            generation: generation,
            targetLease: lease,
            deliveredTextLength: length,
            evidenceQuality: quality,
            deliveredAt: Date(),
            latencyMs: Date().timeIntervalSince(startTime) * 1000
        )
    }
}
