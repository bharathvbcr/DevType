import XCTest
@testable import ExpanderEngine

/// The invariant six private copies encoded: a diagnostic or usage counter must never trap
/// the process just because it ran long enough to overflow.
final class SaturatingArithmeticTests: XCTestCase {

    func testAdditionIsOrdinaryUntilItWouldOverflow() {
        XCTAssertEqual(Saturating.adding(2, 3), 5)
        XCTAssertEqual(Saturating.adding(Int.max - 1, 1), Int.max)
        XCTAssertEqual(Saturating.adding(0, Int.max), Int.max)
    }

    func testAdditionPinsAtMaxInsteadOfTrapping() {
        XCTAssertEqual(Saturating.adding(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.adding(Int.max, Int.max), Int.max)
        XCTAssertEqual(Saturating.adding(UInt64.max, 1), UInt64.max)
        XCTAssertEqual(Saturating.adding(UInt64.max, UInt64.max), UInt64.max)
    }

    /// The one behaviour that differs from the copies. Each of them returned `max` for any
    /// overflow, which is wrong for a negative delta — no current caller passes one, and a
    /// future one now gets the bound the sum actually ran past.
    func testAdditionPinsAtMinWhenANegativeDeltaUnderflows() {
        XCTAssertEqual(Saturating.adding(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.adding(Int.min + 1, -5), Int.min)
        XCTAssertEqual(Saturating.adding(-3, 1), -2, "an in-range negative sum is untouched")
    }

    func testIncrementPinsAtMax() {
        XCTAssertEqual(Saturating.incrementing(41), 42)
        XCTAssertEqual(Saturating.incrementing(Int.max), Int.max)
        XCTAssertEqual(Saturating.incrementing(UInt64.max), UInt64.max)
    }

    func testMultiplicationPinsAtTheBoundItRanPast() {
        XCTAssertEqual(Saturating.multiplying(6, 7), 42)
        XCTAssertEqual(Saturating.multiplying(Int.max, 2), Int.max)
        XCTAssertEqual(Saturating.multiplying(Int.max, -2), Int.min)
        XCTAssertEqual(Saturating.multiplying(0, Int.max), 0)
    }

    /// The reason these exist: the counters they back are unbounded in principle, and a
    /// trap in a diagnostic path would take the app down over a statistic.
    func testRepeatedIncrementAtTheCeilingNeitherTrapsNorWraps() {
        var counter = Int.max - 2
        for _ in 0..<10 { counter = Saturating.incrementing(counter) }
        XCTAssertEqual(counter, Int.max)
    }
}
