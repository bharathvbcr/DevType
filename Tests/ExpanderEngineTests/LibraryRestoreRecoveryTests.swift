import XCTest
@testable import ExpanderEngine

/// "Restore from Backup…" out of a read-blocked or corrupt library, the orphan pre-restore copy,
/// and the backup size cap. Same isolation as `LibraryRollingBackupTests`.
final class LibraryRestoreRecoveryTests: XCTestCase {

    private var root: URL!
    private var support: URL!
    private var file: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devtype-restore-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        file = support.appendingPathComponent("snippets.json")
        defaultsSuite = "devtype.restore.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in walker {
                try? FilePermissions.setPOSIX(root.appendingPathComponent(relative), 0o700)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> SnippetStore {
        SnippetStore(
            location: .init(fileURL: file, expectsExistingLibrary: false),
            deviceDefaults: defaults,
            localSupportDirectory: support,
            watcherFactory: { _ in nil }
        )
    }

    private func groups(_ triggers: String...) -> [SnippetGroup] {
        [SnippetGroup(name: "G", snippets: triggers.map {
            SnippetModel(title: $0, triggerKeyword: $0, replacementText: "body-\($0)")
        })]
    }

    private func triggers(in data: Data) throws -> [String] {
        try SnippetStore.decodeSnippets(from: data).map(\.triggerKeyword).sorted()
    }

    /// Saves `a, aa` then `b`; returns the backup that holds `a, aa`.
    private func makeBackupOfA() throws -> URL {
        let store = makeStore()
        XCTAssertTrue(store.saveGroups(groups("a", "aa")).didSave)
        XCTAssertTrue(store.saveGroups(groups("b")).didSave)
        return try XCTUnwrap(store.libraryBackups().first).url
    }

    // MARK: - Restore out of a latched library

    func testRestoreOverACorruptLatchedLibrarySucceedsAndKeepsTheCorruptBytes() throws {
        let backup = try makeBackupOfA()
        let corrupt = Data("{torn".utf8)
        try corrupt.write(to: file)
        let store = makeStore()
        XCTAssertTrue(store.isLibraryReadFailed, "precondition: a corrupt file latches the store")

        let heard = expectation(description: "listeners hear the restore")
        var registered = false
        let token = store.addGroupListener { _ in if registered { heard.fulfill() } }
        registered = true

        let result = store.restoreLibrary(fromBackup: backup)

        XCTAssertTrue(result.didRestore, "restore was refused in the state it exists for: \(result.outcome)")
        wait(for: [heard], timeout: 2)
        // The restore notifies exactly once (the expectation traps a second call). Stop listening
        // before the follow-up save below, which legitimately notifies again.
        store.removeListener(token: token)
        let kept = try XCTUnwrap(result.preRestoreBackupURL)
        XCTAssertEqual(try Data(contentsOf: kept), corrupt)
        XCTAssertEqual(store.backups.entry(for: kept)?.kind, .preRestore)
        XCTAssertFalse(store.isLibraryReadFailed, "a successful restore must clear the latch")
        XCTAssertEqual(try triggers(in: Data(contentsOf: file)), ["a", "aa"])
        let followUp = store.saveGroups(groups("c"))
        XCTAssertTrue(followUp.didSave, "saves must work again after the restore: \(followUp)")
    }

    func testRestoreOverAnUnreadableLibraryPreservesTheFileItself() throws {
        let backup = try makeBackupOfA()
        let original = try Data(contentsOf: file)
        try FilePermissions.setPOSIX(file, 0)
        if FileManager.default.isReadableFile(atPath: file.path) {
            throw XCTSkip("this process can read a mode-000 file")
        }
        let store = makeStore()
        XCTAssertTrue(store.isLibraryReadFailed)

        let result = store.restoreLibrary(fromBackup: backup)

        XCTAssertTrue(result.didRestore, "\(result.outcome)")
        let kept = try XCTUnwrap(result.preRestoreBackupURL)
        try FilePermissions.setPOSIX(kept, 0o600)
        XCTAssertEqual(try Data(contentsOf: kept), original)
        XCTAssertFalse(store.isLibraryReadFailed)
        XCTAssertEqual(try triggers(in: Data(contentsOf: file)), ["a", "aa"])
    }

    func testRestoreIsRefusedAndTheFileUntouchedWhenThePreRestoreCopyCannotBeWritten() throws {
        let backup = try makeBackupOfA()
        let corrupt = Data("{torn".utf8)
        try corrupt.write(to: file)
        let store = makeStore()
        XCTAssertTrue(store.isLibraryReadFailed)
        let backupsDir = support.appendingPathComponent("Backups", isDirectory: true)
        try FilePermissions.setPOSIX(backupsDir, 0o500)
        defer { try? FilePermissions.setPOSIX(backupsDir, 0o700) }
        if FileManager.default.isWritableFile(atPath: backupsDir.path) {
            throw XCTSkip("this process can write a mode-500 directory")
        }

        let result = store.restoreLibrary(fromBackup: backup)

        XCTAssertFalse(result.didRestore)
        XCTAssertNil(result.preRestoreBackupURL)
        XCTAssertEqual(try Data(contentsOf: file), corrupt, "the library was replaced without a copy")
        XCTAssertTrue(store.isLibraryReadFailed, "a refused restore must leave the latch set")
    }

