import XCTest
@testable import ExpanderEngine

final class SnippetImportPlanTests: XCTestCase {
    private func makeTemporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeImportPlan-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeEspanso(
        _ matches: [(trigger: String, replacement: String)],
        named name: String,
        in directory: URL
    ) throws -> URL {
        let entries = matches.map { match in
            """
              - trigger: "\(match.trigger)"
                replace: "\(match.replacement)"
            """
        }.joined(separator: "\n")
        let source = directory.appendingPathComponent("\(name).yml")
        try "matches:\n\(entries)\n".write(to: source, atomically: true, encoding: .utf8)
        return source
    }

    private func makeStore(in directory: URL, name: String) -> SnippetStore {
        SnippetStore(fileURL: directory.appendingPathComponent("\(name)-snippets.json"))
    }

    func testCrossGroupDuplicateTriggerIsNewInPreviewAndMerge() throws {
        let directory = try makeTemporaryDirectory("cross-group")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try writeEspanso(
            [(trigger: ":same", replacement: "incoming")],
            named: "Imported",
            in: directory
        )
        let plan = try SnippetImporter.prepareImport(from: source)
        let importedGroupName = try XCTUnwrap(plan.groups.first?.name)
        let local = SnippetModel(title: "Local", triggerKeyword: ":same", replacementText: "keep")
        let existing = [SnippetGroup(name: "Local", snippets: [local])]

        let preview = SnippetStore.previewImport(plan, against: existing)
        XCTAssertEqual(plan.snippetCount, preview.items.count)
        XCTAssertEqual(preview.items.map(\.status), [.isNew])
        XCTAssertEqual(preview.newCount, 1)
        XCTAssertEqual(preview.updateCount, 0)
        XCTAssertEqual(preview.conflictCount, 0)

        let store = makeStore(in: directory, name: "cross-group")
        XCTAssertEqual(store.saveGroups(existing), .saved)
        let (_, summary) = store.commitImport(plan, mode: .merge)
        XCTAssertEqual(summary.outcome, .saved)
        XCTAssertEqual(summary.snippetsAdded, 1)
        XCTAssertEqual(store.loadGroups().count, 2)
        XCTAssertEqual(
            store.loadGroups().first(where: { $0.name == "Local" })?.snippets.first?.replacementText,
            "keep"
        )
        XCTAssertEqual(
            store.loadGroups().first(where: { $0.name == importedGroupName })?.snippets.first?.replacementText,
            "incoming"
        )
    }

    func testSameGroupPreviewUsesTheExactMergeCollisionRules() throws {
        let directory = try makeTemporaryDirectory("same-group")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try writeEspanso(
            [
                (trigger: ":same", replacement: "new exact"),
                (trigger: ":case", replacement: "new folded"),
                (trigger: ":new", replacement: "brand new")
            ],
            named: "General",
            in: directory
        )
        let plan = try SnippetImporter.prepareImport(from: source)
        let importedGroupName = try XCTUnwrap(plan.groups.first?.name)
        let exactID = UUID()
        let foldedID = UUID()
        let existing = [
            SnippetGroup(name: importedGroupName, snippets: [
                SnippetModel(id: exactID, title: "Exact", triggerKeyword: ":same", replacementText: "old exact"),
                SnippetModel(id: foldedID, title: "Folded", triggerKeyword: ":CASE", replacementText: "old folded")
            ])
        ]

        let preview = SnippetStore.previewImport(plan, against: existing)
        XCTAssertEqual(plan.snippetCount, preview.items.count)
        XCTAssertEqual(preview.items.map(\.status), [.isUpdate, .isConflict, .isNew])
        XCTAssertEqual(preview.newCount, 1)
        XCTAssertEqual(preview.updateCount, 1)
        XCTAssertEqual(preview.conflictCount, 1)

        let store = makeStore(in: directory, name: "same-group")
        XCTAssertEqual(store.saveGroups(existing), .saved)
        let (_, summary) = store.commitImport(plan, mode: .merge)
        XCTAssertEqual(summary.outcome, .saved)
        XCTAssertEqual(summary.snippetsAdded, 1)
        XCTAssertEqual(summary.snippetsUpdated, 2)

        let committed = try XCTUnwrap(store.loadGroups().first(where: { $0.name == importedGroupName }))
        XCTAssertEqual(committed.snippets.first(where: { $0.id == exactID })?.replacementText, "new exact")
        XCTAssertEqual(committed.snippets.first(where: { $0.id == foldedID })?.triggerKeyword, ":CASE")
        XCTAssertEqual(committed.snippets.first(where: { $0.id == foldedID })?.replacementText, "new folded")
        XCTAssertEqual(committed.snippets.first(where: { $0.triggerKeyword == ":new" })?.replacementText, "brand new")
    }

