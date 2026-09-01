import Foundation
import ExpanderEngine

/// Which parts of a `SnippetTagSuggester.Suggestion` the user has actually accepted.
///
/// A suggestion is an offer, not a change. Nothing here is applied to a snippet until the user
/// turns the corresponding chip on, and this type is the record of that: the editor sheet asks
/// it what to write at save time rather than tracking acceptance across a handful of view
/// properties that can disagree with each other.
///
/// Two rules it exists to hold:
///
/// 1. **Nothing can be accepted that was never suggested.** `tagsToApply` reads through the
///    suggestion rather than replaying what was clicked, so no code path can add a tag the
///    model did not propose and the normalizer did not clear.
/// 2. **A manual group choice ends the suggestion's claim on the popup.** Once the user picks
///    a group themselves, the suggested one is no longer accepted — the chip stops reading as
///    though it is responsible for a selection it did not make.
struct TagSuggestionAcceptance: Equatable {

    /// The offer. Immutable — a new suggestion replaces the whole value.
    let suggestion: SnippetTagSuggester.Suggestion

    /// Accepted tags, held as a set because click order is not selection order.
    private var acceptedTags: Set<String> = []

    private(set) var isGroupAccepted = false

    init(suggestion: SnippetTagSuggester.Suggestion) {
        self.suggestion = suggestion
    }

    // MARK: - Tags

    mutating func setTag(_ tag: String, accepted: Bool) {
        if accepted {
            acceptedTags.insert(tag)
        } else {
            acceptedTags.remove(tag)
        }
    }

    /// The tags to write, in the model's ranking rather than in click order — the same order
    /// `SnippetTagSuggester.normalizedTags` took care to preserve.
    ///
    /// Reading *through* the suggestion rather than out of `acceptedTags` is what enforces
    /// rule 1: a string that was never offered cannot appear here however it got into the
    /// accepted set. `setTag` deliberately does not re-check the same thing — one rule, one
    /// owner, and this is the owner that also fixes the order.
    var tagsToApply: [String] {
        suggestion.tags.filter { acceptedTags.contains($0) }
    }

    // MARK: - Group

    /// The group the user accepted, or `nil` — including when there was nothing to accept.
    var groupToApply: String? {
        isGroupAccepted ? suggestion.groupName : nil
    }

    mutating func setGroupAccepted(_ accepted: Bool) {
        guard suggestion.groupName != nil else { return }
        isGroupAccepted = accepted
    }

    /// The user changed the group popup themselves. Their choice stands; the suggestion's
    /// does not get to sit alongside it looking accepted.
    mutating func groupSelectionChangedManually() {
        isGroupAccepted = false
    }

    // MARK: - Presentation

    /// Whether there is anything to show a chip for at all.
    var hasAnythingToOffer: Bool {
        !suggestion.tags.isEmpty || suggestion.groupName != nil
    }
}
