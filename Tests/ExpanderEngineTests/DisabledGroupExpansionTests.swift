import XCTest
@testable import ExpanderEngine

/// Turning a group off must stop its triggers firing.
///
/// It did not. `group.enabled` was honoured by `SnippetExporter` (three call sites) and by
/// `SnippetSearch.makeIndex`, but nothing on the expansion path consulted it: the engine is fed
/// `groups.flatMap(\.snippets)` — in `SnippetDocument.snippets`, `loadSnippets()`, and the
/// listener payload that `AppDelegate` assigns to `EventTapEngine.shared.snippets` — and
/// `AbbreviationMatcher` only ever checks `snippet.enabled`.
///
/// So switching a group off changed what you could search and what you exported, and left every
/// trigger inside it still expanding. That is precisely the "control that looks live but changes
/// nothing" failure `ToggleChip.inertReason` exists elsewhere in this codebase to prevent.
final class DisabledGroupExpansionTests: XCTestCase {

    private func snippet(_ trigger: String, enabled: Bool = true) -> SnippetModel {
        var s = SnippetModel(title: trigger, triggerKeyword: trigger, replacementText: "value")
        s.enabled = enabled
        return s
    }

    private func match(_ trigger: String, in snippets: [SnippetModel]) -> AbbreviationMatch? {
        AbbreviationMatcher(snippets: snippets).match(characters: Array(trigger))
    }

    // MARK: - The bug

    func testATriggerInADisabledGroupDoesNotExpand() {
        let groups = [
            SnippetGroup(name: "Work", enabled: false, snippets: [snippet(":sig")])
        ]
        let live = SnippetStore.expandableSnippets(in: groups)
        XCTAssertNil(
            match(":sig", in: live),
            "a snippet in a disabled group must not match"
        )
    }

    /// The control: the same snippet in an enabled group still works, so the fix cannot have
    /// simply switched everything off.
    func testTheSameTriggerInAnEnabledGroupStillExpands() {
        let groups = [
            SnippetGroup(name: "Work", enabled: true, snippets: [snippet(":sig")])
        ]
        let live = SnippetStore.expandableSnippets(in: groups)
        XCTAssertNotNil(match(":sig", in: live))
    }

    func testOnlyTheDisabledGroupIsAffected() {
        let groups = [
            SnippetGroup(name: "Off", enabled: false, snippets: [snippet(":off")]),
            SnippetGroup(name: "On", enabled: true, snippets: [snippet(":on")]),
        ]
        let live = SnippetStore.expandableSnippets(in: groups)
        XCTAssertNil(match(":off", in: live))
        XCTAssertNotNil(match(":on", in: live))
    }

    // MARK: - Shape of the result

    /// Snippets are returned disabled rather than dropped, so anything counting the library
    /// still sees them — only their ability to fire changes.
    func testSnippetsFromADisabledGroupAreReturnedButDisabled() {
        let groups = [
            SnippetGroup(name: "Off", enabled: false, snippets: [snippet(":a"), snippet(":b")])
        ]
        let live = SnippetStore.expandableSnippets(in: groups)
        XCTAssertEqual(live.count, 2, "nothing is dropped")
        XCTAssertTrue(live.allSatisfy { !$0.enabled })
    }

    /// A snippet the user disabled individually stays disabled in an enabled group — the group
    /// flag may only ever subtract.
    func testAnIndividuallyDisabledSnippetStaysDisabledInAnEnabledGroup() {
        let groups = [
            SnippetGroup(name: "On", enabled: true, snippets: [snippet(":x", enabled: false)])
        ]
        let live = SnippetStore.expandableSnippets(in: groups)
        XCTAssertEqual(live.count, 1)
        XCTAssertFalse(live[0].enabled)
        XCTAssertNil(match(":x", in: live))
    }

    /// Enabling a group must not re-enable a snippet the user turned off by hand.
    func testAGroupToggleNeverReEnablesASnippet() {
        let off = snippet(":x", enabled: false)
        let groups = [SnippetGroup(name: "On", enabled: true, snippets: [off])]
        XCTAssertFalse(SnippetStore.expandableSnippets(in: groups)[0].enabled)
    }

    func testEverythingElseAboutASnippetSurvives() {
        var original = snippet(":sig")
        original.tags = ["invoice"]
        original.includeApps = ["com.apple.TextEdit"]
        original.replacementText = "Regards"
        let groups = [SnippetGroup(name: "Off", enabled: false, snippets: [original])]
        let live = SnippetStore.expandableSnippets(in: groups)[0]
        XCTAssertEqual(live.id, original.id)
        XCTAssertEqual(live.tags, original.tags)
        XCTAssertEqual(live.includeApps, original.includeApps)
        XCTAssertEqual(live.replacementText, original.replacementText)
    }

    func testAnEmptyLibraryIsHandled() {
        XCTAssertTrue(SnippetStore.expandableSnippets(in: []).isEmpty)
    }

    // MARK: - Secrets

    /// The same listener payload builds the secrets menu, so a disabled group must not keep
    /// offering its secrets either.
    func testASecretInADisabledGroupIsAlsoDisabled() {
        var secret = SnippetModel(title: "Token", triggerKeyword: "", replacementText: "")
        secret.isSecret = true
        let groups = [SnippetGroup(name: "Off", enabled: false, snippets: [secret])]
        let live = SnippetStore.expandableSnippets(in: groups)
        XCTAssertFalse(live[0].enabled)
    }
}