    func testPreparedPlanSurvivesSourceMutationAndRemovalWithoutReparsing() throws {
        let directory = try makeTemporaryDirectory("toctou")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory, name: "toctou")
        XCTAssertEqual(store.saveGroups([]), .saved)

        let mutableSource = try writeEspanso(
            [(trigger: ":original", replacement: "original body")],
            named: "Mutable",
            in: directory
        )
        let mutationPlan = try SnippetImporter.prepareImport(from: mutableSource)
        _ = try writeEspanso(
            [(trigger: ":changed", replacement: "changed body")],
            named: "Mutable",
            in: directory
        )

        let (_, mutationSummary) = store.commitImport(mutationPlan, mode: .merge)
        XCTAssertEqual(mutationSummary.outcome, .saved)
        XCTAssertNotNil(store.loadGroups().flatMap(\.snippets).first { $0.triggerKeyword == ":original" })
        XCTAssertNil(store.loadGroups().flatMap(\.snippets).first { $0.triggerKeyword == ":changed" })

        let removableSource = try writeEspanso(
            [(trigger: ":removed", replacement: "still committed")],
            named: "Removed",
            in: directory
        )
        let removalPlan = try SnippetImporter.prepareImport(from: removableSource)
        try FileManager.default.removeItem(at: removableSource)

