import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// Randomized adversarial driving of the whole focus-wait loop, not just the pure decision.
///
/// `SourceAppDelivery` is where an already-generated payload — a finished AI transform, a
/// rendered macro, a palette value — is handed to the injection pipeline. Two things must hold
/// no matter what the window server does while it runs: the payload is never handed over while
/// some other app is in front, and it is never simply dropped on the floor without the caller
/// being told. Everything below is a property over thousands of seeded random histories rather
/// than a hand-picked case.
///
/// `DEVTYPE_DELIVERY_STRESS=8 swift test --filter SourceAppDeliveryStress` runs 8× the seeds.
final class SourceAppDeliveryStressTests: XCTestCase {

    private final class Random: @unchecked Sendable {
        private let lock = NSLock()
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        func next(_ bound: Int) -> Int { bound <= 0 ? 0 : Int(next() % UInt64(bound)) }
        func pick<T>(_ options: [T]) -> T { options[next(options.count)] }
    }

    private static let ownPID: pid_t = 10
    private static let sourcePID: pid_t = 20
    private static let thirdPID: pid_t = 30

    /// One recorded history of a single `perform` run.
    private final class Trace {
        var frontmost: pid_t?
        var terminated = false
        var activations = 0
        var deliveries = 0
        var failures = 0
        var polls = 0
        var focusProbes = 0
        var pending: [() -> Void] = []
        /// What was true at the instant the payload was handed over.
        var frontmostAtDelivery: pid_t??
        var focusAtDelivery: SelectionReader.AXFocusObservation?
        var pollsAtDelivery: Int?
        var lastFocus: SelectionReader.AXFocusObservation = .notObserved
        /// Set when the focus probe ran while the source app was not frontmost — an AX
        /// round-trip nothing could act on.
        var probedWhileNotFrontmost = false
    }

    private func run(
        seed: UInt64,
        frontmostStates: [pid_t?],
        focusStates: [SelectionReader.AXFocusObservation],
        allowTermination: Bool
    ) -> Trace {
        let rng = Random(seed: seed)
        let trace = Trace()
        trace.frontmost = rng.pick(frontmostStates)

        SourceAppDelivery.perform(
            sourcePID: Self.sourcePID,
            ownPID: Self.ownPID,
            environment: .init(
                frontmostPID: { [weak trace] in
                    guard let trace else { return nil }
                    trace.polls += 1
                    return trace.frontmost
                },
                sourceTerminated: { [weak trace] in trace?.terminated ?? true },
                activate: { trace.activations += 1 },
                schedule: { _, action in
                    trace.pending.append {
                        // The window server is free to change anything between polls.
                        trace.frontmost = rng.pick(frontmostStates)
                        if allowTermination, rng.next(40) == 0 { trace.terminated = true }
                        action()
                    }
                },
                axFocus: {
                    trace.focusProbes += 1
                    if trace.frontmost != Self.sourcePID { trace.probedWhileNotFrontmost = true }
                    let focus = rng.pick(focusStates)
                    trace.lastFocus = focus
                    return focus
                }
            ),
            onUnavailable: { _ in trace.failures += 1 },
            operation: { _ in
                trace.deliveries += 1
                trace.frontmostAtDelivery = .some(trace.frontmost)
                trace.focusAtDelivery = trace.lastFocus
                trace.pollsAtDelivery = trace.polls
            }
        )

        var drains = 0
        while !trace.pending.isEmpty {
            drains += 1
            XCTAssertLessThanOrEqual(
                drains, SelectionReader.sourceFocusMaxPolls + 2,
                "seed \(seed): focus polling must have a finite budget"
            )
            guard drains <= SelectionReader.sourceFocusMaxPolls + 2 else { break }
            trace.pending.removeFirst()()
        }
        return trace
    }

    private var seedCount: Int {
        let multiplier = ProcessInfo.processInfo.environment["DEVTYPE_DELIVERY_STRESS"]
            .flatMap(Int.init) ?? 1
        return 1_500 * max(1, multiplier)
    }

    /// The two properties that matter most, over every history the environment can produce.
    ///
    /// "Exactly one terminal" is the one that keeps the user's work: a run that ends without
    /// either delivering or reporting unavailable has silently eaten a finished AI transform,
    /// which is precisely the failure mode the panel-driven paths were fixed for once already.
    func testEveryHistoryEndsInExactlyOneTerminalOutcome() {
        let everyFrontmost: [pid_t?] = [nil, ownPIDValue, sourcePIDValue, thirdPIDValue]
        let everyFocus: [SelectionReader.AXFocusObservation] = [
            .notObserved, .unfocused, .ownProcess,
            .external(element: 1), .external(element: 2), .external(element: 3),
        ]
        for seed in 1...UInt64(seedCount) {
            let trace = run(
                seed: seed,
                frontmostStates: everyFrontmost,
                focusStates: everyFocus,
                allowTermination: true
            )
            XCTAssertEqual(
                trace.deliveries + trace.failures, 1,
                "seed \(seed): delivered=\(trace.deliveries) failed=\(trace.failures)"
            )
            XCTAssertLessThanOrEqual(trace.activations, 1, "seed \(seed): activated more than once")
            XCTAssertTrue(trace.pending.isEmpty, "seed \(seed): polling never terminated")
        }
    }

