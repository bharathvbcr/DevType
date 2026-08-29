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
            if let text = await respond(to: request) {
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

    // MARK: - Model

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func respond(to request: CorrectionRequest) async -> String? {
        let budget = request.deadline.timeIntervalSinceNow
        guard budget > 0.2 else { return nil }

        let instructions = CorrectionPromptBuilder.systemPrompt(
            policy: request.policy,
            protectedSpans: request.protectedSpans
        )
        let prompt = CorrectionPromptBuilder.userPrompt(rawTranscript: request.rawTranscript)

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
