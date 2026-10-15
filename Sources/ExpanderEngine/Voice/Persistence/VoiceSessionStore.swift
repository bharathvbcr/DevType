import Foundation

public final class VoiceSessionStore: @unchecked Sendable {
    public static let shared = VoiceSessionStore()

    private let baseDirectory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    public init(baseDirectory: URL? = nil) {
        if let base = baseDirectory {
            self.baseDirectory = base
        } else {
            self.baseDirectory = SupportDirectory.voiceSessions
        }
        do {
            try fileManager.createDirectory(
                at: self.baseDirectory,
                withIntermediateDirectories: true,
                attributes: [FileAttributeKey.posixPermissions: 0o700]
            )
        } catch {
            DevTypeLog.store.error(
                "[Voice] could not create session store directory \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
        }
    }

    public func sessionDirectory(for sessionID: VoiceSessionID) -> URL {
        baseDirectory.appendingPathComponent(sessionID.description, isDirectory: true)
    }

    public func createSession(snapshot: VoiceSessionSnapshot) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        let dir = sessionDirectory(for: snapshot.sessionID)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o700])

        let manifestURL = dir.appendingPathComponent("manifest.json")
        let data = try JSONEncoder().encode(snapshot)
        try atomicWrite(data: data, to: manifestURL, maximumBytes: VoiceRecoveryService.ScanLimits.standard.maximumManifestBytes)
        return dir
    }

    private struct SessionFile {
        var name: String
        var maximumBytes: Int
    }

    private static let rawTranscriptFile = SessionFile(
        name: "raw-transcript.json",
        maximumBytes: VoiceRecoveryService.ScanLimits.standard.maximumRawTranscriptBytes
    )
    private static let finalTranscriptFile = SessionFile(
        name: "final-transcript.json",
        maximumBytes: VoiceRecoveryService.ScanLimits.standard.maximumFinalTranscriptBytes
    )
    private static let deliveryReceiptFile = SessionFile(
        name: "delivery-receipt.json",
        maximumBytes: VoiceRecoveryService.ScanLimits.standard.maximumDeliveryReceiptBytes
    )
    /// An artifact record is metadata, not the audio, so it uses the manifest ceiling.
    private static let audioArtifactFile = SessionFile(
        name: "audio-artifact.json",
        maximumBytes: VoiceRecoveryService.ScanLimits.standard.maximumManifestBytes
    )

    public func saveRawTranscript(_ raw: RawTranscript, for sessionID: VoiceSessionID) throws {
        try saveJSON(raw, file: Self.rawTranscriptFile, sessionID: sessionID)
    }

    public func saveFinalTranscript(_ final: FinalTranscript, for sessionID: VoiceSessionID) throws {
        try saveJSON(final, file: Self.finalTranscriptFile, sessionID: sessionID)
    }

    public func saveDeliveryReceipt(_ receipt: DeliveryReceipt, for sessionID: VoiceSessionID) throws {
        try saveJSON(receipt, file: Self.deliveryReceiptFile, sessionID: sessionID)
    }

    /// Persists the exact artifact metadata used for recognition. The CAF itself is written by
    /// `DurableVoiceCapture`; keeping its measured digest and frame count beside the transcripts
    /// lets recovery distinguish a complete file from an incomplete capture.
    public func saveAudioArtifact(_ artifact: AudioArtifact, for sessionID: VoiceSessionID) throws {
        try saveJSON(artifact, file: Self.audioArtifactFile, sessionID: sessionID)
    }

    private func saveJSON<Value: Encodable>(
        _ value: Value,
        file: SessionFile,
        sessionID: VoiceSessionID
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileURL = sessionDirectory(for: sessionID).appendingPathComponent(file.name)
        let data = try JSONEncoder().encode(value)
        try atomicWrite(data: data, to: fileURL, maximumBytes: file.maximumBytes)
    }

    private func atomicWrite(data: Data, to destinationURL: URL, maximumBytes: Int) throws {
        // A successful save must remain readable under the recovery service's own bounds.
        guard data.count <= maximumBytes else { throw POSIXError(.EFBIG) }
        try FilePermissions.atomicWrite(data, to: destinationURL)
    }
}
