import CryptoKit
import Foundation

/// On-disk envelope for snippets. Versioned so future fields can migrate without wiping user data.
public struct SnippetDocument: Codable, Equatable {
    public static let currentSchemaVersion = 3
    public static let defaultGroupName = "General"

    public var schemaVersion: Int
    public var groups: [SnippetGroup]
    public var secrets: [SecretModel]

    // Internal projection into the established whole-library transaction owner. The reserved
    // group is never encoded or offered as a user snippet group.
    static let secretGroupID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    public var transactionGroups: [SnippetGroup] {
        guard !secrets.isEmpty else { return groups }
        return groups + [SnippetGroup(id: Self.secretGroupID, name: "Secrets", symbol: "key.fill",
                                      snippets: secrets.map(\.snippetAdapter))]
    }

    /// Flattened snippets for engine / legacy callers.
    public var snippets: [SnippetModel] {
        transactionGroups.flatMap(\.snippets)
    }

    public init(schemaVersion: Int = SnippetDocument.currentSchemaVersion, groups: [SnippetGroup], secrets: [SecretModel] = []) {
        self.schemaVersion = schemaVersion
        self.secrets = secrets + SnippetStore.expandableSnippets(in: groups)
            .filter(\.isSecret).map(SecretModel.init(migrating:))
        // A reserved-ID group holding real snippets is user data that must not be dropped — but it
        // must not keep the reserved identity either. Retaining it produced a `transactionGroups`
        // projection with two groups sharing one ID, and every mutation that walks that projection
        // resolves a group by `firstIndex(where: { $0.id == ... })`. `encode` already refused such a
        // document, so this could never reach disk; the damage was to the in-memory projection
        // handed to mutations before that refusal. Re-home the snippets under a fresh ID so the
        // reserved ID belongs exclusively to the projection below.
        self.groups = groups.compactMap { group in
            var copy = group
            copy.snippets.removeAll(where: \.isSecret)
            guard group.id == Self.secretGroupID else { return copy }
            // Nothing but secrets: this is the projection round-tripping back in, not user data.
            guard !copy.snippets.isEmpty else { return nil }
            copy.id = UUID()
            return copy
        }
    }

    /// Convenience: wrap a flat snippet list in the default group (v1 migration shape).
    public init(schemaVersion: Int = SnippetDocument.currentSchemaVersion, snippets: [SnippetModel]) {
        self.init(schemaVersion: schemaVersion, groups: [SnippetGroup(name: Self.defaultGroupName, snippets: snippets)])
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, groups, snippets, secrets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version > 0, !(container.contains(.groups) && container.contains(.snippets)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid or ambiguous library envelope."))
        }
        let decodedGroups: [SnippetGroup]
        if container.contains(.groups) {
            decodedGroups = try container.decode([SnippetGroup].self, forKey: .groups)
        } else if container.contains(.snippets), version < 3 {
            let flat = try container.decode([SnippetModel].self, forKey: .snippets)
            decodedGroups = [SnippetGroup(name: Self.defaultGroupName, snippets: flat)]
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "The library collection is missing."))
        }
        guard !decodedGroups.contains(where: { $0.id == Self.secretGroupID }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "A snippet group uses the reserved secret collection identifier."))
        }
        let decodedSecrets = version == 3 || container.contains(.secrets)
            ? try container.decode([SecretModel].self, forKey: .secrets) : []
        self.init(schemaVersion: version, groups: decodedGroups, secrets: decodedSecrets)
        guard hasUniqueSecretIDs else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Secret identifiers must be unique and distinct from snippet identifiers."))
        }
    }

    var hasUniqueSecretIDs: Bool {
        let ids = Set(secrets.map(\.id))
        return ids.count == secrets.count && ids.isDisjoint(with: groups.flatMap(\.snippets).map(\.id))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let normalized = SnippetDocument(schemaVersion: schemaVersion, groups: groups, secrets: secrets)
        guard normalized.hasUniqueSecretIDs,
              !normalized.groups.contains(where: { $0.id == Self.secretGroupID }) else {
            throw EncodingError.invalidValue("secret identifiers", .init(codingPath: encoder.codingPath,
                debugDescription: "Secret identifiers must be unique and distinct from snippet identifiers."))
        }
        try container.encode(max(schemaVersion, Self.currentSchemaVersion), forKey: .schemaVersion)
        try container.encode(normalized.groups, forKey: .groups)
        try container.encode(normalized.secrets, forKey: .secrets)
    }
}

