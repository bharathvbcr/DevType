import XCTest
@testable import ExpanderEngine

/// Group-level app scope, and how it composes with a snippet's own.
///
/// The composition rule is the whole feature: blocking unions, limiting intersects, and two
/// non-overlapping limits mean the snippet can never fire. That last case is the trap — an empty
/// `includeApps` means "everywhere", so an intersection written back naively turns two
/// contradictory limits into no limit at all.
final class GroupAppScopeTests: XCTestCase {

    private func snippet(include: [String] = [], exclude: [String] = []) -> SnippetModel {
        var s = SnippetModel(title: "T", triggerKeyword: ":t", replacementText: "v")
        s.includeApps = include
        s.excludeApps = exclude
        return s
    }

    private func live(
        groupInclude: [String] = [],
        groupExclude: [String] = [],
        snippetInclude: [String] = [],
        snippetExclude: [String] = [],
        groupEnabled: Bool = true
    ) -> SnippetModel {
        let group = SnippetGroup(
            name: "G",
            enabled: groupEnabled,
            includeApps: groupInclude,
            excludeApps: groupExclude,
            snippets: [snippet(include: snippetInclude, exclude: snippetExclude)]
        )
        return SnippetStore.expandableSnippets(in: [group])[0]
    }

    // MARK: - The group rule on its own

    func testAnUnscopedGroupAppliesEverywhere() {
        let group = SnippetGroup(name: "G")
        XCTAssertTrue(group.appliesTo(bundleID: "com.apple.TextEdit"))
        XCTAssertTrue(group.appliesTo(bundleID: nil))
    }

    func testAGroupIncludeListLimits() {
        let group = SnippetGroup(name: "G", includeApps: ["com.apple.TextEdit"])
        XCTAssertTrue(group.appliesTo(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(group.appliesTo(bundleID: "com.apple.Safari"))
        XCTAssertFalse(group.appliesTo(bundleID: nil))
    }

    func testAGroupExcludeListBlocks() {
        let group = SnippetGroup(name: "G", excludeApps: ["com.apple.Safari"])
        XCTAssertFalse(group.appliesTo(bundleID: "com.apple.Safari"))
        XCTAssertTrue(group.appliesTo(bundleID: "com.apple.TextEdit"))
    }

    func testGroupScopeMatchingIsCaseInsensitive() {
        XCTAssertTrue(SnippetGroup(name: "G", includeApps: ["COM.Apple.TextEdit"])
            .appliesTo(bundleID: "com.apple.textedit"))
    }

    // MARK: - Blocking unions

    func testAGroupBlockAppliesToEverySnippetInIt() {
        let s = live(groupExclude: ["com.apple.Safari"])
        XCTAssertFalse(s.appliesTo(bundleID: "com.apple.Safari"))
        XCTAssertTrue(s.appliesTo(bundleID: "com.apple.TextEdit"))
    }

    func testGroupAndSnippetBlocksBothApply() {
        let s = live(groupExclude: ["com.apple.Safari"], snippetExclude: ["com.apple.Mail"])
        XCTAssertFalse(s.appliesTo(bundleID: "com.apple.Safari"))
        XCTAssertFalse(s.appliesTo(bundleID: "com.apple.Mail"))
        XCTAssertTrue(s.appliesTo(bundleID: "com.apple.TextEdit"))
    }

    /// A block both levels name must not be stored twice.
    func testADuplicateBlockIsNotAddedAgain() {
        let s = live(groupExclude: ["com.apple.Safari"], snippetExclude: ["COM.APPLE.Safari"])
        XCTAssertEqual(s.excludeApps.count, 1)
    }

    // MARK: - Limiting intersects

    func testAGroupLimitAppliesWhenTheSnippetHasNone() {
        let s = live(groupInclude: ["com.apple.TextEdit"])
        XCTAssertTrue(s.appliesTo(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(s.appliesTo(bundleID: "com.apple.Safari"))
    }

    func testOverlappingLimitsIntersect() {
        let s = live(
            groupInclude: ["com.apple.TextEdit", "com.apple.Mail"],
            snippetInclude: ["com.apple.Mail", "com.apple.Safari"]
        )
        XCTAssertTrue(s.appliesTo(bundleID: "com.apple.Mail"), "the app both lists allow")
        XCTAssertFalse(s.appliesTo(bundleID: "com.apple.TextEdit"), "only the group allowed it")
        XCTAssertFalse(s.appliesTo(bundleID: "com.apple.Safari"), "only the snippet allowed it")
    }

    /// The trap: an empty intersection must not read as "everywhere".
    func testContradictoryLimitsDisableTheSnippetRatherThanFreeingIt() {
        let s = live(
            groupInclude: ["com.apple.TextEdit"],
            snippetInclude: ["com.apple.Safari"]
        )
        XCTAssertFalse(
            s.enabled,
            "two limits that share nothing mean the snippet can never fire — it must not "
                + "collapse to an empty includeApps, which means everywhere"
        )
    }

    /// Belt and braces on the same case, through the matcher rather than the flag.
    func testAContradictorilyScopedSnippetMatchesNowhere() {
        let group = SnippetGroup(
            name: "G",
            includeApps: ["com.apple.TextEdit"],
            snippets: [{
                var s = SnippetModel(title: "T", triggerKeyword: ":t", replacementText: "v")
                s.includeApps = ["com.apple.Safari"]
                return s
            }()]
        )
        let matcher = AbbreviationMatcher(snippets: SnippetStore.expandableSnippets(in: [group]))
        for app in ["com.apple.TextEdit", "com.apple.Safari", "com.apple.Mail"] {
            XCTAssertNil(
                matcher.match(characters: Array(":t"), bundleID: app),
                "must not fire in \(app)"
            )
        }
    }

    // MARK: - Interaction with the enabled flag

    func testADisabledGroupStillWinsOverAMatchingScope() {
        let s = live(groupInclude: ["com.apple.TextEdit"], groupEnabled: false)
        XCTAssertFalse(s.enabled)
    }

    /// An unscoped group must leave its snippets byte-identical, so the fold cannot become a
    /// tax every library pays.
    func testAnUnscopedGroupChangesNothing() {
        let original = snippet(include: ["com.apple.Mail"], exclude: ["com.apple.Safari"])
        let group = SnippetGroup(name: "G", snippets: [original])
        let result = SnippetStore.expandableSnippets(in: [group])[0]
        XCTAssertEqual(result, original)
    }

    func testGroupScopeSurvivesACodableRoundTrip() throws {
        let group = SnippetGroup(
            name: "G",
            includeApps: ["com.apple.TextEdit"],
            excludeApps: ["com.apple.Safari"]
        )
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(SnippetGroup.self, from: data)
        XCTAssertEqual(decoded.includeApps, group.includeApps)
        XCTAssertEqual(decoded.excludeApps, group.excludeApps)
    }

    /// A library written before this feature has neither key; it must decode as unscoped rather
    /// than fail.
    func testALibraryWithoutTheKeysDecodesAsUnscoped() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"G","snippets":[]}"#
        let decoded = try JSONDecoder().decode(SnippetGroup.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.includeApps.isEmpty)
        XCTAssertTrue(decoded.excludeApps.isEmpty)
        XCTAssertTrue(decoded.appliesTo(bundleID: "com.apple.TextEdit"))
    }
}
