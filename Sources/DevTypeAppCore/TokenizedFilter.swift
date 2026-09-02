import Foundation

/// Free-text filtering for the app's short, labelled lists (AI actions, the shortcut
/// reference).
///
/// These panels each tested `field.contains(query)` against the *whole* query string, so a
/// multi-word query only matched when those words happened to sit adjacent, in that order,
/// inside one field. "sig email" found nothing even with both words plainly on the row, and
/// no query could ever span two fields. The palette and the snippet manager both tokenize;
/// these did not, so the same words behaved differently depending on which box you typed in.
///
/// Deliberately not ranked. These lists are short and already grouped in a meaningful order —
/// a shortcut reference that reshuffles itself as you type is harder to read, not easier.
/// Ranking belongs to `CommandPaletteCatalog` and `SnippetSearch`, where the catalogue is
/// large enough that position carries information.
enum TokenizedFilter {

    /// True when every word in `query` appears in at least one field.
    ///
    /// Conjunctive on purpose: this is a narrowing tool over a list the user can already see,
    /// so forgiving an unmatched word would widen the result instead of sharpening it. That is
    /// the opposite of the palette's rule, where an unfamiliar word in a natural-language
    /// phrase should not blank the list.
    static func matches(query: String, fields: [String]) -> Bool {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = fields.map { $0.lowercased() }
        return terms.allSatisfy { term in haystack.contains { $0.contains(term) } }
    }
}
