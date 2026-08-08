import CryptoKit
import Foundation
import Security

/// Keychain-backed values for snippets marked `isSecret`.
///
/// The library file is plain JSON in Application Support. A password kept there is readable by
/// anything running as the user, ends up in Time Machine and in every export, and shows up in the
/// snippet editor over the user's shoulder. `SnippetModel.encode(to:)` therefore refuses to write
/// a secret's text at all — the value lives only here, keyed by the snippet's UUID, and is fetched
/// at the moment of use.
///
/// Scope of what this does and does not protect: the value is at rest in the login keychain, ACL'd
/// to this app, and never written to disk by DevType itself. It is *not* protected against a
/// process already running as the user with debugger rights, and it is on the pasteboard for as
/// long as the paste needs it. Those are the same limits every macOS password manager has.
public final class SecretStore {
    public static let shared = SecretStore()

    /// Legacy keychain service (§8.9). Items here were created by ad-hoc-signed builds; their
    /// `change_acl` ACL entry ended up empty, so the §8.10 partition heal is a silent no-op on
    /// them and every rebuild re-triggers the login-password dialog. Read for migration only.
    public static let service = "com.devtype.app.secret"

    /// Current keychain service (§8.10). Every item here was created by the cert-pinned
    /// identity, giving it a `change_acl` entry that identity matches — which is what makes the
    /// partition heal work and rebuilds silent. Distinct from anything the app might store
    /// later, so `purgeOrphans` can enumerate *only* snippet secrets and never delete an
    /// unrelated item.
    public static let serviceV2 = "com.devtype.app.secret.v2"

    /// Why a secret operation failed, in a form the UI can act on.
    ///
    /// `OSStatus` is kept because the difference between "user clicked Deny on the keychain
    /// prompt" (`errSecAuthFailed`) and "this build is not allowed to read the item"
    /// (`errSecMissingEntitlement`, after a signing-identity change) decides what to tell the user.
    public enum Failure: Error, Equatable {
        case keychain(OSStatus)
        case emptyValue

        public var status: OSStatus? {
            if case .keychain(let status) = self { return status }
            return nil
        }
    }

    private let backing: SecretBackingStore

    /// §8.11: the live store is file-first with the keychain reduced to one master-key item.
    /// Tests always inject a backing — the default touches the real keychain and filesystem.
    public init(backing: SecretBackingStore = ConsolidatedSecretBackingStore()) {
        self.backing = backing
    }

    // MARK: - Accounts

    /// The keychain account for a snippet. The UUID and nothing else: a trigger or title would
    /// put user-chosen text ("gmail password") into an attribute that is readable without
    /// unlocking the item.
    public static func account(for id: UUID) -> String { id.uuidString }

    public static func snippetID(forAccount account: String) -> UUID? { UUID(uuidString: account) }

    // MARK: - Operations

    /// Store (or replace) the secret for a snippet.
    ///
    /// An empty value is rejected rather than stored: "" is indistinguishable from "no secret" at
    /// every read site, and silently accepting it would produce a secret snippet that pastes
    /// nothing while looking configured.
    @discardableResult
    public func store(_ secret: String, for id: UUID) -> Result<Void, Failure> {
        guard !secret.isEmpty else { return .failure(.emptyValue) }
        let status = backing.set(secret, account: Self.account(for: id))
        return status == errSecSuccess ? .success(()) : .failure(.keychain(status))
    }

    /// Fetch the secret for a snippet, or `nil` when there is none / it cannot be read.
    ///
    /// Deliberately not `throws`: every caller is at the point of pasting, where the only useful
    /// distinction is "have a value" vs "do not". `SecretAccessDiagnostics` carries the detail
    /// for the diagnostic report.
    public func secret(for id: UUID) -> String? {
        backing.value(account: Self.account(for: id))
    }

    public func hasSecret(for id: UUID) -> Bool {
        backing.contains(account: Self.account(for: id))
    }

    /// Snippet IDs whose secrets still live in the legacy service (§8.10). Non-empty means the
    /// one-time migration flow should be offered before those secrets are copied.
    public func snippetIDsPendingMigration() -> Set<UUID> {
        Set(backing.legacyAccountsPendingMigration().compactMap(Self.snippetID(forAccount:)))
    }

    /// Run the migration batch. See `KeychainSecretBackingStore.migrateLegacy` for the dialog
    /// contract: `allowInteraction: true` is the only way this app ever shows a keychain prompt.
    @discardableResult
    public func migrateLegacy(allowInteraction: Bool) -> SecretMigrationSummary {
        backing.migrateLegacy(allowInteraction: allowInteraction)
    }

    /// See `SecretBackingStore.keychainLocked` — tells "locked" apart from "missing".
    public func isKeychainLocked() -> Bool { backing.keychainLocked() }

    /// See `SecretBackingStore.requestKeychainUnlock` — explained-first dialog doorway.
    @discardableResult
    public func requestKeychainUnlock() -> Bool { backing.requestKeychainUnlock() }

    /// §8.11: sweep keychain-resident secrets into the encrypted archive. Silent by
    /// construction; the app calls it at launch, when v2 reads are known-good for the
    /// running identity — exactly the moment to move them.
    @discardableResult
    public func consolidateSecrets() -> SecretConsolidationSummary {
        backing.consolidateIntoFile()
    }

    /// One value-free line for the diagnostic report describing where secrets live.
    public func storageDescription() -> String { backing.storageDescription() }

    @discardableResult
    public func remove(for id: UUID) -> Result<Void, Failure> {
        let status = backing.delete(account: Self.account(for: id))
        // Deleting something that is not there is the desired end state, not an error.
        if status == errSecSuccess || status == errSecItemNotFound { return .success(()) }
        return .failure(.keychain(status))
    }

