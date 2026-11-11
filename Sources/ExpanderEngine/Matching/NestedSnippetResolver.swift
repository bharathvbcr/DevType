import Foundation

/// Resolves `{{snippet:trigger}}` references to replacement text.
///
/// Five call sites had written this out by hand as
/// `snippets.first { $0.triggerKeyword == trigger || (!$0.isCaseSensitive && …lowercased() == …) }`
/// — a linear scan with a `lowercased()` allocation per candidate, run once per nested reference.
/// One of those copies sat inside the CGEventTap callback, where the cost scales with the whole
/// library on the keystroke that expands a snippet.
///
/// The precedence rule the hand-written scan implements is subtle enough to be worth stating: it
/// returns the **first snippet in library order** that matches *either* exactly or case-folded.
/// That is not the same as "try the exact table, then the folded one" — a case-sensitive snippet
/// appearing earlier must not answer a query that differs from it only in case, even though it
/// occupies the folded key in a naive two-table scheme. So both tables record the library
/// *position* and the smaller one wins, among candidates that are actually eligible.
///
/// Eligibility is decided in two places. Secrets and disabled snippets are never indexed: a
/// first-writer slot held by one of them would hide a later snippet with the same trigger.
/// App scope is not decided at init — one snapshot is shared across apps — so each key keeps
/// every indexed candidate in library order, and lookup skips those that do not `appliesTo`
/// the bundle `frontmostBundleID` returns. An excluded earlier snippet must not keep the slot.
public struct NestedSnippetResolver {

    private struct Candidate {
        let position: Int
        let snippet: SnippetModel
    }

    /// Exact trigger -> candidates in library order.
    private let exactIndex: [String: [Candidate]]
    /// Lowercased trigger -> candidates, for case-insensitive snippets only, in library order.
    private let foldedIndex: [String: [Candidate]]
    /// Read at lookup, not at init. The default is an unknown app (`nil`), which is
    /// `appliesTo`'s rule: an include list matches nothing, an exclude-only snippet still matches.
    private let frontmostBundleID: () -> String?

    /// Secrets are **always** dropped, and the caller is not offered a say.
    ///
    /// Resolving one inside another snippet would put a secret into whatever document the outer
    /// snippet lands in, with no explicit gesture naming it — the opposite of the deliberate
    /// menu/palette gesture every other secret route requires. This used to be an
    /// `excludingSecrets` flag defaulting to `false`: both production callers passed `true`, so
    /// nothing leaked, but the default was fail-open and the next caller to write
    /// `NestedSnippetResolver(snippets: library)` would have inherited the unsafe behaviour
    /// silently. A secret also carries no trigger to resolve (`snippetAdapter` leaves it empty),
    /// so indexing one could only ever shadow the `""` key. Unrepresentable beats guarded.
    ///
    /// Disabled snippets are dropped for the same slot reason. `frontmostBundleID` defaults to
    /// `{ nil }` so a direct init stays unscoped: no app is injected, and `appliesTo(nil)` applies.
    public init(
        snippets: [SnippetModel],
        frontmostBundleID: @escaping () -> String? = { nil }
    ) {
        var exact: [String: [Candidate]] = [:]
        var folded: [String: [Candidate]] = [:]
        exact.reserveCapacity(snippets.count)
        folded.reserveCapacity(snippets.count)

        for (position, snippet) in snippets.enumerated() {
            if snippet.isSecret || !snippet.enabled { continue }
            let candidate = Candidate(position: position, snippet: snippet)
            exact[snippet.triggerKeyword, default: []].append(candidate)
            if !snippet.isCaseSensitive {
                folded[snippet.triggerKeyword.lowercased(), default: []].append(candidate)
            }
        }

        self.exactIndex = exact
        self.foldedIndex = folded
        self.frontmostBundleID = frontmostBundleID
    }

    /// Replacement text for a nested reference, or `nil` when no eligible snippet claims that trigger.
    public func replacement(for trigger: String) -> String? {
        let bundleID = frontmostBundleID()
        let exactHit = firstEligible(exactIndex[trigger], bundleID: bundleID)
        // Fold even when an exact candidate exists: an earlier case-insensitive snippet must beat
        // a later exact one. A case-sensitive snippet is not in this table, so it cannot shadow
        // a folded query.
        let foldedHit = firstEligible(foldedIndex[trigger.lowercased()], bundleID: bundleID)
        switch (exactHit, foldedHit) {
        case (nil, nil):
            return nil
        case let (hit?, nil), let (nil, hit?):
            return hit.snippet.replacementText
        case let (left?, right?):
            let winner = left.position <= right.position ? left : right
            return winner.snippet.replacementText
        }
    }

    /// The closure shape `MacroRenderer.expand` takes. It reads `frontmostBundleID` on each call.
    public var lookup: (String) -> String? {
        { self.replacement(for: $0) }
    }

    private func firstEligible(_ candidates: [Candidate]?, bundleID: String?) -> Candidate? {
        candidates?.first { $0.snippet.appliesTo(bundleID: bundleID) }
    }
}
