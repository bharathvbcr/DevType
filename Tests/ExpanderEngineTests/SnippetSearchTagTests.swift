import XCTest
@testable import ExpanderEngine

/// Tags as search terms.
///
/// `SnippetModel.tags` round-trips through both interchange formats DevType speaks under the
/// name `search_terms` — `EspansoImporter` reads them, `SnippetExporter` writes them — and until
/// this change DevType was the only participant that did not actually search them.
final class SnippetSearchTagTests: XCTestCase {

    private func snippet(
        trigger: String,
        title: String,
        body: String = "some body text",
        tags: [String] = []
    ) -> SnippetModel {
        var s = SnippetModel(title: title, triggerKeyword: trigger, replacementText: body)
        s.tags = tags
        return s
    }

    private func library(_ snippets: [SnippetModel], group: String = "General") -> [SnippetGroup] {
        [SnippetGroup(name: group, snippets: snippets)]
    }

    // MARK: - The gap this closes

    func testASnippetIsFoundByATagThatAppearsNowhereElseInIt() {
        let groups = library([
            snippet(trigger: ":sig", title: "Signature", body: "Regards, Bharath", tags: ["invoice"])
        ])
        let hits = SnippetSearch.run(query: "invoice", in: groups, includeDisabled: true, limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.snippet.triggerKeyword, ":sig")
    }

    func testATagThatMatchesNothingStillFindsNothing() {
        let groups = library([snippet(trigger: ":sig", title: "Signature", tags: ["invoice"])])
        XCTAssertTrue(SnippetSearch.run(query: "zzz", in: groups, includeDisabled: true, limit: 10).isEmpty)
    }

    // MARK: - Ranking

