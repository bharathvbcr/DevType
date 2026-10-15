import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

/// App-side follow-through measurements. Same min-of-N rule as `BenchmarkGate`, which lives in
/// the engine test target and is not linked here. Skipped unless `DEVTYPE_BENCH=1`. Release
/// configuration is the one the ceilings mean; `Scripts/ci-local.sh` step 2b runs that.
final class FollowThroughBenchmarkTests: XCTestCase {

    private func requireBench() throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_BENCH"] == "1" else {
            throw XCTSkip("set DEVTYPE_BENCH=1 to run benchmarks")
        }
    }

    private func elapsedMs(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func interleaved(rounds: Int = 5, _ a: () -> Void, _ b: () -> Void) -> (a: Double, b: Double) {
        for _ in 0..<1 { a(); b() }
        var bestA = Double.infinity
        var bestB = Double.infinity
        for _ in 0..<rounds {
            bestA = min(bestA, elapsedMs(a))
            bestB = min(bestB, elapsedMs(b))
        }
        return (bestA, bestB)
    }

    /// B4: `rank` serves a per-language folded catalogue. The other side is `termScores`,
    /// which still folds every field on every call.
    ///
    /// Release 2026-10-14, min of 5: folded rank x40 25.32 ms, per-call `termScores` x40
    /// 24.50 ms. Rank also sorts, applies the usage boost, and drops non-matches, so the
    /// two sides are not the same work. The cached rank stayed within 1 ms of folding every
    /// field and then stopping. Dropping the index would put that fold back on top of the
    /// sort. The index stays. Ceiling 80 ms.
    func testB4FoldedMacroRankVersusPerCallFold() throws {
        try requireBench()
        let loc = LocalizationManager.shared
        let categories = MacroCategory.allCases
        let boost: (String) -> Int = { _ in 1 }
        _ = MacroPaletteRanking.rank(query: "tomorrow", loc: loc, usageBoost: boost)
        let pair = interleaved(rounds: 5, {
            for _ in 0..<40 {
                _ = MacroPaletteRanking.rank(query: "tomorrow uuid", loc: loc, usageBoost: boost)
            }
        }, {
            for _ in 0..<40 {
                let terms = ["tomorrow", "uuid"]
                for category in categories {
                    let title = loc.s(category.titleKey)
                    for descriptor in MacroCatalog.descriptors(in: category) {
                        _ = MacroPaletteRanking.termScores(
                            descriptor, terms: terms, categoryTitle: title, loc: loc
                        )
                    }
                }
            }
        })
        print(String(format: "  B4 folded rank x40 %8.2f ms vs per-call fold x40 %8.2f ms", pair.a, pair.b))
        let ceiling = 80.0
        XCTAssertLessThanOrEqual(pair.a, ceiling, String(format: "B4 folded rank %.2f ms exceeds %.0f ms", pair.a, ceiling))
    }

    /// B9 / B10: one formatter per language, against building a `DateFormatter` per value.
    /// Release 2026-10-14, min of 5: cached x80 0.00 ms vs fresh x80 0.01 ms. Ceiling 30 ms.
    func testB9FormatterCacheVersusFreshDateFormatter() throws {
        try requireBench()
        let cache = LocalizedFormatterCache()
        let pair = interleaved(rounds: 5, {
            for _ in 0..<80 {
                _ = cache.formatter(kind: "follow-through-date", languageCode: "en") { DateFormatter() }
            }
        }, {
            for _ in 0..<80 { _ = DateFormatter() }
        })
        print(String(format: "  B9/B10 cached formatter x80 %8.2f ms vs fresh %8.2f ms", pair.a, pair.b))
        XCTAssertLessThan(pair.a, pair.b)
        XCTAssertLessThanOrEqual(pair.a, 30, String(format: "cached formatters %.2f ms exceeds 30 ms", pair.a))
    }
}
