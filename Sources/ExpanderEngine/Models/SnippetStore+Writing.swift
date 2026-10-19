import CryptoKit
import Foundation

extension SnippetStore {
    // MARK: - Writing

    /// What a write must do with the bytes it replaces.
    enum BackupRequirement {
        /// An ordinary save: copy the previous bytes into a rolling backup when they changed.
        /// Failing to copy does not stop the save; it is reported as `.savedWithoutBackup`. A file
        /// that cannot be read at all is escalated to `.required(.preOverwrite)`, because
        /// overwriting bytes nobody can read again is not a save the user asked for. The live
        /// file stays in place until the replacement commits.
        case rolling
        /// A replacement the user confirmed, or one onto a library they did not write here: the
        /// previous file must be preserved first, or nothing is written.
        case required(LibraryBackupStore.Kind)
    }

    enum ReplaceResult {
        case written(backupURL: URL?, backupFailure: String?)
        /// The file already held exactly these bytes; nothing was written or copied.
        case unchanged
        case raceDetected
        case backupFailed(String)
        case failed(String)
    }

    /// The one coordinated replace every whole-library write goes through: saves, the forced
    /// overwrite, and Save As / Stop Syncing onto an existing file.
    ///
    /// §1.13: the digest re-check, the backup and the write happen inside one coordinated write
    /// block, so no other coordinated reader or writer (another DevType, iCloud, Finder) can land
    /// between them. The bytes read for the digest are the bytes backed up.
    func coordinatedReplace(
        at url: URL,
        with data: Data,
        expecting expectedDigest: FileDigest?,
        backup requirement: BackupRequirement
    ) -> ReplaceResult {
        var result: ReplaceResult = .failed("File coordination did not run")
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: url,
            options: [.forReplacing],
            error: &coordinationError
        ) { actualURL in
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: actualURL.path)
            let onDisk = exists ? try? Data(contentsOf: actualURL) : nil
            if let expectedDigest {
                let digest: FileDigest = !exists
                    ? .absent
                    : onDisk.map { FileDigest.sha(Self.sha256(of: $0)) } ?? .unreadable
                guard digest == expectedDigest else {
                    result = .raceDetected
                    return
                }
            }
            if let onDisk, onDisk == data {
                result = .unchanged
                return
            }

            var backupURL: URL?
            var backupFailure: String?
            var createdBackup = false
            var revealAfterCommit = false
            let required: LibraryBackupStore.Kind?
            switch requirement {
            case .required(let kind): required = kind
            case .rolling: required = exists && onDisk == nil ? .preOverwrite : nil
            }
            if let required {
                do {
                    let preserved = try self.backups.preserve(fileAt: actualURL, bytes: onDisk, kind: required)
                    backupURL = preserved?.url
                    createdBackup = preserved?.created ?? false
                    revealAfterCommit = preserved?.revealAfterCommit ?? false
                } catch {
                    result = .backupFailed(
                        "The existing library was not replaced because a backup of it could not be saved: \(error.localizedDescription)"
                    )
                    return
                }
            } else if let onDisk, !onDisk.isEmpty {
                do {
                    let copy = try self.backups.backUp(onDisk, kind: .save)
                    backupURL = copy.url
                    if copy.created { self.backups.schedulePrune() }
                } catch {
                    backupFailure = error.localizedDescription
                }
            }

