import XCTest
@testable import ExpanderEngine

/// §2.6 — `verifyTextDelivery` used to do `value.contains(expectedText)` over the *entire*
/// focused field, every 50 ms of the hold loop. In a 200 KB TextEdit document that is an O(n·m)
/// scan on main. The bounded form must never turn "too large to judge" into `false`, because
/// `false` is what re-pastes and duplicates the user's text.
final class DeliveryVerifierBoundedContainsTests: XCTestCase {

    private func large(_ filler: Character = "a", units: Int) -> String {
        String(repeating: String(filler), count: units)
    }

    // MARK: - Small fields: exact `contains` semantics

    func testEmptyNeedleIsAlwaysContained() {
        XCTAssertEqual(DeliveryVerifier.boundedContains("", in: "anything", caretLocation: nil), true)
        XCTAssertEqual(DeliveryVerifier.boundedContains("", in: "", caretLocation: nil), true)
    }

    func testSmallFieldScansUnbounded() {
        XCTAssertEqual(DeliveryVerifier.boundedContains("needle", in: "a needle here", caretLocation: nil), true)
        XCTAssertEqual(DeliveryVerifier.boundedContains("needle", in: "a haystack here", caretLocation: nil), false)
        XCTAssertEqual(DeliveryVerifier.boundedContains("x", in: "", caretLocation: nil), false)
    }

    func testBoundedContainsHandlesNonBreakingSpace() {
        XCTAssertEqual(DeliveryVerifier.boundedContains("`slm ", in: "`slm\u{00A0}", caretLocation: nil), true)
        XCTAssertEqual(DeliveryVerifier.boundedContains("`slm\u{00A0}", in: "`slm ", caretLocation: nil), true)
    }


    func testSmallFieldIgnoresCaretLocation() {
        // Below the scan threshold the caret is irrelevant — the whole value is cheap to scan.
        XCTAssertEqual(DeliveryVerifier.boundedContains("needle", in: "needle at the front", caretLocation: 9_999), true)
    }

    // MARK: - Large fields

    func testLargeFieldWithNoCaretIsUndecidable() {
        let value = large(units: DeliveryVerifier.maxVerificationScanUTF16 + 10)
        XCTAssertNil(
            DeliveryVerifier.boundedContains("aaa", in: value, caretLocation: nil),
            "No caret and too large to scan means 'cannot judge', never 'missing'."
        )
    }

    func testLargeFieldFindsTextInTheCaretWindow() {
        let needle = "INSERTED"
        let head = large(units: DeliveryVerifier.maxVerificationScanUTF16)
        let value = head + needle + "tail"
        let caret = head.utf16.count + needle.utf16.count
        XCTAssertEqual(DeliveryVerifier.boundedContains(needle, in: value, caretLocation: caret), true)
    }

    func testLargeFieldReportsMissWhenTheWindowIsClean() {
        let head = large(units: DeliveryVerifier.maxVerificationScanUTF16 + 4_000)
        let caret = head.utf16.count
        XCTAssertEqual(DeliveryVerifier.boundedContains("INSERTED", in: head, caretLocation: caret), false)
    }

    func testLargeFieldIgnoresTextFarOutsideTheCaretWindow() {
        // The needle sits at the very start; the caret is far past the slack window, so the
        // bounded scan legitimately does not see it.
        let needle = "INSERTED"
        let tail = large(units: DeliveryVerifier.maxVerificationScanUTF16 + 8_000)
        let value = needle + tail
        let caret = value.utf16.count
        XCTAssertEqual(DeliveryVerifier.boundedContains(needle, in: value, caretLocation: caret), false)
    }

    func testOutOfRangeCaretIsUndecidable() {
        let value = large(units: DeliveryVerifier.maxVerificationScanUTF16 + 10)
        XCTAssertNil(DeliveryVerifier.boundedContains("aaa", in: value, caretLocation: -1))
        XCTAssertNil(DeliveryVerifier.boundedContains("aaa", in: value, caretLocation: value.utf16.count + 1))
    }

    func testCaretAtZeroInALargeFieldStillProducesAWindow() {
        let needle = "INSERTED"
        let value = needle + large(units: DeliveryVerifier.maxVerificationScanUTF16 + 100)
        XCTAssertEqual(DeliveryVerifier.boundedContains(needle, in: value, caretLocation: 0), true)
    }

    // MARK: - The three-outcome contract

    func testVerificationTreatsUnreadableFieldsAsUnavailableNotFailed() {
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(expectedText: "x", baseline: nil, after: nil),
            .unavailable
        )
        let noValue = DeliveryVerifier.FocusedTextObservation(value: nil, selectedText: nil)
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(expectedText: "x", baseline: nil, after: noValue),
            .unavailable
        )
    }

    func testVerificationDetectsDeliveryAndMiss() {
        let after = DeliveryVerifier.FocusedTextObservation(value: "hello world", selectedText: nil)
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(expectedText: "world", baseline: nil, after: after),
            .delivered
        )
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(expectedText: "goodbye", baseline: nil, after: after),
            .failed
        )
    }

    func testLargeUnjudgeableFieldNeverReportsFailed() {
        let value = large(units: DeliveryVerifier.maxVerificationScanUTF16 + 10)
        let after = DeliveryVerifier.FocusedTextObservation(value: value, selectedText: nil, caretLocation: nil)
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(expectedText: "INSERTED", baseline: nil, after: after),
            .unavailable
        )
    }
}
