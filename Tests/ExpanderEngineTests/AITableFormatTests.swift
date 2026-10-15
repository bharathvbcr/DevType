import XCTest
@testable import ExpanderEngine

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The Markdown a table transform inserts, and the schema the model is asked to fill.
///
/// Rendering is compiled on every toolchain. The schema and the
/// `GeneratedContent` round trip exist only where Foundation Models imports.
final class AITableFormatTests: XCTestCase {

    func testRendersAHeaderAndRows() {
        let markdown = AITableFormat.markdown(
            columns: ["Name", "Role"],
            rows: [["Ada", "Engine"], ["Grace", "Compiler"]]
        )
        XCTAssertEqual(
            markdown,
            """
            | Name | Role |
            | --- | --- |
            | Ada | Engine |
            | Grace | Compiler |
            """
        )
    }

    func testShortRowIsPaddedAndLongRowIsCutToTheHeader() {
        let markdown = AITableFormat.markdown(
            columns: ["A", "B"],
            rows: [["only"], ["1", "2", "3"]]
        )
        XCTAssertEqual(
            markdown,
            """
            | A | B |
            | --- | --- |
            | only |  |
            | 1 | 2 |
            """
        )
    }

    func testPipeAndNewlineCannotOpenAColumnOrARow() {
        let markdown = AITableFormat.markdown(
            columns: ["Cell"],
            rows: [["a|b\nc"]]
        )
        XCTAssertEqual(
            markdown,
            """
            | Cell |
            | --- |
            | a\\|b c |
            """
        )
    }

    func testEmptyColumnsEmptyRowsAndBlankHeadersAreAFailedFormat() {
        XCTAssertNil(AITableFormat.markdown(columns: [], rows: [["a"]]))
        XCTAssertNil(AITableFormat.markdown(columns: ["A"], rows: []))
        XCTAssertNil(AITableFormat.markdown(columns: ["  ", "\n"], rows: [["a", "b"]]))
    }

    func testACellStopsAtTheCap() {
        let raw = String(repeating: "a", count: AITableFormat.maximumCellCharacters + 40)
        let markdown = AITableFormat.markdown(columns: ["C"], rows: [[raw]])
        let cell = String(repeating: "a", count: AITableFormat.maximumCellCharacters) + "…"
        XCTAssertEqual(
            markdown,
            """
            | C |
            | --- |
            | \(cell) |
            """
        )
    }

    func testColumnsAndRowsPastTheCapAreDropped() throws {
        let columns = (1...10).map { "C\($0)" }
        let row = (1...10).map { "R\($0)" }
        let rows = (1...45).map { _ in row }
        let markdown = try XCTUnwrap(AITableFormat.markdown(columns: columns, rows: rows))
        XCTAssertTrue(markdown.contains("C8"))
        XCTAssertFalse(markdown.contains("C9"))
        XCTAssertFalse(markdown.contains("R9"))
        let lines = markdown.split(separator: "\n")
        // Header, rule, then at most maximumRows body lines.
        XCTAssertEqual(lines.count, AITableFormat.maximumRows + 2)
    }

    func testToTableIsAPreviewOnlyModelFormat() {
        let kind = AITransformKind.toTable
        XCTAssertEqual(kind.rawValue, "totable")
        XCTAssertEqual(kind.defaultOutputMode, .preview)
        XCTAssertTrue(kind.requiresModel)
        XCTAssertEqual(kind.markdownPolicy, .preserve)
        XCTAssertFalse(kind.isChunkSafe)
        XCTAssertFalse(kind.isRewriteStyle)
        XCTAssertEqual(kind.tokenBudgetMultiplier, 1.6)
        XCTAssertNil(AILocalTransform.run(kind: kind, input: "a, b"))
        XCTAssertEqual(kind.localizationKey, "ai.kind.totable")
    }

    #if canImport(FoundationModels)
    func testGenerationSchemaBuilds() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("DynamicGenerationSchema requires macOS 26")
        }
        let schema = try AITableFormat.generationSchema()
        XCTAssertFalse(String(describing: schema).isEmpty)
    }

    func testGeneratedContentRoundTripsThroughTheRenderer() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("GeneratedContent requires macOS 26")
        }
        let content = try GeneratedContent(json: """
        {"columns":["Name","Role"],"rows":[["Ada","Engine"],["Grace","Compiler"]]}
        """)
        XCTAssertEqual(
            AITableFormat.markdown(from: content),
            AITableFormat.markdown(
                columns: ["Name", "Role"],
                rows: [["Ada", "Engine"], ["Grace", "Compiler"]]
            )
        )
    }
    #endif

}

