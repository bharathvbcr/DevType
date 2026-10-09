import Foundation

/// The conflict resolver's disk transaction. The store owns mutation serialization and file
/// coordination; this object has no independent lifetime, cache, or background work.
enum LibraryConflictRecovery {
    struct Version {
        let url: URL
        let remove: () throws -> Void
    }

    struct IO {
        var read: (URL) throws -> Data = boundedRead
        var write: (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }
    }

    enum Outcome {
        case adoptionFailed(String, recoveryURL: URL?)
        case adopted(Data, recoveryURL: URL, cleanupPending: String?)
    }

    struct Journal: Codable {
        let libraryPath: String
        let versionCount: Int
        let selectedLocal: Bool
        var phase: String
    }

    enum Failure: Error {
        case missingCandidate, tooManyVersions, oversizedCandidate, recoveryMismatch, adoptionMismatch
    }

    static let maximumCandidateBytes = 64 * 1024 * 1024
    static let maximumRecoveryBytes = 256 * 1024 * 1024
    static let maximumVersions = 32

    static func boundedRead(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        var data = Data()
        do {
            while let chunk = try handle.read(upToCount: min(65_536, maximumCandidateBytes + 1 - data.count)),
                  !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= maximumCandidateBytes else { throw Failure.oversizedCandidate }
            }
        } catch {
            try handle.close()
            throw error
        }
        try handle.close()
        return data
    }

    private static func persist(_ journal: Journal, in folder: URL, io: IO) throws {
        let data = try JSONEncoder().encode(journal)
        let url = folder.appendingPathComponent("recovery.json")
        try io.write(data, url)
        guard try io.read(url) == data else { throw Failure.recoveryMismatch }
    }

    /// Every alternative is copied and read back before adoption. Failed removals remain
    /// unresolved in the version store, so a fresh process can retry without a hidden queue.
    /// Recovery folders are retained on success as well as failure; `prune(recoveryRoot:)` bounds
    /// them afterwards, never during a resolution.
    static func resolve(
        fileURL: URL, recoveryRoot: URL, localCandidate: Data?, versions: [Version],
        io: IO = IO(), validate: (Data) throws -> Void
    ) -> Outcome {
        var recoveryURL: URL?
        var chosen: Data
        var journal: Journal
        do {
            guard versions.count <= maximumVersions else { throw Failure.tooManyVersions }
            let original = FileManager.default.fileExists(atPath: fileURL.path) ? try io.read(fileURL) : nil
            guard let candidate = localCandidate ?? original else { throw Failure.missingCandidate }
            guard candidate.count <= maximumCandidateBytes else { throw Failure.oversizedCandidate }
            try validate(candidate)
            chosen = candidate
            var copies: [(String, Data)] = [("selected.json", candidate)]
            if let original { copies.append(("current-before.json", original)) }
            var total = copies.reduce(0) { $0 + $1.1.count }
            for (index, version) in versions.enumerated() {
                let data = try io.read(version.url)
                guard data.count <= maximumCandidateBytes,
                      data.count <= maximumRecoveryBytes - total else { throw Failure.oversizedCandidate }
                total += data.count
                copies.append(("alternative-\(index).json", data))
            }
            let folder = recoveryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            recoveryURL = folder
            for (name, data) in copies {
                let destination = folder.appendingPathComponent(name)
                try io.write(data, destination)
                guard try io.read(destination) == data else { throw Failure.recoveryMismatch }
            }
            journal = Journal(libraryPath: fileURL.path, versionCount: versions.count,
                              selectedLocal: localCandidate != nil, phase: "prepared")
            try persist(journal, in: folder, io: io)
            // Remote adoption validates and keeps the exact current bytes. Local adoption writes
            // only after all alternatives have a verified recovery copy.
            if localCandidate != nil { try io.write(candidate, fileURL) }
            guard try io.read(fileURL) == candidate else { throw Failure.adoptionMismatch }
        } catch {
            return .adoptionFailed("Library adoption could not be verified: \(error.localizedDescription)", recoveryURL: recoveryURL)
        }

        guard let folder = recoveryURL else {
            return .adoptionFailed("Recovery folder was not prepared", recoveryURL: nil)
        }
        do {
            journal.phase = "adopted"
            try persist(journal, in: folder, io: io)
            for version in versions {
                guard try io.read(fileURL) == chosen else { throw Failure.adoptionMismatch }
                // Remove only the captured object. Do not mark it resolved first: a failed
                // removal must remain visible as an unresolved conflict across restart.
                try version.remove()
            }
            journal.phase = "complete"
            try persist(journal, in: folder, io: io)
            return .adopted(chosen, recoveryURL: folder, cleanupPending: nil)
        } catch {
            return .adopted(chosen, recoveryURL: folder,
                            cleanupPending: "Library adopted; alternate-version cleanup is pending: \(error.localizedDescription)")
        }
    }

    // MARK: - Retention

    /// Content-free accounting for one pass; safe for logs and the diagnostic report.
    struct PruneReport: Equatable {
        /// Folders still on disk after the pass, whatever kept them.
        var retained = 0
        var removed = 0
        /// Kept because an adoption that references them still has cleanup pending.
        var referenced = 0
        /// Kept because their age or journal could not be read; never guessed at.
        var skipped = 0
        /// Kept because removal failed; the next pass retries.
        var failed = 0
        /// False when the recovery root could not be listed at all; counts are then zero, not
        /// a measurement.
        var enumerationComplete = true
    }

    static let retainedNewestFolders = 10
    static let retainedFolderAge: TimeInterval = 30 * 24 * 60 * 60

    /// Bounds the recovery folders `resolve` leaves behind, after `VoiceRecoveryService.prune`.
    ///
    /// Kept: the `keepingNewest` newest removable folders, every folder younger than `maxAge`,
    /// every folder whose journal is still in the `adopted` phase (an adoption whose alternate-
    /// version cleanup is pending refers to it), and every folder whose creation date or journal
    /// cannot be read — those are skipped, not removed, and the pass carries on. Everything else
    /// is removed. Only directories directly under `recoveryRoot` are considered.
    @discardableResult
    static func prune(
        recoveryRoot: URL,
        now: Date = Date(),
        keepingNewest: Int = retainedNewestFolders,
        maxAge: TimeInterval = retainedFolderAge
    ) -> PruneReport {
        var report = PruneReport()
        let fm = FileManager.default
        guard fm.fileExists(atPath: recoveryRoot.path) else { return report }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey]
        let folders: [URL]
        do {
            folders = try fm.contentsOfDirectory(
                at: recoveryRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            report.enumerationComplete = false
            DevTypeLog.store.error(
                "[ConflictRecovery] Could not list recovery folders \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            return report
        }

        var removable: [(url: URL, createdAt: Date)] = []
        for folder in folders {
            guard let values = try? folder.resourceValues(forKeys: keys) else {
                report.skipped += 1
                continue
            }
            guard values.isDirectory == true else { continue }
            guard let createdAt = values.creationDate,
                  let journalData = try? boundedRead(folder.appendingPathComponent("recovery.json")),
                  let journal = try? JSONDecoder().decode(Journal.self, from: journalData) else {
                report.skipped += 1
                continue
            }
            if journal.phase == "adopted" {
                report.referenced += 1
                continue
            }
            removable.append((folder, createdAt))
        }

        removable.sort { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.url.path < rhs.url.path
        }
        var kept = 0
        for (index, candidate) in removable.enumerated() {
            if index < max(0, keepingNewest) || now.timeIntervalSince(candidate.createdAt) < maxAge {
                kept += 1
                continue
            }
            do {
                try fm.removeItem(at: candidate.url)
                report.removed += 1
            } catch {
                report.failed += 1
                DevTypeLog.store.error(
                    "[ConflictRecovery] Could not remove a recovery folder \(DevTypeLog.errorMetadata(error), privacy: .public)"
                )
            }
        }
        report.retained = kept + report.referenced + report.skipped + report.failed
        if report.removed > 0 || report.failed > 0 || report.skipped > 0 {
            DevTypeLog.store.info(
                "[ConflictRecovery] prune retained=\(report.retained, privacy: .public) removed=\(report.removed, privacy: .public) referenced=\(report.referenced, privacy: .public) skipped=\(report.skipped, privacy: .public) failed=\(report.failed, privacy: .public)"
            )
        }
        return report
    }
}
