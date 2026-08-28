import Foundation

public actor SpeechProviderRegistry {
    public static let shared = SpeechProviderRegistry()

    private var providers: [String: SpeechRecognizer] = [:]

    private init() {
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
        for (_, provider) in providers {
            // Check privacy route alignment
            if privacyRoute == .onDeviceOnly && provider.descriptor.privacyRoute != .onDeviceOnly {
                continue
            }
            if privacyRoute == .localNetworkOnly && provider.descriptor.privacyRoute == .cloudPermitted {
                continue
            }
            let readiness = await provider.probe()
            results.append((provider.descriptor, readiness))
        }
        return results
    }

    public func resolveActiveRecognizer(preferredID: String?, privacyRoute: PrivacyRoute) async -> SpeechRecognizer {
        if let id = preferredID, let preferred = providers[id] {
            if privacyRoute == .onDeviceOnly && preferred.descriptor.privacyRoute == .onDeviceOnly {
                return preferred
            }
            if privacyRoute == .localNetworkOnly && preferred.descriptor.privacyRoute != .cloudPermitted {
                return preferred
            }
            if privacyRoute == .cloudPermitted {
                return preferred
            }
        }

        // Default to on-device Apple Speech
        if let legacy = providers["apple.speech.legacy"] {
            return legacy
        }
        return LegacyAppleSpeechAdapter()
    }
}
