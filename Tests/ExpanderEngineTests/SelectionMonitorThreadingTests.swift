import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// `SelectionMonitor`'s AX observer callback runs on the main run loop. It must read no AX
/// attribute there: every round-trip (`isProcessTrusted`, focus query, owner lookup, selected
/// text) belongs on `refreshQueue`. These tests drive the callback through `Environment.axReads`
/// and record the thread each read ran on; the focus query is held on a semaphore so a handler
/// that did the read inline would hang instead of returning.
final class SelectionMonitorThreadingTests: XCTestCase {
    private final class Reads {
        private let lock = NSLock()
        private var onMain: [String] = []
        private var offMain: [String] = []
        private var frontmostOffMain = 0
        private var frontmostCalls = 0
        let gate = DispatchSemaphore(value: 0)
        let firstQueryStarted = DispatchSemaphore(value: 0)
        var blockFirstQuery = false
        private var queries = 0

        func read(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            if Thread.isMainThread { onMain.append(name) } else { offMain.append(name) }
        }

        func frontmost() -> Int {
            lock.lock(); defer { lock.unlock() }
            frontmostCalls += 1
            if !Thread.isMainThread { frontmostOffMain += 1 }
            return frontmostCalls
        }

        /// Returns true for the first query when it should be held.
        func queryStarted() -> Bool {
            lock.lock(); defer { lock.unlock() }
            queries += 1
            return queries == 1 && blockFirstQuery
        }

        var axReadsOnMain: [String] { lock.lock(); defer { lock.unlock() }; return onMain }
        var axReadsOffMain: [String] { lock.lock(); defer { lock.unlock() }; return offMain }
        var frontmostReadsOffMain: Int { lock.lock(); defer { lock.unlock() }; return frontmostOffMain }
        var frontmostReads: Int { lock.lock(); defer { lock.unlock() }; return frontmostCalls }
        var queryCount: Int { lock.lock(); defer { lock.unlock() }; return queries }
    }

    private let element = AXUIElementCreateSystemWide()

    private func makeMonitor(
        _ reads: Reads,
        enabled: Bool = true,
        selectedText: @escaping () -> String? = { "picked text" }
    ) -> SelectionMonitor {
        let defaults = UserDefaults(suiteName: "SelectionMonitorThreadingTests.\(UUID().uuidString)")!
        defaults.set(enabled, forKey: SelectionMonitor.featureEnabledDefaultsKey)
        var environment = SelectionMonitor.Environment.fixed()
        environment.frontmostBundleID = { "com.example.app.\(reads.frontmost())" }
        environment.axReads = SelectionMonitor.AXReads(
            isProcessTrusted: { reads.read("isProcessTrusted"); return true },
            queryFocusedElement: {
                reads.read("queryFocusedElement")
                if reads.queryStarted() {
                    reads.firstQueryStarted.signal()
                    reads.gate.wait()
                }
                return .available(self.element)
            },
            ownerBundleID: { _ in reads.read("ownerBundleID"); return nil },
            copySelectedText: { _, _ in reads.read("copySelectedText"); return selectedText() }
        )
        return SelectionMonitor(defaults: defaults, environment: environment)
    }

    func testNotificationHandlerReadsNoAXAttributeOnMain() {
        let reads = Reads()
        reads.blockFirstQuery = true
        let monitor = makeMonitor(reads)

        XCTAssertTrue(Thread.isMainThread)
        monitor.handleAXNotification()   // returns although the focus query is still blocked
        XCTAssertEqual(reads.firstQueryStarted.wait(timeout: .now() + 10), .success,
                       "The read must have started on the refresh queue")
        XCTAssertEqual(reads.axReadsOnMain, [], "The callback read AX on the main thread")

        reads.gate.signal()
        monitor.waitForRefreshesForTesting()
        XCTAssertEqual(reads.axReadsOnMain, [])
        XCTAssertEqual(reads.axReadsOffMain,
                       ["isProcessTrusted", "queryFocusedElement", "ownerBundleID", "copySelectedText"],
                       "The whole read ran off main, in order, with the cheap attribute first")
        XCTAssertEqual(reads.frontmostReads, 1)
        XCTAssertEqual(reads.frontmostReadsOffMain, 0, "NSWorkspace is main-only: resolved in the callback")
        XCTAssertEqual(monitor.rawCachedSelection()?.text, "picked text")
        XCTAssertEqual(monitor.rawCachedSelection()?.bundleID, "com.example.app.1")
    }

