import XCTest
@testable import ExpanderEngine

/// §8.1 regression coverage for the erase's last gate: a backspace post that silently no-ops
/// must refuse the expansion instead of injecting the replacement on top of an unerased trigger.
///
/// The incident class this closes: Post Events revoked (or every CGEvent creation failing) at
/// post time means **zero** backspaces reach the field, yet `finishGuardedErase` used to report
/// unconditional success — so the pipeline proceeded to inject and the user got
/// `trigger + replacement`. The precondition had verified the trigger was there; only the
/// posting half can know whether it actually left.
final class BackspaceIntegrityTests: XCTestCase {

    /// Records requests and reports a configurable posted count — the seam for "Post Events
    /// were revoked mid-session" without touching real HID.
    private final class FakeBackspacePoster: BackspacePosting {
        var requestedCounts: [Int] = []
        var postedToReport = 0

        func sendBackspaces(count: Int) -> Int {
            requestedCounts.append(count)
            return min(postedToReport, count)
        }

        func sendBackspacesAsync(count: Int, completion: @escaping (Bool) -> Void) {
            requestedCounts.append(count)
            let erased = count == 0 || postedToReport >= count
            DispatchQueue.main.async { completion(erased) }
        }
    }

    private func makePlan(_ text: String = "abc") -> ErasePlan {
        ErasePlan(text: text)
    }