    /// Delete every stored secret whose snippet no longer exists.
    ///
    /// Without this, deleting a secret snippet leaves its password in the keychain forever — the
    /// user believes they removed it, and nothing in the UI would ever show them otherwise.
    /// Returns the number of items removed.
    @discardableResult
    public func purgeOrphans(keeping liveIDs: Set<UUID>) -> Int {
        // Through `orphanAccounts`, which owns the rule the loop here once skipped: an account
        // that does not parse as a UUID is *not* ours to delete. Latent until §8.11 put the
        // master key — the first non-UUID account — under the same service.
        var removed = 0
        for account in Self.orphanAccounts(stored: backing.accounts(), liveIDs: liveIDs) {
            if backing.delete(account: account) == errSecSuccess { removed += 1 }
        }
        return removed
    }

    /// Pure policy: which stored accounts are orphans, given the live snippet IDs?
    ///
    /// Split out so the destructive half can be tested without a keychain, and so the rule is
    /// stated once: an account that does not parse as a UUID is *not* ours to delete, even though
    /// it sits under our service name. Deleting what we do not understand is how a bug in this
    /// function becomes someone's lost credential.
    public static func orphanAccounts(stored: Set<String>, liveIDs: Set<UUID>) -> Set<String> {
        let live = Set(liveIDs.map(account(for:)))
        return stored.filter { candidate in
            guard snippetID(forAccount: candidate) != nil else { return false }
            return !live.contains(candidate)
        }
    }
}

// MARK: - Backing store

/// The three keychain operations `SecretStore` needs, behind a protocol so the tests never touch
/// the real keychain — which prompts, depends on the signing identity, and would leave items
/// behind on the developer's machine.
public protocol SecretBackingStore: AnyObject {
    func set(_ value: String, account: String) -> OSStatus
    func value(account: String) -> String?
    func contains(account: String) -> Bool
    func delete(account: String) -> OSStatus
    func accounts() -> Set<String>
    /// Legacy-service accounts that still need migrating (empty for stores with no legacy tier).
    func legacyAccountsPendingMigration() -> [String]
    /// Move every legacy item to the current service. `allowInteraction` is the ONE switch in
    /// this API that may put a system dialog on screen — callers own the moment it flips.
    func migrateLegacy(allowInteraction: Bool) -> SecretMigrationSummary
    /// Is the backing keychain currently locked? A locked keychain fails every decrypt while
    /// metadata queries keep working, which without this check masquerades as "no secret".
    func keychainLocked() -> Bool
    /// Ask the system to unlock — may show the system unlock dialog, so callers explain first.
    func requestKeychainUnlock() -> Bool
    /// §8.11: move keychain-resident secrets into the encrypted archive. Silent; safe to call
    /// every launch (no-op once everything is consolidated).
    func consolidateIntoFile() -> SecretConsolidationSummary
    /// One value-free line for the diagnostic report describing where secrets live.
    func storageDescription() -> String
}

extension SecretBackingStore {
    /// Stores without a legacy tier (the in-memory test double) have nothing to migrate.
    public func legacyAccountsPendingMigration() -> [String] { [] }
    public func migrateLegacy(allowInteraction: Bool) -> SecretMigrationSummary {
        SecretMigrationSummary()
    }
    /// An in-memory store has no lock to be behind.
    public func keychainLocked() -> Bool { false }
    public func requestKeychainUnlock() -> Bool { true }
    /// Nothing to consolidate in a store without a keychain tier.
    public func consolidateIntoFile() -> SecretConsolidationSummary { SecretConsolidationSummary() }
    public func storageDescription() -> String { "in-memory" }
}

/// What one consolidation pass achieved. `remaining` counts keychain-resident secrets that
/// could not be moved yet (unreadable silently, or no master key while the keychain is locked).
public struct SecretConsolidationSummary: Equatable {
    public var moved: Int
    public var remaining: Int
    public var failed: Int

    public init(moved: Int = 0, remaining: Int = 0, failed: Int = 0) {
        self.moved = moved
        self.remaining = remaining
        self.failed = failed
    }
}

// MARK: - Partition policy (§8.10)

/// Why the file-based keychain asks for the login password after every rebuild, and what this
/// app does about it. Established empirically on this machine (macOS 27, 2026-08-08), because
/// TN3137 documents only that the file-based access model "is completely different" — the
/// partition mechanics below appear in no Apple document we could find.
///
/// Since macOS 10.12, reading a file-based item requires passing **two** checks:
///
/// 1. The ACL application entry — for this app, cert-pinned:
///    `identifier "com.devtype.app" and certificate root = H"…"`. Stable across rebuilds.
/// 2. The **partition list** (`partition_id` ACL entry). For apps signed by an Apple-issued
///    certificate this records `teamid:…`, which is stable. For a self-signed certificate
///    macOS falls back to recording the per-build `cdhash:…` — so the check breaks on every
///    rebuild, and "Always Allow" (which edits this list, hence the password field in that
///    dialog) authorizes one build only.
///
/// The measured escape: a **metadata-only `SecItemUpdate`** by an app that matches check 1
/// appends the caller's partition to the list — silently, and without touching the value. An
/// app that fails check 1 can vandalize the value (the `encrypt` entry is open) but its
/// partition never grants a read, so healing is gated by the certificate exactly like the read
/// itself. `KeychainSecretBackingStore.value` heals and retries before it ever lets the system
/// put a password dialog on screen.
///
/// Deletion has no such escape: `SecItemDelete` is owner-checked against the *creating build*
/// (`errSecInvalidOwnerEdit` from any other, even after a heal), so cross-build deletes destroy
/// the value in place and leave a marked husk instead — see `tombstoneDescription`.
public enum KeychainPartitionPolicy {
    /// `kSecAttrComment` written by the heal update. The write is what heals; the text is
    /// honest labeling for anyone inspecting the item in Keychain Access.
    public static let healComment = "Managed by DevType"

    /// `kSecAttrDescription` ("Kind" in Keychain Access) for a live secret.
    public static let liveDescription = "DevType secret"

    /// `kSecAttrDescription` marking an item whose value was destroyed because the item itself
    /// could not be deleted (owner build gone). Husks are invisible to every API here.
    public static let tombstoneDescription = "DevType retired secret"

