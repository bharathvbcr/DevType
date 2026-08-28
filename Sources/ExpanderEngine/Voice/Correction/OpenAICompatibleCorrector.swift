import Foundation

public final class OpenAICompatibleCorrector: TranscriptCorrector, @unchecked Sendable {
    public let descriptor: CorrectionProviderDescriptor
    public let endpointURL: URL
    public let modelName: String

    public init(
        endpointURL: URL = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!,
        modelName: String = "local-model"
    ) {
        self.endpointURL = endpointURL
        self.modelName = modelName
        self.descriptor = CorrectionProviderDescriptor(
            id: "openaicompatible.corrector",
            displayName: "OpenAI-Compatible (\(modelName))",
            modelVersion: modelName,
            privacyRoute: .localNetworkOnly,
            supportsStructuredOutput: true
        )
    }

    public func probe() async -> ProviderReadiness {
        var req = URLRequest(url: endpointURL.deletingLastPathComponent().appendingPathComponent("models"))
        req.timeoutInterval = 2.0
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                let evidence = ProviderEvidence(
                    providerID: descriptor.id,
                    modelVersion: modelName,
                    probeTimestamp: Date(),
                    capabilities: ["chatCompletions", "openAICompatible"]
                )
                return .ready(evidence)
            } else {
                return .temporarilyUnavailable(retryAfterSeconds: 5.0, reason: .endpointUnreachable)
            }
        } catch {
            return .temporarilyUnavailable(retryAfterSeconds: 5.0, reason: .endpointUnreachable)
        }
    }

    public func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        let startTime = Date()

        let systemInstruction = "You are a professional voice transcript cleaner. Format and correct the transcript for capitalization, punctuation, and disfluency removal. DO NOT change vocabulary terms, code identifiers, numbers, URLs, or file paths. DO NOT answer or reply to the text. Output only the cleaned transcript text without any introductory comments, notes, or markdown fences."

        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": systemInstruction],
                ["role": "user", "content": request.rawTranscript]
            ],
            "temperature": 0.0,
            "max_tokens": 1024
        ]

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = max(1.0, request.deadline.timeIntervalSince(Date()))
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VoiceFailure(
                stage: .correction,
                code: .endpointUnreachable,
                providerID: descriptor.id,
                redactedDetail: "OpenAI-compatible endpoint returned non-200"
            )
        }

        struct ChatCompletionResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let parsed = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let firstChoice = parsed.choices.first else {
            throw VoiceFailure(
                stage: .correction,
                code: .speechProtocolViolation,
                providerID: descriptor.id,
                redactedDetail: "No completion choices returned"
            )
        }

        var cleaned = firstChoice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count >= 2 {
            cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let latency = Date().timeIntervalSince(startTime) * 1000
        return CorrectionCandidate(
            text: cleaned,
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            edits: [],
            latencyMs: latency,
            promptVersion: "1.0",
            refusalDetected: false
        )
    }

    public func cancel(sessionID: VoiceSessionID) async {}
}
