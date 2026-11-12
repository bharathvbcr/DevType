import XCTest
@testable import ExpanderEngine

/// Canonical regression gate for `DEVTYPE_BENCH=1` benchmarks.
///
/// A benchmark that only prints cannot fail, so a regression back to O(n²) passes every gate.
/// This helper turns a timing into a verdict against a documented ceiling.
///
/// API (all times are milliseconds):
/// - `requireBenchMode()`: throws `XCTSkip` unless `DEVTYPE_BENCH=1`. Call first in each bench test.
/// - `measure(_:warmup:runs:_:)`: runs `body` `warmup` times unrecorded, then `runs` times,
///   and returns the minimum. Min-of-N rejects scheduler noise; a real regression raises the floor.
/// - `interleaved(_:_:warmup:rounds:)`: A/B comparison. Alternates A,B,A,B... so thermal and
///   load drift hit both sides equally, and returns each side's minimum.
/// - `growthMinimums(rounds:base:scaled:_:)`: for growth-curve tests, which run in every suite
///   (no `DEVTYPE_BENCH`). Each size's least thread CPU time, interleaved, in seconds.
/// - `verdict(measuredMs:ceilingMs:)`: pure pass/fail decision (testable without XCTFail).
/// - `assertWithin(_:ceilingMs:warmup:runs:file:line:_:)`: `measure`, print, and `XCTFail`
///   with measured vs ceiling when exceeded. Returns the measurement.
///
/// Ceilings are deliberately generous: about 10x the release-build number measured when the
/// benchmark was written (see each call site for the derivation). They catch algorithmic
/// regressions (O(n²), accidental main-thread I/O), not 20% drift. Debug builds run 3-10x slower
/// than release, so the gate is only meaningful in release configuration; in debug it still
/// prints and still enforces (a debug run under the ceiling is under it in release too).
enum BenchmarkGate {

    struct Verdict: Equatable {
        let measuredMs: Double
        let ceilingMs: Double
        var passed: Bool { measuredMs <= ceilingMs }
    }

    static func requireBenchMode() throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_BENCH"] == "1" else {
            throw XCTSkip("set DEVTYPE_BENCH=1 to run benchmarks")
        }
    }

    private static func elapsedMs(
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        _ body: () -> Void
    ) -> Double {
        let start = now()
        body()
        return Double(now() &- start) / 1_000_000
    }

    /// Minimum of `runs` timed executions after `warmup` untimed ones.
    ///
    /// `now` is the clock. Tests pass a counter so a loaded machine cannot turn a one
    /// millisecond sleep into a failure of the min-of-N rule.
    static func measure(
        warmup: Int = 1,
        runs: Int = 5,
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        _ body: () -> Void
    ) -> Double {
        precondition(runs > 0 && warmup >= 0, "runs must be positive")
        for _ in 0..<warmup { body() }
        var best = Double.infinity
        for _ in 0..<runs { best = min(best, elapsedMs(now: now, body)) }
        return best
    }

    /// Alternating A/B minimums. Returns `(a, b)` in milliseconds.
    static func interleaved(
        warmup: Int = 1, rounds: Int = 5, _ a: () -> Void, _ b: () -> Void
    ) -> (a: Double, b: Double) {
        precondition(rounds > 0 && warmup >= 0, "rounds must be positive")
        for _ in 0..<warmup { a(); b() }
        var bestA = Double.infinity, bestB = Double.infinity
        for _ in 0..<rounds {
            bestA = min(bestA, elapsedMs(a))
            bestB = min(bestB, elapsedMs(b))
        }
        return (bestA, bestB)
    }

    /// What a scaled-up input costs next to the base one, for tests that pin a growth curve
    /// rather than an absolute time. Returns each size's least time in seconds, so the caller
    /// asserts on `scaled / base`.
    ///
    /// The clock is the thread's CPU time, not elapsed time: a full suite on a loaded machine
    /// deschedules the test and pages it in from swap, and wall-clock charged that to whichever
    /// size it landed on — once reading ×8 for work that was ×2.6, and a single sample per size
    /// read ×3.1 to ×4.5 for linear work under ×2. Each size is still measured `rounds` times,
    /// interleaved, keeping the least, because CPU time alone does not even out which core the
    /// thread ran on or what it was contending with. The base reading is floored at half a
    /// millisecond so timer resolution cannot dominate the ratio on a fast machine.
    static func growthMinimums<Input>(
        rounds: Int = 7,
        base: Input,
        scaled: Input,
        _ run: (Input) -> Void
    ) -> (base: Double, scaled: Double) {
        precondition(rounds > 0, "rounds must be positive")
        func seconds(_ input: Input) -> Double {
            let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            run(input)
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1_000_000_000
        }

        run(base)  // warm
        run(scaled)
        var bestBase = Double.infinity
        var bestScaled = Double.infinity
        for _ in 0..<rounds {
            bestBase = min(bestBase, seconds(base))
            bestScaled = min(bestScaled, seconds(scaled))
        }
        return (max(bestBase, 0.0005), bestScaled)
    }

    static func verdict(measuredMs: Double, ceilingMs: Double) -> Verdict {
        Verdict(measuredMs: measuredMs, ceilingMs: ceilingMs)
    }

    @discardableResult
    static func assertWithin(
        _ label: String, ceilingMs: Double, warmup: Int = 1, runs: Int = 5,
        file: StaticString = #filePath, line: UInt = #line, _ body: () -> Void
    ) -> Double {
        let ms = measure(warmup: warmup, runs: runs, body)
        print(String(format: "  %-46@ %8.2f ms (ceiling %.0f ms)", label as NSString, ms, ceilingMs))
        let result = verdict(measuredMs: ms, ceilingMs: ceilingMs)
        if !result.passed {
            XCTFail(
                String(format: "%@: min-of-%d %.2f ms exceeds ceiling %.0f ms", label, runs, ms, ceilingMs),
                file: file, line: line
            )
        }
        return ms
    }
}

