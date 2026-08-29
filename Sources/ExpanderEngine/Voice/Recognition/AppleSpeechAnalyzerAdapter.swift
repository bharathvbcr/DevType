import Foundation
import Speech

/// Placeholder for the macOS 26 `SpeechAnalyzer` / `SpeechTranscriber` path.
///
/// **Not implemented.** `probe()` reports `.incompatible` unconditionally, so the registry
/// never selects it and the ladder falls through to `LegacyAppleSpeechAdapter`.
///
/// It previously reported `.ready` with capabilities `["speechAnalyzer", "volatileRevisions"]`
/// while `transcribe` constructed a legacy adapter and returned that. A probe that claims a
/// capability it does not exercise is indistinguishable from one that ran and passed, which
/// is how "supported" comes to mean "unexamined" — so it now refuses until the real
/// implementation lands.
///
/// Implementing it means: build a `SpeechTranscriber` with `reportingOptions: [.volatileResults]`,
/// feed one `AsyncStream<AnalyzerInput>` for the whole session, map `result.isFinal` onto
/// `Finality.final` (which is already the shape `LiveSpeechStream` emits), and install models
/// through `AssetInventory`. The advantage over the legacy path is that volatile-versus-final
/// is reported by the framework instead of inferred from endpoint restarts.
public final class AppleSpeechAnalyzerAdapter: SpeechRecognizer, @unchecked Sendable {
    public let descriptor: SpeechProviderDescriptor

    public init() {
        self.descriptor = SpeechProviderDescriptor(
            id: "apple.speech.analyzer",
            displayName: "Apple SpeechAnalyzer (not implemented)",
            modelVersion: "unimplemented",
            privacyRoute: .onDeviceOnly,
            supportsStreaming: false,
            supportsContextualStrings: false
        )
    }

    public func probe() async -> ProviderReadiness {
        .incompatible(reason: .modelNotFound)
    }

    public func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: VoiceFailure(
                stage: .recognition,
                code: .modelNotFound,
                providerID: descriptor.id,
                userAction: .retryWithOtherProvider,
                redactedDetail: "SpeechAnalyzer adapter is not implemented; select another provider"
            ))
        }
    }

    public func cancel(sessionID: VoiceSessionID) async {}
}
