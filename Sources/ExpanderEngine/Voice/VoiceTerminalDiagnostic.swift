import Foundation

/// The one persisted description of a voice session that did not finish normally.
///
/// Every field has a finite vocabulary. There is deliberately no string payload for a provider
/// id, transcript, audio path, target application, model response, or `Error` description. That
/// makes this safe to retain while the opt-in content-bearing voice trace remains disabled.
public struct VoiceTerminalDiagnostic: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case failed
        case cancelled
        case superseded
    }

    /// Failure codes reuse the reducer's typed taxonomy. Cancellation and supersession are not
    /// failures, so they remain distinct instead of being mislabeled as `staleGeneration`.
    public enum Code: Equatable, Sendable {
        case failure(FailureCode)
        case cancelled
        case superseded

        public var rawValue: String {
            switch self {
            case .failure(let code): return code.rawValue
            case .cancelled: return "cancelled"
            case .superseded: return "sessionSuperseded"
            }
        }
    }

    /// Whitelisted provider families. Unknown/free-form provider identifiers collapse to
    /// `unknown`; they are never copied into a report or Activity history.
    public enum Provider: String, Codable, Sendable {
        case audioCapture
        case appleSpeech
        case gemini
        case whisperCpp
        case deterministic
        case appleIntelligence
        case ollama
        case openAICompatible
        case textDelivery
        case sessionStore
        case sessionCoordinator
        case unknown
    }

    public enum Locality: String, Codable, Sendable {
        case onDevice
        case localNetwork
        case cloud
    }

    public enum Recoverability: String, Codable, Sendable {
        case notRecoverable
        case retryImmediately
        case retryAfterDelay
        case userActionRequired
        case notApplicable
    }

    public let id: UUID
    public let recordedAt: Date
    public let outcome: Outcome
    public let code: Code
    public let stage: FailureStage
    public let provider: Provider
    public let locality: Locality
    public let recoverability: Recoverability

    public init(
        id: UUID = UUID(),
        recordedAt: Date = Date(),
        outcome: Outcome,
        code: Code,
        stage: FailureStage,
        provider: Provider,
        locality: Locality,
        recoverability: Recoverability
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.outcome = outcome
        self.code = code
        self.stage = stage
        self.provider = provider
        self.locality = locality
        self.recoverability = recoverability
    }

    public init(
        failure: VoiceFailure,
        snapshot: VoiceSessionSnapshot,
        recordedAt: Date = Date()
    ) {
        let context = Self.providerContext(for: failure, snapshot: snapshot)
        self.init(
            id: failure.diagnosticID,
            recordedAt: recordedAt,
            outcome: .failed,
            code: .failure(failure.code),
            stage: failure.stage,
            provider: context.provider,
            locality: context.locality,
            recoverability: Self.recoverability(for: failure.retryClass)
        )
    }

    public static func cancelled(
        snapshot: VoiceSessionSnapshot,
        stage: FailureStage,
        recordedAt: Date = Date()
    ) -> VoiceTerminalDiagnostic {
        let context = providerContext(for: stage, snapshot: snapshot)
        return VoiceTerminalDiagnostic(
            recordedAt: recordedAt,
            outcome: .cancelled,
            code: .cancelled,
            stage: stage,
            provider: context.provider,
            locality: context.locality,
            recoverability: .notApplicable
        )
    }

    public static func superseded(
        snapshot: VoiceSessionSnapshot,
        stage: FailureStage,
        recordedAt: Date = Date()
    ) -> VoiceTerminalDiagnostic {
        let context = providerContext(for: stage, snapshot: snapshot)
        return VoiceTerminalDiagnostic(
            recordedAt: recordedAt,
            outcome: .superseded,
            code: .superseded,
            stage: stage,
            provider: context.provider,
            locality: context.locality,
            recoverability: .retryImmediately
        )
    }

    /// Content-free terminal result for delivery that completed without reaching the target.
    public static func deliveryFailure(
        code: FailureCode,
        recoverability: Recoverability,
        recordedAt: Date = Date()
    ) -> VoiceTerminalDiagnostic {
        VoiceTerminalDiagnostic(
            recordedAt: recordedAt,
            outcome: .failed,
            code: .failure(code),
            stage: .delivery,
            provider: .textDelivery,
            locality: .onDevice,
            recoverability: recoverability
        )
    }

    public static func preflightFailure(
        code: FailureCode,
        stage: FailureStage,
        provider: Provider,
        locality: Locality,
        recordedAt: Date = Date()
    ) -> VoiceTerminalDiagnostic {
        VoiceTerminalDiagnostic(
            recordedAt: recordedAt,
            outcome: .failed,
            code: .failure(code),
            stage: stage,
            provider: provider,
            locality: locality,
            recoverability: .userActionRequired
        )
    }

    private static func recoverability(for retryClass: RetryClass) -> Recoverability {
        switch retryClass {
        case .none: return .notRecoverable
        case .immediateSameRoute: return .retryImmediately
        case .jitteredBackoff: return .retryAfterDelay
        case .afterUserAction: return .userActionRequired
        }
    }

    private static func providerContext(
        for failure: VoiceFailure,
        snapshot: VoiceSessionSnapshot
    ) -> (provider: Provider, locality: Locality) {
        switch failure.stage {
        case .audioCapture, .audioFinalization:
            return (.audioCapture, .onDevice)
        case .recognition, .rawValidation:
            let descriptor = snapshot.effectiveSpeechProvider
            let providerID = failure.providerID ?? descriptor.id
            return descriptorContext(
                id: providerID,
                fallbackRoute: speechRoute(
                    for: providerID,
                    snapshot: snapshot,
                    defaultRoute: descriptor.privacyRoute
                )
            )
        case .correction, .correctionValidation:
            let descriptor = snapshot.effectiveCorrectionProvider
            let providerID = failure.providerID ?? descriptor.id
            return descriptorContext(
                id: providerID,
                fallbackRoute: correctionRoute(
                    for: providerID,
                    snapshot: snapshot,
                    defaultRoute: descriptor.privacyRoute
                )
            )
        case .persistence:
            return (.sessionStore, .onDevice)
        case .delivery:
            return (.textDelivery, .onDevice)
        case .protocolViolation:
            return (.sessionCoordinator, .onDevice)
        }
    }

    private static func speechRoute(
        for providerID: String,
        snapshot: VoiceSessionSnapshot,
        defaultRoute: PrivacyRoute
    ) -> PrivacyRoute {
        if snapshot.resolvedSpeechProvider?.id == providerID {
            return snapshot.resolvedSpeechProvider?.privacyRoute ?? defaultRoute
        }
        if snapshot.speechProvider.id == providerID {
            return snapshot.speechProvider.privacyRoute
        }
        return defaultRoute
    }

    private static func correctionRoute(
        for providerID: String,
        snapshot: VoiceSessionSnapshot,
        defaultRoute: PrivacyRoute
    ) -> PrivacyRoute {
        if snapshot.resolvedCorrectionProvider?.id == providerID {
            return snapshot.resolvedCorrectionProvider?.privacyRoute ?? defaultRoute
        }
        if snapshot.correctionProvider.id == providerID {
            return snapshot.correctionProvider.privacyRoute
        }
        return defaultRoute
    }

    private static func providerContext(
        for stage: FailureStage,
        snapshot: VoiceSessionSnapshot
    ) -> (provider: Provider, locality: Locality) {
        let synthetic = VoiceFailure(stage: stage, code: .staleGeneration)
        return providerContext(for: synthetic, snapshot: snapshot)
    }

    private static func descriptorContext(
        id: String,
        fallbackRoute: PrivacyRoute
    ) -> (provider: Provider, locality: Locality) {
        switch id {
        case VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer,
             VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy:
            return (.appleSpeech, .onDevice)
        case VoiceSessionSnapshotFactory.ProviderID.gemini:
            return (.gemini, .cloud)
        case VoiceSessionSnapshotFactory.ProviderID.whisperServer:
            return (.whisperCpp, .localNetwork)
        case VoiceSessionSnapshotFactory.ProviderID.deterministicCorrector,
             CorrectionProviderRegistry.disabledID:
            return (.deterministic, .onDevice)
        case VoiceSessionSnapshotFactory.ProviderID.proofreadCorrector,
             VoiceSessionSnapshotFactory.ProviderID.appleFoundationModels:
            return (.appleIntelligence, .onDevice)
        case VoiceSessionSnapshotFactory.ProviderID.ollamaCorrector:
            return (.ollama, .localNetwork)
        case VoiceSessionSnapshotFactory.ProviderID.openAICompatibleCorrector:
            return (.openAICompatible, .localNetwork)
        default:
            return (.unknown, locality(for: fallbackRoute))
        }
    }

    private static func locality(for route: PrivacyRoute) -> Locality {
        switch route {
        case .onDeviceOnly: return .onDevice
        case .localNetworkOnly: return .localNetwork
        case .cloudPermitted: return .cloud
        }
    }
}

extension VoiceTerminalDiagnostic.Code: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "cancelled": self = .cancelled
        case "sessionSuperseded": self = .superseded
        default:
            guard let failure = FailureCode(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown voice terminal diagnostic code"
                )
            }
            self = .failure(failure)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