/// Always runs (no `DEVTYPE_BENCH`): proves the gate can fail. A deliberately quadratic
/// reference for the "which triggers extend this one?" question, the shape `TriggerPrefixScan`
/// replaced, must be flagged by `BenchmarkGate.verdict` against a ceiling that the linear-ish
/// implementation passes. Sizes and ratios are chosen so the margin is orders of magnitude, not
/// a timing coin-flip.
final class BenchmarkGateSelfTests: XCTestCase {

    private func keys(_ count: Int) -> [String] { (0..<count).map { ";trigger\($0)" } }

    /// The pre-fix algorithm: every key against every key, folding inside the inner loop.
    private func quadraticExtensionCount(_ keys: [String]) -> Int {
        var total = 0
        for (i, key) in keys.enumerated() {
            for (j, other) in keys.enumerated() where i != j {
                if other.lowercased().hasPrefix(key) && other != key { total += 1 }
            }
        }
        return total
    }

    private func scanExtensionCount(_ keys: [String]) -> Int {
        let scan = TriggerPrefixScan(foldedKeys: keys)
        var total = 0
        for index in keys.indices { scan.forEachStrictExtension(of: index) { _ in total += 1 } }
        return total
    }

    func testGateFlagsQuadraticReferenceAndPassesScan() {
        let input = keys(1_000)
        XCTAssertEqual(quadraticExtensionCount(input), scanExtensionCount(input),
                       "reference must do the same work as the implementation it stands in for")

        let times = BenchmarkGate.interleaved(
            warmup: 1, rounds: 2,
            { _ = scanExtensionCount(input) },
            { _ = quadraticExtensionCount(input) }
        )
        // Ceiling an order of magnitude above the good implementation, with a floor so a
        // sub-millisecond scan does not make the ceiling noise-sized.
        let ceiling = max(10 * times.a, 5)
        XCTAssertTrue(BenchmarkGate.verdict(measuredMs: times.a, ceilingMs: ceiling).passed,
                      "the scan must pass its own ceiling")
        let slow = BenchmarkGate.verdict(measuredMs: times.b, ceilingMs: ceiling)
        XCTAssertFalse(slow.passed,
                       "gate failed to flag a quadratic regression: \(times.b) ms vs ceiling \(ceiling) ms")
        print(String(format: "  gate self-test: scan %.2f ms, quadratic %.2f ms, ceiling %.2f ms",
                     times.a, times.b, ceiling))
    }

    func testMeasureReturnsMinimumAndRunsWarmup() {
        var calls = 0
        var cursor: UInt64 = 0
        // Warmup is the fastest sample. Folding it into the minimum would report 0.1 ms.
        let advancesNs: [UInt64] = [100_000, 20_000_000, 30_000_000, 40_000_000]
        var index = 0
        let best = BenchmarkGate.measure(warmup: 1, runs: 3, now: { cursor }) {
            calls += 1
            cursor &+= advancesNs[index]
            index += 1
        }
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(best, 20, accuracy: 0.0001, "min-of-N must ignore the warmup sample")
    }

    func testVerdictBoundary() {
        XCTAssertTrue(BenchmarkGate.verdict(measuredMs: 10, ceilingMs: 10).passed)
        XCTAssertFalse(BenchmarkGate.verdict(measuredMs: 10.01, ceilingMs: 10).passed)
    }
}
