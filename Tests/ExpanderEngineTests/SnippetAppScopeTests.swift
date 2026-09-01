import XCTest
@testable import ExpanderEngine

/// `SnippetModel.appliesTo(bundleID:)` and the matcher that consults it.
///
/// This gate has run on every keystroke since §4.4 — `AbbreviationMatcher` calls it at four
/// sites — and had no tests at all, because until now nothing in the UI could produce a scoped
/// snippet, so nobody had a reason to write one.
final class SnippetAppScopeTests: XCTestCase {

    private func snippet(
        trigger: String = ":sig",
        include: [String] = [],
        exclude: [String] = []
    ) -> SnippetModel {
        var s = SnippetModel(title: "Signature", triggerKeyword: trigger, replacementText: "Regards")
        s.includeApps = include
        s.excludeApps = exclude
        return s
    }

    // MARK: - Unscoped

    func testAnUnscopedSnippetAppliesEverywhere() {
        let s = snippet()
        XCTAssertTrue(s.appliesTo(bundleID: "com.apple.TextEdit"))
        XCTAssertTrue(s.appliesTo(bundleID: "com.microsoft.VSCode"))
        XCTAssertTrue(s.appliesTo(bundleID: nil))
        XCTAssertTrue(s.appliesTo(bundleID: ""))
    }

    // MARK: - Include list

    func testAnIncludeListAdmitsOnlyItsApps() {
        let s = snippet(include: ["com.apple.TextEdit"])
        XCTAssertTrue(s.appliesTo(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(s.appliesTo(bundleID: "com.microsoft.VSCode"))
    }

    /// The frontmost app cannot always be identified. A snippet restricted to a named app must
    /// not fire when we do not know where we are — the safe direction is to withhold.
    func testAnUnknownAppDoesNotSatisfyAnIncludeList() {
        let s = snippet(include: ["com.apple.TextEdit"])
        XCTAssertFalse(s.appliesTo(bundleID: nil))
        XCTAssertFalse(s.appliesTo(bundleID: ""))
    }

    func testIncludeMatchingIsCaseInsensitive() {
        let s = snippet(include: ["com.apple.TextEdit"])
        XCTAssertTrue(s.appliesTo(bundleID: "COM.APPLE.TEXTEDIT"))
        XCTAssertTrue(s.appliesTo(bundleID: "com.apple.textedit"))
    }

    // MARK: - Exclude list

    func testAnExcludeListBlocksItsAppsAndAdmitsTheRest() {
        let s = snippet(exclude: ["com.apple.Terminal"])
        XCTAssertFalse(s.appliesTo(bundleID: "com.apple.Terminal"))
        XCTAssertTrue(s.appliesTo(bundleID: "com.apple.TextEdit"))
    }

    /// An exclude-only snippet is unrestricted by default, so an unknown app is admitted —
    /// the opposite of the include case, and deliberately so.
    func testAnUnknownAppIsAdmittedByAnExcludeOnlySnippet() {
        let s = snippet(exclude: ["com.apple.Terminal"])
        XCTAssertTrue(s.appliesTo(bundleID: nil))
    }

    func testExcludeMatchingIsCaseInsensitive() {
        let s = snippet(exclude: ["com.apple.Terminal"])
        XCTAssertFalse(s.appliesTo(bundleID: "COM.APPLE.TERMINAL"))
    }

    // MARK: - Both lists

    /// Exclude wins. An import can set both, so this is reachable in real libraries and is what
    /// `SnippetAppScopeSummary.explanation` tells the user.
    func testExcludeTakesPrecedenceOverInclude() {
        let s = snippet(include: ["com.apple.Terminal"], exclude: ["com.apple.Terminal"])
        XCTAssertFalse(
            s.appliesTo(bundleID: "com.apple.Terminal"),
            "an app on both lists must be blocked, not admitted"
        )
    }

    func testBothListsStillRestrictToTheIncludeSet() {
        let s = snippet(include: ["com.apple.TextEdit"], exclude: ["com.apple.Terminal"])
        XCTAssertTrue(s.appliesTo(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(s.appliesTo(bundleID: "com.apple.Terminal"))
        XCTAssertFalse(s.appliesTo(bundleID: "com.microsoft.VSCode"))
    }

    // MARK: - Through the matcher

    private func match(_ snippets: [SnippetModel], typing text: String, in bundleID: String?) -> SnippetModel? {
        let matcher = AbbreviationMatcher(snippets: snippets)
        return matcher.match(characters: Array(text), bundleID: bundleID)?.snippet
    }

    func testTheMatcherWithholdsAScopedSnippetOutsideItsApp() {
        let scoped = snippet(trigger: ":sig", include: ["com.apple.TextEdit"])
        XCTAssertNotNil(match([scoped], typing: ":sig", in: "com.apple.TextEdit"))
        XCTAssertNil(
            match([scoped], typing: ":sig", in: "com.microsoft.VSCode"),
            "the trigger must simply not fire where the snippet does not apply"
        )
    }

    func testTheMatcherWithholdsAnExcludedSnippet() {
        let scoped = snippet(trigger: ":sig", exclude: ["com.apple.Terminal"])
        XCTAssertNil(match([scoped], typing: ":sig", in: "com.apple.Terminal"))
        XCTAssertNotNil(match([scoped], typing: ":sig", in: "com.apple.TextEdit"))
    }

    /// Two snippets can share a trigger when their scopes do not overlap — the per-app feature
    /// is only useful if the same abbreviation can mean different things in different apps.
    func testTwoAppScopedSnippetsCanShareATrigger() {
        let editor = snippet(trigger: ":sig", include: ["com.apple.TextEdit"])
        var terminal = snippet(trigger: ":sig", include: ["com.apple.Terminal"])
        terminal.replacementText = "# signed"

        let inEditor = match([editor, terminal], typing: ":sig", in: "com.apple.TextEdit")
        let inTerminal = match([editor, terminal], typing: ":sig", in: "com.apple.Terminal")
        XCTAssertEqual(inEditor?.replacementText, "Regards")
        XCTAssertEqual(inTerminal?.replacementText, "# signed")
    }

    func testAnUnscopedSnippetStillMatchesWhenTheAppIsUnknown() {
        let plain = snippet(trigger: ":sig")
        XCTAssertNotNil(match([plain], typing: ":sig", in: nil))
    }
}
