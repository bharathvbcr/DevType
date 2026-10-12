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

    fileprivate var hasUniqueSecretIDs: Bool {
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
    /// file, or a zero-byte one; with anything else, a missing backup means nothing was written.
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
        fileprivate let renderedSnippet: SnippetModel

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

            fileprivate init(snippet: SnippetModel, groupName: String, status: Status) {
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

        fileprivate init(plan: SnippetImporter.ImportPlan, items: [Item]) {
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
    /// Bumps `_libraryRevision` on every assignment, including the ones a future caller
    /// adds. Search's index cache keys on that counter instead of hashing every group and
    /// snippet to discover nothing changed — which it did on every keystroke in the command
    /// palette, at 627 µs per keystroke on a 2,000-snippet library.
    private var _cachedGroups: [SnippetGroup]? {
        didSet { _libraryRevision &+= 1 }
    }
    /// Monotonic, in-process only. Never persisted: it answers "is this the same library I
    /// indexed a moment ago", which is a question about this process's memory.
    private var _libraryRevision: UInt64 = 0
    private var _lastLoadIssue: LoadIssue?
    private var _saveBlocked: SaveOutcome?
    /// §0.3: latched when the library on disk could not be read/decoded. Blocks
    /// every save (including forced ones) until a clean reload or an explicit
    /// `clearLibraryReadFailure()` / `forceOverwriteLibrary(...)`.
    private var _hardFailure: SaveOutcome?
    private var _lastSaveFailure: SaveOutcome?
    private var _pendingConflicts: [ConflictVersion] = []
    /// Count only: account identifiers and values never cross the SecretStore boundary.
    private var _pendingSecretCleanupCount = 0

    private var fileURL: URL
    private var expectsExistingLibrary: Bool
    private let deviceDefaults: UserDefaults
    private let localSupportDirectory: URL
    private var localDefaultURL: URL { localSupportDirectory.appendingPathComponent("snippets.json") }
    /// Every copy this store keeps of a library file it is about to replace: rolling copies from
    /// saves, and the one-off safety copies taken before an overwrite, restore or relocation.
    let backups: LibraryBackupStore
    private var conflictRecoveryRoot: URL {
        localSupportDirectory.appendingPathComponent("ConflictRecovery", isDirectory: true)
    }
    private let conflictRecoveryPruneQueue = DispatchQueue(
        label: "devtype.store.conflict-recovery-prune",
        qos: .utility
    )
    private let conflictRecoveryPruneLock = NSLock()
    private var _lastConflictRecoveryPrune: LibraryConflictRecovery.PruneReport?

    private let watcherFactory: (URL) -> StoreWatching?
    private var watcher: StoreWatching?
    private let digestLock = NSLock()
    private var savedDigest: FileDigest = .absent

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
    private let rmwLock = NSLock()

    private let concurrencyProbeLock = NSLock()
    private var concurrencyProbe: ConcurrencyProbe?
    private let secretCleanupRetryStateLock = NSLock()
    /// Covers the destructive sweep itself, including direct test/maintenance calls. The request
    /// queue is serial, but this also prevents a synchronous retry from racing that worker.
    private let secretCleanupExecutionLock = NSLock()
    private var secretCleanupRetryRunning = false
    private var secretCleanupRetryNeedsTrailingPass = false
    private var secretCleanupRetryCompletions: [(SecretStore.PurgeSummary) -> Void] = []
    private let secretCleanupRetryQueue = DispatchQueue(
        label: "devtype.store.secret-cleanup",
        qos: .utility
    )

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

    private func invokeConcurrencyProbe(_ keyPath: KeyPath<ConcurrencyProbe, (() -> Void)?>) {
        concurrencyProbeLock.lock()
        let callback = concurrencyProbe?[keyPath: keyPath]
        concurrencyProbeLock.unlock()
        callback?()
    }

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
    private static func firstNonWhitespaceByte(in data: Data) -> UInt8? {
        data.first { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
    }

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
    private func saveGroupsSerialized(_ groups: [SnippetGroup]) -> SaveOutcome {
        commitGroupsSerialized(groups, safetyKind: nil, bypassLatch: false).outcome
    }

    /// `safetyKind` makes the write keep whatever it replaces as that kind of backup, or not
    /// happen. `bypassLatch` additionally skips the save latch and digest guard; it is only for
    /// user-confirmed recovery, and clears the read-failure latch when the write lands.
    private func commitGroupsSerialized(
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
    private func purgeOrphanSecrets(
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
        return importGroupsSerialized(imported, mode: mode)
    }

    /// Caller owns `rmwLock`. Shared by the ordinary group API and the image
    /// promotion transaction so orphan collection cannot observe a promoted
    /// attachment before its library reference commits.
    private func importGroupsSerialized(
        _ imported: [SnippetGroup],
        mode: ImportMode
    ) -> ImportSummary {
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
                // "Duplicate" is a new library entity, not another occurrence of the vendor's
                // stable UUID. Repeating the same import must therefore create a fresh identity
                // every time, even when the first vendor UUID did not collide yet.
                copy.id = Self.freshGroupID(excluding: current)
                copy.name = Self.uniqueGroupName(base: group.name, existing: current.map(\.name))
                added += copy.snippets.count
                current.append(copy)
                created.append(copy.name)

            case .replaceGroup:
                if let idx = Self.importTargetIndex(named: group.name, in: current) {
                    added += group.snippets.count
                    var replacement = group
                    // Replacement keeps the local entity's identity; importing a vendor UUID
                    // must not invalidate selection/restoration state or collide with a peer.
                    replacement.id = current[idx].id
                    current[idx] = replacement
                    updatedGroups.append(group.name)
                } else {
                    var copy = group
                    if current.contains(where: { $0.id == copy.id }) {
                        copy.id = Self.freshGroupID(excluding: current)
                    }
                    added += group.snippets.count
                    current.append(copy)
                    created.append(group.name)
                }

            case .merge:
                if let idx = Self.importTargetIndex(named: group.name, in: current) {
                    let result = Self.mergeSnippets(incoming: group.snippets, into: current[idx].snippets)
                    current[idx].snippets = result.snippets
                    added += result.added
                    changed += result.updated
                    unchanged += result.unchanged
                    if result.added > 0 || result.updated > 0 {
                        updatedGroups.append(group.name)
                    }
                } else {
                    var copy = group
                    if current.contains(where: { $0.id == copy.id }) {
                        copy.id = Self.freshGroupID(excluding: current)
                    }
                    added += group.snippets.count
                    current.append(copy)
                    created.append(group.name)
                }

            case .skipConflicts:
                if let idx = Self.importTargetIndex(named: group.name, in: current) {
                    let result = Self.mergeSnippets(
                        incoming: group.snippets,
                        into: current[idx].snippets,
                        updateMatches: false
                    )
                    current[idx].snippets = result.snippets
                    added += result.added
                    unchanged += result.unchanged
                    if result.added > 0 {
                        updatedGroups.append(group.name)
                    }
                } else {
                    var copy = group
                    if current.contains(where: { $0.id == copy.id }) {
                        copy.id = Self.freshGroupID(excluding: current)
                    }
                    added += group.snippets.count
                    current.append(copy)
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

    /// Preview a prepared source against the store's current library snapshot.
    /// Commit still reloads under `rmwLock`, preserving edits made while the
    /// confirmation sheet is open.
    public func previewImport(_ plan: SnippetImporter.ImportPlan) -> ImportPreview {
        Self.previewImport(plan, against: loadGroups())
    }

    /// Pure preview seam for tests and UI projections. Same-named imported
    /// groups are simulated in order because commit does the same; a trigger in
    /// another group is deliberately not a collision.
    public static func previewImport(
        _ plan: SnippetImporter.ImportPlan,
        against existingGroups: [SnippetGroup]
    ) -> ImportPreview {
        var projected = existingGroups
        var items: [ImportPreview.Item] = []

        for group in plan.groups {
            if let index = importTargetIndex(named: group.name, in: projected) {
                let merge = mergeSnippets(incoming: group.snippets, into: projected[index].snippets)
                projected[index].snippets = merge.snippets
                items.append(contentsOf: zip(group.snippets, merge.statuses).map { snippet, status in
                    ImportPreview.Item(snippet: snippet, groupName: group.name, status: status)
                })
            } else {
                projected.append(group)
                items.append(contentsOf: group.snippets.map {
                    ImportPreview.Item(snippet: $0, groupName: group.name, status: .isNew)
                })
            }
        }

        return ImportPreview(plan: plan, items: items)
    }

    private static func importTargetIndex(named name: String, in groups: [SnippetGroup]) -> Int? {
        groups.firstIndex { $0.name == name && $0.id != SnippetDocument.secretGroupID }
    }

    private static func freshGroupID(excluding groups: [SnippetGroup]) -> UUID {
        let occupied = Set(groups.map(\.id))
        var candidate = UUID()
        while occupied.contains(candidate) { candidate = UUID() }
        return candidate
    }

    private struct MergeResult {
        var snippets: [SnippetModel]
        var added: Int
        var updated: Int
        var unchanged: Int
        var statuses: [ImportPreview.Status]
    }

    private static func mergeSnippets(
        incoming: [SnippetModel],
        into local: [SnippetModel],
        updateMatches: Bool = true
    ) -> MergeResult {
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
        var statuses: [ImportPreview.Status] = []

        for candidate in incoming {
            let trigger = candidate.triggerKeyword
            let folded = trigger.lowercased()
            let exactMatch = trigger.isEmpty ? nil : exactIndex[trigger]
            let foldedMatch = trigger.isEmpty ? nil : foldedIndex[folded]
            let match = exactMatch ?? foldedMatch

            guard let idx = match else {
                result.append(candidate)
                if !trigger.isEmpty {
                    let position = result.count - 1
                    if exactIndex[trigger] == nil { exactIndex[trigger] = position }
                    if foldedIndex[folded] == nil { foldedIndex[folded] = position }
                }
                added += 1
                statuses.append(.isNew)
                continue
            }

            let localSnippet = result[idx]
            statuses.append(
                exactMatch != nil || localSnippet.id == candidate.id ? .isUpdate : .isConflict
            )
            if !updateMatches {
                unchanged += 1
                continue
            }
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
                propagateCase: candidate.propagateCase,
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
                && localSnippet.propagateCase == merged.propagateCase
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

        return MergeResult(
            snippets: result,
            added: added,
            updated: updated,
            unchanged: unchanged,
            statuses: statuses
        )
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
        // (raw bytes, or the file itself moved aside when unreadable), or nothing is written.
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
    private func committedLiveSecretIDs() -> Set<UUID>? {
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

    private func confirmedLiveSecretIDsForCleanup() -> Set<UUID>? {
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
    /// when they cannot be read, the file itself moved into the backup directory. When neither is
    /// possible nothing is written: the result is `.failed`, the read-failure latch stays set, and
    /// the original file is untouched. The keep happens in `writeGroupsToDisk(force:)`, so no
    /// caller can reach the forced write without it.
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
    private func storePendingConflicts(_ conflicts: [ConflictVersion]) -> Bool {
        saveBlockLock.lock()
        let changed = _pendingConflicts != conflicts
        _pendingConflicts = conflicts
        saveBlockLock.unlock()
        return changed
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

    // MARK: - Writing

    /// What a write must do with the bytes it replaces.
    private enum BackupRequirement {
        /// An ordinary save: copy the previous bytes into a rolling backup when they changed.
        /// Failing to copy does not stop the save; it is reported as `.savedWithoutBackup`. A file
        /// that cannot be read at all is escalated to `.required(.preOverwrite)`, because
        /// overwriting bytes nobody can read again is not a save the user asked for.
        case rolling
        /// A replacement the user confirmed, or one onto a library they did not write here: the
        /// previous file must be preserved first, or nothing is written.
        case required(LibraryBackupStore.Kind)
    }

    private enum ReplaceResult {
        case written(backupURL: URL?, backupFailure: String?)
        /// The file already held exactly these bytes; nothing was written or copied.
        case unchanged
        case raceDetected
        case backupFailed(String)
        case failed(String)
    }

    /// The one coordinated replace every whole-library write goes through: saves, the forced
    /// overwrite, and Save As / Stop Syncing onto an existing file.
    ///
    /// §1.13: the digest re-check, the backup and the write happen inside one coordinated write
    /// block, so no other coordinated reader or writer (another DevType, iCloud, Finder) can land
    /// between them. The bytes read for the digest are the bytes backed up.
    private func coordinatedReplace(
        at url: URL,
        with data: Data,
        expecting expectedDigest: FileDigest?,
        backup requirement: BackupRequirement
    ) -> ReplaceResult {
        var result: ReplaceResult = .failed("File coordination did not run")
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: url,
            options: [.forReplacing],
            error: &coordinationError
        ) { actualURL in
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: actualURL.path)
            let onDisk = exists ? try? Data(contentsOf: actualURL) : nil
            if let expectedDigest {
                let digest: FileDigest = !exists
                    ? .absent
                    : onDisk.map { FileDigest.sha(Self.sha256(of: $0)) } ?? .unreadable
                guard digest == expectedDigest else {
                    result = .raceDetected
                    return
                }
            }
            if let onDisk, onDisk == data {
                result = .unchanged
                return
            }

            var backupURL: URL?
            var backupFailure: String?
            var movedAside = false
            var createdBackup = false
            let required: LibraryBackupStore.Kind?
            switch requirement {
            case .required(let kind): required = kind
            case .rolling: required = exists && onDisk == nil ? .preOverwrite : nil
            }
            if let required {
                do {
                    let preserved = try self.backups.preserve(fileAt: actualURL, bytes: onDisk, kind: required)
                    backupURL = preserved?.url
                    movedAside = preserved?.moved ?? false
                    createdBackup = preserved?.created ?? false
                } catch {
                    result = .backupFailed(
                        "The existing library was not replaced because a backup of it could not be saved: \(error.localizedDescription)"
                    )
                    return
                }
            } else if let onDisk, !onDisk.isEmpty {
                do {
                    let copy = try self.backups.backUp(onDisk, kind: .save)
                    backupURL = copy.url
                    if copy.created { self.backups.schedulePrune() }
                } catch {
                    backupFailure = error.localizedDescription
                }
            }

            do {
                try fm.createDirectory(at: actualURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: actualURL, options: .atomic)
                result = .written(backupURL: backupURL, backupFailure: backupFailure)
            } catch {
                if movedAside, let backupURL {
                    // The original was renamed into Backups; put it back where it was.
                    do {
                        try fm.moveItem(at: backupURL, to: actualURL)
                    } catch {
                        DevTypeLog.store.error(
                            "[Store] Could not return a moved-aside library after a failed write \(DevTypeLog.errorMetadata(error), privacy: .public)"
                        )
                    }
                }
                if !movedAside, createdBackup, let backupURL, let onDisk,
                   (try? Data(contentsOf: actualURL)).map({ Self.sha256(of: $0) }) == Self.sha256(of: onDisk) {
                    // The library is exactly as it was, so the safety copy guards nothing. When the
                    // live file changed (or cannot be re-read) the copy is kept.
                    self.backups.discard(backupURL)
                }
                DevTypeLog.store.error(
                    "[Store] Failed to write library \(DevTypeLog.errorMetadata(error), privacy: .public)"
                )
                result = .failed(error.localizedDescription)
            }
        }
        if let coordinationError {
            DevTypeLog.store.error(
                "[Store] File coordination failed while writing \(DevTypeLog.errorMetadata(coordinationError), privacy: .public)"
            )
            return .failed(coordinationError.localizedDescription)
        }
        return result
    }

    private struct DiskWrite {
        let outcome: SaveOutcome
        let backupURL: URL?
    }

    /// `force` skips the save block and the digest guard, and in exchange requires a safety copy
    /// of whatever it replaces — so the forced overwrite and the first-run seed cannot reach the
    /// file without the backup step, whichever caller they come from.
    @discardableResult
    private func writeGroupsToDisk(
        _ groups: [SnippetGroup],
        force: Bool = false,
        bypassHardFailure: Bool = false,
        safetyKind: LibraryBackupStore.Kind? = nil
    ) -> DiskWrite {
        // §0.3: a latched read failure refuses even forced writes. Only
        // `forceOverwriteLibrary` / conflict resolution may bypass it.
        if !bypassHardFailure, let hard = hardFailure() { return DiskWrite(outcome: hard, backupURL: nil) }
        if !force, let blocked = blockedReason() { return DiskWrite(outcome: blocked, backupURL: nil) }

        let data: Data
        do {
            data = try Self.encodeLibrary(groups)
        } catch {
            DevTypeLog.store.error(
                "[Store] Failed to encode snippets \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            return DiskWrite(outcome: .failed(error.localizedDescription), backupURL: nil)
        }

        let replaced = coordinatedReplace(
            at: fileURL,
            with: data,
            expecting: force ? nil : lastKnownDigest(),
            backup: force || safetyKind != nil ? .required(safetyKind ?? .preOverwrite) : .rolling
        )
        let outcome: SaveOutcome
        var backupURL: URL?
        switch replaced {
        case .raceDetected:
            saveBlockLock.lock()
            _saveBlocked = .blockedByRemoteChange
            saveBlockLock.unlock()
            return DiskWrite(outcome: .blockedByRemoteChange, backupURL: nil)
        case .backupFailed(let reason), .failed(let reason):
            return DiskWrite(outcome: .failed(reason), backupURL: nil)
        case .unchanged:
            outcome = .saved
        case .written(let url, let backupFailure):
            backupURL = url
            outcome = backupFailure.map(SaveOutcome.savedWithoutBackup) ?? .saved
        }

        setLastKnownDigest(.sha(Self.sha256(of: data)))
        saveBlockLock.lock()
        _saveBlocked = nil
        saveBlockLock.unlock()
        return DiskWrite(outcome: outcome, backupURL: backupURL)
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
        hexString(of: SHA256.hash(data: data))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Lowercase hex of a digest, built from a lookup table rather than one `String(format:)`
    /// (a varargs formatter plus a heap string) per byte.
    static func hexString<D: Sequence>(of bytes: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
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

    private static func loadFrom(_ location: Location, backups: LibraryBackupStore) -> Loaded {
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
    private func notifyConflictListeners() {
        lock.lock()
        let observers = conflictListeners
        lock.unlock()
        let conflicts = pendingConflicts()
        for observer in observers.values { observer(conflicts) }
    }

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

    /// Convenience for non-preview callers: auto-detect once, prepare a value
    /// plan, then merge that plan into the library.
    @discardableResult
    public func importSnippets(from url: URL) throws -> SnippetImporter.ImportResult {
        let plan = try SnippetImporter.prepareImport(from: url)
        let committed = commitImport(plan, mode: .merge)
        guard committed.summary.outcome.didSave else {
            throw SnippetImporter.ImportError.libraryCommitFailed
        }
        return committed.result
    }

    /// §1.10: same as `importSnippets(from:)` but returns the merge diff.
    public func importSnippets(from url: URL, mode: ImportMode) throws -> (SnippetImporter.ImportResult, ImportSummary) {
        let plan = try SnippetImporter.prepareImport(from: url)
        return commitImport(plan, mode: mode)
    }

    /// Commits the exact parsed value shown in the confirmation sheet. No URL is
    /// retained or read here; the store rebases these groups onto its current
    /// library under the existing serialized read-modify-write boundary.
    public func commitImport(
        _ plan: SnippetImporter.ImportPlan,
        mode: ImportMode
    ) -> (result: SnippetImporter.ImportResult, summary: ImportSummary) {
        rmwLock.lock()
        defer { rmwLock.unlock() }

        let materialized: SnippetImporter.MaterializedImport
        do {
            materialized = try plan.materializeAttachments()
        } catch {
            return (
                plan.result,
                ImportSummary(
                    mode: mode,
                    groupsCreated: [],
                    groupsUpdated: [],
                    snippetsAdded: 0,
                    snippetsUpdated: 0,
                    snippetsUnchanged: 0,
                    outcome: .failed("attachmentCommitFailed")
                )
            )
        }

        let summary = importGroupsSerialized(materialized.result.groups, mode: mode)
        guard summary.outcome.didSave else {
            materialized.rollbackAll()
            return (materialized.result, summary)
        }

        // `.skipConflicts` can deliberately decline an incoming image snippet.
        // Remove only files created by this promotion that the committed library
        // does not reference; never run a broad orphan sweep here.
        materialized.removeUnreferenced(from: loadGroups())
        return (materialized.result, summary)
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
        SnippetDocument(groups: groups).transactionGroups
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

    /// Resolves one conflict entry against the latest in-process library snapshot.
    ///
    /// This owns the complete read-modify-write under `rmwLock`. Passing the groups rendered by
    /// the sheet back to `saveGroups` would overwrite edits that landed while the user was
    /// reading or confirming the conflict. The UUID is resolved only after acquiring the lock,
    /// and cache/listener changes still happen only through `saveGroupsSerialized` after a real
    /// disk write.
    public func resolveTriggerConflict(
        snippetID: UUID,
        action: TriggerConflictResolutionAction
    ) -> TriggerConflictResolutionOutcome {
        resolveTriggerConflict(action: action) { groups in
            var matches: [(group: Int, snippet: Int)] = []
            for groupIndex in groups.indices {
                for snippetIndex in groups[groupIndex].snippets.indices
                where groups[groupIndex].snippets[snippetIndex].id == snippetID {
                    matches.append((groupIndex, snippetIndex))
                }
            }
            // UUID-only callers remain idempotent for a well-formed library, but must fail closed
            // when malformed input makes that UUID name more than one physical entry.
            return matches.count == 1 ? matches[0] : nil
        }
    }

    /// Resolves the exact occurrence rendered by the conflict sheet. Unlike the compatibility
    /// UUID-only entry point, this can safely address non-identical duplicate UUIDs. Any moved,
    /// reordered, edited, or indistinguishable duplicate is a stale/ambiguous target and is refused.
    public func resolveTriggerConflict(
        target: TriggerConflictTarget,
        action: TriggerConflictResolutionAction
    ) -> TriggerConflictResolutionOutcome {
        resolveTriggerConflict(action: action) { groups in
            guard target.occurrence >= 0 else { return nil }
            var matches: [(group: Int, snippet: Int)] = []

            for groupIndex in groups.indices where groups[groupIndex].id == target.groupID {
                let sameID = groups[groupIndex].snippets.indices.filter {
                    groups[groupIndex].snippets[$0].id == target.snippetID
                }
                guard sameID.indices.contains(target.occurrence) else { continue }
                let snippetIndex = sameID[target.occurrence]
                let candidate = groups[groupIndex].snippets[snippetIndex]
                guard Self.matchesRenderedConflictTarget(
                    candidate,
                    rendered: target.renderedSnippet,
                    action: action
                ) else { continue }

                // Two byte-for-byte-equivalent duplicate identities cannot be distinguished by a
                // stale UI row even with an ordinal; reject rather than guessing which one moved.
                let indistinguishable = sameID.filter {
                    Self.matchesRenderedConflictTarget(
                        groups[groupIndex].snippets[$0],
                        rendered: target.renderedSnippet,
                        action: action
                    )
                }
                guard indistinguishable.count == 1 else { continue }
                matches.append((groupIndex, snippetIndex))
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    private func resolveTriggerConflict(
        action: TriggerConflictResolutionAction,
        locate: ([SnippetGroup]) -> (group: Int, snippet: Int)?
    ) -> TriggerConflictResolutionOutcome {
        rmwLock.lock()
        defer { rmwLock.unlock() }

        lock.lock()
        var groups = _cachedGroups ?? loadGroupsUnlocked()
        lock.unlock()

        guard let location = locate(groups) else { return .targetUnavailable }

        switch action {
        case .disable:
            // The requested state already holds. Avoid a needless whole-library write while
            // still reporting success: the stale conflict is resolved and a reload will remove it.
            if !groups[location.group].snippets[location.snippet].enabled {
                return .persisted
            }
            groups[location.group].snippets[location.snippet].enabled = false
        case .delete:
            groups[location.group].snippets.remove(at: location.snippet)
        }

        let outcome = saveGroupsSerialized(groups)
        return outcome.didSave ? .persisted : .refused(outcome)
    }

    private static func matchesRenderedConflictTarget(
        _ candidate: SnippetModel,
        rendered: SnippetModel,
        action: TriggerConflictResolutionAction
    ) -> Bool {
        var candidate = candidate
        var rendered = rendered
        if action == .disable {
            // Another surface may already have converged on the requested disabled state. Enabled
            // is therefore the one mutable bit excluded from this action's stale-row fingerprint.
            candidate.enabled = false
            rendered.enabled = false
        }
        return candidate == rendered
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

        for group in groups where group.enabled {
            for snippet in group.snippets {
                // A secret never reaches the matcher (`EventTapEngine.snippets` filters it), so it
                // can neither shadow another trigger nor be shadowed, and an empty trigger on one
                // is intentional rather than a mistake to report. Including them here produced
                // conflicts the user could not act on and warnings about triggers that do nothing.
                // Disabled snippets and snippets in disabled groups are equally absent from the
                // matcher. Reporting either made the resolver's Disable action appear to work
                // while the same duplicate/case/empty warning immediately returned.
                guard snippet.enabled, snippet.isTypedTriggerExpandable else { continue }
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
                    all.append(entry)
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
        // Fold exactly as the matcher keys: case-insensitive triggers compare lowercased.
        // Folded once here rather than inside the scan — the nested loop this replaces folded
        // its candidate on every comparison, so a 1,000-trigger library allocated a million
        // strings to answer a question about prefixes. 180 ms at 2,000 triggers, on the main
        // thread, per keystroke while the Conflicts chip was active. See `TriggerPrefixScan`.
        let foldedKeys = all.map { $0.caseSensitive ? $0.trigger : $0.trigger.lowercased() }
        let scan = TriggerPrefixScan(foldedKeys: foldedKeys)
        for (index, shadower) in all.enumerated() where shadower.firesWithoutTerminator {
            var shadowed: [Entry] = []
            scan.forEachStrictExtension(of: index) { other in
                // A duplicate UUID names the same snippet twice; the old scan skipped those by
                // identity and this must keep doing so.
                guard all[other].id != shadower.id else { return }
                shadowed.append(all[other])
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

    /// Replaces snippet groups with the defaults while retaining the independent secrets under the same
    /// read-modify-write boundary as every other logical mutation. Callers receive the exact
    /// before/after pair and must not present success unless this result is `.saved`.
    @discardableResult
    public func resetToDefaults() -> GroupMutationResult {
        mutateGroups { groups in
            let secrets = SnippetDocument(groups: groups).secrets
            groups = SnippetDocument(groups: [SnippetGroup(
                name: SnippetDocument.defaultGroupName,
                snippets: defaultSnippets()
            )], secrets: secrets).transactionGroups
            return true
        }
    }

    public func search(_ query: String, limit: Int? = nil) -> [SearchHit] {
        let snapshot = loadGroupsWithRevision()
        return SnippetSearch.run(
            query: query,
            in: snapshot.groups,
            includeDisabled: false,
            limit: limit,
            revision: snapshot.revision,
            libraryID: searchCacheIdentity
        )
    }

    // MARK: - Image housekeeping (§3.7)

    /// Deletes one attachment only if the latest committed library still leaves it unreferenced.
    ///
    /// Post-save cleanup cannot safely act on the editor/manager's old snapshot: another mutation
    /// may have re-used the path after that save returned. The reference check and physical
    /// deletion therefore share the store's whole-library RMW lock. A changed disk digest is
    /// deferred until external state is adopted rather than treating a stale cache as authority.
    @discardableResult
    public func deleteImageIfUnreferenced(
        _ path: String,
        deleteImage: (String) -> Bool
    ) -> ImageCleanupResult {
        guard !path.isEmpty else { return .failed }

        invokeConcurrencyProbe(\.attachmentCleanupWillAcquireMutationLock)
        rmwLock.lock()

        lock.lock()
        let current = _cachedGroups ?? loadGroupsUnlocked()
        lock.unlock()

        let isReferenced = current.lazy
            .flatMap(\.snippets)
            .contains(where: { $0.imagePath == path })
        let result: ImageCleanupResult
        if isReferenced {
            result = .retainedReferenced
        } else if Self.currentDigest(at: fileURL) != lastKnownDigest() {
            result = .deferredRemoteChange
        } else if let blocked = blockedReason() {
            result = blocked == .blockedByRemoteChange ? .deferredRemoteChange : .failed
        } else {
            result = deleteImage(path) ? .removed : .failed
        }
        rmwLock.unlock()

        if result == .deferredRemoteChange {
            externalChangeDetected()
        }
        return result
    }

    /// §3.7: deletes stored images no live snippet references. Returns the file
    /// names removed (or that would be removed when `dryRun` is true).
    @discardableResult
    public func collectOrphanedImages(dryRun: Bool = false) -> [String] {
        rmwLock.lock()
        defer { rmwLock.unlock() }
        return ImageAttachmentStore.shared.collectOrphans(for: loadGroups(), dryRun: dryRun)
    }
}
