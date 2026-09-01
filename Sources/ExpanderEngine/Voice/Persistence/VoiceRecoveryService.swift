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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
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

    /// Sessions that produced text but were never delivered — the app was killed, or the
    /// target app went away mid-insert. These are the ones worth offering back to the user.
    public func recoverableUndelivered(baseDirectory: URL? = nil) -> [RecoverableVoiceSession] {
        scanRecoverableSessions(baseDirectory: baseDirectory).filter { session in
            guard !session.isDelivered else { return false }
            let text = session.finalTranscript?.text ?? session.rawTranscript?.text ?? ""
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The best text a recovered session can offer.
    public static func recoveredText(_ session: RecoverableVoiceSession) -> String {
        let final = session.finalTranscript?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !final.isEmpty { return final }
        return session.rawTranscript?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Deletes session directories that are no longer useful.
    ///
    /// Every dictation writes a directory containing the captured audio, so without this
    /// the store grows without bound — a long-running install would accumulate gigabytes of
    /// recordings that nothing will ever read again.
    ///
    /// Delivered sessions past `olderThan` go first. Undelivered ones are kept longer
    /// because they are the only copy of something the user said and never received, but
    /// they are still bounded: past `keepingAtMost` the oldest are dropped.
    @discardableResult
    public func prune(
        olderThan maxAge: TimeInterval = 7 * 24 * 60 * 60,
        keepingAtMost limit: Int = 50,
        baseDirectory: URL? = nil,
        now: Date = Date()
    ) -> Int {
        let sessions = scanRecoverableSessions(baseDirectory: baseDirectory)
        var removed = 0

        var survivors: [RecoverableVoiceSession] = []
        for session in sessions {
            let age = now.timeIntervalSince(session.snapshot.createdAt)
            let expired = session.isDelivered && age > maxAge
            if expired {
                if discard(session) { removed += 1 }
            } else {
                survivors.append(session)
            }
        }

        // `scanRecoverableSessions` returns newest first, so anything past the cap is oldest.
        let boundedLimit = max(0, limit)
        if survivors.count > boundedLimit {
            for session in survivors[boundedLimit...] where discard(session) {
                removed += 1
            }
        }

        return removed
    }

    /// Removes one session's directory. Returns whether anything was deleted.
    @discardableResult
    public func discard(_ session: RecoverableVoiceSession) -> Bool {
        do {
            try FileManager.default.removeItem(at: session.directoryURL)
            return true
        } catch {
            DevTypeLog.app.error("[Voice] could not remove recovered session directory: \(error)")
            return false
        }
    }
}