    func testRestoreOverAnEmptyLibraryFileNeedsNoPreRestoreCopy() throws {
        let backup = try makeBackupOfA()
        try Data().write(to: file)
        let store = makeStore()

        let result = store.restoreLibrary(fromBackup: backup)

        XCTAssertTrue(result.didRestore, "\(result.outcome)")
        XCTAssertNil(result.preRestoreBackupURL, "a zero-byte file holds nothing worth keeping")
        XCTAssertEqual(try triggers(in: Data(contentsOf: file)), ["a", "aa"])
    }

    func testRestoreWhereTheLibraryPathIsADirectoryNeverLeavesAHalfStateBehind() throws {
        let backup = try makeBackupOfA()
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: file.appendingPathComponent("note.txt"))
        let store = makeStore()

        let result = store.restoreLibrary(fromBackup: backup)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
        if result.didRestore {
            XCTAssertFalse(isDirectory.boolValue)
            XCTAssertEqual(try triggers(in: Data(contentsOf: file)), ["a", "aa"])
            let kept = try XCTUnwrap(result.preRestoreBackupURL, "the directory it replaced must be preserved")
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("note.txt").path),
                          "kept=\(kept.path) \((try? FileManager.default.contentsOfDirectory(atPath: kept.path)) ?? [])")
        } else {
            XCTAssertTrue(isDirectory.boolValue, "a refused restore changed the library path")
        }
    }

    func testAFailedRestoreWriteRemovesItsOrphanPreRestoreCopyWhenTheLibraryIsUnchanged() throws {
        let backup = try makeBackupOfA()
        let store = makeStore()
        let before = try Data(contentsOf: file)
        // Backups/ stays writable; the library's own directory does not, so only the final write fails.
        try FilePermissions.setPOSIX(support, 0o500)
        defer { try? FilePermissions.setPOSIX(support, 0o700) }
        if FileManager.default.isWritableFile(atPath: support.path) {
            throw XCTSkip("this process can write a mode-500 directory")
        }

        let result = store.restoreLibrary(fromBackup: backup)

        XCTAssertFalse(result.didRestore)
        XCTAssertNil(result.preRestoreBackupURL)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(store.backups.entries().filter { $0.kind == .preRestore }.isEmpty,
                      "an orphan pre-restore copy was left behind a restore that never landed")
    }

    func testConcurrentSavesAndRestoresLeaveADecodableLibraryMatchingTheCache() throws {
        let backup = try makeBackupOfA()
        let store = makeStore()
        let group = DispatchGroup()
        for i in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                if i % 3 == 0 { _ = store.restoreLibrary(fromBackup: backup) }
                else { _ = store.saveGroups(self.groups("c\(i)")) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        let onDisk = try triggers(in: Data(contentsOf: file))
        XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword).sorted(), onDisk)
    }

    // MARK: - Backup size cap

    func testRollingBackupsAreCappedAtTheSameLimitListingAndRestoreUse() throws {
        let backups = LibraryBackupStore(directory: support.appendingPathComponent("cap", isDirectory: true))
        let oversized = Data(count: LibraryBackupStore.maximumBackupBytes + 1)
        XCTAssertThrowsError(try backups.backUp(oversized, kind: .save))
        XCTAssertTrue(backups.entries().isEmpty)
        // A safety copy outranks listing: the bytes are kept even though restore would refuse them.
        XCTAssertTrue(try backups.backUp(oversized, kind: .preOverwrite).created)
        let atLimit = Data(count: LibraryBackupStore.maximumBackupBytes)
        XCTAssertTrue(try backups.backUp(atLimit, kind: .save).created)
    }

    func testASaveOverAnOversizedLibraryLandsAndReportsTheSkippedBackup() throws {
        var padded = try SnippetStore.exportLibraryData(groups: groups("a"))
        padded.append(Data(repeating: 0x20, count: LibraryBackupStore.maximumBackupBytes))
        try padded.write(to: file)
        let store = makeStore()
        if store.isLibraryReadFailed { throw XCTSkip("an oversized library is refused at load; cap is moot") }

        let outcome = store.saveGroups(groups("b"))

        guard case .savedWithoutBackup(let reason) = outcome else {
            return XCTFail("expected .savedWithoutBackup, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("backup limit"), reason)
        XCTAssertEqual(try triggers(in: Data(contentsOf: file)), ["b"])
        XCTAssertTrue(store.backups.entries().isEmpty)
    }
}
