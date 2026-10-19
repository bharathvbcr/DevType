import CryptoKit
import Foundation

extension SnippetStore {
    // MARK: - Reading (§0.3 / §1.13)

    /// §0.3: `fileExists(atPath:)` returns false for an evicted iCloud item, which
    /// is how a synced library used to look "missing" and get replaced with demos.
    /// Ask iCloud to materialize it — but do **not** block the caller waiting for
    /// the bytes: this used to busy-wait up to `timeout` on the calling thread,
    /// which `init` reaches synchronously and stalled launches for the full two
    /// seconds. The bounded wait lives in `scheduleMaterializationReload()`, which
    /// polls on a utility queue and reloads when the file lands.
    ///
    /// - Returns: whether the file exists *right now*.
    @discardableResult
    static func materializeIfNeeded(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }

        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        let hasPlaceholder = fm.fileExists(atPath: placeholder.path)
        guard hasPlaceholder || isUbiquitousLocation(url) else { return false }

        do {
            try fm.startDownloadingUbiquitousItem(at: url)
        } catch {
            DevTypeLog.store.error(
                "[Store] startDownloadingUbiquitousItem failed \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            return false
        }
        DevTypeLog.store.notice(
            "[Store] Requested iCloud download of \(url.lastPathComponent, privacy: .public); reload scheduled when it materializes"
        )
        return false
    }

    /// True when the library file is absent but an iCloud download has plausibly
    /// been requested for it (evicted-item placeholder present, or the path sits in
    /// a ubiquity container) — the state where waiting on a background queue can
    /// still produce a library.
    static func isPotentiallyMaterializing(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return false }
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fm.fileExists(atPath: placeholder.path) || isUbiquitousLocation(url)
    }

    /// Polls for the library file on `materializeQueue` until it appears or
    /// `ubiquitousDownloadTimeout` elapses, then reloads from disk exactly like an
    /// external change. Deduped by generation: a newer schedule supersedes the
    /// polls of every older one, so repeated calls while the file is still absent
    /// never stack waits.
    func scheduleMaterializationReload() {
        materializationLock.lock()
        materializationGeneration &+= 1
        let generation = materializationGeneration
        materializationLock.unlock()

        let deadline = Date().addingTimeInterval(max(0, Self.ubiquitousDownloadTimeout))
        let interval = 0.1
        materializeQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            while Date() < deadline {
                if fm.fileExists(atPath: self.fileURL.path) {
                    self.reloadFromDisk()
                    return
                }
                materializationLock.lock()
                let superseded = generation != self.materializationGeneration
                materializationLock.unlock()
                if superseded { return }
                Thread.sleep(forTimeInterval: interval)
            }
            if fm.fileExists(atPath: self.fileURL.path) {
                self.reloadFromDisk()
            }
        }
    }

    /// §1.13: coordinated read so we never observe a half-written or
    /// mid-sync file.
    private static func coordinatedRead(at url: URL) throws -> Data {
        var result: Data?
        var readError: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { actualURL in
            do {
                result = try Data(contentsOf: actualURL)
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return result
    }

    static func loadFrom(_ location: Location, backups: LibraryBackupStore) -> Loaded {
        var out = Loaded()
        let url = location.fileURL

        guard materializeIfNeeded(url) else {
            if location.expectsExistingLibrary {
                out.blocked = .failed("Library not available at configured location")
            }
            return out
        }
        out.fileWasPresent = true
        out.conflicts = unresolvedConflicts(at: url)
        if !out.conflicts.isEmpty {
            out.loadIssue = .conflicted(path: url.path, versionCount: out.conflicts.count)
        }

        let raw: Data
        do {
            raw = try coordinatedRead(at: url)
        } catch {
            DevTypeLog.store.error(
                "[Store] Failed to read snippets \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            out.digest = .unreadable
            out.loadIssue = .unreadable(path: url.path, reason: error.localizedDescription)
            out.hardFailure = .failed("Could not read \(url.path): \(error.localizedDescription)")
            return out
        }

        out.digest = .sha(sha256(of: raw))

        let isBlank: Bool
        if let first = firstNonWhitespaceByte(in: raw),
           first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            // A JSON document is never blank; skip the whole-file String conversion.
            isBlank = false
        } else {
            isBlank = raw.isEmpty
                || String(data: raw, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
        }
        if isBlank {
            // An empty file is a legitimate (if suspicious) empty library — never
            // a reason to write demo snippets. Surface it instead.
            out.loadIssue = out.loadIssue ?? .emptyFile(path: url.path)
            out.decodeSucceeded = true
            return out
        }

        do {
            let document = try decodeDocument(from: raw)
            out.groups = document.transactionGroups
            out.decodeSucceeded = true
            if document.schemaVersion > SnippetDocument.currentSchemaVersion {
                out.blocked = .blockedByNewerSchema
            }
        } catch {
            DevTypeLog.store.error(
                "[Store] Failed to decode snippets \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            // §0.3: timestamped and never overwritten (the old single `.bak` was deleted by
            // the next failed load). Identical bytes from a repeated failed load reuse the
            // existing copy rather than adding one per watcher event.
            if let backupURL = try? backups.backUp(raw, kind: .corrupted).url {
                out.loadIssue = .corrupted(backupURL: backupURL)
            } else {
                out.loadIssue = .unreadable(path: url.path, reason: error.localizedDescription)
            }
            out.hardFailure = .failed("Could not decode \(url.path): \(error.localizedDescription)")
        }
        return out
    }
}
