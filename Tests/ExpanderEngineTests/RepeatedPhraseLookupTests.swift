import XCTest
@testable import ExpanderEngine

/// "You already have a snippet for this."
///
/// Typing something three times by hand when a snippet already covers it means the trigger was
/// forgotten, not missing. Creating a second snippet there would duplicate the library and
/// withhold the one fact that would have helped.
final class RepeatedPhraseLookupTests: XCTestCase {

    private let body = "thanks for getting back to me"

    private func library(_ snippets: [SnippetModel], groupEnabled: Bool = true) -> [SnippetGroup] {
        var group = SnippetGroup(name: "G", snippets: snippets)
        group.enabled = groupEnabled
        return [group]
    }

    private func snippet(
        _ trigger: String,
        body: String,
        enabled: Bool = true,
        secret: Bool = false
    ) -> SnippetModel {
        var s = SnippetModel(
            title: "T", triggerKeyword: trigger, replacementText: body, enabled: enabled,
            isSecret: secret
        )
        s.tags = []
        return s
    }

    func testAMatchingSnippetIsFound() {
        let groups = library([snippet(":ty", body: body)])
        XCTAssertEqual(
            RepeatedPhraseLookup.existingSnippet(for: body, in: groups)?.triggerKeyword,
            ":ty"
        )
    }

    /// Matched on the detector's own normalization, or the reminder would miss the very casing
    /// differences the detector deliberately folds together.
    func testCasingAndSpacingDoNotHideTheMatch() {
        let groups = library([snippet(":ty", body: "Thanks for getting back to me")])
        XCTAssertNotNil(
            RepeatedPhraseLookup.existingSnippet(for: "thanks  for GETTING back to me", in: groups)
        )
    }

    func testAnUnrelatedLibraryYieldsNothing() {
        let groups = library([snippet(":other", body: "something else entirely")])
        XCTAssertNil(RepeatedPhraseLookup.existingSnippet(for: body, in: groups))
    }

    // MARK: - Snippets that cannot type it

    func testADisabledSnippetDoesNotCount() {
        let groups = library([snippet(":ty", body: body, enabled: false)])
        XCTAssertNil(
            RepeatedPhraseLookup.existingSnippet(for: body, in: groups),
            "a disabled snippet cannot type it, so the reminder would be wrong"
        )
    }

    /// The group-disable rule folds in through `expandableSnippets`, so this stays correct
    /// without restating it.
    func testASnippetInADisabledGroupDoesNotCount() {
        let groups = library([snippet(":ty", body: body)], groupEnabled: false)
        XCTAssertNil(RepeatedPhraseLookup.existingSnippet(for: body, in: groups))
    }

    func testASecretDoesNotCount() {
        let groups = library([snippet(":pw", body: body, secret: true)])
        XCTAssertNil(RepeatedPhraseLookup.existingSnippet(for: body, in: groups))
    }

    func testAnEmptyPhraseMatchesNothing() {
        let groups = library([snippet(":empty", body: "")])
        XCTAssertNil(RepeatedPhraseLookup.existingSnippet(for: "   ", in: groups))
    }

    func testAnEmptyLibraryMatchesNothing() {
        XCTAssertNil(RepeatedPhraseLookup.existingSnippet(for: body, in: []))
    }
}
