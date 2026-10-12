import XCTest
import CryptoKit
@testable import ExpanderEngine

/// Palette / manager search benchmarks. Set `DEVTYPE_BENCH=1` to run; skipped otherwise so CI
/// is not timing-sensitive. Every benchmark is min-of-N, interleaves the baseline (A) with the
/// optimised path (B) so machine drift hits both, and asserts a generous ceiling: an order of
/// magnitude above the expected release-build number, so only a real regression trips it.
final class PaletteSearchBenchmarkTests: XCTestCase {

    private func requireBenchMode() throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_BENCH"] == "1" else {
            throw XCTSkip("set DEVTYPE_BENCH=1 to run benchmarks")
        }
    }

    private func library(_ count: Int) -> [SnippetGroup] {
        let snippets = (0..<count).map { index in
            SnippetModel(
                title: "Snippet number \(index) about topic \(index % 37)",
                triggerKeyword: ";w\(index % 97)x\(index)",
                replacementText: String(repeating: "Lorem ipsum dolor sit amet \(index). ", count: 12),
                tags: ["tag\(index % 11)"]
            )
        }
        return [SnippetGroup(name: "All", snippets: snippets)]
    }

    private let source = ObjectIdentifier(PaletteSearchBenchmarkTests.self)

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// Runs `a` and `b` alternately `rounds` times (with `reset` before each) and returns the minimum of each.
    private func interleaved(rounds: Int, reset: () -> Void, a: () -> Void, b: () -> Void) -> (a: Double, b: Double) {
        var bestA = Double.infinity, bestB = Double.infinity
        for _ in 0..<rounds {
            reset()
            bestA = min(bestA, milliseconds(a))
            reset()
            bestB = min(bestB, milliseconds(b))
        }
        return (bestA, bestB)
    }

    private func report(_ label: String, _ result: (a: Double, b: Double)) {
        print(String(format: "  %-52@ before %8.3f ms   after %8.3f ms", label as NSString, result.a, result.b))
    }

    /// Five-keystroke typing sequence: with narrowing (B) vs the full scan every keystroke needed
    /// before (A). A defeats the narrowing slot by searching a second index between keystrokes.
    func testQ1ExtendingQueryNarrowsInsteadOfRescanning() throws {
        try requireBenchMode()
        let groups = library(2_000)
        let typed = ["w1", "w12", "w12x", "w12x1", "w12x12"]
        let indexA = SnippetSearch.makeIndex(for: groups, includeDisabled: true)
        let indexB = SnippetSearch.makeIndex(for: groups, includeDisabled: true)
        let result = interleaved(
            rounds: 7,
            reset: { SnippetSearch.invalidateIndexCache() },
            a: {
                for query in typed {
                    // Untimed in spirit: the clobber is a cached-miss scan of another index, so
                    // subtract it by measuring only after it ran.
                    _ = SnippetSearch.run(query: query + "q", index: indexB)
                    _ = SnippetSearch.run(query: query, index: indexA)
                }
            },
            b: {
                for query in typed { _ = SnippetSearch.run(query: query, index: indexB) }
            }
        )
        // `a` above includes the clobbering scans (roughly doubling it); measure the pure
        // baseline separately so the comparison is honest.
        var pureA = Double.infinity
        for _ in 0..<7 {
            var total = 0.0
            for query in typed {
                SnippetSearch.invalidateIndexCache()
                total += milliseconds { _ = SnippetSearch.run(query: query, index: indexA) }
            }
            pureA = min(pureA, total)
        }
        report("Q1 5-key typing @2000, full scan vs narrowing", (pureA, result.b))
        XCTAssertLessThan(result.b, pureA, "narrowing must not be slower than rescanning")
        XCTAssertLessThan(result.b, 2_000, "ceiling for five keystrokes at 2,000 snippets")
    }

    /// A repeated palette keystroke with a usage boost: cached by boostRevision (B) vs
    /// re-sorted on every call (A, no revision).
    func testQ2BoostedResultsCachedByRevision() throws {
        try requireBenchMode()
        let groups = library(2_000)
        let index = SnippetSearch.makeIndex(for: groups, includeDisabled: true)
        let boost: (UUID) -> Int = { Int($0.uuid.0) % 5 }
        _ = SnippetSearch.run(query: "w1", index: index)
        let result = interleaved(
            rounds: 9,
            reset: {},
            a: { for _ in 0..<200 { _ = SnippetSearch.run(query: "w1", index: index, limit: 40, boost: boost) } },
            b: { for _ in 0..<200 { _ = SnippetSearch.run(query: "w1", index: index, limit: 40, boost: boost, boostRevision: 1, boostSource: source) } }
        )
        report("Q2 200 boosted repeats @2000", result)
        XCTAssertLessThan(result.b, result.a)
        XCTAssertLessThan(result.b, 500)
    }

    /// Identity by revision vs fingerprinting the whole library per keystroke (the manager filter).
    func testQ3RevisionAvoidsFingerprintingTheLibrary() throws {
        try requireBenchMode()
        let groups = library(2_000)
        let libraryID = UUID()
        let result = interleaved(
            rounds: 9,
            reset: {},
            a: { for i in 0..<100 { _ = SnippetSearch.run(query: "w\(i % 9)x", in: groups) } },
            b: { for i in 0..<100 { _ = SnippetSearch.run(query: "w\(i % 9)x", in: groups, revision: 3, libraryID: libraryID) } }
        )
        report("Q3 100 manager filters @2000, fingerprint vs revision", result)
        XCTAssertLessThan(result.b, result.a)
        XCTAssertLessThan(result.b, 2_000)
    }

    /// The palette's row build for an identical repeated query, with boost closures supplied.
    func testQ4PaletteRowCacheWithBoosts() throws {
        try requireBenchMode()
        let groups = library(2_000)
        let libraryID = UUID()
        let clipboard = String(repeating: "clipboard text ", count: 20_000)
        func build(revision: UInt64?) {
            _ = CommandPaletteCatalog.buildRows(
                query: "w1", groups: groups, loc: .shared,
                usageBoost: { _ in 1 }, clipboardPreview: clipboard,
                commandUsageBoost: { _ in 1 },
                boostRevision: revision, boostSource: revision == nil ? nil : source, clipboardChangeCount: revision == nil ? nil : 4,
                libraryRevision: 1, libraryID: libraryID
            )
        }
        build(revision: 1)
        let result = interleaved(
            rounds: 9,
            reset: {},
            a: { for _ in 0..<50 { build(revision: nil) } },
            b: { for _ in 0..<50 { build(revision: 1) } }
        )
        report("Q4 50 palette rows builds @2000, no cache vs cached", result)
        XCTAssertLessThan(result.b, result.a)
        XCTAssertLessThan(result.b, 500)
    }

    /// Tied triggers force the comparator down to the locale-aware compare and the id tie-break.
    func testQ5TiedRanking() throws {
        try requireBenchMode()
        let snippets = (0..<2_000).map { _ in
            SnippetModel(title: "Same", triggerKeyword: ":same", replacementText: "x")
        }
        let index = SnippetSearch.makeIndex(for: [SnippetGroup(name: "G", snippets: snippets)], includeDisabled: true)
        var best = Double.infinity
        for round in 0..<7 {
            SnippetSearch.invalidateIndexCache()
            best = min(best, milliseconds { _ = SnippetSearch.run(query: "same\(round % 2 == 0 ? "" : " ")", index: index) })
        }
        print(String(format: "  %-52@ %8.3f ms", "Q5 rank 2000 fully tied hits" as NSString, best))
        XCTAssertLessThan(best, 1_000)
    }

    func testQ6DigestHex() throws {
        try requireBenchMode()
        let digest = SHA256.hash(data: Data("benchmark".utf8))
        let result = interleaved(
            rounds: 9,
            reset: {},
            a: { for _ in 0..<20_000 { _ = digest.map { String(format: "%02x", $0) }.joined() } },
            b: { for _ in 0..<20_000 { _ = SnippetStore.hexString(of: digest) } }
        )
        report("Q6 digest hex x20k", result)
        XCTAssertLessThan(result.b, result.a)
        XCTAssertLessThan(result.b, 500)
    }
}
