import CryptoKit
import Foundation

extension SnippetStore {
    // MARK: - Conflicts (§1.13)

    /// §1.13: iCloud conflict versions detected by the last load. Non-empty means
    /// the cache was deliberately *not* replaced from disk.
    public func pendingConflicts() -> [ConflictVersion] {
        saveBlockLock.lock()
        defer { saveBlockLock.unlock() }
        return _pendingConflicts
    }

    /// Re-queries the file system rather than using the cached snapshot.
    public func unresolvedConflicts() -> [ConflictVersion] {
        Self.unresolvedConflicts(at: fileURL)
    }

    public enum ConflictChoice { case local, remote }

    public enum ConflictResolutionOutcome: Equatable {
        case adoptionFailed(String, recoveryURL: URL?)
        case adopted(recoveryURL: URL)
        case adoptedCleanupPending(String, recoveryURL: URL)

        public var didAdopt: Bool {
            if case .adoptionFailed = self { return false }
            return true
        }
    }

    /// Compatibility adapters. UI callers use the typed result to surface pending cleanup.
    @discardableResult
    public func resolveConflictsKeepingLocal() -> SaveOutcome {
        switch resolveConflicts(keeping: .local) {
        case .adoptionFailed(let message, _): return .failed(message)
        case .adopted, .adoptedCleanupPending: return .saved
        }
    }

    @discardableResult
    public func resolveConflictsKeepingRemote() -> Bool {
        resolveConflicts(keeping: .remote).didAdopt
    }

    /// Capture, recovery copies, verified adoption, and version cleanup share the same mutation
    /// lock and coordinated write. Observers are dispatched after releasing those boundaries.
    @discardableResult
    public func resolveConflicts(keeping choice: ConflictChoice) -> ConflictResolutionOutcome {
        rmwLock.lock()
        let result = resolveConflictsSerialized(keeping: choice)
        rmwLock.unlock()
        // A verified adoption is the moment a new recovery folder lands; bound them now, off the
        // mutation lock. A failed adoption leaves nothing new worth pruning around.
        switch result {
        case .adopted, .adoptedCleanupPending: scheduleConflictRecoveryPrune(completion: nil)
        case .adoptionFailed: break
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyConflictListeners()
            if case .adoptionFailed(let message, _) = result {
                self.publishSaveFailure(.failed(message))
            } else {
                self.publishSaveFailure(nil)
                let groups = self.loadGroups()
                let observers = self.lock.withLock { (self.listeners, self.groupListeners) }
                let flat = Self.expandableSnippets(in: groups)
                for listener in observers.0.values { listener(flat) }
                for listener in observers.1.values { listener(groups) }
            }
        }
        return result
    }

    private func resolveConflictsSerialized(keeping choice: ConflictChoice) -> ConflictResolutionOutcome {
        let local: Data?
        do {
            local = choice == .local ? try Self.encodeLibrary(Self.sanitizeGroups(loadGroups())) : nil
        } catch { return .adoptionFailed(error.localizedDescription, recoveryURL: nil) }
        var result: LibraryConflictRecovery.Outcome?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: fileURL, options: [.forReplacing], error: &coordinationError) { url in
            let versions = (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map { version in
                LibraryConflictRecovery.Version(url: version.url, remove: { try version.remove() })
            }
            result = LibraryConflictRecovery.resolve(
                fileURL: url, recoveryRoot: conflictRecoveryRoot,
                localCandidate: local, versions: versions
            ) { data in
                let document = try Self.decodeDocument(from: data)
                guard document.schemaVersion <= SnippetDocument.currentSchemaVersion else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
        guard let result else {
            return .adoptionFailed(coordinationError?.localizedDescription ?? "File coordination did not run", recoveryURL: nil)
        }
        switch result {
        case .adoptionFailed(let reason, let recoveryURL):
            return .adoptionFailed(reason, recoveryURL: recoveryURL)
        case .adopted(let data, let recoveryURL, let cleanupPending):
            // Validation above guarantees decoding; still fail visibly if that contract changes.
            let document: SnippetDocument
            do { document = try Self.decodeDocument(from: data) }
            catch { return .adoptionFailed(error.localizedDescription, recoveryURL: recoveryURL) }
            let remaining = Self.unresolvedConflicts(at: fileURL)
            storePendingConflicts(remaining)
            let pending = cleanupPending ?? coordinationError?.localizedDescription
                ?? (remaining.isEmpty ? nil : "Library adopted; additional conflict versions require review")
            setLastKnownDigest(.sha(Self.sha256(of: data)))
            saveBlockLock.lock()
            _hardFailure = nil
            _saveBlocked = pending == nil ? nil : .blockedByRemoteChange
            saveBlockLock.unlock()
            lock.lock()
            _cachedGroups = document.transactionGroups
            _lastLoadIssue = remaining.isEmpty ? nil : .conflicted(path: fileURL.path, versionCount: remaining.count)
            lock.unlock()
            if let pending { return .adoptedCleanupPending(pending, recoveryURL: recoveryURL) }
            return .adopted(recoveryURL: recoveryURL)
        }
    }

    /// Launch-time housekeeping for everything the store keeps for recovery: rolling library
    /// backups and conflict-recovery folders. Both run on utility queues; a failure is logged and
    /// retried by the next trigger.
    public func scheduleRecoveryMaintenance() {
        backups.schedulePrune()
        scheduleConflictRecoveryPrune(completion: nil)
    }

    /// Conflict-recovery folders still on disk after the last prune pass, or `nil` before any
    /// pass has completed (or when the folder could not be listed) — never a guessed zero.
    public var conflictRecoveryRetainedFolderCount: Int? {
        conflictRecoveryPruneLock.lock()
        defer { conflictRecoveryPruneLock.unlock() }
        guard let report = _lastConflictRecoveryPrune, report.enumerationComplete else { return nil }
        return report.retained
    }

    func scheduleConflictRecoveryPrune(completion: ((LibraryConflictRecovery.PruneReport) -> Void)?) {
        let root = conflictRecoveryRoot
        conflictRecoveryPruneQueue.async { [weak self] in
            let report = LibraryConflictRecovery.prune(recoveryRoot: root)
            if let self {
                self.conflictRecoveryPruneLock.lock()
                self._lastConflictRecoveryPrune = report
                self.conflictRecoveryPruneLock.unlock()
            }
            completion?(report)
        }
    }

    /// Stores the snapshot without notifying. Safe to call while `lock` is held
    /// (`loadGroupsUnlocked` does) — it only touches `saveBlockLock`.
    @discardableResult
    func storePendingConflicts(_ conflicts: [ConflictVersion]) -> Bool {
        saveBlockLock.lock()
        let changed = _pendingConflicts != conflicts
        _pendingConflicts = conflicts
        saveBlockLock.unlock()
        return changed
    }

    static func unresolvedConflicts(at url: URL) -> [ConflictVersion] {
        guard FileManager.default.fileExists(atPath: url.path),
              let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !versions.isEmpty else {
            return []
        }
        return versions.map {
            ConflictVersion(
                url: $0.url,
                modificationDate: $0.modificationDate,
                deviceName: $0.localizedNameOfSavingComputer
            )
        }
    }
}
