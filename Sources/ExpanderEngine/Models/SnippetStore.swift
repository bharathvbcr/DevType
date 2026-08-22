import CryptoKit
import Foundation

/// On-disk envelope for snippets. Versioned so future fields can migrate without wiping user data.
public struct SnippetDocument: Codable, Equatable {
    public static let currentSchemaVersion = 2
    public static let defaultGroupName = "General"

    public var schemaVersion: Int
    public var groups: [SnippetGroup]

    /// Flattened snippets for engine / legacy callers.
    public var snippets: [SnippetModel] {
        groups.flatMap(\.snippets)
    }

    public init(schemaVersion: Int = SnippetDocument.currentSchemaVersion, groups: [SnippetGroup]) {
        self.schemaVersion = schemaVersion
        self.groups = groups
    }

    /// Convenience: wrap a flat snippet list in the default group (v1 migration shape).
    public init(schemaVersion: Int = SnippetDocument.currentSchemaVersion, snippets: [SnippetModel]) {
        self.schemaVersion = schemaVersion
        self.groups = [SnippetGroup(name: Self.defaultGroupName, snippets: snippets)]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, groups, snippets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if let decodedGroups = try container.decodeIfPresent([SnippetGroup].self, forKey: .groups) {
            groups = decodedGroups
        } else if let legacySnippets = try container.decodeIfPresent([SnippetModel].self, forKey: .snippets) {
            groups = [SnippetGroup(name: Self.defaultGroupName, snippets: legacySnippets)]
        } else {
            groups = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(groups, forKey: .groups)
    }
}

public final class SnippetStore {
    /// The one store that owns the whole library, and therefore the only one allowed to decide a
    /// keychain secret is orphaned.
    public static let shared = SnippetStore(
        location: SnippetStore.resolveLocation(defaults: .standard),
        watcherFactory: SnippetStore.defaultWatcherFactory,
        secretPurgeEnabled: true
    )

    private let secretStore: SecretStore
    /// See `purgeOrphanSecrets`: off for partial / scratch stores, on for `shared`.
    private let secretPurgeEnabled: Bool

    public enum LoadIssue: Equatable {
        case corrupted(backupURL: URL)
        /// §0.3: the file exists but could not be read at all (I/O error, or an
        /// iCloud item that never materialized). Distinct from `corrupted`: we
        /// have no bytes, so there is nothing to back up.
        case unreadable(path: String, reason: String)
        /// §0.3: the file is present but empty. Surfaced so the UI can warn
        /// before the user saves emptiness over a real library.
        case emptyFile(path: String)
        /// §1.13: iCloud reports unresolved conflict versions for the library.
        case conflicted(path: String, versionCount: Int)
    }

    public enum SaveOutcome: Equatable {
        case saved
        case blockedByNewerSchema
        case blockedByRemoteChange
        case failed(String)

        public var didSave: Bool { self == .saved }
    }

    /// §1.13: one iCloud conflict version, surfaced instead of being silently overwritten.
    public struct ConflictVersion: Equatable {
        public let url: URL
        public let modificationDate: Date?
        public let deviceName: String?

        public init(url: URL, modificationDate: Date?, deviceName: String?) {
            self.url = url
            self.modificationDate = modificationDate
            self.deviceName = deviceName
        }
    }

    /// §1.9: a trigger that the matcher will silently shadow, or an unusable trigger.
    /// Reported instead of deleting the snippet.
    public struct TriggerConflict: Equatable {
        public enum Kind: Equatable {
            /// Trigger is empty — the snippet can never fire.
            case emptyTrigger
            /// Two or more snippets resolve to the same matcher key; the first wins.
            case duplicateTrigger
            /// A case-sensitive and a case-insensitive snippet fold to the same key.
            case caseShadow
            /// A shorter trigger that fires without a terminator is a prefix of a longer one,
            /// so the longer trigger can never be typed — the short one always fires first.
            ///
            /// `trigger` holds the shadowing (shorter) trigger; `snippetIDs` / `groupNames`
            /// start with it, followed by every trigger it makes unreachable.
            case prefixShadow
        }

        public let kind: Kind
        /// The matcher key involved (case-folded for case-insensitive snippets).
        public let trigger: String
        public let snippetIDs: [UUID]
        public let groupNames: [String]
        /// `prefixShadow` only: the triggers `trigger` makes unreachable. Naming them is what
        /// makes the warning actionable — a group name does not tell you which trigger is dead.
        public let blockedTriggers: [String]

        public init(
            kind: Kind,
            trigger: String,
            snippetIDs: [UUID],
            groupNames: [String],
            blockedTriggers: [String] = []
        ) {
            self.kind = kind
            self.trigger = trigger
            self.snippetIDs = snippetIDs
            self.groupNames = groupNames
            self.blockedTriggers = blockedTriggers
        }

        /// Comma-joined `blockedTriggers`, or `nil` when there are none.
        public var blockedTriggerSummary: String? {
            blockedTriggers.isEmpty ? nil : blockedTriggers.joined(separator: ", ")
        }
    }

    /// §1.10: how an import folds into the existing library.
    public enum ImportMode: Equatable {
        /// Match by trigger inside a same-named group, update in place, append the
        /// rest. Never removes a local snippet. Default.
        case merge
        /// Legacy behaviour: same-named groups are replaced wholesale. Destructive.
        case replaceGroup
        /// Always land in a freshly named group, leaving existing groups untouched.
        case intoNewGroup
    }

    /// §1.10: what an import actually did, so the UI can show a diff.
    public struct ImportSummary: Equatable {
        public let mode: ImportMode
        public let groupsCreated: [String]
        public let groupsUpdated: [String]
        public let snippetsAdded: Int
        public let snippetsUpdated: Int
        public let snippetsUnchanged: Int
        public let outcome: SaveOutcome

        public init(
            mode: ImportMode,
            groupsCreated: [String],
            groupsUpdated: [String],
            snippetsAdded: Int,
            snippetsUpdated: Int,
            snippetsUnchanged: Int,
            outcome: SaveOutcome
        ) {
            self.mode = mode
            self.groupsCreated = groupsCreated
            self.groupsUpdated = groupsUpdated
            self.snippetsAdded = snippetsAdded
            self.snippetsUpdated = snippetsUpdated
            self.snippetsUnchanged = snippetsUnchanged
            self.outcome = outcome
        }
    }

