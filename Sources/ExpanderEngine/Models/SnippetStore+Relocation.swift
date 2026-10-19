import CryptoKit
import Foundation

extension SnippetStore {
    // MARK: - Store location switching

    /// Writes the library into `directory` and switches to it. A library already there — often
    /// another Mac's, in a shared folder — is kept as a `pre-save-as` backup first; if it cannot
    /// be kept, it is not replaced and the store stays where it was.
    @discardableResult
    public func saveSnippetsAs(toDirectory directory: URL) -> RelocationResult {
        let target = directory.appendingPathComponent(Self.syncedFileName)
        switch replaceForRelocation(at: target, kind: .preSaveAs) {
        case .failure(let message):
            return RelocationResult(success: false, backupURL: nil, message: message, activeLocation: fileURL)
        case .success(let backup):
            deviceDefaults.set(target.path, forKey: DeviceStateKey.storeLocationPath)
            return relocate(to: Location(fileURL: target, expectsExistingLibrary: true), backupURL: backup)
        }
    }

    /// Adopts the library at `target`. Nothing is overwritten — the local file stays where it is —
    /// but what was on screen is kept as a `local-before-link` backup. If that copy cannot be
    /// written the link still proceeds, and `message` says so rather than leaving it unsaid.
    @discardableResult
    public func linkToSnippets(at target: URL) -> RelocationResult {
        var localBackup: URL?
        var message: String?
        do {
            localBackup = try backups.backUp(Self.encodeLibrary(loadGroups()), kind: .localBeforeLink).url
        } catch {
            DevTypeLog.store.error(
                "[Store] No local backup before linking \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            message = "The library on this Mac could not be backed up before linking: \(error.localizedDescription)"
        }
        deviceDefaults.set(target.path, forKey: DeviceStateKey.storeLocationPath)
        return relocate(
            to: Location(fileURL: target, expectsExistingLibrary: true),
            backupURL: localBackup,
            message: message
        )
    }

    /// Copies the library back to the local default file and switches to it. A local library
    /// already there is kept as a `pre-stop-sync` backup first, or it is not replaced.
    @discardableResult
    public func stopSyncing() -> RelocationResult {
        switch replaceForRelocation(at: localDefaultURL, kind: .preStopSync) {
        case .failure(let message):
            return RelocationResult(success: false, backupURL: nil, message: message, activeLocation: fileURL)
        case .success(let backup):
            deviceDefaults.removeObject(forKey: DeviceStateKey.storeLocationPath)
            return relocate(to: Location(fileURL: localDefaultURL, expectsExistingLibrary: false), backupURL: backup)
        }
    }

    private enum RelocationWrite {
        case success(backupURL: URL?)
        case failure(String)
    }

    /// Writes the current library over `target` through the canonical coordinated replace, with
    /// a required safety copy of anything non-empty or unreadable already there.
    private func replaceForRelocation(at target: URL, kind: LibraryBackupStore.Kind) -> RelocationWrite {
        let raw: Data
        do {
            raw = try Self.encodeLibrary(loadGroups())
        } catch {
            DevTypeLog.store.error(
                "[Store] Could not encode the library for relocation \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            return .failure("Could not encode library.")
        }
        switch coordinatedReplace(at: target, with: raw, expecting: nil, backup: .required(kind)) {
        case .written(let backupURL, _):
            return .success(backupURL: backupURL)
        case .unchanged:
            return .success(backupURL: nil)
        case .backupFailed(let message), .failed(let message):
            return .failure(message)
        case .raceDetected:
            // Unreachable without an expected digest; refuse rather than assume.
            return .failure("The destination changed while it was being written.")
        }
    }

    @discardableResult
    private func relocate(to location: Location, backupURL: URL?, message: String? = nil) -> RelocationResult {
        watcher?.stop()
        let previousDirectory = fileURL.deletingLastPathComponent()
        fileURL = location.fileURL
        expectsExistingLibrary = location.expectsExistingLibrary
        Self.setActiveLibraryDirectory(fileURL.deletingLastPathComponent())
        lock.lock()
        _cachedGroups = nil
        lock.unlock()
        // §0.3: a relocation is a fresh start; do not carry a previous file's
        // read failure over to the new location.
        saveBlockLock.lock()
        _hardFailure = nil
        _saveBlocked = nil
        saveBlockLock.unlock()
        let groups = loadGroups()

        // §3.7: images live beside the library. Move them so image snippets keep
        // working after the library moves to (or off) iCloud.
        ImageAttachmentStore.shared.adoptLibraryLocation(
            fileURL,
            migratingFrom: previousDirectory.appendingPathComponent("Images", isDirectory: true)
        )

        watcher = watcherFactory(fileURL)
        startWatching()
        let flat = groups.flatMap(\.snippets)
        lock.lock()
        let snippetListeners = listeners
        let groupListenersCopy = groupListeners
        lock.unlock()
        for listener in snippetListeners.values { listener(flat) }
        for listener in groupListenersCopy.values { listener(groups) }
        return RelocationResult(success: true, backupURL: backupURL, message: message, activeLocation: fileURL)
    }
}
