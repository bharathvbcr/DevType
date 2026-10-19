import CryptoKit
import Foundation

extension SnippetStore {
    // MARK: - External change detection (§2.5)

    func startWatching() {
        guard let watcher else { return }
        watcher.onChange = { [weak self] in
            self?.externalChangeDetected()
        }
        watcher.start()
    }

    /// §2.5: every one of our own writes trips `DirectoryWatcher`. This used to
    /// hop straight to main and do a full-file read + SHA256 there, with no
    /// debounce. Now the event is coalesced and the digest runs on a utility queue.
    func externalChangeDetected() {
        externalStateLock.lock()
        externalChangeGeneration &+= 1
        let generation = externalChangeGeneration
        externalStateLock.unlock()

        coalesceQueue.asyncAfter(deadline: .now() + Self.externalChangeDebounce) { [weak self] in
            guard let self else { return }
            self.externalStateLock.lock()
            let isCurrent = generation == self.externalChangeGeneration
            let applying = self._isApplyingExternalState
            self.externalStateLock.unlock()
            // Reentrancy guard: an apply in flight is generating these events itself.
            guard isCurrent, !applying else { return }

            let onDisk = Self.currentDigest(at: self.fileURL)
            // Self-writes update `savedDigest` before the watcher fires, so they
            // are filtered out here and never round-trip through the cache.
            guard onDisk != self.lastKnownDigest() else { return }

            // The full coordinated read + SHA256 + JSON decode runs right here on
            // the coalesce/io queue — it used to be dispatched to main, stalling
            // the UI for large libraries. `reloadFromDisk` keeps only the cache
            // swap and listener notifications on main.
            self.reloadFromDisk()
        }
    }

    /// Reloads the library from disk and adopts it.
    ///
    /// Threading: the heavy work (coordinated read, SHA256, JSON decode) runs on
    /// the **calling** queue — the external-change path invokes this on
    /// `coalesceQueue` and the materialization wait on `materializeQueue`, never
    /// on main. Only listener notifications hop to main: every listener contract
    /// in this store is main-thread. State latches (`_saveBlocked`,
    /// `_hardFailure`, pending conflicts, `_lastLoadIssue`) stay synchronous so a
    /// caller that resolves conflicts and immediately re-checks sees consistent
    /// answers.
    func reloadFromDisk() {
        externalStateLock.lock()
        if _isApplyingExternalState {
            externalStateLock.unlock()
            return
        }
        _isApplyingExternalState = true
        externalStateLock.unlock()
        defer {
            externalStateLock.lock()
            _isApplyingExternalState = false
            externalStateLock.unlock()
        }

        // A reload is another whole-library writer: advancing the remembered digest and cache
        // while a mutation is paused after reading would let that stale mutation pass its digest
        // guard and overwrite the just-adopted external bytes. Share the complete RMW boundary.
        invokeConcurrencyProbe(\.externalReloadWillAcquireMutationLock)
        rmwLock.lock()
        defer { rmwLock.unlock() }

        let loaded = Self.loadFrom(
            Location(fileURL: fileURL, expectsExistingLibrary: expectsExistingLibrary),
            backups: backups
        )
        setLastKnownDigest(loaded.digest)
        let conflictsChanged = storePendingConflicts(loaded.conflicts)
        if conflictsChanged {
            // §1.13: includes the clearing of a previously reported conflict.
            DispatchQueue.main.async { [weak self] in self?.notifyConflictListeners() }
        }
        if let issue = loaded.loadIssue {
            lock.lock()
            _lastLoadIssue = issue
            lock.unlock()
        }

        // §1.13: iCloud left more than one candidate. Do not pick a winner behind
        // the user's back — block saving and let the UI resolve it.
        if !loaded.conflicts.isEmpty {
            DevTypeLog.store.error(
                "[Store] \(loaded.conflicts.count, privacy: .public) unresolved iCloud conflict version(s) for \(self.fileURL.lastPathComponent, privacy: .public); cache left untouched"
            )
            saveBlockLock.lock()
            _saveBlocked = .blockedByRemoteChange
            saveBlockLock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.publishSaveFailure(.blockedByRemoteChange)
            }
            return
        }

        if let hard = loaded.hardFailure {
            // §0.3: never replace a good in-memory library with a bad file.
            saveBlockLock.lock()
            _hardFailure = hard
            _saveBlocked = hard
            saveBlockLock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.publishSaveFailure(hard)
            }
            return
        }

        guard loaded.decodeSucceeded else {
            // File vanished (deleted/evicted mid-flight). Keep the cache — and if
            // this looks like an evicted iCloud item, arm the background wait that
            // reloads when it materializes again.
            saveBlockLock.lock()
            _saveBlocked = loaded.blocked
            saveBlockLock.unlock()
            if Self.isPotentiallyMaterializing(fileURL) {
                scheduleMaterializationReload()
            }
            return
        }

        saveBlockLock.lock()
        _saveBlocked = loaded.blocked
        _hardFailure = nil
        saveBlockLock.unlock()

        lock.lock()
        _cachedGroups = loaded.groups
        let snippetListeners = listeners
        let groupListenersCopy = groupListeners
        lock.unlock()
        invokeConcurrencyProbe(\.externalReloadDidAdopt)

        let flat = Self.expandableSnippets(in: loaded.groups)
        // `self` is only needed to prove the store is still alive — both listener tables were
        // already copied out above, so nothing here reads through it.
        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            for listener in snippetListeners.values { listener(flat) }
            for listener in groupListenersCopy.values { listener(loaded.groups) }
        }
    }

    /// Fires the conflict listeners with `pendingConflicts()`. Must NOT be called
    /// while any lock is held (it reads the listener table).
    func notifyConflictListeners() {
        lock.lock()
        let observers = conflictListeners
        lock.unlock()
        let conflicts = pendingConflicts()
        for observer in observers.values { observer(conflicts) }
    }
}
