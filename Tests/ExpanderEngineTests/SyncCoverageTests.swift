import XCTest
@testable import ExpanderEngine

final class SyncCoverageTests: XCTestCase {
    // MARK: - RunningAppCheck

    func testRunningAppCheck() {
        XCTAssertTrue(RunningAppCheck.isTextExpander(bundleID: "com.smileonmymac.textexpander", name: nil))
        XCTAssertTrue(RunningAppCheck.isTextExpander(bundleID: nil, name: "TextExpander"))
        XCTAssertFalse(RunningAppCheck.isTextExpander(bundleID: "com.apple.textedit", name: "TextEdit"))

        XCTAssertTrue(RunningAppCheck.isEspanso(bundleID: "com.federicoterzi.espanso", name: nil))
        XCTAssertTrue(RunningAppCheck.isEspanso(bundleID: nil, name: "Espanso"))
        XCTAssertFalse(RunningAppCheck.isEspanso(bundleID: "com.apple.notes", name: "Notes"))
    }

    // MARK: - MacroPreview

    func testMacroPreviewClampedForStage() {
        XCTAssertEqual(MacroPreview.clampedForStage("abc", limit: 0), "")
        XCTAssertEqual(MacroPreview.clampedForStage("abc", limit: -1), "")
        XCTAssertEqual(MacroPreview.clampedForStage("abc", limit: 3), "abc")
        XCTAssertEqual(MacroPreview.clampedForStage("abcdef", limit: 3), "abc…")
    }

    func testMacroPreviewRenderEdgeCases() {
        // Empty popup options and default
        let emptyPopup = MacroPreview.render("%fillpopup:name=test%")
        XCTAssertEqual(emptyPopup, "(test)")

        // Cursor, key, and date
        let misc = MacroPreview.render("key:%key:return%cursor:%|%date:%date:iso%")
        XCTAssertTrue(misc.contains("key:cursor:date:"))

        // Unclosed case block
        let unclosedCase = MacroPreview.render("%case:upper%hello")
        XCTAssertEqual(unclosedCase, "HELLO")
    }

    // MARK: - PaletteTextOps

    func testPaletteTextOpsAllTransforms() {
        XCTAssertEqual(PaletteTextOps.apply(.upper, to: "hello"), "HELLO")
        XCTAssertEqual(PaletteTextOps.apply(.lower, to: "HELLO"), "hello")
        XCTAssertEqual(PaletteTextOps.apply(.title, to: "hello world"), "Hello World")
        XCTAssertEqual(PaletteTextOps.apply(.sentence, to: "hello world. foo bar."), "Hello world. Foo bar.")
        XCTAssertEqual(PaletteTextOps.apply(.snake, to: "Hello World"), "hello_world")
        XCTAssertEqual(PaletteTextOps.apply(.kebab, to: "Hello World"), "hello-world")
        XCTAssertEqual(PaletteTextOps.apply(.camel, to: "hello_world"), "helloWorld")
        XCTAssertEqual(PaletteTextOps.apply(.pascal, to: "hello_world"), "HelloWorld")
        XCTAssertEqual(PaletteTextOps.apply(.sortLines, to: "b\na\nc"), "a\nb\nc")
        XCTAssertEqual(PaletteTextOps.apply(.dedupeLines, to: "a\nb\na\nc\nb"), "a\nb\nc")
        XCTAssertEqual(PaletteTextOps.apply(.trimLines, to: "  a  \n  b  "), "a\nb")
        XCTAssertEqual(PaletteTextOps.apply(.numberLines, to: "first\nsecond"), "1. first\n2. second")
        
        let b64 = PaletteTextOps.apply(.base64Encode, to: "hello")
        XCTAssertEqual(PaletteTextOps.apply(.base64Decode, to: b64), "hello")
        XCTAssertEqual(PaletteTextOps.apply(.base64Decode, to: "!!!invalid base64!!!"), "!!!invalid base64!!!")

        let encodedURL = PaletteTextOps.apply(.urlEncode, to: "hello world&foo=bar")
        XCTAssertTrue(encodedURL.contains("%20"))
        XCTAssertEqual(PaletteTextOps.apply(.urlDecode, to: encodedURL), "hello world&foo=bar")

        let escapedHTML = PaletteTextOps.apply(.htmlEscape, to: "<div class=\"test\" id='foo'>&</div>")
        XCTAssertEqual(escapedHTML, "&lt;div class=&quot;test&quot; id=&#39;foo&#39;&gt;&amp;&lt;/div&gt;")
        XCTAssertEqual(PaletteTextOps.apply(.htmlUnescape, to: escapedHTML), "<div class=\"test\" id='foo'>&</div>")

        let rawJSON = "{\"b\":2,\"a\":1}"
        let pretty = PaletteTextOps.apply(.jsonPretty, to: rawJSON)
        XCTAssertTrue(pretty.contains("\n"))
        let compact = PaletteTextOps.apply(.jsonCompact, to: pretty)
        XCTAssertFalse(compact.contains("\n"))
        XCTAssertEqual(PaletteTextOps.apply(.jsonPretty, to: "invalid json"), "invalid json")
        XCTAssertEqual(PaletteTextOps.apply(.jsonCompact, to: "invalid json"), "invalid json")

        XCTAssertFalse(PaletteTextOps.apply(.sha256, to: "test").isEmpty)
        XCTAssertFalse(PaletteTextOps.apply(.md5, to: "test").isEmpty)
    }

