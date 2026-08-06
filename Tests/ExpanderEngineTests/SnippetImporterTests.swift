import XCTest
@testable import ExpanderEngine

final class SnippetImporterTests: XCTestCase {

    private var espansoMatchDir: URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/espanso/match", isDirectory: true)
    }

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-import-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeTempDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes a minimal TextExpander group plist (group_1.xml) into `dir`.
    private func writeTEGroupFile(to dir: URL, fileName: String = "group_1.xml") throws {
        let plist: [String: Any] = [
            "uuidString": UUID().uuidString,
            "name": "Test Group",
            "snippetPlists": [
                [
                    "uuidString": UUID().uuidString,
                    "abbreviation": ";sig",
                    "plainText": "Best regards",
                    "label": "Signature",
                    "snippetType": 0,
                    "abbreviationMode": 0,
                    "creationDate": Date(),
                    "modificationDate": Date()
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent(fileName))
    }

    // MARK: - detectKind

    func testDetectKindTextExpanderByBundleExtension() throws {
        let dir = try makeTempDir("te-ext")
            .appendingPathComponent("Settings.textexpandersettings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTempDir(dir) }
        XCTAssertEqual(SnippetImporter.detectKind(at: dir), .textExpander)
    }

    func testDetectKindTextExpanderByGroupFiles() throws {
        let dir = try makeTempDir("te-group")
        defer { removeTempDir(dir) }
        try writeTEGroupFile(to: dir)
        XCTAssertEqual(SnippetImporter.detectKind(at: dir), .textExpander)
    }

    func testDetectKindEspansoByYAMLFile() throws {
        let file = espansoMatchDir.appendingPathComponent("base.yml")
        XCTAssertEqual(SnippetImporter.detectKind(at: file), .espanso)
    }

    func testDetectKindEspansoByRootWithMatchDir() throws {
        let dir = try makeTempDir("espanso-root")
        defer { removeTempDir(dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("match", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(SnippetImporter.detectKind(at: dir), .espanso)
    }

    func testDetectKindEspansoByYAMLChildren() {
        XCTAssertEqual(SnippetImporter.detectKind(at: espansoMatchDir), .espanso)
    }

    func testDetectKindUnrecognized() throws {
        let dir = try makeTempDir("empty")
        defer { removeTempDir(dir) }
        XCTAssertNil(SnippetImporter.detectKind(at: dir))
        XCTAssertNil(SnippetImporter.detectKind(at: dir.appendingPathComponent("missing")))
    }

    // MARK: - importFrom

    func testImportFromTextExpanderFolder() throws {
        let dir = try makeTempDir("te-import")
        defer { removeTempDir(dir) }
        try writeTEGroupFile(to: dir)

        let result = try SnippetImporter.importFrom(dir)
        XCTAssertEqual(result.kind, .textExpander)
        XCTAssertEqual(result.snippetCount, 1)
        XCTAssertEqual(result.imageCount, 0)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].name, "Test Group")
        XCTAssertEqual(result.groups[0].snippets.first?.triggerKeyword, ";sig")
    }

    func testImportFromEspansoMatchDir() throws {
        let store = ImageAttachmentStore(directory: try makeTempDir("img-store"))
        defer { removeTempDir(store.imagesDirectory) }

        let result = try SnippetImporter.importFrom(espansoMatchDir, imageStore: store)
        XCTAssertEqual(result.kind, .espanso)
        XCTAssertGreaterThan(result.snippetCount, 0)
        XCTAssertEqual(result.imageCount, 0)
        XCTAssertFalse(result.groups.isEmpty)
        XCTAssertFalse(result.notes.isEmpty) // vars-skips produce a note
    }

    func testImportFromSingleYAMLFile() throws {
        let store = ImageAttachmentStore(directory: try makeTempDir("img-store"))
        defer { removeTempDir(store.imagesDirectory) }

        let file = espansoMatchDir.appendingPathComponent("base.yml")
        let result = try SnippetImporter.importFrom(file, imageStore: store)
        XCTAssertEqual(result.kind, .espanso)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].name, "base")
    }

    func testImportFromUnrecognizedThrows() throws {
        let dir = try makeTempDir("empty")
        defer { removeTempDir(dir) }
        XCTAssertThrowsError(try SnippetImporter.importFrom(dir)) { error in
            guard case SnippetImporter.ImportError.unrecognizedSource = error else {
                return XCTFail("expected unrecognizedSource, got \(error)")
            }
        }
    }

    func testImportFromMissingPathThrows() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try SnippetImporter.importFrom(missing)) { error in
            guard case SnippetImporter.ImportError.pathNotFound = error else {
                return XCTFail("expected pathNotFound, got \(error)")
            }
        }
    }

    // MARK: - Store integration

    func testStoreImportSnippetsMergesGroups() throws {
        let teDir = try makeTempDir("te-store")
        defer { removeTempDir(teDir) }
        try writeTEGroupFile(to: teDir)

        let storeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-store-\(UUID().uuidString)/snippets.json")
        let store = SnippetStore(fileURL: storeFile)
        defer { removeTempDir(storeFile.deletingLastPathComponent()) }

        let result = try store.importSnippets(from: teDir)
        XCTAssertEqual(result.kind, .textExpander)
        let imported = store.loadGroups().first { $0.name == "Test Group" }
        XCTAssertEqual(imported?.snippets.count, 1)
    }
}
