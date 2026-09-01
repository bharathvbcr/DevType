import Foundation

public struct VoiceSessionState: Codable, Sendable, Equatable {
    public var snapshot: VoiceSessionSnapshot
    public var phase: SessionPhase
    public var audioArtifact: AudioArtifact?
    public var rawTranscript: RawTranscript?
    public var correctionCandidate: CorrectionCandidate?
    public var finalTranscript: FinalTranscript?
    public var deliveryReceipt: DeliveryReceipt?
    public var failure: VoiceFailure?
    public var segments: [SpeechSegment]

    public init(
        snapshot: VoiceSessionSnapshot,
        phase: SessionPhase = .preparing,
        audioArtifact: AudioArtifact? = nil,
        rawTranscript: RawTranscript? = nil,
        correctionCandidate: CorrectionCandidate? = nil,
        finalTranscript: FinalTranscript? = nil,
        deliveryReceipt: DeliveryReceipt? = nil,
        failure: VoiceFailure? = nil,
        segments: [SpeechSegment] = []
    ) {
        self.snapshot = snapshot
        self.phase = phase
        self.audioArtifact = audioArtifact
        self.rawTranscript = rawTranscript
        self.correctionCandidate = correctionCandidate
        self.finalTranscript = finalTranscript
        self.deliveryReceipt = deliveryReceipt
        self.failure = failure
        self.segments = segments
    }
}

public enum VoiceSessionEvent: Sendable, Equatable {
    case startCapture(mode: DictationMode)
    case lockInHandsFree
    case stopCapture
    case audioFinalized(AudioArtifact)
    case speechSegmentReceived(SpeechSegment)
    /// A segment produced by the live recognizer *while audio is still being captured*.
    /// Distinct from `speechSegmentReceived`, which belongs to the post-capture pass.
    case liveSegmentReceived(SpeechSegment)
    case speechCompleted(SpeechCompletion)
    case rawValidationPassed(RawTranscript)
    case correctionCandidateReceived(CorrectionCandidate)
    case correctionValidationPassed(FinalTranscript)
    case correctionValidationFailedFallbackRaw(FinalTranscript)
    case deliveryCompleted(DeliveryReceipt)
    case targetLeaseInvalidated(reason: String)
    /// The transcript was a spoken command (e.g. "rewrite this") and was handled by the
    /// app instead of being inserted verbatim.
    case deliveryIntercepted(command: String)
    case cancel
    case failureOccurred(VoiceFailure)
}

public enum VoiceSessionCommand: Sendable, Equatable {
    case startAudioCapture(mode: DictationMode)
    case finalizeAudioCapture
    case transcribeAudio(audio: AudioArtifact)
    /// Hand a live segment to the delivery layer for progressive typing. `finality`
    /// tells the reconciler whether to reconcile (volatile) or seal a commit barrier (final).
    case applyLiveSegment(SpeechSegment)
    case validateRawTranscript(RawTranscript)
    case correctTranscript(raw: RawTranscript)
    case validateCorrectionCandidate(candidate: CorrectionCandidate, raw: RawTranscript)
    case deliverTranscript(finalTranscript: FinalTranscript, lease: TargetLease)
    case persistManifest(phase: SessionPhase)
    case persistAudio(AudioArtifact)
    case persistRaw(RawTranscript)
    case persistFinal(FinalTranscript)
    case persistReceipt(DeliveryReceipt)
    case notifyHUD(phase: SessionPhase)
    case cleanupResources
}

public enum ReducerTransitionError: Error, Equatable, Sendable {
    case invalidTransition(from: SessionPhase, on: String)
    case staleGeneration(current: SessionGeneration, received: SessionGeneration)
    case terminalStateCannotReopen(phase: SessionPhase)
}

