import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// §8.3: one settle-and-retry policy for the focus query and the erase guard.
///
/// The focus query used to retry `.cannotComplete` **only on main**, by `Thread.sleep`-ing there
/// for 30 ms while the event tap could not run — and off-main callers never got the retry. The
/// erase guard had already been fixed to the inverse shape. These pin the shared rule: never
/// sleep on main, retry once off main, and schedule (not sleep) the retry for main callers that
/// ask for it.
final class AXSettleRetryTests: XCTestCase {

    /// Records every sleep and scheduled retry instead of performing them.
    private final class Recorder {
        var sleeps: [TimeInterval] = []
        var scheduled: [TimeInterval] = []
        var pending: [() -> Void] = []

        func policy(mainThread: @escaping () -> Bool) -> AXSettleRetry {
            AXSettleRetry(
                isMainThread: mainThread,
                sleep: { [unowned self] in self.sleeps.append($0) },
                scheduleOnMain: { [unowned self] delay, work in
                    self.scheduled.append(delay)
                    self.pending.append(work)
                }
            )
        }
    }

    private func checker(
        _ recorder: Recorder,
        mainThread: @escaping () -> Bool,
        answers: [AXContextChecker.FocusQueryResult],
        budgets: @escaping (Float) -> Void = { _ in }
    ) -> AXContextChecker {
        var remaining = answers
        return AXContextChecker(settle: recorder.policy(mainThread: mainThread)) { timeout in
            budgets(timeout)
            return remaining.isEmpty ? .missing : remaining.removeFirst()
        }
    }

    // MARK: - Focus query

    func testATimeoutOnTheMainThreadNeverSleeps() {
        XCTAssertTrue(Thread.isMainThread, "XCTest runs this on main; the live check must see it")
        let recorder = Recorder()
        var budgets: [Float] = []
        let subject = checker(
            recorder,
            mainThread: { Thread.isMainThread },
            answers: [.axFailure(.cannotComplete), .missing],
            budgets: { budgets.append($0) }
        )

        let result = subject.queryFocusedElement()

        XCTAssertEqual(recorder.sleeps, [], "Sleeping on main stalls the event tap")
        XCTAssertEqual(recorder.scheduled, [], "The synchronous form must not schedule work either")
        XCTAssertEqual(budgets, [AXContextChecker.messagingTimeoutSeconds],
                       "On main the synchronous form returns the first answer")
        guard case .axFailure(.cannotComplete) = result else {
            return XCTFail("expected the first attempt's timeout, got \(result)")
        }
    }

    func testOffMainCallersGetTheSingleEscalatedRetry() {
        let recorder = Recorder()
        var budgets: [Float] = []
        let element = AXUIElementCreateApplication(1234)
        let subject = checker(
            recorder,
            mainThread: { false },
            answers: [.axFailure(.cannotComplete), .available(element)],
            budgets: { budgets.append($0) }
        )

        let result = subject.queryFocusedElement()

        XCTAssertEqual(recorder.sleeps, [AXSettleRetry.settleDelay])
        XCTAssertEqual(budgets, [
            AXContextChecker.focusQueryTimeout(attemptIndex: 0),
            AXContextChecker.focusQueryTimeout(attemptIndex: 1)
        ], "One retry, with the escalated budget")
        XCTAssertNotNil(result.element)
    }

    func testAnOffMainThreadReallyRetries() {
        let recorder = Recorder()
        var attempts = 0
        let subject = AXContextChecker(settle: recorder.policy(mainThread: { Thread.isMainThread })) { _ in
            attempts += 1
            return .axFailure(.cannotComplete)
        }
        let done = expectation(description: "off-main query")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = subject.queryFocusedElement()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(recorder.sleeps.count, 1)
    }

    func testOnlyAFirstAttemptTimeoutIsRetried() {
        for answer: AXContextChecker.FocusQueryResult in [
            .missing, .untrusted, .axFailure(.apiDisabled), .axFailure(.invalidUIElement)
        ] {
            let recorder = Recorder()
            var attempts = 0
            let subject = AXContextChecker(settle: recorder.policy(mainThread: { false })) { _ in
                attempts += 1
                return answer
            }
            _ = subject.queryFocusedElement()
            XCTAssertEqual(attempts, 1, "\(answer) is evidence, not a transient")
            XCTAssertEqual(recorder.sleeps, [])
        }
    }

    func testTheAsynchronousFormSchedulesTheRetryOnMainInsteadOfSleeping() {
        let recorder = Recorder()
        let element = AXUIElementCreateApplication(1234)
        let subject = checker(
            recorder,
            mainThread: { true },
            answers: [.axFailure(.cannotComplete), .available(element)]
        )
        var delivered: AXContextChecker.FocusQueryResult?
        subject.queryFocusedElement { delivered = $0 }

        XCTAssertNil(delivered, "The retry is pending, not run inline")
        XCTAssertEqual(recorder.sleeps, [])
        XCTAssertEqual(recorder.scheduled, [AXSettleRetry.settleDelay])
        recorder.pending.forEach { $0() }
        XCTAssertNotNil(delivered?.element, "The scheduled retry delivers its own answer")
    }