    /// What a tombstoned item's value is overwritten with. Non-empty on purpose:
    /// `SecItemUpdate` silently ignores an empty `kSecValueData`, leaving the secret intact —
    /// measured, not guessed.
    public static let tombstoneValue = "retired"

    public static func isTombstone(description: String?) -> Bool {
        description == tombstoneDescription
    }
}

/// Which keychain service to try, in what order, and when a legacy hit must move (§8.10).
///
/// The split exists because the legacy items are *incurable in place*: their `change_acl` ACL
/// entry lists no applications (a leftover of ad-hoc creation plus Always-Allow surgery), so
/// the partition heal that keeps current-epoch items silent can never take effect on them —
/// measured on the real items: no comment written, no partition appended, dialog back on the
/// next build. The only fix is a fresh item created by the stable cert identity, which is
/// exactly what migration does the first time a legacy value is successfully read (one last
/// system dialog) or re-saved in the editor (no dialog at all).
public enum SecretServiceEpoch: CaseIterable, Equatable {
    case current
    case legacy

    public var service: String {
        switch self {
        case .current: return SecretStore.serviceV2
        case .legacy: return SecretStore.service
        }
    }

    /// Short name for the diagnostics trail.
    public var trailName: String {
        switch self {
        case .current: return "v2"
        case .legacy: return "legacy"
        }
    }

    /// Current first: once an account is migrated, the legacy husk must never shadow it.
    public static let readOrder: [SecretServiceEpoch] = [.current, .legacy]

    /// A value read out of the legacy service moves to the current one immediately — that
    /// read may have cost the user a password dialog, and migrating is what makes it the last.
    public static func shouldMigrate(from epoch: SecretServiceEpoch, readSucceeded: Bool) -> Bool {
        epoch == .legacy && readSucceeded
    }
}

/// The read sequence as a pure state machine, so the retry logic is table-testable without a
/// keychain. Phases: a silent attempt, a silent attempt after healing, and a final attempt with
/// the system password dialog allowed (the legitimate fallback when the signing identity itself
/// changed — Always Allow then re-pins the ACL entry and later builds heal silently again).
public enum KeychainReadPlan {
    public enum Phase: Equatable { case silent, healed, interactive }
    public enum Step: Equatable {
        /// Value in hand; stop.
        case succeed
        /// No value to be had; stop.
        case fail
        /// Metadata-touch the item to re-partition it, then retry silently.
        case heal
        /// Allow the system password dialog and retry once.
        case askUser
    }

    public static func step(after status: OSStatus, phase: Phase) -> Step {
        if status == errSecSuccess { return .succeed }
        // Absent is absent — no amount of healing or prompting invents an item.
        if status == errSecItemNotFound { return .fail }
        switch phase {
        case .silent: return .heal
        case .healed: return .askUser
        case .interactive: return .fail
        }
    }
}

/// How the most recent keychain read went — the one fact the diagnostic report needs to tell
/// "policy bug" apart from "user has no enrolled finger" apart from "keychain said no".
/// Never carries an account, a title, or a value.
public enum SecretReadOutcome: Equatable {
    case none
    case ok
    case healed
    case granted
    case failed(OSStatus)

    public var label: String {
        switch self {
        case .none: return "no reads this run"
        case .ok: return "ok"
        case .healed: return "ok (healed partition after rebuild)"
        case .granted: return "ok (user granted via password dialog)"
        case .failed(let status): return "failed (\(status))"
        }
    }
}

/// Read recorder plus a step trail, kept apart from `SecretBackingStore` so the protocol (and
/// its in-memory test double) stays three operations wide.
///
/// The trail is what turns "it prompted again" into a diagnosis: every fetch, heal, migration
/// copy and destroy appends one line with its `OSStatus`. Accounts are aliased (`item A`,
/// `item B`, …) in first-seen order — the report must never carry a real account, because the
/// account is the snippet's UUID and the report is pasted into chat windows.
public final class SecretAccessDiagnostics {
    public static let shared = SecretAccessDiagnostics()
    /// Enough for several full read/migrate cycles; old steps fall off the front.
    public static let trailCapacity = 48

    private let lock = UnfairLock()
    private var last: SecretReadOutcome = .none
    private var steps: [String] = []
    private var aliases: [String: String] = [:]

    public init() {}

    public func record(_ outcome: SecretReadOutcome) {
        lock.lock(); defer { lock.unlock() }
        last = outcome
    }

    public func lastRead() -> SecretReadOutcome {
        lock.lock(); defer { lock.unlock() }
        return last
    }

    /// Append one value-free step, e.g. `note("legacy fetch", -25293, account: account)`.
    public func note(_ step: String, _ status: OSStatus? = nil, account: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var line = step
        if let account { line = "\(alias(for: account)): \(line)" }
        if let status { line += " → \(status)" }
        steps.append(line)
        if steps.count > Self.trailCapacity {
            steps.removeFirst(steps.count - Self.trailCapacity)
        }
    }

    public func trail() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return steps
    }

    /// Stable within a run, meaningless outside it. Alias assignment is first-seen order.
    private func alias(for account: String) -> String {
        if let existing = aliases[account] { return existing }
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let index = aliases.count
        let name = index < letters.count
            ? "item \(letters[letters.index(letters.startIndex, offsetBy: index)])"
            : "item #\(index + 1)"
        aliases[account] = name
        return name
    }
}

/// What one migration pass achieved. `needsUser` is the count of legacy items that could not
/// be read silently and were skipped because the pass was not allowed to show dialogs.
public struct SecretMigrationSummary: Equatable {
    public var migrated: Int
    public var needsUser: Int
    public var failed: Int

    public init(migrated: Int = 0, needsUser: Int = 0, failed: Int = 0) {
        self.migrated = migrated
        self.needsUser = needsUser
        self.failed = failed
    }
}

