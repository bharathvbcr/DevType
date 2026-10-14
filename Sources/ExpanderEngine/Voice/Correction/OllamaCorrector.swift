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
        await LocalCorrectorProbe.readiness(
            endpoint: endpointURL,
            providerID: descriptor.id,
            modelVersion: modelName,
            capabilities: ["ollamaNative", "localInference"],
            makeRequest: Self.probeRequest(endpoint:)
        )
    }

    public func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        let endpoint = endpointURL
        guard LocalEndpointSecurity.isValid(endpoint) else {
            throw VoiceFailure(
                stage: .correction,
                code: .endpointUnreachable,
                providerID: descriptor.id,
                retryClass: .afterUserAction,
                artifactState: .durable,
                userAction: .configureEndpoint,
                redactedDetail: "Ollama refused a non-loopback endpoint"
            )
        }
        let startTime = Date()
        let urlRequest = try Self.correctionRequest(request, endpoint: endpoint, model: modelName)

        let (data, response) = try await LocalEndpointSecurity.data(
            for: urlRequest,
            maximumResponseBytes: LocalEndpointSecurity.maximumCorrectionResponseBytes
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VoiceFailure(
                stage: .correction,
                code: .endpointUnreachable,
                providerID: descriptor.id,
                redactedDetail: "Ollama returned non-200 status code"
            )
        }

        let decoded = try Self.responseText(from: data, endpoint: endpoint)
        var cleaned = decoded.text
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip enclosing quotes if model added them
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count >= 2 {
            cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let latency = Date().timeIntervalSince(startTime) * 1000
        return CorrectionCandidate(
            text: CorrectionOutputSanitizer.sanitize(
                cleaned,
                original: request.rawTranscript,
                markdown: AIPreferences.voiceMarkdownPolicy
            ),
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            edits: [],
            latencyMs: latency,
            promptVersion: CorrectionPromptBuilder.version,
            refusalDetected: false,
            modelStopIsComplete: decoded.modelStopIsComplete
        )
    }

    public func cancel(sessionID: VoiceSessionID) async {}

    static func probeRequest(endpoint: URL) throws -> URLRequest {
        let route = try LocalCorrectionEndpointRoute.resolve(endpoint)
        guard route.isOllamaNative else {
            throw LocalCorrectionEndpointRoute.RouteError.unsupportedPath
        }
        return LocalCorrectorProbe.request(for: route)
    }

    static func correctionRequest(
        _ request: CorrectionRequest,
        endpoint: URL,
        model: String
    ) throws -> URLRequest {
        let route = try LocalCorrectionEndpointRoute.resolve(endpoint)
        guard route.isOllamaNative else {
            throw LocalCorrectionEndpointRoute.RouteError.unsupportedPath
        }

        let systemInstruction = CorrectionPromptBuilder.systemPrompt(
            policy: request.policy,
            protectedSpans: request.protectedSpans,
            locale: request.locale
        )
        let userInstruction = CorrectionPromptBuilder.userPrompt(rawTranscript: request.rawTranscript)

        let body: [String: Any]
        switch route.api {
        case .ollamaChat:
            body = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemInstruction],
                    ["role": "user", "content": userInstruction]
                ],
                "stream": false,
                "options": [
                    "temperature": 0.0,
                    "num_predict": 1024
                ]
            ]
        case .ollamaGenerate:
            body = [
                "model": model,
                "prompt": systemInstruction + "\n\n" + userInstruction,
                "stream": false,
                "options": [
                    "temperature": 0.0,
                    "num_predict": 1024
                ]
            ]
        case .openAIChatCompletions:
            throw LocalCorrectionEndpointRoute.RouteError.unsupportedPath
        }

        var urlRequest = URLRequest(url: route.correctionURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = max(1.0, request.deadline.timeIntervalSince(Date()))
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func responseText(from data: Data, endpoint: URL) throws -> DecodedCorrectionText {
        let route = try LocalCorrectionEndpointRoute.resolve(endpoint)
        switch route.api {
        case .ollamaChat:
            struct ChatResponse: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
                let done: Bool?
                let doneReason: String?

                enum CodingKeys: String, CodingKey {
                    case message
                    case done
                    case doneReason = "done_reason"
                }
            }
            let parsed = try JSONDecoder().decode(ChatResponse.self, from: data)
            let stop = CorrectionGenerationStop.classify(reason: parsed.doneReason, done: parsed.done)
            return try DecodedCorrectionText.resolve(content: parsed.message?.content, stop: stop)
        case .ollamaGenerate:
            struct GenerateResponse: Decodable {
                let response: String?
                let done: Bool?
                let doneReason: String?

                enum CodingKeys: String, CodingKey {
                    case response
                    case done
                    case doneReason = "done_reason"
                }
            }
            let parsed = try JSONDecoder().decode(GenerateResponse.self, from: data)
            let stop = CorrectionGenerationStop.classify(reason: parsed.doneReason, done: parsed.done)
            return try DecodedCorrectionText.resolve(content: parsed.response, stop: stop)
        case .openAIChatCompletions:
            throw LocalCorrectionEndpointRoute.RouteError.unsupportedPath
        }
    }
}
