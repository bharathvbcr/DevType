import Foundation
import XCTest
@testable import ExpanderEngine

final class TriggerConflictResolutionTests: XCTestCase {
    private func snippet(
        _ trigger: String,
        id: UUID = UUID(),
        title: String = "Snippet",
        enabled: Bool = true,
        caseSensitive: Bool = false
    ) -> SnippetModel {
        SnippetModel(
            id: id,
            title: title,
            triggerKeyword: trigger,
            replacementText: title,
            isCaseSensitive: caseSensitive,
            enabled: enabled
        )
    }

    private func temporaryStore() -> (SnippetStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevType-ConflictResolution-\(UUID().uuidString)")
        return (SnippetStore(fileURL: directory.appendingPathComponent("snippets.json")), directory)
    }

    func testDisabledSnippetsCannotCreateAnyKindOfMatcherConflict() {
        let disabledEmpty = snippet("", title: "Empty", enabled: false)
        let enabledDuplicate = snippet(":dup", title: "Live")
        let disabledDuplicate = snippet(":dup", title: "Off", enabled: false)
        let enabledSensitive = snippet(":Case", title: "Sensitive", caseSensitive: true)
        let disabledInsensitive = snippet(":case", title: "Insensitive", enabled: false)

        let conflicts = SnippetStore.triggerConflicts(in: [SnippetGroup(name: "G", snippets: [
            disabledEmpty, enabledDuplicate, disabledDuplicate, enabledSensitive, disabledInsensitive,
        ])])

        XCTAssertTrue(conflicts.isEmpty, "Disabled snippets never reach AbbreviationMatcher and cannot conflict.")
    }

    func testDisabledGroupsCannotCreateMatcherConflicts() {
        let groups = [
            SnippetGroup(name: "Live", snippets: [snippet(":same", title: "Live")]),
            SnippetGroup(name: "Off", enabled: false, snippets: [snippet(":same", title: "Off")]),
        ]

        XCTAssertTrue(SnippetStore.triggerConflicts(in: groups).isEmpty)
    }

    func testDisableResolutionPersistsAgainstLatestLibraryAndPreservesConcurrentEdits() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = snippet(":same", title: "Target")
        let peer = snippet(":same", title: "Peer")
        let initial = [SnippetGroup(name: "G", snippets: [target, peer])]
        XCTAssertEqual(store.saveGroups(initial), .saved)

        // Simulates an edit that lands after the resolver rendered its snapshot.
        let late = snippet(":late", title: "Added Elsewhere")
        var latest = store.loadGroups()
        latest[0].snippets.append(late)
        XCTAssertEqual(store.saveGroups(latest), .saved)

