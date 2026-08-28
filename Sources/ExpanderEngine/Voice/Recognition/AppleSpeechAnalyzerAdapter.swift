import Foundation
import Speech

public final class AppleSpeechAnalyzerAdapter: SpeechRecognizer, @unchecked Sendable {
    public let descriptor: SpeechProviderDescriptor

    public init() {
        self.descriptor = SpeechProviderDescriptor(
            id: "apple.speech.analyzer",
            displayName: "Apple SpeechAnalyzer",
            modelVersion: "system-v27",
            privacyRoute: .onDeviceOnly,
            supportsStreaming: true,
            supportsContextualStrings: true
        )
    }

    public func probe() async -> ProviderReadiness {
        if #available(macOS 26.0, *) {
            // Modern SpeechAnalyzer path
            let authStatus = SFSpeechRecognizer.authorizationStatus()
            if authStatus == .authorized {
                let evidence = ProviderEvidence(
                    providerID: descriptor.id,
                    modelVersion: descriptor.modelVersion,
                    probeTimestamp: Date(),
                    capabilities: ["speechAnalyzer", "onDevice", "volatileRevisions"]
                )
                return .ready(evidence)
            } else if authStatus == .notDetermined {
                let granted = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status == .authorized)
                    }
                }
                if granted {
                    return await probe()
                } else {
                    return .requiresPermission(.speechRecognition)
                }
            } else {
                return .requiresPermission(.speechRecognition)
            }
        } else {
            return .incompatible(reason: .modelNotFound)
        }
    }

    public func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error> {
        // Fall back to legacy SFSpeechRecognizer mechanism under the hood if running on pre-v26 OS
        let legacy = LegacyAppleSpeechAdapter(locale: request.locale)
        return legacy.transcribe(request)
    }

    public func cancel(sessionID: VoiceSessionID) async {}
}
