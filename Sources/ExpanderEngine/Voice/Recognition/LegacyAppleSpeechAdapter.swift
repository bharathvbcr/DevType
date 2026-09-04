import Foundation
import Speech

public final class LegacyAppleSpeechAdapter: SpeechRecognizer, @unchecked Sendable {
    public let descriptor: SpeechProviderDescriptor
    private let locale: Locale
    private let authorizationStatus: () -> SpeechAuthorization.Status
    private let runtimeFactory: (Locale) -> AppleOnDeviceSpeechRuntime?

    public convenience init(locale: Locale = Locale.current) {
        self.init(
            locale: locale,
            authorizationStatus: SpeechAuthorization.status,
            runtimeFactory: {
                AppleOnDeviceSpeechRuntime.system(locale: $0, includeEnglishFallback: false)
            }
        )
    }

    init(
        locale: Locale,
        authorizationStatus: @escaping () -> SpeechAuthorization.Status,
        runtimeFactory: @escaping (Locale) -> AppleOnDeviceSpeechRuntime?
    ) {
        self.locale = locale
        self.authorizationStatus = authorizationStatus
        self.runtimeFactory = runtimeFactory
        self.descriptor = SpeechProviderDescriptor(
            id: "apple.speech.legacy",
            displayName: "Apple Speech (On-Device)",
            modelVersion: "system",
            privacyRoute: .onDeviceOnly,
            supportsStreaming: true,
            supportsContextualStrings: true
        )
    }

    /// Observational only — never prompts. See `SpeechAuthorization` for why a readiness
    /// check must not have the side effect of asking the user for permission.
    public func probe() async -> ProviderReadiness {
        guard let runtime = runtimeFactory(locale), runtime.supportsOnDeviceRecognition else {
            return .incompatible(reason: .modelNotFound)
        }

        switch authorizationStatus() {
        case .authorized:
            guard runtime.isAvailable else {
                return .temporarilyUnavailable(retryAfterSeconds: 2.0, reason: .endpointUnreachable)
            }
            return .ready(ProviderEvidence(
                providerID: descriptor.id,
                modelVersion: descriptor.modelVersion,
                probeTimestamp: Date(),
                capabilities: ["onDeviceRecognition", "contextualStrings", "offline"]
            ))
        case .notDetermined, .denied, .restricted:
            return .requiresPermission(.speechRecognition)
        }
    }

    public func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            guard authorizationStatus() == .authorized else {
                continuation.finish(throwing: VoiceFailure(
                    stage: .recognition,
                    code: .speechRecognitionPermissionDenied,
                    providerID: descriptor.id,
                    retryClass: .afterUserAction,
                    artifactState: .durable
                ))
                return
            }

            guard let runtime = runtimeFactory(request.locale) else {
                continuation.finish(throwing: VoiceFailure(
                    stage: .recognition,
                    code: .endpointUnreachable,
                    providerID: descriptor.id,
                    redactedDetail: "SFSpeechRecognizer unavailable for locale \(request.locale.identifier)"
                ))
                return
            }

            guard runtime.supportsOnDeviceRecognition else {
                continuation.finish(throwing: VoiceFailure(
                    stage: .recognition,
                    code: .modelNotFound,
                    providerID: descriptor.id,
                    redactedDetail: "On-device Apple Speech is unavailable for the requested locale"
                ))
                return
            }

            guard runtime.isAvailable else {
                continuation.finish(throwing: VoiceFailure(
                    stage: .recognition,
                    code: .endpointUnreachable,
                    providerID: descriptor.id,
                    redactedDetail: "SFSpeechRecognizer unavailable for the requested locale"
                ))
                return
            }