public enum VoiceSessionReducer {
    public static func reduce(
        state: inout VoiceSessionState,
        event: VoiceSessionEvent,
        eventGeneration: SessionGeneration
    ) -> Result<[VoiceSessionCommand], ReducerTransitionError> {
        guard eventGeneration == state.snapshot.generation else {
            return .failure(.staleGeneration(current: state.snapshot.generation, received: eventGeneration))
        }

        // Terminal state guards
        switch state.phase {
        case .completed, .failed, .cancelled:
            return .failure(.terminalStateCannotReopen(phase: state.phase))
        default:
            break
        }

        var commands: [VoiceSessionCommand] = []

        switch (state.phase, event) {
        // Global Cancellation
        case (_, .cancel):
            state.phase = .cancelled
            commands.append(.notifyHUD(phase: .cancelled))
            commands.append(.persistManifest(phase: .cancelled))
            commands.append(.cleanupResources)
            return .success(commands)

        // Global Failure
        case (_, .failureOccurred(let failure)):
            state.phase = .failed(failure)
            state.failure = failure
            commands.append(.notifyHUD(phase: .failed(failure)))
            commands.append(.persistManifest(phase: .failed(failure)))
            commands.append(.cleanupResources)
            return .success(commands)

        // Preparing -> Capturing
        case (.preparing, .startCapture(let mode)):
            state.phase = .capturing(mode: mode)
            commands.append(.startAudioCapture(mode: mode))
            commands.append(.notifyHUD(phase: state.phase))
            commands.append(.persistManifest(phase: state.phase))

        // Live recognition during capture — progressive typing.
        case (.capturing, .liveSegmentReceived(let segment)):
            if let idx = state.segments.firstIndex(where: { $0.segmentID == segment.segmentID }) {
                // Ignore out-of-order revisions; the recognizer may retract and resend.
                guard segment.revision >= state.segments[idx].revision else {
                    return .success(commands)
                }
                state.segments[idx] = segment
            } else {
                state.segments.append(segment)
            }
            commands.append(.applyLiveSegment(segment))

        // Late live segments can arrive after the stop event; absorb them without
        // faulting the session, but do not type them — capture has already ended.
        case (.finalizingAudio, .liveSegmentReceived),
             (.recognizing, .liveSegmentReceived):
            return .success(commands)

        // Capturing transitions
        case (.capturing(.hold), .lockInHandsFree):
            state.phase = .capturing(mode: .handsFree)
            commands.append(.notifyHUD(phase: state.phase))
            commands.append(.persistManifest(phase: state.phase))

        case (.capturing, .stopCapture):
            state.phase = .finalizingAudio
            commands.append(.finalizeAudioCapture)
            commands.append(.notifyHUD(phase: .finalizingAudio))
            commands.append(.persistManifest(phase: .finalizingAudio))

        // Finalizing Audio -> Recognizing
        case (.finalizingAudio, .audioFinalized(let artifact)):
            state.audioArtifact = artifact
            state.phase = .recognizing
            commands.append(.persistAudio(artifact))
            commands.append(.transcribeAudio(audio: artifact))
            commands.append(.notifyHUD(phase: .recognizing))
            commands.append(.persistManifest(phase: .recognizing))

        // Recognizing -> Segments / Completion
        case (.recognizing, .speechSegmentReceived(let segment)):
            // Reconcile interval segments
            if let idx = state.segments.firstIndex(where: { $0.segmentID == segment.segmentID }) {
                state.segments[idx] = segment
            } else {
                state.segments.append(segment)
            }
            // Segments are HUD updates only
            commands.append(.notifyHUD(phase: .recognizing))

        case (.recognizing, .speechCompleted(let completion)):
            state.rawTranscript = completion.rawTranscript
            state.phase = .validatingRaw
            commands.append(.persistRaw(completion.rawTranscript))
            commands.append(.validateRawTranscript(completion.rawTranscript))
            commands.append(.notifyHUD(phase: .validatingRaw))
            commands.append(.persistManifest(phase: .validatingRaw))

        // Validating Raw -> Correcting (or ReadyForDelivery if correction disabled)
        case (.validatingRaw, .rawValidationPassed(let raw)):
            state.rawTranscript = raw
            if state.snapshot.correctionProvider.id == "deterministic.none" ||
               state.snapshot.correctionPolicy.tone == .exact && !state.snapshot.correctionPolicy.allowSpokenPunctuation {
                // Skip model correction, produce final transcript immediately
                let final = FinalTranscript(
                    text: raw.text,
                    rawTranscript: raw,
                    correctionCandidate: nil,
                    validationOutcome: .notApplicable
                )
                state.finalTranscript = final
                state.phase = .readyForDelivery
                commands.append(.persistFinal(final))
                commands.append(.deliverTranscript(finalTranscript: final, lease: state.snapshot.targetLease))
                commands.append(.notifyHUD(phase: .readyForDelivery))
                commands.append(.persistManifest(phase: .readyForDelivery))
            } else {
                state.phase = .correcting
                commands.append(.correctTranscript(raw: raw))
                commands.append(.notifyHUD(phase: .correcting))
                commands.append(.persistManifest(phase: .correcting))
            }

        // Correcting -> Validating Correction
        case (.correcting, .correctionCandidateReceived(let candidate)):
            guard let raw = state.rawTranscript else {
                let fail = VoiceFailure(stage: .correctionValidation, code: .speechProtocolViolation, redactedDetail: "Raw transcript missing during correction candidate receipt")
                state.phase = .failed(fail)
                commands.append(.notifyHUD(phase: .failed(fail)))
                return .success(commands)
            }
            state.correctionCandidate = candidate
            state.phase = .validatingCorrection
            commands.append(.validateCorrectionCandidate(candidate: candidate, raw: raw))
            commands.append(.notifyHUD(phase: .validatingCorrection))
            commands.append(.persistManifest(phase: .validatingCorrection))

        // Validating Correction -> Ready for Delivery
        // A provider can fail before producing a candidate. In that case the correction pipeline
        // intentionally returns the raw transcript with `correctionCandidate == nil`; allow that
        // explicit fallback to bypass the candidate-validation subphase while remaining in the
        // reducer's valid state machine.
        case (.correcting, .correctionValidationPassed(let final)) where final.correctionCandidate == nil:
            state.finalTranscript = final
            state.phase = .readyForDelivery
            commands.append(.persistFinal(final))
            commands.append(.deliverTranscript(finalTranscript: final, lease: state.snapshot.targetLease))
            commands.append(.notifyHUD(phase: .readyForDelivery))
            commands.append(.persistManifest(phase: .readyForDelivery))

        case (.validatingCorrection, .correctionValidationPassed(let final)):
            state.finalTranscript = final
            state.phase = .readyForDelivery
            commands.append(.persistFinal(final))
            commands.append(.deliverTranscript(finalTranscript: final, lease: state.snapshot.targetLease))
            commands.append(.notifyHUD(phase: .readyForDelivery))
            commands.append(.persistManifest(phase: .readyForDelivery))

        case (.validatingCorrection, .correctionValidationFailedFallbackRaw(let final)):
            state.finalTranscript = final
            state.phase = .readyForDelivery
            commands.append(.persistFinal(final))
            commands.append(.deliverTranscript(finalTranscript: final, lease: state.snapshot.targetLease))
            commands.append(.notifyHUD(phase: .readyForDelivery))
            commands.append(.persistManifest(phase: .readyForDelivery))

        // Delivery
        case (.readyForDelivery, .deliveryCompleted(let receipt)):
            state.deliveryReceipt = receipt
            let outcome: SessionOutcome = .inserted(receipt)
            state.phase = .completed(outcome)
            commands.append(.persistReceipt(receipt))
            commands.append(.notifyHUD(phase: state.phase))
            commands.append(.persistManifest(phase: state.phase))
            commands.append(.cleanupResources)

        case (.readyForDelivery, .deliveryIntercepted(let command)):
            let outcome: SessionOutcome = .voiceCommandExecuted(command: command)
            state.phase = .completed(outcome)
            commands.append(.notifyHUD(phase: state.phase))
            commands.append(.persistManifest(phase: state.phase))
            commands.append(.cleanupResources)

        case (.readyForDelivery, .targetLeaseInvalidated(let reason)):
            let outcome: SessionOutcome = .savedButNotInserted(reason: reason)
            state.phase = .completed(outcome)
            commands.append(.notifyHUD(phase: state.phase))
            commands.append(.persistManifest(phase: state.phase))
            commands.append(.cleanupResources)

        default:
            return .failure(.invalidTransition(from: state.phase, on: String(describing: event)))
        }

        return .success(commands)
    }
}
