import Foundation

public final class WhisperCppServerAdapter: SpeechRecognizer, @unchecked Sendable {
    public let descriptor: SpeechProviderDescriptor
    private let endpointOverride: URL?

    /// Resolved per call so a Preferences change applies without relaunching.
    public var endpointURL: URL { endpointOverride ?? VoicePreferences.whisperEndpoint }

    public init(endpointURL: URL? = nil) {
        self.endpointOverride = endpointURL
        self.descriptor = SpeechProviderDescriptor(
            id: "whispercpp.server",
            displayName: "Local whisper.cpp Server",
            modelVersion: "whisper-local",
            privacyRoute: .localNetworkOnly,
            supportsStreaming: false,
            supportsContextualStrings: false
        )
    }

    public func probe() async -> ProviderReadiness {
        let components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        guard let host = components?.host, (host == "127.0.0.1" || host == "localhost" || host == "::1") else {
            return .requiresConfiguration(.invalidEndpointFormat)
        }

        guard await WhisperServerSetup.isReachable(endpoint: endpointURL, timeout: 2.0) else {
            return .temporarilyUnavailable(retryAfterSeconds: 5.0, reason: .endpointUnreachable)
        }

        let evidence = ProviderEvidence(
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            probeTimestamp: Date(),
            capabilities: ["localLoopback", "whisperInference"]
        )
        return .ready(evidence)
    }

    public func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let startTime = Date()
                do {
                    // whisper.cpp decodes 16 kHz mono PCM WAV natively; other containers
                    // depend on how the server was built. Capture is CAF, so it is
                    // converted here rather than hoping the server can read it.
                    let audioData = try WhisperAudioPayload.wav16kMono(from: request.audio.fileURL)
                    var urlRequest = URLRequest(url: endpointURL)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = max(1.0, request.deadline.timeIntervalSince(Date()))

                    let boundary = "Boundary-\(UUID().uuidString)"
                    urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

                    var body = Data()
                    func field(_ name: String, _ value: String) {
                        body.append("--\(boundary)\r\n".data(using: .utf8)!)
                        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                        body.append(value.data(using: .utf8)!)
                        body.append("\r\n".data(using: .utf8)!)
                    }

                    body.append("--\(boundary)\r\n".data(using: .utf8)!)
                    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
                    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
                    body.append(audioData)
                    body.append("\r\n".data(using: .utf8)!)

                    // Ask for JSON explicitly; the server otherwise answers in plain text
                    // and the decode below would fail on a perfectly good transcription.
                    field("response_format", "json")
                    field("temperature", "0.0")
                    if !request.locale.identifier.isEmpty {
                        field("language", String(request.locale.identifier.prefix(2)))
                    }

                    body.append("--\(boundary)--\r\n".data(using: .utf8)!)
                    urlRequest.httpBody = body

                    let (data, response) = try await URLSession.shared.data(for: urlRequest)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        throw VoiceFailure(
                            stage: .recognition,
                            code: .endpointUnreachable,
                            providerID: descriptor.id,
                            redactedDetail: "whisper.cpp returned non-200 status"
                        )
                    }

                    struct WhisperResult: Codable {
                        let text: String
                    }

                    let parsed = try JSONDecoder().decode(WhisperResult.self, from: data)
                    let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)

                    let latency = Date().timeIntervalSince(startTime) * 1000
                    let raw = RawTranscript(
                        text: text,
                        localeIdentifier: request.locale.identifier,
                        confidence: 0.95,
                        providerID: descriptor.id,
                        modelVersion: descriptor.modelVersion,
                        latencyMs: latency,
                        audioSHA256: request.audio.sha256Hex,
                        isFinal: true
                    )

                    let segment = SpeechSegment(
                        segmentID: UUID().uuidString,
                        revision: 1,
                        startSeconds: 0,
                        durationSeconds: request.audio.durationSeconds,
                        text: text,
                        confidence: 0.95,
                        finality: .final
                    )
                    continuation.yield(.segment(segment))

                    let completion = SpeechCompletion(
                        rawTranscript: raw,
                        finalSegmentCount: 1,
                        totalDurationSeconds: request.audio.durationSeconds
                    )
                    continuation.yield(.completed(completion))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancel(sessionID: VoiceSessionID) async {}
}
