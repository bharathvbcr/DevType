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
    /// distinction is "have a value" vs "do not". `lastReadStatus` carries the detail for the one
    /// caller that reports it.
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

/// Login-keychain generic passwords.
///
/// Deliberately *not* the data-protection keychain (`kSecUseDataProtectionKeychain`): that
/// requires a keychain-access-group entitlement, and this bundle ships without entitlements, so
/// every call would fail with `errSecMissingEntitlement`. The file-based keychain ACLs the item to
/// this app's code signature, which is cert-pinned by `Scripts/install-app.sh` and therefore
/// survives rebuilds.
public final class KeychainSecretBackingStore: SecretBackingStore {
    public init() {}

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SecretStore.service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    public func set(_ value: String, account: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return errSecParam }
        let query = baseQuery(account: account)

        // Update first: SecItemAdd on an existing account returns errSecDuplicateItem, and the
        // add/delete-then-add alternative loses the value if the process dies between the two.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus != errSecItemNotFound { return updateStatus }

        var insert = query
        insert[kSecValueData as String] = data
        // This device only, and only while unlocked: a password snippet has no business
        // travelling to another Mac in a keychain sync or sitting readable in a backup.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil)
    }

    public func value(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func contains(account: String) -> Bool {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func delete(account: String) -> OSStatus {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    public func accounts() -> Set<String> {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]] else {
            return []
        }
        return Set(entries.compactMap { $0[kSecAttrAccount as String] as? String })
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
