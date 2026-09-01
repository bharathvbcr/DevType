import XCTest
@testable import ExpanderEngine

/// Batch tagging over a whole library.
///
/// Fully exercisable without a model: `SnippetTagSuggester` takes an injected `TaggingEngine`,
/// so what is under test here is the batch discipline — eligibility, the cap, cancellation, and
/// a summary that admits what it did not cover.
final class SnippetLibraryTaggerTests: XCTestCase {

    private var savedMaster: Any?
    private var savedOwn: Any?

    override func setUp() {
        super.setUp()
        savedMaster = UserDefaults.standard.object(forKey: AIPreferences.enabledKey)
        savedOwn = UserDefaults.standard.object(forKey: SnippetTagSuggester.enabledKey)
        UserDefaults.standard.set(true, forKey: AIPreferences.enabledKey)
        UserDefaults.standard.set(true, forKey: SnippetTagSuggester.enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedMaster, forKey: AIPreferences.enabledKey)
        UserDefaults.standard.set(savedOwn, forKey: SnippetTagSuggester.enabledKey)
        super.tearDown()
    }

    private let longBody = "Thanks for the invoice — it is approved and scheduled for payment."

    private func snippet(
        _ trigger: String,
        body: String? = nil,
        tags: [String] = [],
        secret: Bool = false
    ) -> SnippetModel {
        var s = SnippetModel(
            title: "T", triggerKeyword: trigger, replacementText: body ?? longBody, isSecret: secret
        )
        s.tags = tags
        return s
    }

    private func engine(_ tags: [String] = ["invoice"]) -> SnippetTagSuggester.TaggingEngine {
        { _ in SnippetTagSuggester.RawTagging(tags: tags, group: nil) }
    }

    // MARK: - Eligibility

    func testAnUntaggedSubstantialSnippetIsEligible() {
        XCTAssertTrue(SnippetLibraryTagger.isEligible(snippet(":a")))
    }

    /// Deliberately curated tags — an Espanso `search_terms:` list — must not be topped up.
    func testAnAlreadyTaggedSnippetIsSkipped() {
        XCTAssertFalse(SnippetLibraryTagger.isEligible(snippet(":a", tags: ["mine"])))
    }

    func testASecretIsSkipped() {
        XCTAssertFalse(SnippetLibraryTagger.isEligible(snippet(":a", secret: true)))
    }

    func testAShortSnippetIsSkipped() {
        XCTAssertFalse(SnippetLibraryTagger.isEligible(snippet(":a", body: "hi")))
    }

    // MARK: - Tagging a library

    func testEveryEligibleSnippetIsTagged() async {
        let groups = [SnippetGroup(name: "G", snippets: [snippet(":a"), snippet(":b")])]
        let (updated, summary) = await SnippetLibraryTagger.tagLibrary(groups, engine: engine())
        XCTAssertEqual(summary.tagged, 2)
        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(updated[0].snippets.map(\.tags), [["invoice"], ["invoice"]])
    }

    func testIneligibleSnippetsAreLeftExactlyAsTheyWere() async {
        let groups = [SnippetGroup(name: "G", snippets: [
            snippet(":keep", tags: ["mine"]),
            snippet(":secret", secret: true),
            snippet(":short", body: "hi"),
        ])]
        let (updated, summary) = await SnippetLibraryTagger.tagLibrary(groups, engine: engine())
        XCTAssertEqual(summary.tagged, 0)
        XCTAssertEqual(summary.skipped, 3)
        XCTAssertEqual(updated[0].snippets.map(\.tags), [["mine"], [], []])
    }

    func testTaggingSpansEveryGroup() async {
        let groups = [
            SnippetGroup(name: "A", snippets: [snippet(":a")]),
            SnippetGroup(name: "B", snippets: [snippet(":b")]),
        ]
        let (updated, summary) = await SnippetLibraryTagger.tagLibrary(groups, engine: engine())
        XCTAssertEqual(summary.tagged, 2)
        XCTAssertEqual(updated[1].snippets[0].tags, ["invoice"])
    }

    func testAnEngineThatSuggestsNothingIsCountedNotCrashed() async {
        let groups = [SnippetGroup(name: "G", snippets: [snippet(":a")])]
        let (updated, summary) = await SnippetLibraryTagger.tagLibrary(groups, engine: engine([]))
        XCTAssertEqual(summary.noSuggestion, 1)
        XCTAssertEqual(summary.tagged, 0)
        XCTAssertTrue(updated[0].snippets[0].tags.isEmpty)
    }

    func testNoEngineTagsNothingButStillReportsHonestly() async {
        let groups = [SnippetGroup(name: "G", snippets: [snippet(":a")])]
        let (_, summary) = await SnippetLibraryTagger.tagLibrary(groups, engine: nil)
        XCTAssertEqual(summary.tagged, 0)
        XCTAssertEqual(summary.noSuggestion, 1)
    }

    // MARK: - The cap

    /// A capped run must not report itself as covering the library.
    func testTheBatchIsCappedAndSaysSo() async {
        let many = (0..<(SnippetLibraryTagger.maximumBatchSize + 25)).map { snippet(":s\($0)") }
        let groups = [SnippetGroup(name: "G", snippets: many)]
        let (_, summary) = await SnippetLibraryTagger.tagLibrary(groups, engine: engine())
        XCTAssertEqual(summary.tagged, SnippetLibraryTagger.maximumBatchSize)
        XCTAssertEqual(summary.notAttempted, 25)
        XCTAssertFalse(summary.isComplete, "a capped run is not a complete one")
    }

    func testAnUncappedRunReportsComplete() async {
        let groups = [SnippetGroup(name: "G", snippets: [snippet(":a")])]
        let (_, summary) = await SnippetLibraryTagger.tagLibrary(groups, engine: engine())
        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.notAttempted, 0)
    }

    // MARK: - Cancellation

    /// A cancelled run keeps what it finished and counts the rest as not attempted — it must
    /// never look like a run that covered everything.
    func testCancellationStopsAndIsReported() async {
        let many = (0..<20).map { snippet(":s\($0)") }
        let groups = [SnippetGroup(name: "G", snippets: many)]

        let task = Task { () -> SnippetLibraryTagger.Summary in
            let (_, summary) = await SnippetLibraryTagger.tagLibrary(
                groups,
                engine: { _ in
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    return SnippetTagSuggester.RawTagging(tags: ["invoice"], group: nil)
                }
            )
            return summary
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()
        let summary = await task.value

        XCTAssertGreaterThan(summary.notAttempted, 0, "the remainder must be reported")
        XCTAssertFalse(summary.isComplete)
        XCTAssertLessThan(summary.tagged, 20)
    }

    // MARK: - Progress

    func testProgressCountsUpToTheEligibleTotal() async {
        let groups = [SnippetGroup(name: "G", snippets: [snippet(":a"), snippet(":b"), snippet(":c")])]
        let box = Box()
        _ = await SnippetLibraryTagger.tagLibrary(groups, engine: engine()) { done, total in
            box.record(done: done, total: total)
        }
        XCTAssertEqual(box.totals, [3, 3, 3])
        XCTAssertEqual(box.dones, [0, 1, 2])
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _dones: [Int] = []
        private var _totals: [Int] = []
        var dones: [Int] { lock.lock(); defer { lock.unlock() }; return _dones }
        var totals: [Int] { lock.lock(); defer { lock.unlock() }; return _totals }
        func record(done: Int, total: Int) {
            lock.lock(); _dones.append(done); _totals.append(total); lock.unlock()
        }
    }
}
