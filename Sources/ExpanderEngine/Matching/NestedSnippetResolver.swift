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
/// occupies the folded key. So both tables record the library *position* and the smaller one wins.
public struct NestedSnippetResolver {

    /// Exact trigger -> position in library order. First writer wins.
    private let exactIndex: [String: Int]
    /// Lowercased trigger -> position, for case-insensitive snippets only. First writer wins.
    private let foldedIndex: [String: Int]
    private let replacements: [String]

    /// - Parameter excludingSecrets: drops keychain-backed snippets. Resolving one inside another
    ///   snippet would paste a password into whatever document the outer snippet lands in, with
    ///   no explicit gesture naming it.
    public init(snippets: [SnippetModel], excludingSecrets: Bool = false) {
        var exact: [String: Int] = [:]
        var folded: [String: Int] = [:]
        var texts: [String] = []
        texts.reserveCapacity(snippets.count)

        for snippet in snippets {
            if excludingSecrets && snippet.isSecret { continue }
            let position = texts.count
            texts.append(snippet.replacementText)
            if exact[snippet.triggerKeyword] == nil {
                exact[snippet.triggerKeyword] = position
            }
            if !snippet.isCaseSensitive {
                let key = snippet.triggerKeyword.lowercased()
                if folded[key] == nil { folded[key] = position }
            }
        }

        self.exactIndex = exact
        self.foldedIndex = folded
        self.replacements = texts
    }

    /// Replacement text for a nested reference, or `nil` when no snippet claims that trigger.
    public func replacement(for trigger: String) -> String? {
        let exactHit = exactIndex[trigger]
        // Only fold when the exact table missed or matched later than a folded candidate could.
        let foldedHit = foldedIndex[trigger.lowercased()]
        switch (exactHit, foldedHit) {
        case (nil, nil):
            return nil
        case let (position?, nil), let (nil, position?):
            return replacements[position]
        case let (left?, right?):
            return replacements[Swift.min(left, right)]
        }
    }

    /// The closure shape `MacroRenderer.expand` takes.
    public var lookup: (String) -> String? {
        { self.replacement(for: $0) }
    }
}
