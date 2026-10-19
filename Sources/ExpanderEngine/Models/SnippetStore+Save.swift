import CryptoKit
import Foundation

extension SnippetStore {
    /// `@discardableResult` because most callers genuinely cannot act on a failed save, but the
    /// outcome is now *available*: `saveGroups` and `importGroups` both report theirs, and this
    /// one silently dropped it, so a caller that wanted to check had no way to.
    @discardableResult
    public func saveSnippets(_ snippets: [SnippetModel]) -> SaveOutcome {
        // Same RMW serialization as `importGroups`: read baseline, merge, save.
        rmwLock.lock()
        defer { rmwLock.unlock() }
        lock.lock()
        let existing = _cachedGroups ?? loadGroupsUnlocked()
        lock.unlock()

        let replacement = SnippetDocument(snippets: Self.sanitize(snippets))
        let sanitized = replacement.groups.flatMap(\.snippets)
        var updated = SnippetDocument(groups: existing).groups

        if updated.isEmpty {
            updated = [SnippetGroup(name: SnippetDocument.defaultGroupName, snippets: sanitized)]
        } else if updated.count == 1 {
            updated[0].snippets = sanitized
        } else {
            var byID: [UUID: SnippetModel] = [:]
            for snippet in sanitized { byID[snippet.id] = snippet }
            let keepIDs = Set(sanitized.map(\.id))
            var placed = Set<UUID>()
            for gi in updated.indices {
                for si in updated[gi].snippets.indices {
                    let id = updated[gi].snippets[si].id
                    if let replacement = byID[id] {
                        updated[gi].snippets[si] = replacement
                        placed.insert(id)
                    }
                }
                updated[gi].snippets.removeAll { !keepIDs.contains($0.id) }
            }
            let orphans = sanitized.filter { !placed.contains($0.id) }
            if !orphans.isEmpty {
                if let generalIndex = updated.firstIndex(where: { $0.name == SnippetDocument.defaultGroupName }) {
                    updated[generalIndex].snippets.append(contentsOf: orphans)
                } else {
                    updated.insert(SnippetGroup(name: SnippetDocument.defaultGroupName, snippets: orphans), at: 0)
                }
            }
        }

        // `rmwLock` is already held for this whole read-modify-write; the public
        // `saveGroups` would try to re-acquire it and deadlock.
        return saveGroupsSerialized(SnippetDocument(groups: updated, secrets: replacement.secrets).transactionGroups)
    }

    /// Commits `groups` as the whole library. The sanitize → write → cache-commit
    /// sequence runs under `rmwLock`, so it cannot interleave with the
    /// read-modify-write mutations (`importGroups`, `saveSnippets`): a save whose
    /// payload was computed from a stale snapshot can still lose to a later logical writer. The
    /// potentially unbounded secret cleanup is scheduled after commit and re-checks the latest
    /// canonical cache around each deletion; it never extends this mutation lock across securityd.
    @discardableResult
    public func saveGroups(_ groups: [SnippetGroup]) -> SaveOutcome {
        rmwLock.lock()
        defer { rmwLock.unlock() }
        return saveGroupsSerialized(groups)
    }

    /// Applies a logical mutation to the latest in-process library while holding the same lock
    /// used by imports, conflict resolution, and direct saves. Long-lived controllers must use
    /// this instead of loading a snapshot and later handing that whole snapshot to `saveGroups`,
    /// which can overwrite another successful in-process mutation even though disk digests match.
    ///
    /// Return `false` from `mutation` when the user-visible target or another required precondition
    /// no longer exists. That is a stale action (`rejected`), not an unchanged successful edit.
    @discardableResult
    public func mutateGroups(
        _ mutation: (inout [SnippetGroup]) -> Bool
    ) -> GroupMutationResult {
        rmwLock.lock()
        defer { rmwLock.unlock() }

        lock.lock()
        let before = _cachedGroups ?? loadGroupsUnlocked()
        lock.unlock()
        invokeConcurrencyProbe(\.mutationDidRead)

        var after = before
        guard mutation(&after) else { return .rejected(current: before) }
        guard after != before else { return .unchanged(current: before) }

        let sanitized = Self.sanitizeGroups(after)
        let outcome = saveGroupsSerialized(sanitized)
        guard outcome.didSave else { return .refused(outcome) }
        return .saved(before: before, after: sanitized)
    }

    /// Replaces the whole library only when it is still exactly the state an earlier operation
    /// committed. This is the safe model-only undo/rollback primitive: if any other writer landed
    /// in between, refusing preserves that newer work instead of reverting it incidentally.
    @discardableResult
    public func replaceGroups(
        ifCurrent expected: [SnippetGroup],
        with replacement: [SnippetGroup]
    ) -> GroupMutationResult {
        mutateGroups { current in
            guard current == expected else { return false }
            current = replacement
            return true
        }
    }

    /// Body of `saveGroups`. The caller must already hold `rmwLock`: either the
    /// public wrapper above, or one of the RMW mutations that reached here after
    /// their own merge. (`rmwLock` is a plain `NSLock` — non-reentrant — which is
    /// why these call sites use this entry point directly.)
    ///
    /// §1.4: the cache is committed and listeners fire **only** when the bytes
    /// actually reached disk. Previously the cache was updated first and every
    /// listener fired unconditionally, so the UI reported success for writes that
    /// were refused by `blockedReason()` or the digest guard — and every edit was
    /// lost at quit.
    func saveGroupsSerialized(_ groups: [SnippetGroup]) -> SaveOutcome {
        commitGroupsSerialized(groups, safetyKind: nil, bypassLatch: false).outcome
    }

