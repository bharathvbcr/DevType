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

        func start(sourcePID: pid_t = 20) {
            SourceAppDelivery.perform(
                sourcePID: sourcePID,
                ownPID: 10,
                environment: .init(
                    frontmostPID: { [weak self] in self?.frontmost },
                    sourceTerminated: { [weak self] in self?.terminated ?? true },
                    activate: { self.activations += 1 },
                    schedule: { _, action in self.pending.append(action) }
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
