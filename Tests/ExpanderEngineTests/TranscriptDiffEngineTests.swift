import XCTest
@testable import ExpanderEngine

final class TranscriptDiffEngineTests: XCTestCase {

    func testIdenticalTranscriptsProduceSingleKeptSegment() {
        let text = "Hello world from DevType"
        let segments = TranscriptDiffEngine.segments(verbatim: text, cleaned: text)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, text)
        XCTAssertFalse(segments.first?.isCut ?? true)
    }

    func testFillerRemovalMarkedAsCut() {
        let verbatim = "umm let's meet at 2pm"
        let cleaned = "let's meet at 2pm"
        let segments = TranscriptDiffEngine.segments(verbatim: verbatim, cleaned: cleaned)

        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments[0].isCut)
        XCTAssertEqual(segments[0].text, "umm")
        XCTAssertFalse(segments[1].isCut)
        XCTAssertEqual(segments[1].text, "let's meet at 2pm")
    }

    func testSelfCorrectionRemovalMarkedAsCut() {
        let verbatim = "meet at 1pm actually 2pm"
        let cleaned = "meet at 2pm"
        let segments = TranscriptDiffEngine.segments(verbatim: verbatim, cleaned: cleaned)

        // Verbatim words: ["meet", "at", "1pm", "actually", "2pm"]
        // Cleaned words:  ["meet", "at", "2pm"]
        // Expected diff: kept "meet at", cut "1pm actually", kept "2pm"
        XCTAssertFalse(segments.isEmpty)
        let cutSegments = segments.filter { $0.isCut }
        XCTAssertFalse(cutSegments.isEmpty)
        XCTAssertTrue(cutSegments.contains { $0.text.contains("1pm") || $0.text.contains("actually") })
    }

    func testEmptyInputs() {
        XCTAssertTrue(TranscriptDiffEngine.segments(verbatim: "", cleaned: "").isEmpty)
        XCTAssertEqual(TranscriptDiffEngine.segments(verbatim: "hello", cleaned: "").count, 1)
        XCTAssertEqual(TranscriptDiffEngine.segments(verbatim: "", cleaned: "hello").count, 1)
    }

    func testCompleteDivergenceFallsBackSafely() {
        let segments = TranscriptDiffEngine.segments(verbatim: "apples bananas cherries", cleaned: "dogs cats birds")
        // When there is no overlap, it shouldn't crash and should return the cleaned text
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "dogs cats birds")
        XCTAssertFalse(segments[0].isCut)
    }
}
