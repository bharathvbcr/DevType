import Foundation

/// Timestamps tracking the progression of a dictation session.
public struct SessionTimestamps: Sendable, Equatable {
    public var recordingStarted: Date?
    public var recordingStopped: Date?
    public var encodingStarted: Date?
    public var encodingComplete: Date?
    public var transcriptionStarted: Date?
    public var transcriptionComplete: Date?
    public var insertionStarted: Date?
    public var insertionComplete: Date?
    
    public init() {}
    
    /// The duration of the recorded audio, if recording has finished.
    public var audioDuration: TimeInterval? {
        guard let start = recordingStarted, let stop = recordingStopped else { return nil }
        return stop.timeIntervalSince(start)
    }
}

/// Tracks the lifecycle and context of a single dictation attempt.
public struct DictationSession: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public var audioURL: URL?
    public var flacURL: URL?
    public var mode: DictationMode
    public var insertionTargetBundleID: String?
    public var vocabularySnapshot: [String: String]
    public var toneSnapshot: DictationTone
    public var transcriptionEngine: TranscriptionEngine
    public var rawTranscript: String?
    public var finalTranscript: String?
    public var timestamps: SessionTimestamps
    
    /// Factory to begin a new session.
    public static func begin(mode: DictationMode, bundleID: String?, engine: TranscriptionEngine) -> DictationSession {
        return DictationSession(
            id: UUID(),
            startedAt: Date(),
            audioURL: nil,
            flacURL: nil,
            mode: mode,
            insertionTargetBundleID: bundleID,
            vocabularySnapshot: [:],
            toneSnapshot: .natural,
            transcriptionEngine: engine,
            rawTranscript: nil,
            finalTranscript: nil,
            timestamps: SessionTimestamps()
        )
    }
}
