import Foundation
import CoreMedia

// MARK: - Identifiers & Generation

public struct VoiceSessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }
}

public struct SessionGeneration: Hashable, Codable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64 = 0) {
        self.rawValue = rawValue
    }

    public func next() -> SessionGeneration {
        SessionGeneration(rawValue: rawValue + 1)
    }

    public static func < (lhs: SessionGeneration, rhs: SessionGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Privacy Route

public enum PrivacyRoute: String, Codable, Sendable {
    case onDeviceOnly
    case localNetworkOnly
    case cloudPermitted
}

// MARK: - Provider Descriptors & Evidence

public struct SpeechProviderDescriptor: Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let modelVersion: String
    public let privacyRoute: PrivacyRoute
    public let supportsStreaming: Bool
    public let supportsContextualStrings: Bool

    public init(
        id: String,
        displayName: String,
        modelVersion: String,
        privacyRoute: PrivacyRoute,
        supportsStreaming: Bool = false,
        supportsContextualStrings: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.modelVersion = modelVersion
        self.privacyRoute = privacyRoute
        self.supportsStreaming = supportsStreaming
        self.supportsContextualStrings = supportsContextualStrings
    }
}

public struct CorrectionProviderDescriptor: Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let modelVersion: String
    public let privacyRoute: PrivacyRoute
    public let supportsStructuredOutput: Bool

    public init(
        id: String,
        displayName: String,
        modelVersion: String,
        privacyRoute: PrivacyRoute,
        supportsStructuredOutput: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.modelVersion = modelVersion
        self.privacyRoute = privacyRoute
        self.supportsStructuredOutput = supportsStructuredOutput
    }
}

public struct ProviderEvidence: Hashable, Codable, Sendable {
    public let providerID: String
    public let modelVersion: String
    public let probeTimestamp: Date
    public let capabilities: [String]
    public let contextLimits: Int?

    public init(
        providerID: String,
        modelVersion: String,
        probeTimestamp: Date = Date(),
        capabilities: [String] = [],
        contextLimits: Int? = nil
    ) {
        self.providerID = providerID
        self.modelVersion = modelVersion
        self.probeTimestamp = probeTimestamp
        self.capabilities = capabilities
        self.contextLimits = contextLimits
    }
}

public enum VoicePermissionKind: String, Codable, Sendable, Equatable {
    case microphone
    case speechRecognition
    case accessibility
}

public enum ConfigurationRequirement: String, Codable, Sendable, Equatable {
    case missingAPIKey
    case missingEndpoint
    case missingModelDownload
    case invalidEndpointFormat
}

public enum ProviderReadiness: Sendable, Equatable {
    case ready(ProviderEvidence)
    case downloading(progress: Double?)
    case requiresPermission(VoicePermissionKind)
    case requiresConfiguration(ConfigurationRequirement)
    case temporarilyUnavailable(retryAfterSeconds: Double?, reason: FailureCode)
    case incompatible(reason: FailureCode)
    case corrupt(reason: FailureCode)
    case unsupported(reason: FailureCode)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - Failure Taxonomy

public enum FailureStage: String, Codable, Sendable {
    case audioCapture
    case audioFinalization
    case recognition
    case rawValidation
    case correction
    case correctionValidation
    case persistence
    case delivery
    case protocolViolation
}

public enum FailureCode: String, Codable, Sendable {
    case noMicrophone
    case microphonePermissionDenied
    case accessibilityPermissionDenied
    case zeroFramesCaptured
    case captureBackpressure
    case deviceChangeInterrupted
    case diskFull
    case audioEncodingFailed
    case missingAPIKey
    case authFailed
    case endpointUnreachable
    case modelNotFound
    case modelDigestMismatch
    case modelLoadFailed
    case rateLimited
    case quotaExhausted
    case requestTimeout
    case speechNoSpeech
    case speechCoverageGap
    case speechRepeatedLoop
    case speechProtocolViolation
    case correctionRefusal
    case correctionHallucination
    case correctionProtectedSpanAltered
    case correctionUnsupportedEdit
    case correctionTimeout
    case targetLeaseExpired
    case targetAppTerminated
    case secureInputActive
    case manifestWriteFailed
    case staleGeneration
}

public enum RetryClass: String, Codable, Sendable {
    case none
    case immediateSameRoute
    case jitteredBackoff
    case afterUserAction
}

public enum ArtifactState: String, Codable, Sendable {
    case absent
    case partial
    case durable
    case corrupted
}

public enum UserAction: String, Codable, Sendable {
    case grantMicrophonePermission
    case grantAccessibilityPermission
    case enterAPIKey
    case configureEndpoint
    case downloadModel
    case freeDiskSpace
    case retryWithOtherProvider
    case reviewInHistory
}

public struct VoiceFailure: Error, Codable, Sendable, Equatable {
    public let stage: FailureStage
    public let code: FailureCode
    public let providerID: String?
    public let retryClass: RetryClass
    public let artifactState: ArtifactState
    public let userAction: UserAction?
    public let diagnosticID: UUID
    public let redactedDetail: String?

