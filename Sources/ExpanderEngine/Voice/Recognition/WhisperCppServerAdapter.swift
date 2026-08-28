import Foundation

public final class WhisperCppServerAdapter: SpeechRecognizer, @unchecked Sendable {
    public let descriptor: SpeechProviderDescriptor
    public let endpointURL: URL

    public init(endpointURL: URL = URL(string: "http://127.0.0.1:8080/inference")!) {
        self.endpointURL = endpointURL
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

        // Test probe to server
        var req = URLRequest(url: endpointURL.deletingLastPathComponent().appendingPathComponent("health"))
        req.timeoutInterval = 2.0
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                let evidence = ProviderEvidence(
                    providerID: descriptor.id,
                    modelVersion: descriptor.modelVersion,
                    probeTimestamp: Date(),
                    capabilities: ["localLoopback", "whisperInference"]
                )
                return .ready(evidence)
            } else {
                return .temporarilyUnavailable(retryAfterSeconds: 5.0, reason: .endpointUnreachable)
            }
        } catch {
            return .temporarilyUnavailable(retryAfterSeconds: 5.0, reason: .endpointUnreachable)
        }
    }

    public func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let startTime = Date()
                do {
                    let audioData = try Data(contentsOf: request.audio.fileURL)
                    var urlRequest = URLRequest(url: endpointURL)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = max(1.0, request.deadline.timeIntervalSince(Date()))

                    let boundary = "Boundary-\(UUID().uuidString)"
                    urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

                    var body = Data()
                    body.append("--\(boundary)\r\n".data(using: .utf8)!)
                    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.caf\"\r\n".data(using: .utf8)!)
                    body.append("Content-Type: audio/x-caf\r\n\r\n".data(using: .utf8)!)
                    body.append(audioData)
                    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
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
