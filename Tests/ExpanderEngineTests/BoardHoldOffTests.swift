import AppKit
import CoreGraphics
import XCTest
@testable import ExpanderEngine

/// A second expansion that starts while the first one's Cmd+V has not been read must not erase its
/// trigger and then sit in the paste's publication gate. The type-ahead buffer surrenders at 0.35 s,
/// the gate can wait up to the 2 s residency ceiling, and anything typed after the surrender is
/// replayed ahead of the paste and moves the input revision — which refuses the expansion with the
/// trigger already gone. Waiting *before* the erase costs nothing a refusal cannot undo — as long
/// as the wait itself ends inside the hold, which is what `BoardHoldOff.budget` is for.
final class BoardHoldOffTests: XCTestCase {

    /// A scheduler the test drives by hand: `run()` fires the next scheduled step.
    private final class Steps {
        var queue: [(delay: TimeInterval, work: () -> Void)] = []
        var scheduled: TimeInterval = 0
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            scheduled += delay
            queue.append((delay, work))
        }
        func run() { queue.removeFirst().work() }
        func drain(limit: Int = 10_000) -> Int {
            var runs = 0
            while !queue.isEmpty, runs < limit { run(); runs += 1 }
            return runs
        }
    }

    private func hold(
        remaining: [TimeInterval],
        current: @escaping () -> Bool = { true },
        steps: Steps,
        proceeded: @escaping (Bool) -> Void,
        abandoned: @escaping () -> Void
    ) {
        var readings = remaining
        BoardHoldOff.untilFree(
            remaining: { readings.isEmpty ? 0 : readings.removeFirst() },
            stillCurrent: current,
            schedule: steps.schedule,
            proceed: proceeded,
            abandon: abandoned
        )
    }

    func testAFreeBoardProceedsAtOnceWithoutSchedulingAnything() {
        let steps = Steps()
        var waivers: [Bool] = []
        hold(remaining: [0], steps: steps, proceeded: { waivers.append($0) }, abandoned: { XCTFail("abandoned") })
        XCTAssertEqual(waivers, [false], "a free board needs no waiver: the paste's own gate is open too")
        XCTAssertTrue(steps.queue.isEmpty, "a free board costs no hop through the run loop")
    }

    func testAnUnreadPayloadHoldsTheEraseBackUntilTheBoardIsFree() {
        let steps = Steps()
        var waivers: [Bool] = []
        hold(remaining: [1.5, 1.0, 0.4, 0], steps: steps, proceeded: { waivers.append($0) },
             abandoned: { XCTFail("abandoned") })
        XCTAssertTrue(waivers.isEmpty, "the trigger is still in the field while the board is busy")
        steps.run(); steps.run()
        XCTAssertTrue(waivers.isEmpty)
        steps.run()
        XCTAssertEqual(waivers, [false], "freed inside the budget: nothing is published over")
        XCTAssertTrue(steps.queue.isEmpty)
    }

    /// The poll interval is the witness poll, never the whole remaining wait: a read ends the gate
    /// early, and the wait must notice.
    func testEachStepIsOnePollAndNeverTheWholeRemainingWait() {
        let steps = Steps()
        hold(remaining: [1.5, 1.5], steps: steps, proceeded: { _ in }, abandoned: {})
        XCTAssertEqual(steps.queue.first?.delay ?? .infinity, BoardHoldOff.pollInterval, accuracy: 1e-9)
        let brief = Steps()
        hold(remaining: [0.01, 0], steps: brief, proceeded: { _ in }, abandoned: {})
        XCTAssertEqual(brief.queue.first?.delay ?? .infinity, 0.01, accuracy: 1e-9, "never longer than needed")
    }

    /// Anything that makes the operation stale during the wait ends it with nothing erased.
    func testInputDuringTheWaitAbandonsTheExpansionBeforeAnythingIsErased() {
        let steps = Steps()
        var current = true
        var abandoned = 0
        hold(remaining: [1.5, 1.4, 1.3], current: { current }, steps: steps,
             proceeded: { _ in XCTFail("proceeded over input") }, abandoned: { abandoned += 1 })
        steps.run()
        current = false
        steps.run()
        XCTAssertEqual(abandoned, 1)
        XCTAssertTrue(steps.queue.isEmpty, "an abandoned wait stops polling")
    }

    /// A board that stays busy is published over once the budget is spent — never waited out to
    /// the residency ceiling. The wait used to run to the ceiling and then abandon: past the 0.35 s
    /// type-ahead deadline the next real key flushed the held keys into the field, moved the
    /// revision, and the expansion was refused with its swallowed terminator gone for good.
    func testABoardThatStaysBusyIsPublishedOverWhenTheBudgetIsSpent() {
        let steps = Steps()
        var waivers: [Bool] = []
        BoardHoldOff.untilFree(
            remaining: { 1 },
            stillCurrent: { true },
            schedule: steps.schedule,
            proceed: { waivers.append($0) },
            abandon: { XCTFail("abandoned a current expansion over a busy board") }
        )
        _ = steps.drain()
        XCTAssertEqual(waivers, [true], "the paste is told not to wait again after the erase")
        XCTAssertLessThanOrEqual(steps.scheduled, BoardHoldOff.budget + 1e-9)
    }

    /// The budget is what keeps the wait inside the held type-ahead, with room left for the erase
    /// and the paste that follow it.
    func testTheBudgetEndsInsideTheTypeAheadHold() {
        XCTAssertGreaterThan(BoardHoldOff.budget, 0)
        XCTAssertLessThan(BoardHoldOff.budget, TypeAheadBuffer.defaultDeadline)
        XCTAssertLessThan(
            BoardHoldOff.budget, InjectTiming.unverifiedPayloadResidencyFloor,
            "a budget past the residency floor would be the residency wait again"
        )
    }

    func testANonFiniteReadingIsNotWaitedOn() {
        let steps = Steps()
        var waivers: [Bool] = []
        hold(remaining: [.infinity], steps: steps, proceeded: { waivers.append($0) },
             abandoned: { XCTFail("abandoned") })
        XCTAssertEqual(waivers, [true])
        XCTAssertTrue(steps.queue.isEmpty)
    }

    // MARK: - The inject, end to end
    //
    // The policy above is pure. What it is *for* is an order: the wait happens before the focus
    // query, the entry gate, the precondition and the erase, so that every one of them runs after
    // the wait. These run a whole typed expansion through the pipeline while a previous
    // expansion's payload is still on the (private) board and read that order off the harness's
    // log, against the real clock the wait is polled on.

    /// Starts the second expansion once the first payload has at most `remaining` of its lease
    /// left, so the wait it needs fits inside the budget.
    private func waitUntilLeaseHas(
        atMost remaining: TimeInterval, _ harness: InjectionHarness
    ) {
        let deadline = InputClock.monotonicNow() + 2
        while harness.broker.publicationGateRemaining() > remaining, InputClock.monotonicNow() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// A board that frees inside the budget: nothing — not the focus query that feeds the gates,
    /// not the erase — happens until it has, and the expansion then completes normally.
    func testTheInjectWaitsForTheBoardBeforeAnyGateOrErase() throws {
        let harness = try InjectionHarness()
        harness.leaveAnUnreadPayload(in: self)
        waitUntilLeaseHas(atMost: 0.09, harness)
        XCTAssertGreaterThan(harness.broker.publicationGateRemaining(), 0, "the board is still busy when the inject starts")

        let run = harness.typeExpansion(in: self)

        XCTAssertEqual(run.text, "say: Sincerely, Slim")
        XCTAssertEqual(harness.focusQueries, 1)
        XCTAssertEqual(harness.focusQueriesWhileBoardBusy, 0, "the focus query ran while the board still held an unread payload")
        let firstQuery = try XCTUnwrap(harness.time(of: .focusQuery))
        let firstBackspace = try XCTUnwrap(harness.time(of: .backspace))
        let firstPayloadOut = try XCTUnwrap(harness.time(of: .chordDone))
        XCTAssertLessThanOrEqual(firstPayloadOut, firstQuery)
        XCTAssertLessThan(firstQuery, firstBackspace)
        XCTAssertEqual(harness.chords, 2)
    }

    /// A board that stays busy past the budget is published over — and the paste is told so, so it
    /// does not sit out the previous payload's lease *after* the erase: the trigger is gone by
    /// then, and the type-ahead hold has given up.
    func testASpentBudgetPublishesOverTheBoardAndThePasteDoesNotWaitAgain() throws {
        let harness = try InjectionHarness()
        harness.leaveAnUnreadPayload(in: self)
        let leaseStart = try XCTUnwrap(harness.time(of: .chordDone))
        let startedAt = InputClock.monotonicNow()
        XCTAssertGreaterThan(harness.broker.publicationGateRemaining(), BoardHoldOff.budget + 0.1)

        let run = harness.typeExpansion(in: self)

        XCTAssertEqual(run.text, "say: Sincerely, Slim")
        let firstQuery = try XCTUnwrap(harness.time(of: .focusQuery))
        XCTAssertGreaterThanOrEqual(firstQuery - startedAt, BoardHoldOff.budget * 0.9, "the wait spends its budget first")
        XCTAssertEqual(harness.focusQueriesWhileBoardBusy, 1, "the board was still busy when the budget ran out")
        let secondPaste = try XCTUnwrap(harness.timeOfLastPaste())
        XCTAssertLessThan(
            secondPaste - leaseStart, InjectTiming.unverifiedPayloadResidencyFloor - 0.03,
            "the paste waited out the first payload's lease after the erase instead of publishing over it: started at \(Int((startedAt - (harness.stamps.first ?? 0)) * 1000))ms; \(harness.timeline)"
        )
    }

    /// Input that arrives during the wait ends it with nothing erased: the field is exactly what
    /// the user left, and the key that was swallowed is still the caller's to put back.
    func testInputDuringTheWaitInThePipelineErasesNothing() throws {
        let harness = try InjectionHarness()
        harness.leaveAnUnreadPayload(in: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { harness.pipeline.noteDeliveryInput() }

        let run = harness.typeExpansion(in: self)

        guard case .refused = run.outcome else { return XCTFail("expected a refusal, got \(String(describing: run.outcome))") }
        XCTAssertEqual(harness.backspaces, 0, "an abandoned wait erases nothing")
        XCTAssertEqual(harness.focusQueries, 0, "and never reaches the gates that follow it")
        XCTAssertEqual(run.text, "say: `slm", "the trigger is still in the field")
        XCTAssertEqual(harness.chords, 1, "only the earlier payload's ⌘V went out")
    }

    /// The only inject that skips the wait is one that erases nothing: an insert at the caret has
    /// no trigger to protect and no hole to leave, so it queries focus at once.
    func testAnInsertThatErasesNothingDoesNotWait() throws {
        let harness = try InjectionHarness()
        harness.leaveAnUnreadPayload(in: self)

        harness.typeExpansion(in: self, erasing: false)

        // Judged on the board, not the clock: focus was queried while the earlier payload still
        // held it, which a wait could not have allowed. A loaded machine stretches main-queue
        // timers, so an elapsed-time threshold would fail an insert that never waited.
        XCTAssertNotNil(harness.time(of: .focusQuery))
        XCTAssertEqual(harness.focusQueriesWhileBoardBusy, 1, "it queried focus without waiting for the board")
        XCTAssertEqual(harness.backspaces, 0)
    }
}
