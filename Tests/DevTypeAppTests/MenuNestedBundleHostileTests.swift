import AppKit
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// Hostile cases for the menu nested lookup. The provider is a static the resolver
/// must read on every call; these tests never touch `SnippetStore.shared`.
final class MenuNestedBundleHostileTests: XCTestCase {

    override func tearDown() {
        Self.restoreFrontmostProvider()
        super.tearDown()
    }

    func testIncludeMatchIsCaseInsensitive() {
        defer { Self.restoreFrontmostProvider() }
        AppDelegate.nestedSnippetFrontmostBundleID = { "COM.APPLE.TEXTEDIT" }
        let lookup = AppDelegate().nestedSnippetLookup(groups: [group([
            snippet(";go", "in textedit", include: ["com.apple.TextEdit"]),
            snippet(";go", "anywhere")
        ])], revision: 1)
        XCTAssertEqual(lookup(";go"), "in textedit")
    }

    func testEmptyStringProviderUsesTheNilRule() {
        defer { Self.restoreFrontmostProvider() }
        AppDelegate.nestedSnippetFrontmostBundleID = { "" }
        let lookup = AppDelegate().nestedSnippetLookup(groups: [group([
            snippet(";in", "safari only", include: ["com.apple.Safari"]),
            snippet(";ex", "not in mail", exclude: ["com.apple.mail"]),
            snippet(";any", "anywhere")
        ])], revision: 1)
        XCTAssertNil(lookup(";in"))
        XCTAssertEqual(lookup(";ex"), "not in mail")
        XCTAssertEqual(lookup(";any"), "anywhere")
    }

    func testWhitespaceBundleIsNotNilAndDoesNotMatchNotes() {
        defer { Self.restoreFrontmostProvider() }
        AppDelegate.nestedSnippetFrontmostBundleID = { "   " }
        let lookup = AppDelegate().nestedSnippetLookup(groups: [group([
            snippet(";notes", "notes", include: ["Notes"]),
            snippet(";spaces", "spaces", include: ["   "])
        ])], revision: 1)
        XCTAssertNil(lookup(";notes"))
        XCTAssertEqual(
            lookup(";spaces"), "spaces",
            "a bundle of only spaces is a real bundle, so an include list of that string still matches"
        )
    }

    func testExcludeWinsOverIncludeForTheSameBundle() {
        defer { Self.restoreFrontmostProvider() }
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.Safari" }
        let lookup = AppDelegate().nestedSnippetLookup(groups: [group([
            snippet(
                ";go", "blocked",
                include: ["com.apple.Safari"],
                exclude: ["com.apple.Safari"]
            ),
            snippet(";go", "later")
        ])], revision: 1)
        XCTAssertEqual(lookup(";go"), "later")
        XCTAssertNotEqual(lookup(";go"), "blocked")
    }

    func testSecretThenDisabledDoNotHideTheEligibleReplacement() {
        defer { Self.restoreFrontmostProvider() }
        let leaked = "LEAKED-SECRET"
        var secret = snippet(";go", leaked, isSecret: true)
        secret.replacementText = leaked
        let disabled = snippet(";go", "disabled-body", enabled: false)
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.TextEdit" }
        let lookup = AppDelegate().nestedSnippetLookup(groups: [group([
            secret,
            disabled,
            snippet(";go", "eligible")
        ])], revision: 1)
        let answer = lookup(";go")
        XCTAssertEqual(answer, "eligible")
        XCTAssertNotEqual(answer, leaked)
        XCTAssertNotEqual(answer, "disabled-body")
    }

    func testExcludedEarlierSnippetDoesNotHideLaterAndSwapRestoresIt() {
        defer { Self.restoreFrontmostProvider() }
        var bundle = "com.apple.mail"
        AppDelegate.nestedSnippetFrontmostBundleID = { bundle }
        let lookup = AppDelegate().nestedSnippetLookup(groups: [group([
            snippet(";go", "not in mail", exclude: ["com.apple.mail"]),
            snippet(";go", "later")
        ])], revision: 1)
        XCTAssertEqual(lookup(";go"), "later")
        bundle = "com.apple.TextEdit"
        XCTAssertEqual(lookup(";go"), "not in mail")
    }

