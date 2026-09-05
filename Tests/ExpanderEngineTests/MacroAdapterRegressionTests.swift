import XCTest
@testable import ExpanderEngine

final class MacroAdapterRegressionTests: XCTestCase {
    func testFailedParserRenderCannotRetainAnActionOrCursor() {
        let result = MacroParser.render(tokens: [.key("enter"), .cursor,
            .text(String(repeating: "a", count: MacroDocument.maximumUTF16 + 1))])
        XCTAssertEqual(result.failure, .sizeLimit)
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertTrue(result.trailingKeys.isEmpty)
        XCTAssertEqual(result.cursorOffsetFromEnd, 0)
    }

    func testExpansionLabPassesItsPreparedResultToInjection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/DevTypeAppCore/TestExpansionLab.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("MacroRenderer.expand("))
        XCTAssertTrue(source.contains("preResolvedText: self.prepared.text"))
        XCTAssertTrue(source.contains("preResolvedCursorOffset: self.prepared.cursorOffset"))
        XCTAssertTrue(source.contains("trailingKeys: self.prepared.trailingKeys"))
        XCTAssertFalse(source.contains("DynamicTemplateEngine.shared.resolve("))
    }
}