    /// A burst arriving while a read is held collapses to the running read plus ONE follow-up that
    /// carries the newest snapshot — never a backlog of stale ones overwriting it.
    func testBurstOfNotificationsCoalescesAndTheNewestWins() {
        let reads = Reads()
        reads.blockFirstQuery = true
        let monitor = makeMonitor(reads)

        monitor.handleAXNotification()
        XCTAssertEqual(reads.firstQueryStarted.wait(timeout: .now() + 10), .success)
        for _ in 0..<49 { monitor.handleAXNotification() }
        reads.gate.signal()
        monitor.waitForRefreshesForTesting()

        XCTAssertEqual(reads.queryCount, 2, "50 notifications -> the held read and one coalesced follow-up")
        XCTAssertEqual(monitor.rawCachedSelection()?.bundleID, "com.example.app.50",
                       "The follow-up must carry the newest notification's snapshot")
        XCTAssertEqual(reads.axReadsOnMain, [])
    }

    /// `stop()` while a read is in flight: the late result must not resurrect the cache.
    func testStopWhileAReadIsInFlightDropsItsResult() {
        let reads = Reads()
        reads.blockFirstQuery = true
        let monitor = makeMonitor(reads)

        monitor.handleAXNotification()
        XCTAssertEqual(reads.firstQueryStarted.wait(timeout: .now() + 10), .success)
        monitor.stop()   // main: clears and invalidates the in-flight read
        reads.gate.signal()
        monitor.waitForRefreshesForTesting()

        XCTAssertNil(monitor.rawCachedSelection(), "A read that finished after stop() stored its result")
    }

    /// A notification that was queued but not started when the monitor stopped never runs.
    func testStopDropsPendingNotifications() {
        let reads = Reads()
        reads.blockFirstQuery = true
        let monitor = makeMonitor(reads)

        monitor.handleAXNotification()
        XCTAssertEqual(reads.firstQueryStarted.wait(timeout: .now() + 10), .success)
        monitor.handleAXNotification()   // pending behind the held read
        monitor.stop()
        reads.gate.signal()
        monitor.waitForRefreshesForTesting()

        XCTAssertEqual(reads.queryCount, 1, "The pending refresh described a focus that stop() retired")
        XCTAssertNil(monitor.rawCachedSelection())
    }

    func testDisabledFeatureCostsNoHopAndNoRead() {
        let reads = Reads()
        let monitor = makeMonitor(reads, enabled: false)
        monitor.handleAXNotification()
        monitor.waitForRefreshesForTesting()
        XCTAssertEqual(reads.axReadsOnMain + reads.axReadsOffMain, [])
        XCTAssertEqual(reads.frontmostReads, 0)
    }

    // MARK: - consumeSelection

    private func seed(_ monitor: SelectionMonitor, element: AXUIElement) {
        monitor.seedCacheForTesting(
            SelectionMonitor.CachedSelection(
                text: "typed AI selection", bundleID: "com.example.app", changeToken: 1, timestamp: Date()),
            element: element
        )
    }

    /// The typed AI trigger already holds the focus it resolved; consuming must not query AX again.
    func testConsumeUsesTheCallersFocusAndRunsNoAXQuery() {
        let monitor = SelectionMonitor(defaults: .standard, environment: .fixed())
        seed(monitor, element: element)
        var consumed: SelectionMonitor.CachedSelection?
        let queries = FocusQueryProbe.counting {
            consumed = monitor.consumeSelection(rejectWeakAX: false, focusedElement: element)
        }
        XCTAssertEqual(consumed?.text, "typed AI selection")
        XCTAssertEqual(queries, 0, "consumeSelection must not issue a live focus query")
        XCTAssertNil(monitor.rawCachedSelection(), "single use")
    }

    func testConsumeRefusesAndClearsWhenFocusIsADifferentElementOrUnresolved() {
        let monitor = SelectionMonitor(defaults: .standard, environment: .fixed())
        let other = AXUIElementCreateApplication(1)
        for focus in [other, nil] as [AXUIElement?] {
            seed(monitor, element: element)
            let queries = FocusQueryProbe.counting {
                XCTAssertNil(monitor.consumeSelection(rejectWeakAX: false, focusedElement: focus))
            }
            XCTAssertEqual(queries, 0)
            XCTAssertNil(monitor.rawCachedSelection(), "A mismatched focus clears last-known-good")
        }
    }
}
