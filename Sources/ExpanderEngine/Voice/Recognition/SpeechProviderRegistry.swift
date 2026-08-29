import Foundation

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
    /// it probes ready. Probing matters: an unimplemented adapter or a local server that is
    /// not running must fall through to the on-device path rather than fail the dictation.
    public func resolveActiveRecognizer(preferredID: String?, privacyRoute: PrivacyRoute) async -> SpeechRecognizer {
        if let id = preferredID,
           let preferred = providers[id],
           privacyRoute.permits(preferred.descriptor.privacyRoute),
           await preferred.probe().isReady {
            return preferred
        }

        // Floor: on-device Apple Speech, which needs no configuration and no network.
        if let legacy = providers["apple.speech.legacy"] {
            return legacy
        }
        return LegacyAppleSpeechAdapter()
    }
}
