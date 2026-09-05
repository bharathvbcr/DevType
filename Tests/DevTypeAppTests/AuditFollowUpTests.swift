import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

/// The remaining audit fixes: the tag-suggestion merge that rescanned the library once per
/// candidate, the manager's per-keystroke recomputation, the stats poll that recomputed whether
/// or not anything changed, lazily built Preferences panes, and the toast announcement that
/// screen-reader users never got.
final class AuditFollowUpTests: XCTestCase {

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func snippet(_ trigger: String, tags: [String] = [], id: UUID = UUID()) -> SnippetModel {
        var model = SnippetModel(
            id: id,
            title: "Title \(trigger)",
            triggerKeyword: trigger,
            replacementText: "body \(trigger)",
            isCaseSensitive: false,
            requireWordBoundary: true
        )
        model.tags = tags
        return model
    }

    // MARK: - Tag-suggestion merge (P14)

    /// `init` nested `first(where:)` inside loops over groups and snippets, and `apply(to:)`
    /// walked every group and every snippet for each candidate. Tagging a whole library makes
    /// the candidate count proportional to the snippet count, so the cost was quadratic. The
    /// indexed version has to give exactly the same answers.
    func testMergeAppliesSuggestedTags() {
        let id = UUID()
        let baseline = [SnippetGroup(id: UUID(), name: "G", snippets: [snippet(";a", id: id)])]
        var tagged = baseline
        tagged[0].snippets[0].tags = ["work", "email"]

        let merge = SnippetTagSuggestionMerge(baseline: baseline, tagged: tagged)
        var target = baseline
        let summary = merge.apply(to: &target)

        XCTAssertEqual(summary.applied, 1)
        XCTAssertEqual(summary.stale, 0)
        XCTAssertEqual(target[0].snippets[0].tags, ["work", "email"])
    }

    /// Anything moved, edited or deleted since the model saw it is stale, not applied — the
    /// index changes the cost of finding it, never the rule.
    func testMergeRefusesEditedTargets() {
        let id = UUID()
        let baseline = [SnippetGroup(id: UUID(), name: "G", snippets: [snippet(";a", id: id)])]
        var tagged = baseline
        tagged[0].snippets[0].tags = ["work"]
        let merge = SnippetTagSuggestionMerge(baseline: baseline, tagged: tagged)

        var target = baseline
        target[0].snippets[0].replacementText = "edited since the model saw it"
        let summary = merge.apply(to: &target)

        XCTAssertEqual(summary.applied, 0)
        XCTAssertEqual(summary.stale, 1)
        XCTAssertTrue(target[0].snippets[0].tags.isEmpty)
    }

    func testMergeRefusesDeletedTargets() {
        let id = UUID()
        let baseline = [SnippetGroup(id: UUID(), name: "G", snippets: [snippet(";a", id: id)])]
        var tagged = baseline
        tagged[0].snippets[0].tags = ["work"]
        let merge = SnippetTagSuggestionMerge(baseline: baseline, tagged: tagged)

        var target = [SnippetGroup(id: baseline[0].id, name: "G", snippets: [])]
        let summary = merge.apply(to: &target)

        XCTAssertEqual(summary.applied, 0)
        XCTAssertEqual(summary.stale, 1)
    }

    /// A duplicated UUID names more than one physical entry, so the target is ambiguous and the
    /// merge must fail closed. The one-pass index has to keep counting *every* occurrence, not
    /// just the first.
    func testMergeRefusesAmbiguousDuplicateIdentifiers() {
        let id = UUID()
        let baseline = [SnippetGroup(id: UUID(), name: "G", snippets: [snippet(";a", id: id)])]
        var tagged = baseline
        tagged[0].snippets[0].tags = ["work"]
        let merge = SnippetTagSuggestionMerge(baseline: baseline, tagged: tagged)

        var target = baseline
        target[0].snippets.append(snippet(";b", id: id))
        let summary = merge.apply(to: &target)

        XCTAssertEqual(summary.applied, 0)
        XCTAssertEqual(summary.stale, 1, "a duplicate UUID must be refused, not guessed at")
    }

    /// A snippet the model never saw a change for produces no candidate at all.
    func testUnchangedTagsProduceNoCandidates() {
        let id = UUID()
        let baseline = [SnippetGroup(id: UUID(), name: "G", snippets: [snippet(";a", tags: ["x"], id: id)])]
        let merge = SnippetTagSuggestionMerge(baseline: baseline, tagged: baseline)
        var target = baseline
        let summary = merge.apply(to: &target)
        XCTAssertEqual(summary.applied, 0)
        XCTAssertEqual(summary.stale, 0)
    }

