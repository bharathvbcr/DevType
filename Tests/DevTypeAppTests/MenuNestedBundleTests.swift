import AppKit
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// Menu and secret-copy nested lookup must apply snippet include and exclude lists
/// against the frontmost app, read again on every call.
final class MenuNestedBundleTests: XCTestCase {

    override func tearDown() {
        Self.restoreFrontmostProvider()
        super.tearDown()
    }

    func testFrontmostBundleSelectsIncludeMatchOtherwiseTheUnscopedSnippet() {
        defer { Self.restoreFrontmostProvider() }
        let groups = [group(snippets: [
            menuSnippet(
                title: "textedit",
                trigger: ";go",
                replacement: "in textedit",
                include: ["com.apple.TextEdit"]
            ),
            menuSnippet(title: "anywhere", trigger: ";go", replacement: "anywhere")
        ])]

        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.Safari" }
        let safari = AppDelegate().nestedSnippetLookup(groups: groups, revision: 1)
        XCTAssertEqual(safari(";go"), "anywhere")

        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.TextEdit" }
        let textEdit = AppDelegate().nestedSnippetLookup(groups: groups, revision: 2)
        XCTAssertEqual(textEdit(";go"), "in textedit")
    }

    func testSameLookupClosureFollowsAReplacedFrontmostProvider() {
        defer { Self.restoreFrontmostProvider() }
        let groups = [group(snippets: [
            menuSnippet(
                title: "textedit",
                trigger: ";go",
                replacement: "in textedit",
                include: ["com.apple.TextEdit"]
            ),
            menuSnippet(title: "anywhere", trigger: ";go", replacement: "anywhere")
        ])]
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.TextEdit" }
        let lookup = AppDelegate().nestedSnippetLookup(groups: groups, revision: 1)
        XCTAssertEqual(lookup(";go"), "in textedit")

        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.Safari" }
        XCTAssertEqual(
            lookup(";go"), "anywhere",
            "the bundle is read from the static on each lookup, not captured when the resolver is built"
        )
    }

    func testNilBundleSkipsIncludeOnlyAndKeepsExcludeOnlyAndUnscoped() {
        defer { Self.restoreFrontmostProvider() }
        AppDelegate.nestedSnippetFrontmostBundleID = { nil }
        let lookup = AppDelegate().nestedSnippetLookup(groups: [group(snippets: [
            menuSnippet(
                title: "include",
                trigger: ";in",
                replacement: "safari only",
                include: ["com.apple.Safari"]
            ),
            menuSnippet(
                title: "exclude",
                trigger: ";ex",
                replacement: "not in mail",
                exclude: ["com.apple.mail"]
            ),
            menuSnippet(title: "open", trigger: ";any", replacement: "anywhere")
        ])], revision: 1)

        XCTAssertNil(lookup(";in"), "an include list matches nothing when the frontmost app is unknown")
        XCTAssertEqual(lookup(";ex"), "not in mail")
        XCTAssertEqual(lookup(";any"), "anywhere")
    }

    func testExcludedBundleYieldsToALaterEligibleSnippet() {
        defer { Self.restoreFrontmostProvider() }
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.mail" }
        let lookup = AppDelegate().nestedSnippetLookup(groups: [group(snippets: [
            menuSnippet(
                title: "blocked",
                trigger: ";go",
                replacement: "not in mail",
                exclude: ["com.apple.mail"]
            ),
            menuSnippet(title: "later", trigger: ";go", replacement: "later"),
            menuSnippet(
                title: "only blocked",
                trigger: ";only",
                replacement: "hidden",
                exclude: ["com.apple.mail"]
            )
        ])], revision: 1)

        XCTAssertNil(lookup(";only"))
        XCTAssertEqual(lookup(";go"), "later")
    }

    func testSecretAndDisabledSnippetsDoNotAnswer() {
        defer { Self.restoreFrontmostProvider() }
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.apple.TextEdit" }
        let lookup = AppDelegate().nestedSnippetLookup(groups: [group(snippets: [
            menuSnippet(title: "secret", trigger: ";go", replacement: "secret", isSecret: true),
            menuSnippet(title: "off", trigger: ";go", replacement: "disabled", enabled: false),
            menuSnippet(title: "on", trigger: ";go", replacement: "enabled"),
            menuSnippet(title: "secret only", trigger: ";sec", replacement: "secret", isSecret: true),
            menuSnippet(title: "disabled only", trigger: ";off", replacement: "disabled", enabled: false)
        ])], revision: 1)

        XCTAssertNil(lookup(";sec"))
        XCTAssertNil(lookup(";off"))
        XCTAssertEqual(lookup(";go"), "enabled")
    }

    func testFrontmostProviderRestoresToTheWorkspaceApp() {
        AppDelegate.nestedSnippetFrontmostBundleID = { "com.example.not-real" }
        XCTAssertEqual(AppDelegate.nestedSnippetFrontmostBundleID(), "com.example.not-real")
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

    private func group(snippets: [SnippetModel]) -> SnippetGroup {
        SnippetGroup(name: "Menu", snippets: snippets)
    }

    private func menuSnippet(
        title: String,
        trigger: String,
        replacement: String,
        include: [String] = [],
        exclude: [String] = [],
        enabled: Bool = true,
        isSecret: Bool = false
    ) -> SnippetModel {
        SnippetModel(
            title: title,
            triggerKeyword: trigger,
            replacementText: replacement,
            enabled: enabled,
            includeApps: include,
            excludeApps: exclude,
            isSecret: isSecret
        )
    }
}