            let recognitionRequest = SFSpeechURLRecognitionRequest(url: request.audio.fileURL)
            recognitionRequest.requiresOnDeviceRecognition = true
            if #available(macOS 14.0, *), !request.vocabulary.terms.isEmpty {
                // Apple contextual strings guidance: max 100 entries
                let capped = Array(request.vocabulary.terms.prefix(100))
                recognitionRequest.contextualStrings = capped
            }

            let startTime = Date()
            let duration = request.audio.durationSeconds

            // Recognizing a file is not one utterance. `SFSpeechRecognizer` walks the audio
            // and *replaces* its transcript at every pause, so the result that finally
            // carries `isFinal` holds the last utterance alone. Reading that one string as
            // the transcript is what silently discarded everything the user said before
            // their last sentence — and, because the finished transcript then supersedes
            // the live text, deleted it from their document. See `UtteranceAccumulator`.
            var accumulator = UtteranceAccumulator(idPrefix: UUID().uuidString)

            /// Yields the completion built from everything accumulated, not from one result.
            func finishWithAccumulatedTranscript() {
                let text = accumulator.cumulativeText
                let raw = RawTranscript(
                    text: text,
                    localeIdentifier: request.locale.identifier,
                    confidence: text.isEmpty ? 0 : 1.0,
                    providerID: self.descriptor.id,
                    modelVersion: self.descriptor.modelVersion,
                    latencyMs: Date().timeIntervalSince(startTime) * 1000,
                    audioSHA256: request.audio.sha256Hex,
                    isFinal: true
                )
                continuation.yield(.completed(SpeechCompletion(
                    rawTranscript: raw,
                    finalSegmentCount: accumulator.sealedCount,
                    totalDurationSeconds: duration
                )))
                continuation.finish()
            }

            guard let task = runtime.startOnDeviceRecognition(
                with: recognitionRequest,
                resultHandler: { result, error in
                    if let error = error {
                        // Check if error is due to cancellation
                        let nsError = error as NSError
                        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 203 {
                            // Silence timeout. Mid-file this ends the task *after* real
                            // speech, so reporting an empty transcript here would erase a
                            // recognized session rather than describe an empty one.
                            if let sealed = accumulator.sealInFlight(durationSeconds: duration) {
                                continuation.yield(.segment(sealed))
                            }
                            accumulator.endpointReached()
                            finishWithAccumulatedTranscript()
                            return
                        }

                        // Any other error, *after* real speech was already recognized.
                        //
                        // Throwing here discards it, and the session then has no persisted
                        // transcript — which is exactly what `recoverableUndelivered` keys on,
                        // so the saved audio never reaches the user either. The words are lost
                        // twice over for a failure that arrived after the recognizer had
                        // already produced them.
                        //
                        // Recognized text is evidence, not a guess, so it is delivered. The
                        // failure is still recorded loudly, because a transcript that ended on
                        // an error may be short and the trace is where that is diagnosed.
                        if let sealed = accumulator.sealInFlight(durationSeconds: duration) {
                            continuation.yield(.segment(sealed))
                        }
                        accumulator.endpointReached()
                        guard accumulator.cumulativeText.isEmpty else {
                            DevTypeLog.voice.error(
                                """
                                [Voice] recognition ended on an error after producing text; \
                                delivering what was recognized provider=\(self.descriptor.id, privacy: .public) \
                                chars=\(accumulator.cumulativeText.count, privacy: .public)
                                """
                            )
                            VoiceDiagnosticsRecorder.shared.record(
                                "recognition.partialAfterError",
                                note: "provider=\(self.descriptor.id) "
                                    + "chars=\(accumulator.cumulativeText.count) "
                                    + "domain=\(nsError.domain) code=\(nsError.code)"
                            )
                            finishWithAccumulatedTranscript()
                            return
                        }

                        continuation.finish(throwing: error)
                        return
                    }

                    guard let result = result else { return }

                    let step = accumulator.ingest(
                        text: result.bestTranscription.formattedString,
                        isFinal: result.isFinal,
                        durationSeconds: duration
                    )
                    // Order matters: the sealed utterance must reach the consumer before the
                    // one that replaced it, or it is overwritten exactly as it was upstream.
                    if let sealed = step.sealed {
                        continuation.yield(.segment(sealed))
                    }
                    continuation.yield(.segment(step.current))

                    if result.isFinal {
                        accumulator.endpointReached()
                        finishWithAccumulatedTranscript()
                    }
                }
            ) else {
                continuation.finish(throwing: VoiceFailure(
                    stage: .recognition,
                    code: .modelNotFound,
                    providerID: descriptor.id,
                    redactedDetail: "On-device Apple Speech policy rejected recognition startup"
                ))
                return
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func cancel(sessionID: VoiceSessionID) async {
        // Handled via continuation.onTermination
    }
}
