import XCTest
@testable import ExpanderEngine

/// §1.9 — `sanitize` used to silently drop empty-trigger and duplicate-trigger snippets on every
/// save *and* every load, so duplicating a snippet and editing the body before the trigger lost
/// it. Sanitizing is now a no-op and the problem is *reported* instead.
///
/// The subtle case is `caseShadow`: the old de-dup key was case-**sensitive** while
/// `AbbreviationMatcher` de-dupes on `lowercased()`, so `:Hi` and `:hi` both survive to disk and
/// one of them is silently shadowed at match time.
final class TriggerConflictTests: XCTestCase {

    private func snippet(
        _ trigger: String,
        title: String = "S",
        caseSensitive: Bool = false
    ) -> SnippetModel {
        SnippetModel(
            title: title,
            triggerKeyword: trigger,
            replacementText: "x",
            isCaseSensitive: caseSensitive
        )
    }

    private func group(_ name: String, _ snippets: [SnippetModel]) -> SnippetGroup {
        SnippetGroup(name: name, snippets: snippets)
    }

    // MARK: - Clean libraries

    func testNoConflictsInACleanLibrary() {
        let groups = [group("General", [snippet(":a"), snippet(":b"), snippet(":c")])]
        XCTAssertTrue(SnippetStore.triggerConflicts(in: groups).isEmpty)
    }

    func testEmptyLibraryHasNoConflicts() {
        XCTAssertTrue(SnippetStore.triggerConflicts(in: []).isEmpty)
        XCTAssertTrue(SnippetStore.triggerConflicts(in: [group("General", [])]).isEmpty)
    }

    // MARK: - Empty triggers

    func testEmptyTriggersAreReportedOnceWithEverySnippetID() {
        let a = snippet("", title: "Draft A")
        let b = snippet("", title: "Draft B")
        let groups = [group("General", [a, snippet(":ok"), b])]

        let conflicts = SnippetStore.triggerConflicts(in: groups)
        let empties = conflicts.filter { $0.kind == .emptyTrigger }
        XCTAssertEqual(empties.count, 1)
        XCTAssertEqual(empties.first?.trigger, "")
        XCTAssertEqual(Set(empties.first?.snippetIDs ?? []), Set([a.id, b.id]))
    }

    // MARK: - Duplicates

    func testCaseInsensitiveDuplicatesAreReported() {
        let a = snippet(":dup", title: "First")
        let b = snippet(":dup", title: "Second")
        let conflicts = SnippetStore.triggerConflicts(in: [group("General", [a, b])])

        let dupes = conflicts.filter { $0.kind == .duplicateTrigger }
        XCTAssertEqual(dupes.count, 1)
        XCTAssertEqual(dupes.first?.trigger, ":dup")
        XCTAssertEqual(Set(dupes.first?.snippetIDs ?? []), Set([a.id, b.id]))
    }

    func testDuplicatesAreFoundAcrossGroups() {
        let a = snippet(":sig")
        let b = snippet(":sig")
        let conflicts = SnippetStore.triggerConflicts(in: [
            group("Work", [a]),
            group("Home", [b]),
        ])
        let dupes = conflicts.filter { $0.kind == .duplicateTrigger }
        XCTAssertEqual(dupes.count, 1)
        XCTAssertEqual(Set(dupes.first?.groupNames ?? []), Set(["Work", "Home"]))
    }

    func testTwoCaseSensitiveSnippetsWithTheSameSpellingAreDuplicates() {
        let a = snippet(":Hi", caseSensitive: true)
        let b = snippet(":Hi", caseSensitive: true)
        let conflicts = SnippetStore.triggerConflicts(in: [group("General", [a, b])])

        let dupes = conflicts.filter { $0.kind == .duplicateTrigger }
        XCTAssertEqual(dupes.count, 1)
        XCTAssertEqual(dupes.first?.trigger, ":Hi", "Case-sensitive duplicates report the exact spelling")
        XCTAssertTrue(conflicts.allSatisfy { $0.kind != .caseShadow })
    }

    func testDifferentSpellingsOfACaseSensitiveTriggerDoNotCollide() {
        // Two case-sensitive snippets that fold together but never actually match the same
        // typed text: the matcher keys them on their exact spellings, so nothing is shadowed.
        let conflicts = SnippetStore.triggerConflicts(in: [
            group("General", [
                snippet(":Hi", caseSensitive: true),
                snippet(":hi", caseSensitive: true),
            ])
        ])
        XCTAssertTrue(
            conflicts.isEmpty,
            "Distinct case-sensitive spellings are not a conflict, got \(conflicts)"
        )
    }

    // MARK: - Case shadowing (the §1.9 headline)

    func testCaseShadowWhenACaseSensitiveAndACaseInsensitiveTriggerFoldTogether() {
        // Both persist to disk — `sanitize` never removed either, because its de-dup key was
        // case-sensitive — but `AbbreviationMatcher` folds on `lowercased()`, so typing `:Hi`
        // can only ever fire one of them.
        let sensitive = snippet(":Hi", title: "Formal", caseSensitive: true)
        let insensitive = snippet(":hi", title: "Casual", caseSensitive: false)
        let conflicts = SnippetStore.triggerConflicts(in: [
            group("Work", [sensitive]),
            group("Home", [insensitive]),
        ])

        let shadows = conflicts.filter { $0.kind == .caseShadow }
        XCTAssertEqual(shadows.count, 1, "Expected exactly one case-shadow report, got \(conflicts)")
        XCTAssertEqual(shadows.first?.trigger, ":hi", "Case shadow is reported on the folded key")
        XCTAssertEqual(Set(shadows.first?.snippetIDs ?? []), Set([sensitive.id, insensitive.id]))
        XCTAssertEqual(Set(shadows.first?.groupNames ?? []), Set(["Work", "Home"]))
    }

    func testCaseShadowIsReportedEvenWhenSpellingsAreIdentical() {
        let sensitive = snippet(":hi", caseSensitive: true)
        let insensitive = snippet(":hi", caseSensitive: false)
        let conflicts = SnippetStore.triggerConflicts(in: [group("General", [sensitive, insensitive])])
        XCTAssertTrue(conflicts.contains { $0.kind == .caseShadow })
    }

    // MARK: - Output shape

    func testResultsAreDeterministicallyOrdered() {
        let groups = [
            group("General", [
                snippet(":zeta"), snippet(":zeta"),
                snippet(":alpha"), snippet(":alpha"),
                snippet(""),
            ])
        ]
        let first = SnippetStore.triggerConflicts(in: groups)
        let second = SnippetStore.triggerConflicts(in: groups)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.trigger), first.map(\.trigger).sorted())
    }

    /// The store-level wrapper reads the live library.
    func testStoreInstanceReportsConflictsFromDisk() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeConflicts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnippetStore(fileURL: dir.appendingPathComponent("snippets.json"))

        XCTAssertTrue(store.saveGroups([
            group("General", [snippet(":dup"), snippet(":dup"), snippet("")])
        ]).didSave)

        let conflicts = store.triggerConflicts()
        XCTAssertTrue(conflicts.contains { $0.kind == .duplicateTrigger && $0.trigger == ":dup" })
        XCTAssertTrue(conflicts.contains { $0.kind == .emptyTrigger })
    }
}
