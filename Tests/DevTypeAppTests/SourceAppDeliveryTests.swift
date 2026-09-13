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
        var pending: [() -> Void] = []
        var continuation: (@Sendable () -> Bool)?
        /// `nil` keeps the harness on the pre-focus-wait contract, so the original cases still
        /// describe exactly the environment they were written against.
        var axFocusOwner: pid_t??
        var axFocusProbes = 0

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
                        guard let owner = self.axFocusOwner else { return .notObserved }
                        return .owner(owner)
                    }
                ),
                onUnavailable: { self.failures += 1 },
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

    func testUnknownOwnAndTerminatedSourcesNeverActivateOrDeliver() {
        for source in [0, -1, 10, 20] as [pid_t] {
            let h = Harness()
            h.terminated = source == 20
            h.start(sourcePID: source)
            h.drain()
            XCTAssertEqual(h.deliveries, 0, "source \(source)")
            XCTAssertEqual(h.activations, 0, "source \(source)")
            XCTAssertEqual(h.failures, 1, "source \(source)")
        }
    }

    // MARK: - Waiting for AX focus to land, not just for activation

    /// The delivery operation's first act is to capture a paste target from AX. Activation
    /// reaching `NSWorkspace` does not mean the source app has published a focused element yet,
    /// and capturing in that gap produces a target the inject later refuses as "changed".
    func testDeliveryWaitsForAXFocusToReachTheSourceApp() {
        let h = Harness()
        h.frontmost = 20
        h.axFocusOwner = .some(10)  // our own panel still owns AX focus
        h.start()
        XCTAssertEqual(h.deliveries, 0, "must not capture a target while our own panel holds focus")
        h.axFocusOwner = .some(20)
        h.drain()
        XCTAssertEqual(h.deliveries, 1)
        XCTAssertEqual(h.failures, 0)
    }

    /// An app that publishes no focused element at all — common in Electron — must still be
    /// delivered into. The wait is a preference with a bound, never a new refusal.
    func testAppThatNeverPublishesFocusIsStillDeliveredAfterTheBudget() {
        let h = Harness()
        h.frontmost = 20
        h.axFocusOwner = .some(nil)
        h.start()
        let polls = h.drain()
        XCTAssertLessThanOrEqual(polls, SelectionReader.sourceFocusMaxPolls)
        XCTAssertEqual(h.deliveries, 1, "focus is preferred, not required")
        XCTAssertEqual(h.failures, 0)
    }

    /// Same for focus that lands on some third process and stays there.
    func testForeignAXFocusStillDeliversOnceTheBudgetIsSpent() {
        let h = Harness()
        h.frontmost = 20
        h.axFocusOwner = .some(30)
        h.start()
        h.drain()
        XCTAssertEqual(h.deliveries, 1)
        XCTAssertEqual(h.failures, 0)
    }

    /// A source app that never activates must not pay for AX round-trips it cannot benefit from.
    func testAXFocusIsNotProbedWhileTheSourceAppIsNotFrontmost() {
        let h = Harness()
        h.axFocusOwner = .some(20)
        h.start()
        h.drain()
        XCTAssertEqual(h.axFocusProbes, 0)
        XCTAssertEqual(h.failures, 1)
    }

    /// Focus already settled on the first look delivers immediately — the common case must not
    /// have grown a poll.
    func testSettledFocusDeliversWithoutWaiting() {
        let h = Harness()
        h.frontmost = 20
        h.axFocusOwner = .some(20)
        h.start()
        XCTAssertEqual(h.deliveries, 1)
        XCTAssertTrue(h.pending.isEmpty)
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
