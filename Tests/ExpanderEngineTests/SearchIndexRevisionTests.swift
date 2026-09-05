import XCTest
@testable import ExpanderEngine

/// `SnippetSearch` used to prove its index cache still valid by hashing every group and every
/// snippet's id, trigger, title, tags and timestamp — 627 µs at 2,000 snippets, on the main
/// thread, on every keystroke in the command palette, to discover nothing had changed. It now
/// accepts a `SnippetStore.libraryRevision` and compares a counter.
///
/// Three things have to hold for that to be safe: the revision has to actually move when the
/// library changes, a stale revision must never serve results for a different library, and the
/// index has to keep one slot per `includeDisabled` value so two callers cannot evict each
/// other.
final class SearchIndexRevisionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SnippetSearch.invalidateIndexCache()
    }

    override func tearDown() {
        SnippetSearch.invalidateIndexCache()
        super.tearDown()
    }

    private func snippet(_ trigger: String, title: String) -> SnippetModel {
        SnippetModel(
            title: title,
            triggerKeyword: trigger,
            replacementText: "body for \(trigger)",
            isCaseSensitive: false,
            requireWordBoundary: true
        )
    }

    private func makeStore() throws -> (SnippetStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devtype-rev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SnippetStore(fileURL: dir.appendingPathComponent("snippets.json")), dir)
    }

    // MARK: - The revision tracks the library

    func testRevisionMovesWhenTheLibraryChanges() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = store.loadGroupsWithRevision()
        XCTAssertEqual(store.libraryRevision, first.revision, "reading twice must not move it")

        let outcome = store.mutateGroups { groups in
            groups.append(SnippetGroup(name: "Added", snippets: [self.snippet(";new", title: "New")]))
            return true
        }
        guard case .saved = outcome else {
            return XCTFail("expected the mutation to save, got \(outcome)")
        }

        let second = store.loadGroupsWithRevision()
        XCTAssertNotEqual(
            second.revision, first.revision,
            "a committed save must move the revision or a cache keyed on it goes stale"
        )
    }

    /// The pair has to come from one lock acquisition. If it did not, a save landing between
    /// two reads would hand out a new revision naming an old library.
    func testGroupsAndRevisionAgree() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var seen: [UInt64: Int] = [:]
        for _ in 0..<5 {
            let snapshot = store.loadGroupsWithRevision()
            let count = snapshot.groups.reduce(0) { $0 + $1.snippets.count }
            if let previous = seen[snapshot.revision] {
                XCTAssertEqual(previous, count, "same revision named two different libraries")
            }
            seen[snapshot.revision] = count
            _ = store.mutateGroups { groups in
                groups[0].snippets.append(self.snippet(";x\(groups[0].snippets.count)", title: "X"))
                return true
            }
        }
    }

    // MARK: - A revision must not serve another library's results

    func testDifferentLibrariesUnderDifferentRevisionsDoNotShareResults() {
        let a = [SnippetGroup(name: "G", snippets: [snippet(";alpha", title: "Alpha")])]
        let b = [SnippetGroup(name: "G", snippets: [snippet(";beta", title: "Beta")])]

        let fromA = SnippetSearch.run(query: "alpha", in: a, includeDisabled: true, limit: 10, revision: 1)
        XCTAssertEqual(fromA.count, 1)

        let fromB = SnippetSearch.run(query: "alpha", in: b, includeDisabled: true, limit: 10, revision: 2)
        XCTAssertTrue(fromB.isEmpty, "revision 2's library has no `;alpha` — the cache served revision 1")

        let againB = SnippetSearch.run(query: "beta", in: b, includeDisabled: true, limit: 10, revision: 2)
        XCTAssertEqual(againB.count, 1)
    }

    /// The two stamp spaces share one table. A revision of 7 must not be mistaken for a content
    /// fingerprint that happens to be 7.
    func testRevisionAndFingerprintStampsDoNotCollide() {
        let groups = [SnippetGroup(name: "G", snippets: [snippet(";alpha", title: "Alpha")])]
        let stamp = SnippetSearch.fingerprint(of: groups, includeDisabled: true)

        let byRevision = SnippetSearch.run(query: "alpha", in: groups, includeDisabled: true, limit: 10, revision: stamp)
        let byFingerprint = SnippetSearch.run(query: "alpha", in: groups, includeDisabled: true, limit: 10)
        XCTAssertEqual(byRevision.count, 1)
        XCTAssertEqual(byFingerprint.count, 1)
    }

    /// Without a revision the fingerprint still has to notice an edit. Both the trigger and the
    /// title have to move, because search matches either.
    func testFingerprintPathStillNoticesEdits() {
        let before = [SnippetGroup(name: "G", snippets: [snippet(";alpha", title: "Alpha")])]
        XCTAssertEqual(SnippetSearch.run(query: "alpha", in: before, limit: 10).count, 1)

        var edited = before
        edited[0].snippets[0].triggerKeyword = ";omega"
        edited[0].snippets[0].title = "Omega"
        edited[0].snippets[0].replacementText = "body for omega"
        XCTAssertTrue(
            SnippetSearch.run(query: "alpha", in: edited, limit: 10).isEmpty,
            "the fingerprint path must still rebuild when the library changes"
        )
    }

    // MARK: - One index slot per includeDisabled

    /// A single slot meant the palette (`includeDisabled: false`) and the manager
    /// (`includeDisabled: true`) evicted each other and paid a full rebuild on every
    /// alternation. Both answers must stay correct while alternating.
    func testAlternatingIncludeDisabledCallersDoNotEvictEachOther() {
        var disabled = snippet(";off", title: "Disabled one")
        disabled.enabled = false
        let groups = [SnippetGroup(name: "G", snippets: [snippet(";on", title: "Enabled one"), disabled])]

        for _ in 0..<4 {
            let withDisabled = SnippetSearch.run(
                query: "off", in: groups, includeDisabled: true, limit: 10, revision: 42
            )
            XCTAssertEqual(withDisabled.count, 1, "includeDisabled: true must still see the disabled snippet")

            let withoutDisabled = SnippetSearch.run(
                query: "off", in: groups, includeDisabled: false, limit: 10, revision: 42
            )
            XCTAssertTrue(withoutDisabled.isEmpty, "includeDisabled: false must still hide it")
        }
    }

    // MARK: - The query cache does not hoard dead libraries

    /// Results keyed to a library that has been replaced can never be served again, but nothing
    /// used to remove them — they sat pinning `SnippetModel` copies, replacement text included,
    /// until FIFO eviction pushed them out 128 queries later.
    func testQueryCacheDropsResultsForReplacedLibraries() {
        var groups = [SnippetGroup(name: "G", snippets: [snippet(";alpha", title: "Alpha")])]
        _ = SnippetSearch.run(query: "alpha", in: groups, includeDisabled: true, limit: 10, revision: 1)
        XCTAssertGreaterThan(SnippetSearch.cachedQueryCountForTesting, 0)

        groups[0].snippets = [snippet(";beta", title: "Beta")]
        _ = SnippetSearch.run(query: "beta", in: groups, includeDisabled: true, limit: 10, revision: 2)

        XCTAssertEqual(
            SnippetSearch.cachedQueryCountForTesting, 1,
            "the revision-1 result should have been pruned when revision 2 replaced its index"
        )
    }

    /// The eviction ring must not grow without bound as entries are added past capacity.
    func testQueryCacheStaysBoundedUnderManyDistinctQueries() {
        let groups = [SnippetGroup(name: "G", snippets: [snippet(";alpha", title: "Alpha")])]
        for i in 0..<600 {
            _ = SnippetSearch.run(query: "q\(i)", in: groups, includeDisabled: true, limit: 10, revision: 9)
        }
        XCTAssertLessThanOrEqual(SnippetSearch.cachedQueryCountForTesting, 128)
        XCTAssertLessThanOrEqual(
            SnippetSearch.queryCacheRingSizeForTesting, 300,
            "the eviction ring grew without bound instead of compacting"
        )
    }
}

