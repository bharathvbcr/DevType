import AppKit
import XCTest
@testable import ExpanderEngine

final class SnippetImportStagingBoundsTests: XCTestCase {
    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-import-staging-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pngData() throws -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        return try XCTUnwrap(bitmap?.representation(using: .png, properties: [:]))
    }

    private func writeImageImport(
        in source: URL,
        trigger: String?,
        imageName: String = "image.png",
        yamlName: String = "base.yml"
    ) throws -> URL {
        try pngData().write(to: source.appendingPathComponent(imageName))
        let triggerLine = trigger.map { "  - trigger: \"\($0)\"\n" } ?? "  -\n"
        let yaml = "matches:\n\(triggerLine)    image_path: \"\(imageName)\"\n"
        let url = source.appendingPathComponent(yamlName)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func storedImageNames(in store: ImageAttachmentStore) throws -> [String] {
        guard FileManager.default.fileExists(atPath: store.imagesDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: store.imagesDirectory.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private func limits(
        files: Int = 32,
        bytes: Int = 1_000_000,
        snippets: Int = 32
    ) -> SnippetImporter.ResourceLimits {
        .init(maxFileCount: files, maxAggregateBytes: bytes, maxSnippetCount: snippets)
    }

    func testImageWithoutAUsableTriggerNeverMutatesThePersistentAttachmentStore() throws {
        let root = try makeDirectory("no-trigger")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try writeImageImport(in: source, trigger: nil)
        let imageStore = ImageAttachmentStore(directory: imageDirectory)

        XCTAssertThrowsError(try SnippetImporter.prepareImport(from: source, imageStore: imageStore)) {
            guard case SnippetImporter.ImportError.noImportableSnippets = $0 else {
                return XCTFail("Expected noImportableSnippets, got \($0)")
            }
        }
        XCTAssertEqual(try storedImageNames(in: imageStore), [])
    }

    func testPreparedImagePlanIsMutationFreeWhenPreviewIsCancelled() throws {
        let root = try makeDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try writeImageImport(in: source, trigger: ":image")
        let imageStore = ImageAttachmentStore(directory: imageDirectory)

        do {
            let plan = try SnippetImporter.prepareImport(from: source, imageStore: imageStore)
            XCTAssertEqual(plan.imageCount, 1)
            XCTAssertEqual(try storedImageNames(in: imageStore), [])
            // Dropping this value models cancelling the confirmation sheet.
            _ = plan
        }

        XCTAssertEqual(try storedImageNames(in: imageStore), [])
    }

    func testRefusedLibraryCommitRollsBackEveryPromotedImage() throws {
        let root = try makeDirectory("rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try writeImageImport(in: source, trigger: ":image")
        let imageStore = ImageAttachmentStore(directory: imageDirectory)
        let plan = try SnippetImporter.prepareImport(from: source, imageStore: imageStore)
        XCTAssertEqual(try storedImageNames(in: imageStore), [])

        let storeURL = root.appendingPathComponent("future-library.json")
        let future = SnippetDocument(
            schemaVersion: SnippetDocument.currentSchemaVersion + 1,
            groups: []
        )
        try JSONEncoder().encode(future).write(to: storeURL, options: .atomic)
        let store = SnippetStore(fileURL: storeURL)

        let (_, summary) = store.commitImport(plan, mode: .merge)

        XCTAssertEqual(summary.outcome, .blockedByNewerSchema)
        XCTAssertEqual(try storedImageNames(in: imageStore), [])
    }

    func testSuccessfulCommitPromotesThePreparedImageAndRewritesItsReference() throws {
        let root = try makeDirectory("success")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try writeImageImport(in: source, trigger: ":image")
        let imageStore = ImageAttachmentStore(directory: imageDirectory)
        let plan = try SnippetImporter.prepareImport(from: source, imageStore: imageStore)
        let store = SnippetStore(fileURL: root.appendingPathComponent("library.json"))

        let (_, summary) = store.commitImport(plan, mode: .merge)

        XCTAssertEqual(summary.outcome, .saved)
        let snippet = try XCTUnwrap(
            store.loadGroups().flatMap(\.snippets).first { $0.triggerKeyword == ":image" }
        )
        XCTAssertFalse(snippet.imagePath.isEmpty)
        XCTAssertFalse(snippet.imagePath.hasPrefix("devtype-import-stage:"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageStore.url(forImagePath: snippet.imagePath).path))
        XCTAssertEqual(try storedImageNames(in: imageStore).count, 1)
    }

    func testSkipConflictsRemovesOnlyTheUncommittedPromotedImage() throws {
        let root = try makeDirectory("skip-conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let yaml = try writeImageImport(in: source, trigger: ":same", yamlName: "Imported.yml")
        let imageStore = ImageAttachmentStore(directory: imageDirectory)
        let plan = try SnippetImporter.prepareImport(from: yaml, imageStore: imageStore)
        let groupName = try XCTUnwrap(plan.groups.first?.name)
        let baseline = SnippetModel(title: "Local", triggerKeyword: ":same", replacementText: "keep")
        let store = SnippetStore(fileURL: root.appendingPathComponent("library.json"))
        XCTAssertEqual(store.saveGroups([SnippetGroup(name: groupName, snippets: [baseline])]), .saved)

        let (_, summary) = store.commitImport(plan, mode: .skipConflicts)

        XCTAssertEqual(summary.outcome, .saved)
        XCTAssertEqual(summary.snippetsAdded, 0)
        XCTAssertEqual(try storedImageNames(in: imageStore), [])
        let committed = try XCTUnwrap(store.loadGroups().flatMap(\.snippets).first)
        XCTAssertEqual(committed.replacementText, "keep")
        XCTAssertTrue(committed.imagePath.isEmpty)
    }

    func testPartialAttachmentPromotionFailureRollsBackEarlierFilesAndDoesNotWriteLibrary() throws {
        let originalCap = ImageAttachmentStore.maxImportedImageBytes
        defer { ImageAttachmentStore.maxImportedImageBytes = originalCap }

        let root = try makeDirectory("partial-promotion")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let small = try pngData()
        let large = small + Data(repeating: 0xA5, count: 2_048)
        try small.write(to: source.appendingPathComponent("small.png"))
        try large.write(to: source.appendingPathComponent("large.png"))
        try """
        matches:
          - trigger: :small
            image_path: small.png
          - trigger: :large
            image_path: large.png
        """.write(to: source.appendingPathComponent("base.yml"), atomically: true, encoding: .utf8)

        let imageStore = ImageAttachmentStore(directory: imageDirectory)
        let plan = try SnippetImporter.prepareImport(from: source, imageStore: imageStore)
        ImageAttachmentStore.maxImportedImageBytes = small.count + 16
        let store = SnippetStore(fileURL: root.appendingPathComponent("library.json"))

        let (_, summary) = store.commitImport(plan, mode: .merge)

        XCTAssertEqual(summary.outcome, .failed("attachmentCommitFailed"))
        XCTAssertEqual(try storedImageNames(in: imageStore), [])
        let triggers = Set(store.loadGroups().flatMap(\.snippets).map(\.triggerKeyword))
        XCTAssertFalse(triggers.contains(":small"))
        XCTAssertFalse(triggers.contains(":large"))
    }

    func testRollbackDeletionFailureReportsOnlyAggregateCounts() throws {
        let root = try makeDirectory("rollback-delete-refusal")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try writeImageImport(in: source, trigger: ":image")
        var deletionAttempts = 0
        let imageStore = ImageAttachmentStore(directory: imageDirectory) { _ in
            deletionAttempts += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        let plan = try SnippetImporter.prepareImport(from: source, imageStore: imageStore)
        let materialized = try plan.materializeAttachments()

        let cleanup = materialized.rollbackAll()

        XCTAssertEqual(deletionAttempts, 1)
        XCTAssertEqual(cleanup, .init(attempted: 1, removed: 0, failed: 1))
        XCTAssertEqual(cleanup.diagnosticLabel, "attempted=1 removed=0 failed=1")
        XCTAssertFalse(cleanup.diagnosticLabel.contains(root.path))
        XCTAssertEqual(try storedImageNames(in: imageStore).count, 1)
    }

    func testRefusedLibraryOutcomeSurvivesRollbackDeletionFailure() throws {
        let root = try makeDirectory("rollback-outcome")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try writeImageImport(in: source, trigger: ":image")
        var deletionAttempts = 0
        let imageStore = ImageAttachmentStore(directory: imageDirectory) { _ in
            deletionAttempts += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        let plan = try SnippetImporter.prepareImport(from: source, imageStore: imageStore)
        let storeURL = root.appendingPathComponent("future-library.json")
        let future = SnippetDocument(
            schemaVersion: SnippetDocument.currentSchemaVersion + 1,
            groups: []
        )
        try JSONEncoder().encode(future).write(to: storeURL, options: .atomic)

        let (_, summary) = SnippetStore(fileURL: storeURL).commitImport(plan, mode: .merge)

        XCTAssertEqual(summary.outcome, .blockedByNewerSchema)
        XCTAssertEqual(deletionAttempts, 1)
        XCTAssertEqual(try storedImageNames(in: imageStore).count, 1)
    }

    func testSkipConflictOutcomeSurvivesCleanupDeletionFailure() throws {
        let root = try makeDirectory("skip-cleanup-refusal")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let yaml = try writeImageImport(in: source, trigger: ":same", yamlName: "Imported.yml")
        var deletionAttempts = 0
        let imageStore = ImageAttachmentStore(directory: imageDirectory) { _ in
            deletionAttempts += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        let plan = try SnippetImporter.prepareImport(from: yaml, imageStore: imageStore)
        let groupName = try XCTUnwrap(plan.groups.first?.name)
        let baseline = SnippetModel(title: "Local", triggerKeyword: ":same", replacementText: "keep")
        let store = SnippetStore(fileURL: root.appendingPathComponent("library.json"))
        XCTAssertEqual(store.saveGroups([SnippetGroup(name: groupName, snippets: [baseline])]), .saved)

        let (_, summary) = store.commitImport(plan, mode: .skipConflicts)

        XCTAssertEqual(summary.outcome, .saved)
        XCTAssertEqual(summary.snippetsAdded, 0)
        XCTAssertEqual(deletionAttempts, 1)
        XCTAssertEqual(try storedImageNames(in: imageStore).count, 1)
    }

    func testEspansoDirectoryWalkRefusesFileCountOverflowWithoutPartialImages() throws {
        let root = try makeDirectory("file-overflow")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try writeImageImport(in: source, trigger: ":image")
        try "ignored".write(to: source.appendingPathComponent("extra-one.txt"), atomically: true, encoding: .utf8)
        try "ignored".write(to: source.appendingPathComponent("extra-two.txt"), atomically: true, encoding: .utf8)
        let imageStore = ImageAttachmentStore(directory: imageDirectory)

        XCTAssertThrowsError(
            try SnippetImporter.prepareImport(
                from: source,
                imageStore: imageStore,
                limits: limits(files: 2)
            )
        ) {
            XCTAssertEqual($0 as? SnippetImporter.ImportError, .resourceLimitExceeded(.fileCount))
        }
        XCTAssertEqual(try storedImageNames(in: imageStore), [])
    }

    func testFileCountTreatsSymlinkAliasesAsSeparateWalkEntries() throws {
        let root = try makeDirectory("symlink-file-overflow")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "matches:\n  - trigger: :one\n    replace: one\n"
            .write(to: source.appendingPathComponent("base.yml"), atomically: true, encoding: .utf8)
        let shared = source.appendingPathComponent("shared.txt")
        try "ignored".write(to: shared, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("alias-one.txt"),
            withDestinationURL: shared
        )
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("alias-two.txt"),
            withDestinationURL: shared
        )

        XCTAssertThrowsError(
            try SnippetImporter.prepareImport(from: source, limits: limits(files: 2))
        ) {
            XCTAssertEqual($0 as? SnippetImporter.ImportError, .resourceLimitExceeded(.fileCount))
        }
    }

    func testAggregateBudgetChargesDistinctSymlinkAliasesIndependently() throws {
        let root = try makeDirectory("symlink-byte-overflow")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("base.yml")
        try Data(repeating: 0x41, count: 8).write(to: original)
        let alias = root.appendingPathComponent("alias.yml")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: original
        )
        let budget = SnippetImporter.ResourceBudget(
            limits: limits(files: 8, bytes: 12)
        )

        try budget.consumeBytes(8, from: original)
        XCTAssertThrowsError(try budget.consumeBytes(8, from: alias)) {
            XCTAssertEqual($0 as? SnippetImporter.ImportError, .resourceLimitExceeded(.aggregateBytes))
        }
    }

    func testAggregateByteOverflowRefusesTheWholeImport() throws {
        let root = try makeDirectory("byte-overflow")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("base.yml")
        try "matches:\n  - trigger: :one\n    replace: payload\n"
            .write(to: source, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try SnippetImporter.prepareImport(from: source, limits: limits(bytes: 16))
        ) {
            XCTAssertEqual($0 as? SnippetImporter.ImportError, .resourceLimitExceeded(.aggregateBytes))
        }
    }

    func testAggregateByteOverflowAcrossIndividuallyValidImagesLeavesNoPersistentFiles() throws {
        let root = try makeDirectory("image-byte-overflow")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let image = try pngData()
        try image.write(to: source.appendingPathComponent("one.png"))
        try image.write(to: source.appendingPathComponent("two.png"))
        let yaml = """
        matches:
          - trigger: :one
            image_path: one.png
          - trigger: :two
            image_path: two.png
        """
        let yamlURL = source.appendingPathComponent("base.yml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        let yamlBytes = try Data(contentsOf: yamlURL).count
        let imageStore = ImageAttachmentStore(directory: imageDirectory)

        XCTAssertThrowsError(
            try SnippetImporter.prepareImport(
                from: source,
                imageStore: imageStore,
                limits: limits(bytes: yamlBytes + image.count + max(1, image.count / 2))
            )
        ) {
            XCTAssertEqual($0 as? SnippetImporter.ImportError, .resourceLimitExceeded(.aggregateBytes))
        }
        XCTAssertEqual(try storedImageNames(in: imageStore), [])
    }

    func testSnippetCountOverflowRefusesTheWholeEspansoImport() throws {
        let root = try makeDirectory("snippet-overflow")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("base.yml")
        try """
        matches:
          - trigger: :one
            replace: one
          - trigger: :two
            replace: two
        """.write(to: source, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try SnippetImporter.prepareImport(from: source, limits: limits(snippets: 1))
        ) {
            XCTAssertEqual($0 as? SnippetImporter.ImportError, .resourceLimitExceeded(.snippetCount))
        }
    }

    func testTextExpanderFileAndSnippetBoundsAreEnforcedBeforeAPlanExists() throws {
        let root = try makeDirectory("te-overflow")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Settings.textexpandersettings", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        func groupData(abbreviation: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: [
                "uuidString": UUID().uuidString,
                "name": "Imported",
                "snippetPlists": [[
                    "abbreviation": abbreviation,
                    "plainText": "payload",
                    "snippetType": 0,
                    "abbreviationMode": 0
                ]]
            ], format: .xml, options: 0)
        }

        try groupData(abbreviation: ";one").write(to: source.appendingPathComponent("group_1.xml"))
        try groupData(abbreviation: ";two").write(to: source.appendingPathComponent("group_2.xml"))

        XCTAssertThrowsError(
            try SnippetImporter.prepareImport(from: source, limits: limits(files: 1))
        ) {
            XCTAssertEqual($0 as? SnippetImporter.ImportError, .resourceLimitExceeded(.fileCount))
        }
        XCTAssertThrowsError(
            try SnippetImporter.prepareImport(from: source, limits: limits(snippets: 1))
        ) {
            XCTAssertEqual($0 as? SnippetImporter.ImportError, .resourceLimitExceeded(.snippetCount))
        }
    }
}
