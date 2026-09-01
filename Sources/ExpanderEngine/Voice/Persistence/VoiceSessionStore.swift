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
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectory = appSupport.appendingPathComponent("DevType/VoiceSessions", isDirectory: true)
        }
        do {
            try fileManager.createDirectory(
                at: self.baseDirectory,
                withIntermediateDirectories: true,
                attributes: [FileAttributeKey.posixPermissions: 0o700]
            )
        } catch {
            DevTypeLog.store.error(
                "[Voice] could not create session store directory \(self.baseDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
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
        try atomicWrite(data: data, to: manifestURL)
        return dir
    }

    public func saveRawTranscript(_ raw: RawTranscript, for sessionID: VoiceSessionID) throws {
        lock.lock()
        defer { lock.unlock() }
        let dir = sessionDirectory(for: sessionID)
        let fileURL = dir.appendingPathComponent("raw-transcript.json")
        let data = try JSONEncoder().encode(raw)
        try atomicWrite(data: data, to: fileURL)
    }

    public func saveFinalTranscript(_ final: FinalTranscript, for sessionID: VoiceSessionID) throws {
        lock.lock()
        defer { lock.unlock() }
        let dir = sessionDirectory(for: sessionID)
        let fileURL = dir.appendingPathComponent("final-transcript.json")
        let data = try JSONEncoder().encode(final)
        try atomicWrite(data: data, to: fileURL)
    }

    public func saveDeliveryReceipt(_ receipt: DeliveryReceipt, for sessionID: VoiceSessionID) throws {
        lock.lock()
        defer { lock.unlock() }
        let dir = sessionDirectory(for: sessionID)
        let fileURL = dir.appendingPathComponent("delivery-receipt.json")
        let data = try JSONEncoder().encode(receipt)
        try atomicWrite(data: data, to: fileURL)
    }

    /// Persists the exact artifact metadata used for recognition. The CAF itself is written by
    /// `DurableVoiceCapture`; keeping its measured digest and frame count beside the transcripts
    /// lets recovery distinguish a complete file from an incomplete capture.
    public func saveAudioArtifact(_ artifact: AudioArtifact, for sessionID: VoiceSessionID) throws {
        lock.lock()
        defer { lock.unlock() }
        let dir = sessionDirectory(for: sessionID)
        let fileURL = dir.appendingPathComponent("audio-artifact.json")
        let data = try JSONEncoder().encode(artifact)
        try atomicWrite(data: data, to: fileURL)
    }

    private func atomicWrite(data: Data, to destinationURL: URL) throws {
        let tempURL = destinationURL.deletingLastPathComponent().appendingPathComponent(".\(destinationURL.lastPathComponent).tmp")
        try data.write(to: tempURL, options: .atomic)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)
    }
}
