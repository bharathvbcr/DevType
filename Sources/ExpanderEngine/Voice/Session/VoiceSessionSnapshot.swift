import Foundation

public struct VoiceSessionSnapshot: Codable, Sendable, Equatable {
    public let sessionID: VoiceSessionID
    public let generation: SessionGeneration
    public let createdAt: Date
    public let localeIdentifier: String
    /// The provider requested when the session plan was created. This remains immutable even when
    /// readiness resolution selects a fallback, so recovery can explain both user intent and the
    /// component that actually handled the session.
    public let speechProvider: SpeechProviderDescriptor
    public let resolvedSpeechProvider: SpeechProviderDescriptor?
    public let correctionProvider: CorrectionProviderDescriptor
    public let resolvedCorrectionProvider: CorrectionProviderDescriptor?
    public let correctionFallbackProviderIDs: [String]
    public let privacyRoute: PrivacyRoute
    public let vocabularySnapshot: VocabularySnapshot
    public let correctionPolicy: CorrectionPolicy
    public let targetLease: TargetLease
    public let timeoutSeconds: Double

    public init(
        sessionID: VoiceSessionID = VoiceSessionID(),
        generation: SessionGeneration = SessionGeneration(rawValue: 1),
        createdAt: Date = Date(),
        localeIdentifier: String = Locale.current.identifier,
        speechProvider: SpeechProviderDescriptor,
        resolvedSpeechProvider: SpeechProviderDescriptor? = nil,
        correctionProvider: CorrectionProviderDescriptor,
        resolvedCorrectionProvider: CorrectionProviderDescriptor? = nil,
        correctionFallbackProviderIDs: [String],
        privacyRoute: PrivacyRoute,
        vocabularySnapshot: VocabularySnapshot = VocabularySnapshot(),
        correctionPolicy: CorrectionPolicy = CorrectionPolicy(),
        targetLease: TargetLease,
        timeoutSeconds: Double = 30.0
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.createdAt = createdAt
        self.localeIdentifier = localeIdentifier
        self.speechProvider = speechProvider
        self.resolvedSpeechProvider = resolvedSpeechProvider
        self.correctionProvider = correctionProvider
        self.resolvedCorrectionProvider = resolvedCorrectionProvider
        self.correctionFallbackProviderIDs = correctionFallbackProviderIDs
        self.privacyRoute = privacyRoute
        self.vocabularySnapshot = vocabularySnapshot
        self.correctionPolicy = correctionPolicy
        self.targetLease = targetLease
        self.timeoutSeconds = SessionWatchdog.normalizedSeconds(timeoutSeconds)
    }

