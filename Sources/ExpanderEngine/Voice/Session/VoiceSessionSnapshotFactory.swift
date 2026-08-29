import Foundation

/// Builds an immutable `VoiceSessionSnapshot` from the user's current preferences and the
/// target application, at the moment dictation starts.
///
/// Everything the session needs is captured up front: changing a preference mid-dictation
/// cannot retarget a running session, and the manifest written to disk records exactly
/// which providers and policy produced a transcript.
public enum VoiceSessionSnapshotFactory {

    /// Provider descriptor ids, matching `SpeechProviderRegistry` and the correctors.
    public enum ProviderID {
        public static let appleSpeechAnalyzer = "apple.speech.analyzer"
        public static let appleSpeechLegacy = "apple.speech.legacy"
        public static let gemini = "gemini.speech"
        public static let whisperServer = "whispercpp.server"

        public static let deterministicCorrector = "deterministic.local"
        public static let appleFoundationModels = "apple.foundation-models"
        public static let ollamaCorrector = "ollama.corrector"
        public static let openAICompatibleCorrector = "openaicompatible.corrector"
    }

    /// Builds the snapshot for a new dictation.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: target app bundle id, captured before the HUD takes focus.
    ///   - processIdentifier: target app pid, used as the delivery lease.
    ///   - generation: monotonic session generation, so late callbacks from a previous
    ///     dictation are rejected rather than applied to this one.
    public static func make(
        bundleIdentifier: String?,
        processIdentifier: Int32,
        generation: SessionGeneration,
        locale: Locale = Locale.current
    ) -> VoiceSessionSnapshot {
        let engine = VoicePreferences.effectiveEngine
        let route = privacyRoute(for: engine)
        let tone = VoicePreferences.effectiveToneCategory(forBundleID: bundleIdentifier)

        return VoiceSessionSnapshot(
            generation: generation,
            localeIdentifier: locale.identifier,
            speechProvider: speechProvider(for: engine, route: route),
            correctionProvider: correctionProvider(for: engine, route: route),
            privacyRoute: route,
            vocabularySnapshot: VocabularySnapshot(
                terms: Array(VoicePreferences.customDictionary.values).sorted()
            ),
            correctionPolicy: correctionPolicy(tone: tone),
            targetLease: TargetLease(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier
            ),
            timeoutSeconds: max(5.0, VoicePreferences.localLLMTimeout + 20.0)
        )
    }

    // MARK: - Privacy

    /// The route a given engine implies. This is what the registry uses to refuse a
    /// provider that would send audio somewhere the user did not agree to.
    public static func privacyRoute(for engine: TranscriptionEngine) -> PrivacyRoute {
        switch engine {
        case .gemini:
            return .cloudPermitted
        case .localLLM, .whisperLocal:
            // Recognition and/or correction may reach a loopback endpoint.
            return .localNetworkOnly
        case .appleSpeech:
            return .onDeviceOnly
        }
    }

    // MARK: - Providers

    private static func speechProvider(
        for engine: TranscriptionEngine,
        route: PrivacyRoute
    ) -> SpeechProviderDescriptor {
        switch engine {
        case .gemini:
            return SpeechProviderDescriptor(
                id: ProviderID.gemini,
                displayName: engine.displayName,
                modelVersion: "gemini-3.5-transcribe",
                privacyRoute: .cloudPermitted,
                supportsStreaming: false,
                supportsContextualStrings: true
            )
        case .whisperLocal:
            return SpeechProviderDescriptor(
                id: ProviderID.whisperServer,
                displayName: engine.displayName,
                modelVersion: "whisper-local",
                privacyRoute: .localNetworkOnly,
                supportsStreaming: false,
                supportsContextualStrings: false
            )
        case .localLLM, .appleSpeech:
            return SpeechProviderDescriptor(
                id: ProviderID.appleSpeechLegacy,
                displayName: engine.displayName,
                modelVersion: "sfspeech",
                privacyRoute: .onDeviceOnly,
                supportsStreaming: true,
                supportsContextualStrings: true
            )
        }
    }

    private static func correctionProvider(
        for engine: TranscriptionEngine,
        route: PrivacyRoute
    ) -> CorrectionProviderDescriptor {
        switch engine {
        case .gemini:
            // Gemini punctuates and formats during transcription; a second correction
            // pass would only add latency and a chance to make it worse.
            return descriptor(id: ProviderID.deterministicCorrector, name: "Built-in", route: .onDeviceOnly)

        case .localLLM:
            // Apple Intelligence is the better default when it is actually usable: no
            // server to run, nothing on the network. The registry probes it and falls back
            // on its own, so an optimistic choice here is safe.
            if #available(macOS 26.0, *) {
                return descriptor(
                    id: ProviderID.appleFoundationModels,
                    name: "Apple Intelligence",
                    route: .onDeviceOnly
                )
            }
            let endpoint = VoicePreferences.localLLMEndpoint.absoluteString
            if endpoint.contains("11434") {
                return descriptor(id: ProviderID.ollamaCorrector, name: "Ollama", route: .localNetworkOnly)
            }
            return descriptor(
                id: ProviderID.openAICompatibleCorrector,
                name: "Local endpoint",
                route: .localNetworkOnly
            )

        case .whisperLocal, .appleSpeech:
            return descriptor(id: ProviderID.deterministicCorrector, name: "Built-in", route: .onDeviceOnly)
        }
    }

    private static func descriptor(
        id: String,
        name: String,
        route: PrivacyRoute
    ) -> CorrectionProviderDescriptor {
        CorrectionProviderDescriptor(
            id: id,
            displayName: name,
            modelVersion: "1",
            privacyRoute: route,
            supportsStructuredOutput: false
        )
    }

    // MARK: - Policy

    /// Translates the user's tone and formatting preferences into the correction policy
    /// the validator enforces. Verbatim mode maps to `.exact`, which disables every
    /// rewriting permission — the transcript is delivered as recognized.
    public static func correctionPolicy(tone: ToneCategory) -> CorrectionPolicy {
        if VoicePreferences.isVerbatimModeEnabled {
            return CorrectionPolicy(
                tone: .exact,
                allowDisfluencyRemoval: false,
                allowFalseStartRemoval: false,
                allowSpokenPunctuation: false,
                allowNumberFormatting: false,
                preserveProtectedSpans: true
            )
        }

        return CorrectionPolicy(
            tone: correctionTone(for: tone),
            allowDisfluencyRemoval: VoicePreferences.isRemoveDisfluenciesEnabled,
            allowFalseStartRemoval: VoicePreferences.isRemoveDisfluenciesEnabled,
            allowSpokenPunctuation: VoicePreferences.isAutoPunctuateEnabled,
            allowNumberFormatting: VoicePreferences.isAutoPunctuateEnabled,
            preserveProtectedSpans: true
        )
    }

    public static func correctionTone(for tone: ToneCategory) -> CorrectionTone {
        switch tone {
        case .email: return .professional
        case .workChat: return .standard
        case .personalChat: return .casual
        case .code: return .code
        case .neutral: return .standard
        }
    }
}
