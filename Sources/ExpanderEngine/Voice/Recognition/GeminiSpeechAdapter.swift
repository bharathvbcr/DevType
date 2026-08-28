import Foundation

public final class GeminiSpeechAdapter: SpeechRecognizer, @unchecked Sendable {
    public let descriptor: SpeechProviderDescriptor
    private let modelName: String

    public init(modelName: String = "gemini-2.0-flash") {
        self.modelName = modelName
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
        let evidence = ProviderEvidence(
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            probeTimestamp: Date(),
            capabilities: ["cloudTranscription", "multilingual", "punctuation"]
        )
        return .ready(evidence)
    }

    public func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard request.privacyRoute == .cloudPermitted else {
                    continuation.finish(throwing: VoiceFailure(
                        stage: .recognition,
                        code: .speechProtocolViolation,
                        providerID: descriptor.id,
                        redactedDetail: "Cloud audio egress blocked: session privacy route is \(request.privacyRoute)"
                    ))
                    return
                }

                guard let apiKey = GeminiAPIKeyStore.load(), !apiKey.isEmpty else {
                    continuation.finish(throwing: VoiceFailure(
                        stage: .recognition,
                        code: .missingAPIKey,
                        providerID: descriptor.id,
                        userAction: .enterAPIKey,
                        redactedDetail: "Missing Gemini API key"
                    ))
                    return
                }

                let startTime = Date()
                do {
                    let audioData = try Data(contentsOf: request.audio.fileURL)
                    let base64Audio = audioData.base64EncodedString()

                    let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)"
                    guard let url = URL(string: urlString) else {
                        throw VoiceFailure(stage: .recognition, code: .endpointUnreachable, providerID: descriptor.id)
                    }

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.timeoutInterval = max(2.0, request.deadline.timeIntervalSince(Date()))

                    let prompt = "Transcribe the spoken audio verbatim. Output only the transcription without any extra commentary, notes, or markdown formatting."
                    let requestBody: [String: Any] = [
                        "contents": [
                            [
                                "parts": [
                                    ["text": prompt],
                                    [
                                        "inline_data": [
                                            "mime_type": "audio/x-caf",
                                            "data": base64Audio
                                        ]
                                    ]
                                ]
                            ]
                        ],
                        "generationConfig": [
                            "temperature": 0.0,
                            "maxOutputTokens": 2048
                        ]
                    ]

                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

                    let (data, response) = try await URLSession.shared.data(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw VoiceFailure(stage: .recognition, code: .endpointUnreachable, providerID: descriptor.id)
                    }

                    if http.statusCode == 401 || http.statusCode == 403 {
                        throw VoiceFailure(stage: .recognition, code: .authFailed, providerID: descriptor.id, userAction: .enterAPIKey)
                    } else if http.statusCode == 429 {
                        throw VoiceFailure(stage: .recognition, code: .rateLimited, providerID: descriptor.id)
                    } else if !(200...299).contains(http.statusCode) {
                        throw VoiceFailure(stage: .recognition, code: .endpointUnreachable, providerID: descriptor.id)
                    }

                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let candidates = json["candidates"] as? [[String: Any]],
                          let firstCandidate = candidates.first,
                          let content = firstCandidate["content"] as? [String: Any],
                          let parts = content["parts"] as? [[String: Any]],
                          let firstPart = parts.first,
                          let rawText = firstPart["text"] as? String else {
                        throw VoiceFailure(stage: .recognition, code: .speechProtocolViolation, providerID: descriptor.id, redactedDetail: "Malformed Gemini response JSON")
                    }

                    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let latency = Date().timeIntervalSince(startTime) * 1000

                    let raw = RawTranscript(
                        text: text,
                        localeIdentifier: request.locale.identifier,
                        confidence: 0.98,
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
                        confidence: 0.98,
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
