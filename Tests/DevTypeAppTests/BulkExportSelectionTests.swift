import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// The bulk bar's "Export…" button.
///
/// The handler `bulkExportSelected` existed since the bulk bar was built, and all three
/// string tables already carried `manager.bulk.export` — but no `#selector` ever referenced
/// it, so the button was never constructed and the action could not fire. Wiring it up
/// exposed a second problem: the handler called `LibraryExporter.present(from:)`, which
/// reads `store.loadGroups()` and writes the *whole* library. Under a label reading
/// "3 selected" that silently exports all 400 snippets.
///
/// `restrict(_:to:)` is the narrowing that makes the button mean what it says. The save
/// panel itself is not exercised here — `present` needs an `NSSavePanel` and a window.
final class BulkExportSelectionTests: XCTestCase {

    private func snippet(_ trigger: String) -> SnippetModel {
        SnippetModel(title: trigger, triggerKeyword: trigger, replacementText: "body-\(trigger)")
    }

    private func group(_ name: String, _ snippets: [SnippetModel]) -> SnippetGroup {
        SnippetGroup(name: name, snippets: snippets)
    }

    /// The regression: a selection must not drag the rest of the library into the file.
    func testRestrictKeepsOnlySelectedSnippets() {
        let keep = snippet("aaa")
        let drop = snippet("bbb")
        let alsoKeep = snippet("ccc")
        let groups = [group("One", [keep, drop]), group("Two", [alsoKeep])]

        let result = LibraryExporter.restrict(groups, to: [keep.id, alsoKeep.id])

        let exported = result.flatMap(\.snippets).map(\.triggerKeyword).sorted()
        XCTAssertEqual(exported, ["aaa", "ccc"],
                       "Export must contain exactly the selected snippets, not the whole library.")
    }

    /// A group with nothing selected should not appear as an empty shell — Espanso and CSV
    /// re-import both treat an empty group as a real (useless) group.
    func testRestrictDropsGroupsWithNothingSelected() {
        let keep = snippet("aaa")
        let groups = [group("One", [keep]), group("Untouched", [snippet("bbb"), snippet("ccc")])]

        let result = LibraryExporter.restrict(groups, to: [keep.id])

        XCTAssertEqual(result.map(\.name), ["One"])
    }

    /// Surviving groups keep their identity so a round-trip re-import lands snippets back
    /// in the right group rather than in a flattened default.
    func testRestrictPreservesGroupMetadata() {
        let keep = snippet("aaa")
        let source = SnippetGroup(
            name: "Shell Commands",
            symbol: "terminal.fill",
            colorHex: "#F24A3D",
            snippets: [keep, snippet("bbb")]
        )

        let result = LibraryExporter.restrict([source], to: [keep.id])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, source.id)
        XCTAssertEqual(result.first?.name, "Shell Commands")
        XCTAssertEqual(result.first?.symbol, "terminal.fill")
        XCTAssertEqual(result.first?.colorHex, "#F24A3D")
    }

    /// `nil` is the menu-bar / utility-bar path, which still exports everything.
    func testNilRestrictionExportsWholeLibrary() {
        let groups = [group("One", [snippet("aaa"), snippet("bbb")]), group("Two", [snippet("ccc")])]

        let result = LibraryExporter.restrict(groups, to: nil)

        XCTAssertEqual(result.flatMap(\.snippets).count, 3)
        XCTAssertEqual(result.map(\.name), ["One", "Two"])
    }

    /// The subset JSON path goes through the same envelope as a full export, so a
    /// selection export re-imports exactly like a library export does.
    func testSubsetJSONRoundTripsThroughTheLibraryEnvelope() throws {
        let keep = snippet("aaa")
        let groups = LibraryExporter.restrict(
            [group("One", [keep, snippet("bbb")])],
            to: [keep.id]
        )

        let data = try SnippetStore.exportLibraryData(groups: groups)
        let decoded = try SnippetStore.decodeSnippets(from: data)

        XCTAssertEqual(decoded.map(\.triggerKeyword), ["aaa"])
    }
}

/// The Espanso *folder* export — one match file per group.
///
/// `SnippetExporter.espansoYAMLFiles(from:)` could already produce this layout but nothing
/// called it, so the exporter only ever offered a single concatenated document. Espanso
/// itself reads a `match/` directory, which is also what users keep in version control.
final class EspansoDirectoryExportTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devtype-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func snippet(_ trigger: String) -> SnippetModel {
        SnippetModel(title: trigger, triggerKeyword: trigger, replacementText: "body-\(trigger)")
    }

    func testWritesOneFilePerGroup() throws {
        let target = root.appendingPathComponent("match")
        try LibraryExporter.writeEspansoDirectory(
            groups: [
                SnippetGroup(name: "Shell", snippets: [snippet("aaa")]),
                SnippetGroup(name: "Email", snippets: [snippet("bbb"), snippet("ccc")]),
            ],
            to: target
        )

        let written = try FileManager.default
            .contentsOfDirectory(atPath: target.path)
            .sorted()
        XCTAssertEqual(written.count, 2, "one file per group, got \(written)")
        let joined = try written
            .map { try String(contentsOf: target.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        XCTAssertTrue(joined.contains("aaa"))
        XCTAssertTrue(joined.contains("bbb"))
        XCTAssertTrue(joined.contains("ccc"))
    }

    /// The staging directory must not survive a successful export.
    func testLeavesNoStagingDirectoryBehind() throws {
        try LibraryExporter.writeEspansoDirectory(
            groups: [SnippetGroup(name: "Shell", snippets: [snippet("aaa")])],
            to: root.appendingPathComponent("match")
        )

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".devtype-export-") }
        XCTAssertTrue(leftovers.isEmpty, "staging directory leaked: \(leftovers)")
    }

    /// Re-exporting over an existing folder replaces it rather than merging into it, so a
    /// group deleted since the last export does not linger as a stale match file.
    func testReexportReplacesRatherThanMerges() throws {
        let target = root.appendingPathComponent("match")
        try LibraryExporter.writeEspansoDirectory(
            groups: [
                SnippetGroup(name: "Shell", snippets: [snippet("aaa")]),
                SnippetGroup(name: "Retired", snippets: [snippet("bbb")]),
            ],
            to: target
        )
        try LibraryExporter.writeEspansoDirectory(
            groups: [SnippetGroup(name: "Shell", snippets: [snippet("aaa")])],
            to: target
        )

        let written = try FileManager.default.contentsOfDirectory(atPath: target.path)
        XCTAssertEqual(written.count, 1, "stale group file survived re-export: \(written)")
    }

    /// A selection export and a folder export compose: the folder holds only the selection.
    func testComposesWithSelectionRestriction() throws {
        let keep = snippet("aaa")
        let target = root.appendingPathComponent("match")
        let groups = LibraryExporter.restrict(
            [SnippetGroup(name: "Shell", snippets: [keep, snippet("bbb")])],
            to: [keep.id]
        )

        try LibraryExporter.writeEspansoDirectory(groups: groups, to: target)

        let files = try FileManager.default.contentsOfDirectory(atPath: target.path)
        let contents = try String(
            contentsOf: target.appendingPathComponent(files[0]),
            encoding: .utf8
        )
        XCTAssertTrue(contents.contains("aaa"))
        XCTAssertFalse(contents.contains("bbb"), "unselected snippet leaked into the export")
    }
}
