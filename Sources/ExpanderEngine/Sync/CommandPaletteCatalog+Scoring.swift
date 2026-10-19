import Foundation
import NaturalLanguage

extension CommandPaletteCatalog {

    // MARK: - Scoring

    /// A partial match must land at least one term on a trigger, alias or title. Without
    /// this floor a single stray substring hit inside a search blob would admit the whole
    /// catalogue on any multi-word query.
    public static let minimumPartialTermScore = 700

    /// Score at which a term counts as one the catalogue *understands*, and so may veto a
    /// command that misses it.
    ///
    /// Higher than the admission floor on purpose: every tier at or above 800 is a match at a
    /// word boundary — an exact trigger, alias or title, or a prefix of one. Below it sits
    /// `alias.contains(term)`, which fires mid-word.
    ///
    /// That distinction is not theoretical. Adding "fold together" as a merge alias made the
    /// three letters in "to-get-her" a mid-word match for "get", which promoted `get` to a
    /// capability word and silently vetoed proofread for "get rid of the typos" — a query
    /// about something else entirely. Any alias can collide with any short word this way, so
    /// the rule is that only a word-boundary match may speak for the catalogue.
    public static let minimumDiscriminatingTermScore = 800

    /// Share of the score a partial match keeps as coverage approaches zero. Full coverage
    /// keeps 100%, so a command matching every term always outranks one matching some.
    public static let partialCoverageFloor = 0.55

