import XCTest
@testable import ExpanderEngine

final class TranscriptDiffBudgetRegressionTests: XCTestCase {
    func testOversizedDivergentTranscriptFallsBackToCompleteCleanedText() {
        let original = "same " + (0..<1100).map { "old\($0)" }.joined(separator: " ")
        let cleaned = "same " + (0..<1100).map { "new\($0)" }.joined(separator: " ")
        XCTAssertEqual(TranscriptDiffEngine.segments(verbatim: original, cleaned: cleaned), [
            TranscriptDiffEngine.Segment(text: cleaned, isCut: false)
        ])
    }
}