    /// A tag is a deliberate statement about one snippet; a group is a bucket its neighbours
    /// share. Asserted through the public ranking rather than the private score constants.
    func testATagMatchOutranksAGroupNameMatch() {
        let tagged = snippet(trigger: ":a", title: "Alpha", tags: ["billing"])
        let grouped = snippet(trigger: ":b", title: "Beta")
        let groups = [
            SnippetGroup(name: "General", snippets: [tagged]),
            SnippetGroup(name: "Billing", snippets: [grouped]),
        ]
        let hits = SnippetSearch.run(query: "billing", in: groups, includeDisabled: true, limit: 10)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.snippet.triggerKeyword, ":a", "the tagged snippet should rank first")
    }

    func testATriggerMatchStillOutranksATagMatch() {
        let byTag = snippet(trigger: ":a", title: "Alpha", tags: ["email"])
        let byTrigger = snippet(trigger: ":email", title: "Beta")
        let hits = SnippetSearch.run(
            query: "email", in: library([byTag, byTrigger]), includeDisabled: true, limit: 10
        )
        XCTAssertEqual(hits.first?.snippet.triggerKeyword, ":email")
    }

    func testATagMatchOutranksABodyMatch() {
        let byTag = snippet(trigger: ":a", title: "Alpha", body: "nothing here", tags: ["quarterly"])
        let byBody = snippet(trigger: ":b", title: "Beta", body: "the quarterly report")
        let hits = SnippetSearch.run(
            query: "quarterly", in: library([byTag, byBody]), includeDisabled: true, limit: 10
        )
        XCTAssertEqual(hits.first?.snippet.triggerKeyword, ":a")
    }

    func testAnExactTagOutranksAPartialOne() {
        let exact = snippet(trigger: ":a", title: "Alpha", tags: ["work"])
        let partial = snippet(trigger: ":b", title: "Beta", tags: ["workflow"])
        let hits = SnippetSearch.run(
            query: "work", in: library([exact, partial]), includeDisabled: true, limit: 10
        )
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.snippet.triggerKeyword, ":a")
    }

    // MARK: - Matching shape

    func testAnyOneOfSeveralTagsCanMatch() {
        let groups = library([
            snippet(trigger: ":a", title: "Alpha", tags: ["first", "second", "third"])
        ])
        for term in ["first", "second", "third"] {
            XCTAssertEqual(
                SnippetSearch.run(query: term, in: groups, includeDisabled: true, limit: 10).count,
                1,
                "\"\(term)\" should match via its tag"
            )
        }
    }

    /// Suggested tags are lowercased at the boundary, but imported ones are whatever the source
    /// file said, so matching has to be case-insensitive like every other field.
    func testTagMatchingIsCaseInsensitive() {
        let groups = library([snippet(trigger: ":a", title: "Alpha", tags: ["Invoice"])])
        XCTAssertEqual(
            SnippetSearch.run(query: "invoice", in: groups, includeDisabled: true, limit: 10).count, 1
        )
    }

    /// Multi-term queries are AND across fields — a tag may satisfy one term and the title another.
    func testATagCanSatisfyOneTermOfAMultiTermQuery() {
        let groups = library([
            snippet(trigger: ":a", title: "Signature", tags: ["billing"]),
            snippet(trigger: ":b", title: "Signature", tags: ["personal"]),
        ])
        let hits = SnippetSearch.run(
            query: "signature billing", in: groups, includeDisabled: true, limit: 10
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.snippet.triggerKeyword, ":a")
    }

    // MARK: - Highlights

    /// A hit belongs to one of several tags and the highlight table is keyed by field, so a tag
    /// match deliberately reports no ranges. `evaluate` must drop it rather than emit an empty
    /// highlight the UI would try to render.
    func testATagMatchProducesNoHighlight() {
        let groups = library([snippet(trigger: ":a", title: "Alpha", tags: ["invoice"])])
        let hits = SnippetSearch.run(query: "invoice", in: groups, includeDisabled: true, limit: 10)
        XCTAssertEqual(hits.first?.highlights.filter { $0.field == .tag }, [])
    }

    // MARK: - Cache invalidation

    /// Everything except the tags is pinned — same snippet id, same group id, same timestamps.
    ///
    /// Without pinning, these tests pass whether or not tags are in the fingerprint: a fresh
    /// `SnippetGroup` gets a random `id` and a fresh `SnippetModel` gets `Date()` timestamps,
    /// either of which moves the hash on its own. That made the first version of this test
    /// vacuous — it went green against a build with `hasher.combine(snippet.tags)` deleted.
    private func pinnedLibrary(tags: [String]) -> [SnippetGroup] {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let model = SnippetModel(
            id: Self.pinnedSnippetID,
            title: "Alpha",
            triggerKeyword: ":a",
            replacementText: "nothing relevant",
            createdAt: stamp,
            updatedAt: stamp,
            tags: tags
        )
        return [SnippetGroup(id: Self.pinnedGroupID, name: "General", snippets: [model])]
    }

    private static let pinnedSnippetID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let pinnedGroupID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// Self-check on the pinning: two libraries that differ in nothing must hash identically,
    /// or the tests below would again be measuring the wrong thing.
    func testPinnedLibrariesAreIdenticalWhenTagsAreIdentical() {
        XCTAssertEqual(
            SnippetSearch.fingerprint(of: pinnedLibrary(tags: ["invoice"]), includeDisabled: true),
            SnippetSearch.fingerprint(of: pinnedLibrary(tags: ["invoice"]), includeDisabled: true)
        )
    }

    /// `run(query:in:)` caches an index keyed by `fingerprint`. Tags had to be added to that
    /// hash too: without it, adding a tag leaves the stale index in place and the snippet stays
    /// unfindable until something else about it changes.
    func testAddingATagChangesTheIndexFingerprint() {
        XCTAssertNotEqual(
            SnippetSearch.fingerprint(of: pinnedLibrary(tags: []), includeDisabled: true),
            SnippetSearch.fingerprint(of: pinnedLibrary(tags: ["invoice"]), includeDisabled: true)
        )
    }

    func testChangingATagsTextChangesTheIndexFingerprint() {
        XCTAssertNotEqual(
            SnippetSearch.fingerprint(of: pinnedLibrary(tags: ["invoice"]), includeDisabled: true),
            SnippetSearch.fingerprint(of: pinnedLibrary(tags: ["receipt"]), includeDisabled: true)
        )
    }

    /// The end-to-end version, through the cache the fingerprint guards. Same pinned identity
    /// on both sides, so only the tag can rebuild the index.
    func testASnippetBecomesFindableAsSoonAsATagIsAdded() {
        XCTAssertTrue(
            SnippetSearch.run(
                query: "invoice", in: pinnedLibrary(tags: []), includeDisabled: true, limit: 10
            ).isEmpty
        )
        XCTAssertEqual(
            SnippetSearch.run(
                query: "invoice", in: pinnedLibrary(tags: ["invoice"]), includeDisabled: true, limit: 10
            ).count,
            1,
            "the cached index must have been rebuilt when the tag was added"
        )
    }

    /// And the reverse — removing a tag must stop finding it, or the editor's remove-a-tag
    /// affordance would appear to do nothing.
    func testRemovingATagMakesItUnfindableAgain() {
        XCTAssertEqual(
            SnippetSearch.run(
                query: "invoice", in: pinnedLibrary(tags: ["invoice"]), includeDisabled: true, limit: 10
            ).count,
            1
        )
        XCTAssertTrue(
            SnippetSearch.run(
                query: "invoice", in: pinnedLibrary(tags: []), includeDisabled: true, limit: 10
            ).isEmpty
        )
    }

    // MARK: - No effect on untagged libraries

    /// Every existing snippet has no tags. The new rung must be inert for them.
    func testUntaggedSnippetsScoreExactlyAsBefore() {
        let model = snippet(trigger: ":sig", title: "Signature", body: "Regards")
        XCTAssertEqual(SnippetSearch.score(snippet: model, needle: "sig"), 980)
        XCTAssertEqual(SnippetSearch.score(snippet: model, needle: "signature"), 620)
        XCTAssertEqual(SnippetSearch.score(snippet: model, needle: "regards"), 200)
    }
}