    func testPaletteTextOpsGeneratorsAndSummaries() {
        let uuid = PaletteTextOps.generate(.uuid)
        XCTAssertEqual(UUID(uuidString: uuid)?.uuidString.lowercased(), uuid)

        let lorem = PaletteTextOps.generate(.lorem)
        XCTAssertTrue(lorem.hasPrefix("Lorem ipsum"))

        let pass = PaletteTextOps.generate(.password)
        XCTAssertEqual(pass.count, 20)

        let summary = PaletteTextOps.countSummary(for: "Hello world\nSecond line")
        XCTAssertTrue(summary.contains("chars"))
        XCTAssertTrue(summary.contains("words"))
        XCTAssertTrue(summary.contains("lines"))
        XCTAssertEqual(PaletteTextOps.countSummary(for: ""), "0 chars · 0 words · 0 lines")

        XCTAssertEqual(PaletteTextOps.formatMathResult(42.0), "42")
    }

    // MARK: - SnippetExporter

    func testSnippetExporterPropertiesAndErrors() {
        XCTAssertEqual(SnippetExporter.Format.espansoYAML.fileExtension, "yml")
        XCTAssertEqual(SnippetExporter.Format.csv.fileExtension, "csv")
        XCTAssertEqual(SnippetExporter.Format.espansoYAML.displayName, "Espanso YAML")
        XCTAssertEqual(SnippetExporter.Format.csv.displayName, "CSV")
        XCTAssertEqual(SnippetExporter.Format.espansoYAML.suggestedFileName, "devtype-espanso.yml")
        XCTAssertEqual(SnippetExporter.Format.csv.suggestedFileName, "devtype-snippets.csv")

        let yamlErr = SnippetExporter.ExportError.yamlSerializationFailed("syntax error")
        XCTAssertTrue(yamlErr.errorDescription?.contains("syntax error") == true)
        let encErr = SnippetExporter.ExportError.encodingFailed
        XCTAssertTrue(encErr.errorDescription?.contains("UTF-8") == true)
    }

    func testSnippetExporterEmptyAndDisabledFiltering() throws {
        let snippet1 = SnippetModel(
            id: UUID(),
            title: "Active",
            triggerKeyword: "act",
            replacementText: "Active replacement",
            enabled: true
        )
        let snippet2 = SnippetModel(
            id: UUID(),
            title: "Disabled",
            triggerKeyword: "dis",
            replacementText: "Disabled replacement",
            enabled: false
        )
        let snippet3 = SnippetModel(
            id: UUID(),
            title: "NoTrigger",
            triggerKeyword: "",
            replacementText: "No trigger",
            enabled: true
        )

        let activeGroup = SnippetGroup(
            id: UUID(),
            name: "ActiveGroup",
            enabled: true,
            snippets: [snippet1, snippet2, snippet3]
        )
        let disabledGroup = SnippetGroup(
            id: UUID(),
            name: "DisabledGroup",
            enabled: false,
            snippets: [snippet1]
        )

        // Export only enabled
        let options = SnippetExporter.Options(includeDisabled: false, imageStore: nil)
        let yaml = try SnippetExporter.espansoYAML(from: [activeGroup, disabledGroup], options: options)
        XCTAssertTrue(yaml.contains("act"))
        XCTAssertFalse(yaml.contains("dis"))

        let data = try SnippetExporter.data(from: [activeGroup], format: .csv, options: options)
        XCTAssertFalse(data.isEmpty)
    }
}