    /// Query words that carry no command meaning. Excluded from the coverage denominator so
    /// "make this sound polite" is judged on `make/sound/polite` rather than being punished
    /// for a `this` that no command will ever list as an alias.
    ///
    /// Direction words like `to` stay in: `conversationalBoost` reads the raw phrase for
    /// "to english" / "to telugu", but the tokens still have to reach a translate command.
    public static let queryStopwords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "it", "its",
        "my", "me", "i", "you", "your", "is", "are", "was", "be", "am",
        "do", "does", "did", "please", "can", "could", "would", "should",
        "and", "or", "as", "so", "just", "very", "really", "bit", "some",
        "up", "out", "here", "there", "thing", "stuff", "kinda", "pls"
    ]

    /// Terms that should drive scoring: content words, or every word when the query is
    /// nothing but stopwords (`"do it"`), so such a query still searches rather than
    /// silently matching nothing.
    public static func contentTerms(_ terms: [String]) -> [String] {
        let content = terms.filter { !queryStopwords.contains($0) }
        return Array((content.isEmpty ? terms : content).prefix(maximumQueryTerms))
    }

    /// Per-term match scores for one command; `nil` where the term did not match at all.
    static func termScores(entry: CommandIndexEntry, terms: [String]) -> [Int?] {
        terms.map { term in
            bestTermScore(
                term: term,
                trigger: entry.foldedTrigger,
                title: entry.foldedTitle,
                subtitle: entry.foldedSubtitle,
                aliases: entry.foldedAliases,
                aliasBlob: entry.foldedAliasBlob,
                searchBlob: entry.searchBlob
            )
        }
    }

    /// Term-coverage scoring.
    ///
    /// The previous rule was conjunctive — one unmatched term vetoed the command outright — so
    /// every conversational query ("make this sound polite", "tidy up my writing") returned an
    /// empty palette. That also made `conversationalBoost` and the semantic index unreachable
    /// for exactly those queries, because both are applied only to commands that already
    /// scored.
    ///
    /// An unmatched term now costs coverage instead of vetoing — but only when it is a word no
    /// command in the catalogue understands. `discriminating` carries the terms that *some*
    /// command matches strongly, and missing one of those is still fatal. That distinction is
    /// what keeps "fix telugu" away from proofread: `telugu` names a capability proofread does
    /// not have, whereas `polite` is a word nothing claims and so is safely ignored.
    ///
    /// A fully covered query scores exactly what it scored before — the coverage factor is 1.0
    /// at full coverage — so existing rankings are untouched and only new, strictly
    /// lower-scored partial hits appear.
    public static func combinedScore(
        termScores scores: [Int?],
        discriminating: [Bool]
    ) -> Int? {
        guard !scores.isEmpty else { return nil }
        var total = 0
        var matched = 0
        var strongest = 0
        for (index, value) in scores.enumerated() {
            guard let value else {
                if discriminating[index] { return nil }
                continue
            }
            total += value
            matched += 1
            strongest = Swift.max(strongest, value)
        }
        guard matched > 0 else { return nil }
        let base = total / matched
        guard matched < scores.count else { return base }
        guard strongest >= minimumPartialTermScore else { return nil }
        let coverage = Double(matched) / Double(scores.count)
        return Int(Double(base) * (partialCoverageFloor + (1 - partialCoverageFloor) * coverage))
    }

    /// Offline NLEmbedding semantic boost IDs (Stage 1). Returns empty on OOV / failure.
    public static func semanticBoostIDs(
        for query: String,
        loc: LocalizationManager = .shared,
        limit: Int = 8
    ) -> [String] {
        PaletteSemanticIndex.boostIDs(for: query, commands: commands, loc: loc, limit: limit)
    }

    private static func bestTermScore(
        term: String,
        trigger: String,
        title: String,
        subtitle: String,
        aliases: [String],
        aliasBlob: String,
        searchBlob: String
    ) -> Int? {
        if trigger == term { return 1000 }
        if trigger.hasPrefix(term) { return 920 }
        if trigger.contains(term) { return 720 }

        for alias in aliases {
            if alias == term { return 980 }
            if alias.hasPrefix(term) { return 900 }
            if alias.split(separator: " ").contains(where: { $0 == term || $0.hasPrefix(term) }) {
                return 860
            }
            if alias.contains(term) { return 750 }
        }

        if title == term { return 880 }
        if title.hasPrefix(term) { return 820 }
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: {
            String($0).hasPrefix(term)
        }) {
            return 700
        }
        if title.contains(term) { return 560 }

        if subtitle.contains(term) { return 420 }
        if aliasBlob.contains(term) || searchBlob.contains(term) { return 400 }

        if let fuzzy = subsequenceBonus(term: term, in: trigger) {
            return 300 + fuzzy
        }
        if let first = aliases.first, let fuzzy = subsequenceBonus(term: term, in: first) {
            return 280 + fuzzy
        }
        return nil
    }

    static func conversationalBoost(query: String, command: PaletteCommand) -> Int {
        let q = query.lowercased()
        guard case .ai(let kind) = command.action else {
            if case .date = command.action, q.contains("date") || q.contains("time") {
                return 15
            }
            if case .textOp(let op) = command.action {
                if op == .upper, q.contains("upper") || q.contains("caps") { return 40 }
                if op == .lower, q.contains("lower") { return 40 }
                if op == .sortLines, q.contains("sort") { return 40 }
            }
            return 0
        }
        var boost = 0
        if q.contains("make this") || q.contains("make it") || q.contains("make the") {
            boost += 40
        }
        switch kind {
        case .formal where q.contains("formal") || q.contains("professional"):
            boost += 60
        case .friendly where q.contains("friendly") || q.contains("casual") || q.contains("warm"):
            boost += 60
        case .proofread where q.contains("proof") || q.contains("grammar")
            || q.contains("spelling") || q.contains("correct") || q.contains("fix"):
            boost += 60
        case .promptEnhance where q.contains("prompt") || q.contains("enhance"):
            boost += 60
        case .bulletize where q.contains("bullet") || q.contains("list"):
            boost += 50
        case .condense where q.contains("short") || q.contains("summar") || q.contains("conden"):
            boost += 50
        case .expand where q.contains("expand") || q.contains("longer") || q.contains("elaborate"):
            boost += 50
        case .rewrite where q.contains("rewrite") || q.contains("rephrase") || q.contains("clear"):
            boost += 40
        case .paraphrase where q.contains("paraphrase") || q.contains("reword"):
            boost += 50
        // Direction is carried by word order alone — "telugu to english" and
        // "english to telugu" share every token — so these read the raw phrase
        // rather than the tokens the scorer sees.
        case .translate where q.contains("to english") || q.contains("in english"):
            boost += 120
        case .translateTelugu where q.contains("to telugu") || q.contains("in telugu"):
            boost += 120
        case .translateHindi where q.contains("to hindi") || q.contains("in hindi"):
            boost += 120
        case .translate where q.contains("translat") || q.contains("meaning"):
            boost += 40
        default:
            break
        }
        return boost
    }

    static func tokenize(_ query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .prefix(maximumQueryTerms)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func subsequenceBonus(term: String, in haystack: String) -> Int? {
        let needle = Array(term)
        let hay = Array(haystack)
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        var hi = 0
        var gaps = 0
        var last = -1
        for ch in needle {
            var found = false
            while hi < hay.count {
                if hay[hi] == ch {
                    if last >= 0 { gaps += hi - last - 1 }
                    last = hi
                    hi += 1
                    found = true
                    break
                }
                hi += 1
            }
            if !found { return nil }
        }
        return max(0, 40 - gaps)
    }
}
