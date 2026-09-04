import AppKit
import Foundation
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

final class ConflictResolverStateTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func snippet(
        _ trigger: String,
        title: String,
        caseSensitive: Bool = false,
        id: UUID = UUID()
    ) -> SnippetModel {
        SnippetModel(
            id: id,
            title: title,
            triggerKeyword: trigger,
            replacementText: "Replacement for \(title)",
            isCaseSensitive: caseSensitive
        )
    }

    func testSnapshotProjectsEveryConflictingSnippetAndItsGroupFromOneLibraryValue() {
        let snippets = (1...5).map { snippet(":same", title: "Snippet \($0)") }
        let groups = [
            SnippetGroup(name: "One", snippets: Array(snippets[0...1])),
            SnippetGroup(name: "Two", snippets: Array(snippets[2...4])),
        ]

        let snapshot = ConflictResolverSnapshot(groups: groups, detectionEnabled: true)

        XCTAssertEqual(snapshot.conflictCount, 1)
        XCTAssertEqual(snapshot.affectedSnippetCount, 5)
        XCTAssertEqual(snapshot.rows.first?.items.map(\.snippet.id), snippets.map(\.id))
        XCTAssertEqual(snapshot.rows.first?.items.map(\.groupName), ["One", "One", "Two", "Two", "Two"])
        XCTAssertEqual(snapshot.rows.first?.affectedSnippetCount, 5)
    }

    func testSnapshotDoesNotClaimConflictFreeWhenDetectionIsDisabled() {
        let snippets = [snippet(":same", title: "A"), snippet(":same", title: "B")]
        let snapshot = ConflictResolverSnapshot(
            groups: [SnippetGroup(name: "G", snippets: snippets)],
            detectionEnabled: false
        )

        XCTAssertFalse(snapshot.detectionEnabled)
        XCTAssertTrue(snapshot.rows.isEmpty)
        XCTAssertEqual(snapshot.emptyState, .detectionDisabled)
    }

    func testSnapshotRetainsDistinctOccurrenceTargetsForDuplicateUUIDs() throws {
        let duplicateID = UUID()
        let first = snippet(":same", title: "First", id: duplicateID)
        let second = snippet(":same", title: "Second", id: duplicateID)
        let group = SnippetGroup(name: "G", snippets: [first, second])

        let snapshot = ConflictResolverSnapshot(groups: [group], detectionEnabled: true)
        let row = try XCTUnwrap(snapshot.rows.first { $0.conflict.kind == .duplicateTrigger })

        XCTAssertEqual(snapshot.affectedSnippetCount, 2)
        XCTAssertEqual(row.items.map(\.target.occurrence), [0, 1])
        XCTAssertEqual(row.items.map(\.target.groupID), [group.id, group.id])
    }

    func testWinnerProjectionMatchesEachConflictKindInsteadOfBlindlyChoosingFirst() throws {
        let insensitive = snippet(":Hi", title: "Insensitive", caseSensitive: false)
        let sensitive = snippet(":Hi", title: "Sensitive", caseSensitive: true)
        let empty = snippet("", title: "Draft")
        let short = snippet("`go", title: "Short")
        let long = snippet("`going", title: "Long")
        let duplicateA = snippet(":dup", title: "First")
        let duplicateB = snippet(":dup", title: "Second")
        let snapshot = ConflictResolverSnapshot(
            groups: [SnippetGroup(name: "G", snippets: [
                insensitive, sensitive, empty, short, long, duplicateA, duplicateB,
            ])],
            detectionEnabled: true
        )

        let emptyRow = try XCTUnwrap(snapshot.rows.first { $0.conflict.kind == .emptyTrigger })
        XCTAssertEqual(emptyRow.items.map(\.isWinner), [false])

        let caseRow = try XCTUnwrap(snapshot.rows.first { $0.conflict.kind == .caseShadow })
        XCTAssertEqual(caseRow.items.map(\.snippet.id), [insensitive.id, sensitive.id])
        XCTAssertEqual(caseRow.items.map(\.isWinner), [false, true])

        let prefixRow = try XCTUnwrap(snapshot.rows.first { $0.conflict.kind == .prefixShadow })
        XCTAssertEqual(prefixRow.items.map(\.snippet.id), [short.id, long.id])
        XCTAssertEqual(prefixRow.items.map(\.isWinner), [true, false])

        let duplicateRow = try XCTUnwrap(snapshot.rows.first {
            $0.conflict.kind == .duplicateTrigger && $0.conflict.trigger == ":dup"
        })
        XCTAssertEqual(duplicateRow.items.map(\.snippet.id), [duplicateA.id, duplicateB.id])
        XCTAssertEqual(duplicateRow.items.map(\.isWinner), [true, false])
    }

    func testDynamicRowHeightGrowsForEveryRenderedSnippetAndIsBoundedForEmptyInput() {
        let empty = ConflictResolverLayout.rowHeight(snippetCount: 0)
        let one = ConflictResolverLayout.rowHeight(snippetCount: 1)
        let five = ConflictResolverLayout.rowHeight(snippetCount: 5)
        let fifty = ConflictResolverLayout.rowHeight(snippetCount: 50)

        XCTAssertEqual(empty, ConflictResolverLayout.emptyRowHeight)
        XCTAssertGreaterThan(one, empty)
        XCTAssertEqual(
            five - one,
            4 * (ConflictResolverLayout.snippetRowHeight + ConflictResolverLayout.snippetSpacing)
        )
        XCTAssertGreaterThanOrEqual(
            one,
            ConflictResolverLayout.headerRowHeight + ConflictResolverLayout.snippetRowHeight
        )
        XCTAssertGreaterThan(fifty, five)
        XCTAssertTrue(fifty.isFinite)
    }

    func testConflictResolverCopyExistsInEveryLanguage() {
        let required = [
            "conflict.resolver.summary.other",
            "conflict.resolver.affected.other",
            "conflict.resolver.disabled",
            "conflict.resolver.noTrigger",
            "conflict.resolver.group",
            "conflict.resolver.stale.title",
            "conflict.resolver.stale.message",
            "conflict.resolver.ax.table",
            "conflict.resolver.ax.disable",
            "conflict.resolver.ax.delete",
        ]

        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for key in required {
                XCTAssertNotNil(table[key], "\(language.rawValue) is missing \(key)")
            }
        }
        let english = LocalizationManager.stringTable(for: .en)
        XCTAssertNotNil(english["conflict.resolver.summary.one"])
        XCTAssertNotNil(english["conflict.resolver.affected.one"])
    }

    func testActionTargetForwardsTheCompleteOccurrenceIdentityWithoutNarrowing() {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let groupID = UUID()
        let snippet = snippet(":same", title: "Second", id: id)
        let conflictTarget = SnippetStore.TriggerConflictTarget(
            groupID: groupID,
            snippet: snippet,
            occurrence: 1
        )
        var received: SnippetStore.TriggerConflictTarget?
        let target = ConflictSnippetActionTarget(target: conflictTarget) { received = $0 }

        target.invoke(NSButton())

        XCTAssertEqual(target.conflictTarget, conflictTarget)
        XCTAssertEqual(received, conflictTarget)
    }

    func testControllerSourceUsesExactActionIdentityConfirmationAndDynamicCompleteRows() throws {
        let sourceURL = Self.repositoryRoot
            .appendingPathComponent("Sources/DevTypeAppCore/SnippetConflictResolverSheet.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("prefix(3)"), "The resolver must render the complete conflict.")
        XCTAssertFalse(source.contains(".id.hashValue"), "A hash is not a unique action identity.")
        XCTAssertFalse(source.contains("sender.tag"), "Button tags must not decode snippet identity.")
        XCTAssertFalse(source.contains(".tag ="), "Button tags must not encode snippet identity.")
        XCTAssertTrue(source.contains("ConflictSnippetActionTarget(target:"))
        XCTAssertTrue(source.contains("DevTypeAlert.confirm("))
        XCTAssertTrue(source.contains("destructive: true"))
        XCTAssertTrue(source.contains("heightOfRow row:"))
        XCTAssertTrue(source.contains("case .refused(let outcome):"))
        XCTAssertTrue(source.contains("case .failed(let reason):"))
    }
}
