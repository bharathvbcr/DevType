import XCTest
@testable import ExpanderEngine

final class ProductivityTextToolsTests: XCTestCase {
    func testIdentifierStylesHandleAcronymsAndExistingSeparators() {
        let input = "  HTTPServer v2_ID -- userName  "
        let cases: [(PaletteTextOp, String)] = [
            (.snake, "http_server_v2_id_user_name"), (.kebab, "http-server-v2-id-user-name"),
            (.camel, "httpServerV2IdUserName"), (.pascal, "HttpServerV2IdUserName")
        ]
        for (operation, expected) in cases {
            XCTAssertEqual(PaletteTextOps.apply(operation, to: input), expected)
            XCTAssertEqual(PaletteTextOps.apply(operation, to: expected), expected)
        }
    }

    func testIdentifierStylesAreOfflineAndLocaleIndependent() {
        for locale in [Locale(identifier: "tr_TR"), Locale(identifier: "ja_JP")] {
            XCTAssertEqual(TextCaseTransform.snake.apply(to: "Istanbul 東京 Café", locale: locale), "istanbul_東京_café")
        }
        XCTAssertEqual(PaletteTextOps.apply(.camel, to: ""), "")
        XCTAssertEqual(PaletteTextOps.apply(.snake, to: "--- 👩🏽‍💻 ---"), "")
        XCTAssertEqual(PaletteTextOps.apply(.snake, to: "e\u{301}clair Value"), "e\u{301}clair_value")
    }

    func testBothMacroSyntaxesUseTheSameTransformsAndKeepCursorAnchors() {
        let engine = DynamicTemplateEngine()
        for (name, expected) in [("snake", "http_server"), ("camel", "httpServer"), ("pascal", "HttpServer"), ("kebab", "http-server")] {
            XCTAssertEqual(engine.resolve("{{\(name):HTTPServer}}").text, expected)
            XCTAssertEqual(MacroRenderer.expand(content: "%case:\(name)%HTTPServer%caseend%", clipboardText: "").text, expected)
        }
        let marked = engine.resolve("{{snake:HTTPS{{cursor}}erver}}")
        XCTAssertEqual(marked.text, "http_server")
        XCTAssertEqual(marked.cursorOffset, 6, "cursor remains after the S, even at an acronym boundary")
    }

    func testNewToolsAreDiscoverableThroughTheRealPaletteCatalog() {
        for operation in [PaletteTextOp.snake, .kebab, .camel, .pascal] {
            let hits = CommandPaletteCatalog.matchCommands(query: operation.rawValue)
            let expected = PaletteCommandAction.textOp(operation)
            XCTAssertTrue(hits.contains { $0.command.action == expected }, operation.rawValue)
        }
    }

    func testEncodingRoundTripsAndMalformedInputIsPreserved() {
        for text in ["a&b=c+d", "東京 👩🏽‍💻", "\u{0}", "\r\n", "100%", ""] {
            XCTAssertEqual(PaletteTextOps.apply(.urlDecode, to: PaletteTextOps.apply(.urlEncode, to: text)), text)
            XCTAssertEqual(PaletteTextOps.apply(.base64Decode, to: PaletteTextOps.apply(.base64Encode, to: text)), text)
        }
        for malformed in ["%", "%QQ", "%FF"] {
            XCTAssertEqual(PaletteTextOps.apply(.urlDecode, to: malformed), malformed)
        }
        XCTAssertEqual(PaletteTextOps.apply(.jsonPretty, to: "{broken"), "{broken")
    }

    func testIdentifierConversionStressDoesNotGrowOnRepeatedApplication() {
        let fragments = ["HTTPServer", "URL", "userName", "東京", "Résumé", "v2", " ", "-", "_", "👩🏽‍💻"]
        for seed in 0..<1_000 {
            let source = (0..<(seed % 40)).map { fragments[(seed + $0 * 3) % fragments.count] }.joined(separator: " ")
            for operation in [PaletteTextOp.snake, .kebab, .camel, .pascal] {
                let output = PaletteTextOps.apply(operation, to: source)
                XCTAssertEqual(PaletteTextOps.apply(operation, to: output), output)
                XCTAssertFalse(output.contains("__"))
            }
        }
    }
}
