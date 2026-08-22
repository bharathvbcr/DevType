import XCTest
@testable import ExpanderEngine

// CSV formula-injection hardening. A field whose first character is one of
// `=`, `+`, `-`, `@` (or tab/CR) executes as a spreadsheet formula when the
// exported CSV is opened in Excel/Numbers/Sheets — a snippet titled
// `=cmd|' /C calc'!A0` would run code on the reader's machine. The standard
// mitigation is prefixing such fields with a single apostrophe; plain text
// must pass through byte-for-byte unchanged.

final class SnippetExportCsvInjectionTests: XCTestCase {

    private func group(_ snippets: [SnippetModel]) -> [SnippetGroup] {
        [SnippetGroup(name: "Group", snippets: snippets)]
    }

    private func makeSnippet(title: String, trigger: String, replacement: String) -> SnippetModel {
        SnippetModel(title: title, triggerKeyword: trigger, replacementText: replacement)
    }

    private func rows(of csv: String) -> [String] {
        csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    private func row(containing needle: String, in csv: String) throws -> String {
        try XCTUnwrap(rows(of: csv).first { $0.contains(needle) },
                      "no CSV row contains \(needle) in:\n\(csv)")
    }

    /// Every dangerous leading character gets neutralized with an apostrophe.
    func testFormulaLeadingCharactersAreNeutralized() throws {
        let csv = SnippetExporter.csv(from: group([
            makeSnippet(title: "=cmd|' /C calc'!A0", trigger: ":eq", replacement: "x"),
            makeSnippet(title: "+SUM(A1:A9)", trigger: ":plus", replacement: "x"),
            makeSnippet(title: "@import_url", trigger: ":at", replacement: "x"),
            makeSnippet(title: "-1 day", trigger: ":minus", replacement: "x"),
            makeSnippet(title: "\tTAB(A1)", trigger: ":tab", replacement: "x"),
        ]))

        XCTAssertTrue(try row(containing: ":eq", in: csv).contains("'=cmd"),
                      "leading '=' must be apostrophe-prefixed")
        XCTAssertTrue(try row(containing: ":plus", in: csv).contains("'+SUM"),
                      "leading '+' must be apostrophe-prefixed")
        XCTAssertTrue(try row(containing: ":at", in: csv).contains("'@import"),
                      "leading '@' must be apostrophe-prefixed")
        XCTAssertTrue(try row(containing: ":minus", in: csv).contains("'-1 day"),
                      "leading '-' must be apostrophe-prefixed (accepted tradeoff)")
        XCTAssertTrue(try row(containing: ":tab", in: csv).contains("'\tTAB"),
                      "leading tab must be apostrophe-prefixed")
    }

    /// The header row and ordinary fields must be untouched — no stray
    /// apostrophes, no re-quoting drift.
    func testPlainFieldsPassThroughUnchanged() throws {
        let csv = SnippetExporter.csv(
            from: group([
                makeSnippet(title: "plain title", trigger: ":plain", replacement: "normal text"),
            ]),
            options: SnippetExporter.Options(includeDisabled: true, imageStore: nil)
        )

        XCTAssertEqual(rows(of: csv).first, SnippetExporter.csvColumns.joined(separator: ","))
        XCTAssertFalse(csv.contains("'"), "nothing here should need an apostrophe: \(csv)")

        let body = try row(containing: ":plain", in: csv)
        XCTAssertTrue(body.contains(",plain title,,normal text,"),
                      "row content must survive verbatim")
    }

    /// Neutralization happens before RFC 4180 quoting, so a formula-leading
    /// field that also contains a comma stays valid CSV.
    func testNeutralizationComposesWithQuoting() throws {
        let csv = SnippetExporter.csv(from: group([
            makeSnippet(title: "=a,b", trigger: ":comma", replacement: "x"),
        ]))

        let line = try row(containing: ":comma", in: csv)
        XCTAssertTrue(line.contains("\"'=a,b\""),
                      "the apostrophe must sit inside the quoted field: \(line)")
    }
}
