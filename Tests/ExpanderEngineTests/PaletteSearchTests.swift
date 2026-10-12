import XCTest
@testable import ExpanderEngine

/// Behaviour of the palette / manager search paths: narrowing, boosted-result caching, the
/// palette row cache and ordering equivalence with the pre-optimisation comparator.
final class PaletteSearchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SnippetSearch.invalidateIndexCache()
        CommandPaletteCatalog.invalidateCache()
    }

    override func tearDown() {
        SnippetSearch.invalidateIndexCache()
        CommandPaletteCatalog.invalidateCache()
        super.tearDown()
    }

    // MARK: Fixtures

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

    private func uuid(_ rng: inout SplitMix64) -> UUID {
        var bytes: [UInt8] = []
        for _ in 0..<2 { withUnsafeBytes(of: rng.next()) { bytes.append(contentsOf: $0) } }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Ties (shared triggers, equal-length triggers), mixed case, CJK and emoji.
    private func randomLibrary(seed: UInt64, count: Int) -> [SnippetGroup] {
        var rng = SplitMix64(state: seed)
        let words = ["temp", "Temple", "TEMPLATE", "email", "Email", "sig", "signature", "addr", "地址", "模板",
                     "你好", "😀smile", "🎉party", "café", "Cafe", "résumé", "work", "home", "x", "zz"]
        let sigils = [":", ";", "~", ""]
        var groups: [SnippetGroup] = []
        for g in 0..<4 {
            var snippets: [SnippetModel] = []
            for _ in 0..<(count / 4) {
                let trigger = sigils.randomElement(using: &rng)! + words.randomElement(using: &rng)!
                    + (Bool.random(using: &rng) ? "" : String(Int.random(in: 0..<9, using: &rng)))
                snippets.append(SnippetModel(
                    id: uuid(&rng),
                    title: words.randomElement(using: &rng)! + " " + words.randomElement(using: &rng)!,
                    triggerKeyword: trigger,
                    replacementText: words.randomElement(using: &rng)! + " body " + words.randomElement(using: &rng)!,
                    enabled: Int.random(in: 0..<8, using: &rng) != 0,
                    tags: Bool.random(using: &rng) ? [words.randomElement(using: &rng)!] : []
                ))
            }
            groups.append(SnippetGroup(id: uuid(&rng), name: words.randomElement(using: &rng)! + " group \(g)", snippets: snippets))
        }
        return groups
    }

    /// The comparator exactly as it was before the optimisation.
    private func referenceOrder(_ hits: [SearchHit]) -> [UUID] {
        hits.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let la = a.snippet.triggerKeyword.count, lb = b.snippet.triggerKeyword.count
            if la != lb { return la < lb }
            let order = a.snippet.triggerKeyword.localizedCaseInsensitiveCompare(b.snippet.triggerKeyword)
            if order != .orderedSame { return order == .orderedAscending }
            if a.id != b.id { return a.id.uuidString < b.id.uuidString }
            return a.groupID.uuidString < b.groupID.uuidString
        }.map(\.id)
    }

    private func assertSame(_ lhs: [SearchHit], _ rhs: [SearchHit], _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.map(\.id), rhs.map(\.id), message, file: file, line: line)
        XCTAssertEqual(lhs.map(\.score), rhs.map(\.score), message, file: file, line: line)
        XCTAssertEqual(lhs.map(\.highlights), rhs.map(\.highlights), message, file: file, line: line)
    }

    private func freshRun(_ query: String, _ groups: [SnippetGroup]) -> [SearchHit] {
        SnippetSearch.run(query: query, index: SnippetSearch.makeIndex(for: groups, includeDisabled: true))
    }

    // MARK: Narrowing

    func testExtendingAQueryOnlyRescoresThePreviousHits() {
        let groups = randomLibrary(seed: 1, count: 400)
        let index = SnippetSearch.makeIndex(for: groups, includeDisabled: true)

        SnippetSearch.resetEvaluationCountForTesting()
        let first = SnippetSearch.run(query: "tem", index: index)
        XCTAssertEqual(SnippetSearch.evaluationCountForTesting, index.count, "First query scans the library.")
        XCTAssertLessThan(first.count, index.count, "Precondition: the query must exclude snippets.")

        SnippetSearch.resetEvaluationCountForTesting()
        let second = SnippetSearch.run(query: "temp", index: index)
        XCTAssertEqual(SnippetSearch.evaluationCountForTesting, first.count,
                       "One more character must re-score only the previous hits, not rescan non-matching snippets.")

        assertSame(second, freshRun("temp", groups), "Narrowed result must equal a from-scratch scan")
    }

    func testShrinkingOrReplacingAQueryDoesNotReuseStaleHits() {
        let groups = randomLibrary(seed: 2, count: 400)
        let index = SnippetSearch.makeIndex(for: groups, includeDisabled: true)
        _ = SnippetSearch.run(query: "temp", index: index)

        SnippetSearch.resetEvaluationCountForTesting()
        let shrunk = SnippetSearch.run(query: "tem", index: index)
        XCTAssertEqual(SnippetSearch.evaluationCountForTesting, index.count, "Deleting a character must rescan.")
        assertSame(shrunk, freshRun("tem", groups), "Shrunk query must see hits the longer query excluded")

        SnippetSearch.resetEvaluationCountForTesting()
        _ = SnippetSearch.run(query: "email", index: index)
        XCTAssertEqual(SnippetSearch.evaluationCountForTesting, index.count, "An unrelated query must rescan.")
    }

    func testExclusionsAndStatesNeverNarrow() {
        let groups = randomLibrary(seed: 3, count: 400)
        let index = SnippetSearch.makeIndex(for: groups, includeDisabled: true)
        for pair in [("temp -ema", "temp -email"), ("is:e", "is:en"), ("-tem", "-temp")] {
            _ = SnippetSearch.run(query: pair.0, index: index)
            let narrowed = SnippetSearch.run(query: pair.1, index: index)
            assertSame(narrowed, freshRun(pair.1, groups), "\(pair.0) -> \(pair.1)")
        }
    }

    func testLibraryMutationBetweenKeystrokesIsSeen() {
        var groups = randomLibrary(seed: 4, count: 200)
        let libraryID = UUID()
        _ = SnippetSearch.run(query: "tem", in: groups, revision: 1, libraryID: libraryID)
        _ = SnippetSearch.run(query: "temp", in: groups, revision: 1, libraryID: libraryID)

        groups[0].snippets.append(SnippetModel(title: "Fresh", triggerKeyword: ":tempzzz", replacementText: "x"))
        let after = SnippetSearch.run(query: "tempz", in: groups, revision: 2, libraryID: libraryID)
        XCTAssertTrue(after.contains { $0.snippet.triggerKeyword == ":tempzzz" },
                      "A snippet added between keystrokes must not be hidden by hits cached for the old revision")
        groups[0].snippets.removeAll { $0.triggerKeyword == ":tempzzz" }
        let removed = SnippetSearch.run(query: "tempzz", in: groups, revision: 3, libraryID: libraryID)
        XCTAssertFalse(removed.contains { $0.snippet.triggerKeyword == ":tempzzz" })
    }

    // MARK: Boost cache

    private let source = ObjectIdentifier(PaletteSearchTests.self)

    func testBoostedResultsAreCachedByBoostRevision() {
        let groups = randomLibrary(seed: 5, count: 200)
        let index = SnippetSearch.makeIndex(for: groups, includeDisabled: true)
        var calls = 0
        let boost: (UUID) -> Int = { _ in calls += 1; return 3 }

        let first = SnippetSearch.run(query: "temp", index: index, limit: 40, boost: boost, boostRevision: 1, boostSource: source)
        let afterFirst = calls
        XCTAssertGreaterThan(afterFirst, 0)
        let second = SnippetSearch.run(query: "temp", index: index, limit: 40, boost: boost, boostRevision: 1, boostSource: source)
        XCTAssertEqual(calls, afterFirst, "Same query and boost revision must be served from cache")
        assertSame(first, second, "cached boosted result")

        _ = SnippetSearch.run(query: "temp", index: index, limit: 40, boost: boost, boostRevision: 2, boostSource: source)
        XCTAssertGreaterThan(calls, afterFirst, "A moved boost revision must recompute")

        let afterThird = calls
        _ = SnippetSearch.run(query: "temp", index: index, limit: 10, boost: boost, boostRevision: 2, boostSource: source)
        XCTAssertGreaterThan(calls, afterThird, "A different limit is a different result")

        let uncachedBase = calls
        _ = SnippetSearch.run(query: "temp", index: index, limit: 40, boost: boost)
        _ = SnippetSearch.run(query: "temp", index: index, limit: 40, boost: boost)
        XCTAssertGreaterThan(calls, uncachedBase, "Without a revision and source a closure's state is unknowable, so nothing is cached")
    }

    func testSameRevisionFromADifferentSourceNeverSharesARanking() {
        let groups = randomLibrary(seed: 10, count: 100)
        let index = SnippetSearch.makeIndex(for: groups, includeDisabled: true)
        let target = SnippetSearch.run(query: "temp", index: index).last!.id
        let a = SnippetSearch.run(query: "temp", index: index, boost: { $0 == target ? 5_000 : 0 },
                                  boostRevision: 1, boostSource: source)
        let b = SnippetSearch.run(query: "temp", index: index, boost: { _ in 0 },
                                  boostRevision: 1, boostSource: ObjectIdentifier(SnippetStore.self))
        XCTAssertEqual(a.first?.id, target)
        XCTAssertNotEqual(b.first?.id, target)
    }

    func testBoostedRankingStaysEqualToReference() {
        let groups = randomLibrary(seed: 6, count: 300)
        let index = SnippetSearch.makeIndex(for: groups, includeDisabled: true)
        let boost: (UUID) -> Int = { Int($0.uuid.0) % 7 }
        let boosted = SnippetSearch.run(query: "e", index: index, boost: boost, boostRevision: 9, boostSource: source)
        XCTAssertFalse(boosted.isEmpty)
        XCTAssertEqual(boosted.map(\.id), referenceOrder(boosted))
    }

    // MARK: Equivalence

    func testRankingMatchesReferenceAcrossRandomizedLibraryAndKeystrokes() {
        let groups = randomLibrary(seed: 42, count: 600)
        let index = SnippetSearch.makeIndex(for: groups, includeDisabled: true)
        let typed = ["", "  ", "t", "te", "tem", "temp", "templ", "TEM", "Tem", "tem", "te", "e", "em", "ema", "email",
                     "emai", "中", "中文", "地", "地址", "你", "😀", "😀s", "😀sm", "caf", "cafe", "café", "résu", "resu",
                     "temp x", "temp  x", "temp -zz", "temp -zzz", "group:work", "tag:e", "\"temp\"", "\"temp",
                     "sg", "sig", "is:enabled", ":", ":t", ";", "~e", "zz", "z", "zzz"]
        for query in typed {
            let reused = SnippetSearch.run(query: query, index: index)
            let fresh = freshRun(query, groups)
            assertSame(reused, fresh, "query '\(query)'")
            XCTAssertEqual(reused.map(\.id), referenceOrder(reused), "order for '\(query)'")
            let limited = SnippetSearch.run(query: query, index: index, limit: 5)
            XCTAssertEqual(limited.map(\.id), Array(fresh.prefix(5)).map(\.id), "limit for '\(query)'")
        }
        XCTAssertTrue(SnippetSearch.run(query: "", index: index).isEmpty)
        XCTAssertTrue(SnippetSearch.run(query: " \n\t ", index: index).isEmpty)
    }

    // MARK: Palette rows

    func testPaletteRowCacheHitsWithUsageBoostsAndMissesOnEachKeyInput() {
        let groups = randomLibrary(seed: 7, count: 60)
        let libraryID = UUID()
        func build(boostRev: UInt64 = 1, changeCount: Int = 10, libraryRev: UInt64 = 1) {
            _ = CommandPaletteCatalog.buildRows(
                query: "temp", groups: groups, loc: .shared,
                usageBoost: { _ in 1 }, clipboardPreview: "hello",
                commandUsageBoost: { _ in 1 },
                boostRevision: boostRev, boostSource: source, clipboardChangeCount: changeCount,
                libraryRevision: libraryRev, libraryID: libraryID
            )
        }
        build()
        XCTAssertEqual(CommandPaletteCatalog.rowCacheHitCount, 0)
        build()
        XCTAssertEqual(CommandPaletteCatalog.rowCacheHitCount, 1, "Repeated identical query with boosts must hit")
        build(boostRev: 2)
        XCTAssertEqual(CommandPaletteCatalog.rowCacheHitCount, 1, "boost revision change must miss")
        build(changeCount: 11)
        XCTAssertEqual(CommandPaletteCatalog.rowCacheHitCount, 1, "clipboard change count change must miss")
        build(libraryRev: 2)
        XCTAssertEqual(CommandPaletteCatalog.rowCacheHitCount, 1, "library revision change must miss")
        build(libraryRev: 2)
        XCTAssertEqual(CommandPaletteCatalog.rowCacheHitCount, 2)
    }

    func testPaletteRowCacheNeverServesClosureRankingsWithoutABoostRevision() {
        let groups = randomLibrary(seed: 8, count: 40)
        for _ in 0..<2 {
            _ = CommandPaletteCatalog.buildRows(
                query: "temp", groups: groups, loc: .shared,
                usageBoost: { _ in 1 }, commandUsageBoost: { _ in 1 }
            )
        }
        XCTAssertEqual(CommandPaletteCatalog.rowCacheHitCount, 0)
    }

    // MARK: Digest hex

    func testHexStringMatchesStringFormat() {
        var rng = SplitMix64(state: 99)
        for length in [0, 1, 32, 33] {
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            XCTAssertEqual(SnippetStore.hexString(of: bytes), bytes.map { String(format: "%02x", $0) }.joined())
        }
    }
}
