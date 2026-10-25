import AppKit
import CoreGraphics
import SourceTreeTestSupport
import XCTest
@testable import ExpanderEngine

/// A second expansion that starts while the first one's Cmd+V has not been read must not erase its
/// trigger and then sit in the paste's publication gate. The type-ahead buffer surrenders at 0.35 s,
/// the gate can wait up to the 2 s residency ceiling, and anything typed after the surrender is
/// replayed ahead of the paste and moves the input revision — which refuses the expansion with the
/// trigger already gone. Waiting *before* the erase costs nothing a refusal cannot undo.
final class BoardHoldOffTests: XCTestCase {

    /// A scheduler the test drives by hand: `run()` fires the next scheduled step.
    private final class Steps {
        var queue: [(delay: TimeInterval, work: () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { queue.append((delay, work)) }
        func run() { queue.removeFirst().work() }
    }

    private func hold(
        remaining: [TimeInterval],
        current: @escaping () -> Bool = { true },
        steps: Steps,
        proceeded: @escaping () -> Void,
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
        var proceeded = 0
        hold(remaining: [0], steps: steps, proceeded: { proceeded += 1 }, abandoned: { XCTFail("abandoned") })
        XCTAssertEqual(proceeded, 1)
        XCTAssertTrue(steps.queue.isEmpty, "a free board costs no hop through the run loop")
    }

    func testAnUnreadPayloadHoldsTheEraseBackUntilTheBoardIsFree() {
        let steps = Steps()
        var proceeded = 0
        hold(remaining: [1.5, 1.0, 0.4, 0], steps: steps, proceeded: { proceeded += 1 },
             abandoned: { XCTFail("abandoned") })
        XCTAssertEqual(proceeded, 0, "the trigger is still in the field while the board is busy")
        steps.run(); steps.run()
        XCTAssertEqual(proceeded, 0)
        steps.run()
        XCTAssertEqual(proceeded, 1)
        XCTAssertTrue(steps.queue.isEmpty)
    }

    /// The poll interval is the witness poll, never the whole remaining wait: a read ends the gate
    /// early, and the wait must notice.
    func testEachStepIsOnePollAndNeverTheWholeRemainingWait() {
        let steps = Steps()
        hold(remaining: [1.5, 1.5], steps: steps, proceeded: {}, abandoned: {})
        XCTAssertEqual(steps.queue.first?.delay ?? .infinity, InjectTiming.payloadWitnessPollInterval, accuracy: 1e-9)
        let brief = Steps()
        hold(remaining: [0.01, 0], steps: brief, proceeded: {}, abandoned: {})
        XCTAssertEqual(brief.queue.first?.delay ?? .infinity, 0.01, accuracy: 1e-9, "never longer than needed")
    }

    /// Anything that makes the operation stale during the wait ends it with nothing erased.
    func testInputDuringTheWaitAbandonsTheExpansionBeforeAnythingIsErased() {
        let steps = Steps()
        var current = true
        var abandoned = 0
        hold(remaining: [1.5, 1.4, 1.3], current: { current }, steps: steps,
             proceeded: { XCTFail("proceeded over input") }, abandoned: { abandoned += 1 })
        steps.run()
        current = false
        steps.run()
        XCTAssertEqual(abandoned, 1)
        XCTAssertTrue(steps.queue.isEmpty, "an abandoned wait stops polling")
    }

    /// Bounded even if the gate never reports free: past the residency ceiling the expansion is
    /// refused rather than waiting forever.
    func testAGateThatNeverOpensIsBounded() {
        let steps = Steps()
        var abandoned = 0
        var readings = 0
        BoardHoldOff.untilFree(
            remaining: { readings += 1; return 1 },
            stillCurrent: { true },
            schedule: steps.schedule,
            proceed: { XCTFail("proceeded with the board still busy") },
            abandon: { abandoned += 1 }
        )
        var polls = 0
        while !steps.queue.isEmpty, polls < 10_000 { steps.run(); polls += 1 }
        XCTAssertEqual(abandoned, 1)
        XCTAssertLessThanOrEqual(
            Double(polls) * InjectTiming.payloadWitnessPollInterval,
            InjectTiming.unverifiedPayloadResidencyCeiling + InjectTiming.payloadReadGrace + 1
        )
    }

    // MARK: - The broker's side of it

    private struct NoLayout: KeyboardLayoutProviding {
        func currentSourceID() -> String? { nil }
        func keyCode(for character: Character) -> CGKeyCode? { nil }
    }

    /// `publicationGateRemaining` is the existing gate, asked rather than waited on: positive while a
    /// payload ⌘V has gone out for is unread, zero once it is read and the grace has passed.
    func testTheBrokerReportsTheGateItWouldHaveWaitedOn() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var environment = PasteboardBroker.Environment()
        environment.pasteboard = { board }
        environment.canPostEvents = { true }
        environment.secureInputActive = { false }
        environment.targetCurrent = { _, _, _ in true }
        let broker = PasteboardBroker(
            hid: HIDKeyPoster(
                commandEventIO: .init(canPost: { true }, post: { _ in }, pause: {}),
                layout: KeyboardLayoutState(provider: NoLayout())
            ),
            verifier: DeliveryVerifier.shared, timing: InjectTimingStore(), environment: environment
        )
        XCTAssertEqual(broker.publicationGateRemaining(now: InputClock.monotonicNow()), 0, "nothing pending")

        board.clearContents()
        board.setString("USER-OLD", forType: .string)
        let posted = expectation(description: "posted")
        broker.pasteViaClipboard(
            text: "FIRST", expectedText: nil, baseline: nil, focus: .resolved(nil),
            completeBeforeRestore: true
        ) { _ in posted.fulfill() }
        wait(for: [posted], timeout: 5)

        let now = InputClock.monotonicNow()
        XCTAssertGreaterThan(broker.publicationGateRemaining(now: now), 0, "⌘V is out and nobody has read the payload")
        XCTAssertLessThanOrEqual(
            broker.publicationGateRemaining(now: now), InjectTiming.unverifiedPayloadResidencyCeiling
        )
        XCTAssertEqual(
            broker.publicationGateRemaining(now: now + InjectTiming.unverifiedPayloadResidencyCeiling + 1), 0,
            "bounded by the lease"
        )
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
        XCTAssertTrue(body.contains("publicationGateRemaining(now:"))
        XCTAssertTrue(body.contains("refuseEntryGate("), "an abandoned wait is recorded like any entry-gate refusal")
    }
}
