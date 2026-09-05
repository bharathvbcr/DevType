import XCTest
@testable import ExpanderEngine

final class DeliveryAttributionTests: XCTestCase {
    func testExistingMatchingSelectionCannotConfirmANewPaste() {
        let same = DeliveryVerifier.FocusedTextObservation(value: "payload", selectedText: "payload")
        XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(expectedText: "payload", baseline: same, after: same), .unavailable)
    }

    func testUnrelatedEditWithAnExistingPayloadCannotConfirmANewPaste() {
        let before = DeliveryVerifier.FocusedTextObservation(value: "payload elsewhere; A", selectedText: nil)
        let after = DeliveryVerifier.FocusedTextObservation(value: "payload elsewhere; B", selectedText: nil)
        XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(expectedText: "payload", baseline: before, after: after), .unavailable)
    }

    func testMatchingContentWithoutABaselineIsUnverified() {
        let after = DeliveryVerifier.FocusedTextObservation(value: "payload", selectedText: nil)
        XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(expectedText: "payload", baseline: nil, after: after), .unavailable)
    }

    func testUnicodeExpansionBeforeCaretCannotTurnStaleTextIntoFailure() {
        let value = String(repeating: "İ", count: 1024) + String(repeating: "a", count: 33_000) + "TrIgGeR"
        let before = DeliveryVerifier.FocusedTextObservation(value: value, selectedText: nil, caretLocation: value.utf16.count)
        XCTAssertEqual(DeliveryVerifier.verifyTextDelivery(
            expectedText: "replacement", baseline: before, after: before,
            staleProbe: "trigger", staleProbeCaseInsensitive: true
        ), .unavailable)
        XCTAssertEqual(DeliveryVerifier.boundedContains(
            "trigger", in: value, caretLocation: value.utf16.count, caseInsensitive: true
        ), true)
    }

    func testAbsenceAndHistoricalTrustNeverAuthorizeAutomaticReplay() {
        for trust in [true, false] {
            for failures in 0...4 {
                for attempts in 1...3 {
                    for elapsed in [0.349, 0.350, 0.351] {
                        let decision = PasteboardBroker.decidePasteHold(
                            delivery: .failed, pasteAttemptsCompleted: attempts, maxAttempts: 3,
                            elapsed: elapsed, holdTimeout: 0.350, consecutiveFailures: failures,
                            trustFailureVerdict: trust
                        )
                        XCTAssertEqual(decision, elapsed < 0.350 ? .waitMore : .giveUpUnverified)
                    }
                }
            }
        }
    }
}