/// Login-keychain generic passwords.
///
/// Deliberately *not* the data-protection keychain (`kSecUseDataProtectionKeychain`): per
/// TN3137 its access groups "must be authorized by a provisioning profile", and a self-signed
/// bundle cannot carry one — a probe binary claiming the entitlement is killed outright
/// (SIGKILL from AMFI). The file-based keychain ACLs the item to this app's code signature,
/// which is cert-pinned by `Scripts/make-signing-cert.sh`; the per-rebuild partition problem
/// that signature cannot solve is handled by `KeychainPartitionPolicy` healing.
public final class KeychainSecretBackingStore: SecretBackingStore {
    private let lock = UnfairLock()
    private let diagnostics: SecretAccessDiagnostics

    public init(diagnostics: SecretAccessDiagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    private func baseQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// Run `body` with keychain UI suppressed, restoring the previous state after. Suppression
    /// is what turns "partition mismatch" into a status we can heal instead of a password
    /// dialog the user has to read.
    private func withoutKeychainUI<T>(_ body: () -> T) -> T {
        var previous: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return body()
    }

    /// One query answering everything about an item: status, value, and whether it is a husk.
    private func fetch(service: String, account: String) -> (status: OSStatus, value: String?, tombstone: Bool) {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let attrs = item as? [String: Any] else {
            return (status, nil, false)
        }
        let tombstone = KeychainPartitionPolicy.isTombstone(
            description: attrs[kSecAttrDescription as String] as? String
        )
        let value = (attrs[kSecValueData as String] as? Data)
            .flatMap { String(data: $0, encoding: .utf8) }
        return (status, value, tombstone)
    }

    /// The metadata-only update that re-partitions the item to this build. Gated by the item's
    /// cert-pinned ACL entries, so only code signed like this app gains anything from it.
    private func healPartition(service: String, account: String) {
        let touch: [String: Any] = [kSecAttrComment as String: KeychainPartitionPolicy.healComment]
        _ = SecItemUpdate(baseQuery(service: service, account: account) as CFDictionary, touch as CFDictionary)
    }

    /// Write a live value into one service. Update first: SecItemAdd on an existing account
    /// returns errSecDuplicateItem, and the delete-then-add alternative loses the value if the
    /// process dies between the two. A value update also re-partitions the item to this build
    /// (measured) and resurrects a tombstoned husk — hence the explicit live description.
    private func write(_ data: Data, service: String, account: String) -> OSStatus {
        let query = baseQuery(service: service, account: account)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrDescription as String: KeychainPartitionPolicy.liveDescription,
            kSecAttrComment as String: KeychainPartitionPolicy.healComment,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus != errSecItemNotFound { return updateStatus }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrDescription as String] = KeychainPartitionPolicy.liveDescription
        insert[kSecAttrComment as String] = KeychainPartitionPolicy.healComment
        // This device only, and only while unlocked: a password snippet has no business
        // travelling to another Mac in a keychain sync or sitting readable in a backup.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil)
    }

    /// Best-effort destruction of one service's item: delete when this build may (creator
    /// only — measured), otherwise overwrite the value in place and mark the husk. Every read
    /// surface here treats the marker as "absent".
    private func destroy(service: String, account: String) -> OSStatus {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return status }

