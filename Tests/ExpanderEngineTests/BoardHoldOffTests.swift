import AppKit
import CoreGraphics
import SourceTreeTestSupport
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

    // MARK: - Wiring

    /// Before the focus query, the entry gate, the precondition and the erase: every one of them
    /// runs after the wait, which is what lets the wait be a plain hold.
    func testTheInjectWaitsForTheBoardBeforeAnyGateOrErase() throws {
        let pipeline = SourceContractTests.strippingComments(
            try SourceTree.text("Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift")
        )
        let body = try SourceTree.functionBody("private func injectOnMain(", in: pipeline)
        let wait = try XCTUnwrap(body.range(of: "BoardHoldOff.untilFree("))
        // The only inject that skips the wait is one that erases nothing (and the secure-clipboard
        // paste, which publishes a payload rather than erasing a trigger).
        XCTAssertTrue(body.contains("guard !request.erasePlan.isEmpty, !request.secureClipboardPaste else"))
        let proceed = try XCTUnwrap(body.range(of: "focusQuery {", options: .backwards))
        XCTAssertLessThan(wait.lowerBound, proceed.lowerBound, "the gated path queries focus only once the board is free")
        XCTAssertTrue(body.contains("publicationGateRemaining()"))
        XCTAssertTrue(body.contains("refuseEntryGate("), "an abandoned wait is recorded like any entry-gate refusal")
        XCTAssertTrue(body.contains("request.publicationGate = .waivedBeforeErase"),
                      "a spent budget is carried to the paste so it does not wait again after the erase")
        XCTAssertEqual(
            pipeline.components(separatedBy: "publicationGate: context.request.publicationGate").count - 1, 2,
            "both the text and the image paste of a typed expansion honour the waiver"
        )
    }
}
