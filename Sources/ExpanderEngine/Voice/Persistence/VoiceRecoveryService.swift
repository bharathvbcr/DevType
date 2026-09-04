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

    /// Launch recovery keeps only this many candidate directories in memory and opens artifacts
    /// for only those candidates. The default on-disk retention ceiling is 50 sessions, so this
    /// lets a normal store be inspected completely while a corrupt directory flood cannot fan out
    /// reads.
    internal struct ScanLimits: Sendable {
        static let standard = ScanLimits(
            maximumCandidateDirectories: 50,
            maximumManifestBytes: 1 * 1_024 * 1_024,
            maximumRawTranscriptBytes: 1 * 1_024 * 1_024,
            maximumFinalTranscriptBytes: 4 * 1_024 * 1_024,
            maximumDeliveryReceiptBytes: 64 * 1_024
        )

        var maximumCandidateDirectories: Int
        var maximumManifestBytes: Int
        var maximumRawTranscriptBytes: Int
        var maximumFinalTranscriptBytes: Int
        var maximumDeliveryReceiptBytes: Int

        init(
            maximumCandidateDirectories: Int,
            maximumManifestBytes: Int,
            maximumRawTranscriptBytes: Int,
            maximumFinalTranscriptBytes: Int,
            maximumDeliveryReceiptBytes: Int
        ) {
            self.maximumCandidateDirectories = max(0, maximumCandidateDirectories)
            self.maximumManifestBytes = max(0, maximumManifestBytes)
            self.maximumRawTranscriptBytes = max(0, maximumRawTranscriptBytes)
            self.maximumFinalTranscriptBytes = max(0, maximumFinalTranscriptBytes)
            self.maximumDeliveryReceiptBytes = max(0, maximumDeliveryReceiptBytes)
        }
    }

    /// Content-free accounting for one bounded scan. `candidateDirectoriesSkippedByLimit` is exact
    /// when `directoryEnumerationWasComplete` is true; callers must not present a partial count as
    /// complete after an enumerator or metadata failure.
    public struct ScanReport: Sendable {
        public let sessions: [RecoverableVoiceSession]
        public let candidateDirectoriesObserved: Int
        public let candidateDirectoriesInspected: Int
        public let candidateDirectoriesSkippedByLimit: Int
        public let candidateDirectoriesRejected: Int
        public let corruptArtifactCount: Int
        public let oversizedArtifactCount: Int
        public let directoryEnumerationWasComplete: Bool

        /// Safe for OSLog and copied diagnostics: counts and a completeness bit, never paths,
        /// provider payloads, or recovered transcript text.
        public var diagnosticSummary: String {
            "observed=\(candidateDirectoriesObserved) "
                + "inspected=\(candidateDirectoriesInspected) "
                + "skippedByLimit=\(candidateDirectoriesSkippedByLimit) "
                + "rejected=\(candidateDirectoriesRejected) "
                + "corruptArtifacts=\(corruptArtifactCount) "
                + "oversizedArtifacts=\(oversizedArtifactCount) "
                + "enumerationComplete=\(directoryEnumerationWasComplete)"
        }
    }

    private let sessionStore: VoiceSessionStore
    private let scanLimits: ScanLimits

    public convenience init(sessionStore: VoiceSessionStore = VoiceSessionStore.shared) {
        self.init(sessionStore: sessionStore, scanLimits: .standard)
    }

    internal init(
        sessionStore: VoiceSessionStore = VoiceSessionStore.shared,
        scanLimits: ScanLimits
    ) {
        self.sessionStore = sessionStore
        self.scanLimits = scanLimits
    }

    public func scanRecoverableSessions(baseDirectory: URL? = nil) -> [RecoverableVoiceSession] {
        scanReport(baseDirectory: baseDirectory).sessions
    }

    public func scanReport(baseDirectory: URL? = nil) -> ScanReport {
        let baseDir = baseDirectory ?? SupportDirectory.voiceSessions
        let enumeration = boundedCandidateDirectories(at: baseDir)
        var results: [RecoverableVoiceSession] = []
        results.reserveCapacity(enumeration.candidates.count)
        var issues = ArtifactIssueCounts()

        for candidate in enumeration.candidates {
            if let session = readSession(at: candidate.url, issues: &issues) {
                results.append(session)
            }
        }

        let sessions = results.sorted { lhs, rhs in
            if lhs.snapshot.createdAt != rhs.snapshot.createdAt {
                return lhs.snapshot.createdAt > rhs.snapshot.createdAt
            }
            return lhs.directoryURL.standardizedFileURL.path
                < rhs.directoryURL.standardizedFileURL.path
        }
        let report = ScanReport(
            sessions: sessions,
            candidateDirectoriesObserved: enumeration.observedCount,
            candidateDirectoriesInspected: enumeration.candidates.count,
            candidateDirectoriesSkippedByLimit: max(
                0,
                enumeration.observedCount - enumeration.candidates.count
            ),
            candidateDirectoriesRejected: issues.candidateDirectoriesRejected,
            corruptArtifactCount: issues.corruptArtifactCount,
            oversizedArtifactCount: issues.oversizedArtifactCount,
            directoryEnumerationWasComplete: enumeration.wasComplete
        )
        if report.candidateDirectoriesSkippedByLimit > 0
            || report.candidateDirectoriesRejected > 0
            || report.corruptArtifactCount > 0
            || report.oversizedArtifactCount > 0
            || !report.directoryEnumerationWasComplete {
            DevTypeLog.voice.notice(
                "[Voice] bounded recovery scan: \(report.diagnosticSummary, privacy: .public)"
            )
        }
        return report
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
        let baseDir = baseDirectory ?? SupportDirectory.voiceSessions
        let boundedLimit = max(0, limit)
        var retained: [RetentionCandidate] = []
        retained.reserveCapacity(min(boundedLimit, ScanLimits.standard.maximumCandidateDirectories))
        var removed = 0
        var issues = ArtifactIssueCounts()

        // Unlike launch recovery, retention must visit the complete directory stream: reusing the
        // 50-item recovery projection would permanently strand every older directory. The top-K
        // set contains metadata only; decoded transcript objects are released after each visit.
        let enumeration = enumerateCandidateDirectories(at: baseDir) { candidate in
            guard let session = readSession(at: candidate.url, issues: &issues) else { return }
            let age = now.timeIntervalSince(session.snapshot.createdAt)
            let expired = session.isDelivered && age > maxAge
            if expired {
                if discard(session) { removed += 1 }
                return
            }

            let retentionCandidate = RetentionCandidate(
                directoryURL: session.directoryURL,
                createdAt: session.snapshot.createdAt,
                isRecovery: !session.isDelivered && !Self.recoveredText(session).isEmpty
            )
            if let rejected = insertRetentionCandidate(
                retentionCandidate,
                into: &retained,
                limit: boundedLimit
            ), discardDirectory(at: rejected.directoryURL) {
                removed += 1
            }
        }

        if issues.candidateDirectoriesRejected > 0
            || issues.corruptArtifactCount > 0
            || issues.oversizedArtifactCount > 0
            || !enumeration.wasComplete {
            let diagnosticSummary = "observed=\(enumeration.observedCount) "
                + "retained=\(retained.count) removed=\(removed) "
                + "rejected=\(issues.candidateDirectoriesRejected) "
                + "corruptArtifacts=\(issues.corruptArtifactCount) "
                + "oversizedArtifacts=\(issues.oversizedArtifactCount) "
                + "enumerationComplete=\(enumeration.wasComplete)"
            DevTypeLog.voice.notice(
                "[Voice] bounded recovery prune: \(diagnosticSummary, privacy: .public)"
            )
        }
        return removed
    }

    /// Removes one session's directory. Returns whether anything was deleted.
    @discardableResult
    public func discard(_ session: RecoverableVoiceSession) -> Bool {
        discardDirectory(at: session.directoryURL)
    }

    private func discardDirectory(at directoryURL: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: directoryURL)
            return true
        } catch {
            DevTypeLog.app.error("[Voice] could not remove recovered session directory: \(error)")
            return false
        }
    }

    private struct CandidateDirectory {
        let url: URL
        let recency: Date
    }

    private struct CandidateEnumeration {
        let candidates: [CandidateDirectory]
        let observedCount: Int
        let wasComplete: Bool
    }

    private struct DirectoryEnumeration {
        let observedCount: Int
        let wasComplete: Bool
    }

    private struct ArtifactIssueCounts {
        var candidateDirectoriesRejected = 0
        var corruptArtifactCount = 0
        var oversizedArtifactCount = 0
    }

    private struct RetentionCandidate {
        let directoryURL: URL
        let createdAt: Date
        let isRecovery: Bool
    }

    private enum ArtifactRead<Value> {
        case missing
        case value(Value)
        case oversized
        case corrupt
    }

    /// Streams top-level directory metadata and retains only the newest bounded candidate set.
    /// This intentionally does not call `contentsOfDirectory`, which would first materialize every
    /// attacker- or crash-created entry before a limit could be applied.
    private func boundedCandidateDirectories(at baseDirectory: URL) -> CandidateEnumeration {
        var candidates: [CandidateDirectory] = []
        candidates.reserveCapacity(scanLimits.maximumCandidateDirectories)
        let enumeration = enumerateCandidateDirectories(at: baseDirectory) { candidate in
            insertCandidate(candidate, into: &candidates)
        }
        return CandidateEnumeration(
            candidates: candidates,
            observedCount: enumeration.observedCount,
            wasComplete: enumeration.wasComplete
        )
    }

    /// Visits every top-level directory without retaining the directory listing. Callers choose
    /// their own bounded projection; the returned completeness bit prevents partial enumeration
    /// from being reported as exhaustive.
    private func enumerateCandidateDirectories(
        at baseDirectory: URL,
        visit: (CandidateDirectory) -> Void
    ) -> DirectoryEnumeration {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .contentModificationDateKey,
            .creationDateKey,
        ]
        var wasComplete = true
        guard let enumerator = FileManager.default.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                wasComplete = false
                return true
            }
        ) else {
            return DirectoryEnumeration(observedCount: 0, wasComplete: false)
        }

        var observedCount = 0

        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                wasComplete = false
                continue
            }
            guard values.isDirectory == true else { continue }

            observedCount += 1
            let candidate = CandidateDirectory(
                url: url,
                recency: values.contentModificationDate ?? values.creationDate ?? .distantPast
            )
            visit(candidate)
        }

        return DirectoryEnumeration(
            observedCount: observedCount,
            wasComplete: wasComplete
        )
    }

    private func insertCandidate(
        _ candidate: CandidateDirectory,
        into candidates: inout [CandidateDirectory]
    ) {
        let limit = scanLimits.maximumCandidateDirectories
        guard limit > 0 else { return }

        let insertionIndex = candidates.firstIndex {
            Self.candidatePrecedes(candidate, $0)
        } ?? candidates.endIndex
        if candidates.count < limit {
            candidates.insert(candidate, at: insertionIndex)
        } else if insertionIndex < candidates.endIndex {
            candidates.insert(candidate, at: insertionIndex)
            candidates.removeLast()
        }
    }

    private static func candidatePrecedes(
        _ lhs: CandidateDirectory,
        _ rhs: CandidateDirectory
    ) -> Bool {
        if lhs.recency != rhs.recency {
            return lhs.recency > rhs.recency
        }
        return lhs.url.standardizedFileURL.path < rhs.url.standardizedFileURL.path
    }

    /// Maintains the whole-store retention winners in priority order while using O(limit) memory.
    /// A returned candidate is permanently below the current top-K boundary and can be deleted:
    /// later candidates can only keep or raise that boundary, never make the rejected item win.
    private func insertRetentionCandidate(
        _ candidate: RetentionCandidate,
        into retained: inout [RetentionCandidate],
        limit: Int
    ) -> RetentionCandidate? {
        guard limit > 0 else { return candidate }

        let insertionIndex = retained.firstIndex {
            Self.retentionCandidatePrecedes(candidate, $0)
        } ?? retained.endIndex
        if retained.count < limit {
            retained.insert(candidate, at: insertionIndex)
            return nil
        }
        guard insertionIndex < retained.endIndex else { return candidate }
        retained.insert(candidate, at: insertionIndex)
        return retained.removeLast()
    }

    private static func retentionCandidatePrecedes(
        _ lhs: RetentionCandidate,
        _ rhs: RetentionCandidate
    ) -> Bool {
        if lhs.isRecovery != rhs.isRecovery {
            return lhs.isRecovery
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.directoryURL.standardizedFileURL.path
            < rhs.directoryURL.standardizedFileURL.path
    }

    private func readSession(
        at sessionDirectory: URL,
        issues: inout ArtifactIssueCounts
    ) -> RecoverableVoiceSession? {
        let manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
        let snapshot: VoiceSessionSnapshot
        switch readArtifact(
            VoiceSessionSnapshot.self,
            at: manifestURL,
            maximumBytes: scanLimits.maximumManifestBytes
        ) {
        case .value(let decoded):
            snapshot = decoded
        case .oversized:
            issues.candidateDirectoriesRejected += 1
            issues.oversizedArtifactCount += 1
            return nil
        case .missing, .corrupt:
            issues.candidateDirectoriesRejected += 1
            issues.corruptArtifactCount += 1
            return nil
        }

        // A missing receipt means delivery never committed. An existing receipt that cannot be
        // read does not prove the opposite: its state is unknown, so fail closed instead of
        // surfacing a potentially already-delivered transcript as a recovery.
        let receiptURL = sessionDirectory.appendingPathComponent("delivery-receipt.json")
        let receipt: DeliveryReceipt?
        switch readArtifact(
            DeliveryReceipt.self,
            at: receiptURL,
            maximumBytes: scanLimits.maximumDeliveryReceiptBytes
        ) {
        case .missing:
            receipt = nil
        case .value(let decoded):
            receipt = decoded
        case .oversized:
            issues.candidateDirectoriesRejected += 1
            issues.oversizedArtifactCount += 1
            return nil
        case .corrupt:
            issues.candidateDirectoriesRejected += 1
            issues.corruptArtifactCount += 1
            return nil
        }

        let rawTranscript = optionalArtifactValue(
            readArtifact(
                RawTranscript.self,
                at: sessionDirectory.appendingPathComponent("raw-transcript.json"),
                maximumBytes: scanLimits.maximumRawTranscriptBytes
            ),
            corruptArtifactCount: &issues.corruptArtifactCount,
            oversizedArtifactCount: &issues.oversizedArtifactCount
        )
        let finalTranscript = optionalArtifactValue(
            readArtifact(
                FinalTranscript.self,
                at: sessionDirectory.appendingPathComponent("final-transcript.json"),
                maximumBytes: scanLimits.maximumFinalTranscriptBytes
            ),
            corruptArtifactCount: &issues.corruptArtifactCount,
            oversizedArtifactCount: &issues.oversizedArtifactCount
        )
        let cafURL = sessionDirectory.appendingPathComponent("capture.caf")

        return RecoverableVoiceSession(
            snapshot: snapshot,
            directoryURL: sessionDirectory,
            audioFileURL: FileManager.default.fileExists(atPath: cafURL.path) ? cafURL : nil,
            rawTranscript: rawTranscript,
            finalTranscript: finalTranscript,
            receipt: receipt,
            isDelivered: receipt != nil
        )
    }

    private func readArtifact<Value: Decodable>(
        _ type: Value.Type,
        at url: URL,
        maximumBytes: Int
    ) -> ArtifactRead<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard maximumBytes >= 0, maximumBytes < Int.max else { return .oversized }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .corrupt
        }
        defer { try? handle.close() }

        do {
            let initialSize = try handle.seekToEnd()
            guard initialSize <= UInt64(maximumBytes) else { return .oversized }
            try handle.seek(toOffset: 0)

            var data = Data()
            data.reserveCapacity(min(maximumBytes + 1, 64 * 1_024))
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(remaining, 64 * 1_024)),
                      !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
            guard data.count <= maximumBytes else { return .oversized }
            return .value(try JSONDecoder().decode(type, from: data))
        } catch {
            return .corrupt
        }
    }

    private func optionalArtifactValue<Value>(
        _ artifact: ArtifactRead<Value>,
        corruptArtifactCount: inout Int,
        oversizedArtifactCount: inout Int
    ) -> Value? {
        switch artifact {
        case .missing:
            return nil
        case .value(let value):
            return value
        case .oversized:
            oversizedArtifactCount += 1
            return nil
        case .corrupt:
            corruptArtifactCount += 1
            return nil
        }
    }
}
