import Foundation

public struct VoiceSessionSnapshot: Codable, Sendable, Equatable {
    public let sessionID: VoiceSessionID
    public let generation: SessionGeneration
    public let createdAt: Date
    public let localeIdentifier: String
    public let speechProvider: SpeechProviderDescriptor
    public let correctionProvider: CorrectionProviderDescriptor
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
        correctionProvider: CorrectionProviderDescriptor,
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
        self.correctionProvider = correctionProvider
        self.privacyRoute = privacyRoute
        self.vocabularySnapshot = vocabularySnapshot
        self.correctionPolicy = correctionPolicy
        self.targetLease = targetLease
        self.timeoutSeconds = timeoutSeconds
    }
}
