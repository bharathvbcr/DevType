import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

final class SourceAppDeliveryTests: XCTestCase {
    private final class Harness {
        var frontmost: pid_t? = 10
        var terminated = false
        var activations = 0
        var failures = 0
        var deliveries = 0
        /// Every cause handed to `onUnavailable`, in order.
        var causes: [SelectionReader.SourceUnavailability] = []
        var pending: [() -> Void] = []
        var continuation: (@Sendable () -> Bool)?
        /// What the AX focus probe answers, poll by poll; the last entry repeats once the list
        /// runs out, so a case describes only the polls it cares about.
        ///
        /// Empty is `.notObserved` — "this caller does not probe focus" — which keeps the
        /// original cases on exactly the contract they were written against.
        var axFocus: [SelectionReader.AXFocusObservation] = []
        private var axFocusIndex = 0
        var axFocusProbes = 0

        private func nextFocus() -> SelectionReader.AXFocusObservation {
            guard !axFocus.isEmpty else { return .notObserved }
            defer { axFocusIndex += 1 }
            return axFocus[min(axFocusIndex, axFocus.count - 1)]
        }

        func start(sourcePID: pid_t = 20) {
            SourceAppDelivery.perform(
                sourcePID: sourcePID,
                ownPID: 10,
                environment: .init(
                    frontmostPID: { [weak self] in self?.frontmost },
                    sourceTerminated: { [weak self] in self?.terminated ?? true },
                    activate: { self.activations += 1 },
                    schedule: { _, action in self.pending.append(action) },
                    axFocus: { [weak self] in
                        guard let self else { return .notObserved }
                        self.axFocusProbes += 1
                        return self.nextFocus()
                    }
                ),
                onUnavailable: { self.failures += 1; self.causes.append($0) },
                operation: {
                    self.deliveries += 1
                    self.continuation = $0
                }
            )
        }

        @discardableResult
        func drain() -> Int {
            var count = 0
            while !pending.isEmpty, count < 30 {
                count += 1
                pending.removeFirst()()
            }
            XCTAssertTrue(pending.isEmpty, "Focus polling must have a finite budget")
            return count
        }
    }

    func testFailedActivationDoesNotDeliverIntoDevType() {
        let h = Harness()
        h.start()
        h.drain()
        XCTAssertEqual(h.deliveries, 0)
        XCTAssertEqual(h.failures, 1)
        XCTAssertEqual(h.activations, 1)
    }

    func testSlowActivationIsAwaitedAndDeliveredOnlyOnce() {
        let h = Harness()
        h.start()
        h.pending.removeFirst()()
        XCTAssertEqual(h.deliveries, 0)
        h.frontmost = 20
        h.drain()
        XCTAssertEqual(h.deliveries, 1)
        XCTAssertEqual(h.failures, 0)
        XCTAssertEqual(h.continuation?(), true)
    }

    func testSwitchToAnotherAppAbortsWithoutFurtherFocusTheft() {
        let h = Harness()
        h.start()
        h.frontmost = 30
        h.drain()
        XCTAssertEqual(h.deliveries, 0)
        XCTAssertEqual(h.failures, 1)
        XCTAssertEqual(h.activations, 1)
    }

    func testContinuationStaysBoundToOriginalProcessAfterHandoff() {
        let h = Harness()
        h.frontmost = 20
        h.start()
        h.drain()
        XCTAssertEqual(h.continuation?(), true)
        h.frontmost = 30
        XCTAssertEqual(h.continuation?(), false)
        h.frontmost = nil
        XCTAssertEqual(h.continuation?(), false)
        h.frontmost = 20
        h.terminated = true
        XCTAssertEqual(h.continuation?(), false)
    }

    /// The entry guard refuses four different situations, and each one reaches the caller under
    /// its own name. They used to arrive as one indistinguishable callback, which is how a
    /// refusal raised because DevType *was* the source came to be reported as the source app
    /// failing to come back to the front.
    func testEntryGuardNamesEachCauseInsteadOfCollapsingThem() {
        let cases: [(pid_t, Bool, SelectionReader.SourceUnavailability)] = [
            (0, false, .noSourceApp),
            (-1, false, .noSourceApp),
            (10, false, .ownProcess),
            (20, true, .sourceTerminated),
        ]
        for (source, terminated, expected) in cases {
            let h = Harness()
            h.terminated = terminated
            h.start(sourcePID: source)
            h.drain()
            XCTAssertEqual(h.deliveries, 0, "source \(source)")
            XCTAssertEqual(h.activations, 0, "source \(source)")
            XCTAssertEqual(h.failures, 1, "source \(source)")
            XCTAssertEqual(h.causes, [expected], "source \(source)")
        }
    }