    /// The safety property: a payload is only ever handed over while the source app is in front.
    /// Handing it over at any other moment types the user's text into whatever they switched to.
    func testPayloadIsNeverHandedOverWhileAnotherAppIsInFront() {
        let everyFrontmost: [pid_t?] = [nil, ownPIDValue, sourcePIDValue, thirdPIDValue]
        let everyFocus: [SelectionReader.AXFocusObservation] = [
            .notObserved, .unfocused, .ownProcess, .external(element: 1), .external(element: 2),
        ]
        for seed in 1...UInt64(seedCount) {
            let trace = run(
                seed: seed,
                frontmostStates: everyFrontmost,
                focusStates: everyFocus,
                allowTermination: false
            )
            guard let frontmostAtDelivery = trace.frontmostAtDelivery else { continue }
            XCTAssertEqual(
                frontmostAtDelivery, Self.sourcePID,
                "seed \(seed): delivered while \(String(describing: frontmostAtDelivery)) was frontmost"
            )
        }
    }

    /// Focus still inside our own panel may only be delivered through once the bounded budget
    /// is spent — never as a first choice. That is the difference between "we waited and gave
    /// up" and "we captured our own search field as the user's target".
    func testFocusInsideOurPanelOnlyDeliversAfterTheBudgetIsSpent() {
        for seed in 1...UInt64(seedCount) {
            let trace = run(
                seed: seed,
                frontmostStates: [sourcePIDValue],
                focusStates: [.ownProcess, .unfocused, .external(element: 1)],
                allowTermination: false
            )
            guard trace.deliveries == 1,
                  let focus = trace.focusAtDelivery,
                  focus == .ownProcess || focus == .unfocused,
                  let pollsAtDelivery = trace.pollsAtDelivery else { continue }
            XCTAssertGreaterThan(
                pollsAtDelivery, SelectionReader.sourceFocusMaxPolls,
                "seed \(seed): delivered on unsettled focus without spending the budget"
            )
        }
    }

    /// An app that is never frontmost must cost no AX round-trips at all. AX queries are
    /// synchronous main-thread IPC; spending them on a poll whose outcome cannot change is how
    /// a bounded wait turns into a visible hang.
    func testNeverProbesAXFocusForAnAppThatNeverComesToTheFront() {
        for seed in 1...UInt64(seedCount) {
            let trace = run(
                seed: seed,
                frontmostStates: [nil, ownPIDValue],
                focusStates: [.external(element: 1)],
                allowTermination: false
            )
            XCTAssertEqual(trace.focusProbes, 0, "seed \(seed): probed AX focus with the source app not in front")
            XCTAssertFalse(trace.probedWhileNotFrontmost, "seed \(seed)")
            XCTAssertEqual(trace.deliveries, 0, "seed \(seed)")
            XCTAssertEqual(trace.failures, 1, "seed \(seed)")
        }
    }

    /// A source app that settles immediately must not pay the budget. This is the common case —
    /// a regression here is a visible half-second stall on every AI transform.
    func testSettledSourceAppDeliversWithinTwoPolls() {
        for seed in 1...UInt64(min(seedCount, 200)) {
            let trace = run(
                seed: seed,
                frontmostStates: [sourcePIDValue],
                focusStates: [.external(element: 42)],
                allowTermination: false
            )
            XCTAssertEqual(trace.deliveries, 1, "seed \(seed)")
            XCTAssertLessThanOrEqual(
                trace.focusProbes, 2,
                "seed \(seed): a stable element must settle on the confirming poll, not ride the budget"
            )
        }
    }