    /// The cost that motivated indexing: a library-wide tagging run must not be quadratic.
    func testWholeLibraryTaggingStaysLinearish() {
        let ids = (0..<1_500).map { _ in UUID() }
        let baseline = [SnippetGroup(
            id: UUID(),
            name: "G",
            snippets: ids.enumerated().map { snippet(";t\($0.offset)", id: $0.element) }
        )]
        var tagged = baseline
        for index in tagged[0].snippets.indices { tagged[0].snippets[index].tags = ["auto"] }

        let started = Date()
        let merge = SnippetTagSuggestionMerge(baseline: baseline, tagged: tagged)
        var target = baseline
        let summary = merge.apply(to: &target)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(summary.applied, 1_500)
        XCTAssertLessThan(
            elapsed, 2.0,
            "tagging 1,500 snippets took \(elapsed)s — the per-candidate library scan is back"
        )
    }

    // MARK: - Manager recomputation (P7 / P8 / P9 / X5)

    /// Search ran the full pipeline on every keystroke with no coalescing. The debounce that
    /// replaced that has to be short enough to feel immediate.
    func testFilterDebounceIsShortEnoughToFeelImmediate() throws {
        let manager = try source("Sources/DevTypeAppCore/SnippetManagerViewController.swift")
        XCTAssertTrue(
            manager.contains("filterDebounceInterval"),
            "the search field must coalesce rather than run the pipeline per keystroke"
        )
        XCTAssertTrue(manager.contains("filterDebounce?.cancel()"))
        // Anything acting on the list has to see what the user typed, not the mid-debounce table.
        XCTAssertTrue(manager.contains("func flushPendingFilter()"))
        XCTAssertTrue(
            manager.contains("tableView.onWillHandleInput"),
            "taking focus or pressing a key must apply a pending filter first"
        )
        for destructive in [
            "bulkDeleteSelected", "selectAllSnippets", "bulkExportSelected",
            "deleteSnippet", "editSelectedSnippet", "bulkEnableSelected", "bulkDisableSelected",
            "bulkDuplicateSelected", "bulkPrefixSuffixSelected"
        ] {
            XCTAssertTrue(
                manager.contains("func \(destructive)() {\n        flushPendingFilter()"),
                "\(destructive) must not act on a list the user has already narrowed"
            )
        }
    }

    /// The `.conflicts` chip called `triggerConflicts()` — a whole-library analysis — once per
    /// filter application, and `.unused` took a lock in `UsageStatsStore` once per snippet.
    func testChipFiltersDoNotRecomputeWholeLibraryAnalysesPerSnippet() throws {
        let manager = try source("Sources/DevTypeAppCore/SnippetManagerViewController.swift")
        XCTAssertTrue(
            manager.contains("conflictSnippetIDs()"),
            "conflicts must come from a revision-keyed cache, not a fresh scan per keystroke"
        )
        XCTAssertTrue(manager.contains("cachedConflictRevision"))
        XCTAssertTrue(
            manager.contains("SnippetStore.shared.usageCountsByID()"),
            "the unused chip must read the usage map once, not once per snippet"
        )
        XCTAssertFalse(
            manager.contains("filtered.filter { SnippetStore.shared.usageCount(for: $0) == 0 }"),
            "the per-snippet locked lookup is what this replaced"
        )
    }

    /// Comparators used to do their expensive work inside the comparison: two locked store calls
    /// per comparison for `.usage` / `.recentlyUsed`, and `localizedStandardCompare` for the
    /// text modes.
    func testSortComparatorsComputeTheirKeysOncePerElement() throws {
        let manager = try source("Sources/DevTypeAppCore/SnippetManagerViewController.swift")
        XCTAssertTrue(manager.contains("private func sortedByKey<Key>"))
        XCTAssertFalse(
            manager.contains("input.sorted { store.usageCount(for: $0) > store.usageCount(for: $1) }"),
            "the two-locked-reads-per-comparison sort is what this replaced"
        )
    }

    /// `reloadData()` clears selection, so refining a search after selecting rows for a bulk
    /// operation used to silently drop the selection.
    func testSelectionSurvivesAFilterReload() throws {
        let manager = try source("Sources/DevTypeAppCore/SnippetManagerViewController.swift")
        XCTAssertTrue(manager.contains("private func restoreSelection(ids: Set<UUID>)"))
        XCTAssertTrue(manager.contains("restoreSelection(ids: selectedIDs)"))
    }

