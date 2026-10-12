import XCTest
@testable import ExpanderEngine

/// Failure paths that used to be invisible: the secret archive quarantine move, and orphan
/// collection counting files it failed to remove.
final class StoreFailureDiagnosticsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeStoreFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        PersistedFileLoader.observer = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    func testSecretArchiveQuarantineMoveFailureLeavesAValueFreeNote() throws {
        try XCTSkipIf(getuid() == 0, "root ignores directory modes")
        let url = directory.appendingPathComponent("secrets.enc")
        let diagnostics = SecretAccessDiagnostics()
        let backing = ConsolidatedSecretBackingStore(
            fileURL: url, tier: InMemorySecretBackingStore(), diagnostics: diagnostics
        )
        // A first save creates the archive lock beside the file; then the archive goes bad.
        XCTAssertEqual(backing.set("seed", account: UUID().uuidString), errSecSuccess)
        try Data("not a sealed archive".utf8).write(to: url)
        // Read-only directory: the quarantine rename is refused.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let account = "account-name-that-must-not-leak-\(UUID().uuidString)"
        _ = backing.set("secret-value-that-must-not-leak", account: account)

        let trail = diagnostics.trail().joined(separator: "\n")
        XCTAssertTrue(trail.contains("quarantine move failed"), trail)
        XCTAssertFalse(trail.contains(account), trail)
        XCTAssertFalse(trail.contains("secret-value-that-must-not-leak"), trail)
        XCTAssertFalse(trail.contains(directory.path), trail)
    }

    func testOrphanCollectionCountsOnlyActualRemovals() throws {
        let lock = NSLock()
        var lines: [String] = []
        PersistedFileLoader.observer = { lock.lock(); lines.append($0); lock.unlock() }

        let store = ImageAttachmentStore(directory: directory) { url in
            if url.lastPathComponent == "stuck.png" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        for name in ["gone.png", "stuck.png"] {
            try Data([0]).write(to: directory.appendingPathComponent(name))
        }

        let removed = store.collectOrphans(referencedPaths: [])
        XCTAssertEqual(removed, ["gone.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stuck.png").path))
        lock.lock(); defer { lock.unlock() }
        XCTAssertTrue(lines.joined().contains("Failed to remove 1 orphaned"), lines.joined())

        // A dry run still reports what would go.
        XCTAssertEqual(store.collectOrphans(referencedPaths: [], dryRun: true), ["stuck.png"])
    }
}