    func testTheAsynchronousFormAnswersInlineWhenNoRetryIsNeeded() {
        let recorder = Recorder()
        let subject = checker(recorder, mainThread: { true }, answers: [.missing])
        var delivered: AXContextChecker.FocusQueryResult?
        subject.queryFocusedElement { delivered = $0 }
        guard case .missing = delivered else { return XCTFail("expected an inline answer") }
        XCTAssertEqual(recorder.scheduled, [])
    }

    func testTheExpandGateUsesAPreResolvedFocusWithoutQuerying() {
        let queries = FocusQueryProbe.counting {
            let decision = AXContextChecker.shared.evaluateExpandGate(
                canUseAX: true, canPostEvents: true, focus: .missing
            )
            // Untrusted test hosts refuse before focus is consulted; trusted ones decide on the
            // focus handed in. Neither may ask AX again.
            XCTAssertNotNil(decision.reason)
        }
        XCTAssertEqual(queries, 0)
    }

    // MARK: - One policy, two owners

    private func mismatchingExecutor(_ settle: AXSettleRetry) -> EraseExecutor {
        EraseExecutor(
            textAccess: .init(
                value: { _ in "👩‍💻" },
                selectedRange: { _ in NSRange(location: 2, length: 0) },
                stringForRange: { _, _ in "👩" }
            ),
            settle: settle
        )
    }

    func testTheEraseGuardFollowsTheSamePolicyOnMain() {
        let recorder = Recorder()
        let result = mismatchingExecutor(recorder.policy(mainThread: { true })).evaluateErasePrecondition(
            plan: ErasePlan(text: "👩"), focus: .resolved(AXUIElementCreateApplication(1234))
        )
        XCTAssertTrue(result.blocksErase)
        XCTAssertEqual(recorder.sleeps, [], "Same rule as the focus query: no sleep on main")
    }

    func testTheEraseGuardFollowsTheSamePolicyOffMain() {
        let recorder = Recorder()
        _ = mismatchingExecutor(recorder.policy(mainThread: { false })).evaluateErasePrecondition(
            plan: ErasePlan(text: "👩"), focus: .resolved(AXUIElementCreateApplication(1234))
        )
        XCTAssertEqual(recorder.sleeps, [AXSettleRetry.settleDelay])
    }

    func testTheAsynchronousEraseGuardSchedulesThroughThePolicy() {
        let recorder = Recorder()
        var delivered: ErasePreconditionResult?
        mismatchingExecutor(recorder.policy(mainThread: { true })).evaluateErasePrecondition(
            plan: ErasePlan(text: "👩"), focus: .resolved(AXUIElementCreateApplication(1234))
        ) { delivered = $0 }
        XCTAssertNil(delivered)
        XCTAssertEqual(recorder.scheduled, [AXSettleRetry.settleDelay])
        XCTAssertEqual(recorder.sleeps, [])
    }

    func testBothOwnersShareOneSettleDelay() {
        XCTAssertEqual(AXContextChecker.focusQueryRetryDelaySeconds, AXSettleRetry.settleDelay)
        XCTAssertEqual(InjectTiming.erasePreconditionRetryDelay, AXSettleRetry.settleDelay)
    }

    /// The defect was a hand-written copy; a test of behaviour cannot see a second copy being
    /// written beside the policy. Neither owner may sleep on its own again.
    func testNeitherOwnerSleepsOutsideThePolicy() throws {
        for path in [
            "Sources/ExpanderEngine/Engine/AXContextChecker.swift",
            "Sources/ExpanderEngine/Engine/EraseExecutor.swift"
        ] {
            let source = SourceContractTests.strippingComments(try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent(path),
                encoding: .utf8
            ))
            // The one other sleep in AXContextChecker is the Chromium manual-accessibility rescue:
            // a bounded multi-poll on explicit gestures only, a different mechanism from this
            // single retry. Every *other* sleep is a hand-written copy of the policy.
            let sleeps = source.components(separatedBy: "Thread.sleep(").count - 1
            let rescuePolls = source.components(
                separatedBy: "Thread.sleep(forTimeInterval: Self.manualAccessibilityPollSeconds)"
            ).count - 1
            XCTAssertEqual(sleeps, rescuePolls, "\(path) must retry through AXSettleRetry")
            XCTAssertFalse(source.contains("Thread.isMainThread else"),
                           "\(path) must not decide the retry by thread itself")
            XCTAssertTrue(source.contains("settle.run("), "\(path) must use the shared policy")
        }
    }
}
