import XCTest
@testable import ExpanderEngine

final class TranscriptDiffBudgetTests: XCTestCase {
    func testTextTokenAndMatrixBudgetsProduceDistinctOmissions() {
        XCTAssertEqual(TranscriptDiffEngine.compare(
            verbatim: String(repeating: "a", count: TranscriptDiffEngine.maximumTextUTF16 + 1), cleaned: "a"
        ), .omitted(.textBudget))
        XCTAssertEqual(TranscriptDiffEngine.compare(
            verbatim: String(repeating: "a ", count: TranscriptDiffEngine.maximumTokens + 1), cleaned: "a"
        ), .omitted(.tokenBudget))
        let a = (0..<1100).map { "old\($0)" }.joined(separator: " ")
        let b = (0..<1100).map { "new\($0)" }.joined(separator: " ")
        XCTAssertEqual(TranscriptDiffEngine.compare(verbatim: a, cleaned: b), .omitted(.matrixBudget))
    }

    func testCommonPrefixAndSuffixAvoidQuadraticWorkAndRetainTheCut() {
        let prefix = String(repeating: "before ", count: 1500)
        let suffix = String(repeating: " after", count: 1500)
        guard case .compared(let segments) = TranscriptDiffEngine.compare(
            verbatim: prefix + "umm" + suffix, cleaned: prefix + "yes" + suffix
        ) else { return XCTFail("Small changed middle must fit the budget") }
        XCTAssertEqual(segments.filter(\.isCut).map(\.text), ["umm"])
    }

    func testCancellationBeforeAndDuringComparisonProducesNoPartialDiff() {
        XCTAssertEqual(TranscriptDiffEngine.compare(verbatim: "a", cleaned: "b", isCancelled: { true }), .omitted(.cancelled))
        var checks = 0
        let a = (0..<300).map { "old\($0)" }.joined(separator: " ")
        let b = (0..<300).map { "new\($0)" }.joined(separator: " ")
        let result = TranscriptDiffEngine.compare(verbatim: a, cleaned: b, isCancelled: {
            checks += 1
            return checks == 4
        })
        XCTAssertEqual(result, .omitted(.cancelled))
        XCTAssertEqual(checks, 4)
    }

    func testUnicodeTokensAndRepeatedPunctuationPreserveOriginalText() {
        guard case .compared(let segments) = TranscriptDiffEngine.compare(
            verbatim: "🧑🏽‍💻 umm café ... done", cleaned: "🧑🏽‍💻 café ... done"
        ) else { return XCTFail() }
        XCTAssertEqual(segments.map(\.text).joined(separator: " "), "🧑🏽‍💻 umm café ... done")
        XCTAssertTrue(segments.contains { $0.isCut && $0.text.contains("umm") })
    }
}