    public init(
        stage: FailureStage,
        code: FailureCode,
        providerID: String? = nil,
        retryClass: RetryClass = .none,
        artifactState: ArtifactState = .absent,
        userAction: UserAction? = nil,
        diagnosticID: UUID = UUID(),
        redactedDetail: String? = nil
    ) {
        self.stage = stage
        self.code = code
        self.providerID = providerID
        self.retryClass = retryClass
        self.artifactState = artifactState
        self.userAction = userAction
        self.diagnosticID = diagnosticID
        self.redactedDetail = redactedDetail
    }
}

// MARK: - Speech Recognition Contracts

public struct AudioArtifact: Codable, Sendable, Equatable {
    public let fileURL: URL
    public let format: String
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int64
    public let durationSeconds: Double
    public let byteCount: Int64
    public let sha256Hex: String
    public let gapCount: Int

    public init(
        fileURL: URL,
        format: String = "caf",
        sampleRate: Double = 16000,
        channelCount: Int = 1,
        frameCount: Int64 = 0,
        durationSeconds: Double = 0,
        byteCount: Int64 = 0,
        sha256Hex: String = "",
        gapCount: Int = 0
    ) {
        self.fileURL = fileURL
        self.format = format
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex
        self.gapCount = gapCount
    }
}

public struct VocabularySnapshot: Codable, Sendable, Equatable {
    public let terms: [String]
    public let hashValueHex: String

    public init(terms: [String] = []) {
        self.terms = terms
        let joined = terms.sorted().joined(separator: "|")
        self.hashValueHex = String(joined.hashValue)
    }
}

public struct SpeechRequest: Sendable {
    public let sessionID: VoiceSessionID
    public let generation: SessionGeneration
    public let audio: AudioArtifact
    public let locale: Locale
    public let vocabulary: VocabularySnapshot
    public let deadline: Date
    public let privacyRoute: PrivacyRoute

    public init(
        sessionID: VoiceSessionID,
        generation: SessionGeneration,
        audio: AudioArtifact,
        locale: Locale = Locale.current,
        vocabulary: VocabularySnapshot = VocabularySnapshot(),
        deadline: Date,
        privacyRoute: PrivacyRoute
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.audio = audio
        self.locale = locale
        self.vocabulary = vocabulary
        self.deadline = deadline
        self.privacyRoute = privacyRoute
    }
}

public enum Finality: String, Codable, Sendable {
    case volatile
    case final
}

public struct SpeechAlternative: Codable, Sendable, Equatable {
    public let text: String
    public let confidence: Double?

    public init(text: String, confidence: Double? = nil) {
        self.text = text
        self.confidence = confidence
    }
}

public struct SpeechSegment: Codable, Sendable, Equatable {
    public let segmentID: String
    public let revision: UInt64
    public let startSeconds: Double
    public let durationSeconds: Double
    public let text: String
    public let alternatives: [SpeechAlternative]
    public let confidence: Double?
    public let finality: Finality

    public init(
        segmentID: String,
        revision: UInt64 = 1,
        startSeconds: Double = 0,
        durationSeconds: Double = 0,
        text: String,
        alternatives: [SpeechAlternative] = [],
        confidence: Double? = nil,
        finality: Finality = .volatile
    ) {
        self.segmentID = segmentID
        self.revision = revision
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.text = text
        self.alternatives = alternatives
        self.confidence = confidence
        self.finality = finality
    }
}

public struct SpeechMetricsSample: Codable, Sendable, Equatable {
    public let audioLevel: Float
    public let processedFrames: Int64
    public let latencyMs: Double

    public init(audioLevel: Float, processedFrames: Int64, latencyMs: Double) {
        self.audioLevel = audioLevel
        self.processedFrames = processedFrames
        self.latencyMs = latencyMs
    }
}

public struct SpeechCompletion: Codable, Sendable, Equatable {
    public let rawTranscript: RawTranscript
    public let finalSegmentCount: Int
    public let totalDurationSeconds: Double

