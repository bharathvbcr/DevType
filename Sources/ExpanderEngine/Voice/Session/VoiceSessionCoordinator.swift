import Foundation
import AVFoundation

public actor VoiceSessionCoordinator {
    public static let shared = VoiceSessionCoordinator()

    private var activeState: VoiceSessionState?
    /// `internal` rather than `private` only so `VoiceCaptureRaceTests` can retire a generation
    /// mid-flight, which is the whole shape of the race being guarded.
    var taskBag: SessionTaskBag?
    private let capture: any VoiceCaptureEngine
    private let store = VoiceSessionStore.shared
    private let speechRegistry = SpeechProviderRegistry.shared
    private let correctionRegistry = CorrectionProviderRegistry.shared

    public var onPhaseChange: (@Sendable (SessionPhase) -> Void)?

    /// Emitted for each live segment while audio is still being captured, so the delivery
    /// layer can type progressively. `.volatile` segments are still being revised;
    /// `.final` marks an endpoint and seals a commit barrier.
    public var onLiveSegment: (@Sendable (SpeechSegment) -> Void)?

    /// Live microphone level, forwarded for HUD metering.
    public var onAudioLevel: (@Sendable (Float) -> Void)?

    /// Gives the app a chance to claim the transcript as a spoken command before it is
    /// typed. Returning `true` means the app handled it and nothing should be inserted.
    public var onDeliveryIntercept: (@Sendable (String) async -> Bool)?

    private var liveStream: LiveSpeechStream?

    /// Bounds every phase after capture ends. See `SessionWatchdog`.
    private let watchdog = SessionWatchdog()
    /// Prevents a failed persistence report from recursively trying to persist its own failed
    /// manifest forever. The actor makes this a serialized state bit, not a racy global flag.
    private var handlingPersistenceFailure = false

    private init() {
        capture = DurableVoiceCapture.shared
    }

    /// Test seam. Production always goes through `shared`; this exists so the capture-start and
    /// capture-finalize races can be driven against a double instead of a live microphone.
    init(capture: any VoiceCaptureEngine) {
        self.capture = capture
    }

    /// Test seam: install a bag so `performStartAudioCapture` has a generation to compare against.
    func installTaskBagForTesting(_ bag: SessionTaskBag?) {
        taskBag = bag
    }

    // Actor-isolated setters — callbacks are stored state and cannot be assigned
    // from outside the actor.
    public func setOnPhaseChange(_ handler: (@Sendable (SessionPhase) -> Void)?) {
        onPhaseChange = handler
    }

    public func setOnLiveSegment(_ handler: (@Sendable (SpeechSegment) -> Void)?) {
        onLiveSegment = handler
    }

    public func setOnAudioLevel(_ handler: (@Sendable (Float) -> Void)?) {
        onAudioLevel = handler
    }

    public func setOnDeliveryIntercept(_ handler: (@Sendable (String) async -> Bool)?) {
        onDeliveryIntercept = handler
    }

    /// The raw and corrected transcripts of the current session, once recognition has run.
    /// Used to show the user what cleanup changed, and to offer a revert.
    public func transcripts() -> (raw: String, final: String)? {
        guard let state = activeState,
              let raw = state.rawTranscript,
              let final = state.finalTranscript else { return nil }
        return (raw.text, final.text)
    }

    public func startSession(snapshot: VoiceSessionSnapshot, mode: DictationMode = .hold) async throws {
        // If an existing session is running, cancel it cleanly
        if let existingBag = taskBag {
            existingBag.advanceGenerationAndCancelAll()
            disarmWatchdog()
            liveStream?.cancel()
            liveStream = nil
            await capture.cancelCapture()
        }

        let generation = snapshot.generation
        let bag = SessionTaskBag(sessionID: snapshot.sessionID, generation: generation)
        self.taskBag = bag

        await MainActor.run {
            VoiceInsertionService.shared.beginSession(targetLease: snapshot.targetLease)
        }

        let state = VoiceSessionState(snapshot: snapshot, phase: .preparing)
        self.activeState = state

        // Create session directory & manifest before capture starts. If this gate fails, do not
        // leave the insertion service armed or a half-live session behind for a later toggle.
        do {
            _ = try store.createSession(snapshot: snapshot)
        } catch {
            activeState = nil
            taskBag = nil
            _ = await MainActor.run { VoiceInsertionService.shared.rollback() }
            throw VoiceFailure(
                stage: .persistence,
                code: .manifestWriteFailed,
                retryClass: .afterUserAction,
                artifactState: .absent,
                userAction: .freeDiskSpace,
                redactedDetail: "Could not create the voice session manifest: \(error.localizedDescription)"
            )
        }

        // Reduce start event
        _ = processEvent(.startCapture(mode: mode), generation: generation)
    }

    public func stopSession() async {
        guard let state = activeState, taskBag != nil else { return }
        let generation = state.snapshot.generation
        _ = processEvent(.stopCapture, generation: generation)
    }

    public func cancelSession() async {
        guard let state = activeState, taskBag != nil else { return }
        // Reduce cancellation while the session generation is still current. Advancing the bag
        // first makes the reducer reject its own `.cancel` event as stale, which skips the
        // terminal HUD/manifest transition and leaves cancellation invisible to observers.
        let generation = state.snapshot.generation
        disarmWatchdog()
        liveStream?.cancel()
        liveStream = nil
        _ = await MainActor.run { VoiceInsertionService.shared.rollback() }
        _ = processEvent(.cancel, generation: generation)
        await capture.cancelCapture()
        self.activeState = nil
        self.taskBag = nil
    }

    private func processEvent(_ event: VoiceSessionEvent, generation: SessionGeneration) -> Bool {
        guard var state = activeState, let bag = taskBag else { return false }
        guard bag.isCurrentGeneration(generation) else { return false }

        let result = VoiceSessionReducer.reduce(state: &state, event: event, eventGeneration: generation)
        switch result {
        case .success(let commands):
            self.activeState = state
            executeCommands(commands, for: state.snapshot, generation: generation)
            return true
        case .failure(let error):
            let fail = VoiceFailure(
                stage: .protocolViolation,
                code: .speechProtocolViolation,
                redactedDetail: "Reducer error: \(error)"
            )
            state.phase = .failed(fail)
            state.failure = fail
            self.activeState = state
            // A protocol violation is terminal too. Route it through the same command path as
            // provider and persistence failures so an invalid event cannot strand the microphone,
            // live recognizer, watchdog, or insertion lease.
            executeCommands(
                [
                    .notifyHUD(phase: .failed(fail)),
                    .persistManifest(phase: .failed(fail)),
                    .cleanupResources
                ],
                for: state.snapshot,
                generation: generation
            )
            return false
        }
    }

    // MARK: - Watchdog

    private func armWatchdog(seconds: Double, generation: SessionGeneration) {
        Task { [weak self] in
            await self?.watchdog.arm(seconds: seconds, generation: generation) { [weak self] expired in
                await self?.failOnTimeout(generation: expired, after: seconds)
            }
        }
    }

    private func disarmWatchdog() {
        Task { [watchdog] in await watchdog.disarm() }
    }

    private func failOnTimeout(generation: SessionGeneration, after seconds: Double) {
        guard let state = activeState else { return }
        switch state.phase {
        case .completed, .failed, .cancelled:
            return   // finished in time
        default:
            break
        }

        liveStream?.cancel()
        liveStream = nil

        let failure = VoiceFailure(
            stage: Self.stage(for: state.phase),
            code: .requestTimeout,
            retryClass: .afterUserAction,
            redactedDetail: "Session exceeded \(Int(seconds))s in phase \(state.phase)"
        )
        _ = processEvent(.failureOccurred(failure), generation: generation)
    }

    /// Attributes a timeout to the stage that was actually running, so the diagnostic
    /// names the component that stalled rather than reporting a generic failure.
    static func stage(for phase: SessionPhase) -> FailureStage {
        switch phase {
        case .preparing, .capturing: return .audioCapture
        case .finalizingAudio: return .audioFinalization
        case .recognizing: return .recognition
        case .validatingRaw: return .rawValidation
        case .correcting: return .correction
        case .validatingCorrection: return .correctionValidation
        case .readyForDelivery, .delivering: return .delivery
        case .completed, .failed, .cancelled, .recoverable: return .protocolViolation
        }
    }

    private func startLiveRecognition(snapshot: VoiceSessionSnapshot, generation: SessionGeneration) async {
        liveStream?.cancel()

        let stream = LiveSpeechStream(
            locale: Locale(identifier: snapshot.localeIdentifier),
            contextualStrings: snapshot.vocabularySnapshot.terms,
            onSegment: { [weak self] segment in
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.ingestLiveSegment(segment, generation: generation)
                }
            },
            onFailure: { [weak self] failure in
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.ingestLiveFailure(failure, generation: generation)
                }
            }
        )
        liveStream = stream

        await capture.setOnPCMBuffer { [weak stream] buffer in
            stream?.append(buffer)
        }
        await capture.setOnAudioLevelUpdate { [weak self] level in
            guard let self else { return }
            Task { await self.emitAudioLevel(level) }
        }
    }

    private func finishLiveRecognition() async {
        await capture.setOnPCMBuffer(nil)
        liveStream?.finish()
    }

    private func emitAudioLevel(_ level: Float) {
        onAudioLevel?(level)
    }

    private func ingestLiveSegment(_ segment: SpeechSegment, generation: SessionGeneration) -> Bool {
        processEvent(.liveSegmentReceived(segment), generation: generation)
    }

    private func ingestLiveFailure(_ failure: VoiceFailure, generation: SessionGeneration) -> Bool {
        processEvent(.failureOccurred(failure), generation: generation)
    }

    // MARK: - Capture task bodies
    //
    // Lifted out of `executeCommands` so the ordering rules below can be driven directly by
    // `VoiceCaptureRaceTests`. Inside a `Task { }` in a switch case they were reachable only by
    // booting a whole session against a real microphone, which is why the guarantees they carry
    // were previously asserted by grepping this file.

    /// Opens the microphone for `generation`, or tears it back down if that generation retired
    /// while it was being opened.
    ///
    /// Two awaits sit between entry and a live microphone, and a session can be superseded or
    /// stopped across either. Checking only on the way in is what allowed a cancelled session to
    /// still open the mic and leave it open — which the user sees as a recording indicator that
    /// never goes away.
    func performStartAudioCapture(
        sessionDir: URL,
        snapshot: VoiceSessionSnapshot,
        generation: SessionGeneration
    ) async {
        do {
            guard taskBag?.isCurrentGeneration(generation) == true else { return }
            try Task.checkCancellation()
            await startLiveRecognition(snapshot: snapshot, generation: generation)
            try Task.checkCancellation()
            try await capture.startCapture(sessionDirectory: sessionDir)
            // Setup finished, but this task may have lost the race while it ran.
            guard taskBag?.isCurrentGeneration(generation) == true else {
                await capture.cancelCapture()
                return
            }
        } catch is CancellationError {
            // A cooperative stop, not a device problem. This used to fall into the catch below
            // and surface as `.noMicrophone`, so every superseded session accused the user's
            // microphone of being broken.
            await capture.cancelCapture()
        } catch {
            let fail = (error as? VoiceFailure) ?? VoiceFailure(
                stage: .audioCapture,
                code: .noMicrophone,
                redactedDetail: error.localizedDescription
            )
            _ = processEvent(.failureOccurred(fail), generation: generation)
        }
    }

    /// Closes the microphone and hands the artifact to the reducer, unless this generation
    /// retired first — in which case the artifact belongs to a session nobody is waiting on.
    func performFinalizeAudioCapture(generation: SessionGeneration) async {
        do {
            try Task.checkCancellation()
            await finishLiveRecognition()
            try Task.checkCancellation()
            let artifact = try await capture.stopCapture()
            _ = processEvent(.audioFinalized(artifact), generation: generation)
        } catch is CancellationError {
            // Reporting `.zeroFramesCaptured` here turned an ordinary stop into a failure
            // banner for a session the user had already moved on from.
        } catch {
            let fail = (error as? VoiceFailure) ?? VoiceFailure(
                stage: .audioFinalization,
                code: .zeroFramesCaptured,
                redactedDetail: error.localizedDescription
            )
            _ = processEvent(.failureOccurred(fail), generation: generation)
        }
    }

    private func executeCommands(_ commands: [VoiceSessionCommand], for snapshot: VoiceSessionSnapshot, generation: SessionGeneration) {
        for command in commands {
            // A command can synchronously expose a persistence failure, which transitions the
            // reducer to a terminal state and cancels/removes the task bag. Do not continue the
            // stale command list afterward (for example, do not publish a completed HUD state or
            // attempt the remaining manifest write after a receipt write already failed).
            guard taskBag?.isCurrentGeneration(generation) == true else { return }
            switch command {
            case .notifyHUD(let phase):
                VoiceDiagnosticsRecorder.shared.record(
                    "session.phase", note: String(describing: phase)
                )
                onPhaseChange?(phase)

            case .startAudioCapture:
                let sessionDir = store.sessionDirectory(for: snapshot.sessionID)
                let task = Task { [weak self] in
                    guard let self = self else { return }
                    await self.performStartAudioCapture(
                        sessionDir: sessionDir, snapshot: snapshot, generation: generation
                    )
                }
                _ = taskBag?.add(task)

            case .finalizeAudioCapture:
                armWatchdog(seconds: snapshot.timeoutSeconds, generation: generation)
                let task = Task { [weak self] in
                    guard let self = self else { return }
                    await self.performFinalizeAudioCapture(generation: generation)
                }
                _ = taskBag?.add(task)

            case .transcribeAudio(let audio):
                let task = Task { [weak self] in
                    guard let self = self else { return }
                    let recognizer = await self.speechRegistry.resolveActiveRecognizer(
                        preferredID: snapshot.speechProvider.id,
                        privacyRoute: snapshot.privacyRoute
                    )

                    let speechRequest = SpeechRequest(
                        sessionID: snapshot.sessionID,
                        generation: generation,
                        audio: audio,
                        locale: Locale(identifier: snapshot.localeIdentifier),
                        vocabulary: snapshot.vocabularySnapshot,
                        deadline: Date().addingTimeInterval(snapshot.timeoutSeconds),
                        privacyRoute: snapshot.privacyRoute
                    )

                    do {
                        let stream = recognizer.transcribe(speechRequest)
                        for try await event in stream {
                            guard await self.taskBag?.isCurrentGeneration(generation) == true else { break }
                            switch event {
                            case .segment(let seg):
                                _ = await self.processEvent(.speechSegmentReceived(seg), generation: generation)
                            case .metrics:
                                break
                            case .completed(let comp):
                                _ = await self.processEvent(.speechCompleted(comp), generation: generation)
                            }
                        }
                    } catch {
                        let fail = (error as? VoiceFailure) ?? VoiceFailure(
                            stage: .recognition,
                            code: .endpointUnreachable,
                            redactedDetail: error.localizedDescription
                        )
                        _ = await self.processEvent(.failureOccurred(fail), generation: generation)
                    }
                }
                _ = taskBag?.add(task)

            case .validateRawTranscript(let raw):
                _ = processEvent(.rawValidationPassed(raw), generation: generation)

            case .correctTranscript(let raw):
                let task = Task { [weak self] in
                    guard let self = self else { return }

                    // Resolution enforces the session's privacy route and probes the
                    // provider, so an endpoint that is down falls back immediately instead
                    // of stalling the dictation for the whole timeout.
                    let corrector = await self.correctionRegistry.resolveActiveCorrector(
                        preferredID: snapshot.correctionProvider.id,
                        privacyRoute: snapshot.privacyRoute
                    )

                    guard let corrector else {
                        // No provider can be used — deliver exactly what was recognized. The
                        // reducer is still in `.correcting` here, so use the explicit terminal
                        // correction event rather than pretending validation already happened in
                        // the `.validatingCorrection` phase.
                        _ = await self.processEvent(
                            .correctionValidationPassed(FinalTranscript(
                                text: raw.text,
                                rawTranscript: raw,
                                correctionCandidate: nil,
                                validationOutcome: .notApplicable
                            )),
                            generation: generation
                        )
                        return
                    }

                    let final = await CorrectionPipeline.execute(
                        rawTranscript: raw,
                        corrector: corrector,
                        policy: snapshot.correctionPolicy,
                        vocabulary: snapshot.vocabularySnapshot,
                        deadline: Date().addingTimeInterval(snapshot.timeoutSeconds),
                        privacyRoute: snapshot.privacyRoute,
                        sessionID: snapshot.sessionID,
                        generation: generation
                    )

                    // A successful candidate must cross the reducer's candidate-received edge
                    // before validation can complete. The old code emitted only
                    // `correctionValidationPassed` while still in `.correcting`, which turned
                    // every normal voice correction into a protocol failure and made delivery
                    // unreachable. A thrown/empty-provider fallback has no candidate and uses the
                    // reducer's direct raw-result edge above.
                    if let candidate = final.correctionCandidate {
                        guard await self.processEvent(
                            .correctionCandidateReceived(candidate),
                            generation: generation
                        ) else { return }
                    }
                    _ = await self.processEvent(
                        .correctionValidationPassed(final),
                        generation: generation
                    )
                }
                _ = taskBag?.add(task)

            case .applyLiveSegment(let segment):
                // `DispatchQueue.main.async`, not `Task { @MainActor }`.
                //
                // Unstructured tasks carry no ordering guarantee: several are in flight at
                // once at speaking speed, and if a later segment is applied before an
                // earlier one, a new segment id lands out of order and the transcript is
                // assembled in the wrong sequence — which the reconciler then corrects by
                // erasing. The main queue is FIFO, so segments arrive in the order the
                // recognizer produced them.
                DispatchQueue.main.async {
                    VoiceInsertionService.shared.applyLiveSegment(segment)
                }
                onLiveSegment?(segment)

            case .validateCorrectionCandidate:
                break

            case .cleanupResources:
                disarmWatchdog()
                liveStream?.cancel()
                liveStream = nil
                Task { [capture] in
                    await capture.cancelCapture()
                }
                if let phase = activeState?.phase {
                    switch phase {
                    case .completed, .failed, .cancelled:
                        _ = taskBag?.advanceGenerationAndCancelAll()
                        taskBag = nil
                    default:
                        break
                    }
                }

            case .deliverTranscript(let finalTranscript, let lease):
                let task = Task { [weak self] in
                    guard let self = self else { return }

                    if let intercept = await self.onDeliveryIntercept,
                       await intercept(finalTranscript.text) {
                        _ = await self.processEvent(
                            .deliveryIntercepted(command: finalTranscript.text),
                            generation: generation
                        )
                        return
                    }

                    let receipt = await VoiceInsertionService.shared.deliver(
                        text: finalTranscript.text,
                        targetLease: lease,
                        sessionID: snapshot.sessionID,
                        generation: generation,
                        // A proofread or rewrite pass supersedes the live text rather than
                        // refining it, so it is allowed past the commit barrier.
                        replacingOwnedText: AITransformCorrector
                            .isTransformProvider(snapshot.correctionProvider.id)
                    )
                    if receipt.evidenceQuality == .targetMismatch {
                        _ = await self.processEvent(.targetLeaseInvalidated(reason: "Target application PID changed before delivery"), generation: generation)
                    } else {
                        _ = await self.processEvent(.deliveryCompleted(receipt), generation: generation)
                    }
                }
                _ = taskBag?.add(task)

            case .persistManifest:
                do {
                    _ = try store.createSession(snapshot: snapshot)
                } catch {
                    handlePersistenceFailure(error, generation: generation, artifactState: .partial)
                    return
                }

            case .persistAudio(let artifact):
                do {
                    try store.saveAudioArtifact(artifact, for: snapshot.sessionID)
                } catch {
                    handlePersistenceFailure(error, generation: generation, artifactState: .partial)
                    return
                }

            case .persistRaw(let raw):
                do {
                    try store.saveRawTranscript(raw, for: snapshot.sessionID)
                } catch {
                    handlePersistenceFailure(error, generation: generation, artifactState: .partial)
                    return
                }

            case .persistFinal(let final):
                do {
                    try store.saveFinalTranscript(final, for: snapshot.sessionID)
                } catch {
                    handlePersistenceFailure(error, generation: generation, artifactState: .partial)
                    return
                }

            case .persistReceipt(let receipt):
                do {
                    try store.saveDeliveryReceipt(receipt, for: snapshot.sessionID)
                } catch {
                    handlePersistenceFailure(error, generation: generation, artifactState: .partial)
                    return
                }
            }
        }
    }

    private func handlePersistenceFailure(
        _ error: Error,
        generation: SessionGeneration,
        artifactState: ArtifactState
    ) {
        guard !handlingPersistenceFailure else {
            DevTypeLog.store.error(
                "[Voice] secondary persistence failure while recording the primary failure: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        handlingPersistenceFailure = true
        defer { handlingPersistenceFailure = false }

        let failure = VoiceFailure(
            stage: .persistence,
            code: .manifestWriteFailed,
            retryClass: .afterUserAction,
            artifactState: artifactState,
            userAction: .freeDiskSpace,
            redactedDetail: "Voice session persistence failed: \(error.localizedDescription)"
        )
        guard processEvent(.failureOccurred(failure), generation: generation) else {
            // A receipt failure can happen after the reducer has already reached `.completed`.
            // Preserve that truthful delivery state, but still tear down capture/watchdog/task
            // resources and leave a structured OSLog record instead of silently leaking them.
            DevTypeLog.store.error(
                "[Voice] could not transition after persistence failure because the session was terminal"
            )
            disarmWatchdog()
            liveStream?.cancel()
            liveStream = nil
            Task { [capture] in
                await capture.cancelCapture()
            }
            _ = taskBag?.advanceGenerationAndCancelAll()
            taskBag = nil
            return
        }
    }
}
