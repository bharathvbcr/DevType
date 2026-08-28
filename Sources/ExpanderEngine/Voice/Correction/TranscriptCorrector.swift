import Foundation

public protocol TranscriptCorrector: Sendable {
    var descriptor: CorrectionProviderDescriptor { get }
    func probe() async -> ProviderReadiness
    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate
    func cancel(sessionID: VoiceSessionID) async
}
