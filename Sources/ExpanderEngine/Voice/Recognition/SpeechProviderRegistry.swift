import Foundation

/// Exactly one of `recognizer` or `failure` is populated. Resolution is a typed preflight rather
/// than a best-effort provider guess, so an unready preferred service cannot silently route audio
/// through an Apple recognizer that is itself unready or requires a permission the session lacks.
public struct SpeechProviderResolution: Sendable {
    public let recognizer: (any SpeechRecognizer)?
    public let failure: VoiceFailure?

    private init(recognizer: (any SpeechRecognizer)?, failure: VoiceFailure?) {
        self.recognizer = recognizer
        self.failure = failure
    }

    static func ready(_ recognizer: any SpeechRecognizer) -> SpeechProviderResolution {
        SpeechProviderResolution(recognizer: recognizer, failure: nil)
    }

    static func unavailable() -> SpeechProviderResolution {
        SpeechProviderResolution(
            recognizer: nil,
            failure: VoiceFailure(
                stage: .recognition,
                code: .noReadyProvider,
                retryClass: .afterUserAction,
                artifactState: .durable,
                userAction: .retryWithOtherProvider,
                redactedDetail: "No permitted speech provider reported ready"
            )
        )
    }
}

public actor SpeechProviderRegistry {
    public static let shared = SpeechProviderRegistry()

    private var providers: [String: SpeechRecognizer] = [:]

    /// An isolated registry containing exactly `providers` and nothing else.
    ///
    /// Tests need this: the default set probes real system and network services, so a
    /// suite built on it would depend on the machine it runs on — and probing Apple Speech
    /// on an un-authorized machine used to prompt.
    public init(providers: [SpeechRecognizer]) {
        for provider in providers {
            self.providers[provider.descriptor.id] = provider
        }
    }

    /// The production registry: every shipping provider.
    public init() {
        let legacy = LegacyAppleSpeechAdapter()
        let analyzer = AppleSpeechAnalyzerAdapter()
        let whisper = WhisperCppServerAdapter()
        let gemini = GeminiSpeechAdapter()

        providers[legacy.descriptor.id] = legacy
        providers[analyzer.descriptor.id] = analyzer
        providers[whisper.descriptor.id] = whisper
        providers[gemini.descriptor.id] = gemini
    }

    public func register(_ provider: SpeechRecognizer) {
        providers[provider.descriptor.id] = provider
    }

    public func provider(for id: String) -> SpeechRecognizer? {
        providers[id]
    }

    public func availableProviders(for privacyRoute: PrivacyRoute) async -> [(descriptor: SpeechProviderDescriptor, readiness: ProviderReadiness)] {
        var results: [(SpeechProviderDescriptor, ProviderReadiness)] = []
        for provider in providers.values where privacyRoute.permits(provider.descriptor.privacyRoute) {
            results.append((provider.descriptor, await provider.probe()))
        }
        return results.sorted { $0.0.id < $1.0.id }
    }


    /// Resolves the recognizer for a session.
    ///
    /// A preferred provider is used only when the session's privacy route permits it *and*
    /// it probes ready. Unready local/Apple implementations may use the ready on-device floor,
    /// but an explicitly selected cloud provider fails closed instead of silently changing where
    /// recognition happens after its credential or consent prerequisite disappears.
    public func resolveActiveRecognizer(
        preferredID: String?,
        privacyRoute: PrivacyRoute
    ) async -> SpeechProviderResolution {
        if let id = preferredID,
           let preferred = providers[id],
           privacyRoute.permits(preferred.descriptor.privacyRoute) {
            if await preferred.probe().isReady {
                return .ready(preferred)
            }

            if preferred.descriptor.privacyRoute == .cloudPermitted {
                return .unavailable()
            }
        }

        // The on-device floor is a fallback only after it independently proves ready. Returning it
        // solely because it exists bypasses TCC and per-locale on-device capability checks.
        let legacyID = "apple.speech.legacy"
        if preferredID != legacyID,
           let legacy = providers[legacyID],
           privacyRoute.permits(legacy.descriptor.privacyRoute),
           await legacy.probe().isReady {
            return .ready(legacy)
        }
        return .unavailable()
    }
}