    func testCachedSameRevisionFollowsALaterProviderChange() {
        defer { Self.restoreFrontmostProvider() }
        let delegate = AppDelegate()
        let groups = [group([
            snippet(";go", "in textedit", include: ["com.apple.TextEdit"]),
            snippet(";go", "anywhere")
        ])]
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.TextEdit" }
        let first = delegate.nestedSnippetLookup(groups: groups, revision: 1)
        XCTAssertEqual(first(";go"), "in textedit")
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.Safari" }
        XCTAssertEqual(first(";go"), "anywhere")

        let second = delegate.nestedSnippetLookup(groups: groups, revision: 1)
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.TextEdit" }
        XCTAssertEqual(second(";go"), "in textedit")
    }

    func testDifferentRevisionFollowsTheProvider() {
        defer { Self.restoreFrontmostProvider() }
        let delegate = AppDelegate()
        let groups = [group([
            snippet(";go", "in textedit", include: ["com.apple.TextEdit"]),
            snippet(";go", "anywhere")
        ])]
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.TextEdit" }
        let first = delegate.nestedSnippetLookup(groups: groups, revision: 1)
        XCTAssertEqual(first(";go"), "in textedit")

        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.Safari" }
        let rebuilt = delegate.nestedSnippetLookup(groups: groups, revision: 2)
        XCTAssertEqual(rebuilt(";go"), "anywhere")
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.TextEdit" }
        XCTAssertEqual(rebuilt(";go"), "in textedit")
    }

    func testNewlineInBundleDoesNotMatchCleanInclude() {
        defer { Self.restoreFrontmostProvider() }
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.TextEdit\n" }
        let lookup = AppDelegate().nestedSnippetLookup(groups: [group([
            snippet(";go", "clean", include: ["com.apple.TextEdit"]),
            snippet(";go", "fallback")
        ])], revision: 1)
        XCTAssertEqual(lookup(";go"), "fallback")
        XCTAssertNotEqual(lookup(";go"), "clean")
    }

    func testSecondGroupAnswersWhenFirstGroupTriggerIsExcluded() {
        defer { Self.restoreFrontmostProvider() }
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.mail" }
        let groups = [
            SnippetGroup(name: "First", snippets: [
                snippet(";go", "first", exclude: ["com.apple.mail"])
            ]),
            SnippetGroup(name: "Second", snippets: [
                snippet(";go", "second")
            ])
        ]
        let lookup = AppDelegate().nestedSnippetLookup(groups: groups, revision: 1)
        XCTAssertEqual(lookup(";go"), "second")
    }

    func testProviderMayChangeOnEveryCall() {
        defer { Self.restoreFrontmostProvider() }
        var textEditNext = true
        AppDelegate.nestedSnippetFrontmostBundleID = {
            let textEdit = textEditNext
            textEditNext = !textEditNext
            return textEdit ? "com.apple.TextEdit" : "com.apple.Safari"
        }
        let lookup = AppDelegate().nestedSnippetLookup(groups: [group([
            snippet(";go", "in textedit", include: ["com.apple.TextEdit"]),
            snippet(";go", "anywhere")
        ])], revision: 1)
        let first = lookup(";go")
        let second = lookup(";go")
        XCTAssertEqual(first, "in textedit")
        XCTAssertEqual(second, "anywhere")
        XCTAssertNotEqual(first, second)
    }

    func testStaticProviderIsTheWorkspaceClosureAfterRestore() {
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.example.hostile" }
        defer { Self.restoreFrontmostProvider() }
        Self.restoreFrontmostProvider()
        XCTAssertEqual(
            AppDelegate.nestedSnippetFrontmostBundleID(),
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    private static func restoreFrontmostProvider() {
        AppDelegate.nestedSnippetFrontmostBundleID = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    }

    private func group(_ snippets: [SnippetModel]) -> SnippetGroup {
        SnippetGroup(name: "Hostile", snippets: snippets)
    }

    private func snippet(
        _ trigger: String,
        _ replacement: String,
        include: [String] = [],
        exclude: [String] = [],
        enabled: Bool = true,
        isSecret: Bool = false
    ) -> SnippetModel {
        SnippetModel(
            title: trigger,
            triggerKeyword: trigger,
            replacementText: replacement,
            enabled: enabled,
            includeApps: include,
            excludeApps: exclude,
            isSecret: isSecret
        )
    }
}
