import Foundation

/// The orphan-secret cleanup hold.
///
/// A blank `snippets.json` loads as an empty library, and a missing local one is seeded with the
/// default snippets. Neither references any secret, and neither says anything about the secrets
/// already stored: a truncated sync, a deleted file, a lost library location or a launch pointed
/// at a fresh directory all look like this, and a deleted keychain value cannot come back from a
/// library backup. So such a load starts a hold. While it is on, cleanup may delete only secrets
/// that an ordinary save newly referenced since the last blank or missing load (`introduced`);
/// every other stored secret is kept.
///
/// The hold survives relaunch through a small record beside the secrets, keyed by the library's
/// canonical path, and shared by every DevType process (the app and the CLI) under a file lock.
/// It ends only when a load decodes a real, conflict-free library whose bytes are not among the
/// files DevType wrote since the hold began — the user's own library put back, synced in from
/// another Mac, or linked. DevType's own writes (the seeded defaults, saves, restores, Save As,
/// Stop Syncing, keeping the local version of a conflict) are fingerprinted into the record
/// *before* the write lands.
struct SecretCleanupHold: Equatable {
    var held = false
    /// Secret IDs that ordinary saves newly referenced since the last blank or missing load.
    var introduced: Set<UUID> = []
    /// SHA-256 of every library file DevType wrote since the hold began, newest last, capped.
    var ownDigests: [String] = []
    /// The record existed but could not be read. Fail closed: the next real load is taken as
    /// DevType's own rather than as a reason to lift.
    var adoptNextRealLoad = false

    /// A hold can last indefinitely. Each digest is ~65 bytes in the record, so 4,096 keeps it
    /// under ~300 KB while covering years of ordinary saves; an own file older than that which
    /// comes back from outside DevType (Time Machine, an old iCloud version) is taken as foreign.
    static let maximumOwnDigests = 4_096

    mutating func noteOwn(_ digest: String) {
        ownDigests.removeAll { $0 == digest }
        ownDigests.append(digest)
        trimOwn()
    }

    mutating func trimOwn() {
        if ownDigests.count > Self.maximumOwnDigests {
            ownDigests.removeFirst(ownDigests.count - Self.maximumOwnDigests)
        }
    }

    /// Another DevType process's view of the same hold, read from the record, as a union. For
    /// `held` and `ownDigests` that only adds protection. For `introduced` it can add permission
    /// to purge: a stale process can write back a secret it introduced that this process's blank
    /// load had since forgotten. That is limited to secrets introduced during the hold, never one
    /// that predates it. The record's order (which every writer has merged) comes first and this
    /// process's own additions after, so stale digests are not re-promoted to newest.
    mutating func merge(_ disk: SecretCleanupHoldRecordState) {
        switch disk {
        case .absent:
            return
        case .unreadable:
            held = true
            adoptNextRealLoad = true
        case .record(let own, let ids):
            held = true
            let onDisk = Set(own)
            ownDigests = own + ownDigests.filter { !onDisk.contains($0) }
            trimOwn()
            introduced.formUnion(ids)
        }
    }
}

enum SecretCleanupHoldRecordState: Equatable {
    case absent
    case unreadable
    case record(own: [String], introduced: Set<UUID>)
}

extension SnippetStore {
    /// Beside the secret archive, not the library: losing the library must not lose the hold.
    public static var defaultSecretCleanupHoldDirectory: URL {
        SupportDirectory.devType.appendingPathComponent("SecretCleanupHolds", isDirectory: true)
    }

    private struct HoldRecord: Codable {
        var version: Int
        var libraryPath: String
        var ownDigests: [String]
        var introduced: [String]
    }

    private static let holdRecordVersion = 1

