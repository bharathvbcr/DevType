import ApplicationServices
import XCTest
@testable import ExpanderEngine

final class DeliveryRangeTransitionTests: XCTestCase {
    func testInsertionAndReplacementAtPinnedRangeAreConfirmed() {
        for selected in [false, true] {
            let before = DeliveryObservationFixture.at("prefix OLD suffix", 7, 3)
            let after = DeliveryObservationFixture.at("prefix payload suffix", selected ? 7 : 14, selected ? 7 : 0)
            XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(expectedText: "payload", baseline: before, after: after), .delivered)
        }
        XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(
            expectedText: "payload", baseline: DeliveryObservationFixture.at("prefix ", 7),
            after: DeliveryObservationFixture.at("prefix payload", 14)
        ), .delivered)
    }

    func testTargetChangeOrWrongRangeCannotConfirmDelivery() {
        let before = DeliveryObservationFixture.at("prefix ", 7)
        let wrongField = DeliveryObservationFixture.at("prefix payload", 14, target: AXUIElementCreateApplication(1))
        let wrongRange = DeliveryObservationFixture.at("prefix payload", 0)
        for after in [wrongField, wrongRange] {
            XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(expectedText: "payload", baseline: before, after: after), .unavailable)
        }
    }

    func testMatchingSelectionAndUnrelatedEditWithPinnedTargetRemainUnverified() {
        let before = DeliveryObservationFixture.at("payload old", 0, 7, selectedText: "payload")
        let after = DeliveryObservationFixture.at("payload new", 0, 7, selectedText: "payload")
        XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(expectedText: "payload", baseline: before, after: after), .unavailable)
        XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(expectedText: "payload", baseline: before, after: before), .unavailable)
    }

    func testLargeFieldUnicodeCoordinatesRemainOriginal() {
        let prefix = String(repeating: "İ😀e\u{301}", count: 7000)
        let offset = prefix.utf16.count
        let before = DeliveryObservationFixture.at(prefix + "OLD suffix", offset, 3)
        let after = DeliveryObservationFixture.at(prefix + "new😀 suffix", offset + 5)
        XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(expectedText: "new😀", baseline: before, after: after), .delivered)
    }

    func testInvalidOrMidSurrogateRangesAreUnavailable() {
        for range in [NSRange(location: -1, length: 0), NSRange(location: .max, length: .max),
                      NSRange(location: 1, length: 1), NSRange(location: 0, length: 50)] {
            let before = DeliveryVerifier.FocusedTextObservation(value: "😀old", selectedText: nil,
                selectedRange: range, target: DeliveryObservationFixture.target)
            XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(expectedText: "new", baseline: before,
                after: DeliveryObservationFixture.at("new", 3)), .unavailable)
        }
    }

    func testAmbiguousPartialAndDuplicateWritesNeverBecomeFailures() {
        for output in ["", "pay", "payloadpayload", "unrelated"] {
            XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(expectedText: "payload",
                baseline: DeliveryObservationFixture.at("", 0),
                after: DeliveryObservationFixture.at(output, output.utf16.count)), .unavailable)
        }
    }
}
