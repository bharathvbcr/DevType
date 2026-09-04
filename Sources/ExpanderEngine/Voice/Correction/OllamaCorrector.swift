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
        let endpoint = endpointURL
        guard LocalEndpointSecurity.isValid(endpoint) else {
            return .requiresConfiguration(.invalidEndpointFormat)
        }
        do {
            let req = try Self.probeRequest(endpoint: endpoint)
            let (_, response) = try await LocalEndpointSecurity.data(
                for: req,
                maximumResponseBytes: LocalEndpointSecurity.maximumReadinessResponseBytes
            )
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

        var cleaned = try Self.responseText(from: data, endpoint: endpoint)
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
            refusalDetected: false
        )
    }

    public func cancel(sessionID: VoiceSessionID) async {}

    static func probeRequest(endpoint: URL) throws -> URLRequest {
        let route = try LocalCorrectionEndpointRoute.resolve(endpoint)
        guard route.isOllamaNative else {
            throw LocalCorrectionEndpointRoute.RouteError.unsupportedPath
        }
        var request = URLRequest(url: route.readinessURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0
        return request
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

    static func responseText(from data: Data, endpoint: URL) throws -> String {
        let route = try LocalCorrectionEndpointRoute.resolve(endpoint)
        switch route.api {
        case .ollamaChat:
            struct ChatResponse: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            return try JSONDecoder().decode(ChatResponse.self, from: data).message.content
        case .ollamaGenerate:
            struct GenerateResponse: Decodable { let response: String }
            return try JSONDecoder().decode(GenerateResponse.self, from: data).response
        case .openAIChatCompletions:
            throw LocalCorrectionEndpointRoute.RouteError.unsupportedPath
        }
    }
}
