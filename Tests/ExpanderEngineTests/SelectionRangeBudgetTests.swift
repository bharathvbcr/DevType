import XCTest
@testable import ExpanderEngine

final class SelectionRangeBudgetTests: XCTestCase {
    func testOversizedRangeListIsRefusedBeforeAnyAXRead() {
        var reads = 0
        let result = SelectionReader.gatherSelectionPieces(Array(0..<65), deadline: nil) { _ in
            reads += 1
            return "x"
        }
        XCTAssertNil(result)
        XCTAssertEqual(reads, 0)
    }

    func testFailedPieceCannotReturnAPartialSelection() {
        XCTAssertNil(SelectionReader.gatherSelectionPieces(["first", "missing", "last"], deadline: nil) {
            $0 == "missing" ? nil : $0
        })
    }

    func testExpiredDeadlineNeverReads() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = SelectionReader.gatherSelectionPieces([1], deadline: now, now: { now }) { _ in
            XCTFail("An exhausted read budget must not start another AX operation")
            return "text"
        }
        XCTAssertNil(result)
    }

    func testOneStalledPieceCannotLaunchMoreReadsOrReturnPartialText() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = now.addingTimeInterval(1)
        var reads = 0
        let result = SelectionReader.gatherSelectionPieces([1, 2, 3], deadline: deadline, now: { now }) { _ in
            reads += 1
            now = now.addingTimeInterval(2)
            return "late text"
        }
        XCTAssertNil(result)
        XCTAssertEqual(reads, 1)
    }

    func testBackgroundCallerWithoutExplicitDeadlineStillHasATimeBudget() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var reads = 0
        let result = SelectionReader.gatherSelectionPieces([1, 2, 3], deadline: nil, now: { now }) { _ in
            reads += 1
            now = now.addingTimeInterval(1)
            return "piece"
        }
        XCTAssertNil(result)
        XCTAssertEqual(reads, 2, "Background cache reads must not run all 64 potentially stalled pieces")
    }

    func testSeparatorsCountTowardTheAggregateLimit() {
        let exact = String(repeating: "x", count: SelectionReader.maxSelectionCharacters - 2)
        XCTAssertEqual(SelectionReader.gatherSelectionPieces([exact, "y"], deadline: nil) { $0 }?.count,
                       SelectionReader.maxSelectionCharacters)
        let oversized = SelectionReader.gatherSelectionPieces([exact + "x", "y"], deadline: nil) { $0 }
        XCTAssertTrue(oversized == nil, "Aggregate length must include separators")
    }

    func testAcceptedRangeOrderWhitespaceAndUnicodeArePreserved() {
        let pieces = ["  first  ", "👩‍👩‍👧‍👧", "العربية", "e\u{301}"]
        XCTAssertEqual(SelectionReader.gatherSelectionPieces(pieces, deadline: nil) { $0 },
                       pieces.joined(separator: "\n"))
        XCTAssertEqual(SelectionReader.gatherSelectionPieces(Array(repeating: "x", count: 64), deadline: nil) { $0 }?.count, 127)
    }
}