        let tomb: [String: Any] = [
            kSecValueData as String: Data(KeychainPartitionPolicy.tombstoneValue.utf8),
            kSecAttrDescription as String: KeychainPartitionPolicy.tombstoneDescription,
        ]
        let tombStatus = SecItemUpdate(
            baseQuery(service: service, account: account) as CFDictionary,
            tomb as CFDictionary
        )
        // The secret is gone either way the caller cares about; report the destroy result.
        return tombStatus == errSecSuccess ? errSecSuccess : status
    }

    public func set(_ value: String, account: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return errSecParam }
        lock.lock(); defer { lock.unlock() }
        return withoutKeychainUI {
            let status = write(data, service: SecretStore.serviceV2, account: account)
            // A save is also a free migration: the plaintext is in hand, so the incurable
            // legacy copy can be destroyed without ever showing a dialog.
            if status == errSecSuccess {
                _ = destroy(service: SecretStore.service, account: account)
            }
            return status
        }
    }

    private enum ReadResult {
        case absent
        case value(String?, SecretReadOutcome)
        case needsUser
        case failed(OSStatus)
    }

    /// The silent read against one service: a fetch, then heal-and-retry. **Never** shows a
    /// dialog — a read that cannot complete silently reports `.needsUser` and it is the
    /// migration flow's job (and no one else's) to decide when the user sees a prompt.
    private func readSilently(epoch: SecretServiceEpoch, account: String) -> ReadResult {
        let service = epoch.service
        return withoutKeychainUI {
            var result = fetch(service: service, account: account)
            diagnostics.note("\(epoch.trailName) fetch", result.status, account: account)
            var phase = KeychainReadPlan.Phase.silent
            if KeychainReadPlan.step(after: result.status, phase: phase) == .heal {
                healPartition(service: service, account: account)
                phase = .healed
                result = fetch(service: service, account: account)
                diagnostics.note("\(epoch.trailName) fetch after heal", result.status, account: account)
            }
            switch KeychainReadPlan.step(after: result.status, phase: phase) {
            case .succeed:
                // A husk reads as "no secret", never as its placeholder value.
                if result.tombstone { return .absent }
                return .value(result.value, phase == .silent ? .ok : .healed)
            case .fail:
                // Absent is not a failure worth reporting; anything else is.
                if result.status == errSecItemNotFound { return .absent }
                return .failed(result.status)
            case .askUser, .heal:
                return .needsUser
            }
        }
    }

    /// Copy one just-read legacy value into the current service, then destroy the source.
    /// Destroy only once the copy definitely exists — a failed copy leaves the original alone.
    private func migrate(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        _ = withoutKeychainUI {
            let copied = write(data, service: SecretStore.serviceV2, account: account)
            diagnostics.note("migrate copy", copied, account: account)
            if copied == errSecSuccess {
                let destroyed = destroy(service: SecretStore.service, account: account)
                diagnostics.note("migrate destroy legacy", destroyed, account: account)
            }
            return copied
        }
    }

    public func value(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }

        for epoch in SecretServiceEpoch.readOrder {
            switch readSilently(epoch: epoch, account: account) {
            case .absent:
                continue
            case .value(let value, let outcome):
                if SecretServiceEpoch.shouldMigrate(from: epoch, readSucceeded: value != nil),
                   let value {
                    migrate(value, account: account)
                }
                diagnostics.record(outcome)
                return value
            case .needsUser:
                // Structurally incapable of prompting: the answer here is "run the migration
                // flow", reported through `legacyAccountsPendingMigration`, never a dialog in
                // the middle of an ordinary copy.
                diagnostics.record(.failed(errSecInteractionNotAllowed))
                return nil
            case .failed(let status):
                diagnostics.record(.failed(status))
                return nil
            }
        }
        return nil
    }

    /// Legacy accounts that still hold a live item. Metadata-only, silent, cheap.
    public func legacyAccountsPendingMigration() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return withoutKeychainUI { legacyAccountsLocked() }
    }

    private func legacyAccountsLocked() -> [String] {
        var query = baseQuery(service: SecretStore.service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry -> String? in
            guard !KeychainPartitionPolicy.isTombstone(
                description: entry[kSecAttrDescription as String] as? String
            ) else { return nil }
            return entry[kSecAttrAccount as String] as? String
        }.sorted()
    }

    /// Locked means every decrypt fails while metadata succeeds — the state that used to be
    /// misreported as "no secret stored". Users enable auto-lock in Keychain Access ("lock
    /// after N minutes", "lock when sleeping"); DevType must diagnose it, not deny the secret.
    public func keychainLocked() -> Bool {
        var status = SecKeychainStatus(0)
        guard SecKeychainGetStatus(nil, &status) == errSecSuccess else {
            // No default keychain at all — not a lock problem; let reads speak for themselves.
            return false
        }
        return status & SecKeychainStatus(kSecUnlockStateStatus) == 0
    }

    /// The system unlock prompt — the login password dialog macOS itself owns. Reached only
    /// through UI that told the user why (same doorway rule as migration).
    public func requestKeychainUnlock() -> Bool {
        let status = SecKeychainUnlock(nil, 0, nil, false)
        diagnostics.note("keychain unlock request", status)
        return status == errSecSuccess
    }

    /// The one-shot batch that finishes the §8.10 upgrade. Tries every legacy item silently
    /// first (heal included); only with `allowInteraction` — granted by the UI *after telling
    /// the user how many dialogs to expect* — does it fall through to the system prompt, one
    /// item at a time. This function is the only interactive keychain path in the app.
    public func migrateLegacy(allowInteraction: Bool) -> SecretMigrationSummary {
        lock.lock(); defer { lock.unlock() }
        var summary = SecretMigrationSummary()

        for account in withoutKeychainUI({ legacyAccountsLocked() }) {
            switch readSilently(epoch: .legacy, account: account) {
            case .value(let value, _):
                guard let value else { summary.failed += 1; continue }
                migrate(value, account: account)
                summary.migrated += 1
                continue
            case .absent:
                continue
            case .failed:
                summary.failed += 1
                continue
            case .needsUser:
                guard allowInteraction else {
                    summary.needsUser += 1
                    continue
                }
            }

            // The system password dialog, deliberately: the user was told it was coming.
            // Answering it is the last time — the value moves to the current service right here.
            let final = fetch(service: SecretStore.service, account: account)
            diagnostics.note("legacy fetch with dialog", final.status, account: account)
            if final.status == errSecSuccess, !final.tombstone, let value = final.value {
                migrate(value, account: account)
                summary.migrated += 1
            } else if final.status == errSecUserCanceled {
                summary.needsUser += 1
            } else {
                summary.failed += 1
            }
        }
        diagnostics.note(
            "migration pass: \(summary.migrated) migrated, \(summary.needsUser) pending, \(summary.failed) failed"
        )
        return summary
    }

    public func contains(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return withoutKeychainUI {
            for epoch in SecretServiceEpoch.readOrder {
                var query = baseQuery(service: epoch.service, account: account)
                query[kSecReturnAttributes as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                      let attrs = item as? [String: Any] else {
                    continue
                }
                if !KeychainPartitionPolicy.isTombstone(
                    description: attrs[kSecAttrDescription as String] as? String
                ) { return true }
            }
            return false
        }
    }

    public func delete(account: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        return withoutKeychainUI {
            let current = destroy(service: SecretStore.serviceV2, account: account)
            let legacy = destroy(service: SecretStore.service, account: account)
            // "Not found in either" is the caller's success case (idempotent remove); a real
            // failure in either service is worth surfacing.
            if current == errSecSuccess || legacy == errSecSuccess { return errSecSuccess }
            return current == errSecItemNotFound ? legacy : current
        }
    }

    public func accounts() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return withoutKeychainUI {
            var found: Set<String> = []
            for epoch in SecretServiceEpoch.readOrder {
                var query = baseQuery(service: epoch.service, account: nil)
                query[kSecReturnAttributes as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitAll

                var items: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
                      let entries = items as? [[String: Any]] else {
                    continue
                }
                for entry in entries {
                    guard !KeychainPartitionPolicy.isTombstone(
                        description: entry[kSecAttrDescription as String] as? String
                    ), let account = entry[kSecAttrAccount as String] as? String else { continue }
                    found.insert(account)
                }
            }
            return found
        }
    }
}

// MARK: - Encrypted archive (§8.11)

/// The sealing/opening codec for the secrets archive, split from all I/O so every byte-level
/// property is testable without a file or a keychain.
///
/// Why an archive at all: with one keychain item *per secret*, every secret carries its own
/// ACL and partition destiny — and securityd's file-keychain behaviour proved erratic enough
/// (§8.10: a heal that landed on one item and skipped its twin) that "should never prompt" was
/// not "cannot". With the values AES-GCM-sealed in a file DevType owns and only a single
/// random master key in the keychain, the entire dialog surface is one item, and reads after
/// the first per launch touch no keychain at all.
public enum EncryptedSecretArchive {
    public static let version = 1