    private func finish(
        _ executor: EraseExecutor,
        plan: ErasePlan,
        result: ErasePreconditionResult = .ok
    , file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let done = expectation(description: "finishGuardedErase completed")
        var erased: Bool?
        executor.finishGuardedErase(
            plan: plan,
            afterPossibleWrite: false,
            result: result,
            onUnverifiableAfterWrite: nil
        ) {
            erased = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(erased, "completion must run", file: file, line: line)
    }

    /// THE regression: zero backspaces posted must refuse the expand. Pre-fix this returned
    /// `true` unconditionally and the replacement landed after the untouched trigger.
    func testZeroPostedBackspacesRefuseTheExpand() throws {
        let poster = FakeBackspacePoster()
        poster.postedToReport = 0
        let executor = EraseExecutor(hid: poster)

        XCTAssertFalse(
            try finish(executor, plan: makePlan("abc")),
            "Nothing was deleted — building on this state duplicates the expansion."
        )
        XCTAssertEqual(poster.requestedCounts, [3], "The plan's full backspace count must be requested.")
    }

    /// A partial post leaves a partial trigger in the field; injecting on top of that is the
    /// same corruption shape one unit short. Refuse.
    func testPartiallyPostedBackspacesRefuseTheExpand() throws {
        let poster = FakeBackspacePoster()
        poster.postedToReport = 2
        let executor = EraseExecutor(hid: poster)

        XCTAssertFalse(
            try finish(executor, plan: makePlan("abc")),
            "2 of 3 backspaces landed — the field holds 'a' plus whatever comes next."
        )
    }

    /// The healthy path stays healthy: a fully-posted erase still reports success.
    func testFullyPostedBackspacesProceed() throws {
        let poster = FakeBackspacePoster()
        poster.postedToReport = 3
        let executor = EraseExecutor(hid: poster)

        XCTAssertTrue(try finish(executor, plan: makePlan("abc")))
    }

    /// The pre-existing refusals are untouched by the new gate.
    func testMismatchStillRefusesBeforeAnyPosting() {
        let poster = FakeBackspacePoster()
        let executor = EraseExecutor(hid: poster)

        XCTAssertFalse(try finish(executor, plan: makePlan(), result: .mismatch("field changed")))
        XCTAssertEqual(poster.requestedCounts, [], "A refused erase must not post anything.")
    }

    /// Vacuous case: an empty plan succeeds without posting — and never even reaches the
    /// posting half, because `performGuardedErase` short-circuits a zero count first.
    func testEmptyPlanSucceedsWithoutPosting() {
        let poster = FakeBackspacePoster()
        let executor = EraseExecutor(hid: poster)

        let done = expectation(description: "completed")
        executor.performGuardedErase(plan: makePlan("")) { erased in
            XCTAssertTrue(erased)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(poster.requestedCounts, [], "Nothing to erase — nothing may be posted.")
    }

    /// Real-poster contract, posting-free edge: a zero count is vacuous success.
    func testHIDKeyPosterZeroCountIsVacuouslySuccessful() {
        let done = expectation(description: "completed")
        HIDKeyPoster.shared.sendBackspacesAsync(count: 0) { erased in
            XCTAssertTrue(erased)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}

/// Pins the held-expansion cursor geometry against a plausible-looking wrong "fix": when the
/// user types a suffix while a prefix-debounced expansion is held, those keystrokes sit AFTER
/// the trigger in the field and are re-appended after the resolved text — so the {{cursor}}
/// offset, measured from the START of the resolved text, is unchanged by the suffix. Shifting
/// the offset by the suffix length would park the caret after the typed suffix instead of at
/// the marker.
final class HeldExpansionCursorGeometryTests: XCTestCase {

    func testTypedSuffixDoesNotShiftTheCursorMarker() throws {
        // "Hi {{cursor}}!" renders to "Hi !" with the caret between the space and '!'.
        let resolved = MacroRenderer.expand(content: "Hi {{cursor}}!")
        XCTAssertEqual(resolved.text, "Hi !")
        let offset = try XCTUnwrap(resolved.cursorOffset)
        XCTAssertEqual(offset, "Hi ".utf16.count)

        // The user typed "XY" during the hold: injected blob is the expansion + suffix.
        let combined = resolved.text + "XY"
        let totalUTF16 = combined.utf16.count

        // Correct math: from-end distance = total − start-offset → caret before "!XY".
        let utf16FromEnd = totalUTF16 - offset
        XCTAssertEqual(utf16FromEnd, "!XY".utf16.count)
        let arrows = HIDKeyPoster.leftArrowCount(text: combined, utf16OffsetFromEnd: utf16FromEnd)
        XCTAssertEqual(arrows, 3, "One arrow per grapheme cluster of '!XY'.")

        // If anyone "fixes" the offset by adding the suffix length, from-end collapses to 1
        // (caret after 'X') or the planner drops placement entirely — both regressions.
        XCTAssertTrue(
            InjectionPlanner.needsCursorHID(cursorOffset: offset, totalUTF16Length: totalUTF16),
            "A mid-text marker with a typed suffix still needs cursor placement."
        )
    }
}

/// §8.12 recovery-hook hygiene: resetting the telemetry log must also drop clipboard-residency
/// counters, or a "fresh" report keeps showing stale unverified-hold data from before the reset.
final class InjectTelemetryResetTests: XCTestCase {

    func testResetClearsClipboardHoldCounters() {
        let log = InjectTelemetryLog.shared
        log.recordUnverifiedClipboardHold(bundleID: "com.example.resettest", heldFor: 1.5)
        XCTAssertFalse(log.clipboardHoldsByBundle().isEmpty)

        log.reset()

        XCTAssertTrue(
            log.clipboardHoldsByBundle().isEmpty,
            "reset() is documented as a recovery hook — stale residency counters defeat it."
        )
    }
}

/// §1.1: two concurrent starters must both observe the run loop as soon as it exists. The old
/// one-shot semaphore starved the second waiter for the full timeout even though the loop came
/// up in milliseconds.
final class TapRunLoopThreadStartRaceTests: XCTestCase {

    func testConcurrentStartAndWaitBothSeeTheRunLoopQuickly() {
        let thread = TapRunLoopThread()
        defer { thread.shutdown() }

        let expA = expectation(description: "starter A")
        let expB = expectation(description: "starter B")
        DispatchQueue.global().async {
            XCTAssertNotNil(thread.startAndWait(timeout: 0.5))
            expA.fulfill()
        }
        DispatchQueue.global().async {
            XCTAssertNotNil(thread.startAndWait(timeout: 0.5))
            expB.fulfill()
        }
        wait(for: [expA, expB], timeout: 5)
    }
}
