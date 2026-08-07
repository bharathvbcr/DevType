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
}
