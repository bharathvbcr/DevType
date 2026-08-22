import XCTest
@testable import ExpanderEngine

// The legacy single-snippet scorer (`SnippetSearch.score(snippet:needle:)`) is
// a shim over the same entry evaluator the index uses, but it used to fold the
// *entire* body while `makeIndex` caps bodies at
// `maxIndexedBodyCharacters`. The two paths must agree: same matches, same
// scores, and no unbounded work for huge snippets.

final class SnippetSearchShimCapTests: XCTestCase {

    private func makeSnippet(body: String) -> SnippetModel {
        SnippetModel(title: "Body Probe", triggerKeyword: ":probe", replacementText: body)
    }

    /// Needle near the start: both paths must find it with an identical score.
    func testNearStartNeedleScoresIdenticallyOnBothPaths() {
        let cap = SnippetSearchIndex.maxIndexedBodyCharacters
        let snippet = makeSnippet(
            body: "alpha " + String(repeating: "x", count: cap * 2)
        )
        let group = SnippetGroup(name: "g", snippets: [snippet])
        let hits = SnippetSearch.run(query: "alpha", index: SnippetSearch.makeIndex(for: [group]))

        XCTAssertEqual(SnippetSearch.score(snippet: snippet, needle: "alpha"), hits.first?.score,
                       "legacy shim and capped index path must agree")
    }

    /// Needle beyond the cap: the capped index cannot see it, so the shim must
    /// not see it either. Pre-fix this diverged (shim folded the full body).
    func testBeyondCapNeedleIsInvisibleOnBothPaths() {
        let cap = SnippetSearchIndex.maxIndexedBodyCharacters
        let hidden = makeSnippet(
            body: String(repeating: "x", count: cap + 100_000) + " zebra tail"
        )
        let group = SnippetGroup(name: "g", snippets: [hidden])
        let index = SnippetSearch.makeIndex(for: [group])

        XCTAssertTrue(SnippetSearch.run(query: "zebra", index: index).isEmpty,
                      "index path must not match past the cap")

        let started = Date()
        let shimScore = SnippetSearch.score(snippet: hidden, needle: "zebra")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10.0,
                          "scoring a huge body must complete promptly")

        XCTAssertNil(shimScore,
                     "legacy shim must agree with the capped index path on huge bodies")
    }
}
