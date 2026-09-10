import XCTest
@testable import ExpanderEngine

final class InputBufferBoundaryTests: XCTestCase {
    func testCombiningMarkBurstCannotBypassTypeAheadStorageLimit() {
        var buffer = TypeAheadBuffer()
        let now = Date()
        buffer.beginExpansion(focusPID: 1, now: now)
        var admitted = ""
        var flushed = false
        for _ in 0..<10_000 {
            let text = "\u{0301}"
            switch buffer.admit(unicode: text, isSynthetic: false, resetsBuffer: false, focusPID: 1, now: now) {
            case .swallow: admitted += text
            case .flushThenPassThrough(let replay):
                XCTAssertEqual(replay, admitted)
                flushed = true
            case .passThrough: break
            }
            if flushed { break }
        }
        XCTAssertTrue(flushed, "A single extended grapheme cannot hold unlimited key events")
        XCTAssertLessThanOrEqual(admitted.utf16.count, 4_096)
        XCTAssertTrue(buffer.endExpansion().isEmpty, "Flushed keys must not replay twice")
    }

    func testNonfiniteHoldWindowCannotDisableTheDeadline() {
        for interval in [Double.infinity, Double.nan, -Double.infinity] {
            var buffer = TypeAheadBuffer(holdWindow: interval)
            let now = Date()
            buffer.beginExpansion(focusPID: 1, now: now)
            XCTAssertTrue(buffer.holdWindow.isFinite)
            XCTAssertEqual(buffer.admit(unicode: "x", isSynthetic: false, resetsBuffer: false,
                                        focusPID: 1, now: now.addingTimeInterval(1)),
                           .flushThenPassThrough(replay: ""))
        }
    }

    func testNegativeLayoutCapacityBehavesAsAnEmptyBuffer() {
        for capacity in [-1, Int.min, 0] {
            var buffer = LayoutBuffer(maxCount: capacity)
            buffer.appendLiteral(composed: "a", physical: "a")
            XCTAssertTrue(buffer.isEmpty)
            XCTAssertEqual(buffer.physical, "")
        }
    }
}
