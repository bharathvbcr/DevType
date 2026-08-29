import Foundation

public final class OllamaCorrector: TranscriptCorrector, @unchecked Sendable {
    public let descriptor: CorrectionProviderDescriptor
    private let endpointOverride: URL?
    private let modelOverride: String?

    /// Resolved per call, not captured at construction. The registry builds providers once
    /// at launch, so a stored endpoint would pin whatever was configured then and silently
    /// ignore every later change the user makes in Preferences.
    public var endpointURL: URL { endpointOverride ?? VoicePreferences.localLLMEndpoint }
    public var modelName: String { modelOverride ?? VoicePreferences.localLLMModel }

    public init(
        endpointURL: URL? = nil,
        modelName: String? = nil
    ) {
        self.endpointOverride = endpointURL
        self.modelOverride = modelName
        self.descriptor = CorrectionProviderDescriptor(
            id: "ollama.corrector",
            displayName: "Ollama",
            modelVersion: "runtime",
            privacyRoute: .localNetworkOnly,
            supportsStructuredOutput: false
        )
    }

    public func probe() async -> ProviderReadiness {
        var req = URLRequest(url: endpointURL.deletingLastPathComponent().appendingPathComponent("tags"))
        req.timeoutInterval = 2.0
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                let evidence = ProviderEvidence(
                    providerID: descriptor.id,
                    modelVersion: modelName,
                    probeTimestamp: Date(),
                    capabilities: ["ollamaNative", "localInference"]
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

        let systemInstruction = CorrectionPromptBuilder.systemPrompt(
            policy: request.policy,
            protectedSpans: request.protectedSpans
        )

        let prompt = systemInstruction + "\n\n" + CorrectionPromptBuilder.userPrompt(rawTranscript: request.rawTranscript)

        let body: [String: Any] = [
            "model": modelName,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.0,
                "num_predict": 1024
            ]
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
                redactedDetail: "Ollama returned non-200 status code"
            )
        }

        struct OllamaResponse: Codable {
            let response: String
        }

        let parsed = try JSONDecoder().decode(OllamaResponse.self, from: data)
        var cleaned = parsed.response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip enclosing quotes if model added them
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count >= 2 {
            cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let latency = Date().timeIntervalSince(startTime) * 1000
        return CorrectionCandidate(
            text: CorrectionOutputSanitizer.sanitize(cleaned),
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            edits: [],
            latencyMs: latency,
            promptVersion: CorrectionPromptBuilder.version,
            refusalDetected: false
        )
    }

    public func cancel(sessionID: VoiceSessionID) async {}
}
