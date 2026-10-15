import Foundation
import ExpanderEngine

/// Relevance and personalization for the macro palette (⌥⌘M).
///
/// The macro palette used to be a boolean `contains` filter over one flattened haystack in
/// fixed catalogue order: a term hitting the *category title* counted exactly as much as one
/// hitting the macro's own name, and how often you had actually used a macro counted for
/// nothing. That left the app with two palettes ranking by two different rules, only one of
/// which learned anything.
///
/// Field weights and the coverage rule are taken from `CommandPaletteCatalog` rather than
/// reimplemented, so the two palettes cannot drift apart.
enum MacroPaletteRanking {

    struct Match: Equatable {
        let descriptor: MacroDescriptor
        let score: Int

        static func == (lhs: Match, rhs: Match) -> Bool {
            lhs.descriptor.id == rhs.descriptor.id && lhs.score == rhs.score
        }
    }

    struct Section: Equatable {
        let category: MacroCategory
        let matches: [Match]
    }

    /// Usage key for a macro. Namespaced so macro ids can never collide with the palette
    /// command ids that share `CommandUsageStatsStore`.
    static func usageID(_ descriptor: MacroDescriptor) -> String { "macro.\(descriptor.id)" }

    /// Per-term relevance across name, token, engine keywords, description and category title,
    /// so "tomorrow", "%uuid%", "fill" and "Dynamic" all still find something — but ranked
    /// rather than merely filtered.
    static func termScores(
        _ descriptor: MacroDescriptor,
        terms: [String],
        categoryTitle: String,
        loc: LocalizationManager
    ) -> [Int?] {
        fieldScores(
            name: descriptor.name(using: loc).lowercased(),
            token: descriptor.token.lowercased(),
            keywords: descriptor.keywords.lowercased(),
            detail: descriptor.detail(using: loc).lowercased(),
            category: categoryTitle.lowercased(),
            terms: terms
        )
    }

    /// Already-folded fields. `rank` serves these from the per-language index; `termScores`
    /// folds on the way in so the two paths cannot drift.
    private static func fieldScores(
        name: String,
        token: String,
        keywords: String,
        detail: String,
        category: String,
        terms: [String]
    ) -> [Int?] {
        terms.map { term -> Int? in
            if name == term || token == term { return 1000 }
            if token.contains(term) { return 920 }
            if name.hasPrefix(term) { return 900 }
            if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains(where: { $0.hasPrefix(term) }) { return 860 }
            if name.contains(term) { return 750 }
            if keywords.split(whereSeparator: { $0 == " " || $0 == "," })
                .contains(where: { $0 == term || $0.hasPrefix(term) }) { return 820 }
            if keywords.contains(term) { return 700 }
            if detail.contains(term) { return 420 }
            if category.contains(term) { return 400 }
            return nil
        }
    }

    private struct FoldedEntry {
        let descriptor: MacroDescriptor
        let category: MacroCategory
        let name: String
        let token: String
        let keywords: String
        let detail: String
        let categoryTitle: String
    }

    private static let foldedLock = NSLock()
    private static var foldedCache: (language: AppLanguage, entries: [FoldedEntry])?

    /// One lowercasing of the catalogue per UI language. `rank` used to fold every field of
    /// every macro on every keystroke. The catalogue itself is static.
    private static func foldedEntries(loc: LocalizationManager) -> [FoldedEntry] {
        let language = loc.language
        foldedLock.lock()
        if let foldedCache, foldedCache.language == language {
            let entries = foldedCache.entries
            foldedLock.unlock()
            return entries
        }
        foldedLock.unlock()

        var entries: [FoldedEntry] = []
        for category in MacroCategory.allCases {
            let title = loc.s(category.titleKey).lowercased()
            // One catalogue: the editor inserts `CommandPaletteCatalog.macros`, and
            // this ranking walks that same table. A private copy here would let the
            // rows a person picks drift from the tokens that land in the snippet.
            // `macros(in:)` is the section order the palette already shows.
            for descriptor in CommandPaletteCatalog.macros(in: category) {
                entries.append(FoldedEntry(
                    descriptor: descriptor,
                    category: category,
                    name: descriptor.name(using: loc).lowercased(),
                    token: descriptor.token.lowercased(),
                    keywords: descriptor.keywords.lowercased(),
                    detail: descriptor.detail(using: loc).lowercased(),
                    categoryTitle: title
                ))
            }
        }

        foldedLock.lock()
        if loc.language == language {
            foldedCache = (language, entries)
        }
        foldedLock.unlock()
        return entries
    }

    /// Ranked sections for a query.
    ///
    /// With no query this is a reference list, so catalogue order is the useful order and is
    /// left untouched. Once the user types, relevance leads and usage breaks ties.
    static func rank(
        query: String,
        loc: LocalizationManager,
        usageBoost: (String) -> Int = { CommandUsageStatsStore.shared.rankBoost(for: $0) }
    ) -> [Section] {
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: " ")
            .map(String.init)
        let scoredTerms = CommandPaletteCatalog.contentTerms(terms)
        let browsing = scoredTerms.isEmpty

        // Score everything first: whether an unmatched word is forgivable depends on whether
        // any macro in the catalogue understands it, which is not knowable one macro at a time.
        // Fields are already folded for this language; see `foldedEntries`.
        var perMacro: [(descriptor: MacroDescriptor, category: MacroCategory, scores: [Int?])] = []
        var discriminating = [Bool](repeating: false, count: scoredTerms.count)
        for entry in foldedEntries(loc: loc) {
            let scores = fieldScores(
                name: entry.name,
                token: entry.token,
                keywords: entry.keywords,
                detail: entry.detail,
                category: entry.categoryTitle,
                terms: scoredTerms
            )
            for (index, value) in scores.enumerated()
            where (value ?? 0) >= CommandPaletteCatalog.minimumDiscriminatingTermScore {
                discriminating[index] = true
            }
            perMacro.append((entry.descriptor, entry.category, scores))
        }

        var ranked: [MacroCategory: [Match]] = [:]
        for item in perMacro {
            let relevance: Int
            if browsing {
                relevance = 0
            } else if let value = CommandPaletteCatalog.combinedScore(
                termScores: item.scores, discriminating: discriminating
            ) {
                relevance = value
            } else {
                continue
            }
            ranked[item.category, default: []].append(
                Match(descriptor: item.descriptor, score: relevance + usageBoost(usageID(item.descriptor)))
            )
        }

        let ordered: [MacroCategory] = browsing
            ? MacroCategory.allCases
            : MacroCategory.allCases.sorted {
                (ranked[$0]?.map(\.score).max() ?? Int.min)
                    > (ranked[$1]?.map(\.score).max() ?? Int.min)
            }

        return ordered.compactMap { category in
            guard var matches = ranked[category], !matches.isEmpty else { return nil }
            if !browsing {
                matches.sort {
                    $0.score != $1.score
                        ? $0.score > $1.score
                        : $0.descriptor.token.count < $1.descriptor.token.count
                }
            }
            return Section(category: category, matches: matches)
        }
    }
}
