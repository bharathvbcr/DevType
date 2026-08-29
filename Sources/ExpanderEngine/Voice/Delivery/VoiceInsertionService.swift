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

    /// Clears all ownership. Called when a dictation starts, so a new session never
    /// believes it owns text left over from the last one.
    public func beginSession() {
        reconciler.reset()
        assembler.reset()
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

        // With progressive typing off, nothing is on screen yet; the assembler still tracks
        // the transcript so final delivery knows it owns nothing.
        guard VoicePreferences.isRealTimeTypingEnabled else { return }
        guard changed else { return }

        let edit = reconciler.reconcile(target: assembler.cumulativeText)
        inject(edit)

        // Seal exactly what the recognizer has moved past. Driven by the assembler rather
        // than by this segment's `finality` flag, because a superseded utterance is settled
        // whether or not the recognizer ever labelled it final.
        reconciler.sealPrefix(assembler.settledText)
    }

    // MARK: - Final delivery

    /// Delivers the authoritative transcript, reconciled against whatever live typing
    /// already placed in the document.
    public func deliver(
        text: String,
        targetLease: TargetLease,
        sessionID: VoiceSessionID,
        generation: SessionGeneration
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
        assembler.reset()
        inject(edit)
        return edit.eraseCount
    }

    // MARK: - Injection

    private func inject(_ edit: VoiceReconciledEdit) {
        guard !edit.isNoop else { return }

        let snippet = SnippetModel(
            title: "Voice Dictation",
            triggerKeyword: "",
            replacementText: edit.textToInject
        )
        TextInjectionPipeline.shared.inject(
            snippet: snippet,
            triggerLength: 0,
            swallowed: .notSwallowed,
            eraseCountOverride: edit.eraseCount,
            preResolvedText: edit.textToInject,
            secureClipboardPaste: false
        )
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
