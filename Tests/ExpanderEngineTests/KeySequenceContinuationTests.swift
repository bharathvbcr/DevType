import XCTest
@testable import ExpanderEngine

final class KeySequenceContinuationTests: XCTestCase {
    func testCancellationAtEveryPairBoundaryStopsWithoutPostingMoreKeys() {
        for cancelAt in 0...8 {
            var events: [Int] = []
            let count = HIDKeyPoster.postKeyPairs(count: 8, shouldContinue: { events.count < cancelAt }) {
                events.append($0)
                return true
            }
            XCTAssertEqual(count, cancelAt)
            XCTAssertEqual(events, Array(0..<cancelAt))
        }
    }

    func testAllocationFailureStopsSequenceAndReportsPartialPost() {
        var attempts = 0
        let count = HIDKeyPoster.postKeyPairs(count: 8, shouldContinue: { true }) { index in
            attempts += 1
            return index < 3
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(attempts, 4)
    }

    func testOversizedAndInvalidBurstsAreRefusedBeforeAnyEffect() {
        for count in [Int.min, -1, 0, 4097, Int.max] {
            XCTAssertEqual(HIDKeyPoster.postKeyPairs(count: count, shouldContinue: { XCTFail(); return true }) { _ in
                XCTFail(); return true
            }, 0)
        }
    }
}
