import XCTest
import SourceTreeTestSupport
@testable import ExpanderEngine

/// Every path that replaces a library file the user did not just write keeps a copy first, and
/// refuses to replace it when no copy could be kept.
///
/// "Replace with Defaults" on an unreadable library, Save As onto a folder that already holds a
/// library (another Mac's, typically), and Stop Syncing onto the local file each used to write
/// straight through: the first with no backup step at all, the other two with a backup that was
/// skipped when the old file could not be read and ignored when it could not be written.
///
/// Backups are blocked the way they fail in practice — the backup directory cannot be created —
/// by putting a regular file where `<support>/Backups` should be. Nothing is mocked.
final class LibrarySafetyBackupTests: XCTestCase {

    private var root: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devtype-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaultsSuite = "devtype.safety.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
        makeEverythingWritable(under: root)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func dir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func snippet(_ trigger: String) -> SnippetModel {
        SnippetModel(title: trigger, triggerKeyword: trigger, replacementText: "body-\(trigger)")
    }

    private func libraryBytes(_ trigger: String) throws -> Data {
        try SnippetStore.exportLibraryData(groups: [SnippetGroup(name: "G", snippets: [snippet(trigger)])])
    }

    private func makeStore(file: URL, support: URL) -> SnippetStore {
        SnippetStore(
            location: .init(fileURL: file, expectsExistingLibrary: false),
            deviceDefaults: defaults,
            localSupportDirectory: support,
            watcherFactory: { _ in nil }
        )
    }

    private func backupsDirectory(_ support: URL) -> URL {
        support.appendingPathComponent("Backups", isDirectory: true)
    }

    private func backupFiles(_ support: URL) -> [URL] {
        let directory = backupsDirectory(support)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().map { directory.appendingPathComponent($0) }
    }

    /// The backup directory cannot be created: a regular file holds its name.
    private func blockBackups(_ support: URL) throws {
        let directory = backupsDirectory(support)
        try? FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
    }

    /// `chmod 000`, skipping when the process can read it anyway (running as root).
    private func makeUnreadable(_ url: URL) throws {
        try FilePermissions.setPOSIX(url, 0)
        if FileManager.default.isReadableFile(atPath: url.path) {
            throw XCTSkip("this process can read a mode-000 file; cannot model an unreadable library")
        }
    }

    private func bytes(of url: URL) throws -> Data {
        try FilePermissions.setPOSIX(url, 0o600)
        return try Data(contentsOf: url)
    }

    private func makeEverythingWritable(under url: URL) {
        guard let walker = FileManager.default.enumerator(atPath: url.path) else { return }
        try? FilePermissions.setPOSIX(url, 0o700)
        for case let relative as String in walker {
            try? FilePermissions.setPOSIX(url.appendingPathComponent(relative), 0o700)
        }
    }

    private var defaultGroups: [SnippetGroup] {
        [SnippetGroup(name: SnippetDocument.defaultGroupName, snippets: [snippet(":default")])]
    }

    // MARK: - forceOverwriteLibrary

