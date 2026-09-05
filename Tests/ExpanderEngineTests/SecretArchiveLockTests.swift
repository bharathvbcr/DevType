import Darwin
import XCTest
@testable import ExpanderEngine

// §-audit hardening for `ConsolidatedSecretBackingStore.withArchiveLock`.
//
// An unavailable lock must be diagnosed AND refuse the transaction. The earlier
// fail-open expectation preserved single-instance availability by allowing the
// very cross-writer data loss that the archive lock is meant to prevent.

final class SecretArchiveLockTests: XCTestCase {

    func testUnavailableLockNeverChangesArchiveOrMasterKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeArchiveLock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let tier = InMemorySecretBackingStore()
        let store = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
        let sealed = UUID().uuidString
        let resident = UUID().uuidString
        XCTAssertEqual(store.set("sealed", account: sealed), errSecSuccess)
        XCTAssertEqual(tier.set("resident", account: resident), errSecSuccess)
        let bytes = try Data(contentsOf: url)
        let key = tier.value(account: ConsolidatedSecretBackingStore.masterKeyAccount)
        let lockURL = url.appendingPathExtension("lock")
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)

        XCTAssertEqual(store.set("replacement", account: sealed), errSecIO)
        XCTAssertEqual(store.delete(account: sealed), errSecIO)
        XCTAssertNil(store.value(account: resident), "A read must not migrate without exclusion")
        XCTAssertEqual(store.consolidateIntoFile(), .init(moved: 0, remaining: 1, failed: 0))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(tier.value(account: ConsolidatedSecretBackingStore.masterKeyAccount), key)
        XCTAssertEqual(tier.value(account: resident), "resident")

        try FileManager.default.removeItem(at: lockURL)
        let reopened = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
        XCTAssertEqual(reopened.value(account: sealed), "sealed")
        XCTAssertEqual(reopened.value(account: resident), "resident")
    }

    func testLockOpenFailureIsRecordedAndStoreRecoversAfterRepair() throws {
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

        XCTAssertEqual(store.set("lockless-value", account: "acct-a"), errSecIO)
        XCTAssertNil(store.value(account: "acct-a"))
        XCTAssertFalse(store.contains(account: "acct-a"))
        XCTAssertEqual(store.delete(account: "acct-a"), errSecIO)
        XCTAssertTrue(tier.accounts().isEmpty, "Refusal must not create a master key or tier value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))

        let trail = diagnostics.trail()
        XCTAssertTrue(
            trail.contains("archive lock unavailable"),
            "an unavailable archive lock must be visible in the diagnostics trail; got \(trail)"
        )
        XCTAssertTrue(trail.contains { $0.contains("transaction refused") })

        try FileManager.default.removeItem(at: archiveURL.appendingPathExtension("lock"))
        XCTAssertEqual(store.set("lockless-value", account: "acct-a"), errSecSuccess)
        XCTAssertEqual(store.value(account: "acct-a"), "lockless-value")
        XCTAssertTrue(store.contains(account: "acct-a"))
        XCTAssertEqual(store.delete(account: "acct-a"), errSecSuccess)
    }

    func testNonregularLockPathRefusesWritesEvenWhenOpenSucceeds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeArchiveLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        // A device opens successfully (and macOS can even accept flock on it), but it is
        // not a regular archive lock file. No bytes are written to the device.
        try FileManager.default.createSymbolicLink(atPath: url.appendingPathExtension("lock").path,
                                                 withDestinationPath: "/dev/null")
        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        let store = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: diagnostics)
        XCTAssertEqual(store.set("refused", account: UUID().uuidString), errSecIO)
        XCTAssertTrue(tier.accounts().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(diagnostics.trail().contains("archive lock file invalid — transaction refused"))
    }

    func testHeldArchiveLockTimesOutWithoutMutationAndRecovers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeArchiveLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        let store = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: diagnostics)
        let account = UUID().uuidString
        XCTAssertEqual(store.set("retryable", account: account), errSecIO)
        XCTAssertTrue(tier.accounts().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(diagnostics.trail().contains("archive lock timed out — transaction refused"))

        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertEqual(store.set("retryable", account: account), errSecSuccess)
        let reopened = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
        XCTAssertEqual(reopened.value(account: account), "retryable")
    }
}
