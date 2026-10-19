import CryptoKit
import Foundation

extension SnippetStore {
    public func consumeLastLoadIssue() -> LoadIssue? {
        lock.lock()
        defer { lock.unlock() }
        let issue = _lastLoadIssue
        _lastLoadIssue = nil
        return issue
    }

    @discardableResult
    public func addListener(_ listener: @escaping ([SnippetModel]) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        listeners[token] = listener
        let current = _cachedGroups?.flatMap(\.snippets) ?? loadGroupsUnlocked().flatMap(\.snippets)
        lock.unlock()
        listener(current)
        return token
    }

    @discardableResult
    public func addGroupListener(_ listener: @escaping ([SnippetGroup]) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        groupListeners[token] = listener
        let current = _cachedGroups ?? loadGroupsUnlocked()
        lock.unlock()
        listener(current)
        return token
    }

    /// §1.4: fires with the current failure (or `nil` when clear) on registration and
    /// on every subsequent change, so the UI can show "your edit did not save".
    @discardableResult
    public func addSaveFailureListener(_ listener: @escaping (SaveOutcome?) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        saveFailureListeners[token] = listener
        lock.unlock()
        listener(lastSaveFailure)
        return token
    }

    /// §1.13: fires with the current unresolved iCloud conflict versions.
    @discardableResult
    public func addConflictListener(_ listener: @escaping ([ConflictVersion]) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        conflictListeners[token] = listener
        lock.unlock()
        listener(pendingConflicts())
        return token
    }

    public func removeListener(token: UUID) {
        lock.lock()
        listeners.removeValue(forKey: token)
        groupListeners.removeValue(forKey: token)
        saveFailureListeners.removeValue(forKey: token)
        conflictListeners.removeValue(forKey: token)
        lock.unlock()
    }

    public func loadSnippets() -> [SnippetModel] {
        loadGroups().flatMap(\.snippets)
    }

    /// The library as the *matcher* must see it: a snippet in a disabled group is disabled.
    ///
    /// `group.enabled` was honoured by `SnippetExporter` and by `SnippetSearch.makeIndex`, but
    /// by nothing on the expansion path — the engine is handed `groups.flatMap(\.snippets)` and
    /// `AbbreviationMatcher` only checks `snippet.enabled`. Switching a group off therefore
    /// changed what you could search and what you exported, and left every trigger in it firing.
    ///
    /// Snippets are returned *disabled* rather than dropped so that callers counting the library
    /// still see them, and so the one filter every consumer already applies (`snippet.enabled`)
    /// is the only rule anyone has to know. The group flag may only ever subtract: a snippet the
    /// user switched off by hand stays off in an enabled group.
    public static func expandableSnippets(in groups: [SnippetGroup]) -> [SnippetModel] {
        groups.flatMap { group -> [SnippetModel] in
            group.snippets.map { snippet in
                var copy = snippet
                if !group.enabled { copy.enabled = false }
                foldGroupScope(of: group, into: &copy)
                return copy
            }
        }
    }

    /// Merges a group's app scope into one of its snippets.
    ///
    /// Blocking unions — a snippet is suppressed if *either* list suppresses it, and subtraction
    /// needs no tie-break. Limiting intersects, because both lists have to allow the app.
    ///
    /// The case that needs care is two `includeApps` lists that do not overlap. The intersection
    /// is empty, and an empty `includeApps` means "everywhere" — so writing it back would turn
    /// two contradictory limits into no limit at all, which is the exact inversion of what the
    /// user asked for. Such a snippet can never fire anywhere, so it is disabled instead.
    private static func foldGroupScope(of group: SnippetGroup, into snippet: inout SnippetModel) {
        guard !group.includeApps.isEmpty || !group.excludeApps.isEmpty else { return }

        for blocked in group.excludeApps
        where !snippet.excludeApps.contains(where: { $0.caseInsensitiveCompare(blocked) == .orderedSame }) {
            snippet.excludeApps.append(blocked)
        }

        guard !group.includeApps.isEmpty else { return }
        if snippet.includeApps.isEmpty {
            snippet.includeApps = group.includeApps
            return
        }
        let shared = snippet.includeApps.filter { candidate in
            group.includeApps.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }
        if shared.isEmpty {
            snippet.enabled = false
        } else {
            snippet.includeApps = shared
        }
    }

    public func loadGroups() -> [SnippetGroup] {
        loadGroupsWithRevision().groups
    }