        let (_, removalSummary) = store.commitImport(removalPlan, mode: .merge)
        XCTAssertEqual(removalSummary.outcome, .saved)
        XCTAssertEqual(
            store.loadGroups().flatMap(\.snippets).first { $0.triggerKeyword == ":removed" }?.replacementText,
            "still committed"
        )
    }

    func testSamePlanHasDistinctNonDestructiveMergeAndReplaceSemantics() throws {
        let directory = try makeTemporaryDirectory("modes")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeEspanso(
            [
                (trigger: ":same", replacement: "imported"),
                (trigger: ":new", replacement: "new")
            ],
            named: "General",
            in: directory
        )
        let plan = try SnippetImporter.prepareImport(from: source)
        let importedGroupName = try XCTUnwrap(plan.groups.first?.name)
        let localCollisionID = UUID()
        let baseline = [
            SnippetGroup(name: importedGroupName, snippets: [
                SnippetModel(title: "Local only", triggerKeyword: ":local", replacementText: "retain"),
                SnippetModel(
                    id: localCollisionID,
                    title: "Collision",
                    triggerKeyword: ":same",
                    replacementText: "old"
                )
            ])
        ]

        let mergeStore = makeStore(in: directory, name: "merge")
        let replaceStore = makeStore(in: directory, name: "replace")
        XCTAssertEqual(mergeStore.saveGroups(baseline), .saved)
        XCTAssertEqual(replaceStore.saveGroups(baseline), .saved)

        let (_, mergeSummary) = mergeStore.commitImport(plan, mode: .merge)
        let (_, replaceSummary) = replaceStore.commitImport(plan, mode: .replaceGroup)
        XCTAssertEqual(mergeSummary.outcome, .saved)
        XCTAssertEqual(replaceSummary.outcome, .saved)

        let merged = try XCTUnwrap(mergeStore.loadGroups().first(where: { $0.name == importedGroupName }))
        XCTAssertEqual(merged.snippets.count, 3)
        XCTAssertNotNil(merged.snippets.first { $0.triggerKeyword == ":local" })
        XCTAssertEqual(merged.snippets.first { $0.triggerKeyword == ":same" }?.id, localCollisionID)

        let replaced = try XCTUnwrap(replaceStore.loadGroups().first(where: { $0.name == importedGroupName }))
        XCTAssertEqual(Set(replaced.snippets.map(\.triggerKeyword)), [":same", ":new"])
        XCTAssertNil(replaced.snippets.first { $0.triggerKeyword == ":local" })
        XCTAssertNotEqual(replaced.snippets.first { $0.triggerKeyword == ":same" }?.id, localCollisionID)
    }

    func testCommitRebasesOntoEditsMadeAfterPreview() throws {
        let directory = try makeTemporaryDirectory("concurrent-edit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeEspanso(
            [(trigger: ":incoming", replacement: "imported")],
            named: "General",
            in: directory
        )
        let plan = try SnippetImporter.prepareImport(from: source)
        let groupName = try XCTUnwrap(plan.groups.first?.name)
        let store = makeStore(in: directory, name: "concurrent-edit")
        let baseline = SnippetModel(title: "Baseline", triggerKeyword: ":base", replacementText: "base")
        XCTAssertEqual(store.saveGroups([SnippetGroup(name: groupName, snippets: [baseline])]), .saved)

        let preview = store.previewImport(plan)
        XCTAssertEqual(preview.items.map(\.status), [.isNew])

        let concurrent = SnippetModel(
            title: "Created while confirming",
            triggerKeyword: ":concurrent",
            replacementText: "must survive"
        )
        XCTAssertEqual(
            store.saveGroups([SnippetGroup(name: groupName, snippets: [baseline, concurrent])]),
            .saved
        )

        let (_, summary) = store.commitImport(plan, mode: .merge)
        XCTAssertEqual(summary.outcome, .saved)
        let triggers = Set(store.loadGroups().flatMap(\.snippets).map(\.triggerKeyword))
        XCTAssertEqual(triggers, [":base", ":concurrent", ":incoming"])
    }

    func testEmptyAndInvalidSourcesCannotProduceACommitPlan() throws {
        let directory = try makeTemporaryDirectory("invalid")
        defer { try? FileManager.default.removeItem(at: directory) }

        let empty = directory.appendingPathComponent("empty.yml")
        try "matches: []\n".write(to: empty, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SnippetImporter.prepareImport(from: empty)) { error in
            guard case SnippetImporter.ImportError.noImportableSnippets = error else {
                return XCTFail("expected noImportableSnippets, got \(error)")
            }
        }

        let invalid = directory.appendingPathComponent("invalid.yml")
        try "matches: [\n".write(to: invalid, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SnippetImporter.prepareImport(from: invalid))
    }

    func testSaveRefusalDoesNotCommitThePreparedPlanOrMutateTheCache() throws {
        let directory = try makeTemporaryDirectory("save-refusal")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try writeEspanso(
            [(trigger: ":incoming", replacement: "must not land")],
            named: "General",
            in: directory
        )
        let plan = try SnippetImporter.prepareImport(from: source)
        let importedGroupName = try XCTUnwrap(plan.groups.first?.name)
        let baseline = [
            SnippetGroup(name: importedGroupName, snippets: [
                SnippetModel(title: "Protected", triggerKeyword: ":protected", replacementText: "keep")
            ])
        ]
        let storeURL = directory.appendingPathComponent("future-snippets.json")
        let futureDocument = SnippetDocument(
            schemaVersion: SnippetDocument.currentSchemaVersion + 1,
            groups: baseline
        )
        let originalBytes = try JSONEncoder().encode(futureDocument)
        try originalBytes.write(to: storeURL, options: .atomic)
        let store = SnippetStore(fileURL: storeURL)

        let (_, summary) = store.commitImport(plan, mode: .merge)

        XCTAssertEqual(summary.outcome, .blockedByNewerSchema)
        XCTAssertEqual(store.loadGroups(), baseline)
        XCTAssertEqual(try Data(contentsOf: storeURL), originalBytes)
        XCTAssertNil(store.loadGroups().flatMap(\.snippets).first { $0.triggerKeyword == ":incoming" })
    }

    func testThrowingConvenienceRefusesToReportParsedSuccessWhenCommitFails() throws {
        let directory = try makeTemporaryDirectory("throwing-save-refusal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeEspanso(
            [(trigger: ":incoming", replacement: "must not land")],
            named: "General",
            in: directory
        )
        let storeURL = directory.appendingPathComponent("future-snippets.json")
        let futureDocument = SnippetDocument(
            schemaVersion: SnippetDocument.currentSchemaVersion + 1,
            groups: []
        )
        try JSONEncoder().encode(futureDocument).write(to: storeURL, options: .atomic)
        let store = SnippetStore(fileURL: storeURL)

        XCTAssertThrowsError(try store.importSnippets(from: source)) { error in
            XCTAssertEqual(error as? SnippetImporter.ImportError, .libraryCommitFailed)
            XCTAssertFalse(error.localizedDescription.contains(source.path))
        }

        let (_, summary) = try store.importSnippets(from: source, mode: .merge)
        XCTAssertEqual(summary.outcome, .blockedByNewerSchema)
    }
}