    /// Our own process is refused *before* the source app is activated, and named as such. This
    /// is the pre-check the AI palette consults so a transform is never generated for a delivery
    /// that cannot land.
    func testOwnProcessSourceIsRefusedWithoutActivating() {
        let h = Harness()
        h.start(sourcePID: 10)
        h.drain()
        XCTAssertEqual(h.causes, [.ownProcess])
        XCTAssertEqual(h.activations, 0, "Activating ourselves would be a no-op with a cost")
        XCTAssertEqual(
            SelectionReader.SourceUnavailability.ownProcess.reason,
            "DevType was frontmost — there was no other application to insert into"
        )
    }

    /// A third app taking the front and the source never returning are different events with
    /// different answers; only the second one is about focus failing to arrive.
    func testPollTimeCausesAreDistinguished() {
        let third = Harness()
        third.frontmost = 30
        third.start()
        third.drain()
        XCTAssertEqual(third.causes, [.replacedByAnotherApp])

        let stalled = Harness()
        stalled.frontmost = 10
        stalled.start()
        stalled.drain()
        XCTAssertEqual(stalled.causes, [.focusNeverReturned])

        // Quitting mid-wait is reported as the quit, not as the budget that happened to notice it.
        let quit = Harness()
        quit.frontmost = nil
        quit.start()
        quit.terminated = true
        quit.drain()
        XCTAssertEqual(quit.causes, [.sourceTerminated])
    }

    /// Every cause carries a distinct sentence — the whole point of splitting them.
    func testEveryCauseHasItsOwnSentence() {
        let reasons = SelectionReader.SourceUnavailability.allCases.map(\.reason)
        XCTAssertEqual(
            Set(reasons).count,
            SelectionReader.SourceUnavailability.allCases.count,
            "Two causes sharing a sentence puts the report back where it started."
        )
        XCTAssertFalse(reasons.contains { $0.isEmpty })
    }

    // MARK: - Waiting for AX focus to leave our panel, not just for activation

    /// The delivery operation's first act is to capture a paste target from AX. Activation
    /// reaching `NSWorkspace` does not mean focus has left DevType yet, and capturing in that
    /// gap produces a target the inject later refuses as "changed".
    func testDeliveryWaitsForAXFocusToLeaveOurOwnPanel() {
        let h = Harness()
        h.frontmost = 20
        h.axFocus = [.ownProcess, .ownProcess, .external(element: 7), .external(element: 7)]
        h.start()
        XCTAssertEqual(h.deliveries, 0, "must not capture a target while our own panel holds focus")
        h.pending.removeFirst()()
        XCTAssertEqual(h.deliveries, 0)
        h.drain()
        XCTAssertEqual(h.deliveries, 1)
        XCTAssertEqual(h.failures, 0)
    }

    /// An app that publishes no focused element at all — common in Electron — must still be
    /// delivered into. The wait is a preference with a bound, never a new refusal.
    func testAppThatNeverPublishesFocusIsStillDeliveredAfterTheBudget() {
        let h = Harness()
        h.frontmost = 20
        h.axFocus = [.unfocused]
        h.start()
        let polls = h.drain()
        XCTAssertLessThanOrEqual(polls, SelectionReader.sourceFocusMaxPolls)
        XCTAssertEqual(h.deliveries, 1, "focus is preferred, not required")
        XCTAssertEqual(h.failures, 0)
    }

    /// Focus served by a process other than the source app is the *normal* case for WebKit:
    /// Safari publishes web-content elements from its WebContent process, so the element's pid
    /// is never Safari's. Keying the wait on the source pid made that unsatisfiable — every
    /// delivery into such an app burned the whole 500 ms budget, and the settle never engaged,
    /// leaving the refusal bug unfixed there. What matters is that focus left *us*.
    func testFocusServedByAHelperProcessSettlesInsteadOfBurningTheBudget() {
        let h = Harness()
        h.frontmost = 20
        h.axFocus = [.external(element: 99)]
        h.start()
        let polls = h.drain()
        XCTAssertEqual(h.deliveries, 1)
        XCTAssertEqual(h.failures, 0)
        XCTAssertLessThanOrEqual(polls, 2, "a stable helper-served element must settle, not wait out the budget")
    }

