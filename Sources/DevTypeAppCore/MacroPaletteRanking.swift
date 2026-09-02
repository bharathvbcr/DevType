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
        let name = descriptor.name(using: loc).lowercased()
        let token = descriptor.token.lowercased()
        let keywords = descriptor.keywords.lowercased()
        let detail = descriptor.detail(using: loc).lowercased()
        let category = categoryTitle.lowercased()

        return terms.map { term -> Int? in
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

        let titles = Dictionary(
            uniqueKeysWithValues: MacroCategory.allCases.map { ($0, loc.s($0.titleKey)) }
        )

        // Score everything first: whether an unmatched word is forgivable depends on whether
        // any macro in the catalogue understands it, which is not knowable one macro at a time.
        var perMacro: [(descriptor: MacroDescriptor, category: MacroCategory, scores: [Int?])] = []
        var discriminating = [Bool](repeating: false, count: scoredTerms.count)
        for category in MacroCategory.allCases {
            let title = titles[category] ?? ""
            for descriptor in MacroCatalog.descriptors(in: category) {
                let scores = termScores(
                    descriptor, terms: scoredTerms, categoryTitle: title, loc: loc
                )
                for (index, value) in scores.enumerated()
                where (value ?? 0) >= CommandPaletteCatalog.minimumDiscriminatingTermScore {
                    discriminating[index] = true
                }
                perMacro.append((descriptor, category, scores))
            }
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
