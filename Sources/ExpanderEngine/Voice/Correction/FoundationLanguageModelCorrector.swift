import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Transcript cleanup on Apple's on-device `SystemLanguageModel` (macOS 26+).
///
/// Fully local: the transcript never leaves the machine, which is why this corrector is
/// permitted under the strictest privacy route. Bounded by the request deadline and
/// falling back to the deterministic corrector whenever the model is unavailable,
/// declines, or runs long — a correction is an enhancement, never a prerequisite for
/// delivering the user's words.
public final class FoundationLanguageModelCorrector: TranscriptCorrector, @unchecked Sendable {

    /// The on-device model's context window, in tokens, shared between the instructions,
    /// the prompt and the response.
    ///
    /// Dictation runs straight into this: a few minutes of continuous speech is thousands
    /// of tokens, and the model must also fit its answer — roughly as long as the input —
    /// in the same window. Sending an over-long transcript throws
    /// `.exceededContextWindowSize` and the session cannot answer at all, so a long
    /// dictation would silently lose cleanup entirely.
    ///
    /// Newer SDKs expose `SystemLanguageModel.contextSize` and `tokenCount(for:)` for an
    /// exact measurement. This uses a deliberately conservative character estimate instead
    /// so the budget holds on every OS version the app supports; the cost of
    /// over-estimating is one extra chunk, and the cost of under-estimating is a failed
    /// correction.
    public static let contextWindowTokens = 4096

    /// Characters per token, rounded down hard. English averages nearer four; three keeps
    /// the estimate above the true count for punctuation-dense dictation.
    private static let charactersPerToken = 3

    /// Headroom for the chat template and any tokeniser disagreement.
    private static let safetyMarginTokens = 256

    public let descriptor: CorrectionProviderDescriptor
    private let fallback = DeterministicCorrector()

    public init() {
        self.descriptor = CorrectionProviderDescriptor(
            id: "apple.foundation-models",
            displayName: "Apple Intelligence (On-Device)",
            modelVersion: "system-language-model",
            privacyRoute: .onDeviceOnly,
            supportsStructuredOutput: true
        )
    }