    /// Terminating the source app mid-wait must abort rather than deliver into whatever
    /// inherits the front. A dead pid cannot receive a paste.
    func testSourceTerminationMidWaitAlwaysAborts() {
        for seed in 1...UInt64(min(seedCount, 500)) {
            let rng = Random(seed: seed)
            let trace = Trace()
            trace.frontmost = Self.sourcePID

            SourceAppDelivery.perform(
                sourcePID: Self.sourcePID,
                ownPID: Self.ownPID,
                environment: .init(
                    frontmostPID: { trace.frontmost },
                    sourceTerminated: { trace.terminated },
                    activate: { trace.activations += 1 },
                    schedule: { _, action in
                        trace.pending.append {
                            trace.polls += 1
                            if trace.polls >= rng.next(6) + 1 { trace.terminated = true }
                            action()
                        }
                    },
                    // Never settles, so the loop keeps polling until termination lands.
                    axFocus: {
                        trace.focusProbes += 1
                        return .external(element: UInt64(trace.focusProbes))
                    }
                ),
                onUnavailable: { _ in trace.failures += 1 },
                operation: { _ in trace.deliveries += 1 }
            )
            while !trace.pending.isEmpty { trace.pending.removeFirst()() }

            XCTAssertEqual(trace.deliveries + trace.failures, 1, "seed \(seed)")
            if trace.terminated {
                XCTAssertEqual(trace.deliveries, 0, "seed \(seed): delivered into a terminated app")
                XCTAssertEqual(trace.failures, 1, "seed \(seed)")
            }
        }
    }

    /// The continuation handed to the pipeline stays pinned to the process the payload was
    /// resolved against, for the whole life of the inject — the pipeline consults it again
    /// after its own queue and clipboard waits, long after this loop has returned.
    func testContinuationRemainsPinnedAfterDeliveryAcrossEveryFrontmostChange() {
        let trace = Trace()
        trace.frontmost = Self.sourcePID
        var continuation: (@Sendable () -> Bool)?

        SourceAppDelivery.perform(
            sourcePID: Self.sourcePID,
            ownPID: Self.ownPID,
            environment: .init(
                frontmostPID: { trace.frontmost },
                sourceTerminated: { trace.terminated },
                activate: {},
                schedule: { _, action in trace.pending.append(action) },
                axFocus: { .external(element: 1) }
            ),
            onUnavailable: { _ in trace.failures += 1 },
            operation: { continuation = $0 }
        )
        while !trace.pending.isEmpty { trace.pending.removeFirst()() }
        XCTAssertNotNil(continuation)

        for frontmost in [nil, Self.ownPID, Self.thirdPID] as [pid_t?] {
            trace.frontmost = frontmost
            XCTAssertEqual(continuation?(), false, "frontmost \(String(describing: frontmost))")
        }
        trace.frontmost = Self.sourcePID
        XCTAssertEqual(continuation?(), true)
        trace.terminated = true
        XCTAssertEqual(continuation?(), false, "a terminated source can never continue")
    }

    // MARK: - Classifying what AX focus actually reported

    /// The production classifier, which the fuzz above stubs out. Getting `.ownProcess` wrong
    /// in either direction is a real bug: call our own panel `.external` and the wait settles
    /// on DevType's own search field and captures that as the user's target; call a genuine
    /// external element `.ownProcess` and every delivery stalls for the whole budget.
    func testFocusClassificationSeparatesOurOwnPanelFromEverythingElse() {
        XCTAssertEqual(
            SourceAppDelivery.classifyFocus(elementOwner: Self.ownPID, elementIdentity: 7, ownPID: Self.ownPID),
            .ownProcess,
            "our own panel must never be offered as a capture target"
        )
        XCTAssertEqual(
            SourceAppDelivery.classifyFocus(elementOwner: Self.sourcePID, elementIdentity: 7, ownPID: Self.ownPID),
            .external(element: 7)
        )
        XCTAssertEqual(
            SourceAppDelivery.classifyFocus(elementOwner: Self.thirdPID, elementIdentity: 7, ownPID: Self.ownPID),
            .external(element: 7),
            "a helper process serving the app's AX tree is still external to us"
        )
    }

    /// No element published at all is `.unfocused`, whatever the owner field says — including
    /// the contradictory reading where an owner is known but no element is.
    func testNoPublishedElementIsAlwaysUnfocused() {
        for owner in [nil, Self.ownPID, Self.sourcePID, Self.thirdPID] as [pid_t?] {
            XCTAssertEqual(
                SourceAppDelivery.classifyFocus(elementOwner: owner, elementIdentity: nil, ownPID: Self.ownPID),
                .unfocused,
                "owner \(String(describing: owner))"
            )
        }
    }

    /// An unreadable pid resolves to "not ours" — the same rule `SelectionReader` applies to
    /// selection candidates. Failing closed here would strand deliveries into any app whose AX
    /// element does not answer `AXUIElementGetPid`, for no safety gain: the entry gate still
    /// verifies the target before anything is written.
    func testUnreadableOwnerIsTreatedAsExternalRatherThanStallingTheDelivery() {
        XCTAssertEqual(
            SourceAppDelivery.classifyFocus(elementOwner: nil, elementIdentity: 3, ownPID: Self.ownPID),
            .external(element: 3)
        )
    }

    private var ownPIDValue: pid_t? { Self.ownPID }
    private var sourcePIDValue: pid_t? { Self.sourcePID }
    private var thirdPIDValue: pid_t? { Self.thirdPID }
}