    struct Payload: Codable {
        let version: Int
        let entries: [String: String]
    }

    /// Seal one value. Nonce is fresh-random per call (CryptoKit), so equal plaintexts yield
    /// different blobs; `combined` carries nonce + ciphertext + tag in one base64 string.
    public static func seal(_ value: String, key: SymmetricKey) -> String? {
        guard let box = try? AES.GCM.seal(Data(value.utf8), using: key),
              let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    /// Open one blob. Any tamper — flipped bit, truncation, wrong key — fails the GCM tag and
    /// returns nil rather than plausible garbage.
    public static func open(_ blob: String, key: SymmetricKey) -> String? {
        guard let data = Data(base64Encoded: blob),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// Deterministic encoding (sorted keys) so an unchanged archive is byte-identical.
    public static func encode(_ entries: [String: String]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Payload(version: version, entries: entries))
    }

    /// nil for anything this build cannot vouch for — malformed bytes *or a future version*.
    /// The caller preserves what it cannot read; overwriting an archive some newer build wrote
    /// would destroy secrets this build merely fails to understand.
    public static func decode(_ data: Data) -> [String: String]? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == version else { return nil }
        return payload.entries
    }
}

/// §8.11: file-first secret storage with the keychain reduced to one master-key item.
///
/// Layout: `secrets.enc` in Application Support holds the sealed values; the 256-bit master
/// key is a keychain item under the proven v2 service with the non-UUID account below — which
/// `SecretStore.orphanAccounts` already refuses to purge, `snippetIDsPendingMigration` cannot
/// mistake for a snippet, and the §8.10 silent/heal machinery keeps readable across rebuilds.
/// Trust anchor is unchanged: the file is useless without the key, and the key is ACL'd to
/// this app exactly as every secret item was. What changes is arithmetic: one keychain object
/// instead of N, at most one silent read per launch instead of one per copy.
///
/// The keychain tier stays underneath as fallback and migration source. An item leaves the
/// keychain only after its file copy has been decrypt-verified; a save that cannot reach the
/// master key (locked keychain) falls back to a keychain item, never fails harder than §8.10.
public final class ConsolidatedSecretBackingStore: SecretBackingStore {
    public static let masterKeyAccount = "com.devtype.masterkey"
    public static let archiveFileName = "secrets.enc"

    private let lock = UnfairLock()
    private let tier: SecretBackingStore
    private let diagnostics: SecretAccessDiagnostics
    private let fileURL: URL
    /// Instance-scoped so probes and witnesses can use their own account: a foreign-owned husk
    /// squatting on the real account would trap the app in read-back-refusal fallback forever.
    private let masterAccount: String
    private var cachedKey: SymmetricKey?

    public init(
        fileURL: URL? = nil,
        tier: SecretBackingStore? = nil,
        diagnostics: SecretAccessDiagnostics = .shared,
        masterKeyAccount: String = ConsolidatedSecretBackingStore.masterKeyAccount
    ) {
        self.fileURL = fileURL
            ?? SnippetStore.defaultLocalSupportDirectory
                .appendingPathComponent(Self.archiveFileName)
        self.tier = tier ?? KeychainSecretBackingStore(diagnostics: diagnostics)
        self.diagnostics = diagnostics
        self.masterAccount = masterKeyAccount
    }

    // MARK: File I/O (always under `lock`)

    private enum Archive {
        case missing
        case entries([String: String])
        /// Bytes exist that this build cannot vouch for. Never overwritten in place.
        case unreadable
    }

    private func loadArchive() -> Archive {
        guard let data = try? Data(contentsOf: fileURL) else { return .missing }
        guard let entries = EncryptedSecretArchive.decode(data) else { return .unreadable }
        return .entries(entries)
    }

    /// Cross-process exclusive lock around every read-modify-write of the archive. The
    /// in-process `lock` already serializes this instance; this guards the window a *second
    /// writer* (another DevType process, a probe, a future tool) could use to clobber a
    /// load-modify-save in flight — the §8.11 post-mortem shape that cost one secret its
    /// value. Never nested: callers hold it around the whole load→save→verify sequence.
    private func withArchiveLock<T>(_ body: () -> T) -> T {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = fileURL.appendingPathExtension("lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        _ = flock(fd, LOCK_EX)
        defer { _ = flock(fd, LOCK_UN) }
        return body()
    }

    /// The only sanctioned way to drop a keychain copy: reload the archive **from disk** and
    /// prove the entry that is about to replace it decrypts from those reloaded bytes. A save
    /// that merely returned true is not proof — the file can have been clobbered since.
    private func verifiedOnDisk(account: String, expecting value: String, key: SymmetricKey) -> Bool {
        guard case .entries(let reloaded) = loadArchive(),
              let blob = reloaded[account],
              EncryptedSecretArchive.open(blob, key: key) == value else {
            diagnostics.note("archive reload-verify failed — keychain copy kept", account: account)
            return false
        }
        return true
    }

    /// Atomic write (temp + rename via `.atomic`), owner-only permissions.
    private func saveArchive(_ entries: [String: String]) -> Bool {
        guard let data = EncryptedSecretArchive.encode(entries) else { return false }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            diagnostics.note("archive save failed")
            return false
        }
    }