            do {
                try fm.createDirectory(at: actualURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: actualURL, options: .atomic)
                if revealAfterCommit, let backupURL {
                    self.backups.reveal(backupURL)
                }
                result = .written(backupURL: backupURL, backupFailure: backupFailure)
            } catch {
                if createdBackup, let backupURL, self.backupGuardsNothing(backupURL, live: actualURL, previous: onDisk) {
                    // The library is exactly as it was, so the safety copy guards nothing. When the
                    // live file changed (or cannot be re-read) the copy is kept. A hard link shares
                    // the live inode: dropping the backup name leaves the pre-overwrite bytes in place.
                    self.backups.discard(backupURL)
                }
                DevTypeLog.store.error(
                    "[Store] Failed to write library \(DevTypeLog.errorMetadata(error), privacy: .public)"
                )
                result = .failed(error.localizedDescription)
            }
        }
        if let coordinationError {
            DevTypeLog.store.error(
                "[Store] File coordination failed while writing \(DevTypeLog.errorMetadata(coordinationError), privacy: .public)"
            )
            return .failed(coordinationError.localizedDescription)
        }
        return result
    }

    /// The safety copy can be removed because the live path still holds the bytes it was taken from.
    private func backupGuardsNothing(_ backup: URL, live: URL, previous: Data?) -> Bool {
        if backups.sameInode(backup, live) { return true }
        guard let previous else { return false }
        return (try? Data(contentsOf: live)).map { Self.sha256(of: $0) } == Self.sha256(of: previous)
    }

    struct DiskWrite {
        let outcome: SaveOutcome
        let backupURL: URL?
    }

    /// `force` skips the save block and the digest guard, and in exchange requires a safety copy
    /// of whatever it replaces — so the forced overwrite and the first-run seed cannot reach the
    /// file without the backup step, whichever caller they come from.
    @discardableResult
    func writeGroupsToDisk(
        _ groups: [SnippetGroup],
        force: Bool = false,
        bypassHardFailure: Bool = false,
        safetyKind: LibraryBackupStore.Kind? = nil
    ) -> DiskWrite {
        // §0.3: a latched read failure refuses even forced writes. Only
        // `forceOverwriteLibrary` / conflict resolution may bypass it.
        if !bypassHardFailure, let hard = hardFailure() { return DiskWrite(outcome: hard, backupURL: nil) }
        if !force, let blocked = blockedReason() { return DiskWrite(outcome: blocked, backupURL: nil) }

        let data: Data
        do {
            data = try Self.encodeLibrary(groups)
        } catch {
            DevTypeLog.store.error(
                "[Store] Failed to encode snippets \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            return DiskWrite(outcome: .failed(error.localizedDescription), backupURL: nil)
        }

        let replaced = coordinatedReplace(
            at: fileURL,
            with: data,
            expecting: force ? nil : lastKnownDigest(),
            backup: force || safetyKind != nil ? .required(safetyKind ?? .preOverwrite) : .rolling
        )
        let outcome: SaveOutcome
        var backupURL: URL?
        switch replaced {
        case .raceDetected:
            saveBlockLock.lock()
            _saveBlocked = .blockedByRemoteChange
            saveBlockLock.unlock()
            return DiskWrite(outcome: .blockedByRemoteChange, backupURL: nil)
        case .backupFailed(let reason), .failed(let reason):
            return DiskWrite(outcome: .failed(reason), backupURL: nil)
        case .unchanged:
            outcome = .saved
        case .written(let url, let backupFailure):
            backupURL = url
            outcome = backupFailure.map(SaveOutcome.savedWithoutBackup) ?? .saved
        }

        setLastKnownDigest(.sha(Self.sha256(of: data)))
        saveBlockLock.lock()
        _saveBlocked = nil
        saveBlockLock.unlock()
        return DiskWrite(outcome: outcome, backupURL: backupURL)
    }

    func blockedReason() -> SaveOutcome? {
        saveBlockLock.lock()
        defer { saveBlockLock.unlock() }
        return _hardFailure ?? _saveBlocked
    }

    func hardFailure() -> SaveOutcome? {
        saveBlockLock.lock()
        defer { saveBlockLock.unlock() }
        return _hardFailure
    }

    func lastKnownDigest() -> FileDigest {
        digestLock.lock()
        defer { digestLock.unlock() }
        return savedDigest
    }

    func setLastKnownDigest(_ digest: FileDigest) {
        digestLock.lock()
        savedDigest = digest
        digestLock.unlock()
    }

    static func sha256(of data: Data) -> String {
        hexString(of: SHA256.hash(data: data))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Lowercase hex of a digest, built from a lookup table rather than one `String(format:)`
    /// (a varargs formatter plus a heap string) per byte.
    static func hexString<D: Sequence>(of bytes: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func currentDigest(at url: URL) -> FileDigest {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let raw = try? Data(contentsOf: url) else { return .unreadable }
        return .sha(sha256(of: raw))
    }
}
