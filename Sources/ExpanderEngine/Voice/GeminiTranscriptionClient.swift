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

/// A raw URLSession-based Gemini API client for the `gemini-3.5-transcribe` model.
public actor GeminiTranscriptionClient {
    public static let shared = GeminiTranscriptionClient()
    private let session: URLSession
    private let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe:streamGenerateContent?alt=sse")!
    
    /// Maximum allowed audio payload size for inline base64 data (25MB).
    public static let maxPayloadSizeBytes = 25 * 1024 * 1024
    
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }
    
    /// Transcribes audio data using the Gemini model.
    /// - Parameters:
    ///   - audioData: The audio data to transcribe
    ///   - mimeType: The mime type of the audio data (e.g. "audio/flac")
    ///   - audioDurationSeconds: The duration of the audio in seconds, for timeout calculation
    ///   - steeringPrompt: The prompt to steer the transcription
    ///   - apiKey: The Gemini API key
    /// - Returns: A GeminiTranscriptionResult
    public func transcribe(
        audioData: Data,
        mimeType: String,
        audioDurationSeconds: TimeInterval,
        steeringPrompt: String,
        apiKey: String
    ) async throws -> GeminiTranscriptionResult {
        return try await transcribeWithRetry(
            audioData: audioData,
            mimeType: mimeType,
            audioDurationSeconds: audioDurationSeconds,
            steeringPrompt: steeringPrompt,
            apiKey: apiKey,
            isRetry: false
        )
    }
    
    private func transcribeWithRetry(
        audioData: Data,
        mimeType: String,
        audioDurationSeconds: TimeInterval,
        steeringPrompt: String,
        apiKey: String,
        isRetry: Bool
    ) async throws -> GeminiTranscriptionResult {
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
            let (bytes, response) = try await session.bytes(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GeminiTranscriptionError.networkError("Invalid response type")
            }
            
            try checkStatusCode(httpResponse.statusCode)
            
            var accumulatedText = ""
            
            for try await line in bytes.lines {
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
            
        } catch let error as GeminiTranscriptionError {
            throw error
        } catch let error as URLError {
            if !isRetry {
                DevTypeLog.app.info("Transient URLError, retrying: \(error.localizedDescription)")
                return try await transcribeWithRetry(
                    audioData: audioData,
                    mimeType: mimeType,
                    audioDurationSeconds: audioDurationSeconds,
                    steeringPrompt: steeringPrompt,
                    apiKey: apiKey,
                    isRetry: true
                )
            }
            if error.code == .timedOut {
                throw GeminiTranscriptionError.timeout
            }
            throw GeminiTranscriptionError.networkError(error.localizedDescription)
        } catch {
            if !isRetry {
                DevTypeLog.app.info("Transient error, retrying: \(error.localizedDescription)")
                return try await transcribeWithRetry(
                    audioData: audioData,
                    mimeType: mimeType,
                    audioDurationSeconds: audioDurationSeconds,
                    steeringPrompt: steeringPrompt,
                    apiKey: apiKey,
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
    
    /// Validates the given API key securely using the x-goog-api-key header (never via URL query params)
    public func validateAPIKey(_ key: String) async -> Bool {
        guard !key.isEmpty else { return false }
        
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 8.0
        
        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return (200...299).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            return false
        }
    }
}
