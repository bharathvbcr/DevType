import ApplicationServices
import Foundation
import XCTest
@testable import ExpanderEngine

final class EraseRangeEvidenceTests: XCTestCase {
    private final class Poster: BackspacePosting {
        var counts: [Int] = []
        func sendBackspaces(count: Int) -> Int { counts.append(count); return count }
        func sendBackspacesAsync(count: Int, completion: @escaping (Bool) -> Void) {
            counts.append(count)
            completion(true)
        }
    }

    private final class Field {
        // Shape from the report: 49 UTF-16 units, a caret at 49, and six whitespace
        // units (three NBSP) where the six-character trigger should have been.
        var value: String? = String(repeating: "x", count: 43) + " \u{00A0} \u{00A0} \u{00A0}"
        var range: NSRange? = NSRange(location: 49, length: 0)
        var rangedText: String? = "`addrx"
        var afterRangeRead: (() -> Void)?
        var requestedRanges: [NSRange] = []

        func executor() -> EraseExecutor {
            EraseExecutor(textAccess: .init(
                value: { _ in self.value },
                selectedRange: { _ in self.range },
                stringForRange: { _, range in
                    self.requestedRanges.append(range)
                    self.afterRangeRead?()
                    return self.rangedText
                }
            ))
        }
    }

    private func evaluate(
        _ field: Field, plan: ErasePlan = ErasePlan(text: "`addrx"), vouched: Bool = true
    ) -> ErasePreconditionResult {
        // Only the injected reader sees this handle. No AX request or key post is made.
        field.executor().evaluateErasePrecondition(
            plan: plan, element: AXUIElementCreateApplication(1234), retryOnMismatch: false,
            insertionPointFollowsExpectedText: vouched
        )
    }

    func testStaleWhitespaceValueRecoversOnlyWithMatchingCaretRangeEvidence() {
        let field = Field()
        let result = evaluate(field)
        XCTAssertFalse(result.blocksErase)
        XCTAssertTrue(result.requiresHID, "Conflicting AX views cannot authorize an AX range write.")
        XCTAssertEqual(field.requestedRanges, [NSRange(location: 43, length: 6)])
    }

    func testReadableWhitespaceMismatchWithoutCorroborationStillRefuses() {
        for text: String? in [nil, "", "      ", "`other", "prefix `addrx", "`addrx suffix"] {
            let field = Field()
            field.rangedText = text
            XCTAssertTrue(evaluate(field).blocksErase, "Unproven range: \(String(describing: text))")
        }
    }

    func testValidValueDoesNotPayForAnotherTextRead() {
        let field = Field()
        field.value = String(repeating: "x", count: 43) + "`addrx"
        XCTAssertEqual(evaluate(field), .ok)
        XCTAssertTrue(field.requestedRanges.isEmpty)
    }

    func testCaretChangeDuringCorroborationRefuses() {
        for changed: NSRange? in [nil, NSRange(location: 48, length: 0), NSRange(location: 49, length: 1)] {
            let field = Field()
            field.afterRangeRead = { [weak field] in field?.range = changed }
            XCTAssertTrue(evaluate(field).blocksErase)
        }
    }

    func testUndoAndVoiceCannotBorrowTheTypedCaretVouch() {
        let field = Field()
        XCTAssertTrue(evaluate(field, vouched: false).blocksErase)
        XCTAssertTrue(field.requestedRanges.isEmpty)
    }

    func testCorroborationUsesTheExistingUnicodeAndCaseComparison() {
        for (expected, actual) in [("🎓abc", "🎓abc"), ("e\u{0301}abc", "e\u{0301}abc"),
                                   ("ab cd", "ab\u{00A0}cd"), ("`addrx", "`ADDRX")] {
            let field = Field()
            field.rangedText = actual
            let result = evaluate(field, plan: ErasePlan(text: expected, caseInsensitive: true))
            XCTAssertFalse(result.blocksErase)
            XCTAssertTrue(result.requiresHID)
            XCTAssertEqual(field.requestedRanges, [NSRange(location: 49 - expected.utf16.count,
                                                          length: expected.utf16.count)])
        }
        let field = Field()
        field.rangedText = "`ADDRX"
        XCTAssertTrue(evaluate(field).blocksErase)
    }

    func testRecoveredEvidenceCannotPostAfterAWriteOrAContextChange() {
        let plan = ErasePlan(text: "🎓abc")
        let field = Field()
        field.rangedText = plan.expectedText
        let evidence = evaluate(field, plan: plan)
        XCTAssertTrue(evidence.requiresHID)
        for afterWrite in [false, true] {
            for current in [false, true] {
                let poster = Poster()
                let executor = EraseExecutor(hid: poster)
                var completions: [Bool] = []
                executor.finishGuardedErase(
                    plan: plan, afterPossibleWrite: afterWrite, result: evidence,
                    canProceed: { current }, onUnverifiableAfterWrite: nil,
                    completion: { completions.append($0) }
                )
                let allowed = current && !afterWrite
                XCTAssertEqual(completions, [allowed])
                XCTAssertEqual(poster.counts, allowed ? [4] : [], "Use graphemes, never five UTF-16 units.")
            }
        }
    }

    func testSelectedInvalidAndUnboundedRangesNeverRequestCorroboration() {
        for range: NSRange? in [nil, NSRange(location: 49, length: 1),
                                NSRange(location: 0, length: 0), NSRange(location: NSNotFound, length: 0)] {
            let field = Field()
            field.range = range
            _ = evaluate(field)
            XCTAssertTrue(field.requestedRanges.isEmpty)
        }
        for plan in [ErasePlan.counted(6),
                     ErasePlan(expectedText: "`addrx", utf16Count: 5, backspaceCount: 6),
                     ErasePlan(expectedText: "`addrx", utf16Count: 6, backspaceCount: 7),
                     ErasePlan(text: String(repeating: "y", count: DeliveryVerifier.maxVerificationScanUTF16 + 1))] {
            let field = Field()
            field.value = String(repeating: "x", count: DeliveryVerifier.maxVerificationScanUTF16 + 100)
            field.range = NSRange(location: field.value?.utf16.count ?? 0, length: 0)
            _ = evaluate(field, plan: plan)
            XCTAssertTrue(field.requestedRanges.isEmpty)
        }
    }

    func testRangeDiagnosticsDistinguishMissingWrongAndRacingEvidenceWithoutText() {
        for (text, expectedStatus): (String?, String) in [(nil, "unavailable"), ("PRIVATE", "invalidLength"),
                                                          ("SECRET", "mismatch"), ("`addrx", "selectionChanged")] {
            let field = Field()
            field.rangedText = text
            if expectedStatus == "selectionChanged" {
                field.afterRangeRead = { [weak field] in field?.range = nil }
            }
            guard case .mismatch(let reason) = evaluate(field) else { return XCTFail("Expected refusal") }
            XCTAssertTrue(reason.contains("rangeProbe=\(expectedStatus)"), reason)
            XCTAssertFalse(reason.contains("PRIVATE"))
            XCTAssertFalse(reason.contains("SECRET"))
            XCTAssertFalse(reason.contains("`addrx"))
        }
    }
}
