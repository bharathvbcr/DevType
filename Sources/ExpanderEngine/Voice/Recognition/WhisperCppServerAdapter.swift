import Foundation

public final class WhisperCppServerAdapter: SpeechRecognizer, @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)
    typealias ManagedInferenceURL = @Sendable () -> URL?
    typealias Reachability = @Sendable (URL) async -> Bool

    public let descriptor: SpeechProviderDescriptor
    private let endpointOverride: URL?
    private let maximumWAVBytes: Int
    private let transport: Transport
    private let managedInferenceURL: ManagedInferenceURL
    private let reachability: Reachability

    /// Resolved per call so a Preferences change applies without relaunching.
    /// This is the saved spelling. A spawned child is addressed from `requestURL()`.
    public var endpointURL: URL { endpointOverride ?? VoicePreferences.whisperEndpoint }

    public convenience init(endpointURL: URL? = nil) {
        self.init(
            endpointURL: endpointURL,
            transport: { request, maximumResponseBytes in
                try await LocalEndpointSecurity.data(
                    for: request,
                    maximumResponseBytes: maximumResponseBytes
                )
            },
            managedInferenceURL: { WhisperServerController.shared.managedInferenceURL },
            reachability: { url in
                await WhisperServerSetup.isReachable(endpoint: url, timeout: 2.0)
            }
        )
    }

    init(
        endpointURL: URL?,
        maximumWAVBytes: Int = WhisperAudioPayload.maximumWAVBytes,
        transport: @escaping Transport,
        managedInferenceURL: @escaping ManagedInferenceURL = { nil },
        reachability: @escaping Reachability = { url in
            await WhisperServerSetup.isReachable(endpoint: url, timeout: 2.0)
        }
    ) {
        self.endpointOverride = endpointURL
        self.maximumWAVBytes = maximumWAVBytes
        self.transport = transport
        self.managedInferenceURL = managedInferenceURL
        self.reachability = reachability
        self.descriptor = SpeechProviderDescriptor(
            id: "whispercpp.server",
            displayName: "Local whisper.cpp Server",
            modelVersion: "whisper-local",
            privacyRoute: .localNetworkOnly,
            supportsStreaming: false,
            supportsContextualStrings: false
        )
    }

    /// Saved spelling after it has been accepted as loopback, then the bound address of a
    /// child this controller spawned. A non-loopback preference is returned unchanged so it
    /// stays `invalidEndpoint` instead of being hidden on 127.0.0.1.
    private func requestURL() -> URL {
        let saved = endpointURL
        guard LocalEndpointSecurity.isValid(saved) else { return saved }
        return managedInferenceURL() ?? saved
    }

    public func probe() async -> ProviderReadiness {
        let endpoint = requestURL()
        guard LocalEndpointSecurity.isValid(endpoint) else {
            return .requiresConfiguration(.invalidEndpointFormat)
        }
        let probeURL = WhisperServerSetup.readinessProbeURL(for: endpoint)
        guard LocalEndpointSecurity.isValid(probeURL) else {
            return .temporarilyUnavailable(retryAfterSeconds: 5.0, reason: .endpointUnreachable)
        }

        guard await reachability(probeURL) else {
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
        // Capture once, then enforce again at the actual egress boundary. `probe()` is only a
        // readiness hint: callers can invoke `transcribe` directly and preferences can change
        // between a probe and this call. Audio must never follow either path off loopback.
        let endpoint = requestURL()
        return AsyncThrowingStream { continuation in
            let task = Task {
                let startTime = Date()
                do {
                    try Task.checkCancellation()
                    guard LocalEndpointSecurity.isValid(endpoint) else {
                        throw VoiceFailure(
                            stage: .recognition,
                            code: .endpointUnreachable,
                            providerID: descriptor.id,
                            retryClass: .afterUserAction,
                            artifactState: .durable,
                            userAction: .configureEndpoint,
                            redactedDetail: "Local Whisper refused a non-loopback endpoint"
                        )
                    }
                    // whisper.cpp decodes 16 kHz mono PCM WAV natively; other containers
                    // depend on how the server was built. Capture is CAF, so it is
                    // converted here rather than hoping the server can read it.
                    let audioData = try WhisperAudioPayload.wav16kMono(
                        from: request.audio.fileURL,
                        maximumWAVBytes: self.maximumWAVBytes
                    )
                    try Task.checkCancellation()
                    var urlRequest = URLRequest(url: endpoint)
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

                    try Task.checkCancellation()
                    let (data, response) = try await self.transport(
                        urlRequest,
                        LocalEndpointSecurity.maximumTranscriptionResponseBytes
                    )
                    try Task.checkCancellation()
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(sessionID: VoiceSessionID) async {
        // Consumer cancellation terminates the stream and cancels its conversion/transport task.
    }
}
