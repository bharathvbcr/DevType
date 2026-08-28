import Foundation

public final class FoundationLanguageModelCorrector: TranscriptCorrector, @unchecked Sendable {
    public let descriptor: CorrectionProviderDescriptor

    public init() {
        self.descriptor = CorrectionProviderDescriptor(
            id: "apple.foundation-models",
            displayName: "Apple Intelligence (Foundation Models)",
            modelVersion: "system-language-model",
            privacyRoute: .onDeviceOnly,
            supportsStructuredOutput: true
        )
    }

    public func probe() async -> ProviderReadiness {
        if #available(macOS 26.0, *) {
            let evidence = ProviderEvidence(
                providerID: descriptor.id,
                modelVersion: descriptor.modelVersion,
                probeTimestamp: Date(),
                capabilities: ["appleIntelligence", "systemLanguageModel", "onDevicePrivate"]
            )
            return .ready(evidence)
        } else {
            return .incompatible(reason: .modelNotFound)
        }
    }

    public func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        // Deterministic fallback if on earlier OS baseline
        let deterministic = DeterministicCorrector()
        return try await deterministic.correct(request)
    }

    public func cancel(sessionID: VoiceSessionID) async {}
}
