import XCTest
@testable import ExpanderEngine

final class ProductivityPaletteIntegrityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CommandPaletteCatalog.invalidateCache()
    }

    func testGeneratorDoesNotReplayTheCachedUUID() throws {
        func generated() throws -> String {
            let rows = CommandPaletteCatalog.buildRows(query: "uuid", groups: [])
            return try XCTUnwrap(rows.compactMap { row -> String? in
                guard case .command(let hit) = row, hit.command.action == .generate(.uuid) else { return nil }
                return hit.insertText
            }.first)
        }
        XCTAssertNotEqual(try generated(), try generated())
    }

    func testSmallNonzeroCalculatorResultDoesNotBecomeZero() {
        XCTAssertNotEqual(PaletteTextOps.formatMathResult(0.000000001), "0")
        XCTAssertEqual(PaletteTextOps.formatMathResult(1.0 / 3.0), SafeMathParser.format(1.0 / 3.0))
    }

    func testURLComponentEncodingEscapesQueryDelimiters() {
        XCTAssertEqual(PaletteTextOps.apply(.urlEncode, to: "a&b=c+d?#/"), "a%26b%3Dc%2Bd%3F%23%2F")
    }

    func testJSONToolsSupportScalarDocuments() {
        XCTAssertEqual(PaletteTextOps.apply(.jsonCompact, to: "  true  "), "true")
        XCTAssertEqual(PaletteTextOps.apply(.jsonPretty, to: "  42  "), "42")
        XCTAssertEqual(PaletteTextOps.apply(.jsonCompact, to: " null "), "null")
    }

    func testLineToolsRecognizeWindowsAndUnicodeLineBreaks() {
        for separator in ["\r\n", "\r", "\u{2028}", "\u{2029}"] {
            let text = ["beta", "alpha", "beta"].joined(separator: separator)
            XCTAssertEqual(PaletteTextOps.apply(.dedupeLines, to: text), "beta\nalpha")
            XCTAssertEqual(PaletteTextOps.apply(.sortLines, to: text), "alpha\nbeta\nbeta")
            XCTAssertEqual(PaletteTextOps.apply(.numberLines, to: text), "1. beta\n2. alpha\n3. beta")
            XCTAssertTrue(PaletteTextOps.countSummary(for: text).hasSuffix("3 lines"))
        }
    }
}
