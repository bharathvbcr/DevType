import XCTest
@testable import ExpanderEngine

final class EspansoImporterTests: XCTestCase {

    private var fixtureRoot: URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/espanso", isDirectory: true)
    }

    private var matchDir: URL {
        fixtureRoot.appendingPathComponent("match", isDirectory: true)
    }

    func testImportStaticMultilineWordTriggersAndCursor() throws {
        let result = try EspansoImporter.importFrom(matchDir)

        let base = try XCTUnwrap(result.groups.first { $0.name == "base" })
        let byTrigger = Dictionary(uniqueKeysWithValues: base.snippets.map { ($0.triggerKeyword, $0) })

        let hello = try XCTUnwrap(byTrigger[":hello"])
        XCTAssertEqual(hello.replacementText, "Hello World")
        XCTAssertEqual(hello.label, "Greeting")
        XCTAssertEqual(hello.title, "Greeting")
        XCTAssertFalse(hello.requireWordBoundary)

        let multi = try XCTUnwrap(byTrigger[":multi"])
        XCTAssertEqual(multi.replacementText, "Line one\nLine two\n")

        let word = try XCTUnwrap(byTrigger["ther"])
        XCTAssertEqual(word.replacementText, "there")
        XCTAssertTrue(word.requireWordBoundary)

        let sig = try XCTUnwrap(byTrigger[":sig"])
        let signature = try XCTUnwrap(byTrigger[":signature"])
        XCTAssertEqual(sig.replacementText, "Best regards")
        XCTAssertEqual(signature.replacementText, "Best regards")

        let cursor = try XCTUnwrap(byTrigger[":cursor"])
        XCTAssertEqual(cursor.replacementText, "code({{cursor}});")
    }

    func testSkipsVarsAndUntranslatedMustache() throws {
        let result = try EspansoImporter.importFrom(matchDir)
        let base = try XCTUnwrap(result.groups.first { $0.name == "base" })
        let triggers = Set(base.snippets.map(\.triggerKeyword))

        XCTAssertFalse(triggers.contains(":now"))
        XCTAssertFalse(triggers.contains(":barevar"))
        XCTAssertGreaterThanOrEqual(result.skippedVars, 2)
    }

    func testUnderscoreFileSkippedUnlessImported() throws {
        let result = try EspansoImporter.importFrom(matchDir)
        let allTriggers = Set(result.groups.flatMap(\.snippets).map(\.triggerKeyword))

        // Reached via with_import.yml → imports: ./_private.yml
        XCTAssertTrue(allTriggers.contains(":secret"))
        XCTAssertTrue(allTriggers.contains(":public"))

        // No standalone group named "_private" from auto-load of underscore file alone
        // (matches live under the imported file's stem group).
        let privateGroup = result.groups.first { $0.name == "_private" }
        XCTAssertNotNil(privateGroup)
        XCTAssertEqual(privateGroup?.snippets.map(\.triggerKeyword), [":secret"])
    }

    func testImportSingleYAMLFile() throws {
        let file = matchDir.appendingPathComponent("base.yml")
        let result = try EspansoImporter.importFrom(file)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].name, "base")
        XCTAssertGreaterThan(result.snippetCount, 0)
        XCTAssertFalse(result.groups[0].snippets.contains { $0.triggerKeyword == ":now" })
    }

    func testImportPackageUsesManifestTitle() throws {
        let pkg = fixtureRoot.appendingPathComponent("packages/sample-pkg", isDirectory: true)
        let result = try EspansoImporter.importFrom(pkg)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].name, "Sample Package")
        XCTAssertEqual(result.groups[0].snippets.map(\.triggerKeyword), [":pkg"])
        XCTAssertEqual(result.snippetCount, 1)
    }

    func testImportCycleGuard() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("espanso-cycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.yml")
        let b = dir.appendingPathComponent("b.yml")
        try """
        imports:
          - "./b.yml"
        matches:
          - trigger: ":a"
            replace: "A"
        """.write(to: a, atomically: true, encoding: .utf8)
        try """
        imports:
          - "./a.yml"
        matches:
          - trigger: ":b"
            replace: "B"
        """.write(to: b, atomically: true, encoding: .utf8)

        let result = try EspansoImporter.importFrom(dir)
        let triggers = Set(result.groups.flatMap(\.snippets).map(\.triggerKeyword))
        XCTAssertEqual(triggers, [":a", ":b"])
    }

    func testRunningAppCheckIsEspanso() {
        XCTAssertTrue(RunningAppCheck.isEspanso(bundleID: "com.federicoterzi.espanso", name: nil))
        XCTAssertTrue(RunningAppCheck.isEspanso(bundleID: nil, name: "Espanso"))
        XCTAssertFalse(RunningAppCheck.isEspanso(bundleID: "com.apple.TextEdit", name: "TextEdit"))
    }
}