    /// `safetyKind` makes the write keep whatever it replaces as that kind of backup, or not
    /// happen. `bypassLatch` additionally skips the save latch and digest guard; it is only for
    /// user-confirmed recovery, and clears the read-failure latch when the write lands.
    func commitGroupsSerialized(
        _ groups: [SnippetGroup],
        safetyKind: LibraryBackupStore.Kind?,
        bypassLatch: Bool
    ) -> DiskWrite {
        let sanitized = Self.sanitizeGroups(groups)
        let liveSecretIDs = Set(
            sanitized
                .flatMap(\.snippets)
                .filter(\.isSecret)
                .map(\.id)
        )
        // Install the whole commit's protection in one brief critical section. This method already
        // runs under `rmwLock`, so it must never wait for securityd: an uncoordinated same-ID
        // re-reference that intersects an irreversible delete fails closed, releasing `rmwLock`
        // for unrelated mutations. The editor's staged-secret transaction acquires its blocking
        // per-ID lease before entering this method, so its publication reaches this fast path only
        // after the old delete has finished and the replacement value has been stored.
        let secretCommitLease = secretPurgeEnabled
            ? secretStore.tryProtectFromOrphanPurge(liveSecretIDs)
            : nil
        if secretPurgeEnabled, secretCommitLease == nil {
            let failure = SaveOutcome.failed(
                "A referenced secret is still being removed; retry after cleanup finishes."
            )
            publishSaveFailure(failure)
            return DiskWrite(outcome: failure, backupURL: nil)
        }
        defer { secretCommitLease?.end() }

        if secretPurgeEnabled {
            // A latched library never committed a cache; recovery then treats every secret the
            // restored library references as new, so each must still have a stored value.
            guard let previouslyLiveSecretIDs = committedLiveSecretIDs() ?? (bypassLatch ? [] : nil) else {
                let failure = SaveOutcome.failed("Secret state is unavailable; the library was not changed.")
                publishSaveFailure(failure)
                return DiskWrite(outcome: failure, backupURL: nil)
            }
            let newlyReferencedIDs = liveSecretIDs.subtracting(previouslyLiveSecretIDs)
            guard newlyReferencedIDs.allSatisfy({ secretStore.hasSecret(for: $0) }) else {
                let failure = SaveOutcome.failed(
                    "A newly referenced secret has no stored value; the library was not changed."
                )
                publishSaveFailure(failure)
                return DiskWrite(outcome: failure, backupURL: nil)
            }
        }

        let write = writeGroupsToDisk(
            sanitized,
            force: bypassLatch,
            bypassHardFailure: bypassLatch,
            safetyKind: safetyKind
        )
        let outcome = write.outcome

        guard outcome.didSave else {
            DevTypeLog.store.error(
                "[Store] Save did not land outcome=\(outcome.diagnosticLabel, privacy: .public)"
            )
            publishSaveFailure(outcome)
            return write
        }
        if bypassLatch {
            saveBlockLock.lock()
            _hardFailure = nil
            saveBlockLock.unlock()
        }

        lock.lock()
        _cachedGroups = sanitized
        let snippetListeners = listeners
        let groupListenersCopy = groupListeners
        lock.unlock()

        publishSaveFailure(nil)

        let flat = sanitized.flatMap(\.snippets)

        for listener in snippetListeners.values { listener(flat) }
        for listener in groupListenersCopy.values { listener(sanitized) }

        // Only after bytes, cache, and deterministic notifications have committed. Keychain and
        // encrypted-archive operations may stall; enqueueing is bounded and coalesced, while the
        // worker re-reads the canonical live secret IDs immediately around each deletion.
        if secretPurgeEnabled {
            requestOrphanSecretCleanupRetry()
        }
        return write
    }

    /// Drop keychain entries for snippets that no longer exist.
    ///
    /// Guarded by `secretPurgeEnabled` because a store instance built over a *partial* library —
    /// the importers' scratch stores, and every test that saves two snippets to a temp directory —
    /// would otherwise read "these are all the snippets that exist" and delete the real library's
    /// secrets. Only the shared store, which owns the whole library, is allowed to purge.
    @discardableResult
    func purgeOrphanSecrets(
        keepingLatest latestLiveIDs: () -> Set<UUID>?
    ) -> SecretStore.PurgeSummary {
        guard secretPurgeEnabled else { return .init() }
        let summary = secretStore.purgeOrphans(keepingLatest: latestLiveIDs,
            confirmingLatest: { [weak self] in self?.confirmedLiveSecretIDsForCleanup() })
        saveBlockLock.lock()
        _pendingSecretCleanupCount = summary.pending
        saveBlockLock.unlock()
        if summary.removed > 0 {
            DevTypeLog.store.info(
                "[Store] purged \(summary.removed, privacy: .public) orphaned secret(s) from the keychain"
            )
        }
        if summary.pending > 0 {
            // Aggregate counts only. Never log the stable keychain account UUID, snippet title,
            // trigger, or value while surfacing a failed destructive cleanup.
            DevTypeLog.store.error(
                "[Store] orphaned secret cleanup incomplete attempted=\(summary.attempted, privacy: .public) removed=\(summary.removed, privacy: .public) failed=\(summary.failed, privacy: .public) deferred=\(summary.deferred, privacy: .public)"
            )
        }
        return summary
    }
}