    public struct Location: Equatable {
        public let fileURL: URL
        /// User explicitly chose this path (iCloud sync folder, Link, Save As).
        public let expectsExistingLibrary: Bool

        public init(fileURL: URL, expectsExistingLibrary: Bool) {
            self.fileURL = fileURL
            self.expectsExistingLibrary = expectsExistingLibrary
        }
    }

    public struct RelocationResult: Equatable {
        public let success: Bool
        public let backupURL: URL?
        public let message: String?
        public let activeLocation: URL
    }

    public enum DeviceStateKey {
        public static let storeLocationPath = "devtype.storeFileURL"
    }

    public static let storeDirEnvKey = "DEVTYPE_STORE_DIR"
    public static let syncedFileName = "DevType-snippets.json"

    /// §2.5: watcher events are coalesced over this window before any disk work happens.
    public static let externalChangeDebounce: TimeInterval = 0.25

    /// §0.3: bounded wait for `startDownloadingUbiquitousItem` to materialize the file.
    public static let ubiquitousDownloadTimeout: TimeInterval = 2.0

    private enum FileDigest: Equatable {
        case absent
        case unreadable
        case sha(String)
    }

    private let lock = NSLock()
    /// Dedicated lock for `_saveBlocked` — NSLock is not re-entrant, so we
    /// cannot reuse `lock` here: `loadGroupsUnlocked` holds `lock` and calls
    /// `writeGroupsToDisk`, which also needs to touch `_saveBlocked`.
    /// Lock ordering rule: `lock` may be held while acquiring `saveBlockLock`,
    /// but never the reverse.
    private let saveBlockLock = NSLock()
    private var listeners: [UUID: ([SnippetModel]) -> Void] = [:]
    private var groupListeners: [UUID: ([SnippetGroup]) -> Void] = [:]
    /// §1.4: lets the UI surface a save that never landed.
    private var saveFailureListeners: [UUID: (SaveOutcome?) -> Void] = [:]
    /// §1.13: lets the UI surface an iCloud conflict instead of losing a side.
    private var conflictListeners: [UUID: ([ConflictVersion]) -> Void] = [:]
    private var _cachedGroups: [SnippetGroup]?
    private var _lastLoadIssue: LoadIssue?
    private var _saveBlocked: SaveOutcome?
    /// §0.3: latched when the library on disk could not be read/decoded. Blocks
    /// every save (including forced ones) until a clean reload or an explicit
    /// `clearLibraryReadFailure()` / `forceOverwriteLibrary(...)`.
    private var _hardFailure: SaveOutcome?
    private var _lastSaveFailure: SaveOutcome?
    private var _pendingConflicts: [ConflictVersion] = []

    private var fileURL: URL
    private var expectsExistingLibrary: Bool
    private let deviceDefaults: UserDefaults
    private let localSupportDirectory: URL
    private var localDefaultURL: URL { localSupportDirectory.appendingPathComponent("snippets.json") }

    private let watcherFactory: (URL) -> StoreWatching?
    private var watcher: StoreWatching?
    private let digestLock = NSLock()
    private var savedDigest: FileDigest = .absent

    /// Serializes read-modify-write mutations (`importGroups`, `saveSnippets`) and
    /// the sanitize→write→purge tail of every direct `saveGroups`.
    /// The per-call `lock` cannot span an RMW — `loadGroups()` and `saveGroups()`
    /// acquire it internally and unfair locks are not reentrant — so two
    /// overlapping merges both computed against the same cached baseline and the
    /// later write silently dropped the earlier one's groups. The on-disk digest
    /// guard does not catch this either: it defends against *external* writers,
    /// and every successful in-process write refreshes the digest that the check
    /// compares against.
    ///
    /// `saveGroups` is included because its orphan purge is destructive beyond the
    /// library file: a direct save computed from a stale snapshot could interleave
    /// its purge after another writer's commit and delete keychain secrets that
    /// the just-written library still references.
    ///
    /// Held across listener dispatch (they fire from `saveGroupsSerialized`, which
    /// these methods all reach): a listener that synchronously calls back into
    /// `importGroups`/`saveSnippets`/`saveGroups` would self-deadlock. Every
    /// current listener hops to main asynchronously first.
    private let rmwLock = NSLock()

    /// §2.5: reentrancy guard. Set for the duration of an external-state apply so a
    /// watcher event produced by that apply cannot recurse back into `reloadFromDisk`.
    private let externalStateLock = NSLock()
    private var _isApplyingExternalState = false
    private var externalChangeGeneration: UInt64 = 0
    /// §2.5: digest work (full-file read + SHA256) runs here, never on main.
    private let coalesceQueue = DispatchQueue(label: "devtype.store.external", qos: .utility)

    /// §1.5: usage counters live in a coalesced sidecar, not in the library file.
    /// Assignable so tests can point at a temp file.
    public var usageStatsStore: UsageStatsStore = .shared

    // MARK: - Active location registry (§3.7)

    private static let activeDirectoryLock = NSLock()
    private static var _activeLibraryDirectory: URL?

    /// §3.7: directory holding the most recently initialized/relocated library.
    /// `ImageAttachmentStore` follows this so image attachments travel with the
    /// library instead of being frozen at first access.
    public static var activeLibraryDirectory: URL? {
        activeDirectoryLock.lock()
        defer { activeDirectoryLock.unlock() }
        return _activeLibraryDirectory
    }

    private static func setActiveLibraryDirectory(_ url: URL?) {
        activeDirectoryLock.lock()
        _activeLibraryDirectory = url
        activeDirectoryLock.unlock()
    }

    /// Set when the last disk load recovered from corrupt JSON. Cleared after UI consumes it.
    public var lastLoadIssue: LoadIssue? {
        lock.lock()
        defer { lock.unlock() }
        return _lastLoadIssue
    }

    public var activeLocationURL: URL { fileURL }

    public var isUsingConfiguredLocation: Bool { expectsExistingLibrary }

    public var allSnippets: [SnippetModel] {
        loadSnippets()
    }

    public static var defaultLocalSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevType", isDirectory: true)
    }

