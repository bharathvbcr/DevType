import XCTest
@testable import ExpanderEngine

final class TemplateRenderingTests: XCTestCase {

    func testSafeMathParserEvaluation() {
        XCTAssertEqual(SafeMathParser.evaluate("12 + 4"), 16.0)
        XCTAssertEqual(SafeMathParser.evaluate("10 * (3 + 2)"), 50.0)
        XCTAssertEqual(SafeMathParser.evaluate("2 ^ 3"), 8.0)
        XCTAssertEqual(SafeMathParser.evaluate("10 % 3"), 1.0)
        XCTAssertEqual(SafeMathParser.evaluate("-5 + 10"), 5.0)
        XCTAssertNil(SafeMathParser.evaluate("10 / 0"))
    }

    func testDynamicTemplateEngineDateAndClipboard() {
        let engine = DynamicTemplateEngine.shared
        let testDate = Date(timeIntervalSince1970: 1700000000)

        let template = "Hello {{clipboard}}, today is {{date:yyyy-MM-dd}}, calc={{calc: 5 * 5}}"
        let result = engine.resolve(template, currentDate: testDate, clipboardText: "DevType User")

        XCTAssertEqual(result.text, "Hello DevType User, today is 2023-11-14, calc=25")
        XCTAssertNil(result.cursorOffset)
    }

    func testDynamicTemplateEngineCursorOffset() {
        let engine = DynamicTemplateEngine.shared
        let template = "Function: () { {{cursor}} }"
        let result = engine.resolve(template)

        XCTAssertEqual(result.text, "Function: () {  }")
        XCTAssertEqual(result.cursorOffset, 15)
    }

    func testDynamicTemplateEngineMultipleCursorTags() {
        let engine = DynamicTemplateEngine.shared
        let template = "Start: {{cursor}}, End: {{cursor}}"
        let result = engine.resolve(template)

        XCTAssertEqual(result.text, "Start: , End: ")
        XCTAssertEqual(result.cursorOffset, 7)
    }

    func testClipboardCompatibilityAdapterPreservesLiteralTokensWithoutExecutingThem() {
        let raw = "hello {{clipboard}} {{cursor}} {{calc:1+2}} {{date}} world"
        XCTAssertEqual(DynamicTemplateEngine.sanitizeClipboardText(raw), raw)
        let result = DynamicTemplateEngine.shared.resolve("{{clipboard}}", clipboardText: raw)
        XCTAssertEqual(result.text, raw)
        XCTAssertNil(result.cursorOffset)
        XCTAssertNil(result.failure)
    }

    func testSafeMathParserBoundsExpressionLength() {
        let oversized = String(repeating: "1+", count: 40) + "1"
        XCTAssertGreaterThan(oversized.count, SafeMathParser.maxExpressionLength)
        XCTAssertNil(SafeMathParser.evaluate(oversized))
        XCTAssertEqual(SafeMathParser.evaluate("1+2"), 3.0)
        XCTAssertNil(SafeMathParser.evaluate("1 + abc"))
    }

    func testCursorOffsetUsesUTF16() {
        let engine = DynamicTemplateEngine.shared
        // BMP-only: Character index == UTF-16 index
        let ascii = engine.resolve("ab{{cursor}}cd")
        XCTAssertEqual(ascii.cursorOffset, 2)
        // Emoji is one Character but two UTF-16 units
        let emoji = engine.resolve("👍{{cursor}}")
        XCTAssertEqual(emoji.cursorOffset, 2)
    }

    func testClipboardLazyReadSkipsPasteboardWithoutTag() {
        let engine = DynamicTemplateEngine.shared
        XCTAssertFalse(DynamicTemplateEngine.templateNeedsClipboard("hello {{date}} {{cursor}}"))
        XCTAssertTrue(DynamicTemplateEngine.templateNeedsClipboard("x {{clipboard}} y"))

        // Without {{clipboard}}, an explicit clipboardText must not appear in output.
        let noTag = engine.resolve(
            "plain {{calc:1+1}}",
            clipboardText: "SHOULD_NOT_APPEAR"
        )
        XCTAssertEqual(noTag.text, "plain 2")
        XCTAssertFalse(noTag.text.contains("SHOULD_NOT_APPEAR"))

        // With tag, provided clipboardText is used (no need to touch the real pasteboard).
        let withTag = engine.resolve(
            "clip={{clipboard}}",
            clipboardText: "from-arg"
        )
        XCTAssertEqual(withTag.text, "clip=from-arg")
    }

    func testNestedFillPartRendering() {
        // Single fillPart ON / OFF
        let singleOn = MacroParser.parse("%fillpart:name=Sec:default=yes%Hello%fillpartend%")
        XCTAssertEqual(MacroParser.render(tokens: singleOn).text, "Hello")

        let singleOff = MacroParser.parse("%fillpart:name=Sec:default=no%Hello%fillpartend%")
        XCTAssertEqual(MacroParser.render(tokens: singleOff).text, "")

        // Outer OFF, Inner ON -> Outer skip must NOT be cleared by Inner fillPartEnd
        let outerOffInnerOn = MacroParser.parse(
            "A%fillpart:name=Out:default=no%B%fillpart:name=In:default=yes%C%fillpartend%D%fillpartend%E"
        )
        XCTAssertEqual(MacroParser.render(tokens: outerOffInnerOn).text, "AE")

        // Outer OFF, Inner OFF
        let outerOffInnerOff = MacroParser.parse(
            "A%fillpart:name=Out:default=no%B%fillpart:name=In:default=no%C%fillpartend%D%fillpartend%E"
        )
        XCTAssertEqual(MacroParser.render(tokens: outerOffInnerOff).text, "AE")

        // Outer ON, Inner OFF
        let outerOnInnerOff = MacroParser.parse(
            "A%fillpart:name=Out:default=yes%B%fillpart:name=In:default=no%C%fillpartend%D%fillpartend%E"
        )
        XCTAssertEqual(MacroParser.render(tokens: outerOnInnerOff).text, "ABDE")

        // Outer ON, Inner ON
        let outerOnInnerOn = MacroParser.parse(
            "A%fillpart:name=Out:default=yes%B%fillpart:name=In:default=yes%C%fillpartend%D%fillpartend%E"
        )
        XCTAssertEqual(MacroParser.render(tokens: outerOnInnerOn).text, "ABCDE")
    }
}
