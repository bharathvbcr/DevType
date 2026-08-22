import Security
import XCTest
@testable import ExpanderEngine

// Deletion integrity: `delete` is two-phase (sealed archive + keychain tier).
// Pre-fix the phases were combined with `||`, so a failed archive save was masked
// by a tier success — the UI reported "deleted" while the sealed copy remained on
// disk and `contains`/`value` still resolved the secret.

final class SecretDeleteIntegrityTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("secret-delete-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        // Restore writability so cleanup always succeeds even mid-failure.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path
        )
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore(tier: SecretBackingStore = InMemorySecretBackingStore())
        -> (ConsolidatedSecretBackingStore, URL) {
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let store = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        return (store, url)
    }

    func testFailedArchiveSaveReportsFailureAndKeepsSecretResolvable() throws {
        let (store, url) = makeStore()
        let id = UUID().uuidString
        XCTAssertEqual(store.set("doomed", account: id), errSecSuccess)
        XCTAssertEqual(store.value(account: id), "doomed")

        // Make every write into the archive's directory fail (temp-file creation
        // included), while reads keep working.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )

        XCTAssertEqual(
            store.delete(account: id), errSecIO,
            "an archive copy that cannot be removed is a FAILED delete"
        )
        XCTAssertTrue(store.contains(account: id))
        XCTAssertEqual(store.value(account: id), "doomed")
    }

    /// Ordinary path stays intact: an account living only in the keychain tier
    /// deletes cleanly when the archive has no entry for it.
    func testTierOnlyDeleteStillSucceeds() {
        let tier = InMemorySecretBackingStore()
        let id = UUID().uuidString
        _ = tier.set("resident", account: id)
        let (store, _) = makeStore(tier: tier)

        XCTAssertEqual(store.delete(account: id), errSecSuccess)
        XCTAssertFalse(store.contains(account: id))
        XCTAssertNil(store.value(account: id))
    }

    /// An archive holding bytes this build cannot vouch for may still hold the
    /// account's sealed copy. Delete must refuse honestly (`errSecIO`), leave the
    /// tier copy — and therefore a resolvable secret — in place, and neither
    /// quarantine nor overwrite the unreadable bytes (recovery flows own them).
    func testUnreadableArchiveRefusesDeleteAndKeepsEntryReadable() throws {
        let tier = InMemorySecretBackingStore()
        let id = UUID().uuidString
        _ = tier.set("resident", account: id)
        let (store, url) = makeStore(tier: tier)

        // Real archive bytes first (so the file exists), then corrupt them in place
        // the way a torn write or a newer schema would.
        XCTAssertEqual(store.set("sealed", account: UUID().uuidString), errSecSuccess)
        let undecodable = Data(#"{ "version": 1, "entries": { "#.utf8)
        try undecodable.write(to: url)

        XCTAssertEqual(
            store.delete(account: id), errSecIO,
            "with unreadable archive bytes a delete cannot prove the sealed copy is gone; "
                + "it must refuse rather than report success over a surviving shadow"
        )
        XCTAssertTrue(store.contains(account: id))
        XCTAssertEqual(store.value(account: id), "resident")
    }
}
