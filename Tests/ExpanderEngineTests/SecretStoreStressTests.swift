import XCTest
@testable import ExpanderEngine

/// Adversarial pressure on the storage tier: a keychain that lies, flaps, and fails in every
/// combination, driven concurrently. The property that must never break is the one whose
/// violation is unrecoverable — **key material is never destroyed**.
final class SecretStoreStressTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("secret-stress-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A tier whose master-key readability flaps under the caller's feet, the way a keychain
    /// auto-locking mid-session and an ACL re-partitioned by a rebuild both present.
    private final class FlappingTier: SecretBackingStore {
        let inner = InMemorySecretBackingStore()
        private let lock = NSLock()
        private var _readable = true
        /// Every distinct master-key value this tier has ever been asked to store.
        private(set) var masterKeyWrites: [String] = []

        var readable: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _readable }
            set { lock.lock(); _readable = newValue; lock.unlock() }
        }

        func set(_ value: String, account: String) -> OSStatus {
            if account == ConsolidatedSecretBackingStore.masterKeyAccount {
                lock.lock()
                if masterKeyWrites.last != value { masterKeyWrites.append(value) }
                lock.unlock()
            }
            return inner.set(value, account: account)
        }
        func value(account: String) -> String? {
            if account == ConsolidatedSecretBackingStore.masterKeyAccount, !readable { return nil }
            return inner.value(account: account)
        }
        func contains(account: String) -> Bool { inner.contains(account: account) }
        func delete(account: String) -> OSStatus { inner.delete(account: account) }
        func accounts() -> Set<String> { inner.accounts() }
    }

    /// The unrecoverable failure, hunted directly: across any interleaving of saves, reads and
    /// consolidation passes while the key's readability flaps, the store must never write a
    /// *second* distinct master key. The first one is the only way into every sealed secret.
    func testTheMasterKeyIsWrittenAtMostOnceHoweverTheKeychainFlaps() {
        for seed in UInt64(1)...120 {
            var rng = SplitMix64(seed: seed)
            let tier = FlappingTier()
            let url = directory.appendingPathComponent("flap-\(seed).enc")
            var store = ConsolidatedSecretBackingStore(
                fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
            )
            var accounts: [String] = []

            for _ in 0..<40 {
                switch Int.random(in: 0..<6, using: &rng) {
                case 0:
                    tier.readable.toggle()
                case 1:
                    let id = UUID().uuidString
                    accounts.append(id)
                    _ = store.set("secret-\(id.prefix(4))", account: id)
                case 2:
                    if let id = accounts.randomElement(using: &rng) { _ = store.value(account: id) }
                case 3:
                    _ = store.consolidateIntoFile()
                case 4:
                    // A relaunch: fresh instance, nothing cached.
                    store = ConsolidatedSecretBackingStore(
                        fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
                    )
                default:
                    if let id = accounts.randomElement(using: &rng) { _ = store.delete(account: id) }
                }
            }

            XCTAssertLessThanOrEqual(
                tier.masterKeyWrites.count, 1,
                "seed \(seed): \(tier.masterKeyWrites.count) distinct master keys were written."
                    + " Every write past the first orphans every secret sealed under the previous one."
            )
        }
    }

    /// Whatever the tier does, a value that was successfully saved must still read back — the
    /// archive and the keychain fallback must never both disclaim a secret.
    func testNoSavedSecretIsEverLostAcrossFlapsAndRelaunches() {
        for seed in UInt64(1)...120 {
            var rng = SplitMix64(seed: seed)
            let tier = FlappingTier()
            let url = directory.appendingPathComponent("durable-\(seed).enc")
            var store = ConsolidatedSecretBackingStore(
                fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
            )
            var expected: [String: String] = [:]

            for step in 0..<40 {
                switch Int.random(in: 0..<5, using: &rng) {
                case 0:
                    tier.readable.toggle()
                case 1:
                    let id = "acct-\(step)-\(seed)"
                    let value = "value-\(step)"
                    if store.set(value, account: id) == errSecSuccess { expected[id] = value }
                case 2:
                    _ = store.consolidateIntoFile()
                case 3:
                    store = ConsolidatedSecretBackingStore(
                        fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
                    )
                default:
                    if let id = expected.keys.sorted().randomElement(using: &rng) {
                        if store.delete(account: id) == errSecSuccess { expected.removeValue(forKey: id) }
                    }
                }
            }

            // Readable keychain is the fair reading condition: an unreadable key is a diagnosed
            // outage, not data loss. Everything saved must come back.
            tier.readable = true
            let reopened = ConsolidatedSecretBackingStore(
                fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
            )
            for (account, value) in expected {
                XCTAssertEqual(
                    reopened.value(account: account), value,
                    "seed \(seed): \(account) was saved successfully and cannot be read back"
                )
            }
        }
    }

    /// Consolidation accounting must be total: every candidate lands in exactly one bucket.
    /// A pass that quietly drops an item would understate what is still keychain-resident.
    func testConsolidationAccountingIsTotalUnderEveryKeyState() {
        for readable in [true, false] {
            let tier = FlappingTier()
            tier.readable = readable
            let (store, _, _) = (
                ConsolidatedSecretBackingStore(
                    fileURL: directory.appendingPathComponent("acct-\(readable).enc"),
                    tier: tier,
                    diagnostics: SecretAccessDiagnostics()
                ), tier, ()
            )
            let ids = (0..<7).map { _ in UUID().uuidString }
            for id in ids { XCTAssertEqual(tier.set("v-\(id.prefix(4))", account: id), errSecSuccess) }

            let summary = store.consolidateIntoFile()
            XCTAssertEqual(
                summary.moved + summary.remaining + summary.failed, ids.count,
                "readable=\(readable): every candidate must be counted exactly once — got \(summary)"
            )
            if !readable {
                XCTAssertEqual(
                    summary, SecretConsolidationSummary(moved: 0, remaining: ids.count, failed: 0),
                    "No usable key defers every item; nothing failed."
                )
            }
        }
    }

    /// Concurrent readers, writers and consolidation passes over one store.
    func testConcurrentAccessNeverLosesTheKeyOrDeadlocks() {
        let tier = FlappingTier()
        let store = ConsolidatedSecretBackingStore(
            fileURL: directory.appendingPathComponent("concurrent.enc"),
            tier: tier,
            diagnostics: SecretAccessDiagnostics()
        )
        let ids = (0..<12).map { _ in UUID().uuidString }
        let group = DispatchGroup()

        for worker in 0..<6 {
            DispatchQueue.global().async(group: group) {
                for i in 0..<150 {
                    let id = ids[(worker + i) % ids.count]
                    switch i % 5 {
                    case 0: _ = store.set("w\(worker)-\(i)", account: id)
                    case 1: _ = store.value(account: id)
                    case 2: _ = store.consolidateIntoFile()
                    case 3: _ = store.accounts()
                    default: if i % 25 == 4 { tier.readable.toggle() }
                    }
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 120), .success, "deadlock under concurrent access")
        XCTAssertLessThanOrEqual(
            tier.masterKeyWrites.count, 1,
            "Concurrency must not open a window where a second master key is minted."
        )
    }
}
