import CryptoKit
import Foundation

extension SnippetStore {
    // MARK: - Usage statistics (§1.5)

    /// §1.5: no longer rewrites the library. Counters go to `UsageStatsStore`,
    /// which coalesces writes (~5 s) and flushes on terminate.
    public func incrementUsage(for snippetID: UUID) {
        usageStatsStore.recordUsage(for: snippetID)
    }

    /// Live usage count: sidecar value, falling back to the legacy in-library
    /// counter for snippets that have not been used since the migration.
    /// Every recorded usage count in one read.
    ///
    /// The per-snippet accessor takes a lock inside `UsageStatsStore`, so filtering or sorting a
    /// library through it cost one lock acquisition per snippet — two per comparison inside a
    /// sort comparator. Callers working over a whole list should take this map once.
    public func usageCountsByID() -> [UUID: Int] {
        usageStatsStore.allStats().mapValues(\.usageCount)
    }

    /// Every recorded last-used timestamp in one read. Companion to `usageCountsByID()`.
    public func lastUsedByID() -> [UUID: Date] {
        usageStatsStore.allStats().compactMapValues(\.lastUsedAt)
    }

    public func usageCount(for snippet: SnippetModel) -> Int {
        max(snippet.usageCount, usageStatsStore.usageCount(for: snippet.id))
    }

    public func usageCount(forSnippetID snippetID: UUID) -> Int {
        usageStatsStore.usageCount(for: snippetID)
    }

    public func rankBoost(for snippet: SnippetModel) -> Int {
        usageStatsStore.rankBoost(for: snippet.id)
    }

    public func rankBoost(forSnippetID snippetID: UUID) -> Int {
        usageStatsStore.rankBoost(for: snippetID)
    }

    /// §4.5: survives relaunch, unlike the in-memory recents list.
    public func lastUsedAt(forSnippetID snippetID: UUID) -> Date? {
        usageStatsStore.lastUsedAt(for: snippetID)
    }

    /// §1.5 migration: copies legacy in-library `usageCount` values into the
    /// sidecar. Idempotent — only fills IDs the sidecar has never seen. Call once
    /// at launch.
    public func migrateLegacyUsageCounts() {
        usageStatsStore.seedLegacyCounts(from: loadSnippets())
    }

    /// §4.5: most-used snippets, highest first.
    public func topUsedSnippets(limit: Int = 10) -> [SnippetModel] {
        let byID = snippetsByID()
        return usageStatsStore.topSnippetIDs(limit: limit).compactMap { byID[$0] }
    }

    /// §4.5: most-recently-used snippets, newest first.
    public func recentlyUsedSnippets(limit: Int = 10) -> [SnippetModel] {
        let byID = snippetsByID()
        return usageStatsStore.recentSnippetIDs(limit: limit).compactMap { byID[$0] }
    }

    private func snippetsByID() -> [UUID: SnippetModel] {
        var byID: [UUID: SnippetModel] = [:]
        for snippet in loadSnippets() where byID[snippet.id] == nil {
            byID[snippet.id] = snippet
        }
        return byID
    }

    /// Flush pending usage counters. Call from `applicationWillTerminate`.
    public func flushUsageStats() {
        usageStatsStore.flush()
    }

    // MARK: - Export (§0.4)

    /// §0.4: pretty-printed JSON of the current document envelope. Works even
    /// while saves are blocked — it is the escape hatch for exactly that state.
    ///
    /// **This is a backup, not the user-facing export.** It encodes `loadGroups()`, so the
    /// envelope carries the independent `secrets` collection: their titles, labels, tags and
    /// timestamps — never their values, which live only in `SecretStore`. That is correct for
    /// its purpose (restoring a library must not silently drop the user's secrets) and wrong for
    /// sharing. The share path is `LibraryExporter`, which reads `loadSnippetGroups()` and so
    /// contains no secret record at all. `SecretBoundaryAdversarialTests` pins both halves.
    public func exportLibraryData() throws -> Data {
        try Self.encodeLibrary(loadGroups())
    }

