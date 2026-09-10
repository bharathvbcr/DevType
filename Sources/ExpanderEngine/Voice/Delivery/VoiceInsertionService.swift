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

    typealias InjectionSubmit = (VoiceReconciledEdit, @escaping TextInjectionPipeline.InjectionCompletion) -> Void
    private let submitOverride: InjectionSubmit?
    private let liveModeOverride: VoicePreferences.LiveDeliveryMode?

    private init() {
        submitOverride = nil
        liveModeOverride = nil
    }

    /// Exercises actual delivery bookkeeping without a live document or user preferences.
    init(submit: @escaping InjectionSubmit, liveMode: VoicePreferences.LiveDeliveryMode = .insertAtEnd) {
        submitOverride = submit
        liveModeOverride = liveMode
    }

    // MARK: - Session lifecycle

    /// The app+field this session is dictating into. Live typing refuses to write anywhere
    /// else, exactly as `deliver` already does — see `applyLiveSegment`.
    private var targetLease: TargetLease?
    private var session = SessionTaskBag(sessionID: VoiceSessionID())
    private var boundSession: (id: VoiceSessionID, generation: SessionGeneration)?
    private var sessionIsCurrent: @Sendable () -> Bool = { true }
    private var liveWriteInFlight = false
    private var liveRevision: UInt64 = 0
    private var liveIdleWaiter: CheckedContinuation<Void, Never>?
    private enum DeliveryPhase { case live, finalizing, finished }
    private var deliveryPhase: DeliveryPhase = .live
    private var deliveryFailed = false

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

    /// Whether a finished transcript may *replace* the text live typing already put on
    /// screen, rather than being reconciled against it.
    ///
    /// A proofread pass legitimately rewrites words behind the commit barrier, so it is let
    /// past. The danger is that a transcript which has *lost* most of the session looks
    /// identical to a proofread at this call site — and applying it erases what the user
    /// dictated. That is exactly how a three-utterance session came to be replaced by its
    /// last sentence: recognition dropped two utterances, correction proofread what was
    /// left, and delivery faithfully deleted the rest.
    ///
    /// So the replacement must stay inside the same deletion ceiling the correction policy
    /// already declares for itself. Past that it is not a proofread, whatever produced it,
    /// and dictation keeps the words the user can see. Losing formatting is recoverable;
    /// losing the sentences is not.
    ///
    /// Content characters only — a proofread changes case, punctuation and spacing freely,
    /// and none of that is evidence about whether the words survived.
    ///
    /// Expressed as a static so the rule is table-testable rather than buried in a
    /// `@MainActor` singleton that reaches the real injection pipeline.
    nonisolated public static func replacementPreservesDictatedText(
        owned: String,
        replacement: String,
        maxDeletionRatio: Double
    ) -> Bool {
        let ownedContent = contentCharacterCount(owned)
        // Below a few words there is not enough signal, and a wrong refusal costs more than
        // a wrong acceptance on text this short.
        guard ownedContent >= 24 else { return true }

        let retained = Double(contentCharacterCount(replacement)) / Double(ownedContent)
        let floor = 1.0 - max(0, min(1, maxDeletionRatio))
        return retained >= floor
    }

    /// Letters and digits only, case-insensitively — the characters that carry words.
    nonisolated private static func contentCharacterCount(_ text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if character.isLetter || character.isNumber { count += 1 }
        }
    }

    /// Clears all ownership. Called when a dictation starts, so a new session never
    /// believes it owns text left over from the last one.
    public func beginSession(targetLease: TargetLease? = nil) {
        _ = session.advanceGenerationAndCancelAll()
        session = SessionTaskBag(sessionID: VoiceSessionID())
        boundSession = nil
        sessionIsCurrent = { true }
        liveWriteInFlight = false
        liveRevision = 0
        deliveryPhase = .live
        deliveryFailed = false
        liveIdleWaiter?.resume()
        liveIdleWaiter = nil
        reconciler.reset()
        assembler.reset()
        self.targetLease = targetLease
        DevTypeLog.voice.info("[Voice] session begin liveDelivery=\(VoicePreferences.liveDeliveryMode.rawValue)")
        VoiceDiagnosticsRecorder.shared.beginSession(
            engine: VoicePreferences.effectiveEngine.rawValue,
            liveDeliveryMode: VoicePreferences.liveDeliveryMode.rawValue
        )
    }

    func beginSession(targetLease: TargetLease, bag: SessionTaskBag, generation: SessionGeneration) {
        beginSession(targetLease: targetLease)
        boundSession = (bag.sessionID, generation)
        sessionIsCurrent = { bag.isCurrentGeneration(generation) }
    }

    /// Text dictation currently believes it has typed into the document.
    ///
    /// Empty in the modes that do not type while speaking — use `recognizedText` for the HUD.
    public var ownedText: String { reconciler.ownedText }

    /// Everything the recognizer has produced this session, whether or not it was typed.
    ///
    /// The HUD needs this rather than `ownedText`: in `previewInHUD` the whole point is that
    /// the words are visible while the document is left alone, and a HUD reading the typed
    /// text would sit blank through the entire session.
    public var recognizedText: String { assembler.cumulativeText }

    // MARK: - Progressive typing

    /// Applies one live segment from the recognizer.
    ///
    /// A `.volatile` segment is reconciled against the in-flight tail. A `.final` segment
    /// is reconciled and then sealed behind the commit barrier, after which no later
    /// revision can erase it — this is what stops a pause from replacing earlier text.
    public func applyLiveSegment(_ segment: SpeechSegment) {
        guard deliveryPhase == .live, sessionIsCurrent() else { return }
        let changed = assembler.ingest(segment)

        VoiceDiagnosticsRecorder.shared.record(
            changed ? "segment.ingested" : "segment.ignored",
            segment: segment,
            settled: assembler.settledText,
            active: assembler.activeText,
            cumulative: assembler.cumulativeText
        )

        // Outside `typeAsYouSpeak` nothing goes on screen yet. The assembler still ingested
        // the segment above, so the HUD has a transcript to show and final delivery knows it
        // owns nothing — the whole proofread text then lands in one insertion.
        guard (liveModeOverride ?? VoicePreferences.liveDeliveryMode).typesWhileSpeaking else { return }
        guard changed else { return }
        guard !deliveryFailed else { return }
        liveRevision &+= 1
        processLiveTranscript()
    }

    /// Only one edit may enter the injection pipeline at a time. New recognizer revisions
    /// update the bounded assembler while it settles, then one diff catches up to the latest.
    private func processLiveTranscript() {
        guard !liveWriteInFlight, !deliveryFailed, sessionIsCurrent() else { return }

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
            VoiceDiagnosticsRecorder.shared.record("segment.withheldTargetMismatch")
            return
        }

        let target = assembler.cumulativeText
        let settled = assembler.settledText
        let currentSession = session
        let revision = liveRevision
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
                target=\(target.count) rev=\(revision) \
                suppressed=\(edit.suppressedCommittedRevision)
                """
            )
        }

        VoiceDiagnosticsRecorder.shared.record(
            "reconcile",
            cumulative: target,
            committedLength: reconciler.committedText.count,
            volatileLength: reconciler.volatileText.count,
            erase: edit.eraseCount,
            inject: edit.textToInject,
            suppressed: edit.suppressedCommittedRevision
        )

        guard !edit.isNoop else {
            reconciler.sealPrefix(settled)
            return
        }
        liveWriteInFlight = true
        inject(edit) { [weak self] outcome in
            Task { @MainActor in
                guard let self, self.session === currentSession else { return }
                self.liveWriteInFlight = false
                switch outcome {
                case .succeeded, .degradedAXOnly, .postedUnverified:
                    self.reconciler.sealPrefix(settled)
                    VoiceDiagnosticsRecorder.shared.record("barrier.sealed", settled: settled,
                        committedLength: self.reconciler.committedText.count,
                        volatileLength: self.reconciler.volatileText.count)
                case .refused:
                    self.reconciler.recoverFromRefusedEdit(expected: tailAfter, previous: tailBefore)
                case .failedSilent:
                    _ = self.reconciler.revertVolatile(from: tailAfter, to: tailBefore)
                    // A partial post has unknown geometry. Preserve the transcript for recovery
                    // and stop this session's writes instead of guessing at another erase.
                    self.deliveryFailed = true
                }
                if self.liveRevision != revision { self.processLiveTranscript() }
                if !self.liveWriteInFlight {
                    self.liveIdleWaiter?.resume()
                    self.liveIdleWaiter = nil
                }
            }
        }
    }

    private func waitForLiveDelivery() async {
        guard liveWriteInFlight else { return }
        await withCheckedContinuation { liveIdleWaiter = $0 }
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
        replacingOwnedText: Bool = false,
        maxDeletionRatio: Double = CorrectionPolicy.defaultMaxDeletionRatio
    ) async -> DeliveryReceipt {
        let startTime = Date()
        let currentSession = session
        func result(_ quality: DeliveryEvidenceQuality, length: Int = 0) -> DeliveryReceipt {
            self.makeDeliveryReceipt(sessionID: sessionID, generation: generation, lease: targetLease,
                    length: length, quality: quality, startTime: startTime)
        }
        if Self.shouldWithholdLiveSegment(
            leasePID: targetLease.processIdentifier,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) { return result(.targetMismatch) }
        if let boundSession,
           boundSession.id != sessionID || boundSession.generation != generation || self.targetLease != targetLease {
            return result(.cancelled)
        }
        guard deliveryPhase != .finalizing else { return result(.failed) }
        guard !Task.isCancelled, sessionIsCurrent() else { return result(.cancelled) }
        deliveryPhase = .finalizing
        defer { if session === currentSession { deliveryPhase = .finished } }
        await waitForLiveDelivery()
        guard session === currentSession, !Task.isCancelled, sessionIsCurrent() else { return result(.cancelled) }
        guard !deliveryFailed else { return result(.failed) }
        if Self.shouldWithholdLiveSegment(
            leasePID: targetLease.processIdentifier,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) { return result(.targetMismatch) }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= SpeechSegment.maximumTranscriptBytes else { return result(.failed) }
        let before = (committed: reconciler.committedText, volatile: reconciler.volatileText)
        let mayReplace = replacingOwnedText && Self.replacementPreservesDictatedText(
            owned: reconciler.ownedText, replacement: trimmed, maxDeletionRatio: maxDeletionRatio
        )
        if replacingOwnedText && !mayReplace {
            DevTypeLog.voice.error("[Voice] refusing destructive replacement — insufficient retained dictation")
            VoiceDiagnosticsRecorder.shared.record("deliver.replaceRefused", cumulative: trimmed, suppressed: true)
        }

        let edit: VoiceReconciledEdit
        if mayReplace, !trimmed.isEmpty, trimmed != reconciler.ownedText {
            let removed = reconciler.rollbackAll()
            edit = VoiceReconciledEdit(eraseCount: removed.eraseCount, textToInject: trimmed,
                                       resultingText: trimmed, erasedText: removed.erasedText)
            _ = reconciler.reconcile(target: trimmed)
        } else {
            edit = reconciler.reconcile(target: trimmed)
        }
        guard !edit.isNoop else {
            reconciler.commitBoundary()
            guard trimmed == reconciler.ownedText else {
                VoiceDiagnosticsRecorder.shared.record("deliver.suppressed", cumulative: trimmed, suppressed: true)
                return result(.failed)
            }
            return result(.settledUnverifiedPaste, length: reconciler.ownedText.count)
        }
        VoiceDiagnosticsRecorder.shared.record("deliver.final", cumulative: trimmed,
                                               erase: edit.eraseCount, inject: edit.textToInject)
        let outcome = await withCheckedContinuation { continuation in
            inject(edit) { continuation.resume(returning: $0) }
        }
        guard session === currentSession, !Task.isCancelled, sessionIsCurrent() else { return result(.cancelled) }
        switch outcome {
        case .succeeded, .degradedAXOnly, .postedUnverified:
            reconciler.commitBoundary()
            let quality: DeliveryEvidenceQuality = outcome == .postedUnverified ? .settledUnverifiedPaste : .verifiedDirectAX
            return result(quality, length: reconciler.ownedText.count)
        case .refused, .failedSilent:
            reconciler.restore(committed: before.committed, volatile: before.volatile)
            deliveryFailed = true
            return result(.failed)
        }
    }

    /// Erases everything dictation owns — cancellation, or handing the text to another
    /// flow such as a voice AI command.
    @discardableResult
    public func rollback() -> Int {
        // Retire pending proposals first. Their physical extent is unknown until completion,
        // so cancellation preserves that text instead of issuing a speculative compensating erase.
        let mayErase = !liveWriteInFlight && deliveryPhase != .finalizing && !deliveryFailed
            && !Self.shouldWithholdLiveSegment(leasePID: targetLease?.processIdentifier,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        _ = session.advanceGenerationAndCancelAll()
        session = SessionTaskBag(sessionID: VoiceSessionID())
        sessionIsCurrent = { true }
        liveWriteInFlight = false
        deliveryPhase = .finished
        deliveryFailed = true
        liveIdleWaiter?.resume()
        liveIdleWaiter = nil
        let edit = reconciler.rollbackAll()
        assembler.reset()
        guard mayErase else {
            DevTypeLog.voice.notice("[Voice] cancellation preserved text — pending or unverifiable delivery")
            return 0
        }
        VoiceDiagnosticsRecorder.shared.record("rollback", erase: edit.eraseCount)
        inject(edit) { _ in }
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
    private func inject(_ edit: VoiceReconciledEdit, completion: @escaping TextInjectionPipeline.InjectionCompletion) {
        guard !edit.isNoop else { completion(.succeeded); return }
        let currentSession = session
        let generation = currentSession.generation
        let externalValidity = sessionIsCurrent
        let shouldContinue: @Sendable () -> Bool = {
            currentSession.isCurrentGeneration(generation) && externalValidity()
        }
        guard shouldContinue() else { completion(.refused("Voice session retired")); return }
        // The real pipeline completes exactly once after its bounded watchdog. Keep the
        // injected boundary equally defensive against a duplicate callback.
        let completionGuard = InjectCompletionGuard()
        let finished: TextInjectionPipeline.InjectionCompletion = { outcome in
            guard completionGuard.markCompleted(outcome) == 1 else { return }
            if case .refused = outcome {
                VoiceDiagnosticsRecorder.shared.record("edit.refused", erase: edit.eraseCount)
            }
            completion(outcome)
        }
        if let submitOverride { submitOverride(edit, finished); return }
        let snippet = SnippetModel(title: "Voice Dictation", triggerKeyword: "", replacementText: edit.textToInject)
        let plan = edit.erasedText.map { ErasePlan(text: $0) }
        TextInjectionPipeline.shared.inject(
            snippet: snippet,
            triggerLength: 0,
            swallowed: .notSwallowed,
            eraseCountOverride: plan == nil ? edit.eraseCount : nil,
            erasePlan: plan,
            preResolvedText: edit.textToInject,
            secureClipboardPaste: false,
            eraseCaretVouched: false,
            shouldContinue: shouldContinue,
            completion: finished
        )
    }

    private func makeDeliveryReceipt(
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