    /// A source app that never activates must not pay for AX round-trips it cannot benefit from.
    func testAXFocusIsNotProbedWhileTheSourceAppIsNotFrontmost() {
        let h = Harness()
        h.axFocus = [.external(element: 1)]
        h.start()
        h.drain()
        XCTAssertEqual(h.axFocusProbes, 0)
        XCTAssertEqual(h.failures, 1)
    }

    /// A caller that does not probe focus at all keeps the original contract: deliver at once.
    func testCallerThatDoesNotProbeFocusDeliversWithoutWaiting() {
        let h = Harness()
        h.frontmost = 20
        h.start()
        XCTAssertEqual(h.deliveries, 1)
        XCTAssertTrue(h.pending.isEmpty)
    }

    // MARK: - Waiting for the focused element to stop moving, not just to exist

    /// The bug this exists for: an AI transform finishes, the source app is reactivated, and the
    /// inject is refused with "target element or selection changed before insertion" — naming
    /// the user's own field as having moved when it had only just arrived.
    ///
    /// Focus leaving us was waited for; stability was not. `.external` is true from the first
    /// instant any element outside DevType is focused, and an app coming back to the front
    /// republishes its focused element while the window server finishes the switch. The
    /// delivery captured that element, the inject re-read focus a run loop later, saw a
    /// different one, and refused — throwing away a payload the user watched being generated.
    func testDeliveryWaitsForTheFocusedElementToStopMoving() {
        let h = Harness()
        h.frontmost = 20
        h.axFocus = [.external(element: 1), .external(element: 2), .external(element: 2)]
        h.start()
        XCTAssertEqual(h.deliveries, 0, "focus having left us is focus arriving, not focus settled")

        h.pending.removeFirst()()
        XCTAssertEqual(h.deliveries, 0, "a different element on the next poll is focus still moving")

        h.drain()
        XCTAssertEqual(h.deliveries, 1, "the same element twice running is a target worth capturing")
        XCTAssertEqual(h.failures, 0)
    }

    /// Focus that flicks back into our own panel mid-settle restarts the settle: `.ownProcess`
    /// is not a settled external element, and the pair either side of it is not "twice running".
    func testFocusReturningToOurPanelMidSettleDoesNotCountAsSettled() {
        let h = Harness()
        h.frontmost = 20
        h.axFocus = [
            .external(element: 5), .ownProcess, .external(element: 5),
            .external(element: 5),
        ]
        h.start()
        h.pending.removeFirst()()
        h.pending.removeFirst()()
        XCTAssertEqual(h.deliveries, 0, "a settle interrupted by our own panel is not a settle")
        h.drain()
        XCTAssertEqual(h.deliveries, 1)
    }

    /// The settle is a preference with a bound, exactly as the focus wait is. An app whose
    /// focused element never stops changing still gets the payload at the end of the budget —
    /// losing already-generated work would be a worse bug than the one this wait fixes.
    func testFocusThatNeverSettlesStillDeliversWithinTheBudget() {
        let h = Harness()
        h.frontmost = 20
        h.axFocus = (0..<40).map { .external(element: UInt64($0)) }
        h.start()
        let polls = h.drain()
        XCTAssertLessThanOrEqual(polls, SelectionReader.sourceFocusMaxPolls)
        XCTAssertEqual(h.deliveries, 1, "the settle must never become a new refusal")
        XCTAssertEqual(h.failures, 0)
    }

    /// Waiting for a settle must not hand a third app the payload: the user switching away is
    /// still an abort, not something to poll through.
    func testSwitchingAwayDuringTheSettleWaitStillAborts() {
        let h = Harness()
        h.frontmost = 20
        h.axFocus = [.external(element: 1), .external(element: 2)]
        h.start()
        XCTAssertEqual(h.deliveries, 0)
        h.frontmost = 30
        h.drain()
        XCTAssertEqual(h.deliveries, 0)
        XCTAssertEqual(h.failures, 1)
    }

    func testNilFrontmostAndSourceTerminationDuringWaitAreBounded() {
        let h = Harness()
        h.frontmost = nil
        h.start()
        let polls = h.drain()
        XCTAssertLessThanOrEqual(polls, SelectionReader.sourceFocusMaxPolls)
        XCTAssertEqual(h.deliveries, 0)
        XCTAssertEqual(h.failures, 1)

        let terminated = Harness()
        terminated.start()
        terminated.terminated = true
        terminated.drain()
        XCTAssertEqual(terminated.deliveries, 0)
        XCTAssertEqual(terminated.failures, 1)
    }
}