    func testForceOverwriteOfAnUnreadableLibraryLeavesATimestampedRawByteBackup() throws {
        let support = try dir("support")
        let file = support.appendingPathComponent("snippets.json")
        let original = try libraryBytes("mine")
        try original.write(to: file)
        try makeUnreadable(file)

        let store = makeStore(file: file, support: support)
        XCTAssertTrue(store.isLibraryReadFailed)
        guard case .unreadable? = store.lastLoadIssue else {
            return XCTFail("expected an unreadable load issue, got \(String(describing: store.lastLoadIssue))")
        }

        XCTAssertTrue(store.forceOverwriteLibrary(with: defaultGroups).didSave)

        let backups = backupFiles(support)
        XCTAssertEqual(backups.count, 1, "the unreadable library was overwritten with no backup: \(backups)")
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try bytes(of: backup), original, "the backup must be the original bytes, not a re-encoding")
        XCTAssertNotNil(LibraryBackupStore.parse(backup.lastPathComponent), "backup name is not timestamped: \(backup.lastPathComponent)")
        XCTAssertEqual(try SnippetStore.decodeSnippets(from: Data(contentsOf: file)).map(\.triggerKeyword), [":default"])
    }

    func testForceOverwriteRefusesWhenTheBackupCannotBeWritten() throws {
        let support = try dir("support")
        let file = support.appendingPathComponent("snippets.json")
        let original = Data("{not-json".utf8)
        try original.write(to: file)
        let store = makeStore(file: file, support: support)
        XCTAssertTrue(store.isLibraryReadFailed)
        try blockBackups(support)

        let outcome = store.forceOverwriteLibrary(with: defaultGroups)

        XCTAssertFalse(outcome.didSave, "the library was replaced although no backup could be written")
        guard case .failed = outcome.outcome else { return XCTFail("expected .failed, got \(outcome.outcome)") }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(store.isLibraryReadFailed, "a refused overwrite must leave saves latched off")
    }

    func testForceOverwriteOfAnUnreadableLibraryRefusesWhenTheBackupCannotBeWritten() throws {
        let support = try dir("support")
        let file = support.appendingPathComponent("snippets.json")
        let original = try libraryBytes("mine")
        try original.write(to: file)
        try makeUnreadable(file)
        let store = makeStore(file: file, support: support)
        try blockBackups(support)

        XCTAssertFalse(store.forceOverwriteLibrary(with: defaultGroups).didSave)
        XCTAssertEqual(try bytes(of: file), original)
    }

    /// A zero-byte file has nothing worth keeping, but the replacement still has to be a new
    /// readable library. `Data.write(.atomic)` updates a mode-000 inode in place when it is the
    /// only link, so the bytes land and the file stays unreadable.
    func testForceOverwriteOfAnUnreadableZeroByteFilePublishesAReadableLibrary() throws {
        let support = try dir("support")
        let file = support.appendingPathComponent("snippets.json")
        try Data().write(to: file)
        try makeUnreadable(file)
        let store = makeStore(file: file, support: support)
        XCTAssertTrue(store.isLibraryReadFailed, "a mode-000 file must latch the read failure")

        XCTAssertTrue(store.forceOverwriteLibrary(with: defaultGroups).didSave)

        XCTAssertTrue(
            FileManager.default.isReadableFile(atPath: file.path),
            "the overwrite wrote the new library into the mode-000 inode, so a relaunch cannot read it"
        )
        let reloaded = makeStore(file: file, support: support)
        XCTAssertFalse(reloaded.isLibraryReadFailed, "relaunch still treats the overwritten library as unreadable")
        XCTAssertEqual(reloaded.loadSnippets().map(\.triggerKeyword), [":default"])
    }

    // MARK: - Save As

    func testSaveSnippetsAsOntoANonEmptyLibraryRefusesWhenTheBackupCannotBeWritten() throws {
        let support = try dir("support")
        let store = makeStore(file: support.appendingPathComponent("snippets.json"), support: support)
        XCTAssertTrue(store.saveGroups([SnippetGroup(name: "G", snippets: [snippet("new")])]).didSave)
        let target = try dir("iCloud")
        let existing = target.appendingPathComponent(SnippetStore.syncedFileName)
        let theirs = try libraryBytes("theirs")
        try theirs.write(to: existing)
        try blockBackups(support)

        let result = store.saveSnippetsAs(toDirectory: target)

        XCTAssertFalse(result.success, "another library was replaced although no backup could be written")
        XCTAssertNotNil(result.message)
        XCTAssertEqual(try Data(contentsOf: existing), theirs)
        XCTAssertEqual(store.activeLocationURL, support.appendingPathComponent("snippets.json"))
        XCTAssertNil(defaults.string(forKey: SnippetStore.DeviceStateKey.storeLocationPath))
    }

    func testSaveSnippetsAsOntoAnUnreadableLibraryRefusesWhenTheBackupCannotBeWritten() throws {
        let support = try dir("support")
        let store = makeStore(file: support.appendingPathComponent("snippets.json"), support: support)
        XCTAssertTrue(store.saveGroups([SnippetGroup(name: "G", snippets: [snippet("new")])]).didSave)
        let target = try dir("iCloud")
        let existing = target.appendingPathComponent(SnippetStore.syncedFileName)
        let theirs = try libraryBytes("theirs")
        try theirs.write(to: existing)
        try makeUnreadable(existing)
        try blockBackups(support)

        let result = store.saveSnippetsAs(toDirectory: target)

        XCTAssertFalse(result.success, "an unreadable library was replaced with no backup")
        XCTAssertEqual(try bytes(of: existing), theirs)
    }

    func testSaveSnippetsAsOntoAnUnreadableLibraryPreservesItsBytes() throws {
        let support = try dir("support")
        let store = makeStore(file: support.appendingPathComponent("snippets.json"), support: support)
        XCTAssertTrue(store.saveGroups([SnippetGroup(name: "G", snippets: [snippet("new")])]).didSave)
        let target = try dir("iCloud")
        let existing = target.appendingPathComponent(SnippetStore.syncedFileName)
        let theirs = try libraryBytes("theirs")
        try theirs.write(to: existing)
        try makeUnreadable(existing)

        let result = store.saveSnippetsAs(toDirectory: target)

        XCTAssertTrue(result.success, result.message ?? "")
        let backup = try XCTUnwrap(result.backupURL, "an unreadable library was replaced with no backup")
        XCTAssertEqual(try bytes(of: backup), theirs)
        XCTAssertEqual(try SnippetStore.decodeSnippets(from: Data(contentsOf: existing)).map(\.triggerKeyword), ["new"])
    }

    // MARK: - Stop Syncing

    func testStopSyncingOntoANonEmptyLocalLibraryRefusesWhenTheBackupCannotBeWritten() throws {
        let support = try dir("support")
        let local = support.appendingPathComponent("snippets.json")
        let store = makeStore(file: local, support: support)
        XCTAssertTrue(store.saveGroups([SnippetGroup(name: "G", snippets: [snippet("synced")])]).didSave)
        XCTAssertTrue(store.saveSnippetsAs(toDirectory: try dir("iCloud")).success)
        // Edited while synced, so Stop Syncing has something different to write over the local file.
        XCTAssertTrue(store.saveGroups([SnippetGroup(name: "G", snippets: [snippet("edited")])]).didSave)
        let localBefore = try Data(contentsOf: local)
        try blockBackups(support)

        let result = store.stopSyncing()

        XCTAssertFalse(result.success, "the local library was replaced although no backup could be written")
        XCTAssertNotNil(result.message)
        XCTAssertEqual(try Data(contentsOf: local), localBefore)
        XCTAssertNotNil(defaults.string(forKey: SnippetStore.DeviceStateKey.storeLocationPath),
                        "a refused Stop Syncing must leave the synced location in force")
    }

    func testStopSyncingOntoAnUnreadableLocalLibraryRefusesWhenTheBackupCannotBeWritten() throws {
        let support = try dir("support")
        let local = support.appendingPathComponent("snippets.json")
        let store = makeStore(file: local, support: support)
        XCTAssertTrue(store.saveGroups([SnippetGroup(name: "G", snippets: [snippet("synced")])]).didSave)
        XCTAssertTrue(store.saveSnippetsAs(toDirectory: try dir("iCloud")).success)
        let localBefore = try Data(contentsOf: local)
        try makeUnreadable(local)
        try blockBackups(support)

        let result = store.stopSyncing()

        XCTAssertFalse(result.success, "an unreadable local library was replaced with no backup")
        XCTAssertEqual(try bytes(of: local), localBefore)
    }

    // MARK: - Link

    func testLinkToSnippetsReportsAMissingLocalBackupInsteadOfProceedingSilently() throws {
        let support = try dir("support")
        let store = makeStore(file: support.appendingPathComponent("snippets.json"), support: support)
        XCTAssertTrue(store.saveGroups([SnippetGroup(name: "G", snippets: [snippet("local")])]).didSave)
        let sharedFile = try dir("shared").appendingPathComponent(SnippetStore.syncedFileName)
        try libraryBytes("remote").write(to: sharedFile)
        try blockBackups(support)

        let result = store.linkToSnippets(at: sharedFile)

        XCTAssertNil(result.backupURL)
        XCTAssertNotNil(result.message, "linking proceeded with no local backup and said nothing")
        XCTAssertTrue(result.success, "the local file is not replaced by a link, so linking may proceed")
        XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword), ["remote"])
    }
}

