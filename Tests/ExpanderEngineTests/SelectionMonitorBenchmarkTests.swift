import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// Main-thread time per AX selection-changed notification, before and after the callback was
/// reduced to a hop (ft-06d301ac item 1). Set `DEVTYPE_BENCH=1` to run; skipped otherwise so CI
/// is not timing-sensitive.
///
/// The AX round-trips are *simulated* through `Environment.axReads` with a fixed busy-wait per
/// read, so the numbers are deterministic and comparable but are not a measurement of any real
/// app's AX latency (unmeasured here: see the card's "No timings were measured"). Both arms run
/// the same refresh body; "before" runs it inline on main exactly as the callback used to,
/// "after" calls the real callback and times only what it does on main. Arms are interleaved and
/// the minimum of N is reported.
final class SelectionMonitorBenchmarkTests: XCTestCase {
    /// Per-read costs, a conservative lower bound for a healthy app (the engine-wide AX timeout
    /// is 50 ms per call; Chromium and large selections cost far more).
    private let queryMicros = 400.0
    private let ownerMicros = 100.0
    private let selectedTextMicros = 400.0

    private func spin(_ micros: Double) {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(micros * 1_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {}
    }

    private func makeMonitor() -> SelectionMonitor {
        let defaults = UserDefaults(suiteName: "SelectionMonitorBenchmarkTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: SelectionMonitor.featureEnabledDefaultsKey)
        let element = AXUIElementCreateSystemWide()
        var environment = SelectionMonitor.Environment.fixed()
        environment.frontmostBundleID = { "com.example.bench" }
        environment.axReads = SelectionMonitor.AXReads(
            isProcessTrusted: { true },
            queryFocusedElement: { self.spin(self.queryMicros); return .available(element) },
            ownerBundleID: { _ in self.spin(self.ownerMicros); return nil },
            copySelectedText: { _, _ in self.spin(self.selectedTextMicros); return "benchmark selection" }
        )
        return SelectionMonitor(defaults: defaults, environment: environment)
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testMainThreadTimePerNotification() throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_BENCH"] == "1" else {
            throw XCTSkip("set DEVTYPE_BENCH=1 to run benchmarks")
        }
        let monitor = makeMonitor()
        let rounds = 25
        var before: [Double] = []
        var after: [Double] = []
        // Warm both arms, then interleave.
        monitor.performRefreshInlineForBenchmark(bundleID: "com.example.bench")
        monitor.handleAXNotification()
        monitor.waitForRefreshesForTesting()
        for _ in 0..<rounds {
            before.append(milliseconds { monitor.performRefreshInlineForBenchmark(bundleID: "com.example.bench") })
            after.append(milliseconds { monitor.handleAXNotification() })
            monitor.waitForRefreshesForTesting()   // keep the background read out of the next sample
        }
        let beforeMin = before.min() ?? 0
        let afterMin = after.min() ?? 0
        print(String(format: "  SelectionMonitor main-thread time/notification (simulated AX %.1f ms of reads):",
                     (queryMicros + ownerMicros + selectedTextMicros) / 1000))
        print(String(format: "    before (inline on main)   min %.3f ms  median %.3f ms",
                     beforeMin, before.sorted()[rounds / 2]))
        print(String(format: "    after  (hop to queue)     min %.3f ms  median %.3f ms",
                     afterMin, after.sorted()[rounds / 2]))
        XCTAssertLessThan(afterMin, beforeMin / 4, "The callback must cost a small fraction of the inline read")
    }
}
