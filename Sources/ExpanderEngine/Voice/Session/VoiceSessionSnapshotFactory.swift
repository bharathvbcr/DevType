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
        public static let proofreadCorrector = "apple.transform.proofread"
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
    ///   - engine: provider choice captured before any asynchronous permission or consent prompt.
    ///     Callers that do not have an asynchronous preflight may use the current effective engine.
    public static func make(
        bundleIdentifier: String?,
        processIdentifier: Int32,
        generation: SessionGeneration,
        engine: TranscriptionEngine = VoicePreferences.effectiveEngine,
        locale: Locale = Locale.current
    ) -> VoiceSessionSnapshot {
        let route = privacyRoute(for: engine)
        let tone = VoicePreferences.effectiveToneCategory(forBundleID: bundleIdentifier)
        let correctionPlan = correctionProviderPlan(for: engine, route: route)

        return VoiceSessionSnapshot(
            generation: generation,
            localeIdentifier: locale.identifier,
            speechProvider: speechProvider(for: engine, route: route),
            correctionProvider: correctionPlan.preferred,
            correctionFallbackProviderIDs: correctionPlan.fallbackIDs,
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
        let supportsSpeechAnalyzer: Bool
        if #available(macOS 26.0, *) {
            supportsSpeechAnalyzer = true
        } else {
            supportsSpeechAnalyzer = false
        }
        return speechProvider(
            for: engine,
            route: route,
            supportsSpeechAnalyzer: supportsSpeechAnalyzer
        )
    }

    /// Injectable platform decision used by the snapshot contract tests. Runtime readiness is
    /// still resolved later by `SpeechProviderRegistry`; this chooses only the preferred provider
    /// that the immutable session manifest records before asynchronous preflight.
    static func speechProvider(
        for engine: TranscriptionEngine,
        route: PrivacyRoute,
        supportsSpeechAnalyzer: Bool
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
            let usesAnalyzer = supportsSpeechAnalyzer
            return SpeechProviderDescriptor(
                id: usesAnalyzer ? ProviderID.appleSpeechAnalyzer : ProviderID.appleSpeechLegacy,
                displayName: engine.displayName,
                modelVersion: usesAnalyzer ? "system" : "sfspeech",
                privacyRoute: .onDeviceOnly,
                supportsStreaming: !usesAnalyzer,
                supportsContextualStrings: true
            )
        }
    }

    private struct CorrectionProviderPlan {
        let preferred: CorrectionProviderDescriptor
        let fallbackIDs: [String]
    }

    private static func correctionProviderPlan(
        for engine: TranscriptionEngine,
        route: PrivacyRoute
    ) -> CorrectionProviderPlan {
        // Proofread-before-insert replaces the correction stage for every engine, including
        // Gemini: the user asked for their words to be proofread, and which recognizer
        // produced them does not change that. The registry probes it and falls back on its
        // own if Apple Intelligence is unavailable.
        if VoicePreferences.isProofreadBeforeInsertEnabled, #available(macOS 26.0, *) {
            return CorrectionProviderPlan(
                preferred: descriptor(
                    id: ProviderID.proofreadCorrector,
                    name: "Apple Intelligence (proofread)",
                    route: .onDeviceOnly
                ),
                fallbackIDs: []
            )
        }

        switch engine {
        case .gemini:
            // Gemini punctuates and formats during transcription; a second correction
            // pass would only add latency and a chance to make it worse.
            return CorrectionProviderPlan(
                preferred: descriptor(id: ProviderID.deterministicCorrector, name: "Built-in", route: .onDeviceOnly),
                fallbackIDs: []
            )

        case .localLLM:
            let preferAppleFoundationModels: Bool
            if #available(macOS 26.0, *) {
                preferAppleFoundationModels = true
            } else {
                preferAppleFoundationModels = false
            }
            let providerIDs = localCorrectionProviderIDs(
                for: VoicePreferences.localLLMEndpoint,
                preferAppleFoundationModels: preferAppleFoundationModels
            )
            let preferredID = providerIDs[0]
            return CorrectionProviderPlan(
                preferred: descriptor(
                    id: preferredID,
                    name: correctionProviderName(for: preferredID),
                    route: preferredID == ProviderID.appleFoundationModels ? .onDeviceOnly : .localNetworkOnly
                ),
                fallbackIDs: Array(providerIDs.dropFirst())
            )

        case .whisperLocal, .appleSpeech:
            return CorrectionProviderPlan(
                preferred: descriptor(id: ProviderID.deterministicCorrector, name: "Built-in", route: .onDeviceOnly),
                fallbackIDs: []
            )
        }
    }

    /// Selects the wire contract from the endpoint's API path. Ollama serves both contracts on
    /// port 11434, so port-based routing can pair an OpenAI path with an incompatible native body.
    static func localCorrectionProviderID(for endpoint: URL) -> String {
        guard let route = try? LocalCorrectionEndpointRoute.resolve(endpoint) else {
            // Preferences accepts custom OpenAI-compatible paths; retain that general-purpose
            // provider as the safe default and let its readiness probe report a bad route.
            return ProviderID.openAICompatibleCorrector
        }
        return route.isOllamaNative ? ProviderID.ollamaCorrector : ProviderID.openAICompatibleCorrector
    }

    /// Ordered model-backed providers for Local AI. The deterministic corrector is the registry's
    /// universal final floor and is intentionally not duplicated in every snapshot.
    public static func localCorrectionProviderIDs(
        for endpoint: URL,
        preferAppleFoundationModels: Bool
    ) -> [String] {
        let loopbackID = localCorrectionProviderID(for: endpoint)
        return preferAppleFoundationModels
            ? [ProviderID.appleFoundationModels, loopbackID]
            : [loopbackID]
    }

    private static func correctionProviderName(for providerID: String) -> String {
        switch providerID {
        case ProviderID.appleFoundationModels: return "Apple Intelligence"
        case ProviderID.ollamaCorrector: return "Ollama"
        default: return "Local endpoint"
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
