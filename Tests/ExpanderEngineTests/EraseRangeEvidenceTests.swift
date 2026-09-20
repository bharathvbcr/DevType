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
        /// `nil` reproduces an AX boundary that could not answer the settability question.
        var acceptsTextMutation: Bool?
        var afterRangeRead: (() -> Void)?
        var requestedRanges: [NSRange] = []
        var mutationProbes = 0

        func executor() -> EraseExecutor {
            EraseExecutor(textAccess: .init(
                value: { _ in self.value },
                selectedRange: { _ in self.range },
                stringForRange: { _, range in
                    self.requestedRanges.append(range)
                    self.afterRangeRead?()
                    return self.rangedText
                },
                role: { _ in self.role },
                acceptsTextMutation: { _ in
                    self.mutationProbes += 1
                    return self.acceptsTextMutation
                }
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

        /// 2026-09-20 GitPulse refuse, reproduced from the field report verbatim:
        /// `actualChars=6 actualWhitespace=4 actualNonASCIIWhitespace=2 … expectedChars=6
        /// expectedWhitespace=0 … caret=21 selection=0 valueUTF16=21 expectedTextInScan=absent
        /// scan=full; rangeProbe=mismatch`.
        ///
        /// Same shape as the combo-box incident, but the role was *not* one the closed list
        /// named — the refuse reason ends `rangeProbe=mismatch`, and the role branch returns
        /// before the probe, so it provably never fired.
        static func gitPulseTerminalRefuse() -> (Field, ErasePlan) {
            // 6 units: two non-whitespace, four whitespace of which two are non-ASCII.
            let window = "a\u{00A0} \u{00A0} b"
            let field = Field()
            field.value = String(repeating: "x", count: 15) + window
            field.range = NSRange(location: 21, length: 0)
            field.rangedText = window
            field.role = "AXGroup"
            field.acceptsTextMutation = false
            return (field, ErasePlan(text: ";addr1"))
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

    // MARK: - 2026-09-20: a projection under a role the closed list never named

    /// The regression. Before the fix this refused: the value is a padded projection, the range
    /// probe agrees with it, the trigger is absent from a full scan, and `AXGroup` is in neither
    /// the unstable-role list nor the text-entry list — so nothing downgraded it.
    func testReadOnlyProjectionUnderAnUnnamedRoleRecoversTheVouchedTrigger() {
        let (field, plan) = Field.gitPulseTerminalRefuse()
        XCTAssertEqual(field.value?.utf16.count, 21)
        XCTAssertEqual(field.range, NSRange(location: 21, length: 0))
        XCTAssertEqual(plan.utf16Count, 6)
        XCTAssertFalse(AXWriteCapabilityStore.isAXWriteUnstableRole(field.role),
                       "The 2026-09-19 list must not already cover this shape.")

        let result = evaluate(field, plan: plan)
        XCTAssertFalse(result.blocksErase, "A read-only projection is not evidence the field changed: \(result)")
        XCTAssertTrue(result.requiresHID, "A projection cannot authorize an AX range write.")
        guard case .unavailable(let reason) = result else {
            return XCTFail("Expected HID recovery, got \(result)")
        }
        XCTAssertTrue(reason.contains("readOnlyRole=AXGroup"), reason)
        // Never leak the user's text or the trigger into a log line.
        XCTAssertFalse(reason.contains(";addr1"), reason)
        XCTAssertFalse(reason.contains("\u{00A0}"), reason)
    }

    /// The conjunction, from both sides. Either signal alone must keep the strict refusal, or the
    /// fix would hand a genuine "your text changed" to a blind erase.
    func testEitherSignalAloneStillRefuses() {
        // Looks like a projection, but advertises a way to write text in → a real field.
        for settable in [true, nil] as [Bool?] {
            let (field, plan) = Field.gitPulseTerminalRefuse()
            field.acceptsTextMutation = settable
            XCTAssertTrue(
                evaluate(field, plan: plan).blocksErase,
                "role=AXGroup acceptsTextMutation=\(String(describing: settable)) must stay strict"
            )
        }
        // Read-only, but reports a text role → a real field that under-reports settability.
        for role in AXWriteCapabilityStore.textEntryRoles {
            let (field, plan) = Field.gitPulseTerminalRefuse()
            field.role = role
            field.acceptsTextMutation = false
            XCTAssertTrue(evaluate(field, plan: plan).blocksErase, "role=\(role) must stay strict")
        }
        // Role unreadable at all → fail-closed, whatever settability says.
        for settable in [true, false, nil] as [Bool?] {
            let (field, plan) = Field.gitPulseTerminalRefuse()
            field.role = nil
            field.acceptsTextMutation = settable
            XCTAssertTrue(evaluate(field, plan: plan).blocksErase, "unreadable role must stay strict")
        }
    }

    /// Settability is a live AX round trip on a path that already made several. Role alone
    /// decides for both named lists, and must not pay for it.
    func testSettabilityIsProbedOnlyWhenRoleCannotDecide() {
        for role in AXWriteCapabilityStore.axWriteUnstableRoles.union(AXWriteCapabilityStore.textEntryRoles) {
            let (field, plan) = Field.gitPulseTerminalRefuse()
            field.role = role
            _ = evaluate(field, plan: plan)
            XCTAssertEqual(field.mutationProbes, 0, "role=\(role) decided without a settability probe")
        }
        let (field, plan) = Field.gitPulseTerminalRefuse()
        _ = evaluate(field, plan: plan)
        XCTAssertEqual(field.mutationProbes, 1, "An undecidable role pays for exactly one probe")
    }

    /// Same borrowing limits the combo-box recovery already has.
    func testProjectionRecoveryCannotBeBorrowedByUndoVoiceOrASelection() {
        let (unvouched, plan) = Field.gitPulseTerminalRefuse()
        XCTAssertTrue(evaluate(unvouched, plan: plan, vouched: false).blocksErase)

        let (undoField, undoPlan) = Field.gitPulseTerminalRefuse()
        let undo = undoField.executor().evaluateErasePrecondition(
            plan: undoPlan, element: AXUIElementCreateApplication(1234), retryOnMismatch: false,
            insertionPointFollowsExpectedText: true,
            intent: .undo(inputEventsSinceExpansion: 0)
        )
        XCTAssertTrue(undo.blocksErase)

        let (selected, selectedPlan) = Field.gitPulseTerminalRefuse()
        selected.range = NSRange(location: 21, length: 2)
        XCTAssertTrue(evaluate(selected, plan: selectedPlan).blocksErase)
    }

    /// The observability half: the role that the policy branched on is in every disagreement,
    /// so a field report can say *why* a refusal happened. Its absence is what left the
    /// 2026-09-19 recovery unconfirmable from the 2026-09-20 report.
    func testEveryDisagreementCarriesTheFocusedRole() {
        var seen = Set<String>()
        for role in ["AXGroup", "AXStaticText", "AXTextField", nil] {
            for text: String? in [nil, "PRIVATE", "SECRET", "`addrx"] {
                let field = Field()
                field.role = role
                field.acceptsTextMutation = true   // keep every case on the strict path
                field.rangedText = text
                if text == "`addrx" { field.afterRangeRead = { [weak field] in field?.range = nil } }
                guard case .mismatch(let reason) = evaluate(field) else {
                    return XCTFail("Expected refusal for role=\(role ?? "nil") text=\(text ?? "nil")")
                }
                XCTAssertTrue(
                    reason.contains("focusedRole=\(role ?? "unreadable")"),
                    "role=\(role ?? "nil"): \(reason)"
                )
                XCTAssertFalse(reason.contains("PRIVATE"), reason)
                XCTAssertFalse(reason.contains("SECRET"), reason)
                XCTAssertFalse(reason.contains("`addrx"), reason)
                seen.insert(role ?? "unreadable")
            }
        }
        XCTAssertEqual(seen, ["AXGroup", "AXStaticText", "AXTextField", "unreadable"])
    }

    // MARK: - Pure classifier

    func testClassifierTruthTableIsExhaustiveAndFailsClosed() {
        let roles: [String?] = [nil, "", "AXComboBox", "AXList", "AXTextField", "AXTextArea",
                                "AXSearchField", "AXSecureTextField", "AXGroup", "AXStaticText",
                                "AXWebArea", "AXScrollArea", "AXUnknown"]
        for role in roles {
            for settable in [true, false, nil] as [Bool?] {
                let authority = ErasePreconditionChecker.classifyAXValue(
                    role: role, acceptsTextMutation: settable
                )
                if AXWriteCapabilityStore.isAXWriteUnstableRole(role) {
                    XCTAssertEqual(authority, .projection("unstableRole=\(role ?? "")"),
                                   "role=\(role ?? "nil") settable=\(String(describing: settable))")
                } else if AXWriteCapabilityStore.isTextEntryRole(role) {
                    XCTAssertEqual(authority, .authoritative,
                                   "A text role owns its buffer whatever settability says")
                } else if let role, !role.isEmpty, settable == false {
                    XCTAssertEqual(authority, .projection("readOnlyRole=\(role)"))
                } else {
                    XCTAssertEqual(authority, .undetermined,
                                   "role=\(role ?? "nil") settable=\(String(describing: settable)) must fail closed")
                }
            }
        }
        // An empty role string is as unreadable as nil, and must never become a projection.
        XCTAssertEqual(ErasePreconditionChecker.classifyAXValue(role: "", acceptsTextMutation: false),
                       .undetermined)
    }

    /// `AXWebArea` is where contenteditable editors live and where the duplicate-injection
    /// incidents came from. It must stay strict unless it positively reports read-only.
    func testWebAreaStaysStrictUnlessItReportsReadOnly() {
        XCTAssertFalse(AXWriteCapabilityStore.isTextEntryRole("AXWebArea"))
        for settable in [true, nil] as [Bool?] {
            XCTAssertEqual(
                ErasePreconditionChecker.classifyAXValue(
                    role: "AXWebArea", acceptsTextMutation: settable
                ),
                .undetermined,
                "A contenteditable web area keeps the strict refusal"
            )
        }
        XCTAssertEqual(
            ErasePreconditionChecker.classifyAXValue(role: "AXWebArea", acceptsTextMutation: false),
            .projection("readOnlyRole=AXWebArea"),
            "A web area that positively reports read-only was never the typed buffer"
        )
    }
}
