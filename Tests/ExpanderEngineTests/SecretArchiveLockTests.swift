import XCTest
@testable import ExpanderEngine

// §-audit hardening for `ConsolidatedSecretBackingStore.withArchiveLock`.
//
// When `open(2)` failed on the lock file the store silently proceeded *without*
// cross-process exclusion — the exact window the §8.11 archive lock exists to
// close — and nothing in the diagnostics trail said so. The fix records
// `archive lock unavailable`, retries once after a short delay, and if the lock
// still cannot be opened proceeds with the failure recorded rather than breaking
// single-process functionality.

final class SecretArchiveLockTests: XCTestCase {

    func testLockOpenFailureIsRecordedAndStoreStillFunctions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeArchiveLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        // A directory at the lock path makes open(O_CREAT | O_RDWR) fail with EISDIR,
        // deterministically and without touching real file permissions.
        try FileManager.default.createDirectory(
            at: archiveURL.appendingPathExtension("lock"),
            withIntermediateDirectories: false
        )

        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        let store = ConsolidatedSecretBackingStore(
            fileURL: archiveURL, tier: tier, diagnostics: diagnostics
        )

        // Single-process functionality must survive the unavailable lock.
        XCTAssertEqual(store.set("lockless-value", account: "acct-a"), errSecSuccess)
        XCTAssertEqual(store.value(account: "acct-a"), "lockless-value")
        XCTAssertTrue(store.contains(account: "acct-a"))
        XCTAssertEqual(store.delete(account: "acct-a"), errSecSuccess)

        let trail = diagnostics.trail()
        XCTAssertTrue(
            trail.contains("archive lock unavailable"),
            "an unavailable archive lock must be visible in the diagnostics trail; got \(trail)"
        )
    }
}