    public static func resolveLocation(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Location {
        if let dir = environment[storeDirEnvKey], !dir.isEmpty {
            return Location(
                fileURL: URL(fileURLWithPath: dir, isDirectory: true)
                    .appendingPathComponent("snippets.json"),
                expectsExistingLibrary: false
            )
        }
        if let path = defaults.string(forKey: DeviceStateKey.storeLocationPath), !path.isEmpty {
            return Location(fileURL: URL(fileURLWithPath: path), expectsExistingLibrary: true)
        }
        return Location(
            fileURL: defaultLocalSupportDirectory.appendingPathComponent("snippets.json"),
            expectsExistingLibrary: false
        )
    }

    static func defaultWatcherFactory(_ fileURL: URL) -> StoreWatching? {
        let directoryWatcher = DirectoryWatcher(directoryURL: fileURL.deletingLastPathComponent())
        guard isUbiquitousLocation(fileURL) else { return directoryWatcher }
        return CompositeWatcher([directoryWatcher, MetadataQueryWatcher(fileURL: fileURL)])
    }

    static func isUbiquitousLocation(_ fileURL: URL) -> Bool {
        if let values = try? fileURL.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            return true
        }
        let directory = fileURL.deletingLastPathComponent()
        if let values = try? directory.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            return true
        }
        let path = fileURL.path
        return path.contains("com~apple~CloudDocs") || path.contains("/Mobile Documents/")
    }

    public convenience init() {
        self.init(fileURL: nil)
    }

    /// Tests and harnesses: pass a temp-file URL; omit for default Application Support location.
    public convenience init(fileURL: URL? = nil, deviceDefaults: UserDefaults = .standard) {
        if let fileURL {
            let parent = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            self.init(
                location: Location(fileURL: fileURL, expectsExistingLibrary: false),
                deviceDefaults: deviceDefaults,
                watcherFactory: { _ in nil }
            )
        } else {
            self.init(
                location: SnippetStore.resolveLocation(defaults: deviceDefaults),
                deviceDefaults: deviceDefaults,
                watcherFactory: SnippetStore.defaultWatcherFactory
            )
        }
    }

    public init(
        location: Location,
        deviceDefaults: UserDefaults = .standard,
        localSupportDirectory: URL = SnippetStore.defaultLocalSupportDirectory,
        watcherFactory: @escaping (URL) -> StoreWatching? = { _ in nil },
        secretStore: SecretStore = .shared,
        secretPurgeEnabled: Bool = false
    ) {
        self.secretStore = secretStore
        self.secretPurgeEnabled = secretPurgeEnabled
        self.fileURL = location.fileURL
        self.expectsExistingLibrary = location.expectsExistingLibrary
        self.deviceDefaults = deviceDefaults
        self.localSupportDirectory = localSupportDirectory
        self.watcherFactory = watcherFactory

        let loaded = Self.loadFrom(location)
        _cachedGroups = loaded.groups
        _lastLoadIssue = loaded.loadIssue
        _pendingConflicts = loaded.conflicts
        saveBlockLock.lock()
        _saveBlocked = loaded.hardFailure ?? loaded.blocked
        _hardFailure = loaded.hardFailure
        saveBlockLock.unlock()
        setLastKnownDigest(loaded.digest)

        // §0.3: only re-enter the load path to seed a genuinely absent local
        // library. A hard failure must not be re-read (it would take a second
        // backup) and must never be "recovered" by writing demo snippets.
        if (_cachedGroups ?? []).isEmpty && !expectsExistingLibrary && loaded.hardFailure == nil {
            _cachedGroups = loadGroupsUnlocked()
        }

        self.watcher = watcherFactory(fileURL)
        startWatching()
        Self.setActiveLibraryDirectory(fileURL.deletingLastPathComponent())

        // §0.3: an evicted iCloud library materializes in the background; pick it
        // up and announce it when it lands instead of having blocked init for it.
        if Self.isPotentiallyMaterializing(fileURL) {
            scheduleMaterializationReload()
        }
    }

    deinit { watcher?.stop() }

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

    public func loadGroups() -> [SnippetGroup] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = _cachedGroups {
            return cached
        }
        let groups = loadGroupsUnlocked()
        _cachedGroups = groups
        return groups
    }

    private struct Loaded {
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

    private func loadGroupsUnlocked() -> [SnippetGroup] {
        let loaded = Self.loadFrom(
            Location(fileURL: fileURL, expectsExistingLibrary: expectsExistingLibrary)
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
                "[Store] Library at \(self.fileURL.path, privacy: .public) is unreadable; saves are blocked until this is resolved."
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
        if let document = try? decoder.decode(SnippetDocument.self, from: data) {
            return document
        }
        let legacySnippets = try decoder.decode([SnippetModel].self, from: data)
        return SnippetDocument(snippets: legacySnippets)
    }

    public func saveSnippets(_ snippets: [SnippetModel]) {
        // Same RMW serialization as `importGroups`: read baseline, merge, save.
        rmwLock.lock()
        defer { rmwLock.unlock() }
        lock.lock()
        let existing = _cachedGroups ?? loadGroupsUnlocked()
        lock.unlock()

        let sanitized = Self.sanitize(snippets)
        var updated = existing

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
        saveGroupsSerialized(updated)
    }

    /// Commits `groups` as the whole library. The sanitize → write → cache-commit
    /// → purge sequence runs under `rmwLock`, so it cannot interleave with the
    /// read-modify-write mutations (`importGroups`, `saveSnippets`): a save whose
    /// payload was computed from a stale snapshot can still lose to a later
    /// logical writer, but its write and its orphan purge now land atomically —
    /// a purge never runs against library bytes other than the ones it computed.
    @discardableResult
    public func saveGroups(_ groups: [SnippetGroup]) -> SaveOutcome {
        rmwLock.lock()
        defer { rmwLock.unlock() }
        return saveGroupsSerialized(groups)
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
    private func saveGroupsSerialized(_ groups: [SnippetGroup]) -> SaveOutcome {
        let sanitized = Self.sanitizeGroups(groups)
        let outcome = writeGroupsToDisk(sanitized)

        guard outcome.didSave else {
            DevTypeLog.store.error(
                "[Store] Save did not land: \(String(describing: outcome), privacy: .public)"
            )
            publishSaveFailure(outcome)
            return outcome
        }

        lock.lock()
        _cachedGroups = sanitized
        let snippetListeners = listeners
        let groupListenersCopy = groupListeners
        lock.unlock()

        publishSaveFailure(nil)

        let flat = sanitized.flatMap(\.snippets)

        // Only after the bytes reached disk. A secret whose snippet is gone from the *saved*
        // library is unreachable — no UI can ever show it again — so leaving it in the keychain
        // means the user deleted a password and it silently stayed. Purging before the write
        // would destroy the value for a save that then failed, which is the worse mistake, so
        // this deliberately sits under `outcome.didSave`.
        purgeOrphanSecrets(liveIDs: Set(flat.map(\.id)))

        for listener in snippetListeners.values { listener(flat) }
        for listener in groupListenersCopy.values { listener(sanitized) }
        return outcome
    }

    /// Drop keychain entries for snippets that no longer exist.
    ///
    /// Guarded by `secretPurgeEnabled` because a store instance built over a *partial* library —
    /// the importers' scratch stores, and every test that saves two snippets to a temp directory —
    /// would otherwise read "these are all the snippets that exist" and delete the real library's
    /// secrets. Only the shared store, which owns the whole library, is allowed to purge.
    private func purgeOrphanSecrets(liveIDs: Set<UUID>) {
        guard secretPurgeEnabled else { return }
        let removed = secretStore.purgeOrphans(keeping: liveIDs)
        if removed > 0 {
            DevTypeLog.store.info(
                "[Store] purged \(removed, privacy: .public) orphaned secret(s) from the keychain"
            )
        }
    }

    /// §1.10: `.merge` shim preserving the original signature.
    @discardableResult
    public func importGroups(_ imported: [SnippetGroup]) -> SaveOutcome {
        importGroups(imported, mode: .merge).outcome
    }

    /// §1.10: the old implementation did `current[idx] = group`, so importing an
    /// Espanso `base.yml` (group name = file basename) or a TextExpander group
    /// called "General" replaced the user's default group wholesale. Merge is now
    /// the default and never drops a local snippet.
    @discardableResult
    public func importGroups(_ imported: [SnippetGroup], mode: ImportMode) -> ImportSummary {
        rmwLock.lock()
        defer { rmwLock.unlock() }
        var current = loadGroups()
        var created: [String] = []
        var updatedGroups: [String] = []
        var added = 0
        var changed = 0
        var unchanged = 0

        for group in imported {
            switch mode {
            case .intoNewGroup:
                var copy = group
                copy.name = Self.uniqueGroupName(base: group.name, existing: current.map(\.name))
                added += copy.snippets.count
                current.append(copy)
                created.append(copy.name)

            case .replaceGroup:
                if let idx = current.firstIndex(where: { $0.name == group.name }) {
                    added += group.snippets.count
                    current[idx] = group
                    updatedGroups.append(group.name)
                } else {
                    added += group.snippets.count
                    current.append(group)
                    created.append(group.name)
                }

            case .merge:
                if let idx = current.firstIndex(where: { $0.name == group.name }) {
                    let result = Self.mergeSnippets(incoming: group.snippets, into: current[idx].snippets)
                    current[idx].snippets = result.snippets
                    added += result.added
                    changed += result.updated
                    unchanged += result.unchanged
                    if result.added > 0 || result.updated > 0 {
                        updatedGroups.append(group.name)
                    }
                } else {
                    added += group.snippets.count
                    current.append(group)
                    created.append(group.name)
                }
            }
        }

        // `rmwLock` is already held for this whole read-modify-write; the public
        // `saveGroups` would try to re-acquire it and deadlock.
        let outcome = saveGroupsSerialized(current)
        return ImportSummary(
            mode: mode,
            groupsCreated: created,
            groupsUpdated: updatedGroups,
            snippetsAdded: added,
            snippetsUpdated: changed,
            snippetsUnchanged: unchanged,
            outcome: outcome
        )
    }

    private struct MergeResult {
        var snippets: [SnippetModel]
        var added: Int
        var updated: Int
        var unchanged: Int
    }

    private static func mergeSnippets(incoming: [SnippetModel], into local: [SnippetModel]) -> MergeResult {
        var result = local
        var exactIndex: [String: Int] = [:]
        var foldedIndex: [String: Int] = [:]
        for (i, snippet) in result.enumerated() where !snippet.triggerKeyword.isEmpty {
            if exactIndex[snippet.triggerKeyword] == nil {
                exactIndex[snippet.triggerKeyword] = i
            }
            let folded = snippet.triggerKeyword.lowercased()
            if foldedIndex[folded] == nil {
                foldedIndex[folded] = i
            }
        }

        var added = 0
        var updated = 0
        var unchanged = 0

        for candidate in incoming {
            let trigger = candidate.triggerKeyword
            let folded = trigger.lowercased()
            let match = trigger.isEmpty ? nil : (exactIndex[trigger] ?? foldedIndex[folded])

            guard let idx = match else {
                result.append(candidate)
                if !trigger.isEmpty {
                    let position = result.count - 1
                    if exactIndex[trigger] == nil { exactIndex[trigger] = position }
                    if foldedIndex[folded] == nil { foldedIndex[folded] = position }
                }
                added += 1
                continue
            }

            let localSnippet = result[idx]
            var mergedTags = localSnippet.tags
            for tag in candidate.tags where !mergedTags.contains(tag) {
                mergedTags.append(tag)
            }

            // Local identity and enablement win so usage stats, references, and a
            // deliberate "off" switch survive a re-import.
            let merged = SnippetModel(
                id: localSnippet.id,
                title: candidate.title.isEmpty ? localSnippet.title : candidate.title,
                label: candidate.label.isEmpty ? localSnippet.label : candidate.label,
                triggerKeyword: localSnippet.triggerKeyword,
                replacementText: candidate.replacementText,
                isCaseSensitive: candidate.isCaseSensitive,
                requireWordBoundary: candidate.requireWordBoundary,
                isPlainText: candidate.isPlainText,
                enabled: localSnippet.enabled,
                imagePath: candidate.imagePath.isEmpty ? localSnippet.imagePath : candidate.imagePath,
                createdAt: localSnippet.createdAt,
                updatedAt: Date(),
                usageCount: localSnippet.usageCount,
                tags: mergedTags,
                includeApps: candidate.includeApps.isEmpty ? localSnippet.includeApps : candidate.includeApps,
                excludeApps: candidate.excludeApps.isEmpty ? localSnippet.excludeApps : candidate.excludeApps
            )

            let identical = localSnippet.title == merged.title
                && localSnippet.label == merged.label
                && localSnippet.replacementText == merged.replacementText
                && localSnippet.isCaseSensitive == merged.isCaseSensitive
                && localSnippet.requireWordBoundary == merged.requireWordBoundary
                && localSnippet.isPlainText == merged.isPlainText
                && localSnippet.imagePath == merged.imagePath
                && localSnippet.tags == merged.tags
                && localSnippet.includeApps == merged.includeApps
                && localSnippet.excludeApps == merged.excludeApps

            if identical {
                unchanged += 1
            } else {
                result[idx] = merged
                updated += 1
            }
        }

        return MergeResult(snippets: result, added: added, updated: updated, unchanged: unchanged)
    }

    private static func uniqueGroupName(base: String, existing: [String]) -> String {
        let name = base.isEmpty ? SnippetDocument.defaultGroupName : base
        let taken = Set(existing)
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name) \(suffix)") { suffix += 1 }
        return "\(name) \(suffix)"
    }

    // MARK: - Usage statistics (§1.5)

    /// §1.5: no longer rewrites the library. Counters go to `UsageStatsStore`,
    /// which coalesces writes (~5 s) and flushes on terminate.
    public func incrementUsage(for snippetID: UUID) {
        usageStatsStore.recordUsage(for: snippetID)
    }

    /// Live usage count: sidecar value, falling back to the legacy in-library
    /// counter for snippets that have not been used since the migration.
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
    public func exportLibraryData() throws -> Data {
        try Self.encodeLibrary(loadGroups())
    }

    /// §0.4: writes the export to `url` (use with `NSSavePanel`).
    public func exportLibrary(to url: URL) throws {
        let data = try exportLibraryData()
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Single encode implementation reused by export, backups, and relocation.
    static func encodeLibrary(_ groups: [SnippetGroup]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(SnippetDocument(groups: groups))
    }

    // MARK: - Save state (§1.4 / §0.3)

    /// §1.4: last save that did not land, or `nil` when the last save succeeded.
    public var lastSaveFailure: SaveOutcome? {
        saveBlockLock.lock()
        defer { saveBlockLock.unlock() }
        return _lastSaveFailure
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

    /// §0.3: user-driven recovery — stop refusing saves. The next save overwrites
    /// whatever is on disk, so callers must confirm first and should offer
    /// `exportLibrary(to:)` beforehand.
    public func clearLibraryReadFailure() {
        saveBlockLock.lock()
        _hardFailure = nil
        _saveBlocked = nil
        saveBlockLock.unlock()
        publishSaveFailure(nil)
    }

    /// §0.3: the single deliberate escape hatch that bypasses the hard-fail latch
    /// and the digest guard. Nothing on the load path may call this.
    @discardableResult
    public func forceOverwriteLibrary(with groups: [SnippetGroup]) -> SaveOutcome {
        let sanitized = Self.sanitizeGroups(groups)
        let outcome = writeGroupsToDisk(sanitized, force: true, bypassHardFailure: true)
        guard outcome.didSave else {
            publishSaveFailure(outcome)
            return outcome
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
        return outcome
    }

    private func publishSaveFailure(_ outcome: SaveOutcome?) {
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

    /// §1.13: keep this device's library. Marks every conflict version resolved,
    /// removes the others, and force-writes the in-memory cache.
    @discardableResult
    public func resolveConflictsKeepingLocal() -> SaveOutcome {
        Self.markConflictsResolved(at: fileURL)
        setPendingConflicts([])
        let groups = loadGroups()
        let outcome = writeGroupsToDisk(groups, force: true, bypassHardFailure: true)
        if outcome.didSave {
            saveBlockLock.lock()
            _hardFailure = nil
            saveBlockLock.unlock()
            publishSaveFailure(nil)
        } else {
            publishSaveFailure(outcome)
        }
        return outcome
    }

    /// §1.13: accept whatever the current (winning) file holds and drop the others.
    @discardableResult
    public func resolveConflictsKeepingRemote() -> Bool {
        Self.markConflictsResolved(at: fileURL)
        setPendingConflicts([])
        reloadFromDisk()
        return pendingConflicts().isEmpty
    }

    /// Stores the snapshot without notifying. Safe to call while `lock` is held
    /// (`loadGroupsUnlocked` does) — it only touches `saveBlockLock`.
    @discardableResult
    private func storePendingConflicts(_ conflicts: [ConflictVersion]) -> Bool {
        saveBlockLock.lock()
        let changed = _pendingConflicts != conflicts
        _pendingConflicts = conflicts
        saveBlockLock.unlock()
        return changed
    }

    /// Must NOT be called while `lock` is held — it reads the listener table.
    private func setPendingConflicts(_ conflicts: [ConflictVersion]) {
        guard storePendingConflicts(conflicts) else { return }
        lock.lock()
        let observers = conflictListeners
        lock.unlock()
        for observer in observers.values { observer(conflicts) }
    }

    private static func unresolvedConflicts(at url: URL) -> [ConflictVersion] {
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

    private static func markConflictsResolved(at url: URL) {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) else { return }
        for version in versions { version.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }

    // MARK: - Writing

    @discardableResult
    private func writeGroupsToDisk(
        _ groups: [SnippetGroup],
        force: Bool = false,
        bypassHardFailure: Bool = false
    ) -> SaveOutcome {
        // §0.3: a latched read failure refuses even forced writes. Only
        // `forceOverwriteLibrary` / conflict resolution may bypass it.
        if !bypassHardFailure, let hard = hardFailure() { return hard }
        if !force, let blocked = blockedReason() { return blocked }

        let data: Data
        do {
            data = try Self.encodeLibrary(groups)
        } catch {
            DevTypeLog.store.error(
                "[Store] Failed to encode snippets: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }

        // §1.13: the digest re-check and the write happen inside one coordinated
        // write block, so the previous check-then-write TOCTOU window is closed
        // against other coordinated readers/writers (other DevType instances,
        // iCloud, Finder).
        var raceDetected = false
        var writeError: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: [.forReplacing],
            error: &coordinationError
        ) { actualURL in
            if !force {
                let onDisk = Self.currentDigest(at: actualURL)
                guard onDisk == self.lastKnownDigest() else {
                    raceDetected = true
                    return
                }
            }
            do {
                let parent = actualURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try data.write(to: actualURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if raceDetected {
            saveBlockLock.lock()
            _saveBlocked = .blockedByRemoteChange
            saveBlockLock.unlock()
            return .blockedByRemoteChange
        }
        if let error = coordinationError {
            DevTypeLog.store.error(
                "[Store] File coordination failed while saving: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }
        if let error = writeError {
            DevTypeLog.store.error(
                "[Store] Failed to save snippets: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }

        setLastKnownDigest(.sha(Self.sha256(of: data)))
        saveBlockLock.lock()
        _saveBlocked = nil
        saveBlockLock.unlock()
        return .saved
    }

    private func blockedReason() -> SaveOutcome? {
        saveBlockLock.lock()
        defer { saveBlockLock.unlock() }
        return _hardFailure ?? _saveBlocked
    }

    private func hardFailure() -> SaveOutcome? {
        saveBlockLock.lock()
        defer { saveBlockLock.unlock() }
        return _hardFailure
    }

    private func lastKnownDigest() -> FileDigest {
        digestLock.lock()
        defer { digestLock.unlock() }
        return savedDigest
    }

    private func setLastKnownDigest(_ digest: FileDigest) {
        digestLock.lock()
        savedDigest = digest
        digestLock.unlock()
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func currentDigest(at url: URL) -> FileDigest {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let raw = try? Data(contentsOf: url) else { return .unreadable }
        return .sha(sha256(of: raw))
    }

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
                "[Store] startDownloadingUbiquitousItem failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
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

    // MARK: Background materialization wait (§0.3)

    /// Serial utility queue for the post-launch iCloud wait. Deliberately separate
    /// from `coalesceQueue`: a pending download parks here for up to
    /// `ubiquitousDownloadTimeout` and must not delay external-change coalescing.
    private let materializeQueue = DispatchQueue(label: "devtype.store.materialize", qos: .utility)
    private let materializationLock = NSLock()
    /// Monotonic token so overlapping schedules collapse into one live poll.
    private var materializationGeneration: UInt64 = 0

    /// Polls for the library file on `materializeQueue` until it appears or
    /// `ubiquitousDownloadTimeout` elapses, then reloads from disk exactly like an
    /// external change. Deduped by generation: a newer schedule supersedes the
    /// polls of every older one, so repeated calls while the file is still absent
    /// never stack waits.
    private func scheduleMaterializationReload() {
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

    /// §0.3: timestamped, never-overwritten backup. The old code used a single
    /// `.bak` and deleted the previous one first, so a second failed load
    /// destroyed the only copy of the user's library.
    private static func makeTimestampedBackup(of url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        var candidate = url.appendingPathExtension("bak.\(stamp)")
        var suffix = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = url.appendingPathExtension("bak.\(stamp)-\(suffix)")
            suffix += 1
            if suffix > 1000 { return nil }
        }
        do {
            try fm.copyItem(at: url, to: candidate)
            DevTypeLog.store.notice(
                "[Store] Wrote library backup \(candidate.lastPathComponent, privacy: .public)"
            )
            return candidate
        } catch {
            DevTypeLog.store.error(
                "[Store] Could not back up unreadable library: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func loadFrom(_ location: Location) -> Loaded {
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
                "[Store] Failed to read snippets from \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            out.digest = .unreadable
            out.loadIssue = .unreadable(path: url.path, reason: error.localizedDescription)
            out.hardFailure = .failed("Could not read \(url.path): \(error.localizedDescription)")
            return out
        }

        out.digest = .sha(sha256(of: raw))

        let isBlank = raw.isEmpty
            || String(data: raw, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
        if isBlank {
            // An empty file is a legitimate (if suspicious) empty library — never
            // a reason to write demo snippets. Surface it instead.
            out.loadIssue = out.loadIssue ?? .emptyFile(path: url.path)
            out.decodeSucceeded = true
            return out
        }

        do {
            let document = try decodeDocument(from: raw)
            out.groups = document.groups
            out.decodeSucceeded = true
            if document.schemaVersion > SnippetDocument.currentSchemaVersion {
                out.blocked = .blockedByNewerSchema
            }
        } catch {
            DevTypeLog.store.error(
                "[Store] Failed to decode snippets from \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            if let backupURL = makeTimestampedBackup(of: url) {
                out.loadIssue = .corrupted(backupURL: backupURL)
            } else {
                out.loadIssue = .unreadable(path: url.path, reason: error.localizedDescription)
            }
            out.hardFailure = .failed("Could not decode \(url.path): \(error.localizedDescription)")
        }
        return out
    }

    // MARK: - External change detection (§2.5)

    private func startWatching() {
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
    private func reloadFromDisk() {
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

        let loaded = Self.loadFrom(Location(fileURL: fileURL, expectsExistingLibrary: expectsExistingLibrary))
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

        let flat = loaded.groups.flatMap(\.snippets)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for listener in snippetListeners.values { listener(flat) }
            for listener in groupListenersCopy.values { listener(loaded.groups) }
        }
    }

    /// Fires the conflict listeners with `pendingConflicts()`. Must NOT be called
    /// while any lock is held (it reads the listener table).
    private func notifyConflictListeners() {
        lock.lock()
        let observers = conflictListeners
        lock.unlock()
        let conflicts = pendingConflicts()
        for observer in observers.values { observer(conflicts) }
    }

    // MARK: - Store location switching

    @discardableResult
    public func saveSnippetsAs(toDirectory directory: URL) -> RelocationResult {
        let target = directory.appendingPathComponent(Self.syncedFileName)
        var backup: URL?
        if FileManager.default.fileExists(atPath: target.path),
           let existing = try? Data(contentsOf: target), !existing.isEmpty {
            backup = writeBackup(existing, tag: "pre-save-as")
        }
        let groups = loadGroups()
        guard let raw = try? Self.encodeLibrary(groups) else {
            return RelocationResult(success: false, backupURL: backup, message: "Could not encode library.", activeLocation: fileURL)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try raw.write(to: target, options: .atomic)
        } catch {
            return RelocationResult(success: false, backupURL: backup, message: error.localizedDescription, activeLocation: fileURL)
        }
        deviceDefaults.set(target.path, forKey: DeviceStateKey.storeLocationPath)
        return relocate(to: Location(fileURL: target, expectsExistingLibrary: true), backupURL: backup)
    }

    @discardableResult
    public func linkToSnippets(at target: URL) -> RelocationResult {
        let localBackup = exportCurrentLibrary(tag: "local-before-link")
        deviceDefaults.set(target.path, forKey: DeviceStateKey.storeLocationPath)
        return relocate(to: Location(fileURL: target, expectsExistingLibrary: true), backupURL: localBackup)
    }

    @discardableResult
    public func stopSyncing() -> RelocationResult {
        var backup: URL?
        if FileManager.default.fileExists(atPath: localDefaultURL.path),
           let existing = try? Data(contentsOf: localDefaultURL), !existing.isEmpty {
            backup = writeBackup(existing, tag: "pre-stop-sync")
        }
        let groups = loadGroups()
        guard let raw = try? Self.encodeLibrary(groups) else {
            return RelocationResult(success: false, backupURL: backup, message: "Could not encode library.", activeLocation: fileURL)
        }
        do {
            try FileManager.default.createDirectory(at: localDefaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try raw.write(to: localDefaultURL, options: .atomic)
        } catch {
            return RelocationResult(success: false, backupURL: backup, message: error.localizedDescription, activeLocation: fileURL)
        }
        deviceDefaults.removeObject(forKey: DeviceStateKey.storeLocationPath)
        return relocate(to: Location(fileURL: localDefaultURL, expectsExistingLibrary: false), backupURL: backup)
    }

    @discardableResult
    private func relocate(to location: Location, backupURL: URL?) -> RelocationResult {
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
        return RelocationResult(success: true, backupURL: backupURL, message: nil, activeLocation: fileURL)
    }

    private func exportCurrentLibrary(tag: String) -> URL? {
        guard let raw = try? Self.encodeLibrary(loadGroups()) else { return nil }
        return writeBackup(raw, tag: tag)
    }

    private func writeBackup(_ raw: Data, tag: String) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let url = localSupportDirectory.appendingPathComponent("devtype-backup-\(tag)-\(formatter.string(from: Date())).json")
        do {
            try FileManager.default.createDirectory(at: localSupportDirectory, withIntermediateDirectories: true)
            // Atomic like every other write here: a crash mid-write must not leave
            // a torn safety backup behind.
            try raw.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Unified import: auto-detects TextExpander vs Espanso and merges the
    /// resulting groups into the library. Single entry point for the UI.
    @discardableResult
    public func importSnippets(from url: URL) throws -> SnippetImporter.ImportResult {
        let result = try SnippetImporter.importFrom(url)
        _ = importGroups(result.groups)
        return result
    }

    /// §1.10: same as `importSnippets(from:)` but returns the merge diff.
    public func importSnippets(from url: URL, mode: ImportMode) throws -> (SnippetImporter.ImportResult, ImportSummary) {
        let result = try SnippetImporter.importFrom(url)
        let summary = importGroups(result.groups, mode: mode)
        return (result, summary)
    }

    /// Imports TextExpander data from a folder URL.
    @discardableResult
    public func importTextExpander(from folder: URL) throws -> TEImporter.ImportResult {
        let result = try TEImporter.importFolder(folder)
        _ = importGroups(result.groups)
        return result
    }

    /// Imports Espanso matches (Tier A static) from a config root, match folder, package, or YAML file.
    @discardableResult
    public func importEspanso(from url: URL) throws -> EspansoImporter.ImportResult {
        let result = try EspansoImporter.importFrom(url)
        _ = importGroups(result.groups)
        return result
    }

    // MARK: - Trigger hygiene (§1.9)

    /// §1.9: **non-destructive**. This used to silently drop empty-trigger and
    /// duplicate-trigger snippets on every save *and* every load, so duplicating a
    /// snippet and editing the body before the trigger lost the snippet at the next
    /// save. Problems are now reported through `triggerConflicts()` instead.
    public static func sanitize(_ snippets: [SnippetModel]) -> [SnippetModel] {
        snippets
    }

    public static func sanitizeGroups(_ groups: [SnippetGroup]) -> [SnippetGroup] {
        groups.map { group in
            var copy = group
            copy.snippets = sanitize(group.snippets)
            return copy
        }
    }

    /// User preference: report trigger conflicts (duplicates, shadowing, empty triggers) in the
    /// editor and library health UI. On by default; the menu bar exposes the switch.
    ///
    /// Only the *reporting* is optional. The matcher's behaviour with colliding triggers is
    /// unchanged either way — turning this off means "stop warning me", not "make `:Hi` and
    /// `:hi` both fire".
    public static let conflictDetectionDisabledDefaultsKey = "devtype.conflictDetection.disabled"

    public static var isConflictDetectionEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: conflictDetectionDisabledDefaultsKey) }
        set { UserDefaults.standard.set(!newValue, forKey: conflictDetectionDisabledDefaultsKey) }
    }

    /// §1.9: triggers the matcher will shadow, plus unusable (empty) triggers.
    ///
    /// Empty when the user has switched conflict detection off — every reporting surface
    /// (editor validation, library health) goes through here or checks the flag itself, so one
    /// switch silences all of them. `triggerConflicts(in:)` stays ungated: it is the pure
    /// detector, and callers that need the truth regardless of preference (tests, internals)
    /// use it directly.
    public func triggerConflicts() -> [TriggerConflict] {
        guard Self.isConflictDetectionEnabled else { return [] }
        return Self.triggerConflicts(in: loadGroups())
    }

    /// §1.9: case folding matches `AbbreviationMatcher` — case-sensitive snippets
    /// key on the exact trigger, case-insensitive ones on `lowercased()` — so the
    /// store and the matcher agree about what collides.
    public static func triggerConflicts(in groups: [SnippetGroup]) -> [TriggerConflict] {
        struct Entry {
            let id: UUID
            let groupName: String
            let trigger: String
            let caseSensitive: Bool
            /// True when `AbbreviationMatcher` fires this trigger the moment it appears at the
            /// buffer suffix, with no terminator. Mirrors match rules (1) and (2): a
            /// punctuation-started trigger fires immediately **regardless** of
            /// `requireWordBoundary`, and any trigger with the flag off fires immediately too.
            /// Only these can shadow a longer trigger.
            let firesWithoutTerminator: Bool
        }

        var empties: [Entry] = []
        var byFolded: [String: [Entry]] = [:]
        var all: [Entry] = []

        for group in groups {
            for snippet in group.snippets {
                // A secret never reaches the matcher (`EventTapEngine.snippets` filters it), so it
                // can neither shadow another trigger nor be shadowed, and an empty trigger on one
                // is intentional rather than a mistake to report. Including them here produced
                // conflicts the user could not act on and warnings about triggers that do nothing.
                guard snippet.isTypedTriggerExpandable else { continue }
                let trigger = snippet.triggerKeyword
                let punctuationStarted = trigger.first.map { !AbbreviationMatcher.isWordCharacter($0) } ?? false
                let entry = Entry(
                    id: snippet.id,
                    groupName: group.name,
                    trigger: trigger,
                    caseSensitive: snippet.isCaseSensitive,
                    firesWithoutTerminator: punctuationStarted || !snippet.requireWordBoundary
                )
                if trigger.isEmpty {
                    empties.append(entry)
                } else {
                    byFolded[trigger.lowercased(), default: []].append(entry)
                    // Disabled snippets cannot fire, so they neither shadow nor are shadowed.
                    if snippet.enabled { all.append(entry) }
                }
            }
        }

        var out: [TriggerConflict] = []
        if !empties.isEmpty {
            out.append(TriggerConflict(
                kind: .emptyTrigger,
                trigger: "",
                snippetIDs: empties.map(\.id),
                groupNames: empties.map(\.groupName)
            ))
        }

        for (folded, entries) in byFolded where entries.count > 1 {
            let sensitive = entries.filter(\.caseSensitive)
            let insensitive = entries.filter { !$0.caseSensitive }

            // Identical spellings among case-sensitive snippets: matcher keeps the first.
            var byExact: [String: [Entry]] = [:]
            for entry in sensitive { byExact[entry.trigger, default: []].append(entry) }
            for (spelling, dupes) in byExact where dupes.count > 1 {
                out.append(TriggerConflict(
                    kind: .duplicateTrigger,
                    trigger: spelling,
                    snippetIDs: dupes.map(\.id),
                    groupNames: dupes.map(\.groupName)
                ))
            }

            // Several case-insensitive snippets fold to one key: matcher keeps the first.
            if insensitive.count > 1 {
                out.append(TriggerConflict(
                    kind: .duplicateTrigger,
                    trigger: folded,
                    snippetIDs: insensitive.map(\.id),
                    groupNames: insensitive.map(\.groupName)
                ))
            }

            // Mixed: the case-sensitive entry wins for its exact spelling, so the
            // case-insensitive snippet is partially shadowed.
            if !insensitive.isEmpty && !sensitive.isEmpty {
                out.append(TriggerConflict(
                    kind: .caseShadow,
                    trigger: folded,
                    snippetIDs: entries.map(\.id),
                    groupNames: entries.map(\.groupName)
                ))
            }
        }

        // Prefix shadowing: a trigger that fires without a terminator makes every longer
        // trigger starting with it unreachable, because the short one fires on the keystroke
        // that completes it — the user never gets to type the rest.
        //
        // This is invisible without the check: both snippets look fine individually, the
        // longer one simply never fires. Note it is asymmetric — only the *shorter* trigger's
        // firing rule matters, since the longer one is never reached.
        for shadower in all where shadower.firesWithoutTerminator {
            // Fold exactly as the matcher keys: case-insensitive triggers compare lowercased.
            let shortKey = shadower.caseSensitive ? shadower.trigger : shadower.trigger.lowercased()
            var shadowed: [Entry] = []
            for candidate in all where candidate.id != shadower.id {
                let longKey = candidate.caseSensitive ? candidate.trigger : candidate.trigger.lowercased()
                guard longKey.count > shortKey.count, longKey.hasPrefix(shortKey) else { continue }
                shadowed.append(candidate)
            }
            guard !shadowed.isEmpty else { continue }
            let ordered = shadowed.sorted { $0.trigger < $1.trigger }
            out.append(TriggerConflict(
                kind: .prefixShadow,
                trigger: shadower.trigger,
                snippetIDs: [shadower.id] + ordered.map(\.id),
                groupNames: [shadower.groupName] + ordered.map(\.groupName),
                blockedTriggers: ordered.map(\.trigger)
            ))
        }

        return out.sorted { lhs, rhs in
            if lhs.trigger != rhs.trigger { return lhs.trigger < rhs.trigger }
            let l = lhs.snippetIDs.first?.uuidString ?? ""
            let r = rhs.snippetIDs.first?.uuidString ?? ""
            return l < r
        }
    }

    public func defaultSnippets() -> [SnippetModel] {
        return [
            SnippetModel(title: "Email Address", triggerKeyword: ":eml", replacementText: "user@devtype.app", isCaseSensitive: false, requireWordBoundary: true),
            SnippetModel(title: "Current Date", triggerKeyword: ":tdate", replacementText: "Today is {{date:yyyy-MM-dd}}", isCaseSensitive: false, requireWordBoundary: false),
            SnippetModel(title: "Greeting Template", triggerKeyword: ":hello", replacementText: "Hello, thanks for reaching out!\n\nBest regards,\nDevType Team", isCaseSensitive: false, requireWordBoundary: true),
            SnippetModel(title: "Function Signature", triggerKeyword: ":func", replacementText: "func {{cursor}}() {\n    // Implementation\n}", isCaseSensitive: false, requireWordBoundary: true)
        ]
    }

    public func search(_ query: String, limit: Int? = nil) -> [SearchHit] {
        SnippetSearch.run(query: query, in: loadGroups(), includeDisabled: false, limit: limit)
    }

    // MARK: - Image housekeeping (§3.7)

    /// §3.7: deletes stored images no live snippet references. Returns the file
    /// names removed (or that would be removed when `dryRun` is true).
    @discardableResult
    public func collectOrphanedImages(dryRun: Bool = false) -> [String] {
        ImageAttachmentStore.shared.collectOrphans(for: loadGroups(), dryRun: dryRun)
    }
}
