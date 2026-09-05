import CryptoKit
import Darwin
import XCTest
@testable import ExpanderEngine

/// §8.11: secrets live AES-GCM-sealed in an archive file; the keychain holds one master key.
/// Everything here runs against a temp directory and the in-memory tier — no live keychain,
/// no dialogs, no leftovers.
final class SecretConsolidationTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("secret-consolidation-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore(
        tier: SecretBackingStore = InMemorySecretBackingStore(),
        diagnostics: SecretAccessDiagnostics = SecretAccessDiagnostics()
    ) -> (ConsolidatedSecretBackingStore, SecretBackingStore, URL) {
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        return (ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: diagnostics), tier, url)
    }

    // MARK: - The codec

    func testSealOpenRoundTripsHostileValues() {
        let key = SymmetricKey(size: .bits256)
        let values = [
            "hunter2", "{{cursor}}not-a-macro", "%@ %d %%", #"quote"and\backslash"#,
            "🔑🙂👩‍👩‍👧‍👦", "كلمة السر", "\u{200B}zero-width", "line1\nline2\ttabbed",
            String(repeating: "correct horse battery staple ", count: 40),
        ]
        for value in values {
            guard let blob = EncryptedSecretArchive.seal(value, key: key) else {
                return XCTFail("seal failed for \(value.prefix(12))…")
            }
            XCTAssertEqual(EncryptedSecretArchive.open(blob, key: key), value)
            XCTAssertFalse(blob.contains(value), "ciphertext must not contain plaintext")
        }
    }

    func testFreshNoncePerSealAndTamperDetection() {
        let key = SymmetricKey(size: .bits256)
        let a = EncryptedSecretArchive.seal("same", key: key)!
        let b = EncryptedSecretArchive.seal("same", key: key)!
        XCTAssertNotEqual(a, b, "equal plaintexts must yield different blobs (fresh nonce)")

        // Flip one byte anywhere: GCM must refuse, never return plausible garbage.
        var bytes = [UInt8](Data(base64Encoded: a)!)
        bytes[bytes.count / 2] ^= 0x01
        let tampered = Data(bytes).base64EncodedString()
        XCTAssertNil(EncryptedSecretArchive.open(tampered, key: key))

        // Wrong key: same refusal.
        XCTAssertNil(EncryptedSecretArchive.open(a, key: SymmetricKey(size: .bits256)))
    }

    func testDecodeRefusesFutureVersionsAndGarbage() {
        XCTAssertNil(EncryptedSecretArchive.decode(Data("not json".utf8)))
        XCTAssertNil(EncryptedSecretArchive.decode(Data()))
        let future = #"{"version":99,"entries":{"a":"b"}}"#
        XCTAssertNil(
            EncryptedSecretArchive.decode(Data(future.utf8)),
            "A future build's archive must be preserved, not reinterpreted."
        )
        let current = EncryptedSecretArchive.encode(["a": "b"])!
        XCTAssertEqual(EncryptedSecretArchive.decode(current), ["a": "b"])
    }

    // MARK: - The store

    func testSetSealsIntoArchiveAndDropsTheKeychainCopy() throws {
        let (store, tier, url) = makeStore()
        let id = UUID().uuidString

        XCTAssertEqual(store.set("s3cret", account: id), errSecSuccess)
        XCTAssertEqual(store.value(account: id), "s3cret")
        XCTAssertTrue(store.contains(account: id))

        // The value is on disk only in sealed form.
        let raw = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("s3cret"))

        // The keychain tier holds the master key and nothing else.
        XCTAssertEqual(tier.accounts(), [ConsolidatedSecretBackingStore.masterKeyAccount])
        // Which also means the store's account list hides the key.
        XCTAssertEqual(store.accounts(), [id])
    }

    func testValueConsolidatesTierResidentsOnFirstRead() {
        let tier = InMemorySecretBackingStore()
        let id = UUID().uuidString
        _ = tier.set("from-keychain", account: id)
        let (store, _, _) = makeStore(tier: tier)

        XCTAssertEqual(store.value(account: id), "from-keychain")
        XCTAssertNil(
            tier.value(account: id),
            "First read must move the value into the archive and drop the tier copy."
        )
        XCTAssertEqual(store.value(account: id), "from-keychain")
    }

    func testConsolidateIntoFileMovesEverythingAndSkipsNonSnippets() {
        let tier = InMemorySecretBackingStore()
        let ids = (0..<3).map { _ in UUID().uuidString }
        for (index, id) in ids.enumerated() { _ = tier.set("v\(index)", account: id) }
        _ = tier.set("not-a-snippet", account: "some-other-tool-account")
        let (store, _, _) = makeStore(tier: tier)

        let summary = store.consolidateIntoFile()
        XCTAssertEqual(summary, SecretConsolidationSummary(moved: 3, remaining: 0, failed: 0))
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(store.value(account: id), "v\(index)")
            XCTAssertNil(tier.value(account: id))
        }
        XCTAssertEqual(
            tier.value(account: "some-other-tool-account"), "not-a-snippet",
            "Only UUID accounts are snippet secrets; anything else is not ours to move."
        )
        // Idempotent: nothing left to do.
        XCTAssertEqual(store.consolidateIntoFile(), SecretConsolidationSummary())
    }

    func testSealedValueWithoutMasterKeyFailsClosedAndSaysSo() {
        let tier = InMemorySecretBackingStore()
        let diagnostics = SecretAccessDiagnostics()
        let (store, _, _) = makeStore(tier: tier, diagnostics: diagnostics)
        let id = UUID().uuidString
        _ = store.set("precious", account: id)

        // The user deletes the master key in Keychain Access (or a fuzzer eats it).
        _ = tier.delete(account: ConsolidatedSecretBackingStore.masterKeyAccount)
        let (fresh, _, _) = makeStore(tier: tier) // fresh instance: no cached key

        XCTAssertNil(fresh.value(account: id), "No key, no plaintext — and no crash.")
        XCTAssertTrue(fresh.storageDescription().contains("MISSING"),
                      "The report must name the missing master key: \(fresh.storageDescription())")
    }

    func testUnreadableArchiveIsQuarantinedNeverOverwritten() throws {
        let (store, _, url) = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":99,"entries":{"future":"bytes"}}"#.utf8).write(to: url)

        let id = UUID().uuidString
        XCTAssertEqual(store.set("new-value", account: id), errSecSuccess)
        XCTAssertEqual(store.value(account: id), "new-value")

        let aside = url.appendingPathExtension("unreadable")
        let preserved = try Data(contentsOf: aside)
        XCTAssertTrue(String(decoding: preserved, as: UTF8.self).contains("future"),
                      "The bytes this build could not vouch for must survive, moved aside.")
    }

    func testSaveFallsBackToTheKeychainTierWhenTheKeyIsUnreachable() {
        /// A tier whose master key cannot be created — the locked-keychain shape.
        final class LockedTier: SecretBackingStore {
            private let inner = InMemorySecretBackingStore()
            func set(_ value: String, account: String) -> OSStatus {
                account == ConsolidatedSecretBackingStore.masterKeyAccount
                    ? errSecInteractionNotAllowed
                    : inner.set(value, account: account)
            }
            func value(account: String) -> String? { inner.value(account: account) }
            func contains(account: String) -> Bool { inner.contains(account: account) }
            func delete(account: String) -> OSStatus { inner.delete(account: account) }
            func accounts() -> Set<String> { inner.accounts() }
        }
        let tier = LockedTier()
        let (store, _, _) = makeStore(tier: tier)
        let id = UUID().uuidString

        XCTAssertEqual(
            store.set("still-saved", account: id), errSecSuccess,
            "A save must never fail harder than §8.10: keychain item fallback."
        )
        XCTAssertEqual(tier.value(account: id), "still-saved")
        XCTAssertEqual(store.value(account: id), "still-saved")
    }

    /// The staleness hole the fuzz found, as its own regression test: save while the master
    /// key is unreachable (locked keychain), unlock, read — the *new* value must win, never a
    /// stale sealed copy shadowing it.
    func testEditingWhileLockedNeverRevertsToTheStaleSealedValue() {
        final class TogglableTier: SecretBackingStore {
            let inner = InMemorySecretBackingStore()
            var locked = false
            func set(_ value: String, account: String) -> OSStatus {
                locked && account == ConsolidatedSecretBackingStore.masterKeyAccount
                    ? errSecInteractionNotAllowed
                    : inner.set(value, account: account)
            }
            func value(account: String) -> String? {
                locked && account == ConsolidatedSecretBackingStore.masterKeyAccount
                    ? nil
                    : inner.value(account: account)
            }
            func contains(account: String) -> Bool { inner.contains(account: account) }
            func delete(account: String) -> OSStatus { inner.delete(account: account) }
            func accounts() -> Set<String> { inner.accounts() }
        }

        let tier = TogglableTier()
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let id = UUID().uuidString

        let store = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        XCTAssertEqual(store.set("old-password", account: id), errSecSuccess) // sealed
        tier.locked = true
        // A fresh instance so no cached master key hides the lock.
        let lockedStore = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        XCTAssertEqual(lockedStore.set("NEW-password", account: id), errSecSuccess) // fallback
        tier.locked = false

        let reopened = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        XCTAssertEqual(
            reopened.value(account: id), "NEW-password",
            "The stale sealed copy must have been evicted by the fallback save."
        )
    }

    /// A keychain write can succeed against an item this identity cannot read back (open
    /// encrypt entry, closed decrypt). Trusting that key would seal archives that die with the
    /// process — every launch a new key, every restart losing every secret. The read-back
    /// guard must refuse the key and keep the store on lossless keychain fallback.
    func testWriteOnlyMasterKeyIsRefusedAndNothingIsLost() {
        final class WriteOnlyMasterTier: SecretBackingStore {
            let inner = InMemorySecretBackingStore()
            func set(_ value: String, account: String) -> OSStatus {
                inner.set(value, account: account)
            }
            func value(account: String) -> String? {
                account == ConsolidatedSecretBackingStore.masterKeyAccount
                    ? nil // written, never readable — the foreign-ACL shape
                    : inner.value(account: account)
            }
            func contains(account: String) -> Bool { inner.contains(account: account) }
            func delete(account: String) -> OSStatus { inner.delete(account: account) }
            func accounts() -> Set<String> { inner.accounts() }
        }

        let tier = WriteOnlyMasterTier()
        let (store, _, url) = makeStore(tier: tier)
        let id = UUID().uuidString

        XCTAssertEqual(store.set("survives", account: id), errSecSuccess)
        XCTAssertEqual(store.value(account: id), "survives")
        XCTAssertEqual(
            tier.inner.value(account: id), "survives",
            "With no trustworthy key, the value must live in the keychain tier."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path)
                && (try? Data(contentsOf: url)).map {
                    EncryptedSecretArchive.decode($0)?[id] != nil
                } == true,
            "Nothing may be sealed with a key that cannot be read back."
        )
        XCTAssertTrue(store.storageDescription().contains("UNREADABLE"),
                      "The report must name the shape: \(store.storageDescription())")
    }

    /// The user's keychain auto-locks (measured mid-session). With the master key warmed at
    /// launch, sealed secrets must keep decrypting straight through a later lock.
    func testWarmedMasterKeySurvivesAKeychainLock() {
        final class TogglableTier: SecretBackingStore {
            let inner = InMemorySecretBackingStore()
            var locked = false
            private func gated(_ account: String) -> Bool {
                locked && account == ConsolidatedSecretBackingStore.masterKeyAccount
            }
            func set(_ value: String, account: String) -> OSStatus {
                gated(account) ? errSecInteractionNotAllowed : inner.set(value, account: account)
            }
            func value(account: String) -> String? {
                gated(account) ? nil : inner.value(account: account)
            }
            func contains(account: String) -> Bool { inner.contains(account: account) }
            func delete(account: String) -> OSStatus { inner.delete(account: account) }
            func accounts() -> Set<String> { inner.accounts() }
        }

        let tier = TogglableTier()
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let id = UUID().uuidString

        // Yesterday's launch sealed the secret.
        let earlier = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        XCTAssertEqual(earlier.set("through-the-lock", account: id), errSecSuccess)

        // Today's launch: consolidation warms the key, then the keychain locks.
        let today = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        _ = today.consolidateIntoFile()
        tier.locked = true
        XCTAssertEqual(
            today.value(account: id), "through-the-lock",
            "A warmed key must carry reads straight through a locked keychain."
        )

        // Without the warm-up (fresh instance, still locked) the value is unreachable —
        // which is exactly what the warm-up exists to prevent.
        let cold = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        XCTAssertNil(cold.value(account: id))
    }

    func testDeleteRemovesFromBothHomes() {
        let tier = InMemorySecretBackingStore()
        let (store, _, _) = makeStore(tier: tier)
        let sealed = UUID().uuidString
        let resident = UUID().uuidString
        _ = store.set("a", account: sealed)
        _ = tier.set("b", account: resident)

        XCTAssertEqual(store.delete(account: sealed), errSecSuccess)
        XCTAssertEqual(store.delete(account: resident), errSecSuccess)
        XCTAssertFalse(store.contains(account: sealed))
        XCTAssertFalse(store.contains(account: resident))
        XCTAssertEqual(store.delete(account: UUID().uuidString), errSecItemNotFound)
    }

    // MARK: - An unreadable master key must never be overwritten

    /// The shape from the field report: `master key created → 0` followed by `master key
    /// read-back failed`, with `contains` still true — the item is present, this identity just
    /// cannot decrypt it (a rebuild re-partitioned the ACL). The read-back guard correctly
    /// refuses to *trust* such a key, but minting one writes over the item first, and those
    /// overwritten bytes are the only way back into every sealed secret — including after the
    /// user answers "Always Allow" and the ACL heals. Creation must never clobber.
    func testUnreadableMasterKeyIsNotOverwrittenAndSealedSecretsSurviveTheHeal() {
        /// Writes always succeed and `contains` always answers true; only the master key's
        /// *decrypt* stops working. Exactly the foreign-ACL shape the report shows.
        final class ReACLedTier: SecretBackingStore {
            let inner = InMemorySecretBackingStore()
            var readable = true
            private func gated(_ account: String) -> Bool {
                !readable && account == ConsolidatedSecretBackingStore.masterKeyAccount
            }
            func set(_ value: String, account: String) -> OSStatus {
                inner.set(value, account: account)
            }
            func value(account: String) -> String? {
                gated(account) ? nil : inner.value(account: account)
            }
            func contains(account: String) -> Bool { inner.contains(account: account) }
            func delete(account: String) -> OSStatus { inner.delete(account: account) }
            func accounts() -> Set<String> { inner.accounts() }
        }

        let tier = ReACLedTier()
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let id = UUID().uuidString
        let keyAccount = ConsolidatedSecretBackingStore.masterKeyAccount

        // Day 1: the key reads back, so the secret is sealed into the archive.
        let day1 = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        XCTAssertEqual(day1.set("old-secret", account: id), errSecSuccess)
        let originalKey = tier.inner.value(account: keyAccount)
        XCTAssertNotNil(originalKey, "precondition: day 1 must have sealed under a stored key")

        // Day 2: a rebuild re-partitions the ACL. The item is present but unreadable, and a
        // fresh process (nothing cached) saves an unrelated secret and runs the launch sweep —
        // both land on `masterKey(createIfNeeded: true)`.
        tier.readable = false
        let day2 = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        XCTAssertTrue(
            day2.storageDescription().contains("UNREADABLE"),
            "precondition: the reported state — \(day2.storageDescription())"
        )
        XCTAssertEqual(day2.set("unrelated", account: UUID().uuidString), errSecSuccess)
        _ = day2.consolidateIntoFile()

        XCTAssertEqual(
            tier.inner.value(account: keyAccount), originalKey,
            "A master key that exists but cannot be read must never be overwritten: those "
                + "bytes are the only way back into every sealed secret."
        )

        // Day 3: the user answers Always Allow, the ACL heals, decrypt works again.
        tier.readable = true
        let day3 = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        XCTAssertEqual(
            day3.value(account: id), "old-secret",
            "The sealed secret must survive the unreadable window and return after the heal."
        )
    }

    // MARK: - "Could not run" is not "failed"

    /// `remaining` is documented as "keychain-resident secrets that could not be moved yet
    /// (unreadable silently, **or no master key while the keychain is locked**)". Reporting
    /// that state as `failed` is what turns a lossless, expected fallback into "4 failed" at
    /// the top of a bug report. A pass with no usable key has deferred every item, not failed
    /// on any of them.
    func testNoUsableMasterKeyDefersConsolidationRatherThanFailingIt() {
        final class WriteOnlyMasterTier: SecretBackingStore {
            let inner = InMemorySecretBackingStore()
            func set(_ value: String, account: String) -> OSStatus {
                inner.set(value, account: account)
            }
            func value(account: String) -> String? {
                account == ConsolidatedSecretBackingStore.masterKeyAccount
                    ? nil // written, never readable — the foreign-ACL shape
                    : inner.value(account: account)
            }
            func contains(account: String) -> Bool { inner.contains(account: account) }
            func delete(account: String) -> OSStatus { inner.delete(account: account) }
            func accounts() -> Set<String> { inner.accounts() }
        }

        let tier = WriteOnlyMasterTier()
        let (store, _, _) = makeStore(tier: tier)
        let residents = [UUID().uuidString, UUID().uuidString, UUID().uuidString]
        for account in residents {
            XCTAssertEqual(tier.set("resident-\(account.prefix(4))", account: account), errSecSuccess)
        }

        let summary = store.consolidateIntoFile()

        XCTAssertEqual(
            summary,
            SecretConsolidationSummary(moved: 0, remaining: residents.count, failed: 0),
            "No usable master key defers every item; nothing failed. Got \(summary)."
        )
        // And the fallback really is lossless — every value still reads through the tier.
        for account in residents {
            XCTAssertNotNil(store.value(account: account))
        }
    }

    // MARK: - The master key is not a purgeable orphan

    func testPurgeOrphansSparesTheMasterKey() {
        let tier = InMemorySecretBackingStore()
        let (backing, _, _) = makeStore(tier: tier)
        let store = SecretStore(backing: backing)
        let live = UUID()
        _ = store.store("keep", for: live)
        _ = store.store("orphan", for: UUID())

        let summary = store.purgeOrphans(keeping: [live])
        XCTAssertEqual(summary, .init(attempted: 1, removed: 1, failed: 0))
        XCTAssertEqual(store.secret(for: live), "keep")
        XCTAssertTrue(
            tier.contains(account: ConsolidatedSecretBackingStore.masterKeyAccount),
            "Purging the master key would orphan every sealed secret at once."
        )
    }

    /// The §8.11 post-mortem test: two independent store instances over the same archive and
    /// tier — the two-writer shape that lost a secret. After the storm, every account must be
    /// readable somewhere; a keychain copy may only be gone if the archive answers for it.
    func testTwoWritersOverOneArchiveLoseNothing() {
        let tier = InMemorySecretBackingStore()
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let a = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
        let b = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())

        let accounts = (0..<12).map { _ in UUID().uuidString }
        for (index, account) in accounts.enumerated() {
            _ = tier.set("seed-\(index)", account: account) // §8.10-era residents
        }

        // Both writers consolidate and read concurrently, interleaving on the same file.
        DispatchQueue.concurrentPerform(iterations: 24) { i in
            let store = i % 2 == 0 ? a : b
            switch i % 3 {
            case 0: _ = store.consolidateIntoFile()
            case 1: _ = store.value(account: accounts[i % accounts.count])
            default: _ = store.set("rewritten-\(i)", account: accounts[i % accounts.count])
            }
        }

        // The invariant that was violated: nothing may be lost. Every account readable.
        let survivor = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        for account in accounts {
            XCTAssertNotNil(
                survivor.value(account: account),
                "account \(account.prefix(8))… lost — the two-writer clobber is back"
            )
        }
    }

    // MARK: - Deterministic two-writer transactions

    /// Pause at real tier boundaries without production hooks or scheduler-dependent sleeps.
    /// Each callback is consumed before invocation so the competing store can use this tier.
    private final class InterleavingTier: SecretBackingStore {
        let inner = InMemorySecretBackingStore()
        var afterMissingMasterKey: (() -> Void)?
        var afterValueRead: ((String) -> Void)?
        var beforeDelete: ((String) -> Void)?
        private(set) var masterKeyWrites = 0

        func set(_ value: String, account: String) -> OSStatus {
            if account == ConsolidatedSecretBackingStore.masterKeyAccount { masterKeyWrites += 1 }
            return inner.set(value, account: account)
        }

        func value(account: String) -> String? {
            let value = inner.value(account: account)
            if account != ConsolidatedSecretBackingStore.masterKeyAccount {
                let callback = afterValueRead
                afterValueRead = nil
                callback?(account)
            }
            return value
        }

        func contains(account: String) -> Bool {
            let present = inner.contains(account: account)
            if !present, account == ConsolidatedSecretBackingStore.masterKeyAccount {
                let callback = afterMissingMasterKey
                afterMissingMasterKey = nil
                callback?()
            }
            return present
        }

        func delete(account: String) -> OSStatus {
            let callback = beforeDelete
            beforeDelete = nil
            callback?(account)
            return inner.delete(account: account)
        }

        func accounts() -> Set<String> { inner.accounts() }
    }

    /// An independent descriptor proves whether the competing writer can enter *now*.
    /// If it can, execute the losing schedule synchronously; otherwise the caller runs the
    /// competitor after the first transaction finishes. Both outcomes are bounded and exercise
    /// real stores, archive bytes and encryption, with no expectation based on elapsed time.
    private func interleaveIfUnlocked(at url: URL, _ operation: () -> Void) throws -> Bool {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            guard error == EWOULDBLOCK else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
            }
            return false
        }
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        operation()
        return true
    }

    func testTwoWritersCannotReplaceTheMasterKeyDuringConsolidation() throws {
        let tier = InterleavingTier()
        let (a, _, url) = makeStore(tier: tier)
        let b = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
        let resident = UUID().uuidString
        let competing = UUID().uuidString
        XCTAssertEqual(tier.set("resident", account: resident), errSecSuccess)

        var interleaved = false
        let write = { XCTAssertEqual(b.set("competing", account: competing), errSecSuccess) }
        tier.afterMissingMasterKey = {
            do { interleaved = try self.interleaveIfUnlocked(at: url, write) }
            catch { XCTFail("Lock probe failed: \(error)") }
        }
        XCTAssertEqual(a.consolidateIntoFile(), .init(moved: 1, remaining: 0, failed: 0))
        XCTAssertNil(tier.afterMissingMasterKey, "The test must reach the key-creation boundary")
        if !interleaved { write() }

        XCTAssertEqual(tier.masterKeyWrites, 1, "A second key strands secrets sealed by the other writer")
        let reopened = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
        XCTAssertEqual(reopened.value(account: resident), "resident")
        XCTAssertEqual(reopened.value(account: competing), "competing")
    }

    func testLazyConsolidationCannotReplayAStaleTierRead() throws {
        try assertTierReadCannotReplay(consolidating: false)
    }

    func testBatchConsolidationCannotReplayAStaleTierRead() throws {
        try assertTierReadCannotReplay(consolidating: true)
    }

    private func assertTierReadCannotReplay(consolidating: Bool) throws {
        for deleting in [false, true] {
            let tier = InterleavingTier()
            let url = directory.appendingPathComponent(UUID().uuidString).appendingPathComponent("secrets.enc")
            let a = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
            let b = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
            // Settle the key first to isolate stale tier reads from master-key creation.
            XCTAssertEqual(a.set("warmup", account: UUID().uuidString), errSecSuccess)
            let account = UUID().uuidString
            XCTAssertEqual(tier.set("old", account: account), errSecSuccess)
            var interleaved = false
            let mutate = {
                XCTAssertEqual(deleting ? b.delete(account: account) : b.set("new", account: account),
                               errSecSuccess)
            }
            tier.afterValueRead = { readAccount in
                XCTAssertEqual(readAccount, account)
                do { interleaved = try self.interleaveIfUnlocked(at: url, mutate) }
                catch { XCTFail("Lock probe failed: \(error)") }
            }
            if consolidating {
                XCTAssertEqual(a.consolidateIntoFile(), .init(moved: 1, remaining: 0, failed: 0))
            }
            else { XCTAssertEqual(a.value(account: account), "old") }
            XCTAssertNil(tier.afterValueRead, "The test must reach the tier-read boundary")
            XCTAssertFalse(tier.inner.contains(account: account), "Migration must actually finish")
            if !interleaved { mutate() }

            let reopened = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
            XCTAssertEqual(reopened.value(account: account), deleting ? nil : "new",
                           "A delayed tier read must not undo a newer edit or resurrect a deletion")
        }
    }

    func testDeleteKeepsBothTiersInOneTransaction() throws {
        let tier = InterleavingTier()
        let (a, _, url) = makeStore(tier: tier)
        let b = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
        let account = UUID().uuidString
        XCTAssertEqual(a.set("resident", account: account), errSecSuccess)
        // Both copies can legitimately survive when consolidation's tier cleanup was denied.
        XCTAssertEqual(tier.set("resident", account: account), errSecSuccess)
        var interleaved = false
        tier.beforeDelete = { deletedAccount in
            XCTAssertEqual(deletedAccount, account)
            do {
                interleaved = try self.interleaveIfUnlocked(at: url) { _ = b.value(account: account) }
            } catch { XCTFail("Lock probe failed: \(error)") }
        }
        XCTAssertEqual(a.delete(account: account), errSecSuccess)
        XCTAssertNil(tier.beforeDelete, "The test must reach tier cleanup")
        if !interleaved { XCTAssertNil(b.value(account: account)) }

        let reopened = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
        XCTAssertNil(reopened.value(account: account), "Consolidation must not resurrect a successful delete")
        XCTAssertFalse(reopened.contains(account: account))
    }

    // MARK: - Fuzz

    /// Random interleaving of every operation against a model dictionary: the store must agree
    /// with the model after every step, and the archive file must never contain a plaintext.
    func testStoreAgreesWithModelUnderFuzz() throws {
        var state: UInt64 = 0x8_11
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        let tier = InMemorySecretBackingStore()
        let (store, _, url) = makeStore(tier: tier)
        var model: [String: String] = [:]
        let ids = (0..<6).map { _ in UUID().uuidString }

        for step in 0..<1_500 {
            let id = ids[Int(next() % UInt64(ids.count))]
            switch next() % 5 {
            case 0:
                let value = "v\(step)-\(next())"
                // A direct tier write simulates an §8.10-era keychain resident. Reality's
                // invariant: old builds are dead after install, so a resident can only exist
                // for an account the archive does not hold — mirror that here.
                if next() % 4 == 0, !store.contains(account: id) {
                    _ = tier.set(value, account: id)
                } else {
                    _ = store.set(value, account: id)
                }
                model[id] = value
            case 1:
                XCTAssertEqual(store.value(account: id), model[id], "step \(step)")
            case 2:
                _ = store.delete(account: id)
                model.removeValue(forKey: id)
            case 3:
                XCTAssertEqual(store.contains(account: id), model[id] != nil, "step \(step)")
            default:
                _ = store.consolidateIntoFile()
            }
        }

        XCTAssertEqual(store.accounts(), Set(model.keys))
        if let raw = try? Data(contentsOf: url) {
            let text = String(decoding: raw, as: UTF8.self)
            for value in model.values {
                XCTAssertFalse(text.contains(value), "plaintext leaked into the archive")
            }
        }
    }
}
