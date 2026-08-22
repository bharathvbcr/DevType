import XCTest
@testable import ExpanderEngine

// Import boundary hardening: imported libraries are untrusted input. Oversized
// source files and oversized individual snippets must be skipped and reported —
// never parsed into memory bombs, never silently dropped.

final class SnippetImportLimitsTests: XCTestCase {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-import-limits-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTEGroup(to dir: URL, name: String, abbreviation: String, plainText: String) throws {
        let plist: [String: Any] = [
            "uuidString": UUID().uuidString,
            "name": "Group",
            "snippetPlists": [[
                "uuidString": UUID().uuidString,
                "abbreviation": abbreviation,
                "plainText": plainText,
                "label": "L",
                "snippetType": 0,
                "abbreviationMode": 0,
                "creationDate": Date(),
                "modificationDate": Date()
            ]]
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent(name))
    }

    // MARK: - TextExpander

    func testTEImportSkipsOversizedSnippetButImportsTheRest() throws {
        let dir = try makeTempDir("te")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTEGroup(
            to: dir, name: "group_1.xml",
            abbreviation: ";ok", plainText: "fine"
        )
        try writeTEGroup(
            to: dir, name: "group_2.xml",
            abbreviation: ";bomb",
            plainText: String(repeating: "x", count: SnippetImporter.SnippetImportLimits.maxReplacementCharacters + 1)
        )

        let result = try SnippetImporter.importFrom(dir)
        XCTAssertEqual(result.snippetCount, 1, "only the normal snippet should be imported")
        XCTAssertEqual(result.groups.flatMap(\.snippets).first?.triggerKeyword, ";ok")
        XCTAssertTrue(result.notes.contains { $0.contains("size limits") },
                      "the skip must be reported: \(result.notes)")
    }

    func testTEImportSkipsOversizedSourceFile() throws {
        let dir = try makeTempDir("te-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTEGroup(to: dir, name: "group_1.xml", abbreviation: ";ok", plainText: "fine")

        let huge = dir.appendingPathComponent("group_2.xml")
        try Data(count: SnippetImporter.SnippetImportLimits.maxSourceFileBytes + 1).write(to: huge)

        let result = try SnippetImporter.importFrom(dir)
        XCTAssertEqual(result.snippetCount, 1, "the oversized file must not be parsed")
        XCTAssertGreaterThan(result.skippedOversized, 0)
    }

    // MARK: - Espanso

    func testEspansoImportSkipsOversizedReplacement() throws {
        let dir = try makeTempDir("espanso")
        defer { try? FileManager.default.removeItem(at: dir) }
        let giant = String(repeating: "y", count: SnippetImporter.SnippetImportLimits.maxReplacementCharacters + 1)
        let yaml = """
        matches:
          - trigger: :ok
            replace: fine
          - trigger: :bomb
            replace: "\(giant)"
        """
        try yaml.write(to: dir.appendingPathComponent("base.yml"), atomically: true, encoding: .utf8)

        let result = try EspansoImporter.importFrom(dir)
        XCTAssertEqual(result.snippetCount, 1)
        XCTAssertEqual(result.skippedOversized, 1)
        XCTAssertEqual(result.groups.flatMap(\.snippets).first?.triggerKeyword, ":ok")
    }

    func testEspansoImportSkipsOversizedTrigger() throws {
        let dir = try makeTempDir("espanso-trigger")
        defer { try? FileManager.default.removeItem(at: dir) }
        let longTrigger = String(repeating: "t", count: SnippetImporter.SnippetImportLimits.maxTriggerCharacters + 1)
        let yaml = """
        matches:
          - trigger: "\(longTrigger)"
            replace: payload
        """
        try yaml.write(to: dir.appendingPathComponent("base.yml"), atomically: true, encoding: .utf8)

        let result = try EspansoImporter.importFrom(dir)
        XCTAssertEqual(result.snippetCount, 0)
        XCTAssertEqual(result.skippedOversized, 1)
    }

    func testEspansoImportSkipsOversizedSourceFileWithoutFailingTheBatch() throws {
        let dir = try makeTempDir("espanso-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("match"), withIntermediateDirectories: true)
        let good = """
        matches:
          - trigger: :ok
            replace: fine
        """
        try good.write(to: dir.appendingPathComponent("match/good.yml"), atomically: true, encoding: .utf8)
        try Data(count: SnippetImporter.SnippetImportLimits.maxSourceFileBytes + 1)
            .write(to: dir.appendingPathComponent("match/huge.yml"))

        let result = try EspansoImporter.importFrom(dir.appendingPathComponent("match"))
        XCTAssertEqual(result.snippetCount, 1, "the batch continues past an oversized file")
        XCTAssertEqual(result.skippedOversized, 1)
    }
}