/// Proves the point of P4 directly rather than by timing: a caller that supplies a library
/// revision never pays the whole-library content hash, which measured 627 µs at 2,000 snippets
/// and ran on every keystroke in the command palette.
final class SearchFingerprintAvoidanceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SnippetSearch.invalidateIndexCache()
        SnippetSearch.resetFingerprintCountForTesting()
    }

    override func tearDown() {
        SnippetSearch.invalidateIndexCache()
        super.tearDown()
    }

    private func library(_ count: Int) -> [SnippetGroup] {
        [SnippetGroup(name: "G", snippets: (0..<count).map { index in
            SnippetModel(
                title: "Snippet \(index)",
                triggerKeyword: ";trigger\(index)",
                replacementText: "body \(index)",
                isCaseSensitive: false,
                requireWordBoundary: true
            )
        })]
    }

    func testSupplyingARevisionCostsNoContentHashAtAll() {
        let groups = library(500)
        for index in 0..<50 {
            _ = SnippetSearch.run(
                query: "snippet \(index)", in: groups, includeDisabled: false, limit: 20, revision: 3
            )
        }
        XCTAssertEqual(
            SnippetSearch.fingerprintCountForTesting, 0,
            "a revision identifies the library outright — nothing should hash it"
        )
    }

    /// Without one, the fingerprint is still computed — once per call, which is exactly the
    /// per-keystroke cost the revision removes.
    func testWithoutARevisionEveryCallStillHashesTheLibrary() {
        let groups = library(50)
        for index in 0..<10 {
            _ = SnippetSearch.run(query: "snippet \(index)", in: groups, limit: 20)
        }
        XCTAssertEqual(
            SnippetSearch.fingerprintCountForTesting, 10,
            "the fallback path is unchanged for callers that cannot supply a revision"
        )
    }
}