public final class SnippetStore {
    /// Revisions are local to this instance, including when two stores read the same file.
    public let searchCacheIdentity = UUID()
    /// The one store that owns the whole library, and therefore the only one allowed to decide a
    /// keychain secret is orphaned.
    public static let shared = SnippetStore(
        location: SnippetStore.resolveLocation(defaults: .standard),
        watcherFactory: SnippetStore.defaultWatcherFactory,
        secretPurgeEnabled: true
    )

    let secretStore: SecretStore
    /// See `purgeOrphanSecrets`: off for partial / scratch stores, on for `shared`.
    let secretPurgeEnabled: Bool

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
        /// The library was written, but the rolling backup of the bytes it replaced was not.
        /// A backup is a safety net for the save, not a precondition of it; the reason is kept
        /// so the caller can say so, and the store has already logged the error.
        case savedWithoutBackup(String)
        case blockedByNewerSchema
        case blockedByRemoteChange
        case failed(String)

        public var didSave: Bool {
            switch self {
            case .saved, .savedWithoutBackup: return true
            case .blockedByNewerSchema, .blockedByRemoteChange, .failed: return false
            }
        }

        /// Stable, content-free label for public diagnostics. The associated failure prose is
        /// retained for user-facing recovery, but can contain a library path or an OS/provider
        /// description and must never be mirrored into a support report.
        public var diagnosticLabel: String {
            switch self {
            case .saved: return "saved"
            case .savedWithoutBackup: return "savedWithoutBackup"
            case .blockedByNewerSchema: return "blockedByNewerSchema"
            case .blockedByRemoteChange: return "blockedByRemoteChange"
            case .failed: return "failed"
            }
        }
    }

    /// Result of `forceOverwriteLibrary(with:)`: whether the replacement landed, and where the
    /// bytes it replaced were kept. `backupURL` is `nil` only when there was nothing to keep — no
    /// file, or one whose bytes were read and were empty. An unreadable file is linked first even
    /// when it is zero length; a missing backup then means nothing was written.
    public struct OverwriteResult: Equatable {
        public let outcome: SaveOutcome
        public let backupURL: URL?
        public var didSave: Bool { outcome.didSave }
    }

    /// Result of `restoreLibrary(fromBackup:)`. `preRestoreBackupURL` holds the library the
    /// restore replaced (`nil` when there was none on disk).
    public struct RestoreResult: Equatable {
        public let outcome: SaveOutcome
        public let preRestoreBackupURL: URL?
        public var didRestore: Bool { outcome.didSave }
    }

    /// One restorable backup, as "Restore from Backup…" lists it. `snippetCount` comes from the
    /// same versioned decoder a load uses; `nil` means the file does not decode as a library this
    /// version can open, and restoring it is refused.
    public struct LibraryBackup: Equatable {
        public let url: URL
        public let createdAt: Date
        public let kind: LibraryBackupStore.Kind
        public let snippetCount: Int?
    }

    /// Result of a store-owned whole-library read-modify-write.
    ///
    /// `saved` includes the exact current state that was read under `rmwLock` and the exact
    /// candidate committed from it. `rejected` means the caller's precondition no longer held;
    /// no write was attempted. `unchanged` likewise performs no write. Keeping these distinct
    /// prevents stale UI actions and stale undo snapshots from masquerading as successful saves.
    public enum GroupMutationResult: Equatable {
        case saved(before: [SnippetGroup], after: [SnippetGroup])
        case unchanged(current: [SnippetGroup])
        case rejected(current: [SnippetGroup])
        case refused(SaveOutcome)

        public var saveOutcome: SaveOutcome? {
            switch self {
            case .saved, .unchanged: return .saved
            case .rejected: return nil
            case .refused(let outcome): return outcome
            }
        }
    }

    /// Result of deleting one attachment through the library owner.
    ///
    /// Deletion is conditional because a path removed by one edit can be referenced again by a
    /// later edit before post-commit cleanup runs. Callers treat `retainedReferenced` as a
    /// successful cleanup decision, while deferred and failed operations remain retryable.
    public enum ImageCleanupResult: Equatable {
        case removed
        case retainedReferenced
        case deferredRemoteChange
        case failed
    }

    /// Deterministic synchronization points for concurrency regression tests. Production leaves
    /// this unset, so the persistence path pays only a lock-and-nil-check at each boundary.
    struct ConcurrencyProbe {
        var mutationDidRead: (() -> Void)?
        var externalReloadWillAcquireMutationLock: (() -> Void)?
        var externalReloadDidAdopt: (() -> Void)?
        var attachmentCleanupWillAcquireMutationLock: (() -> Void)?
        var secretCleanupRetryDidBeginPass: (() -> Void)?

        init(
            mutationDidRead: (() -> Void)? = nil,
            externalReloadWillAcquireMutationLock: (() -> Void)? = nil,
            externalReloadDidAdopt: (() -> Void)? = nil,
            attachmentCleanupWillAcquireMutationLock: (() -> Void)? = nil,
            secretCleanupRetryDidBeginPass: (() -> Void)? = nil
        ) {
            self.mutationDidRead = mutationDidRead
            self.externalReloadWillAcquireMutationLock = externalReloadWillAcquireMutationLock
            self.externalReloadDidAdopt = externalReloadDidAdopt
            self.attachmentCleanupWillAcquireMutationLock = attachmentCleanupWillAcquireMutationLock
            self.secretCleanupRetryDidBeginPass = secretCleanupRetryDidBeginPass
        }
    }

    /// A conflict-row action, expressed as an idempotent domain mutation rather than a UI
    /// toggle. The resolver can be stale by the time the user clicks; `disable` still converges
    /// on the requested state if another surface already disabled the snippet.
    public enum TriggerConflictResolutionAction: Equatable {
        case disable
        case delete
    }

    /// Stable identity for one rendered occurrence in a malformed library that may contain
    /// duplicate snippet UUIDs. `occurrence` is the zero-based ordinal among snippets with the
    /// same UUID in the same group; the full rendered value is retained as a content fingerprint,
    /// so a reordered, moved, or edited stale row is rejected instead of mutating another entry.
    public struct TriggerConflictTarget: Equatable {
        public let groupID: UUID
        public let snippetID: UUID
        public let occurrence: Int
        let renderedSnippet: SnippetModel

        public init(groupID: UUID, snippet: SnippetModel, occurrence: Int) {
            self.groupID = groupID
            self.snippetID = snippet.id
            self.occurrence = occurrence
            self.renderedSnippet = snippet
        }
    }

    /// The exact persistence result of a trigger-conflict action.
    public enum TriggerConflictResolutionOutcome: Equatable {
        case persisted
        /// The resolver's snapshot was stale, missing, or ambiguous.
        case targetUnavailable
        /// The candidate mutation was not committed. Carries the store's typed reason so the UI
        /// cannot present a refused or failed write as a successful resolution.
        case refused(SaveOutcome)
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
        /// Keep local matches unchanged and append only incoming snippets that do not conflict.
        case skipConflicts
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

    /// Read-only projection used by import confirmation UI. It is produced by
    /// the same merge implementation that commit uses, so collision scope and
    /// case-folding cannot drift into a second UI-only interpretation.
    public struct ImportPreview: Equatable {
        public enum Status: Equatable {
            case isNew
            case isUpdate
            case isConflict
        }

        public struct Item: Equatable {
            public let snippet: SnippetModel
            public let groupName: String
            public let status: Status

            init(snippet: SnippetModel, groupName: String, status: Status) {
                self.snippet = snippet
                self.groupName = groupName
                self.status = status
            }
        }

        /// The exact parsed payload these rows describe and confirmation commits.
        public let plan: SnippetImporter.ImportPlan
        public let items: [Item]
        public var newCount: Int { items.filter { $0.status == .isNew }.count }
        public var updateCount: Int { items.filter { $0.status == .isUpdate }.count }
        public var conflictCount: Int { items.filter { $0.status == .isConflict }.count }

        init(plan: SnippetImporter.ImportPlan, items: [Item]) {
            self.plan = plan
            self.items = items
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

    /// `message` explains a failure, or — on success — something the user should still know,
    /// such as a local backup that could not be written before a link.
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

    enum FileDigest: Equatable {
        case absent
        case unreadable
        case sha(String)
    }

    let lock = NSLock()
    /// Dedicated lock for `_saveBlocked` — NSLock is not re-entrant, so we
    /// cannot reuse `lock` here: `loadGroupsUnlocked` holds `lock` and calls
    /// `writeGroupsToDisk`, which also needs to touch `_saveBlocked`.
    /// Lock ordering rule: `lock` may be held while acquiring `saveBlockLock`,
    /// but never the reverse.
    let saveBlockLock = NSLock()
    var listeners: [UUID: ([SnippetModel]) -> Void] = [:]
    var groupListeners: [UUID: ([SnippetGroup]) -> Void] = [:]
    /// §1.4: lets the UI surface a save that never landed.
    var saveFailureListeners: [UUID: (SaveOutcome?) -> Void] = [:]
    /// §1.13: lets the UI surface an iCloud conflict instead of losing a side.
    var conflictListeners: [UUID: ([ConflictVersion]) -> Void] = [:]
    /// Bumps `_libraryRevision` on every assignment, including the ones a future caller
    /// adds. Search's index cache keys on that counter instead of hashing every group and
    /// snippet to discover nothing changed — which it did on every keystroke in the command
    /// palette, at 627 µs per keystroke on a 2,000-snippet library.
    var _cachedGroups: [SnippetGroup]? {
        didSet { _libraryRevision &+= 1 }
    }
    /// Monotonic, in-process only. Never persisted: it answers "is this the same library I
    /// indexed a moment ago", which is a question about this process's memory.
    var _libraryRevision: UInt64 = 0
    var _lastLoadIssue: LoadIssue?
    var _saveBlocked: SaveOutcome?
    /// §0.3: latched when the library on disk could not be read/decoded. Blocks
    /// every save (including forced ones) until a clean reload or an explicit
    /// `clearLibraryReadFailure()` / `forceOverwriteLibrary(...)`.
    var _hardFailure: SaveOutcome?
    var _lastSaveFailure: SaveOutcome?
    var _pendingConflicts: [ConflictVersion] = []
    /// Count only: account identifiers and values never cross the SecretStore boundary.
    var _pendingSecretCleanupCount = 0

    var fileURL: URL
    var expectsExistingLibrary: Bool
    let deviceDefaults: UserDefaults
    private let localSupportDirectory: URL
    var localDefaultURL: URL { localSupportDirectory.appendingPathComponent("snippets.json") }
    /// Every copy this store keeps of a library file it is about to replace: rolling copies from
    /// saves, and the one-off safety copies taken before an overwrite, restore or relocation.
    let backups: LibraryBackupStore
    var conflictRecoveryRoot: URL {
        localSupportDirectory.appendingPathComponent("ConflictRecovery", isDirectory: true)
    }
    let conflictRecoveryPruneQueue = DispatchQueue(
        label: "devtype.store.conflict-recovery-prune",
        qos: .utility
    )
    let conflictRecoveryPruneLock = NSLock()
    var _lastConflictRecoveryPrune: LibraryConflictRecovery.PruneReport?

    let watcherFactory: (URL) -> StoreWatching?
    var watcher: StoreWatching?
    let digestLock = NSLock()
    var savedDigest: FileDigest = .absent

    /// Serializes read-modify-write mutations (`importGroups`, `saveSnippets`) and
    /// the sanitize→write→cache-commit tail of every direct `saveGroups`.
    /// The per-call `lock` cannot span an RMW — `loadGroups()` and `saveGroups()`
    /// acquire it internally and unfair locks are not reentrant — so two
    /// overlapping merges both computed against the same cached baseline and the
    /// later write silently dropped the earlier one's groups. The on-disk digest
    /// guard does not catch this either: it defends against *external* writers,
    /// and every successful in-process write refreshes the digest that the check
    /// compares against.
    ///
    /// `saveGroups` is included so a direct save computed from a stale snapshot cannot
    /// interleave its file/cache commit with a logical mutation. Secret cleanup is deliberately
    /// excluded: securityd can stall indefinitely, so cleanup runs single-flight on its own queue
    /// and re-reads this store's canonical committed live-ID projection before each deletion.
    ///
    /// Held across listener dispatch (they fire from `saveGroupsSerialized`, which
    /// these methods all reach): a listener that synchronously calls back into
    /// `importGroups`/`saveSnippets`/`saveGroups` would self-deadlock. Every
    /// current listener hops to main asynchronously first.
    let rmwLock = NSLock()

    private let concurrencyProbeLock = NSLock()
    private var concurrencyProbe: ConcurrencyProbe?
    let secretCleanupRetryStateLock = NSLock()
    /// Covers the destructive sweep itself, including direct test/maintenance calls. The request
    /// queue is serial, but this also prevents a synchronous retry from racing that worker.
    let secretCleanupExecutionLock = NSLock()
    var secretCleanupRetryRunning = false
    var secretCleanupRetryNeedsTrailingPass = false
    var secretCleanupRetryCompletions: [(SecretStore.PurgeSummary) -> Void] = []
    let secretCleanupRetryQueue = DispatchQueue(
        label: "devtype.store.secret-cleanup",
        qos: .utility
    )

    /// §2.5: reentrancy guard. Set for the duration of an external-state apply so a
    /// watcher event produced by that apply cannot recurse back into `reloadFromDisk`.
    let externalStateLock = NSLock()
    var _isApplyingExternalState = false
    var externalChangeGeneration: UInt64 = 0
    /// §2.5: digest work (full-file read + SHA256) runs here, never on main.
    let coalesceQueue = DispatchQueue(label: "devtype.store.external", qos: .utility)

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

    static func setActiveLibraryDirectory(_ url: URL?) {
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

    /// Kept as the name most of the engine already reaches for; `SupportDirectory` owns
    /// the resolution.
    public static var defaultLocalSupportDirectory: URL { SupportDirectory.devType }

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
        let backups = LibraryBackupStore(
            directory: localSupportDirectory.appendingPathComponent("Backups", isDirectory: true)
        )
        self.backups = backups

        let loaded = Self.loadFrom(location, backups: backups)
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

    func installConcurrencyProbeForTesting(_ probe: ConcurrencyProbe?) {
        concurrencyProbeLock.lock()
        concurrencyProbe = probe
        concurrencyProbeLock.unlock()
    }

    func invokeConcurrencyProbe(_ keyPath: KeyPath<ConcurrencyProbe, (() -> Void)?>) {
        concurrencyProbeLock.lock()
        let callback = concurrencyProbe?[keyPath: keyPath]
        concurrencyProbeLock.unlock()
        callback?()
    }

    // MARK: Background materialization wait (§0.3)

    /// Serial utility queue for the post-launch iCloud wait. Deliberately separate
    /// from `coalesceQueue`: a pending download parks here for up to
    /// `ubiquitousDownloadTimeout` and must not delay external-change coalescing.
    let materializeQueue = DispatchQueue(label: "devtype.store.materialize", qos: .utility)
    let materializationLock = NSLock()
    /// Monotonic token so overlapping schedules collapse into one live poll.
    var materializationGeneration: UInt64 = 0
}