    public init(rawTranscript: RawTranscript, finalSegmentCount: Int, totalDurationSeconds: Double) {
        self.rawTranscript = rawTranscript
        self.finalSegmentCount = finalSegmentCount
        self.totalDurationSeconds = totalDurationSeconds
    }
}

public enum SpeechEvent: Sendable {
    case segment(SpeechSegment)
    case metrics(SpeechMetricsSample)
    case completed(SpeechCompletion)
}

public struct RawTranscript: Codable, Sendable, Equatable {
    public let text: String
    public let localeIdentifier: String
    public let confidence: Double?
    public let providerID: String
    public let modelVersion: String
    public let latencyMs: Double
    public let audioSHA256: String
    public let isFinal: Bool

    public init(
        text: String,
        localeIdentifier: String,
        confidence: Double? = nil,
        providerID: String,
        modelVersion: String,
        latencyMs: Double = 0,
        audioSHA256: String = "",
        isFinal: Bool = true
    ) {
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.confidence = confidence
        self.providerID = providerID
        self.modelVersion = modelVersion
        self.latencyMs = latencyMs
        self.audioSHA256 = audioSHA256
        self.isFinal = isFinal
    }
}

// MARK: - Correction Contracts

public enum CorrectionTone: String, Codable, Sendable {
    case exact
    case standard
    case professional
    case casual
    case code
}

public struct CorrectionPolicy: Codable, Sendable, Equatable {
    public let tone: CorrectionTone
    public let allowDisfluencyRemoval: Bool
    public let allowFalseStartRemoval: Bool
    public let allowSpokenPunctuation: Bool
    public let allowNumberFormatting: Bool
    public let preserveProtectedSpans: Bool
    public let maxAdditionRatio: Double
    public let maxDeletionRatio: Double

    public init(
        tone: CorrectionTone = .standard,
        allowDisfluencyRemoval: Bool = true,
        allowFalseStartRemoval: Bool = true,
        allowSpokenPunctuation: Bool = true,
        allowNumberFormatting: Bool = true,
        preserveProtectedSpans: Bool = true,
        maxAdditionRatio: Double = 0.25,
        maxDeletionRatio: Double = 0.40
    ) {
        self.tone = tone
        self.allowDisfluencyRemoval = allowDisfluencyRemoval
        self.allowFalseStartRemoval = allowFalseStartRemoval
        self.allowSpokenPunctuation = allowSpokenPunctuation
        self.allowNumberFormatting = allowNumberFormatting
        self.preserveProtectedSpans = preserveProtectedSpans
        self.maxAdditionRatio = maxAdditionRatio
        self.maxDeletionRatio = maxDeletionRatio
    }
}

public enum ProtectedSpanKind: String, Codable, Sendable {
    case url
    case email
    case filePath
    case shellFlag
    case codeIdentifier
    case numberWithUnit
    case dateTime
    case currency
    case versionNumber
    case customDictionary
    case quotedLiteral
}

public struct ProtectedSpan: Codable, Sendable, Equatable {
    public let kind: ProtectedSpanKind
    public let originalText: String
    public let canonicalForm: String
    public let utf16RangeStart: Int
    public let utf16RangeLength: Int

    public init(
        kind: ProtectedSpanKind,
        originalText: String,
        canonicalForm: String,
        utf16RangeStart: Int,
        utf16RangeLength: Int
    ) {
        self.kind = kind
        self.originalText = originalText
        self.canonicalForm = canonicalForm
        self.utf16RangeStart = utf16RangeStart
        self.utf16RangeLength = utf16RangeLength
    }
}

public enum CorrectionEditKind: String, Codable, Sendable {
    case punctuation
    case capitalization
    case whitespace
    case disfluencyRemoval
    case falseStartRemoval
    case numberFormatting
    case dictionaryReplacement
    case unsupported
}

public struct CorrectionEdit: Codable, Sendable, Equatable {
    public let kind: CorrectionEditKind
    public let utf16Start: Int
    public let utf16Length: Int
    public let before: String
    public let after: String

    public init(
        kind: CorrectionEditKind,
        utf16Start: Int,
        utf16Length: Int,
        before: String,
        after: String
    ) {
        self.kind = kind
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
        self.before = before
        self.after = after
    }
}

public struct CorrectionRequest: Sendable {
    public let sessionID: VoiceSessionID
    public let generation: SessionGeneration
    public let rawTranscript: String
    public let locale: Locale
    public let policy: CorrectionPolicy
    public let protectedSpans: [ProtectedSpan]
    public let deadline: Date
    public let privacyRoute: PrivacyRoute

