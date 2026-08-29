import Foundation

/// Cloud recognition via Gemini, adapting `GeminiTranscriptionClient` to the
/// `SpeechRecognizer` protocol.
///
/// The transport, retry policy, payload limit and error taxonomy live in the client and
/// are not duplicated here. This adapter's job is the three things the session layer
/// needs: refuse to send audio when the session's privacy route forbids it, encode to
/// FLAC so the upload is a fraction of the raw size, and build the steering prompt from
/// the session's vocabulary and tone.
public final class GeminiSpeechAdapter: SpeechRecognizer, @unchecked Sendable {
    public let descriptor: SpeechProviderDescriptor
    private let client = GeminiTranscriptionClient.shared

    public init(modelName: String = "gemini-3.5-transcribe") {
        self.descriptor = SpeechProviderDescriptor(
            id: "gemini.speech",
            displayName: "Gemini Cloud Speech",
            modelVersion: modelName,
            privacyRoute: .cloudPermitted,
            supportsStreaming: false,
            supportsContextualStrings: true
        )
    }

    public func probe() async -> ProviderReadiness {
        guard let key = GeminiAPIKeyStore.load(), !key.isEmpty else {
            return .requiresConfiguration(.missingAPIKey)
        }
        return .ready(ProviderEvidence(
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            probeTimestamp: Date(),
            capabilities: ["cloudTranscription", "multilingual", "punctuation", "steeringPrompt"]
        ))
    }

    public func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Egress gate. The session's route is the user's decision; a provider may
                // never widen it, so this is checked before the audio is even read.
                guard request.privacyRoute == .cloudPermitted else {
                    continuation.finish(throwing: VoiceFailure(
                        stage: .recognition,
                        code: .speechProtocolViolation,
                        providerID: self.descriptor.id,
                        redactedDetail: "Cloud audio egress blocked: session privacy route is \(request.privacyRoute)"
                    ))
                    return
                }

                guard let apiKey = GeminiAPIKeyStore.load(), !apiKey.isEmpty else {
                    continuation.finish(throwing: VoiceFailure(
                        stage: .recognition,
                        code: .missingAPIKey,
                        providerID: self.descriptor.id,
                        userAction: .enterAPIKey,
                        redactedDetail: "Missing Gemini API key"
                    ))
                    return
                }

                let startTime = Date()
                let (payload, mimeType, scratchURL) = self.encodePayload(for: request)

                defer {
                    if let scratchURL {
                        try? FileManager.default.removeItem(at: scratchURL)
                    }
                }

                guard let payload else {
                    continuation.finish(throwing: VoiceFailure(
                        stage: .recognition,
                        code: .audioEncodingFailed,
                        providerID: self.descriptor.id,
                        redactedDetail: "Could not read captured audio for upload"
                    ))
                    return
                }

