import XCTest
@testable import ExpanderEngine

/// Guards the double-injection shape: `ScholarLM` inserted, then inserted again.
///
/// The injection pipeline tries a transactional AX range replace first and falls back to
/// HID backspaces + paste when that does not report `.replaced`. The fallback is safe only
/// because the guarded erase re-verifies the trigger is still in front of the caret.
///
/// The hole was `.unavailable`. It means "AX could not tell us", and for an untouched field
/// proceeding best-effort is right. After an *attempted* AX write it is not: Safari, Chromium
/// and Electron report a stale or virtualised `AXValue` immediately after a real edit, so a
/// mutation that actually landed reads as unverifiable — and the fallback would erase the
/// trigger (already gone) and paste the expansion a second time.
final class DoubleInjectGuardTests: XCTestCase {

    private let plan = ErasePlan(text: "`slm")

    // MARK: - The distinction the flag encodes

    func testUnavailableDoesNotBlockAnUntouchedField() {
        // No write attempted: best-effort remains correct for AX-opaque hosts, which is the
        // pre-existing behaviour every terminal and Electron app relies on.
        XCTAssertFalse(
            ErasePreconditionResult.unavailable("AXValue unreadable").blocksErase,
            "Unverifiable state alone must not refuse — that would break AX-opaque hosts."
        )
    }

    func testMismatchAlwaysBlocks() {
        XCTAssertTrue(
            ErasePreconditionResult.mismatch("field holds \"x\", expected \"`slm\"").blocksErase
        )
    }

    func testOkNeverBlocks() {
        XCTAssertFalse(ErasePreconditionResult.ok.blocksErase)
    }

    // MARK: - The precondition still catches an already-applied AX edit

    /// When AX *is* readable, the guard already refuses: after a successful replace the field
    /// holds the expansion, not the trigger, so the window comparison mismatches. This is the
    /// path that was always safe — the regression risk lives in the unreadable case above.
    func testFieldHoldingTheExpansionMismatchesTheTriggerPlan() {
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "ScholarLM",
            caretLocation: 9,
            selectionLength: 0
        )
        guard case .mismatch = result else {
            return XCTFail("A field already holding the expansion must not be erased again, got \(result).")
        }
    }

    /// The double-insert shape itself: if the first expansion landed and a second erase+paste
    /// were allowed, the field would read "ScholarLMScholarLM". Verify the checker refuses to
    /// authorise the erase that would precede it.
    func testDoubledFieldDoesNotLookLikeAValidTriggerErase() {
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "ScholarLMScholarLM",
            caretLocation: 18,
            selectionLength: 0
        )
        guard case .mismatch = result else {
            return XCTFail("Expected a mismatch for an already-doubled field, got \(result).")
        }
    }

    /// An unreadable field yields `.unavailable`, *not* `.mismatch` — which is exactly why the
    /// `afterPossibleWrite` flag is needed rather than tightening `blocksErase` globally.
    func testUnreadableFieldYieldsUnavailableNotMismatch() {
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: nil,
            caretLocation: 4,
            selectionLength: 0
        )
        guard case .unavailable = result else {
            return XCTFail("Unreadable AXValue must be .unavailable, got \(result).")
        }
    }

    /// Virtualised hosts report an empty value with a caret at 0. Same conclusion.
    func testVirtualisedFieldYieldsUnavailable() {
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "",
            caretLocation: 0,
            selectionLength: 0
        )
        guard case .unavailable = result else {
            return XCTFail("A virtualised snapshot must be .unavailable, got \(result).")
        }
    }

    /// The still-untouched case must remain erasable, or every expansion would refuse.
    func testFieldStillHoldingTheTriggerIsOK() {
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "type `slm",
            caretLocation: 9,
            selectionLength: 0
        )
        XCTAssertEqual(result, .ok)
    }

    // MARK: - Write provenance: the other half of the flag

    /// The inverse bug, from a second field report: a Chrome PWA (GitHub) with no readable
    /// focused element. `performAXRangeReplace` returned before issuing any write, the pipeline
    /// still set `afterPossibleWrite`, the precondition read `.unavailable` for the same reason
    /// the write never started — and a field that was provably untouched refused to expand.
    /// The flag must come from the outcome's provenance, not from "we called the writer".
    func testOnlyOutcomesThatReachedTheFieldCountAsPossibleWrites() {
        XCTAssertFalse(
            AXTextWriter.AXReplaceOutcome.notAttempted("no focused element").fieldMayHaveMutated,
            "A writer that bailed before any set is not a write — treating it as one turns "
                + "every AX-opaque host into a refused expand."
        )
        XCTAssertFalse(
            AXTextWriter.AXReplaceOutcome
                .notAttempted("learned false-success for x role AXTextArea").fieldMayHaveMutated
        )
        XCTAssertTrue(
            AXTextWriter.AXReplaceOutcome.unavailable("setSelectedText failed (-25204)")
                .fieldMayHaveMutated,
            "A set that was issued and errored may still have landed; unverifiable state after "
                + "it must keep refusing."
        )
        XCTAssertTrue(AXTextWriter.AXReplaceOutcome.replaced.fieldMayHaveMutated)
        XCTAssertTrue(
            AXTextWriter.AXReplaceOutcome.falseSuccess.fieldMayHaveMutated,
            "falseSuccess means a set was issued; the value comparison says it did not stick, "
                + "but the selection was widened and restored — stay conservative."
        )
    }

    /// The pipeline must derive the flag from the outcome — a literal `afterPossibleWrite: true`
    /// is the bug shape this section exists to prevent.
    func testPipelineDerivesTheFlagFromWriteProvenance() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift")
        let source = SourceContractTests.strippingComments(
            try String(contentsOf: url, encoding: .utf8)
        )
        XCTAssertTrue(
            source.contains("attemptedAXWrite = axOutcome.fieldMayHaveMutated"),
            "The expand path must take the flag from the replace outcome."
        )
        XCTAssertFalse(
            source.contains("afterPossibleWrite: true"),
            "No caller may hardcode afterPossibleWrite — that collapses 'we called the writer' "
                + "into 'the field may have changed' and refuses provably-safe expands."
        )
        XCTAssertTrue(
            source.contains("recordUnverifiableAfterWrite"),
            "The unverifiable-after-write refusal must feed the strike ledger, or an unknown "
                + "broken shell refuses forever instead of healing on the second attempt."
        )
    }

    /// The tap's app-switch observer must wake Chromium accessibility trees for the *inject*
    /// path. `SelectionMonitor` does the same poke but only while the AI feature is enabled —
    /// plain text expansion must not depend on an unrelated feature flag for its AX visibility.
    func testEventTapWakesAccessibilityTreesOnAppSwitch() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ExpanderEngine/Engine/EventTapEngine.swift")
        let source = SourceContractTests.strippingComments(
            try String(contentsOf: url, encoding: .utf8)
        )
        XCTAssertTrue(
            source.contains("ensureManualAccessibility"),
            "Without the app-switch wake-up, a Chromium app has no focused AX element at "
                + "expand time: the erase precondition cannot verify the field and every "
                + "expansion degrades to best-effort."
        )
    }
}
