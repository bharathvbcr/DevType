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

    /// Keychain service. Distinct from anything the app might store later, so `purgeOrphans`
    /// can enumerate *only* snippet secrets and never delete an unrelated item.
    public static let service = "com.devtype.app.secret"

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

    public init(backing: SecretBackingStore = KeychainSecretBackingStore()) {
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
        let live = Set(liveIDs.map(Self.account(for:)))
        var removed = 0
        for account in backing.accounts() where !live.contains(account) {
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

/// Last-read recorder, kept apart from `SecretBackingStore` so the protocol (and its in-memory
/// test double) stays three operations wide.
public final class SecretAccessDiagnostics {
    public static let shared = SecretAccessDiagnostics()
    private let lock = UnfairLock()
    private var last: SecretReadOutcome = .none

    public init() {}

    public func record(_ outcome: SecretReadOutcome) {
        lock.lock(); defer { lock.unlock() }
        last = outcome
    }

    public func lastRead() -> SecretReadOutcome {
        lock.lock(); defer { lock.unlock() }
        return last
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

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SecretStore.service,
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
    private func fetch(account: String) -> (status: OSStatus, value: String?, tombstone: Bool) {
        var query = baseQuery(account: account)
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
    /// cert-pinned ACL entry, so only code signed like this app gains anything from it.
    private func healPartition(account: String) {
        let touch: [String: Any] = [kSecAttrComment as String: KeychainPartitionPolicy.healComment]
        _ = SecItemUpdate(baseQuery(account: account) as CFDictionary, touch as CFDictionary)
    }

    public func set(_ value: String, account: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return errSecParam }
        lock.lock(); defer { lock.unlock() }
        return withoutKeychainUI {
            let query = baseQuery(account: account)

            // Update first: SecItemAdd on an existing account returns errSecDuplicateItem, and
            // the delete-then-add alternative loses the value if the process dies between the
            // two. A value update also re-partitions the item to this build (measured) and
            // resurrects a tombstoned husk — hence the explicit live description.
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
    }

    public func value(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }

        enum SilentEnd {
            case done(value: String?, outcome: SecretReadOutcome?)
            case needUser
        }

        // Silent phase, then heal-and-retry, still silent.
        let silent: SilentEnd = withoutKeychainUI {
            var result = fetch(account: account)
            var phase = KeychainReadPlan.Phase.silent
            if KeychainReadPlan.step(after: result.status, phase: phase) == .heal {
                healPartition(account: account)
                phase = .healed
                result = fetch(account: account)
            }
            switch KeychainReadPlan.step(after: result.status, phase: phase) {
            case .succeed:
                // A husk reads as "no secret", never as its placeholder value.
                if result.tombstone { return .done(value: nil, outcome: nil) }
                return .done(value: result.value, outcome: phase == .silent ? .ok : .healed)
            case .fail:
                // Absent is not a failure worth reporting; anything else is.
                let outcome: SecretReadOutcome? =
                    result.status == errSecItemNotFound ? nil : .failed(result.status)
                return .done(value: nil, outcome: outcome)
            case .askUser, .heal:
                return .needUser
            }
        }

        if case .done(let value, let outcome) = silent {
            if let outcome { diagnostics.record(outcome) }
            return value
        }

        // Interactive phase: the one place the system password dialog is allowed. Reached only
        // when the item exists but this signing identity cannot heal it — Always Allow here
        // re-pins the ACL entry, after which every future build heals silently again.
        let final = fetch(account: account)
        switch KeychainReadPlan.step(after: final.status, phase: .interactive) {
        case .succeed:
            if final.tombstone { return nil }
            diagnostics.record(.granted)
            return final.value
        case .fail, .heal, .askUser:
            diagnostics.record(.failed(final.status))
            return nil
        }
    }

    public func contains(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return withoutKeychainUI {
            var query = baseQuery(account: account)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let attrs = item as? [String: Any] else {
                return false
            }
            return !KeychainPartitionPolicy.isTombstone(
                description: attrs[kSecAttrDescription as String] as? String
            )
        }
    }

    public func delete(account: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        return withoutKeychainUI {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { return status }

            // The owner check is pinned to the *creating build* (errSecInvalidOwnerEdit from
            // every other, even after a heal — measured). Destroy the value in place and mark
            // the husk; every read surface here treats the marker as "absent".
            let tomb: [String: Any] = [
                kSecValueData as String: Data(KeychainPartitionPolicy.tombstoneValue.utf8),
                kSecAttrDescription as String: KeychainPartitionPolicy.tombstoneDescription,
            ]
            let tombStatus = SecItemUpdate(
                baseQuery(account: account) as CFDictionary,
                tomb as CFDictionary
            )
            // The secret is gone either way the caller cares about; report the destroy result.
            return tombStatus == errSecSuccess ? errSecSuccess : status
        }
    }

    public func accounts() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return withoutKeychainUI {
            var query = baseQuery(account: nil)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll

            var items: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
                  let entries = items as? [[String: Any]] else {
                return []
            }
            return Set(entries.compactMap { entry -> String? in
                guard !KeychainPartitionPolicy.isTombstone(
                    description: entry[kSecAttrDescription as String] as? String
                ) else { return nil }
                return entry[kSecAttrAccount as String] as? String
            })
        }
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
