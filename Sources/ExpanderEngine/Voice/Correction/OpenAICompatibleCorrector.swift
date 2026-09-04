import Foundation

public final class OpenAICompatibleCorrector: TranscriptCorrector, @unchecked Sendable {
    public let descriptor: CorrectionProviderDescriptor
    private let endpointOverride: URL?
    private let modelOverride: String?

    /// Resolved per call so Preferences changes take effect without relaunching. See the
    /// same note on `OllamaCorrector`.
    public var endpointURL: URL { endpointOverride ?? VoicePreferences.localLLMEndpoint }
    public var modelName: String { modelOverride ?? VoicePreferences.localLLMModel }

    public init(
        endpointURL: URL? = nil,
        modelName: String? = nil
    ) {
        self.endpointOverride = endpointURL
        self.modelOverride = modelName
        self.descriptor = CorrectionProviderDescriptor(
            id: "openaicompatible.corrector",
            displayName: "Local endpoint",
            modelVersion: "runtime",
            privacyRoute: .localNetworkOnly,
            supportsStructuredOutput: true
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
        let endpoint = endpointURL
        guard LocalEndpointSecurity.isValid(endpoint) else {
            throw VoiceFailure(
                stage: .correction,
                code: .endpointUnreachable,
                providerID: descriptor.id,
                retryClass: .afterUserAction,
                artifactState: .durable,
                userAction: .configureEndpoint,
                redactedDetail: "OpenAI-compatible correction refused a non-loopback endpoint"
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
                redactedDetail: "OpenAI-compatible endpoint returned non-200"
            )
        }

        var cleaned = try Self.responseText(from: data)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard route.api == .openAIChatCompletions else {
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
        guard route.api == .openAIChatCompletions else {
            throw LocalCorrectionEndpointRoute.RouteError.unsupportedPath
        }

        let systemInstruction = CorrectionPromptBuilder.systemPrompt(
            policy: request.policy,
            protectedSpans: request.protectedSpans,
            locale: request.locale
        )
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemInstruction],
                ["role": "user", "content": CorrectionPromptBuilder.userPrompt(rawTranscript: request.rawTranscript)]
            ],
            "temperature": 0.0,
            "max_tokens": 1024
        ]

        var urlRequest = URLRequest(url: route.correctionURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = max(1.0, request.deadline.timeIntervalSince(Date()))
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func responseText(from data: Data) throws -> String {
        struct ChatCompletionResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        let parsed = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let firstChoice = parsed.choices.first else {
            throw VoiceFailure(
                stage: .correction,
                code: .speechProtocolViolation,
                providerID: "openaicompatible.corrector",
                redactedDetail: "No completion choices returned"
            )
        }
        return firstChoice.message.content
    }
}