    /// An unreadable archive is moved aside, never deleted: those bytes may be secrets sealed
    /// by a newer build, and forensics beat tidiness. Returns true when the path is clear.
    private func quarantineUnreadableArchive() -> Bool {
        let aside = fileURL.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
            diagnostics.note("archive quarantined as unreadable")
            return true
        } catch {
            return false
        }
    }

    // MARK: Master key (always under `lock`)

    private func masterKey(createIfNeeded: Bool) -> SymmetricKey? {
        if let cachedKey { return cachedKey }
        if let stored = tier.value(account: masterAccount) {
            guard let raw = Data(base64Encoded: stored), raw.count == 32 else {
                diagnostics.note("master key malformed")
                return nil
            }
            let key = SymmetricKey(data: raw)
            cachedKey = key
            return key
        }
        guard createIfNeeded else { return nil }
        let key = SymmetricKey(size: .bits256)
        let encoded = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        let status = tier.set(encoded, account: masterAccount)
        diagnostics.note("master key created", status)
        guard status == errSecSuccess else { return nil }

        // Read-back verification, and it is load-bearing: a keychain write can succeed against
        // an item this identity cannot read (the encrypt ACL entry is open; decrypt is not).
        // Trusting an unverified key would seal archives that die with this process — every
        // launch minting a new key, every restart losing every secret. No read-back, no key:
        // the store stays on per-item keychain fallback, which loses nothing.
        guard tier.value(account: masterAccount) == encoded else {
            diagnostics.note("master key read-back failed — staying on keychain fallback")
            return nil
        }
        cachedKey = key
        return key
    }

    // MARK: SecretBackingStore

    public func set(_ value: String, account: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        return withArchiveLock {
            var entries: [String: String]
            switch loadArchive() {
            case .entries(let existing): entries = existing
            case .missing: entries = [:]
            case .unreadable:
                guard quarantineUnreadableArchive() else { return tier.set(value, account: account) }
                entries = [:]
            }

            // Seal, verify the seal opens, persist — and only then drop any keychain copy. Any
            // failure on this path falls back to a keychain item: storage may regress a tier
            // for one value, but a save never fails harder than §8.10 did.
            guard let key = masterKey(createIfNeeded: true),
                  let blob = EncryptedSecretArchive.seal(value, key: key),
                  EncryptedSecretArchive.open(blob, key: key) == value else {
                return tierFallbackSet(value, account: account, entries: entries)
            }
            entries[account] = blob
            guard saveArchive(entries),
                  verifiedOnDisk(account: account, expecting: value, key: key) else {
                return tierFallbackSet(value, account: account, entries: entries)
            }
            diagnostics.note("sealed into archive", account: account)
            _ = tier.delete(account: account)
            return errSecSuccess
        }
    }

    /// The fallback save, with the staleness hole the fuzz found closed: a stale sealed copy
    /// left in the archive would shadow the newer tier value on every read — the user's edited
    /// secret silently reverting. Tier write first (the new value must be durable before
    /// anything is evicted), then best-effort eviction of the stale entry.
    private func tierFallbackSet(
        _ value: String, account: String, entries: [String: String]
    ) -> OSStatus {
        let status = tier.set(value, account: account)
        if status == errSecSuccess, entries[account] != nil {
            var pruned = entries
            pruned.removeValue(forKey: account)
            if !saveArchive(pruned) {
                diagnostics.note("stale archive entry could not be evicted", account: account)
            }
        }
        return status
    }

    public func value(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }

        if case .entries(let entries) = loadArchive(), let blob = entries[account] {
            guard let key = masterKey(createIfNeeded: false) else {
                // Sealed value present but no key: locked keychain (recoverable via the unlock
                // flow) or a deleted master key (not). The trail + report tell them apart.
                diagnostics.note("sealed value but master key unavailable", account: account)
                diagnostics.record(.failed(errSecInteractionNotAllowed))
                return nil
            }
            guard let value = EncryptedSecretArchive.open(blob, key: key) else {
                diagnostics.note("archive decrypt failed", account: account)
                diagnostics.record(.failed(errSecDecode))
                return nil
            }
            diagnostics.record(.ok)
            return value
        }

        // Not in the archive: the keychain tier (with all its §8.10 healing) is the source —
        // and a successful read is immediately consolidated so the next one never comes here.
        guard let value = tier.value(account: account) else { return nil }
        consolidateLocked(account: account, value: value)
        return value
    }

    public func contains(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if case .entries(let entries) = loadArchive(), entries[account] != nil { return true }
        return tier.contains(account: account)
    }

    public func delete(account: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let removedFromArchive: Bool = withArchiveLock {
            guard case .entries(var entries) = loadArchive(), entries[account] != nil else {
                return false
            }
            entries.removeValue(forKey: account)
            return saveArchive(entries)
        }
        let tierStatus = tier.delete(account: account)
        if removedFromArchive || tierStatus == errSecSuccess { return errSecSuccess }
        return tierStatus
    }

    public func accounts() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var found = Set(tier.accounts())
        // The master key is infrastructure, not a secret anyone stored.
        found.remove(masterAccount)
        if case .entries(let entries) = loadArchive() {
            found.formUnion(entries.keys)
        }
        return found
    }

    // MARK: Consolidation

    /// Move one just-read value into the archive; the tier copy is dropped only after the
    /// entry is verified to decrypt **from the bytes on disk** (`verifiedOnDisk`), under the
    /// cross-process archive lock. Best-effort: any failure leaves the tier copy untouched.
    private func consolidateLocked(account: String, value: String) {
        withArchiveLock {
            var entries: [String: String]
            switch loadArchive() {
            case .entries(let existing): entries = existing
            case .missing: entries = [:]
            case .unreadable:
                guard quarantineUnreadableArchive() else { return }
                entries = [:]
            }
            guard let key = masterKey(createIfNeeded: true),
                  let blob = EncryptedSecretArchive.seal(value, key: key),
                  EncryptedSecretArchive.open(blob, key: key) == value else { return }
            entries[account] = blob
            guard saveArchive(entries),
                  verifiedOnDisk(account: account, expecting: value, key: key) else { return }
            diagnostics.note("consolidated into archive", account: account)
            _ = tier.delete(account: account)
        }
    }

    public func consolidateIntoFile() -> SecretConsolidationSummary {
        lock.lock(); defer { lock.unlock() }
        var summary = SecretConsolidationSummary()

        for account in tier.accounts().sorted() where account != masterAccount {
            // Snippet secrets only: anything else under the service is not ours to move.
            guard SecretStore.snippetID(forAccount: account) != nil else { continue }
            guard let value = tier.value(account: account) else {
                summary.remaining += 1
                continue
            }
            let before = countLocked()
            consolidateLocked(account: account, value: value)
            if countLocked() > before || archiveHasLocked(account: account) {
                summary.moved += 1
            } else {
                summary.failed += 1
            }
        }
        if summary != SecretConsolidationSummary() {
            diagnostics.note(
                "consolidation: \(summary.moved) moved, \(summary.remaining) remaining, \(summary.failed) failed"
            )
        }
        // Warm the master key into the in-process cache while the keychain is likely unlocked
        // (launch = login). The user's keychain auto-locks — measured mid-session — and with
        // the key cached, copies keep decrypting the archive straight through a locked
        // keychain instead of surfacing the unlock flow.
        if masterKey(createIfNeeded: false) != nil {
            diagnostics.note("master key warmed")
        }
        return summary
    }

    private func countLocked() -> Int {
        if case .entries(let entries) = loadArchive() { return entries.count }
        return 0
    }

    private func archiveHasLocked(account: String) -> Bool {
        if case .entries(let entries) = loadArchive() { return entries[account] != nil }
        return false
    }

    // MARK: Pass-through to the keychain tier

    public func legacyAccountsPendingMigration() -> [String] {
        tier.legacyAccountsPendingMigration()
    }

    public func migrateLegacy(allowInteraction: Bool) -> SecretMigrationSummary {
        let summary = tier.migrateLegacy(allowInteraction: allowInteraction)
        // Freshly migrated values are v2 keychain items; sweep them straight into the archive
        // so the migration flow ends with everything in its final home.
        _ = consolidateIntoFile()
        return summary
    }

    public func keychainLocked() -> Bool { tier.keychainLocked() }
    public func requestKeychainUnlock() -> Bool { tier.requestKeychainUnlock() }

    public func storageDescription() -> String {
        lock.lock(); defer { lock.unlock() }
        let sealed = countLocked()
        let keychainResident = tier.accounts().filter {
            $0 != masterAccount && SecretStore.snippetID(forAccount: $0) != nil
        }.count
        let keyState: String
        if cachedKey != nil || tier.value(account: masterAccount) != nil {
            keyState = "present"
        } else if tier.contains(account: masterAccount) {
            // The item exists but this identity cannot read it — the write-only ACL shape the
            // read-back guard protects against. Fallback mode; nothing is lost.
            keyState = "present but UNREADABLE — keychain fallback in use"
        } else {
            keyState = sealed > 0 ? "MISSING with sealed secrets" : "not yet created"
        }
        return "archive: \(sealed) sealed, keychain-resident: \(keychainResident), master key: \(keyState)"
    }
}

