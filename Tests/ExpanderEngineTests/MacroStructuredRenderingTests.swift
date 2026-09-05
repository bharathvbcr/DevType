import XCTest
@testable import ExpanderEngine

final class MacroStructuredRenderingTests: XCTestCase {
    func testAnchorsAtReplacementBoundariesAndMultipleMarkersUseFirstPosition() {
        for (template, text, offset) in [
            ("%|{{upper:abc}}x", "ABCx", 0),
            ("{{cursor}}{{upper:ß}}x", "SSx", 0),
            ("a%|{{upper:ß}}x{{cursor}}", "aSSx", 1),
            ("a{{cursor}}%|{{lower:HELLO}}", "ahello", 1),
            ("{{upper:a%|ß}}x", "ASSx", 1),
            ("{{upper:aß{{cursor}}}}x", "ASSx", 3),
            ("%case:upper%aß%|c%caseend%x", "ASSCx", 3)
        ] {
            let result = MacroRenderer.expand(content: template, clipboardText: "")
            XCTAssertNil(result.failure, template)
            XCTAssertEqual(result.text, text, template)
            XCTAssertEqual(result.cursorOffset, offset, template)
        }
    }

    func testNestedTransformsAcrossBothSyntaxesFollowContainment() {
        for (template, text) in [
            ("%case:upper%{{lower:Hello}}%caseend%", "HELLO"),
            ("{{lower:%case:upper%Hello%caseend%}}", "hello"),
            ("{{title:hello {{upper:world}}}}", "Hello World"),
            ("{{calc:{{counter:sample}}+2}}", "3")
        ] {
            let suite = "devtype.macro.nesting.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail() }
            defer { defaults.removePersistentDomain(forName: suite) }
            let result = MacroRenderer.expand(content: template, clipboardText: "",
                environment: MacroEnvironment(counters: MacroCounterStore(defaults: defaults)))
            XCTAssertNil(result.failure, template)
            XCTAssertEqual(result.text, text, template)
        }
    }

    func testExternalLiteralsCanBeTransformedWithoutBecomingTemplateSyntax() {
        let literal = "ß {{cursor}} {{counter:invoice}} 🧑🏽‍💻"
        let result = MacroRenderer.expand(content: "{{upper:%clipboard}}%|x", clipboardText: literal)
        let expected = literal.uppercased()
        XCTAssertEqual(result.text, expected + "x")
        XCTAssertEqual(result.cursorOffset, expected.utf16.count)
        XCTAssertNil(result.failure)
        let name = MacroRenderer.expand(content: "{{%clipboard}}", clipboardText: "calc:2+2")
        XCTAssertEqual(name.text, "{{calc:2+2}}", "External data cannot supply a macro command name")
    }

    func testGeneratedMacroLookingValueIsNeverReparsed() {
        let result = MacroRenderer.expand(content: "%random:{{upper:payload}}|{{upper:payload}}%", clipboardText: "")
        XCTAssertEqual(result.text, "{{upper:payload}}")
        XCTAssertNil(result.failure)
        XCTAssertNil(result.cursorOffset)
    }

    func testBoundedWorkReturnsTypedFailureWithoutPartialPayloadOrTrailingKeys() {
        let tooLarge = MacroRenderer.expand(content: String(repeating: "a", count: MacroDocument.maximumUTF16 + 1), clipboardText: "")
        XCTAssertEqual(tooLarge.failure, .sizeLimit)
        XCTAssertTrue(tooLarge.text.isEmpty)
        let tooMany = MacroRenderer.expand(content: String(repeating: "{{cursor}}", count: MacroDocument.maximumOperations + 1), clipboardText: "")
        XCTAssertEqual(tooMany.failure, .workLimit)
        XCTAssertTrue(tooMany.text.isEmpty)
        XCTAssertNil(tooMany.cursorOffset)
        let expensive = MacroRenderer.expand(content: String(repeating: "x", count: 100_000) + String(repeating: "{{upper:y}}", count: 200) + "%key:enter%", clipboardText: "")
        XCTAssertEqual(expensive.failure, .workLimit)
        XCTAssertTrue(expensive.text.isEmpty)
        XCTAssertTrue(expensive.trailingKeys.isEmpty)
    }

    func testMalformedOverlappingTransformsRefuseInsteadOfDeliveringPartialText() {
        let result = MacroRenderer.expand(content: "{{upper:abc%case:lower%}}def%caseend%", clipboardText: "")
        XCTAssertEqual(result.failure, .invalidStructure)
        XCTAssertTrue(result.text.isEmpty)
    }

    func testLiteralProjectionKeepsUnicodeAndAdjacentTrustedTagCoordinates() {
        for literal in ["🧑🏽‍💻", "İ\u{0307}", "{{}}", "}} {{", "\u{FFFC}", "line1\n{{cursor}}\nline2"] {
            let result = MacroRenderer.expand(content: "%clipboard{{upper:ß}}%|x", clipboardText: literal)
            XCTAssertEqual(result.text, literal + "SSx")
            XCTAssertEqual(result.cursorOffset, literal.utf16.count + 2)
            XCTAssertNil(result.failure)
        }
    }
}