    /// The stats pill used to build a second full copy of the library immediately after the
    /// pool did.
    func testTheLibraryIsFlattenedOncePerFilterPass() throws {
        let manager = try source("Sources/DevTypeAppCore/SnippetManagerViewController.swift")
        let start = try XCTUnwrap(manager.range(of: "private func applyFilterAndReloadTable() {"))
        let end = try XCTUnwrap(manager.range(of: "private func restoreSelection(ids: Set<UUID>)"))
        let body = String(manager[start.lowerBound..<end.lowerBound])
        let flattens = body.components(separatedBy: "groups.flatMap(\\.snippets)").count - 1
        XCTAssertLessThanOrEqual(
            flattens, 1,
            "the filter pass should flatten the library once and reuse it, not once for the "
                + "pool and again for the stats pill"
        )
    }

    /// Counting rows should never allocate the rows. The group outline rebuilt the whole
    /// flattened library per row render to display one integer.
    func testRowCountsAreSummedNotFlattened() throws {
        let manager = try source("Sources/DevTypeAppCore/SnippetManagerViewController.swift")
        XCTAssertFalse(
            manager.contains("groups.flatMap(\\.snippets).count"),
            "a count must be summed from the group sizes, not materialised"
        )
    }

    // MARK: - Stats poll (P15)

    /// The pane recomputed a full period snapshot every five seconds whether or not anything
    /// had been recorded. `UsageStatsStore.revision` answers that for free.
    func testStatsPollSkipsWhenNothingWasRecorded() throws {
        let stats = try source("Sources/DevTypeAppCore/StatsViewController.swift")
        XCTAssertTrue(stats.contains("lastRefreshedUsageRevision"))
        XCTAssertTrue(
            stats.contains("guard revision != self.lastRefreshedUsageRevision else { return }"),
            "the timer must compare the revision before recomputing"
        )
    }

    /// The revision it gates on has to actually move when usage is recorded.
    func testUsageRevisionMovesWhenUsageIsRecorded() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devtype-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UsageStatsStore(fileURL: url, flushInterval: 0, flushRetryDelay: 0)

        let before = store.revision
        store.recordUsage(for: UUID())
        XCTAssertNotEqual(store.revision, before, "a recorded expansion must move the revision")
    }

    // MARK: - Preferences panes (P11)

    /// All seven panes were built, constrained and left resident before the window appeared,
    /// with six of seven merely `isHidden`. Most users open one.
    func testPreferencesPanesAreBuiltOnFirstSelection() throws {
        let prefs = try source("Sources/DevTypeAppCore/PreferencesWindowController.swift")
        XCTAssertTrue(prefs.contains("private func ensurePane(_ tab: PreferencesTab) -> NSView?"))
        XCTAssertFalse(
            prefs.contains("for tab in PreferencesTab.visibleCases {\n            let pane = makeScrollingPane(for: tab)"),
            "the eager build loop is what this replaced"
        )
        // A pane built after `reloadAll()` has run must still be populated from preferences.
        XCTAssertTrue(prefs.contains("reload(tab)"))
    }

    func testSelectingATabBuildsItsPane() {
        _ = NSApplication.shared
        let controller = PreferencesViewController(hotkeyManager: nil)
        _ = controller.view
        defer { controller.viewWillDisappear() }

        controller.select(.advanced)
        let state = controller.localizationState()
        XCTAssertEqual(state.selectedTab, .advanced)
        XCTAssertNotNil(
            state.scrollOrigins[.advanced],
            "selecting a tab must build its pane, or nothing can be restored into it"
        )
    }

    // MARK: - Toast announcement (X1)

    /// The panel is deliberately non-activating and `ignoresMouseEvents`, so VoiceOver never
    /// moves focus to it. Without an announcement a screen-reader user performs the action and
    /// receives no confirmation that anything happened — across all of the app's toasts.
    func testToastsAnnounceThemselvesToVoiceOver() throws {
        let toast = try source("Sources/DevTypeAppCore/ToastPanel.swift")
        XCTAssertTrue(
            toast.contains("DevTypeAccessibility.announce("),
            "toasts are the app's primary transient feedback and must reach VoiceOver"
        )
        XCTAssertTrue(
            toast.contains("DevTypeAccessibility.reduceMotion"),
            "the fade was the only animation in the app ignoring Reduce Motion"
        )
        XCTAssertTrue(toast.contains("private static var queue: [Pending]"))
    }
}
