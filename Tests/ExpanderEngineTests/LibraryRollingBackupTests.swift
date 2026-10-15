import XCTest
@testable import ExpanderEngine

/// Rolling backups taken by the save path, and "Restore from Backup…".
///
/// Each store is isolated: a temp library file, a temp `localSupportDirectory` (so `Backups/`
/// lands inside the test's root), a private defaults suite, and no watcher.
final class LibraryRollingBackupTests: XCTestCase {

    private var root: URL!
    private var support: URL!
    private var file: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devtype-rolling-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        file = support.appendingPathComponent("snippets.json")
        defaultsSuite = "devtype.rolling.tests.\(UUID().uuidString)"
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

    private func backupFiles() -> [URL] {
        let directory = support.appendingPathComponent("Backups", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().map { directory.appendingPathComponent($0) }
    }

    private func triggers(in data: Data) throws -> [String] {
        try SnippetStore.decodeSnippets(from: data).map(\.triggerKeyword).sorted()
    }

    // MARK: - Rolling backups

    func testAChangedSaveBacksUpThePreviousBytesAndAnIdenticalSaveDoesNot() throws {
        let store = makeStore()
        let libraryA = groups("a")
        XCTAssertTrue(store.saveGroups(libraryA).didSave)
        let afterFirst = backupFiles()
        let bytesA = try Data(contentsOf: file)

        XCTAssertEqual(store.saveGroups(libraryA), .saved)
        XCTAssertEqual(backupFiles(), afterFirst, "an identical save made a backup")

        XCTAssertEqual(store.saveGroups(groups("b")), .saved)
        let afterChange = backupFiles()
        XCTAssertEqual(afterChange.count, afterFirst.count + 1, "a changed save made no backup")
        let newest = try XCTUnwrap(store.backups.entries().first)
        XCTAssertEqual(newest.kind, .save)
        XCTAssertEqual(try Data(contentsOf: newest.url), bytesA, "the backup must hold the bytes the save replaced")
    }

    func testABackupWriteFailureDoesNotBlockTheSaveButIsReported() throws {
        let store = makeStore()
        XCTAssertTrue(store.saveGroups(groups("a")).didSave)
        let backups = support.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.removeItem(at: backups)
        try Data("not a directory".utf8).write(to: backups)

        let outcome = store.saveGroups(groups("b"))

        guard case .savedWithoutBackup(let reason) = outcome else {
            return XCTFail("expected .savedWithoutBackup, got \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(outcome.didSave)
        XCTAssertEqual(outcome.diagnosticLabel, "savedWithoutBackup")
        XCTAssertEqual(try triggers(in: Data(contentsOf: file)), ["b"])
        XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword), ["b"])
        XCTAssertNil(store.lastSaveFailure, "a save that landed must not raise the not-saved banner")
    }

    /// A save after the user clears a read failure must not overwrite bytes nobody could read:
    /// the ordinary save path escalates to a safety copy (a hard link, until the write commits).
    func testAnOrdinarySaveOverAnUnreadableFilePreservesIt() throws {
        let original = try SnippetStore.exportLibraryData(groups: groups("mine"))
        try original.write(to: file)
        try FilePermissions.setPOSIX(file, 0)
        if FileManager.default.isReadableFile(atPath: file.path) {
            throw XCTSkip("this process can read a mode-000 file")
        }
        let store = makeStore()
        XCTAssertTrue(store.isLibraryReadFailed)
        store.clearLibraryReadFailure()

        XCTAssertTrue(store.saveGroups(groups("new")).didSave)

        let preserved = try XCTUnwrap(store.backups.entries().first { $0.kind == .preOverwrite })
        XCTAssertEqual(try Data(contentsOf: preserved.url), original)
    }

    func testFirstRunSeedNeedsNoBackupBecauseThereIsNothingToKeep() {
        let store = makeStore()
        XCTAssertFalse(store.loadSnippets().isEmpty, "first run seeds defaults")
        XCTAssertTrue(backupFiles().isEmpty)
    }

    // MARK: - Restore

    func testRestoreRoundTripsALibraryAndFiresListenersWithoutRelaunch() throws {
        let store = makeStore()
        XCTAssertTrue(store.saveGroups(groups("a", "aa")).didSave)
        XCTAssertTrue(store.saveGroups(groups("b")).didSave)
        let bytesB = try Data(contentsOf: file)

        let listed = store.libraryBackups()
        let backupOfA = try XCTUnwrap(listed.first, "no backups listed")
        XCTAssertEqual(backupOfA.snippetCount, 2, "listing must count snippets with the versioned decoder")
        XCTAssertEqual(backupOfA.kind, .save)

        let heard = expectation(description: "group listener hears the restored library")
        var registered = false
        let token = store.addGroupListener { groups in
            guard registered else { return }
            if groups.flatMap(\.snippets).map(\.triggerKeyword).sorted() == ["a", "aa"] { heard.fulfill() }
        }
        registered = true
        defer { store.removeListener(token: token) }

        let result = store.restoreLibrary(fromBackup: backupOfA.url)

        XCTAssertTrue(result.didRestore, "\(result.outcome)")
        wait(for: [heard], timeout: 2)
        XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword).sorted(), ["a", "aa"])
        XCTAssertEqual(try triggers(in: Data(contentsOf: file)), ["a", "aa"])
        let preRestore = try XCTUnwrap(result.preRestoreBackupURL)
        XCTAssertEqual(try Data(contentsOf: preRestore), bytesB, "the replaced library must be kept as pre-restore")
        XCTAssertEqual(store.backups.entry(for: preRestore)?.kind, .preRestore)
        // And it really is on disk: a fresh store reads the restored library.
        XCTAssertEqual(makeStore().loadSnippets().map(\.triggerKeyword).sorted(), ["a", "aa"])
    }

    func testRestoreOfATornBackupFailsClosed() throws {
        let store = makeStore()
        XCTAssertTrue(store.saveGroups(groups("live")).didSave)
        let full = try SnippetStore.exportLibraryData(groups: groups("old"))
        let torn = try store.backups.backUp(full.prefix(full.count / 2), kind: .save).url
        try assertRestoreRefused(torn, store: store)
        XCTAssertNil(store.libraryBackups().first { $0.url == torn }?.snippetCount,
                     "a torn backup must be listed as not restorable")
    }

    func testRestoreOfAForeignJSONFileFailsClosed() throws {
        let store = makeStore()
        XCTAssertTrue(store.saveGroups(groups("live")).didSave)
        let foreign = try store.backups.backUp(Data(#"{"name":"not a library","items":[1,2,3]}"#.utf8), kind: .save).url
        try assertRestoreRefused(foreign, store: store)
    }

    func testRestoreOfANewerSchemaFailsClosed() throws {
        let store = makeStore()
        XCTAssertTrue(store.saveGroups(groups("live")).didSave)
        let newer = try store.backups.backUp(Data(#"{"schemaVersion":99,"groups":[],"secrets":[]}"#.utf8), kind: .save).url
        try assertRestoreRefused(newer, store: store)
    }

    func testRestoreOfAFileOutsideTheBackupDirectoryFailsClosed() throws {
        let store = makeStore()
        XCTAssertTrue(store.saveGroups(groups("live")).didSave)
        let outside = root.appendingPathComponent("library-save-20261009T120000.000Z.bak.json")
        try SnippetStore.exportLibraryData(groups: groups("stranger")).write(to: outside)
        try assertRestoreRefused(outside, store: store)
    }

    private func assertRestoreRefused(_ url: URL, store: SnippetStore, line: UInt = #line) throws {
        let bytesBefore = try Data(contentsOf: file)
        let snippetsBefore = store.loadSnippets()
        let backupsBefore = backupFiles()
        var notified = false
        var registered = false
        let token = store.addGroupListener { _ in if registered { notified = true } }
        registered = true
        defer { store.removeListener(token: token) }

        let result = store.restoreLibrary(fromBackup: url)

        XCTAssertFalse(result.didRestore, line: line)
        guard case .failed = result.outcome else {
            return XCTFail("expected .failed, got \(result.outcome)", line: line)
        }
        XCTAssertNil(result.preRestoreBackupURL, line: line)
        XCTAssertEqual(try Data(contentsOf: file), bytesBefore, "the live file changed", line: line)
        XCTAssertEqual(store.loadSnippets(), snippetsBefore, "the live library changed", line: line)
        XCTAssertEqual(backupFiles(), backupsBefore, "a refused restore wrote a backup", line: line)
        XCTAssertFalse(notified, "a refused restore notified listeners", line: line)
    }
}
