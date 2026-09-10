import XCTest
@testable import ExpanderEngine

final class ConflictAdoptionRegressionTests: XCTestCase {
    func testRemoteResolutionMustActuallyDecodeAndAdoptTheSelectedCandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "devtype.conflict.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = root.appendingPathComponent("snippets.json")
        let store = SnippetStore(location: .init(fileURL: file, expectsExistingLibrary: false),
                                 deviceDefaults: defaults, localSupportDirectory: root)
        let good = [SnippetGroup(name: "Preserve", snippets: [SnippetModel(
            title: "local", triggerKeyword: ";local", replacementText: "keep me"
        )])]
        XCTAssertTrue(store.saveGroups(good).didSave)
        for invalid in [Data("not json".utf8), Data(), Data("{\"schemaVersion\":999,\"groups\":[]}".utf8)] {
            try invalid.write(to: file, options: .atomic)
            XCTAssertFalse(store.resolveConflictsKeepingRemote())
            XCTAssertEqual(store.loadGroups(), good)
            XCTAssertEqual(try Data(contentsOf: file), invalid)
        }
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(store.resolveConflictsKeepingRemote())
        XCTAssertEqual(store.loadGroups(), good)
    }

    func testFreshStoreLoadsVerifiedLocalRemoteAndEmptyAdoption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("snippets.json")
        let store = SnippetStore(location: .init(fileURL: file, expectsExistingLibrary: false), localSupportDirectory: root)
        let groups = [SnippetGroup(name: "Local", snippets: [SnippetModel(title: "local", triggerKeyword: ";local", replacementText: "chosen")])]
        XCTAssertTrue(store.saveGroups(groups).didSave)
        try Data("invalid current file".utf8).write(to: file, options: .atomic)
        XCTAssertTrue(store.resolveConflicts(keeping: .local).didAdopt)
        let fresh = SnippetStore(location: .init(fileURL: file, expectsExistingLibrary: true), localSupportDirectory: root)
        XCTAssertEqual(fresh.loadGroups(), groups)
        try JSONEncoder().encode(SnippetDocument(groups: [])).write(to: file, options: .atomic)
        XCTAssertTrue(store.resolveConflicts(keeping: .remote).didAdopt)
        XCTAssertEqual(store.loadGroups(), [])
        XCTAssertEqual(SnippetStore(location: .init(fileURL: file, expectsExistingLibrary: true), localSupportDirectory: root).loadGroups(), [])
    }

    /// Registration snapshots immediately; resolve then notifies again on main after the
    /// mutation lock is released. That is the live conflict-observer path — not a leftover
    /// synchronous setter.
    func testResolveConflictsNotifiesConflictListenersOnMain() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("snippets.json")
        let store = SnippetStore(
            location: .init(fileURL: file, expectsExistingLibrary: false),
            localSupportDirectory: root
        )
        let notified = expectation(description: "conflict listener after resolve")
        var snapshots = 0
        _ = store.addConflictListener { _ in
            snapshots += 1
            if snapshots == 2 {
                XCTAssertTrue(Thread.isMainThread)
                notified.fulfill()
            }
        }
        XCTAssertEqual(snapshots, 1, "addConflictListener must snapshot the current conflicts immediately")
        _ = store.resolveConflicts(keeping: .local)
        wait(for: [notified], timeout: 2)
        XCTAssertEqual(snapshots, 2)
    }

}