/// In-memory double for tests. Never used by the app.
public final class InMemorySecretBackingStore: SecretBackingStore {
    private var storage: [String: String] = [:]
    private let lock = UnfairLock()
    /// Forced failure for the error paths, which are otherwise unreachable without a keychain.
    public var forcedStatus: OSStatus?

    public init(seed: [String: String] = [:]) { storage = seed }

    public func set(_ value: String, account: String) -> OSStatus {
        if let forcedStatus { return forcedStatus }
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
        return errSecSuccess
    }

    public func value(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func contains(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage[account] != nil
    }

    public func delete(account: String) -> OSStatus {
        if let forcedStatus { return forcedStatus }
        lock.lock(); defer { lock.unlock() }
        return storage.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }

    public func accounts() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(storage.keys)
    }
}

// MARK: - Library filtering

/// Pure library filters used by the copy surfaces.
///
/// In `ExpanderEngine` rather than next to the panel that calls them so they are reachable from
/// tests — the app is an `executableTarget` and cannot be imported.
public enum SecretLibraryFilter {

    /// Groups reduced to their secrets, dropping groups that then hold none.
    ///
    /// Applied *before* ranking rather than after. The palette caps snippet hits, so filtering
    /// afterwards would let ordinary snippets fill the cap and crowd the secrets out of a search
    /// whose entire purpose is finding one.
    public static func secretsOnly(_ groups: [SnippetGroup]) -> [SnippetGroup] {
        groups.compactMap { group in
            let secrets = group.snippets.filter(\.isSecret)
            guard !secrets.isEmpty else { return nil }
            var copy = group
            copy.snippets = secrets
            return copy
        }
    }
}

/// Ordering and cap for the mouse-only *Copy Secret* submenu.
///
/// Most recently updated first, so a secret just added is at the top; capped so a large library
/// still yields a menu that opens instantly, with the search entry above it covering the rest.
public enum SecretMenuEntryPolicy {
    public static func entries(from snippets: [SnippetModel], limit: Int = 20) -> [SnippetModel] {
        snippets
            .filter(\.isSecret)
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
            .prefix(max(0, limit))
            .map { $0 }
    }
}

// MARK: - Preferences

/// User-facing switches for secret handling.
public enum SecretPreferences {
    public static let requireBiometryKey = "devtype.secrets.requireBiometry"

    /// Ask for Touch ID (or the login password) before revealing a secret.
    ///
    /// Defaults to **on** wherever the machine can evaluate a policy. The failure modes are not
    /// symmetric: the cost of an unwanted prompt is one touch, and the cost of a missing one is
    /// that anyone who walks up to an unlocked Mac can lift a password out of a menu. Someone who
    /// finds the prompt tiresome can turn it off in one click; someone whose password walked out
    /// of the building cannot undo that.
    public static func requireBiometry(
        defaults: UserDefaults = .standard,
        availability: BiometricGate.Availability
    ) -> Bool {
        guard availability.canGate else { return false }
        guard defaults.object(forKey: requireBiometryKey) != nil else { return true }
        return defaults.bool(forKey: requireBiometryKey)
    }

    public static func setRequireBiometry(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: requireBiometryKey)
    }
}
