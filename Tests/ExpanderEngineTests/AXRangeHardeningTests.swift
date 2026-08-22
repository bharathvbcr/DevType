import XCTest
@testable import ExpanderEngine

// Hostile AX selected-text ranges reported by apps must never drive destructive
// arithmetic. Pre-fix, a negative location (kCFNotFound-class sentinel) widened
// the erase onto {0, L-1} — the start of the document — and Int.max-class values
// trapped inside the inject path.

final class AXRangeHardeningTests: XCTestCase {

    private func assertRange(
        _ actual: CFRange?,
        equals expected: CFRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("expected range \(expected), got nil", file: file, line: line)
        }
        XCTAssertEqual(actual.location, expected.location, "location", file: file, line: line)
        XCTAssertEqual(actual.length, expected.length, "length", file: file, line: line)
    }

    // MARK: - isUsableAXRange

    func testNormalRangesAreUsable() {
        XCTAssertTrue(AXTextWriter.isUsableAXRange(CFRange(location: 0, length: 0)))
        XCTAssertTrue(AXTextWriter.isUsableAXRange(CFRange(location: 42, length: 7)))
        XCTAssertTrue(AXTextWriter.isUsableAXRange(
            CFRange(location: AXTextWriter.maxPlausibleAXUTF16Units, length: 1)
        ))
    }

    func testNegativeLocationsAreUnusable() {
        XCTAssertFalse(AXTextWriter.isUsableAXRange(CFRange(location: -1, length: 5)))
        XCTAssertFalse(AXTextWriter.isUsableAXRange(CFRange(location: Int.min, length: 5)))
    }

    func testNegativeLengthsAreUnusable() {
        XCTAssertFalse(AXTextWriter.isUsableAXRange(CFRange(location: 5, length: -1)))
        XCTAssertFalse(AXTextWriter.isUsableAXRange(CFRange(location: 5, length: Int.min)))
    }

    func testNSNotFoundClassValuesAreUnusable() {
        XCTAssertFalse(AXTextWriter.isUsableAXRange(CFRange(location: Int.max, length: 0)))
        XCTAssertFalse(AXTextWriter.isUsableAXRange(CFRange(location: 0, length: Int.max)))
        XCTAssertFalse(AXTextWriter.isUsableAXRange(
            CFRange(location: AXTextWriter.maxPlausibleAXUTF16Units + 1, length: 1)
        ))
    }

    // MARK: - widenedRange(from:eraseCount:)

    func testWideningCoversTriggerAndSelection() {
        // Caret at 10 with a 5-unit selection; erase 4 trigger units → [6, 15).
        assertRange(
            AXTextWriter.widenedRange(from: CFRange(location: 10, length: 5), eraseCount: 4),
            equals: CFRange(location: 6, length: 9)
        )
    }

    func testWideningClampsAtFieldStart() {
        // Erase reaches past the field start: [0, len + loc).
        assertRange(
            AXTextWriter.widenedRange(from: CFRange(location: 2, length: 5), eraseCount: 10),
            equals: CFRange(location: 0, length: 7)
        )
        assertRange(
            AXTextWriter.widenedRange(from: CFRange(location: 0, length: 3), eraseCount: 4),
            equals: CFRange(location: 0, length: 3)
        )
    }

    func testNegativeEraseCountBehavesLikeZero() {
        assertRange(
            AXTextWriter.widenedRange(from: CFRange(location: 5, length: 2), eraseCount: -3),
            equals: CFRange(location: 5, length: 2)
        )
    }

    /// The data-destruction class: pre-fix this produced {0, L-1}, replacing the
    /// start of the document instead of the trigger.
    func testNegativeLocationRefusesToWiden() {
        XCTAssertNil(AXTextWriter.widenedRange(from: CFRange(location: -1, length: 500), eraseCount: 3))
    }

    /// The trap class: pre-fix `range.location - erase` overflowed inside inject.
    func testExtremeValuesRefuseToWidenInsteadOfTrapping() {
        XCTAssertNil(AXTextWriter.widenedRange(from: CFRange(location: Int.min, length: 1), eraseCount: 1))
        XCTAssertNil(AXTextWriter.widenedRange(from: CFRange(location: Int.max, length: 1), eraseCount: 1))
        XCTAssertNil(AXTextWriter.widenedRange(from: CFRange(location: 1, length: Int.max), eraseCount: 1))
        // Bounded-but-huge inputs stay on the safe path and compute exactly.
        let huge = AXTextWriter.maxPlausibleAXUTF16Units
        assertRange(
            AXTextWriter.widenedRange(from: CFRange(location: huge, length: huge), eraseCount: 2),
            equals: CFRange(location: huge - 2, length: huge + 2)
        )
    }
}