    /// §0.4: same envelope as `exportLibraryData()` but for an explicit group list,
    /// so the manager's bulk bar can export just the selected snippets. Routes through
    /// the same `encodeLibrary` as the whole-library path — one encode implementation.
    public static func exportLibraryData(groups: [SnippetGroup]) throws -> Data {
        try encodeLibrary(groups)
    }

    /// Single encode implementation reused by export, relocation and conflict resolution.
    static func encodeLibrary(_ groups: [SnippetGroup]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(SnippetDocument(groups: groups))
    }

    // MARK: - Backups and restore (§0.3)

    /// Every backup "Restore from Backup…" can offer, newest first, each with the snippet count
    /// the versioned decoder finds in it. Reads every listed file (bounded); call off main.
    public func libraryBackups() -> [LibraryBackup] {
        backups.entries().map { entry in
            let count = (try? Self.decodeRestorableBackup(at: entry.url))?.snippets.count
            return LibraryBackup(url: entry.url, createdAt: entry.createdAt, kind: entry.kind, snippetCount: count)
        }
    }

    /// How many backups are on disk, for diagnostics. Lists the directory; reads no file.
    public var libraryBackupCount: Int { backups.entries().count }

    /// The directory backups are kept in, for "Reveal in Finder".
    public var libraryBackupDirectory: URL { backups.directory }

    /// Replaces the library with a backup's contents.
    ///
    /// Fails closed — and leaves the live library and its file untouched — when the file is not
    /// a backup in this store's directory, is torn or not a DevType library, was written by a
    /// newer schema, or when the current library cannot first be kept as a `pre-restore` backup.
    /// The commit goes through the same serialized save as any edit, so listeners, the search
    /// index and the event tap pick up the restored library without a relaunch. Secret values are
    /// never in a backup: on the store that owns secrets (`shared`), a restored secret whose value
    /// is no longer stored is refused by that save rather than restored as an empty secret.
    @discardableResult
    public func restoreLibrary(fromBackup url: URL) -> RestoreResult {
        guard backups.entry(for: url) != nil else {
            return RestoreResult(outcome: .failed("That file is not a DevType library backup."), preRestoreBackupURL: nil)
        }
        let document: SnippetDocument
        do {
            document = try Self.decodeRestorableBackup(at: url)
        } catch {
            DevTypeLog.store.error(
                "[Store] Refused to restore an unreadable backup \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            return RestoreResult(
                outcome: .failed("The backup could not be read as a snippet library: \(error.localizedDescription)"),
                preRestoreBackupURL: nil
            )
        }

        rmwLock.lock()
        defer { rmwLock.unlock() }
        // A read-blocked or corrupt library is exactly where a restore is needed, so a latched
        // state does not refuse it. It bypasses the latch the way `forceOverwriteLibrary` does, and
        // on the same terms: the file it replaces is first kept as a required `pre-restore` copy
        // (raw bytes, or a hard link / copy when unreadable), or nothing is written. The live
        // path keeps its bytes until that copy exists and the replacement commits.
        let latched = blockedReason() != nil
        let write = commitGroupsSerialized(
            document.transactionGroups,
            safetyKind: .preRestore,
            bypassLatch: latched
        )
        if write.outcome.didSave {
            DevTypeLog.store.notice(
                "[Store] Restored library from \(url.lastPathComponent, privacy: .public)"
            )
        }
        return RestoreResult(outcome: write.outcome, preRestoreBackupURL: write.backupURL)
    }

    /// The versioned decoder plus the checks conflict adoption applies: bounded size, and no
    /// schema newer than this build understands.
    private static func decodeRestorableBackup(at url: URL) throws -> SnippetDocument {
        let data = try LibraryConflictRecovery.boundedRead(url)
        let document = try decodeDocument(from: data)
        guard document.schemaVersion <= SnippetDocument.currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document
    }
}
