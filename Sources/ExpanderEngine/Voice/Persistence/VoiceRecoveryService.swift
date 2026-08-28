import Foundation

public struct RecoverableVoiceSession: Sendable, Identifiable {
    public var id: VoiceSessionID { snapshot.sessionID }
    public let snapshot: VoiceSessionSnapshot
    public let directoryURL: URL
    public let audioFileURL: URL?
    public let rawTranscript: RawTranscript?
    public let finalTranscript: FinalTranscript?
    public let receipt: DeliveryReceipt?
    public let isDelivered: Bool

    public init(
        snapshot: VoiceSessionSnapshot,
        directoryURL: URL,
        audioFileURL: URL?,
        rawTranscript: RawTranscript?,
        finalTranscript: FinalTranscript?,
        receipt: DeliveryReceipt?,
        isDelivered: Bool
    ) {
        self.snapshot = snapshot
        self.directoryURL = directoryURL
        self.audioFileURL = audioFileURL
        self.rawTranscript = rawTranscript
        self.finalTranscript = finalTranscript
        self.receipt = receipt
        self.isDelivered = isDelivered
    }
}

public final class VoiceRecoveryService: Sendable {
    public static let shared = VoiceRecoveryService()
    private let sessionStore: VoiceSessionStore

    public init(sessionStore: VoiceSessionStore = VoiceSessionStore.shared) {
        self.sessionStore = sessionStore
    }

    public func scanRecoverableSessions(baseDirectory: URL? = nil) -> [RecoverableVoiceSession] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = baseDirectory ?? appSupport.appendingPathComponent("DevType/VoiceSessions", isDirectory: true)

        guard let contents = try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }

        var results: [RecoverableVoiceSession] = []

        for sessionDir in contents {
            let manifestURL = sessionDir.appendingPathComponent("manifest.json")
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let snapshot = try? JSONDecoder().decode(VoiceSessionSnapshot.self, from: manifestData) else {
                continue
            }

            let cafURL = sessionDir.appendingPathComponent("capture.caf")
            let hasAudio = FileManager.default.fileExists(atPath: cafURL.path)

            let rawURL = sessionDir.appendingPathComponent("raw-transcript.json")
            let rawTranscript = (try? Data(contentsOf: rawURL)).flatMap { try? JSONDecoder().decode(RawTranscript.self, from: $0) }

            let finalURL = sessionDir.appendingPathComponent("final-transcript.json")
            let finalTranscript = (try? Data(contentsOf: finalURL)).flatMap { try? JSONDecoder().decode(FinalTranscript.self, from: $0) }

            let receiptURL = sessionDir.appendingPathComponent("delivery-receipt.json")
            let receipt = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode(DeliveryReceipt.self, from: $0) }

            let isDelivered = receipt != nil

            let recoverable = RecoverableVoiceSession(
                snapshot: snapshot,
                directoryURL: sessionDir,
                audioFileURL: hasAudio ? cafURL : nil,
                rawTranscript: rawTranscript,
                finalTranscript: finalTranscript,
                receipt: receipt,
                isDelivered: isDelivered
            )
            results.append(recoverable)
        }

        return results.sorted { $0.snapshot.createdAt > $1.snapshot.createdAt }
    }
}