    public func probe() async -> ProviderReadiness {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // Availability is a runtime property — Apple Intelligence can be switched off,
            // still downloading, or unsupported on this hardware. Report what is actually
            // true now, not what the OS version implies.
            let model = SystemLanguageModel(useCase: .general)
            switch model.availability {
            case .available:
                return .ready(ProviderEvidence(
                    providerID: descriptor.id,
                    modelVersion: descriptor.modelVersion,
                    probeTimestamp: Date(),
                    capabilities: ["appleIntelligence", "systemLanguageModel", "onDevicePrivate"]
                ))
            case .unavailable(let reason):
                return .temporarilyUnavailable(
                    retryAfterSeconds: nil,
                    reason: Self.failureCode(for: String(describing: reason))
                )
            @unknown default:
                return .incompatible(reason: .modelNotFound)
            }
        }
        #endif
        return .incompatible(reason: .modelNotFound)
    }

    public func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let text = await correctWithinContextWindow(request) {
                return CorrectionCandidate(
                    text: text,
                    providerID: descriptor.id,
                    modelVersion: descriptor.modelVersion,
                    latencyMs: 0,
                    promptVersion: CorrectionPromptBuilder.version,
                    refusalDetected: false
                )
            }
        }
        #endif
        // Model unavailable, declined, or over deadline — deterministic rules still run so
        // the user gets punctuation and capitalisation rather than a raw transcript.
        return try await fallback.correct(request)
    }

    public func cancel(sessionID: VoiceSessionID) async {}

    // MARK: - Context window

    /// Conservative token estimate for a piece of text.
    static func estimatedTokens(_ text: String) -> Int {
        max(1, (text.count + charactersPerToken - 1) / charactersPerToken)
    }

    /// How many tokens of transcript one request may carry.
    ///
    /// The response is budgeted at the same size as the input, because a cleanup answer is
    /// about as long as what it cleans. Halving what remains after the instructions is what
    /// keeps a request from being accepted and then truncated mid-answer.
    static func inputTokenBudget(instructions: String) -> Int {
        let available = contextWindowTokens
            - estimatedTokens(instructions)
            - safetyMarginTokens
        return max(64, available / 2)
    }

    /// Splits a transcript into pieces that each fit the budget, preferring sentence
    /// boundaries so a chunk is never cut mid-clause — the model needs a whole sentence to
    /// punctuate it correctly.
    static func chunk(_ text: String, budgetTokens: Int) -> [String] {
        guard estimatedTokens(text) > budgetTokens else { return [text] }

        let budgetCharacters = budgetTokens * charactersPerToken
        var chunks: [String] = []
        var current = ""

        for sentence in sentences(in: text) {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= budgetCharacters {
                current += " " + sentence
            } else {
                chunks.append(current)
                current = sentence
            }

            // A single sentence longer than the budget (dictation without punctuation is
            // exactly this) is split on word boundaries rather than dropped.
            while current.count > budgetCharacters {
                let head = String(current.prefix(budgetCharacters))
                let cut = head.lastIndex(of: " ") ?? head.endIndex
                let piece = String(head[head.startIndex..<cut]).trimmingCharacters(in: .whitespaces)
                if piece.isEmpty { break }
                chunks.append(piece)
                current = String(current[current.index(cut, offsetBy: cut == head.endIndex ? 0 : 1)...])
            }
        }

        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [text] : chunks
    }

    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result.isEmpty ? [text] : result
    }

    // MARK: - Model

    #if canImport(FoundationModels)

    /// Corrects the transcript, splitting it across sessions when it will not fit the
    /// context window. Each chunk gets a fresh session so context does not accumulate.
    @available(macOS 26.0, *)
    private func correctWithinContextWindow(_ request: CorrectionRequest) async -> String? {
        let instructions = CorrectionPromptBuilder.systemPrompt(
            policy: request.policy,
            protectedSpans: request.protectedSpans
        )
        let budget = Self.inputTokenBudget(instructions: instructions)
        let chunks = Self.chunk(request.rawTranscript, budgetTokens: budget)

        if chunks.count > 1 {
            DevTypeLog.app.info(
                "[Voice] transcript exceeds the on-device context window; correcting in \(chunks.count) chunks"
            )
        }

        var corrected: [String] = []
        for chunk in chunks {
            guard request.deadline.timeIntervalSinceNow > 0.2 else {
                // Out of time. Anything not yet corrected is returned as spoken rather than
                // dropped, so a slow model costs polish and never words.
                corrected.append(contentsOf: chunks.dropFirst(corrected.count))
                break
            }
            guard let piece = await respond(instructions: instructions, transcript: chunk, deadline: request.deadline) else {
                corrected.append(chunk)   // this chunk stays as spoken
                continue
            }
            corrected.append(piece)
        }

        let joined = corrected.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    @available(macOS 26.0, *)
    private func respond(to request: CorrectionRequest) async -> String? {
        await respond(
            instructions: CorrectionPromptBuilder.systemPrompt(
                policy: request.policy,
                protectedSpans: request.protectedSpans
            ),
            transcript: request.rawTranscript,
            deadline: request.deadline
        )
    }

    @available(macOS 26.0, *)
    private func respond(instructions: String, transcript: String, deadline: Date) async -> String? {
        let budget = deadline.timeIntervalSinceNow
        guard budget > 0.2 else { return nil }

        let prompt = CorrectionPromptBuilder.userPrompt(rawTranscript: transcript)

        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    let model = SystemLanguageModel(
                        useCase: .general,
                        guardrails: .permissiveContentTransformations
                    )
                    guard case .available = model.availability else { return nil }
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    let response = try await session.respond(to: Prompt(prompt))
                    return response.content
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                    return nil   // deadline reached — treat as no answer, never as an error
                }

                let first = try await group.next() ?? nil
                group.cancelAll()
                guard let first else { return nil }

                let cleaned = CorrectionOutputSanitizer.sanitize(first)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned
            }
        } catch {
            DevTypeLog.app.info("[Voice] Apple Intelligence correction unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private static func failureCode(for reason: String) -> FailureCode {
        let lower = reason.lowercased()
        if lower.contains("download") || lower.contains("notready") { return .modelNotFound }
        if lower.contains("devicenoteligible") || lower.contains("eligible") { return .modelLoadFailed }
        return .modelNotFound
    }
    #endif
}
