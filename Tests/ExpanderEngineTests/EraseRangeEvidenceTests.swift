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
        var role: String?
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
                },
                role: { _ in self.role }
            ))
        }

        /// 2026-09-19 GitPulse `AXComboBox` refuse: 56-unit selected item, caret at 56,
        /// two non-ASCII whitespace units where a two-character trigger should be,
        /// range probe agrees with that stale window, trigger absent from the full scan.
        static func gitPulseComboBoxRefuse() -> (Field, ErasePlan) {
            let trigger = "`x"
            let field = Field()
            field.value = String(repeating: "x", count: 54) + "\u{00A0}\u{00A0}"
            field.range = NSRange(location: 56, length: 0)
            field.rangedText = "\u{00A0}\u{00A0}"
            field.role = "AXComboBox"
            return (field, ErasePlan(text: trigger))
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

    func testComboBoxHoldingTheTriggerStillPassesWithoutHIDDowngrade() {
        let field = Field()
        field.value = String(repeating: "x", count: 54) + "`x"
        field.range = NSRange(location: 56, length: 0)
        field.role = "AXComboBox"
        XCTAssertEqual(evaluate(field, plan: ErasePlan(text: "`x")), .ok)
        XCTAssertTrue(field.requestedRanges.isEmpty)
        XCTAssertFalse(evaluate(field, plan: ErasePlan(text: "`x")).requiresHID)
    }

    func testGitPulseComboBoxStaleSelectedItemDoesNotRefuseAVouchedTrigger() {
        let (field, plan) = Field.gitPulseComboBoxRefuse()
        XCTAssertEqual(field.value?.utf16.count, 56)
        XCTAssertEqual(plan.utf16Count, 2)
        let result = evaluate(field, plan: plan)
        XCTAssertFalse(result.blocksErase, "Combo box AXValue is the selected item, not the typed filter: \(result)")
        XCTAssertTrue(result.requiresHID, "A selected-item snapshot cannot authorize an AX range write.")
        guard case .unavailable(let reason) = result else {
            return XCTFail("Expected HID recovery, got \(result)")
        }
        XCTAssertTrue(reason.contains("unstableRole=AXComboBox"), reason)
        XCTAssertFalse(reason.contains("`x"), reason)
        XCTAssertFalse(reason.contains("\u{00A0}"), reason)
    }

    func testStableTextFieldWithTheSameStaleWindowStillRefuses() {
        let (field, plan) = Field.gitPulseComboBoxRefuse()
        field.role = "AXTextField"
        XCTAssertTrue(evaluate(field, plan: plan).blocksErase)
        field.role = "AXTextArea"
        XCTAssertTrue(evaluate(field, plan: plan).blocksErase)
        field.role = "AXSearchField"
        XCTAssertTrue(evaluate(field, plan: plan).blocksErase)
        field.role = nil
        XCTAssertTrue(evaluate(field, plan: plan).blocksErase)
    }

    func testUnstableRoleRecoveryCannotBeBorrowedByUndoOrVoice() {
        let (field, plan) = Field.gitPulseComboBoxRefuse()
        XCTAssertTrue(evaluate(field, plan: plan, vouched: false).blocksErase)
        XCTAssertTrue(field.requestedRanges.isEmpty)
        let undo = field.executor().evaluateErasePrecondition(
            plan: plan, element: AXUIElementCreateApplication(1234), retryOnMismatch: false,
            insertionPointFollowsExpectedText: true,
            intent: .undo(inputEventsSinceExpansion: 0)
        )
        XCTAssertTrue(undo.blocksErase)
    }

    func testUnstableRoleWithAnActiveSelectionStillRefuses() {
        let (field, plan) = Field.gitPulseComboBoxRefuse()
        field.range = NSRange(location: 56, length: 2)
        XCTAssertTrue(evaluate(field, plan: plan).blocksErase)
    }

    func testEveryUnstableRoleRecoversTheGitPulseShape() {
        let (field, plan) = Field.gitPulseComboBoxRefuse()
        for role in AXWriteCapabilityStore.axWriteUnstableRoles {
            field.role = role
            field.requestedRanges = []
            let result = evaluate(field, plan: plan)
            XCTAssertFalse(result.blocksErase, role)
            XCTAssertTrue(result.requiresHID, role)
            XCTAssertTrue(field.requestedRanges.isEmpty, "Unstable roles must not pay for a selected-item range read: \(role)")
        }
    }

    func testUnstableRoleHIDRecoveryStillPostsGraphemesAndHonoursContext() {
        let (field, plan) = Field.gitPulseComboBoxRefuse()
        let evidence = evaluate(field, plan: plan)
        XCTAssertTrue(evidence.requiresHID)
        for afterWrite in [false, true] {
            for current in [false, true] {
                let poster = Poster()
                var completions: [Bool] = []
                EraseExecutor(hid: poster).finishGuardedErase(
                    plan: plan, afterPossibleWrite: afterWrite, result: evidence,
                    canProceed: { current }, onUnverifiableAfterWrite: nil,
                    completion: { completions.append($0) }
                )
                let allowed = current && !afterWrite
                XCTAssertEqual(completions, [allowed], "afterWrite=\(afterWrite) current=\(current)")
                XCTAssertEqual(poster.counts, allowed ? [plan.backspaceCount] : [])
            }
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