    public init(
        sessionID: VoiceSessionID,
        generation: SessionGeneration,
        rawTranscript: String,
        locale: Locale = Locale.current,
        policy: CorrectionPolicy = CorrectionPolicy(),
        protectedSpans: [ProtectedSpan] = [],
        deadline: Date,
        privacyRoute: PrivacyRoute
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.rawTranscript = rawTranscript
        self.locale = locale
        self.policy = policy
        self.protectedSpans = protectedSpans
        self.deadline = deadline
        self.privacyRoute = privacyRoute
    }
}

public struct CorrectionCandidate: Codable, Sendable, Equatable {
    public let text: String
    public let providerID: String
    public let modelVersion: String
    public let edits: [CorrectionEdit]
    public let latencyMs: Double
    public let promptVersion: String
    public let refusalDetected: Bool

    public init(
        text: String,
        providerID: String,
        modelVersion: String,
        edits: [CorrectionEdit] = [],
        latencyMs: Double = 0,
        promptVersion: String = "1.0",
        refusalDetected: Bool = false
    ) {
        self.text = text
        self.providerID = providerID
        self.modelVersion = modelVersion
        self.edits = edits
        self.latencyMs = latencyMs
        self.promptVersion = promptVersion
        self.refusalDetected = refusalDetected
    }
}

public enum ValidationOutcome: Codable, Sendable, Equatable {
    case accepted(metrics: [String: Double])
    case rejected(reasons: [FailureCode])
    case fallbackToRaw(reason: FailureCode)
    case notApplicable
}

public struct FinalTranscript: Codable, Sendable, Equatable {
    public let text: String
    public let rawTranscript: RawTranscript
    public let correctionCandidate: CorrectionCandidate?
    public let validationOutcome: ValidationOutcome
    public let timestamp: Date

    public init(
        text: String,
        rawTranscript: RawTranscript,
        correctionCandidate: CorrectionCandidate? = nil,
        validationOutcome: ValidationOutcome,
        timestamp: Date = Date()
    ) {
        self.text = text
        self.rawTranscript = rawTranscript
        self.correctionCandidate = correctionCandidate
        self.validationOutcome = validationOutcome
        self.timestamp = timestamp
    }
}

// MARK: - Target Lease & Delivery

public struct TargetLease: Codable, Sendable, Equatable {
    public let bundleIdentifier: String?
    public let processIdentifier: Int32
    public let targetElementDescription: String?
    public let acquiredAt: Date

    public init(
        bundleIdentifier: String?,
        processIdentifier: Int32,
        targetElementDescription: String? = nil,
        acquiredAt: Date = Date()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.targetElementDescription = targetElementDescription
        self.acquiredAt = acquiredAt
    }
}

public enum DeliveryEvidenceQuality: String, Codable, Sendable {
    case verifiedDirectAX
    case settledUnverifiedPaste
    case clipboardOnly
    case targetMismatch
    case secureInputRefused
    case permissionDenied
    case timedOut
    case cancelled
    case failed
}

public struct DeliveryReceipt: Codable, Sendable, Equatable {
    public let sessionID: VoiceSessionID
    public let generation: SessionGeneration
    public let targetLease: TargetLease
    public let deliveredTextLength: Int
    public let evidenceQuality: DeliveryEvidenceQuality
    public let deliveredAt: Date
    public let latencyMs: Double

    public init(
        sessionID: VoiceSessionID,
        generation: SessionGeneration,
        targetLease: TargetLease,
        deliveredTextLength: Int,
        evidenceQuality: DeliveryEvidenceQuality,
        deliveredAt: Date = Date(),
        latencyMs: Double = 0
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.targetLease = targetLease
        self.deliveredTextLength = deliveredTextLength
        self.evidenceQuality = evidenceQuality
        self.deliveredAt = deliveredAt
        self.latencyMs = latencyMs
    }
}

// MARK: - Session Phases & Commands

public enum SessionPhase: Codable, Sendable, Equatable {
    case preparing
    case capturing(mode: DictationMode)
    case finalizingAudio
    case recognizing
    case validatingRaw
    case correcting
    case validatingCorrection
    case readyForDelivery
    case delivering
    case completed(SessionOutcome)
    case failed(VoiceFailure)
    case cancelled
    case recoverable(lastPhase: String)
}

public enum SessionOutcome: Codable, Sendable, Equatable {
    case inserted(DeliveryReceipt)
    case savedButNotInserted(reason: String)
    case copiedToClipboard(characterCount: Int)
    case voiceCommandExecuted(command: String)
}
