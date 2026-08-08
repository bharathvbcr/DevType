import CryptoKit
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

    // MARK: - The master key is not a purgeable orphan

    func testPurgeOrphansSparesTheMasterKey() {
        let tier = InMemorySecretBackingStore()
        let (backing, _, _) = makeStore(tier: tier)
        let store = SecretStore(backing: backing)
        let live = UUID()
        _ = store.store("keep", for: live)
        _ = store.store("orphan", for: UUID())

        let removed = store.purgeOrphans(keeping: [live])
        XCTAssertEqual(removed, 1)
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
