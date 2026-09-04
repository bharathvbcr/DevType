import Foundation

/// Errors that can occur during Gemini transcription
public enum GeminiTranscriptionError: Error, Equatable, Sendable {
    case noAPIKey
    case invalidAPIKey
    case modelAccessDenied
    case rateLimited
    case quotaExhausted
    case timeout
    case networkError(String)
    case safetyBlocked
    case emptyTranscript
    case payloadTooLarge
    case responseTooLarge
    case uploadNotAuthorized
    case invalidResponse(String)
}

/// The result of a Gemini transcription
public struct GeminiTranscriptionResult: Sendable, Equatable {
    /// The transcribed text
    public let text: String
    /// The raw transcribed text, if any distinction exists
    public let rawText: String
    
    public init(text: String, rawText: String) {
        self.text = text
        self.rawText = rawText
    }
}

/// The detailed verdict of an API key validation check.
public enum APIKeyValidationResult: Equatable, Sendable {
    case valid(modelName: String)
    case invalidKey(reason: String)
    case rateLimited
    case quotaExhausted
    case networkError(reason: String)

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    public var userMessage: String {
        switch self {
        case .valid:
            return "Key Valid & Saved"
        case .invalidKey(let reason):
            return reason.isEmpty ? "Invalid API Key" : reason
        case .rateLimited:
            return "API Rate Limited (429)"
        case .quotaExhausted:
            return "Quota Exhausted"
        case .networkError(let reason):
            return "Network Error: \(reason)"
        }
    }
}

