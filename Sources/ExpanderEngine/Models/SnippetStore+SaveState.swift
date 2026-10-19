import CryptoKit
import Foundation

extension SnippetStore {
    // MARK: - Save state (§1.4 / §0.3)

    /// §1.4: last save that did not land, or `nil` when the last save succeeded.
    public var lastSaveFailure: SaveOutcome? {
        saveBlockLock.lock()
        defer { saveBlockLock.unlock() }
        return _lastSaveFailure
    }

    /// Aggregate cleanup debt suitable for diagnostics. No keychain account identifiers or
    /// secret values are retained here.
    public var pendingSecretCleanupCount: Int {
        saveBlockLock.lock()
        defer { saveBlockLock.unlock() }
        return _pendingSecretCleanupCount
    }

    /// Retries a failed orphan sweep against the latest committed library. The destructive work is
    /// serialized separately from mutations: securityd may stall, and no persistence/UI action may
    /// wait behind it. `SecretStore` re-evaluates this projection before each delete and publishes
    /// a per-ID claim that makes same-ID staging wait while every unrelated mutation continues.
    @discardableResult
    public func retryOrphanSecretCleanup() -> SecretStore.PurgeSummary {
        secretCleanupExecutionLock.lock()
        defer { secretCleanupExecutionLock.unlock() }
        return purgeOrphanSecrets(keepingLatest: { [weak self] in
            self?.committedLiveSecretIDs()
        })
    }

    /// Nil is intentionally distinct from an empty library. If canonical cache state is unavailable,
    /// cleanup retains every value and a later request retries after state recovery.
    func committedLiveSecretIDs() -> Set<UUID>? {
        lock.lock()
        defer { lock.unlock() }
        guard let groups = _cachedGroups else { return nil }
        return Set(
            groups
                .flatMap(\.snippets)
                .filter(\.isSecret)
                .map(\.id)
        )
    }

    /// Metadata authorized for value reads and cleanup. Nil means current authority could not
    /// be established, never an empty collection. Refuse while another mutation owns the
    /// cache/digest pair or disk no longer matches it. Nonblocking acquisition avoids lock inversion.
    public func loadCurrentSecrets() -> [SecretModel]? {
        guard rmwLock.try() else { return nil }
        defer { rmwLock.unlock() }
        guard blockedReason() == nil, hardFailure() == nil,
              case .sha = lastKnownDigest(),
              Self.currentDigest(at: fileURL) == lastKnownDigest() else { return nil }
        lock.lock()
        let groups = _cachedGroups
        lock.unlock()
        return groups.map { SnippetDocument(groups: $0).secrets }
    }

    func confirmedLiveSecretIDsForCleanup() -> Set<UUID>? {
        loadCurrentSecrets().map { Set($0.map(\.id)) }
    }

    /// Coalesces launch, activation, and manual retries onto one bounded worker. While a pass is
    /// stalled in securityd, any number of new requests sets one trailing-pass bit rather than
    /// enqueueing one global job apiece. Callbacks run on the cleanup queue after the coalesced
    /// work is complete.
    public func requestOrphanSecretCleanupRetry(
        completion: ((SecretStore.PurgeSummary) -> Void)? = nil
    ) {
        secretCleanupRetryStateLock.lock()
        if let completion { secretCleanupRetryCompletions.append(completion) }
        if secretCleanupRetryRunning {
            secretCleanupRetryNeedsTrailingPass = true
            secretCleanupRetryStateLock.unlock()
            return
        }
        secretCleanupRetryRunning = true
        secretCleanupRetryStateLock.unlock()

        secretCleanupRetryQueue.async { [weak self] in
            self?.runRequestedOrphanSecretCleanup()
        }
    }

    private func runRequestedOrphanSecretCleanup() {
        while true {
            invokeConcurrencyProbe(\.secretCleanupRetryDidBeginPass)
            let summary = retryOrphanSecretCleanup()

            secretCleanupRetryStateLock.lock()
            if secretCleanupRetryNeedsTrailingPass {
                secretCleanupRetryNeedsTrailingPass = false
                secretCleanupRetryStateLock.unlock()
                continue
            }
            secretCleanupRetryRunning = false
            let completions = secretCleanupRetryCompletions
            secretCleanupRetryCompletions.removeAll()
            secretCleanupRetryStateLock.unlock()

            for completion in completions { completion(summary) }
            return
        }
    }

    /// §1.4: clears the surfaced failure after the UI has shown it. Does not
    /// unblock saving — that is `clearLibraryReadFailure()` / a clean reload.
    public func acknowledgeSaveFailure() {
        publishSaveFailure(nil)
    }

    /// §0.3: true while the library on disk could not be read; every save is refused.
    public var isLibraryReadFailed: Bool {
        saveBlockLock.lock()
        defer { saveBlockLock.unlock() }
        return _hardFailure != nil
    }

    public var libraryReadFailureReason: String? {
        saveBlockLock.lock()
        defer { saveBlockLock.unlock() }
        if case .failed(let reason)? = _hardFailure { return reason }
        return nil
    }

    /// §0.3: user-driven recovery — stop refusing saves. The next save replaces whatever is on
    /// disk, so callers must confirm first. That save still keeps a copy: readable bytes go to a
    /// rolling backup, and a file that cannot be read is preserved as a safety copy or not
    /// replaced at all.
    public func clearLibraryReadFailure() {
        saveBlockLock.lock()
        _hardFailure = nil
        _saveBlocked = nil
        saveBlockLock.unlock()
        publishSaveFailure(nil)
    }

    /// §0.3: the single deliberate escape hatch that bypasses the hard-fail latch
    /// and the digest guard. Nothing on the load path may call this.
    ///
    /// The file it replaces is kept first, as a `pre-overwrite` backup of its raw bytes — or,
    /// when they cannot be read, a hard link (or a copy, when a link is impossible) in the backup
    /// directory. The live path is not renamed aside, so a crash before the overwrite commits
    /// still leaves the pre-overwrite bytes there. When no backup can be made nothing is written:
    /// the result is `.failed`, the read-failure latch stays set, and the original file is
    /// untouched. The keep happens in `writeGroupsToDisk(force:)`, so no caller can reach the
    /// forced write without it.
    @discardableResult
    public func forceOverwriteLibrary(with groups: [SnippetGroup]) -> OverwriteResult {
        let sanitized = Self.sanitizeGroups(groups)
        let write = writeGroupsToDisk(sanitized, force: true, bypassHardFailure: true)
        guard write.outcome.didSave else {
            publishSaveFailure(write.outcome)
            return OverwriteResult(outcome: write.outcome, backupURL: nil)
        }
        saveBlockLock.lock()
        _hardFailure = nil
        saveBlockLock.unlock()

        lock.lock()
        _cachedGroups = sanitized
        let snippetListeners = listeners
        let groupListenersCopy = groupListeners
        lock.unlock()

        publishSaveFailure(nil)
        let flat = sanitized.flatMap(\.snippets)
        for listener in snippetListeners.values { listener(flat) }
        for listener in groupListenersCopy.values { listener(sanitized) }
        return OverwriteResult(outcome: write.outcome, backupURL: write.backupURL)
    }

    func publishSaveFailure(_ outcome: SaveOutcome?) {
        saveBlockLock.lock()
        let changed = _lastSaveFailure != outcome
        _lastSaveFailure = outcome
        saveBlockLock.unlock()
        guard changed else { return }

        lock.lock()
        let observers = saveFailureListeners
        lock.unlock()
        for observer in observers.values { observer(outcome) }
    }
}
