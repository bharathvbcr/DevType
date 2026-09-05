import XCTest
@testable import ExpanderEngine

/// Measures the audit's headline paths against the *real* types, not standalone reproductions.
/// Set `DEVTYPE_BENCH=1` to run; skipped otherwise so CI is not timing-sensitive.
final class AuditBenchmarkTests: XCTestCase {

    private func requireBenchMode() throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_BENCH"] == "1" else {
            throw XCTSkip("set DEVTYPE_BENCH=1 to run benchmarks")
        }
    }

    private func library(_ count: Int) -> [SnippetGroup] {
        let snippets = (0..<count).map { index in
            SnippetModel(
                title: "Snippet \(index)",
                triggerKeyword: ";trigger\(index)",
                replacementText: String(repeating: "Lorem ipsum dolor sit amet. ", count: 6),
                isCaseSensitive: false,
                requireWordBoundary: true
            )
        }
        return [SnippetGroup(name: "All", snippets: snippets)]
    }

    private func time(_ label: String, _ body: () -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "  %-46@ %8.2f ms", label as NSString, ms))
    }

    func testP1ConflictDetection() throws {
        try requireBenchMode()
        for size in [500, 1_000, 2_000] {
            let groups = library(size)
            time("P1 triggerConflicts @ \(size)") {
                _ = SnippetStore.triggerConflicts(in: groups)
            }
        }
    }

    func testP2PrefixIndexBuild() throws {
        try requireBenchMode()
        for size in [500, 1_000, 2_000] {
            let snippets = library(size)[0].snippets
            time("P2 TriggerPrefixIndex @ \(size)") {
                _ = TriggerPrefixIndex(snippets: snippets)
            }
        }
    }

    func testP3MatcherKeystroke() throws {
        try requireBenchMode()
        var snippets = library(500)[0].snippets
        snippets.append(SnippetModel(
            title: "Long",
            triggerKeyword: ";" + String(repeating: "z", count: 60),
            replacementText: "x",
            isCaseSensitive: false,
            requireWordBoundary: false
        ))
        let matcher = AbbreviationMatcher(snippets: snippets)
        let chars = Array("hello world this is what a user types while working ok now!")
        time("P3 matcher x20k keystrokes (longest 61)") {
            for _ in 0..<20_000 { _ = matcher.match(characters: chars) }
        }
    }

    func testP4SearchPerKeystroke() throws {
        try requireBenchMode()
        for size in [1_000, 2_000] {
            let groups = library(size)
            SnippetSearch.invalidateIndexCache()
            _ = SnippetSearch.run(query: "trigger1", in: groups, limit: 40, revision: 7)
            time("P4 cached search x1k keystrokes @ \(size)") {
                for index in 0..<1_000 {
                    _ = SnippetSearch.run(
                        query: "trigger\(index % 50)", in: groups, limit: 40, revision: 7
                    )
                }
            }
        }
    }

    func testP6LocalizationLookup() throws {
        try requireBenchMode()
        let loc = LocalizationManager()
        time("P6 loc.s x200k") {
            for _ in 0..<200_000 { _ = loc.s("common.cancel") }
        }
    }
}