/// The shape the safety guarantees depend on, which no single behavioural test can pin: every
/// whole-library write in `SnippetStore` goes through the one coordinated replace that owns the
/// backup step, and the forced write cannot be requested without it.
final class LibraryWritePathContractTests: XCTestCase {
    private func storeSource() throws -> String {
        return try SourceTree.text("Sources/ExpanderEngine/Models/SnippetStore.swift")
    }

    func testEveryLibraryWriteGoesThroughTheCoordinatedReplace() throws {
        let source = try storeSource()
        XCTAssertEqual(
            source.components(separatedBy: "data.write(to: actualURL, options: .atomic)").count - 1, 1,
            "the coordinated replace must be the only place the library file is written"
        )
        XCTAssertFalse(source.contains("raw.write(to:"), "a hand-rolled relocation write bypasses the backup step")
        XCTAssertFalse(source.contains("copyItem("), "backups belong to LibraryBackupStore")
        XCTAssertFalse(source.contains(".moveItem("), "moving the live library aside drops it if the process dies before the overwrite")
        XCTAssertTrue(source.contains("[Store] No local backup before linking"),
                      "linkToSnippets must log a missing local backup")
        XCTAssertTrue(source.contains("[Store] Could not encode the library for relocation"),
                      "a relocation encode failure must be logged")
        let backupSource = try SourceTree.text("Sources/ExpanderEngine/Models/LibraryBackupStore.swift")
        XCTAssertTrue(backupSource.contains("[Backup] Could not write library backup"),
                      "a backup write failure must be logged")
        XCTAssertTrue(backupSource.contains("[Backup] Could not preserve the library before replacing it"))
        XCTAssertFalse(backupSource.contains(".moveItem("), "preserve must not rename the live library aside")
        // The order is checked inside the replace's own body, so it holds wherever the family's
        // extension files place it relative to the rest of the store.
        let replace = try SourceTree.functionBody("func coordinatedReplace(", in: source)
        let write = try XCTUnwrap(replace.range(of: "data.write(to: actualURL, options: .atomic)"))
        let backupStep = try XCTUnwrap(replace.range(of: "self.backups.preserve(fileAt: actualURL"))
        XCTAssertTrue(backupStep.lowerBound < write.lowerBound,
                      "the backup step must precede the write inside the coordinated replace")
    }

    func testTheForcedWriteRequiresABackupWhoeverCallsIt() throws {
        let source = try storeSource()
        XCTAssertTrue(source.contains("backup: force || safetyKind != nil ? .required(safetyKind ?? .preOverwrite) : .rolling"),
                      "force must imply a required safety copy inside writeGroupsToDisk itself")
        XCTAssertEqual(
            source.components(separatedBy: "bypassHardFailure: true)").count - 1, 1,
            "only forceOverwriteLibrary may bypass the read-failure latch directly"
        )
        XCTAssertEqual(
            source.components(separatedBy: "bypassLatch: latched").count - 1, 1,
            "restoreLibrary is the only other latch bypass, and it always requires a pre-restore copy"
        )
        XCTAssertTrue(source.contains("safetyKind: .preRestore,\n            bypassLatch: latched"))
        let force = try XCTUnwrap(source.range(of: "public func forceOverwriteLibrary("))
        let call = try XCTUnwrap(source.range(of: "writeGroupsToDisk(sanitized, force: true, bypassHardFailure: true)"))
        XCTAssertLessThan(force.lowerBound, call.lowerBound)
    }
}
