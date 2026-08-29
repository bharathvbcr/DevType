import Foundation
import AVFoundation

public actor VoiceSessionCoordinator {
    public static let shared = VoiceSessionCoordinator()

    private var activeState: VoiceSessionState?
    private var taskBag: SessionTaskBag?
    private let capture = DurableVoiceCapture.shared
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

    private init() {}

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

    public func activePhase() -> SessionPhase? {
        activeState?.phase
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

        await MainActor.run { VoiceInsertionService.shared.beginSession() }

        let state = VoiceSessionState(snapshot: snapshot, phase: .preparing)
        self.activeState = state

        // Create session directory & manifest
        _ = try store.createSession(snapshot: snapshot)

        // Reduce start event
        _ = processEvent(.startCapture(mode: mode), generation: generation)
    }

    public func stopSession() async {
        guard let state = activeState, taskBag != nil else { return }
        let generation = state.snapshot.generation
        _ = processEvent(.stopCapture, generation: generation)
    }

    public func cancelSession() async {
        guard activeState != nil, let bag = taskBag else { return }
        let generation = bag.advanceGenerationAndCancelAll()
        disarmWatchdog()
        liveStream?.cancel()
        liveStream = nil
        await capture.cancelCapture()
        _ = await MainActor.run { VoiceInsertionService.shared.rollback() }
        _ = processEvent(.cancel, generation: generation)
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
            self.activeState = state
            onPhaseChange?(.failed(fail))
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

    private func executeCommands(_ commands: [VoiceSessionCommand], for snapshot: VoiceSessionSnapshot, generation: SessionGeneration) {
        for command in commands {
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
                    do {
                        await self.startLiveRecognition(snapshot: snapshot, generation: generation)
                        try await self.capture.startCapture(sessionDirectory: sessionDir)
                    } catch {
                        let fail = (error as? VoiceFailure) ?? VoiceFailure(
                            stage: .audioCapture,
                            code: .noMicrophone,
                            redactedDetail: error.localizedDescription
                        )
                        _ = await self.processEvent(.failureOccurred(fail), generation: generation)
                    }
                }
                _ = taskBag?.add(task)

            case .finalizeAudioCapture:
                armWatchdog(seconds: snapshot.timeoutSeconds, generation: generation)
                let task = Task { [weak self] in
                    guard let self = self else { return }
                    do {
                        await self.finishLiveRecognition()
                        let artifact = try await self.capture.stopCapture()
                        _ = await self.processEvent(.audioFinalized(artifact), generation: generation)
                    } catch {
                        let fail = (error as? VoiceFailure) ?? VoiceFailure(
                            stage: .audioFinalization,
                            code: .zeroFramesCaptured,
                            redactedDetail: error.localizedDescription
                        )
                        _ = await self.processEvent(.failureOccurred(fail), generation: generation)
                    }
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
                        // Correction disabled — deliver exactly what was recognized.
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

                    _ = await self.processEvent(.correctionValidationPassed(final), generation: generation)
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
                liveStream = nil

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
                _ = try? store.createSession(snapshot: snapshot)

            case .persistAudio:
                break

            case .persistRaw(let raw):
                _ = try? store.saveRawTranscript(raw, for: snapshot.sessionID)

            case .persistFinal(let final):
                _ = try? store.saveFinalTranscript(final, for: snapshot.sessionID)

            case .persistReceipt(let receipt):
                _ = try? store.saveDeliveryReceipt(receipt, for: snapshot.sessionID)
            }
        }
    }
}
