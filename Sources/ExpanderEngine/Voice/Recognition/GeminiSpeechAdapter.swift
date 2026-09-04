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
    typealias Transcribe = @Sendable (
        Data,
        String,
        TimeInterval,
        String,
        String,
        @escaping @Sendable () -> Bool
    ) async throws -> GeminiTranscriptionResult

    public let descriptor: SpeechProviderDescriptor
    private let consentGranted: @Sendable () -> Bool
    private let credentialState: @Sendable () -> GeminiAPIKeyStore.ReadState
    private let afterPayloadPrepared: @Sendable () -> Void
    private let transcribeAudio: Transcribe

    public convenience init(modelName: String = "gemini-3.5-transcribe") {
        self.init(
            modelName: modelName,
            consentGranted: { VoicePreferences.hasCloudAudioConsent },
            credentialState: { GeminiAPIKeyStore.readState() },
            afterPayloadPrepared: {},
            transcribe: { audioData, mimeType, duration, prompt, apiKey, uploadAuthorized in
                try await GeminiTranscriptionClient.shared.transcribe(
                    audioData: audioData,
                    mimeType: mimeType,
                    audioDurationSeconds: duration,
                    steeringPrompt: prompt,
                    apiKey: apiKey,
                    uploadAuthorized: uploadAuthorized
                )
            }
        )
    }

    init(
        modelName: String = "gemini-3.5-transcribe",
        consentGranted: @escaping @Sendable () -> Bool,
        credentialState: @escaping @Sendable () -> GeminiAPIKeyStore.ReadState = {
            GeminiAPIKeyStore.readState()
        },
        afterPayloadPrepared: @escaping @Sendable () -> Void = {},
        transcribe: @escaping Transcribe
    ) {
        self.consentGranted = consentGranted
        self.credentialState = credentialState
        self.afterPayloadPrepared = afterPayloadPrepared
        self.transcribeAudio = transcribe
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
        switch GeminiAPIKeyStore.readState() {
        case .available(let key) where !key.isEmpty:
            break
        case .available, .missing:
            return .requiresConfiguration(.missingAPIKey)
        case .unavailable:
            return .temporarilyUnavailable(retryAfterSeconds: nil, reason: .authFailed)
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
            let task = Task {
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

                // Consent is mutable and may be revoked while audio is being captured. The
                // snapshot route proves what was allowed at session start; this live predicate is
                // the final authority at the actual upload boundary. It runs before credentials,
                // file reads, FLAC conversion, base64 encoding, or transport construction.
                guard self.consentGranted() else {
                    continuation.finish(throwing: VoiceFailure(
                        stage: .recognition,
                        code: .cloudAudioConsentRequired,
                        providerID: self.descriptor.id,
                        retryClass: .afterUserAction,
                        artifactState: .durable,
                        userAction: .retryWithOtherProvider,
                        redactedDetail: "Cloud audio consent is not currently granted"
                    ))
                    return
                }

                let keyState = self.credentialState()
                guard case .available(let apiKey) = keyState, !apiKey.isEmpty else {
                    let unavailable: Bool
                    if case .unavailable = keyState { unavailable = true } else { unavailable = false }
                    continuation.finish(throwing: VoiceFailure(
                        stage: .recognition,
                        code: unavailable ? .authFailed : .missingAPIKey,
                        providerID: self.descriptor.id,
                        retryClass: unavailable ? .afterUserAction : .none,
                        userAction: unavailable ? nil : .enterAPIKey,
                        redactedDetail: unavailable
                            ? "Gemini credential Keychain unavailable"
                            : "Missing Gemini API key"
                    ))
                    return
                }

                let startTime = Date()
                let payloadSource = self.preparePayload(for: request)

                defer {
                    if let scratchURL = payloadSource.scratchURL {
                        try? FileManager.default.removeItem(at: scratchURL)
                    }
                }

                let payload: Data
                do {
                    payload = try Self.boundedPayloadData(from: payloadSource.fileURL)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                    return
                } catch let error as GeminiTranscriptionError {
                    continuation.finish(throwing: self.failure(for: error))
                    return
                } catch {
                    continuation.finish(throwing: VoiceFailure(
                        stage: .recognition,
                        code: .audioEncodingFailed,
                        providerID: self.descriptor.id,
                        redactedDetail: "Could not read captured audio for upload"
                    ))
                    return
                }

                self.afterPayloadPrepared()
                guard !Task.isCancelled else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                guard self.consentGranted() else {
                    continuation.finish(throwing: VoiceFailure(
                        stage: .recognition,
                        code: .cloudAudioConsentRequired,
                        providerID: self.descriptor.id,
                        retryClass: .afterUserAction,
                        artifactState: .durable,
                        userAction: .retryWithOtherProvider,
                        redactedDetail: "Cloud audio consent was revoked before upload"
                    ))
                    return
                }

                do {
                    let result = try await self.transcribeAudio(
                        payload,
                        payloadSource.mimeType,
                        request.audio.durationSeconds,
                        self.steeringPrompt(for: request),
                        apiKey,
                        self.consentGranted
                    )
                    try Task.checkCancellation()

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
                    DevTypeLog.voice.error(
                        "[Voice] Gemini transcription failed \(DevTypeLog.errorMetadata(error), privacy: .public)"
                    )
                    continuation.finish(throwing: VoiceFailure(
                        stage: .recognition,
                        code: .endpointUnreachable,
                        providerID: self.descriptor.id,
                        redactedDetail: "Gemini transcription transport failed"
                    ))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(sessionID: VoiceSessionID) async {}

    // MARK: - Payload

    private struct PayloadSource {
        let fileURL: URL
        let mimeType: String
        let scratchURL: URL?
    }

    /// FLAC-encodes the capture for upload, falling back to the raw file if encoding fails. Data
    /// is deliberately not read here: the resulting file is size-checked before allocation.
    private func preparePayload(for request: SpeechRequest) -> PayloadSource {
        let scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-\(request.sessionID.rawValue.uuidString).flac")

        do {
            let encoded = try FLACEncoder.encode(inputURL: request.audio.fileURL, outputURL: scratchURL)
            DevTypeLog.app.info("[Voice] FLAC encoded \(encoded.byteCount) bytes in \(Int(encoded.encodeSeconds * 1000))ms")
            return PayloadSource(fileURL: encoded.url, mimeType: "audio/flac", scratchURL: scratchURL)
        } catch {
            DevTypeLog.voice.error(
                "[Voice] FLAC encoding failed; using original \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            return PayloadSource(
                fileURL: request.audio.fileURL,
                mimeType: mimeType(forExtension: request.audio.fileURL.pathExtension),
                scratchURL: nil
            )
        }
    }

    /// Rejects oversized input before allocating it, then verifies the post-read size to close a
    /// file-replacement race between metadata inspection and `Data` construction.
    static func boundedPayloadData(
        from fileURL: URL,
        maximumBytes: Int = GeminiTranscriptionClient.maxPayloadSizeBytes
    ) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw GeminiTranscriptionError.payloadTooLarge
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw GeminiTranscriptionError.invalidResponse("Audio size unavailable")
        }
        guard size <= Int64(maximumBytes) else {
            throw GeminiTranscriptionError.payloadTooLarge
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var data = Data()
        let chunkSize = 64 * 1024
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0,
                  let chunk = try handle.read(upToCount: min(chunkSize, remaining)),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else {
            throw GeminiTranscriptionError.payloadTooLarge
        }
        return data
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
        var retryClass: RetryClass = .none
        var artifactState: ArtifactState = .absent

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
        case .responseTooLarge:
            code = .speechProtocolViolation
        case .uploadNotAuthorized:
            code = .cloudAudioConsentRequired
            action = .retryWithOtherProvider
            retryClass = .afterUserAction
            artifactState = .durable
        case .invalidResponse:
            code = .speechProtocolViolation
        }

        return VoiceFailure(
            stage: .recognition,
            code: code,
            providerID: descriptor.id,
            retryClass: retryClass,
            artifactState: artifactState,
            userAction: action,
            redactedDetail: "Gemini transcription failed code=\(code.rawValue)"
        )
    }
}