        XCTAssertEqual(
            store.resolveTriggerConflict(snippetID: target.id, action: .disable),
            .persisted
        )
        let saved = store.loadGroups().flatMap(\.snippets)
        XCTAssertEqual(saved.first(where: { $0.id == target.id })?.enabled, false)
        XCTAssertEqual(saved.first(where: { $0.id == peer.id }), peer)
        XCTAssertEqual(saved.first(where: { $0.id == late.id }), late)
        XCTAssertTrue(store.triggerConflicts().isEmpty, "Disabling either duplicate must actually resolve it.")
    }

    func testDeleteResolutionRemovesOnlyTheExactUUIDAndPreservesEverythingElse() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = snippet(":same", title: "Target")
        let peer = snippet(":same", title: "Peer")
        let sameHashIsNotAnIdentity = snippet(":other", title: "Unrelated")
        let groups = [SnippetGroup(name: "G", snippets: [target, peer, sameHashIsNotAnIdentity])]
        XCTAssertEqual(store.saveGroups(groups), .saved)

        XCTAssertEqual(
            store.resolveTriggerConflict(snippetID: target.id, action: .delete),
            .persisted
        )
        XCTAssertEqual(store.loadGroups().flatMap(\.snippets), [peer, sameHashIsNotAnIdentity])
    }

    func testRenderedTargetDisambiguatesDuplicateUUIDsWithoutDeletingTheFirstOccurrence() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let duplicateID = UUID()
        let first = snippet(":same", id: duplicateID, title: "First")
        let second = snippet(":same", id: duplicateID, title: "Second")
        let group = SnippetGroup(name: "G", snippets: [first, second])
        XCTAssertEqual(store.saveGroups([group]), .saved)

        let target = SnippetStore.TriggerConflictTarget(
            groupID: group.id,
            snippet: second,
            occurrence: 1
        )
        XCTAssertEqual(
            store.resolveTriggerConflict(target: target, action: .delete),
            .persisted
        )

        XCTAssertEqual(store.loadGroups().flatMap(\.snippets), [first])
    }

    func testRenderedTargetRejectsAnEditedOrAmbiguousDuplicateWithoutWriting() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("snippets.json")
        let duplicateID = UUID()
        let rendered = snippet(":same", id: duplicateID, title: "Rendered")
        let peer = snippet(":same", id: duplicateID, title: "Peer")
        let group = SnippetGroup(name: "G", snippets: [rendered, peer])
        XCTAssertEqual(store.saveGroups([group]), .saved)
        let target = SnippetStore.TriggerConflictTarget(
            groupID: group.id,
            snippet: rendered,
            occurrence: 0
        )

        var edited = store.loadGroups()
        edited[0].snippets[0].replacementText = "changed after the row rendered"
        XCTAssertEqual(store.saveGroups(edited), .saved)
        let beforeStaleAction = try Data(contentsOf: fileURL)
        XCTAssertEqual(
            store.resolveTriggerConflict(target: target, action: .delete),
            .targetUnavailable
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), beforeStaleAction)

        let identical = snippet(":identical", id: UUID(), title: "Same")
        let identicalGroup = SnippetGroup(name: "I", snippets: [identical, identical])
        XCTAssertEqual(store.saveGroups([identicalGroup]), .saved)
        let ambiguousTarget = SnippetStore.TriggerConflictTarget(
            groupID: identicalGroup.id,
            snippet: identical,
            occurrence: 0
        )
        let beforeAmbiguousAction = try Data(contentsOf: fileURL)
        XCTAssertEqual(
            store.resolveTriggerConflict(target: ambiguousTarget, action: .disable),
            .targetUnavailable
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), beforeAmbiguousAction)
    }

    func testUUIDOnlyResolutionRejectsMalformedDuplicateIdentity() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("snippets.json")
        let duplicateID = UUID()
        let first = snippet(":same", id: duplicateID, title: "First")
        let second = snippet(":same", id: duplicateID, title: "Second")
        XCTAssertEqual(
            store.saveGroups([SnippetGroup(name: "G", snippets: [first, second])]),
            .saved
        )
        let before = try Data(contentsOf: fileURL)

        XCTAssertEqual(
            store.resolveTriggerConflict(snippetID: duplicateID, action: .delete),
            .targetUnavailable
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testMissingTargetDoesNotWriteOrReportSuccess() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("snippets.json")
        XCTAssertEqual(
            store.saveGroups([SnippetGroup(name: "G", snippets: [snippet(":one")])]),
            .saved
        )
        let before = try Data(contentsOf: fileURL)

        XCTAssertEqual(
            store.resolveTriggerConflict(snippetID: UUID(), action: .delete),
            .targetUnavailable
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testRemoteChangeRefusalIsReturnedAndExternalBytesAreNotOverwritten() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("snippets.json")
        let target = snippet(":same", title: "Target")
        let peer = snippet(":same", title: "Peer")
        XCTAssertEqual(
            store.saveGroups([SnippetGroup(name: "Local", snippets: [target, peer])]),
            .saved
        )

        let external = [SnippetGroup(name: "External", snippets: [snippet(":external")])]
        let externalBytes = try SnippetStore.exportLibraryData(groups: external)
        try externalBytes.write(to: fileURL, options: .atomic)

        XCTAssertEqual(
            store.resolveTriggerConflict(snippetID: target.id, action: .disable),
            .refused(.blockedByRemoteChange)
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), externalBytes)
    }
}