    /// The library and the revision that identifies it, read together.
    ///
    /// Two separate calls would be a race: a save landing between them pairs a new revision
    /// with the old groups, and a cache keyed on that would serve the old library forever.
    public func loadGroupsWithRevision() -> (groups: [SnippetGroup], revision: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if let cached = _cachedGroups {
            return (cached, _libraryRevision)
        }
        let groups = loadGroupsUnlocked()
        _cachedGroups = groups
        return (groups, _libraryRevision)
    }

    /// Monotonic counter identifying the in-memory library. Changes on every load, save,
    /// external reload and relocation.
    public var libraryRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _libraryRevision
    }

    struct Loaded {
        var groups: [SnippetGroup] = []
        var digest: FileDigest = .absent
        var loadIssue: LoadIssue?
        var blocked: SaveOutcome?
        /// §0.3: set when the bytes on disk could not be turned into a library.
        var hardFailure: SaveOutcome?
        var conflicts: [ConflictVersion] = []
        var fileWasPresent = false
        /// True when we actually produced a trustworthy library (including a
        /// legitimately empty one).
        var decodeSucceeded = false
    }

    func loadGroupsUnlocked() -> [SnippetGroup] {
        let loaded = Self.loadFrom(
            Location(fileURL: fileURL, expectsExistingLibrary: expectsExistingLibrary),
            backups: backups
        )
        setLastKnownDigest(loaded.digest)
        // `lock` is held by our callers, so store without notifying.
        storePendingConflicts(loaded.conflicts)
        if let issue = loaded.loadIssue { _lastLoadIssue = issue }

        guard loaded.fileWasPresent else {
            // §0.3: nothing on disk. When the user pointed us at an existing
            // library (iCloud / Link) the file is expected to arrive later — do
            // NOT seed defaults over it, and keep whatever we already had.
            if expectsExistingLibrary {
                saveBlockLock.lock()
                _saveBlocked = loaded.blocked
                saveBlockLock.unlock()
                if Self.isPotentiallyMaterializing(fileURL) {
                    scheduleMaterializationReload()
                }
                return _cachedGroups ?? []
            }
            // First run on a local store. This is the only remaining auto-write
            // and it cannot destroy anything: there is no file to destroy.
            let defaults = Self.sanitizeGroups(
                [SnippetGroup(name: SnippetDocument.defaultGroupName, snippets: defaultSnippets())]
            )
            _ = writeGroupsToDisk(defaults, force: true)
            return defaults
        }

        if let hard = loaded.hardFailure {
            // §0.3: the old code wrote 4 demo snippets here with `force: true`,
            // bypassing the digest and block guards and syncing the replacement
            // to every other device. Now: back the file up, latch a hard failure
            // so every save is refused, and hand back the last-known state
            // WITHOUT persisting anything.
            saveBlockLock.lock()
            _hardFailure = hard
            _saveBlocked = hard
            saveBlockLock.unlock()
            DevTypeLog.store.error(
                "[Store] Library \(DevTypeLog.publicPathMetadata(self.fileURL.path), privacy: .public) is unreadable; saves are blocked until this is resolved."
            )
            return _cachedGroups ?? []
        }

        saveBlockLock.lock()
        _saveBlocked = loaded.blocked
        if loaded.decodeSucceeded { _hardFailure = nil }
        saveBlockLock.unlock()
        return loaded.groups
    }

    /// Decodes versioned `SnippetDocument`, v1 `snippets` envelope, or legacy bare `[SnippetModel]` arrays.
    public static func decodeSnippets(from data: Data) throws -> [SnippetModel] {
        try decodeDocument(from: data).snippets
    }

    public static func decodeDocument(from data: Data) throws -> SnippetDocument {
        let decoder = JSONDecoder()
        // Every current envelope is a JSON object, and an object can never decode as the legacy
        // bare `[SnippetModel]` array; skip that doomed full parse when the payload opens with `{`.
        if firstNonWhitespaceByte(in: data) != UInt8(ascii: "{"),
           let legacySnippets = try? decoder.decode([SnippetModel].self, from: data) {
            let document = SnippetDocument(snippets: legacySnippets)
            guard document.hasUniqueSecretIDs else {
                throw DecodingError.dataCorrupted(.init(codingPath: [],
                    debugDescription: "Secret identifiers must be unique and distinct from snippet identifiers."))
            }
            return document
        }
        return try decoder.decode(SnippetDocument.self, from: data)
    }

    /// First byte that is not JSON whitespace (space, tab, LF, CR), or nil for a blank payload.
    static func firstNonWhitespaceByte(in data: Data) -> UInt8? {
        data.first { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
    }
}