    /// Source- and binary-compatible initializer for legacy callers and stored manifests that
    /// predate ordered correction fallback.
    public init(
        sessionID: VoiceSessionID = VoiceSessionID(),
        generation: SessionGeneration = SessionGeneration(rawValue: 1),
        createdAt: Date = Date(),
        localeIdentifier: String = Locale.current.identifier,
        speechProvider: SpeechProviderDescriptor,
        resolvedSpeechProvider: SpeechProviderDescriptor? = nil,
        correctionProvider: CorrectionProviderDescriptor,
        resolvedCorrectionProvider: CorrectionProviderDescriptor? = nil,
        privacyRoute: PrivacyRoute,
        vocabularySnapshot: VocabularySnapshot = VocabularySnapshot(),
        correctionPolicy: CorrectionPolicy = CorrectionPolicy(),
        targetLease: TargetLease,
        timeoutSeconds: Double = 30.0
    ) {
        self.init(
            sessionID: sessionID,
            generation: generation,
            createdAt: createdAt,
            localeIdentifier: localeIdentifier,
            speechProvider: speechProvider,
            resolvedSpeechProvider: resolvedSpeechProvider,
            correctionProvider: correctionProvider,
            resolvedCorrectionProvider: resolvedCorrectionProvider,
            correctionFallbackProviderIDs: [],
            privacyRoute: privacyRoute,
            vocabularySnapshot: vocabularySnapshot,
            correctionPolicy: correctionPolicy,
            targetLease: targetLease,
            timeoutSeconds: timeoutSeconds
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case generation
        case createdAt
        case localeIdentifier
        case speechProvider
        case resolvedSpeechProvider
        case correctionProvider
        case resolvedCorrectionProvider
        case correctionFallbackProviderIDs
        case privacyRoute
        case vocabularySnapshot
        case correctionPolicy
        case targetLease
        case timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(VoiceSessionID.self, forKey: .sessionID)
        generation = try values.decode(SessionGeneration.self, forKey: .generation)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        localeIdentifier = try values.decode(String.self, forKey: .localeIdentifier)
        speechProvider = try values.decode(SpeechProviderDescriptor.self, forKey: .speechProvider)
        resolvedSpeechProvider = try values.decodeIfPresent(
            SpeechProviderDescriptor.self,
            forKey: .resolvedSpeechProvider
        )
        correctionProvider = try values.decode(CorrectionProviderDescriptor.self, forKey: .correctionProvider)
        resolvedCorrectionProvider = try values.decodeIfPresent(
            CorrectionProviderDescriptor.self,
            forKey: .resolvedCorrectionProvider
        )
        correctionFallbackProviderIDs = try values.decodeIfPresent(
            [String].self,
            forKey: .correctionFallbackProviderIDs
        ) ?? []
        privacyRoute = try values.decode(PrivacyRoute.self, forKey: .privacyRoute)
        vocabularySnapshot = try values.decode(VocabularySnapshot.self, forKey: .vocabularySnapshot)
        correctionPolicy = try values.decode(CorrectionPolicy.self, forKey: .correctionPolicy)
        targetLease = try values.decode(TargetLease.self, forKey: .targetLease)
        timeoutSeconds = SessionWatchdog.normalizedSeconds(
            try values.decode(Double.self, forKey: .timeoutSeconds)
        )
    }

    /// The descriptor to use for runtime attribution. A legacy or not-yet-resolved manifest has
    /// no resolved field, in which case the requested provider remains the only known identity.
    public var effectiveSpeechProvider: SpeechProviderDescriptor {
        resolvedSpeechProvider ?? speechProvider
    }

    public var effectiveCorrectionProvider: CorrectionProviderDescriptor {
        resolvedCorrectionProvider ?? correctionProvider
    }

    func resolvingSpeechProvider(
        _ descriptor: SpeechProviderDescriptor
    ) -> VoiceSessionSnapshot {
        VoiceSessionSnapshot(
            sessionID: sessionID,
            generation: generation,
            createdAt: createdAt,
            localeIdentifier: localeIdentifier,
            speechProvider: speechProvider,
            resolvedSpeechProvider: descriptor,
            correctionProvider: correctionProvider,
            resolvedCorrectionProvider: resolvedCorrectionProvider,
            correctionFallbackProviderIDs: correctionFallbackProviderIDs,
            privacyRoute: privacyRoute,
            vocabularySnapshot: vocabularySnapshot,
            correctionPolicy: correctionPolicy,
            targetLease: targetLease,
            timeoutSeconds: timeoutSeconds
        )
    }

    func resolvingCorrectionProvider(
        _ descriptor: CorrectionProviderDescriptor
    ) -> VoiceSessionSnapshot {
        VoiceSessionSnapshot(
            sessionID: sessionID,
            generation: generation,
            createdAt: createdAt,
            localeIdentifier: localeIdentifier,
            speechProvider: speechProvider,
            resolvedSpeechProvider: resolvedSpeechProvider,
            correctionProvider: correctionProvider,
            resolvedCorrectionProvider: descriptor,
            correctionFallbackProviderIDs: correctionFallbackProviderIDs,
            privacyRoute: privacyRoute,
            vocabularySnapshot: vocabularySnapshot,
            correctionPolicy: correctionPolicy,
            targetLease: targetLease,
            timeoutSeconds: timeoutSeconds
        )
    }
}
