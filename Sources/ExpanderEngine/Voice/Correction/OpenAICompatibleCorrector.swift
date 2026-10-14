import Foundation

/// How the HTTP body said generation ended. Only `finished` may be inserted.
enum CorrectionGenerationStop: Equatable, Sendable {
    case finished
    case length
    case omitted
    case notFinished

    var isComplete: Bool { self == .finished }

    /// `done == false` is never finished. A length reason stays length even then.
    /// Nil, blank, or whitespace-only reasons are omitted, not an implied stop.
    static func classify(reason: String?, done: Bool? = nil) -> CorrectionGenerationStop {
        let normalized: String?
        if let reason {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized = trimmed.isEmpty ? nil : trimmed.lowercased()
        } else {
            normalized = nil
        }
        if normalized == "length" {
            return .length
        }
        if done == false {
            return .notFinished
        }
        switch normalized {
        case nil:
            return .omitted
        case "stop":
            return .finished
        default:
            return .notFinished
        }
    }
}

struct DecodedCorrectionText: Equatable, Sendable {
    let text: String
    let stop: CorrectionGenerationStop

    var modelStopIsComplete: Bool { stop.isComplete }

    /// Missing content throws unless the body already says generation did not finish.
    /// A present non-stop reason must still fall back, including when content is absent.
    static func resolve(content: String?, stop: CorrectionGenerationStop) throws -> DecodedCorrectionText {
        if let content {
            return DecodedCorrectionText(text: content, stop: stop)
        }
        switch stop {
        case .length, .notFinished:
            return DecodedCorrectionText(text: "", stop: stop)
        case .finished, .omitted:
            throw DecodingError.valueNotFound(
                String.self,
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Correction response omitted content and has no non-stop finish reason"
                )
            )
        }
    }
}

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
        await LocalCorrectorProbe.readiness(
            endpoint: endpointURL,
            providerID: descriptor.id,
            modelVersion: modelName,
            capabilities: ["chatCompletions", "openAICompatible"],
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

        let decoded = try Self.responseText(from: data)
        var cleaned = decoded.text
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
            refusalDetected: false,
            modelStopIsComplete: decoded.modelStopIsComplete
        )
    }

    public func cancel(sessionID: VoiceSessionID) async {}

    static func probeRequest(endpoint: URL) throws -> URLRequest {
        let route = try LocalCorrectionEndpointRoute.resolve(endpoint)
        guard route.api == .openAIChatCompletions else {
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

    static func responseText(from data: Data) throws -> DecodedCorrectionText {
        struct ChatCompletionResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
                let finishReason: String?

                enum CodingKeys: String, CodingKey {
                    case message
                    case finishReason = "finish_reason"
                }
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
        let stop = CorrectionGenerationStop.classify(reason: firstChoice.finishReason)
        return try DecodedCorrectionText.resolve(content: firstChoice.message?.content, stop: stop)
    }
}
