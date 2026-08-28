import Foundation
import AVFoundation

public actor VoiceSessionCoordinator {
    public static let shared = VoiceSessionCoordinator()

    private var activeState: VoiceSessionState?
    private var taskBag: SessionTaskBag?
    private let capture = DurableVoiceCapture.shared
    private let store = VoiceSessionStore.shared
    private let speechRegistry = SpeechProviderRegistry.shared

    public var onPhaseChange: (@Sendable (SessionPhase) -> Void)?

    private init() {}

    public func activePhase() -> SessionPhase? {
        activeState?.phase
    }

    public func startSession(snapshot: VoiceSessionSnapshot, mode: DictationMode = .hold) async throws {
        // If an existing session is running, cancel it cleanly
        if let existingBag = taskBag {
            existingBag.advanceGenerationAndCancelAll()
            await capture.cancelCapture()
        }

        let generation = snapshot.generation
        let bag = SessionTaskBag(sessionID: snapshot.sessionID, generation: generation)
        self.taskBag = bag

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
        await capture.cancelCapture()
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

    private func executeCommands(_ commands: [VoiceSessionCommand], for snapshot: VoiceSessionSnapshot, generation: SessionGeneration) {
        for command in commands {
            switch command {
            case .notifyHUD(let phase):
                onPhaseChange?(phase)

            case .startAudioCapture:
                let sessionDir = store.sessionDirectory(for: snapshot.sessionID)
                let task = Task { [weak self] in
                    guard let self = self else { return }
                    do {
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
                let task = Task { [weak self] in
                    guard let self = self else { return }
                    do {
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
                    let corrector: TranscriptCorrector
                    switch snapshot.correctionProvider.id {
                    case "ollama.corrector":
                        corrector = OllamaCorrector()
                    case "openaicompatible.corrector":
                        corrector = OpenAICompatibleCorrector()
                    case "apple.foundation-models":
                        corrector = FoundationLanguageModelCorrector()
                    default:
                        corrector = DeterministicCorrector()
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

            case .validateCorrectionCandidate, .cleanupResources:
                break

            case .deliverTranscript(let finalTranscript, let lease):
                let task = Task { [weak self] in
                    guard let self = self else { return }
                    let receipt = await VoiceInsertionService.shared.deliver(
                        text: finalTranscript.text,
                        targetLease: lease,
                        sessionID: snapshot.sessionID,
                        generation: generation
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
