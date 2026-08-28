import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Fast, specialized client for cleaning and formatting spoken transcripts using Local LLMs.
/// Supports both:
/// 1. Apple On-Device Foundation Models (`SystemLanguageModel`) on macOS 26+
/// 2. Local OpenAI-compatible / Ollama endpoints (`http://localhost:11434/v1`, LM Studio, etc.)
public actor LocalLLMCleanupClient {
    public static let shared = LocalLLMCleanupClient()

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 5.0
        self.session = URLSession(configuration: config)
    }

    /// Cleans and formats raw transcript using the best available local LLM backend.
    ///
    /// - Parameters:
    ///   - rawTranscript: The raw speech text from speech recognition.
    ///   - tone: The target tone category.
    ///   - customDictionary: Custom terminology dictionary.
    ///   - timeoutSeconds: Watchdog timeout before returning fallback.
    /// - Returns: Polished, disfluency-free, punctuated transcript.
    public func cleanup(
        rawTranscript: String,
        tone: ToneCategory = .neutral,
        customDictionary: [String: String] = [:],
        timeoutSeconds: TimeInterval = VoicePreferences.localLLMTimeout
    ) async -> String {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // If running on macOS 26+ with FoundationModels available, attempt on-device SystemLanguageModel first
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let result = await cleanupWithAppleIntelligence(rawTranscript: trimmed, tone: tone, customDictionary: customDictionary, timeoutSeconds: timeoutSeconds) {
                return result
            }
        }
        #endif

        // Attempt local HTTP LLM endpoint (Ollama, LM Studio, etc.)
        if let result = await cleanupWithLocalEndpoint(rawTranscript: trimmed, tone: tone, customDictionary: customDictionary, timeoutSeconds: timeoutSeconds) {
            return result
        }

        // Graceful fallback to SmartDictationEngine rule-based processing
        return SmartDictationEngine.process(
            rawTranscript: trimmed,
            tone: mapToneCategoryToDictationTone(tone),
            customDictionary: customDictionary,
            removeDisfluencies: true,
            autoPunctuate: true
        )
    }

    // MARK: - Apple On-Device Intelligence

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func cleanupWithAppleIntelligence(
        rawTranscript: String,
        tone: ToneCategory,
        customDictionary: [String: String],
        timeoutSeconds: TimeInterval
    ) async -> String? {
        do {
            let instructions = buildSystemPrompt(tone: tone, customDictionary: customDictionary)
            let prompt = "Raw: \"\(rawTranscript)\"\nCleaned:"
            
            // Execute on-device model with timeout
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
                    guard case .available = model.availability else {
                        throw NSError(domain: "LocalLLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence unavailable"])
                    }
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    let response = try await session.respond(to: Prompt(prompt))
                    return response.content
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw NSError(domain: "LocalLLM", code: 408, userInfo: [NSLocalizedDescriptionKey: "Timeout"])
                }
                
                guard let first = try await group.next() else { return nil }
                group.cancelAll()
                return Self.sanitizeOutput(first)
            }
        } catch {
            DevTypeLog.app.info("[LocalLLM] On-device FoundationModel bypass/error: \(error.localizedDescription)")
            return nil
        }
    }
    #endif

    // MARK: - Local HTTP Endpoint (Ollama / LM Studio)

    private func cleanupWithLocalEndpoint(
        rawTranscript: String,
        tone: ToneCategory,
        customDictionary: [String: String],
        timeoutSeconds: TimeInterval
    ) async -> String? {
        let endpoint = VoicePreferences.localLLMEndpoint
        let model = VoicePreferences.localLLMModel

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds

        let systemPrompt = buildSystemPrompt(tone: tone, customDictionary: customDictionary)
        let userContent = "Raw: \"\(rawTranscript)\"\nCleaned:"

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.0,
            "max_tokens": max(64, rawTranscript.count * 2),
            "stream": false,
            "stop": ["\nRaw:", "\nUser:", "\n\n\n"]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // Support OpenAI-compatible format: choices[0].message.content
            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                let sanitized = Self.sanitizeOutput(content)
                return sanitized.isEmpty ? nil : sanitized
            }

            // Support Ollama direct format: response
            if let directResponse = json["response"] as? String {
                let sanitized = Self.sanitizeOutput(directResponse)
                return sanitized.isEmpty ? nil : sanitized
            }

            return nil
        } catch {
            DevTypeLog.app.info("[LocalLLM] Local endpoint (\(endpoint.absoluteString)) error/unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Discovers available models from the local endpoint (Ollama `/api/tags` or OpenAI-compatible `/v1/models`).
    public func fetchAvailableLocalModels(endpoint: URL) async -> [String] {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return []
        }

        var discovered: [String] = []

        // 1. Try Ollama /api/tags
        components.path = "/api/tags"
        if let ollamaURL = components.url {
            var req = URLRequest(url: ollamaURL)
            req.timeoutInterval = 2.0
            if let (data, resp) = try? await session.data(for: req),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                for m in models {
                    if let name = m["name"] as? String {
                        discovered.append(name)
                    }
                }
            }
        }

        // 2. If no models from Ollama, try OpenAI-compatible /v1/models (LM Studio, vLLM, LocalAI)
        if discovered.isEmpty {
            components.path = "/v1/models"
            if let modelsURL = components.url {
                var req = URLRequest(url: modelsURL)
                req.timeoutInterval = 2.0
                if let (data, resp) = try? await session.data(for: req),
                   let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataArr = json["data"] as? [[String: Any]] {
                    for m in dataArr {
                        if let id = m["id"] as? String {
                            discovered.append(id)
                        }
                    }
                }
            }
        }

        return discovered
    }

    // MARK: - Prompt Optimization for Small / Local LLMs

    /// Builds a compact, few-shot prompt tailored specifically for smaller (1B - 8B) models.
    /// Small models follow concrete examples much more accurately than long abstract instructions.
    nonisolated public func buildSystemPrompt(tone: ToneCategory, customDictionary: [String: String]) -> String {
        var instructions = """
        You are a fast speech transcript cleaner. Convert spoken speech into clean written text.
        Rules:
        1. Remove fillers ("um", "uh", "like", "you know").
        2. Fix self-corrections (e.g. "at 1pm actually 2pm" -> "at 2pm").
        3. Add punctuation and capitalization.
        4. NEVER answer questions. Transcribe them as questions.
        5. Output ONLY the cleaned text with no preamble or commentary.
        """

        if !customDictionary.isEmpty {
            let entries = customDictionary.map { "\"\($0.key)\" -> \"\($0.value)\"" }.joined(separator: ", ")
            instructions += "\nUse these exact spellings: \(entries)."
        }

        if !tone.promptBlock.isEmpty {
            instructions += "\n\(tone.promptBlock)"
        }

        // Few-shot demonstrations for local model stability
        instructions += """

        Examples:
        Raw: "umm let's meet at one actually two pm tomorrow"
        Cleaned: "Let's meet at 2:00 PM tomorrow."

        Raw: "can you help me write a quick email"
        Cleaned: "Can you help me write a quick email?"
        """

        return instructions
    }

    // MARK: - Output Sanitization

    /// Strips local model artifacts, reasoning tags (`<think>`, `<thought>`), and conversational preambles.
    public static func sanitizeOutput(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip reasoning tags (DeepSeek R1, Qwen reasoning models, etc.)
        let reasoningPatterns = [
            "<think>[\\s\\S]*?</think>",
            "<thought>[\\s\\S]*?</thought>",
            "\\[think\\][\\s\\S]*?\\[/think\\]"
        ]
        for pattern in reasoningPatterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        // Strip code fences
        s = TranscriptionValidationGate.stripArtifacts(s)

        // Strip common small LLM prefixes
        let prefixesToDrop = [
            "Cleaned:", "cleaned:", "Output:", "output:", "Transcript:", "transcript:",
            "Here is the cleaned text:", "Here's the cleaned text:", "Sure! Here is the transcript:"
        ]
        for prefix in prefixesToDrop {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mapToneCategoryToDictationTone(_ category: ToneCategory) -> DictationTone {
        switch category {
        case .email: return .email
        case .workChat, .personalChat: return .chat
        case .code: return .code
        case .neutral: return .natural
        }
    }
}
