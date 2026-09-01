import XCTest
@testable import ExpanderEngine

/// Library relocation — "keep my snippets in iCloud/Dropbox".
///
/// `saveSnippetsAs`, `linkToSnippets` and `stopSyncing` were written, persisted their choice
/// under `DeviceStateKey.storeLocationPath`, and were read back by `resolveLocation` on every
/// launch — but nothing ever called them and nothing ever tested them. These tests
/// characterise the path before it is put behind a button, because it moves the user's
/// entire library and a mistake here is not recoverable from the UI.
///
/// Every store here is fully isolated: a temp library file, a temp `localSupportDirectory`
/// (so backups and the `stopSyncing` destination never touch the real Application Support),
/// a private `UserDefaults` suite, and no watcher.
final class StoreRelocationTests: XCTestCase {

    private var root: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devtype-relocation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaultsSuite = "devtype.relocation.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func dir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A store whose every writable path lands inside `root`.
    private func makeStore(named name: String, seeded: [SnippetModel] = []) throws -> SnippetStore {
        let home = try dir(name)
        let store = SnippetStore(
            location: .init(fileURL: home.appendingPathComponent("snippets.json"),
                            expectsExistingLibrary: false),
            deviceDefaults: defaults,
            localSupportDirectory: home,
            watcherFactory: { _ in nil }
        )
        if !seeded.isEmpty {
            _ = store.saveGroups([SnippetGroup(name: "Test", snippets: seeded)])
        }
        return store
    }

    private func snippet(_ trigger: String) -> SnippetModel {
        SnippetModel(title: trigger, triggerKeyword: trigger, replacementText: "body-\(trigger)")
    }

    private func triggers(at url: URL) throws -> [String] {
        try SnippetStore.decodeSnippets(from: Data(contentsOf: url))
            .map(\.triggerKeyword)
            .sorted()
    }

    // MARK: - Save As

    func testSaveSnippetsAsWritesLibraryToTheNewDirectoryAndActivatesIt() throws {
        let store = try makeStore(named: "origin", seeded: [snippet("aaa"), snippet("bbb")])
        let target = try dir("iCloud")

        let result = store.saveSnippetsAs(toDirectory: target)

        XCTAssertTrue(result.success, "relocation failed: \(result.message ?? "no message")")
        let written = target.appendingPathComponent(SnippetStore.syncedFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertEqual(try triggers(at: written), ["aaa", "bbb"])
        XCTAssertEqual(result.activeLocation, written,
                       "the store must now be reading from the new location")
    }

    /// The whole point of the feature: the choice has to outlive the process.
    func testSaveSnippetsAsPersistsSoAFreshStoreResolvesToTheNewLocation() throws {
        let store = try makeStore(named: "origin", seeded: [snippet("aaa")])
        let target = try dir("iCloud")

        XCTAssertTrue(store.saveSnippetsAs(toDirectory: target).success)

        let resolved = SnippetStore.resolveLocation(defaults: defaults)
        XCTAssertEqual(resolved.fileURL, target.appendingPathComponent(SnippetStore.syncedFileName))
        XCTAssertTrue(resolved.expectsExistingLibrary,
                      "a user-chosen location must not be seeded with demo snippets when empty")
    }

    /// Overwriting a library that is already there must leave a copy behind first.
    func testSaveSnippetsAsBacksUpAnExistingLibraryAtTheTarget() throws {
        let store = try makeStore(named: "origin", seeded: [snippet("new")])
        let target = try dir("iCloud")
        let existing = target.appendingPathComponent(SnippetStore.syncedFileName)
        try SnippetStore.exportLibraryData(groups: [SnippetGroup(name: "Old", snippets: [snippet("old")])])
            .write(to: existing)

        let result = store.saveSnippetsAs(toDirectory: target)

        XCTAssertTrue(result.success)
        let backup = try XCTUnwrap(result.backupURL, "existing library was overwritten with no backup")
        XCTAssertEqual(try triggers(at: backup), ["old"])
        XCTAssertEqual(try triggers(at: existing), ["new"])
    }

    // MARK: - Link

    func testLinkToSnippetsAdoptsAnExistingLibraryInsteadOfOverwritingIt() throws {
        let store = try makeStore(named: "origin", seeded: [snippet("local")])
        let shared = try dir("shared")
        let sharedFile = shared.appendingPathComponent(SnippetStore.syncedFileName)
        try SnippetStore.exportLibraryData(
            groups: [SnippetGroup(name: "Shared", snippets: [snippet("remote")])]
        ).write(to: sharedFile)

        let result = store.linkToSnippets(at: sharedFile)

        XCTAssertTrue(result.success, "link failed: \(result.message ?? "no message")")
        XCTAssertEqual(store.loadGroups().flatMap(\.snippets).map(\.triggerKeyword), ["remote"],
                       "linking must adopt the target library, not push the local one over it")
        XCTAssertEqual(try triggers(at: sharedFile), ["remote"])
    }

    /// Linking discards the local library from view, so it must be recoverable.
    func testLinkToSnippetsBacksUpTheLocalLibraryFirst() throws {
        let store = try makeStore(named: "origin", seeded: [snippet("local")])
        let shared = try dir("shared")
        let sharedFile = shared.appendingPathComponent(SnippetStore.syncedFileName)
        try SnippetStore.exportLibraryData(
            groups: [SnippetGroup(name: "Shared", snippets: [snippet("remote")])]
        ).write(to: sharedFile)

        let result = store.linkToSnippets(at: sharedFile)

        let backup = try XCTUnwrap(result.backupURL, "local library vanished with no backup")
        XCTAssertEqual(try triggers(at: backup), ["local"])
    }

    // MARK: - Stop syncing

    func testStopSyncingCopiesTheLibraryBackToLocalAndClearsThePersistedPath() throws {
        let store = try makeStore(named: "origin", seeded: [snippet("aaa")])
        let target = try dir("iCloud")
        XCTAssertTrue(store.saveSnippetsAs(toDirectory: target).success)
        XCTAssertNotNil(defaults.string(forKey: SnippetStore.DeviceStateKey.storeLocationPath))

        let result = store.stopSyncing()

        XCTAssertTrue(result.success, "stopSyncing failed: \(result.message ?? "no message")")
        XCTAssertNil(defaults.string(forKey: SnippetStore.DeviceStateKey.storeLocationPath),
                     "the synced path must be cleared or the next launch goes straight back to it")
        XCTAssertEqual(store.loadGroups().flatMap(\.snippets).map(\.triggerKeyword), ["aaa"],
                       "the library must survive the trip back to local")
        XCTAssertEqual(try triggers(at: result.activeLocation), ["aaa"])
    }

    // MARK: - Failure

    /// A relocation that cannot write must fail loudly and leave the store where it was,
    /// rather than pointing at a location that holds nothing.
    func testSaveSnippetsAsFailsClosedWhenTheTargetCannotBeWritten() throws {
        let store = try makeStore(named: "origin", seeded: [snippet("aaa")])
        let before = store.loadGroups().flatMap(\.snippets).map(\.triggerKeyword)

        // A regular file where the directory should go: createDirectory must fail.
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocked)

        let result = store.saveSnippetsAs(toDirectory: blocked)

        XCTAssertFalse(result.success, "writing into a file-as-directory reported success")
        XCTAssertNotNil(result.message)
        XCTAssertEqual(store.loadGroups().flatMap(\.snippets).map(\.triggerKeyword), before,
                       "a failed relocation must not disturb the library it was moving")
    }
}
