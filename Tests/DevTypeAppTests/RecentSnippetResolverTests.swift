import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

final class RecentSnippetResolverTests: XCTestCase {
    private func snippet(
        id: UUID = UUID(),
        title: String = "Title",
        body: String = "Body",
        enabled: Bool = true,
        secret: Bool = false
    ) -> SnippetModel {
        SnippetModel(
            id: id,
            title: title,
            triggerKeyword: ":trigger",
            replacementText: body,
            enabled: enabled,
            isSecret: secret
        )
    }

    func testResolvingARecentIDUsesTheCurrentLibraryValue() throws {
        let id = UUID()
        let recorded = snippet(id: id, title: "Old", body: "old body")
        let edited = snippet(id: id, title: "New", body: "new body")
        let ids = RecentSnippetResolver.record(recorded, in: [])

        let resolved = try XCTUnwrap(RecentSnippetResolver.resolve(id, in: [edited]))

        XCTAssertEqual(ids, [id])
        XCTAssertEqual(resolved.title, "New")
        XCTAssertEqual(resolved.replacementText, "new body")
    }

    func testDeletedDisabledAndSecretSnippetsCannotResolve() {
        let id = UUID()

        XCTAssertNil(RecentSnippetResolver.resolve(id, in: []))
        XCTAssertNil(RecentSnippetResolver.resolve(id, in: [snippet(id: id, enabled: false)]))
        XCTAssertNil(RecentSnippetResolver.resolve(id, in: [snippet(id: id, secret: true)]))
    }

    func testReconcileDropsIneligibleMissingAndDuplicateIDsWithoutReordering() {
        let first = snippet()
        let second = snippet()
        let disabled = snippet(enabled: false)
        let secret = snippet(secret: true)
        let missing = UUID()

        let result = RecentSnippetResolver.reconcile(
            [second.id, disabled.id, second.id, missing, secret.id, first.id],
            with: [first, second, disabled, secret]
        )

        XCTAssertEqual(result, [second.id, first.id])
    }

    func testRecordingIsMostRecentFirstDeduplicatedBoundedAndRejectsIneligibleItems() {
        let snippets = (0..<8).map { snippet(title: "Snippet \($0)") }
        var ids: [UUID] = []
        for item in snippets {
            ids = RecentSnippetResolver.record(item, in: ids)
        }

        XCTAssertEqual(ids, snippets.suffix(6).reversed().map(\.id))

        ids = RecentSnippetResolver.record(snippets[4], in: ids)
        XCTAssertEqual(ids.first, snippets[4].id)
        XCTAssertEqual(Set(ids).count, ids.count)

        let unchanged = ids
        ids = RecentSnippetResolver.record(snippet(enabled: false), in: ids)
        ids = RecentSnippetResolver.record(snippet(secret: true), in: ids)
        XCTAssertEqual(ids, unchanged)
    }

    func testGroupDisabledProjectionMakesAFormerRecentEntryIneligible() {
        let item = snippet()
        let projected = SnippetStore.expandableSnippets(
            in: [SnippetGroup(name: "Off", enabled: false, snippets: [item])]
        )

        XCTAssertNil(RecentSnippetResolver.resolve(item.id, in: projected))
        XCTAssertEqual(RecentSnippetResolver.reconcile([item.id], with: projected), [])
    }
}
