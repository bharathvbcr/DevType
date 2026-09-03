import XCTest
@testable import ExpanderEngine

final class SecureInputMonitorLifecycleTests: XCTestCase {
    private static func status(_ locked: Bool) -> SecureInputMonitor.LockStatus {
        .init(isLocked: locked, holdingPID: nil, holdingAppName: nil, holdingExecutablePath: nil)
    }

    private final class Probe {
        private let lock = NSLock()
        private var locked = false
        private var reads = 0

        func set(_ value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            locked = value
        }

        func read() -> SecureInputMonitor.LockStatus {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            return SecureInputMonitorLifecycleTests.status(locked)
        }

        var readCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }
    }

    func testInvalidAndExtremeIntervalsStayBounded() {
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertEqual(SecureInputMonitor.pollingInterval(invalid), 0.35)
        }
        XCTAssertEqual(SecureInputMonitor.pollingInterval(.leastNonzeroMagnitude), 0.05)
        XCTAssertEqual(SecureInputMonitor.pollingInterval(.greatestFiniteMagnitude), 5)
        XCTAssertEqual(SecureInputMonitor.pollingInterval(0.35), 0.35)
    }

    func testOnlyFirstSampleAndTransitionsDeliverOnMain() {
        let probe = Probe()
        let monitor = SecureInputMonitor(statusProvider: probe.read)
        defer { monitor.stopMonitoring() }
        let initial = expectation(description: "initial unlocked")
        let secure = expectation(description: "entered secure")
        let released = expectation(description: "left secure")
        var delivered: [Bool] = []
        monitor.startMonitoring(interval: 0.05) { status in
            XCTAssertTrue(Thread.isMainThread)
            delivered.append(status.isLocked)
            switch delivered.count {
            case 1: initial.fulfill()
            case 2: secure.fulfill()
            case 3: released.fulfill()
            default: XCTFail("Repeated unchanged sample was delivered")
            }
        }
        wait(for: [initial], timeout: 2)
        // Let multiple identical background samples accumulate while main is busy.
        //
        // Wait for the *condition*, not for a fixed slice of wall clock. Sleeping 0.2 s and
        // asserting three reads at a 0.05 s interval asserts a timer *rate*, and GCD coalesces
        // timers under load: a quiet machine delivered four ticks, a loaded macOS 26 CI runner
        // delivered two, and the release gate went red on a test with nothing to say about the
        // change that triggered it. The property under test is that the poller keeps sampling
        // while main is blocked — and that those identical samples are not delivered, which the
        // `default:` branch above enforces. Neither depends on how fast the ticks arrive.
        //
        // `Thread.sleep` keeps main off the dispatch queue exactly as the fixed sleep did, so
        // samples still accumulate undelivered while this loop runs.
        let samplingDeadline = Date().addingTimeInterval(5)
        while probe.readCount < 3, Date() < samplingDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertGreaterThanOrEqual(
            probe.readCount, 3,
            "the poller stopped sampling while main was blocked"
        )
        XCTAssertEqual(
            delivered.count, 1,
            "identical samples must accumulate undelivered while main is blocked"
        )
        probe.set(true)
        wait(for: [secure], timeout: 2)
        probe.set(false)
        wait(for: [released], timeout: 2)
        XCTAssertEqual(delivered, [false, true, false])
    }

    func testRestartRejectsAnInFlightOldSampleAndResetsTheEdgeGate() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let probe = Probe()
        let monitor = SecureInputMonitor {
            let status = probe.read()
            if probe.readCount == 1 {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            return status
        }
        defer { monitor.stopMonitoring() }
        let obsolete = expectation(description: "old session")
        obsolete.isInverted = true
        monitor.startMonitoring(interval: 0.05) { _ in obsolete.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        monitor.stopMonitoring()
        let fresh = expectation(description: "new session's initial unchanged sample")
        monitor.startMonitoring(interval: 0.05) { status in
            XCTAssertFalse(status.isLocked)
            fresh.fulfill()
        }
        release.signal()
        wait(for: [fresh], timeout: 2)
        wait(for: [obsolete], timeout: 0.1)
    }

    func testConcurrentStartStopCannotLeaveAnObsoleteDeliveryOrTimer() {
        let monitor = SecureInputMonitor { Self.status(true) }
        let obsolete = expectation(description: "all concurrent sessions stopped")
        obsolete.isInverted = true
        DispatchQueue.concurrentPerform(iterations: 500) { iteration in
            if iteration % 3 == 0 {
                monitor.stopMonitoring()
            } else {
                monitor.startMonitoring(interval: 0.05) { _ in obsolete.fulfill() }
            }
        }
        monitor.stopMonitoring()
        wait(for: [obsolete], timeout: 0.1)
        let restarted = expectation(description: "usable after concurrent lifecycle churn")
        monitor.startMonitoring(interval: 0.05) { status in
            XCTAssertTrue(status.isLocked)
            restarted.fulfill()
        }
        wait(for: [restarted], timeout: 2)
        monitor.stopMonitoring()
    }

    func testDeinitRevokesAlreadyQueuedDelivery() {
        var monitor: SecureInputMonitor? = SecureInputMonitor { Self.status(true) }
        weak var weakMonitor = monitor
        let obsolete = expectation(description: "deallocated monitor")
        obsolete.isInverted = true
        monitor?.startMonitoring(interval: 0.05) { _ in obsolete.fulfill() }
        Thread.sleep(forTimeInterval: 0.15)
        monitor = nil
        wait(for: [obsolete], timeout: 0.1)
        XCTAssertNil(weakMonitor)
    }
}