/// A raw URLSession-based Gemini API client for the `gemini-3.5-transcribe` model.
public actor GeminiTranscriptionClient {
    public static let shared = GeminiTranscriptionClient()
    private let session: URLSession
    private let baseURL: URL
    private let maximumResponseBytes: Int
    private let validationURL: URL
    private let maximumValidationResponseBytes: Int
    
    /// Maximum allowed audio payload size for inline base64 data (25MB).
    public static let maxPayloadSizeBytes = 25 * 1024 * 1024

    /// Gemini responses are text transcripts. Four MiB is generous for legitimate output while
    /// bounding both the raw SSE stream and the decoded transcript held in memory.
    public static let maxResponseSizeBytes = 4 * 1024 * 1024
    /// API-key validation only needs to consume the small models-list envelope. Keep its budget
    /// independent from transcription so a hostile error/success response cannot allocate MiBs.
    public static let maxValidationResponseSizeBytes = 64 * 1024
    private static let productionBaseURL = URL(
        string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe:streamGenerateContent?alt=sse"
    )!
    private static let productionValidationURL = URL(
        string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1"
    )!
    
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.baseURL = Self.productionBaseURL
        self.maximumResponseBytes = Self.maxResponseSizeBytes
        self.validationURL = Self.productionValidationURL
        self.maximumValidationResponseBytes = Self.maxValidationResponseSizeBytes
    }

    init(
        session: URLSession,
        baseURL: URL,
        maximumResponseBytes: Int,
        validationURL: URL? = nil,
        maximumValidationResponseBytes: Int = GeminiTranscriptionClient.maxValidationResponseSizeBytes
    ) {
        self.session = session
        self.baseURL = baseURL
        self.maximumResponseBytes = maximumResponseBytes
        self.validationURL = validationURL ?? Self.productionValidationURL
        self.maximumValidationResponseBytes = maximumValidationResponseBytes
    }
    
    /// Transcribes audio data using the Gemini model.
    /// - Parameters:
    ///   - audioData: The audio data to transcribe
    ///   - mimeType: The mime type of the audio data (e.g. "audio/flac")
    ///   - audioDurationSeconds: The duration of the audio in seconds, for timeout calculation
    ///   - steeringPrompt: The prompt to steer the transcription
    ///   - apiKey: The Gemini API key
    ///   - uploadAuthorized: Live authority checked immediately before every network attempt.
    /// - Returns: A GeminiTranscriptionResult
    public func transcribe(
        audioData: Data,
        mimeType: String,
        audioDurationSeconds: TimeInterval,
        steeringPrompt: String,
        apiKey: String,
        uploadAuthorized: @escaping @Sendable () -> Bool
    ) async throws -> GeminiTranscriptionResult {
        return try await transcribeWithRetry(
            audioData: audioData,
            mimeType: mimeType,
            audioDurationSeconds: audioDurationSeconds,
            steeringPrompt: steeringPrompt,
            apiKey: apiKey,
            uploadAuthorized: uploadAuthorized,
            isRetry: false
        )
    }
    
    private func transcribeWithRetry(
        audioData: Data,
        mimeType: String,
        audioDurationSeconds: TimeInterval,
        steeringPrompt: String,
        apiKey: String,
        uploadAuthorized: @escaping @Sendable () -> Bool,
        isRetry: Bool
    ) async throws -> GeminiTranscriptionResult {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else {
            throw GeminiTranscriptionError.noAPIKey
        }
        
        guard !audioData.isEmpty else {
            throw GeminiTranscriptionError.emptyTranscript
        }
        
        guard audioData.count <= Self.maxPayloadSizeBytes else {
            throw GeminiTranscriptionError.payloadTooLarge
        }
        
        let timeout = max(60.0, 2.0 * audioDurationSeconds)
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = timeout
        
        // Build the request body
        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": steeringPrompt]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        [
                            "inlineData": [
                                "mimeType": mimeType,
                                "data": audioData.base64EncodedString()
                            ]
                        ]
                    ]
                ]
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw GeminiTranscriptionError.invalidResponse("Failed to serialize request body: \(error)")
        }
        
        do {
            // Consent is mutable. A session-start snapshot cannot authorize a retry that begins
            // after the user has revoked cloud-audio access, so check at every actual upload
            // boundary. The second cancellation check closes the interval spent in the predicate.
            try Task.checkCancellation()
            let isUploadAuthorized = uploadAuthorized()
            try Task.checkCancellation()
            guard isUploadAuthorized else {
                throw GeminiTranscriptionError.uploadNotAuthorized
            }

            let (bytes, response) = try await session.bytes(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw GeminiTranscriptionError.networkError("Invalid response type")
            }

            do {
                try checkStatusCode(httpResponse.statusCode)
            } catch {
                // The response body may still be streaming. Refuse it before a typed status error
                // retries or returns so a rejected request cannot remain live in the background.
                bytes.task.cancel()
                throw error
            }

            guard maximumResponseBytes > 0 else {
                bytes.task.cancel()
                throw GeminiTranscriptionError.responseTooLarge
            }
            if response.expectedContentLength > Int64(maximumResponseBytes) {
                bytes.task.cancel()
                throw GeminiTranscriptionError.responseTooLarge
            }

            // Bound raw bytes before line decoding: `AsyncLineSequence` may otherwise assemble one
            // arbitrarily long line internally before the caller has a chance to reject it.
            var responseData = Data()
            responseData.reserveCapacity(min(maximumResponseBytes, 16 * 1024))
            for try await byte in bytes {
                if Task.isCancelled {
                    bytes.task.cancel()
                    throw CancellationError()
                }
                guard responseData.count < maximumResponseBytes else {
                    bytes.task.cancel()
                    throw GeminiTranscriptionError.responseTooLarge
                }
                responseData.append(byte)
            }
            try Task.checkCancellation()
            guard let responseText = String(data: responseData, encoding: .utf8) else {
                throw GeminiTranscriptionError.invalidResponse("SSE response was not valid UTF-8")
            }

            var accumulatedText = ""
            for lineSlice in responseText.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(lineSlice)
                guard line.hasPrefix("data: ") else { continue }
                let jsonString = String(line.dropFirst(6))
                guard let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                
                if let candidates = json["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first {
                    
                    if let finishReason = firstCandidate["finishReason"] as? String, finishReason == "SAFETY" {
                        throw GeminiTranscriptionError.safetyBlocked
                    }
                    
                    if let content = firstCandidate["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]] {
                        for part in parts {
                            if let text = part["text"] as? String {
                                accumulatedText += text
                            }
                        }
                    }
                }
            }
            
            let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw GeminiTranscriptionError.emptyTranscript
            }
            
            return GeminiTranscriptionResult(text: trimmed, rawText: accumulatedText)
            
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GeminiTranscriptionError {
            throw error
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled {
                throw CancellationError()
            }
            if !isRetry {
                DevTypeLog.app.info("Transient URLError, retrying: \(error.localizedDescription)")
                return try await transcribeWithRetry(
                    audioData: audioData,
                    mimeType: mimeType,
                    audioDurationSeconds: audioDurationSeconds,
                    steeringPrompt: steeringPrompt,
                    apiKey: apiKey,
                    uploadAuthorized: uploadAuthorized,
                    isRetry: true
                )
            }
            if error.code == .timedOut {
                throw GeminiTranscriptionError.timeout
            }
            throw GeminiTranscriptionError.networkError(error.localizedDescription)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            if !isRetry {
                DevTypeLog.app.info("Transient error, retrying: \(error.localizedDescription)")
                return try await transcribeWithRetry(
                    audioData: audioData,
                    mimeType: mimeType,
                    audioDurationSeconds: audioDurationSeconds,
                    steeringPrompt: steeringPrompt,
                    apiKey: apiKey,
                    uploadAuthorized: uploadAuthorized,
                    isRetry: true
                )
            }
            throw GeminiTranscriptionError.networkError(error.localizedDescription)
        }
    }
    
    private func checkStatusCode(_ statusCode: Int) throws {
        switch statusCode {
        case 200...299:
            return
        case 400, 401:
            throw GeminiTranscriptionError.invalidAPIKey
        case 403:
            throw GeminiTranscriptionError.modelAccessDenied
        case 429:
            throw GeminiTranscriptionError.rateLimited
        case 402, 404:
            throw GeminiTranscriptionError.quotaExhausted
        case 500...599:
            throw URLError(.badServerResponse) // Triggers transient retry
        default:
            throw GeminiTranscriptionError.networkError("HTTP status \(statusCode)")
        }
    }
    
    /// Validates the given API key against Google's Generative Language API.
    ///
    /// Performs format sanity verification and probes the live endpoint with `x-goog-api-key`.
    public func validateAPIKeyDetailed(_ key: String) async -> APIKeyValidationResult {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return .invalidKey(reason: "API key cannot be empty")
        }

        if trimmedKey.contains(" ") || trimmedKey.count < 10 {
            return .invalidKey(reason: "Invalid API key format")
        }

        // Probe the models endpoint with pageSize=1. The response is consumed through the same
        // streaming byte-boundary discipline as transcription; provider error bodies are never
        // rendered in Preferences.
        var request = URLRequest(url: validationURL)
        request.httpMethod = "GET"
        request.addValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 6.0

        do {
            let httpResponse = try await boundedValidationResponse(for: request)

            switch httpResponse.statusCode {
            case 200...299:
                return .valid(modelName: "gemini-3.5-transcribe")

            case 400, 401:
                return .invalidKey(reason: "API key is invalid or unauthorized")

            case 403:
                return .invalidKey(reason: "API key does not have permission")

            case 429:
                return .rateLimited

            case 402, 404:
                return .quotaExhausted

            default:
                return .networkError(reason: "HTTP status \(httpResponse.statusCode)")
            }
        } catch GeminiTranscriptionError.responseTooLarge {
            return .networkError(reason: "Validation response exceeded the safe size limit")
        } catch is CancellationError {
            return .networkError(reason: "Validation was cancelled")
        } catch let error as URLError {
            if error.code == .timedOut {
                return .networkError(reason: "Request timed out")
            } else if error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                return .networkError(reason: "No internet connection")
            }
            return .networkError(reason: "Network request failed (code \(error.code.rawValue))")
        } catch {
            return .networkError(reason: "Validation request failed")
        }
    }

    private func boundedValidationResponse(for request: URLRequest) async throws -> HTTPURLResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }

        // Status alone is sufficient for every validation verdict. Refuse rather than buffer a
        // provider-controlled error document, which can contain arbitrary text and has no value
        // to the user-facing decision.
        guard (200...299).contains(httpResponse.statusCode) else {
            bytes.task.cancel()
            return httpResponse
        }

        guard maximumValidationResponseBytes > 0 else {
            bytes.task.cancel()
            throw GeminiTranscriptionError.responseTooLarge
        }
        if response.expectedContentLength > Int64(maximumValidationResponseBytes) {
            bytes.task.cancel()
            throw GeminiTranscriptionError.responseTooLarge
        }

        var byteCount = 0
        for try await _ in bytes {
            if Task.isCancelled {
                bytes.task.cancel()
                throw CancellationError()
            }
            guard byteCount < maximumValidationResponseBytes else {
                bytes.task.cancel()
                throw GeminiTranscriptionError.responseTooLarge
            }
            byteCount += 1
        }
        try Task.checkCancellation()
        return httpResponse
    }
}
