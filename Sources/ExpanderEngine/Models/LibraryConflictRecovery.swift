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
    /// Recovery folders are retained on success as well as failure; none are auto-pruned here.
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
}