    /// One spelling per library, stable across launches and processes: the nearest existing
    /// ancestor resolved through `realpath` (so `/var` vs `/private/var`, `/tmp` vs
    /// `/private/tmp`, or a symlinked folder agree whether or not the folder exists yet), the
    /// rest appended, and the whole path case-folded on a case-insensitive volume.
    static func canonicalLibraryPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL.deletingLastPathComponent()
        var tail = [url.lastPathComponent]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        var base: String
        while true {
            if realpath(existing.path, &buffer) != nil {
                base = String(cString: buffer)
                break
            }
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path {
                base = existing.path
                break
            }
            tail.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        let caseSensitive = (try? URL(fileURLWithPath: base)
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? true
        let path = tail.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
        return caseSensitive ? path : path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func cleanupHoldRecordURL(for library: URL) -> URL? {
        guard let directory = secretCleanupHoldDirectory else { return nil }
        let key = Self.sha256(of: Data(Self.canonicalLibraryPath(library).utf8))
        return directory.appendingPathComponent("\(key).json")
    }

    /// How long one process waits for another's record update. The critical section is a small
    /// read-merge-write, so a longer wait means a stopped process (Ctrl-Z, a debugger), and the
    /// caller may hold the store's locks or the main thread.
    private static let crossProcessHoldLockTimeout: TimeInterval = 2

    /// Cross-process exclusion on one library's record (`flock` on a sibling `.lock` file, left
    /// in place: removing it would race another process's open), so the app and the CLI
    /// read-merge-write it one at a time. Bounded: if the lock cannot be taken in time, or the
    /// lock file cannot be opened, the update runs unlocked and logs it. The update still reads
    /// and merges the record first, so the only exposure is a lost merge with a concurrent
    /// writer — never an unbounded hang of the app.
    private func withCrossProcessHoldLock<T>(for library: URL, _ body: () -> T) -> T {
        guard let recordURL = cleanupHoldRecordURL(for: library) else { return body() }
        let lockPath = recordURL.deletingPathExtension().appendingPathExtension("lock").path
        try? FileManager.default.createDirectory(
            at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            DevTypeLog.store.error("[Store] Secret cleanup hold lock could not be opened; updating unlocked")
            return body()
        }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(Self.crossProcessHoldLockTimeout)
        var locked = false
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR, Date() < deadline else { break }
            usleep(5_000)
        }
        guard locked else {
            DevTypeLog.store.error("[Store] Secret cleanup hold lock was not acquired in time; updating unlocked")
            return body()
        }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    private func readCleanupHoldRecord(for library: URL) -> SecretCleanupHoldRecordState {
        guard let recordURL = cleanupHoldRecordURL(for: library),
              FileManager.default.fileExists(atPath: recordURL.path) else { return .absent }
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(HoldRecord.self, from: data),
              record.version == Self.holdRecordVersion else {
            DevTypeLog.store.error("[Store] Secret cleanup hold record is unreadable; keeping the hold")
            return .unreadable
        }
        return .record(own: record.ownDigests, introduced: Set(record.introduced.compactMap(UUID.init(uuidString:))))
    }

    private func writeCleanupHoldRecord(_ hold: SecretCleanupHold, for library: URL) {
        guard let recordURL = cleanupHoldRecordURL(for: library) else { return }
        let fm = FileManager.default
        do {
            if hold.held {
                try fm.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let record = HoldRecord(
                    version: Self.holdRecordVersion,
                    libraryPath: Self.canonicalLibraryPath(library),
                    ownDigests: hold.ownDigests,
                    introduced: hold.introduced.map(\.uuidString).sorted()
                )
                try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
            } else if fm.fileExists(atPath: recordURL.path) {
                try fm.removeItem(at: recordURL)
            }
        } catch {
            // In memory the hold still applies for this session; only relaunch protection is lost.
            DevTypeLog.store.error(
                "[Store] Could not update the secret cleanup hold record \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
        }
    }

    /// At init, before the first load.
    func restoreCleanupHoldFromRecord() {
        updateCleanupHold { _ in }
    }

    /// The one place the hold changes. Inside the in-process and cross-process locks: read the
    /// record (another DevType process may have extended it), merge it into memory, apply
    /// `change`, then write the result back. Memory is touched only under `digestLock`, which
    /// purge reads. `alsoRecordAt` writes the record for a second path too — the target of
    /// Save As / Stop Syncing, before that write lands.
    func updateCleanupHold(alsoRecordAt extra: URL? = nil, _ change: (inout SecretCleanupHold) -> Void) {
        cleanupHoldRecordLock.lock()
        defer { cleanupHoldRecordLock.unlock() }
        let library = fileURL
        guard secretCleanupHoldDirectory != nil else {
            digestLock.lock()
            change(&cleanupHold)
            digestLock.unlock()
            return
        }
        let after: SecretCleanupHold = withCrossProcessHoldLock(for: library) {
            let disk = readCleanupHoldRecord(for: library)
            digestLock.lock()
            cleanupHold.merge(disk)
            change(&cleanupHold)
            let after = cleanupHold
            digestLock.unlock()
            if after.held || disk != .absent {
                writeCleanupHoldRecord(after, for: library)
            }
            return after
        }
        if let extra, after.held, Self.canonicalLibraryPath(extra) != Self.canonicalLibraryPath(library) {
            withCrossProcessHoldLock(for: extra) {
                var combined = after
                combined.merge(readCleanupHoldRecord(for: extra))
                writeCleanupHoldRecord(combined, for: extra)
            }
        }
    }

    /// Every load decides the hold. A blank or missing file starts it, or — when it is already
    /// on — forgets what the session introduced (the lost library may still reference those)
    /// while keeping the fingerprints of DevType's own writes: an evicted iCloud file that comes
    /// back is still DevType's. A real, conflict-free document DevType did not write lifts it.
    /// An unreadable, corrupt or conflicted read changes nothing.
    func updateCleanupHold(afterLoading loaded: Loaded) {
        updateCleanupHold { hold in
            if loaded.isBlank || !loaded.fileWasPresent {
                hold.held = true
                hold.introduced = []
                return
            }
            guard hold.held,
                  loaded.decodeSucceeded, loaded.hardFailure == nil, loaded.conflicts.isEmpty,
                  case .sha(let digest) = loaded.digest else { return }
            if hold.adoptNextRealLoad {
                hold.adoptNextRealLoad = false
                hold.noteOwn(digest)
            } else if !hold.ownDigests.contains(digest) {
                hold = SecretCleanupHold()
            }
        }
    }

    /// Write-ahead: called before any whole-library write lands, with the exact bytes.
    func noteOwnLibraryWrite(_ data: Data, at target: URL) {
        let digest = Self.sha256(of: data)
        updateCleanupHold(alsoRecordAt: target) { hold in
            guard hold.held else { return }
            hold.noteOwn(digest)
        }
    }

    /// While the hold is on, an ordinary save records the secret IDs it newly referenced, so
    /// that deleting one of those snippets later can still purge its value. Restores and other
    /// recovery writes do not record: what they bring back predates the hold.
    func noteSecretsIntroducedDuringHold(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        updateCleanupHold { hold in
            guard hold.held else { return }
            hold.introduced.formUnion(ids)
        }
    }

    /// A relocation moves the hold with the library: `fileURL` already names the new path. The
    /// record for the new path is written (merged with any record already there) before the old
    /// one is removed.
    func moveCleanupHoldRecord(from previous: URL) {
        guard secretCleanupHoldDirectory != nil,
              Self.canonicalLibraryPath(previous) != Self.canonicalLibraryPath(fileURL) else { return }
        digestLock.lock()
        let wasHeld = cleanupHold.held
        digestLock.unlock()
        guard wasHeld else { return }
        updateCleanupHold { _ in }
        cleanupHoldRecordLock.lock()
        defer { cleanupHoldRecordLock.unlock() }
        withCrossProcessHoldLock(for: previous) {
            writeCleanupHoldRecord(SecretCleanupHold(), for: previous)
        }
    }

    /// Cleanup policy for one orphaned secret: always, unless the hold is on and the secret was
    /// not introduced during it.
    func mayPurgeOrphanSecret(_ id: UUID) -> Bool {
        digestLock.lock()
        defer { digestLock.unlock() }
        return !cleanupHold.held || cleanupHold.introduced.contains(id)
    }

    var isSecretCleanupHeld: Bool {
        digestLock.lock()
        defer { digestLock.unlock() }
        return cleanupHold.held
    }
}