                do {
                    let result = try await self.client.transcribe(
                        audioData: payload,
                        mimeType: mimeType,
                        audioDurationSeconds: request.audio.durationSeconds,
                        steeringPrompt: self.steeringPrompt(for: request),
                        apiKey: apiKey
                    )

                    // Gemini transcribes with a general-purpose model, and a general-purpose
                    // model formats: asked for a heading it heard, it writes `## `. When
                    // correction is off — or on, and it falls back to raw — this text is
                    // what lands in the user's field, so the Markdown pass belongs here, at
                    // the boundary where a model's answer becomes a transcript. Only the
                    // Markdown pass: the wrapper and preamble passes are the correction
                    // stage's job and would be second-guessing the recognizer's words.
                    let text = AIMarkdownStripper.strip(
                        result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        policy: AIPreferences.voiceMarkdownPolicy
                    )
                    guard !text.isEmpty else {
                        continuation.finish(throwing: VoiceFailure(
                            stage: .recognition,
                            code: .speechNoSpeech,
                            providerID: self.descriptor.id
                        ))
                        return
                    }

                    let latency = Date().timeIntervalSince(startTime) * 1000

                    continuation.yield(.segment(SpeechSegment(
                        segmentID: "gemini-0",
                        revision: 1,
                        startSeconds: 0,
                        durationSeconds: request.audio.durationSeconds,
                        text: text,
                        confidence: nil,
                        finality: .final
                    )))

                    continuation.yield(.completed(SpeechCompletion(
                        rawTranscript: RawTranscript(
                            text: text,
                            localeIdentifier: request.locale.identifier,
                            confidence: nil,
                            providerID: self.descriptor.id,
                            modelVersion: self.descriptor.modelVersion,
                            latencyMs: latency,
                            audioSHA256: request.audio.sha256Hex,
                            isFinal: true
                        ),
                        finalSegmentCount: 1,
                        totalDurationSeconds: request.audio.durationSeconds
                    )))
                    continuation.finish()

                } catch let error as GeminiTranscriptionError {
                    continuation.finish(throwing: self.failure(for: error))
                } catch {
                    continuation.finish(throwing: VoiceFailure(
                        stage: .recognition,
                        code: .endpointUnreachable,
                        providerID: self.descriptor.id,
                        redactedDetail: error.localizedDescription
                    ))
                }
            }
        }
    }

    public func cancel(sessionID: VoiceSessionID) async {}

    // MARK: - Payload

    /// FLAC-encodes the capture for upload, falling back to the raw file if encoding
    /// fails. Returns the scratch URL so the caller can delete it.
    private func encodePayload(for request: SpeechRequest) -> (Data?, String, URL?) {
        let scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-\(request.sessionID.rawValue.uuidString).flac")

        do {
            let encoded = try FLACEncoder.encode(inputURL: request.audio.fileURL, outputURL: scratchURL)
            let data = try Data(contentsOf: encoded.url)
            DevTypeLog.app.info("[Voice] FLAC encoded \(encoded.byteCount) bytes in \(Int(encoded.encodeSeconds * 1000))ms")
            return (data, "audio/flac", scratchURL)
        } catch {
            DevTypeLog.app.error("[Voice] FLAC encoding failed, uploading original: \(error)")
            let data = try? Data(contentsOf: request.audio.fileURL)
            return (data, mimeType(forExtension: request.audio.fileURL.pathExtension), nil)
        }
    }

    private func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "caf": return "audio/x-caf"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "m4a", "mp4": return "audio/mp4"
        default: return "audio/wav"
        }
    }

    /// Builds the steering prompt from the session snapshot's vocabulary and tone, so
    /// custom terminology and per-app tone actually reach the model.
    private func steeringPrompt(for request: SpeechRequest) -> String {
        let vocabulary = Dictionary(
            uniqueKeysWithValues: request.vocabulary.terms.map { ($0, $0) }
        )
        return TranscriptionSteeringPrompt.build(
            vocabulary: vocabulary,
            tone: .neutral,
            verbatim: VoicePreferences.isVerbatimModeEnabled
        )
    }

    // MARK: - Errors

    private func failure(for error: GeminiTranscriptionError) -> VoiceFailure {
        let code: FailureCode
        var action: UserAction?

        switch error {
        case .noAPIKey:
            code = .missingAPIKey; action = .enterAPIKey
        case .invalidAPIKey, .modelAccessDenied:
            code = .authFailed; action = .enterAPIKey
        case .rateLimited:
            code = .rateLimited
        case .quotaExhausted:
            code = .quotaExhausted; action = .retryWithOtherProvider
        case .timeout:
            code = .requestTimeout
        case .networkError:
            code = .endpointUnreachable
        case .safetyBlocked:
            code = .speechProtocolViolation
        case .emptyTranscript:
            code = .speechNoSpeech
        case .payloadTooLarge:
            code = .captureBackpressure
        case .invalidResponse:
            code = .speechProtocolViolation
        }

        return VoiceFailure(
            stage: .recognition,
            code: code,
            providerID: descriptor.id,
            userAction: action,
            redactedDetail: String(describing: error)
        )
    }
}
