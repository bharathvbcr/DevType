import XCTest
@testable import ExpanderEngine

final class MacroAnchorLiteralRegressionTests: XCTestCase {
    func testTECursorTracksFinalTextAcrossMustacheLengthChanges() {
        for (template, text, offset) in [
            ("{{upper:abc}}%|x", "ABCx", 3),
            ("{{upper:ß}}%|🧑🏽‍💻", "SS🧑🏽‍💻", 2),
            ("{{calc:12+4}}%|x", "16x", 2),
            ("%case:upper%aß%|c%caseend%", "ASSC", 3)
        ] {
            let result = MacroRenderer.expand(content: template, clipboardText: "")
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(result.cursorOffset, offset, template)
        }
    }

    func testExternalClipboardAndFillInDataStayLiteralWithoutLosingBraces() {
        let literal = "const item = {{value}}; {{cursor}} {{calc:2+2}} %|"
        for template in ["%clipboard", "{{clipboard}}", "%filltext:name=X%"] {
            let result = MacroRenderer.expand(content: template, fillValues: [0: literal], clipboardText: literal)
            XCTAssertEqual(result.text, literal, template)
            XCTAssertNil(result.cursorOffset, template)
        }
    }

    func testClipboardCannotCreateGeneratedValuesOrCaseTags() throws {
        let suite = "devtype.macro.literal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let counters = MacroCounterStore(defaults: defaults)
        let literal = "{{counter:invoice}} {{upper:payload}}"
        let result = MacroRenderer.expand(content: "%clipboard", clipboardText: literal,
                                          environment: MacroEnvironment(counters: counters))
        XCTAssertEqual(result.text, literal)
        XCTAssertEqual(counters.value(for: "invoice"), 0)
    }
}
