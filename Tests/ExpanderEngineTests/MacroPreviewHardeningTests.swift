import XCTest
@testable import ExpanderEngine

// Editor-preview renderer runs on every manager-list row and search row, on the
// main thread. Unterminated default-off `%fillpart` sections used to trigger a
// full rescan of the remaining tokens per marker — O(n²) on pathological
// templates. These tests pin both the linear cost and the skip semantics.

final class MacroPreviewHardeningTests: XCTestCase {

    func testTerminatedDefaultOffPartIsSkipped() {
        let preview = MacroPreview.render("%fillpart:p:default=no%HIDDEN%fillpartend%VISIBLE")
        XCTAssertEqual(preview, "VISIBLE")
    }

    func testDefaultOnPartRendersThrough() {
        let preview = MacroPreview.render("%fillpart:p:default=yes%SHOWN%fillpartend%")
        XCTAssertEqual(preview, "SHOWN")
    }

    func testNestedPartsSkipAsOneBlock() {
        let content = "%fillpart:a:default=no%OUTER %fillpart:b:default=no%INNER%fillpartend% TAIL%fillpartend%END"
        XCTAssertEqual(MacroPreview.render(content), "END")
    }

    /// An unterminated default-off part skips only its own marker; following
    /// content still renders. Pre-fix this contract held but cost a full scan of
    /// the remaining tokens per marker.
    func testUnterminatedPartStillRendersFollowingContent() {
        // Separators are required: adjacent `%…%%…%` merges into one macro body
        // under §3.6 escaping.
        let content = Array(repeating: "%fillpart:p:default=no%", count: 3).joined(separator: " ") + " VISIBLE"
        XCTAssertEqual(MacroPreview.render(content), "   VISIBLE")
    }

    /// 20k unterminated parts ≈ 2×10⁸ switch iterations pre-fix (multi-second
    /// main-thread stall in the editor); linear matching is microseconds.
    ///
    /// The bound is deliberately loose wall clock (2s), not a performance budget:
    /// this test exists to catch the quadratic rescan coming back, which turns
    /// these renders into *seconds* even unloaded. A tight bound only measures
    /// machine load — it false-alarmed at 0.43s in a loaded full-suite run while
    /// the true regression would still blow past 2s by orders of magnitude.
    func testManyUnterminatedPartsDoNotRegressToQuadratic() {
        // Separators required — see the three-part test above.
        let content = Array(repeating: "%fillpart:p:default=no%", count: 20_000).joined(separator: " ") + " VISIBLE"
        let started = Date()
        let preview = MacroPreview.render(content)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(preview, String(repeating: " ", count: 19_999) + " VISIBLE")
        XCTAssertLessThan(elapsed, 2.0, "render took \(elapsed)s — quadratic behavior is back")
    }
}
