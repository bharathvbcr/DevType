import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// The words the app-scope UI puts on screen.
///
/// The model rule itself (`appliesTo(bundleID:)`, and the matcher that consults it) is covered
/// in `ExpanderEngineTests/SnippetAppScopeTests` — it belongs with the engine, and asserting it
/// twice would leave two owners for one rule.
///
/// `SnippetModel.includeApps` / `excludeApps` have been honoured by the matcher on every
/// keystroke since §4.4, exported as `apps:` / `exclude_apps:`, and read back by
/// `EspansoImporter`. Nothing could create one without hand-editing the library JSON, so the
/// rule that mattered most — what happens when both lists are set — had never been stated
/// anywhere a user could see it.
final class SnippetAppScopeSummaryTests: XCTestCase {

    private let loc = LocalizationManager.shared

    private func snippet(include: [String] = [], exclude: [String] = []) -> SnippetModel {
        var s = SnippetModel(title: "T", triggerKeyword: ":t", replacementText: "v")
        s.includeApps = include
        s.excludeApps = exclude
        return s
    }

    // MARK: - Chip summary

    func testTheChipSaysAllAppsWhenNothingIsScoped() {
        XCTAssertEqual(
            SnippetAppScopeSummary.chipTitle(include: [], exclude: [], loc: loc),
            loc.s("appscope.chip.all")
        )
    }

    func testTheChipCountsAnIncludeList() {
        let title = SnippetAppScopeSummary.chipTitle(include: ["a", "b"], exclude: [], loc: loc)
        XCTAssertTrue(title.contains("2"), "the chip should say how many, got \"\(title)\"")
        XCTAssertNotEqual(title, loc.s("appscope.chip.all"))
    }

    func testTheChipCountsAnExcludeList() {
        let title = SnippetAppScopeSummary.chipTitle(include: [], exclude: ["a"], loc: loc)
        XCTAssertTrue(title.contains("1"))
        XCTAssertNotEqual(title, loc.s("appscope.chip.all"))
    }

    /// Singular and plural must differ, or the plural table entry is dead weight.
    func testTheChipDistinguishesOneAppFromSeveral() {
        XCTAssertNotEqual(
            SnippetAppScopeSummary.chipTitle(include: ["a"], exclude: [], loc: loc),
            SnippetAppScopeSummary.chipTitle(include: ["a", "b"], exclude: [], loc: loc)
        )
    }

    /// With both lists set the chip has to pick one story; it leads with the narrower rule.
    func testTheChipPrefersTheIncludeListWhenBothAreSet() {
        XCTAssertEqual(
            SnippetAppScopeSummary.chipTitle(include: ["a"], exclude: ["b"], loc: loc),
            SnippetAppScopeSummary.chipTitle(include: ["a"], exclude: [], loc: loc)
        )
    }

    // MARK: - Explanation

    /// Four distinct states must read as four distinct sentences — the "both" case is the one
    /// a user cannot infer, so it must not collapse into any of the others.
    func testEachScopeStateHasItsOwnSentence() {
        let sentences = [
            SnippetAppScopeSummary.explanation(include: [], exclude: [], loc: loc),
            SnippetAppScopeSummary.explanation(include: ["a"], exclude: [], loc: loc),
            SnippetAppScopeSummary.explanation(include: [], exclude: ["b"], loc: loc),
            SnippetAppScopeSummary.explanation(include: ["a"], exclude: ["b"], loc: loc),
        ]
        XCTAssertEqual(Set(sentences).count, 4, "each state needs its own wording")
        for sentence in sentences {
            XCTAssertFalse(sentence.hasPrefix("appscope."), "unresolved key: \(sentence)")
        }
    }

    // MARK: - Scope value

    func testIsScopedIsFalseOnlyWhenBothListsAreEmpty() {
        XCTAssertFalse(SnippetAppScope.unscoped.isScoped)
        XCTAssertTrue(SnippetAppScope(includeApps: ["a"], excludeApps: []).isScoped)
        XCTAssertTrue(SnippetAppScope(includeApps: [], excludeApps: ["b"]).isScoped)
        XCTAssertTrue(SnippetAppScope(includeApps: ["a"], excludeApps: ["b"]).isScoped)
    }

}
