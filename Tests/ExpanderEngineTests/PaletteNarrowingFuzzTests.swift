import XCTest
@testable import ExpanderEngine

/// Differential fuzz: a query typed one keystroke at a time (with the narrowing slot and query
/// cache live) must return exactly what a from-scratch scan of the same query returns.
final class PaletteNarrowingFuzzTests: XCTestCase {

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Single keystrokes: ASCII, query syntax, accents, combining marks, ß/ligatures/fullwidth,
    /// Hangul (precomposed, compatibility and conjoining jamo), CJK and emoji incl. modifiers/ZWJ.
    private static let keys: [String] = [
        "a", "b", "c", "e", "i", "l", "m", "p", "s", "t", "x", "z", "A", "E", "S", "T",
        " ", " ", "-", ":", "\"", "\\", "~", ";",
        "é", "É", "\u{301}", "\u{308}", "ß", "ﬁ", "Ａ", "ｔ",
        "가", "각", "한", "글", "ㄱ", "ㅏ", "ㄴ", "\u{1100}", "\u{1161}", "\u{11A8}",
        "中", "文", "地", "址",
        "😀", "👍", "\u{1F3FD}", "\u{200D}", "👩", "💻", "🇺", "🇸",
    ]
    private static let fragments: [String] = [
        "is:", "tag:", "group:", "trigger:", "title:", "content:", "-", "\"",
    ]
    private static let words: [String] = [
        "temp", "Temple", "TEMPLATE", "email", "sig", "signature", "café", "Cafe", "résumé", "Straße",
        "strasse", "ﬁle", "file", "Ａｂｃ", "abc", "한글", "가각", "\u{1100}\u{1161}\u{11A8}", "ㄱㅏ",
        "中文", "地址", "😀smile", "👍🏽ok", "👩‍💻dev", "🇺🇸us", "e\u{301}cole", "école", "x", "zz", "a-b", "a:b",
    ]

    private func uuid(_ rng: inout SplitMix64) -> UUID {
        var b: [UInt8] = []
        for _ in 0..<2 { withUnsafeBytes(of: rng.next()) { b.append(contentsOf: $0) } }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private func library(_ rng: inout SplitMix64, count: Int) -> [SnippetGroup] {
        func w() -> String { Self.words.randomElement(using: &rng)! }
        var groups: [SnippetGroup] = []
        for g in 0..<3 {
            var snippets: [SnippetModel] = []
            for _ in 0..<(count / 3) {
                let sigil = [":", ";", "~", ""].randomElement(using: &rng)!
                snippets.append(SnippetModel(
                    id: uuid(&rng),
                    title: w() + " " + w(),
                    triggerKeyword: sigil + w(),
                    replacementText: w() + " " + w() + " " + w(),
                    enabled: Int.random(in: 0..<6, using: &rng) != 0,
                    tags: Bool.random(using: &rng) ? [w()] : []
                ))
            }
            groups.append(SnippetGroup(id: uuid(&rng), name: w() + " \(g)", snippets: snippets))
        }
        return groups
    }

    private func keystrokes(_ rng: inout SplitMix64) -> [String] {
        var text = ""
        var states: [String] = []
        for _ in 0..<Int.random(in: 4...14, using: &rng) {
            let roll = Int.random(in: 0..<20, using: &rng)
            if roll == 0, !text.isEmpty {
                text.removeLast()                       // backspace
            } else if roll < 3 {
                text += Self.fragments.randomElement(using: &rng)!
            } else if roll < 5 {
                text += String(Self.words.randomElement(using: &rng)!.prefix(2))
            } else {
                text += Self.keys.randomElement(using: &rng)!
            }
            states.append(text)
        }
        return states
    }

    private struct Shape: Equatable {
        let ids: [UUID]
        let scores: [Int]
        let highlights: [[SearchHighlight]]
        init(_ hits: [SearchHit]) {
            ids = hits.map(\.id); scores = hits.map(\.score); highlights = hits.map(\.highlights)
        }
    }

    /// Found by the fuzz below: the cache is keyed on the trimmed query, but the raw query was
    /// tokenized, and inside an unclosed quote trailing whitespace is part of the term.
    func testTrailingSpaceInsideAnOpenQuoteCannotBeServedAnotherQuerysAnswer() {
        SnippetSearch.invalidateIndexCache()
        defer { SnippetSearch.invalidateIndexCache() }
        let groups = [SnippetGroup(name: "g", snippets: [
            SnippetModel(title: "item", triggerKeyword: ":item", replacementText: "x"),
        ])]
        let index = SnippetSearch.makeIndex(for: groups, includeDisabled: true)
        let typed = SnippetSearch.run(query: "\"i", index: index)
        let extended = SnippetSearch.run(query: "\"i ", index: index)
        let fresh = SnippetSearch.run(query: "\"i ", index: SnippetSearch.makeIndex(for: groups, includeDisabled: true))
        XCTAssertEqual(typed.count, 1)
        XCTAssertEqual(extended.map(\.id), fresh.map(\.id), "same query, same answer, whatever ran before it")
        let boosted = SnippetSearch.run(query: "\"i ", index: SnippetSearch.makeIndex(for: groups, includeDisabled: true),
                                        boost: { _ in 0 })
        XCTAssertEqual(boosted.map(\.id), fresh.map(\.id), "boosted and unboosted runs parse the query the same way")
    }

    func testTypedQueriesMatchAFreshScanAtEveryKeystroke() {
        var rng = SplitMix64(state: 0xD1FF)
        var narrowedSteps = 0
        var totalSteps = 0
        var failures = 0
        let rounds = Int(ProcessInfo.processInfo.environment["DEVTYPE_FUZZ_ROUNDS"] ?? "") ?? 80
        for round in 0..<rounds {
            let groups = library(&rng, count: 90)
            let sequence = keystrokes(&rng)
            // Expected answers first, each on a brand-new index so no slot can be reused.
            SnippetSearch.invalidateIndexCache()
            let expected = sequence.map { query -> Shape in
                Shape(SnippetSearch.run(query: query, index: SnippetSearch.makeIndex(for: groups, includeDisabled: true)))
            }
            SnippetSearch.invalidateIndexCache()
            let index = SnippetSearch.makeIndex(for: groups, includeDisabled: true)
            for (step, query) in sequence.enumerated() {
                SnippetSearch.resetEvaluationCountForTesting()
                let got = Shape(SnippetSearch.run(query: query, index: index))
                let evaluated = SnippetSearch.evaluationCountForTesting
                totalSteps += 1
                if evaluated > 0 && evaluated < index.count { narrowedSteps += 1 }
                if got != expected[step] {
                    failures += 1
                    if failures <= 10 {
                        let prev = step > 0 ? sequence[step - 1] : "<none>"
                        XCTFail("round \(round) step \(step): '\(prev.debugDescription)' -> '\(query.debugDescription)' "
                                + "narrowed=\(got.ids.count) fresh=\(expected[step].ids.count)")
                    }
                }
            }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(narrowedSteps, totalSteps / 10, "the fuzz must actually exercise the narrowing path")
        print("narrowing fuzz: \(totalSteps) keystrokes, \(narrowedSteps) narrowed, \(failures) mismatches")
    }
}
