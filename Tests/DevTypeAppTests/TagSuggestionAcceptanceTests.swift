import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// The rule that a suggestion is an offer and not a change.
///
/// This is the first behaviour in `DevTypeAppCore` under a real unit test rather than a
/// source grep — the acceptance state is plain data precisely so it could be one.
final class TagSuggestionAcceptanceTests: XCTestCase {

    private func acceptance(
        tags: [String] = ["email", "billing"],
        group: String? = "Work"
    ) -> TagSuggestionAcceptance {
        TagSuggestionAcceptance(
            suggestion: SnippetTagSuggester.Suggestion(tags: tags, groupName: group)
        )
    }

    // MARK: - Nothing is applied by default

    /// The whole point: a suggestion the user never touches must not reach the snippet.
    func testAFreshSuggestionAppliesNothing() {
        let subject = acceptance()
        XCTAssertEqual(subject.tagsToApply, [])
        XCTAssertNil(subject.groupToApply)
        XCTAssertFalse(subject.isGroupAccepted)
    }

    func testAcceptingOneTagDoesNotAcceptTheOthers() {
        var subject = acceptance(tags: ["email", "billing", "urgent"])
        subject.setTag("billing", accepted: true)
        XCTAssertEqual(subject.tagsToApply, ["billing"])
    }

    func testAcceptingTagsLeavesTheGroupAlone() {
        var subject = acceptance()
        subject.setTag("email", accepted: true)
        XCTAssertNil(subject.groupToApply, "a tag chip must not drag the group along with it")
    }

    func testAcceptingTheGroupLeavesTheTagsAlone() {
        var subject = acceptance()
        subject.setGroupAccepted(true)
        XCTAssertEqual(subject.groupToApply, "Work")
        XCTAssertEqual(subject.tagsToApply, [])
    }

    // MARK: - Only what was suggested

    func testATagThatWasNeverSuggestedCannotBeAccepted() {
        var subject = acceptance(tags: ["email"])
        subject.setTag("invented", accepted: true)
        XCTAssertEqual(subject.tagsToApply, [], "acceptance must not be forgeable")
    }

    func testTheGroupCannotBeAcceptedWhenNoneWasSuggested() {
        var subject = acceptance(group: nil)
        subject.setGroupAccepted(true)
        XCTAssertFalse(subject.isGroupAccepted)
        XCTAssertNil(subject.groupToApply)
    }

    // MARK: - Order

    /// `SnippetTagSuggester.normalizedTags` preserves the model's ranking; accepting in a
    /// different order must not scramble it, or the stored tags depend on click sequence.
    func testAppliedTagsFollowTheSuggestionOrderNotTheClickOrder() {
        var subject = acceptance(tags: ["alpha", "beta", "gamma"])
        subject.setTag("gamma", accepted: true)
        subject.setTag("alpha", accepted: true)
        XCTAssertEqual(subject.tagsToApply, ["alpha", "gamma"])
    }

    // MARK: - Toggling off

    func testATagCanBeUnaccepted() {
        var subject = acceptance()
        subject.setTag("email", accepted: true)
        subject.setTag("email", accepted: false)
        XCTAssertEqual(subject.tagsToApply, [])
    }

    func testAcceptingTheSameTagTwiceAddsItOnce() {
        var subject = acceptance()
        subject.setTag("email", accepted: true)
        subject.setTag("email", accepted: true)
        XCTAssertEqual(subject.tagsToApply, ["email"])
    }

    func testTheGroupCanBeUnaccepted() {
        var subject = acceptance()
        subject.setGroupAccepted(true)
        subject.setGroupAccepted(false)
        XCTAssertNil(subject.groupToApply)
    }

    // MARK: - A manual choice wins

    /// Once the user picks a group in the popup, the suggested one is no longer what is
    /// selected — leaving it "accepted" would make the chip claim credit for their choice.
    func testChoosingAGroupManuallyRevokesTheSuggestedOne() {
        var subject = acceptance()
        subject.setGroupAccepted(true)
        subject.groupSelectionChangedManually()
        XCTAssertFalse(subject.isGroupAccepted)
        XCTAssertNil(subject.groupToApply)
    }

    /// The group and the tags are independent decisions; revoking one must not revoke the other.
    func testAManualGroupChoiceLeavesAcceptedTagsIntact() {
        var subject = acceptance()
        subject.setTag("email", accepted: true)
        subject.setGroupAccepted(true)
        subject.groupSelectionChangedManually()
        XCTAssertEqual(subject.tagsToApply, ["email"])
    }

    func testTheGroupCanBeAcceptedAgainAfterAManualChange() {
        var subject = acceptance()
        subject.groupSelectionChangedManually()
        subject.setGroupAccepted(true)
        XCTAssertEqual(subject.groupToApply, "Work")
    }

    // MARK: - Presentation

    func testAnEmptySuggestionOffersNothingToShow() {
        XCTAssertFalse(acceptance(tags: [], group: nil).hasAnythingToOffer)
    }

    func testATagOnlyOrGroupOnlySuggestionIsStillWorthShowing() {
        XCTAssertTrue(acceptance(tags: ["email"], group: nil).hasAnythingToOffer)
        XCTAssertTrue(acceptance(tags: [], group: "Work").hasAnythingToOffer)
    }

    // MARK: - Contract with the normalizer

    /// What the editor writes at save is `normalizedTags(tagsToApply, existing:)`. Accepted
    /// tags are already normalized, so that second pass must be a no-op rather than a filter
    /// that quietly drops what the user just switched on.
    func testAcceptedTagsSurviveTheSaveTimeRenormalization() {
        let suggested = SnippetTagSuggester.normalizedTags(["Email", "  Billing Notes "])
        var subject = acceptance(tags: suggested, group: nil)
        for tag in suggested { subject.setTag(tag, accepted: true) }
        XCTAssertEqual(
            SnippetTagSuggester.normalizedTags(subject.tagsToApply, existing: []),
            subject.tagsToApply
        )
        XCTAssertEqual(subject.tagsToApply, ["email", "billing notes"])
    }

    /// A tag the snippet already carries is dropped at save. That is correct — but it means
    /// the accepted set is not always what lands, so the save path must stay additive.
    func testAlreadyPresentTagsAreNotAddedTwice() {
        var subject = acceptance(tags: ["email", "billing"], group: nil)
        subject.setTag("email", accepted: true)
        subject.setTag("billing", accepted: true)
        XCTAssertEqual(
            SnippetTagSuggester.normalizedTags(subject.tagsToApply, existing: ["email"]),
            ["billing"]
        )
    }
}
