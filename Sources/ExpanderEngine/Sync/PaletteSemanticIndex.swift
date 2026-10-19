import Foundation
import NaturalLanguage

// MARK: - Semantic index (C4 Stage 1)

enum PaletteSemanticIndex {
    private static let lock = NSLock()
    /// Vectors are only comparable inside the embedding space that produced them, so the
    /// cache is keyed by language. Comparing a Japanese query vector against English command
    /// vectors is not a weak signal — it is a meaningless number.
    private static var cachedVectors: [String: [String: [Double]]] = [:]
    private static var cachedLanguage: AppLanguage?

    /// Cosine floor for a neighbour to count. Raised from 0.35: at that threshold an averaged
    /// word embedding returned `ai.explainregex` as the nearest command for "tidy up my
    /// writing", "shorten this a bit" and "make this sound polite" alike.
    static let minimumSimilarity = 0.45

    static func invalidateCache() {
        lock.lock()
        cachedVectors.removeAll(keepingCapacity: false)
        cachedLanguage = nil
        lock.unlock()
    }

    /// The embedding space to use for this query, or `nil` when there is none.
    ///
    /// Apple ships word embeddings for a fixed set of languages. Asking for one that does not
    /// exist returns `nil`, which is the honest answer — the caller then falls back to lexical
    /// matching rather than scoring against a space the query does not live in.
    static func embedding(for query: String) -> (NLEmbedding, String)? {
        let detected = NLLanguageRecognizer.dominantLanguage(for: query)
        // Short queries give the recognizer too little to go on and it guesses wildly, so a
        // pure-ASCII query is treated as English rather than whatever it reported.
        let isASCII = query.allSatisfy { $0.isASCII }
        let language: NLLanguage = isASCII ? .english : (detected ?? .english)
        guard let embedding = NLEmbedding.wordEmbedding(for: language) else { return nil }
        return (embedding, language.rawValue)
    }

    static func boostIDs(
        for query: String,
        commands: [PaletteCommand],
        loc: LocalizationManager,
        limit: Int
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        guard let (embedding, languageKey) = embedding(for: trimmed) else { return [] }
        guard let queryVector = averageEmbedding(for: trimmed, embedding: embedding) else { return [] }

        let vectors = commandVectors(
            commands, loc: loc, embedding: embedding, languageKey: languageKey
        )

        var scored: [(String, Double)] = []
        for command in commands {
            guard let vector = vectors[command.id] else { continue }
            let sim = cosineSimilarity(queryVector, vector)
            if sim > minimumSimilarity {
                scored.append((command.id, sim))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map(\.0)
    }

    /// Command vectors for one embedding space. Built from the *localized* title and subtitle
    /// as well as the English trigger and aliases: in a non-English space the English tokens
    /// are simply out of vocabulary and drop out, leaving the localized text to carry the
    /// meaning. That is what makes a Japanese or Korean query able to match at all.
    private static func commandVectors(
        _ commands: [PaletteCommand],
        loc: LocalizationManager,
        embedding: NLEmbedding,
        languageKey: String
    ) -> [String: [Double]] {
        lock.lock()
        if cachedLanguage != loc.language {
            cachedVectors.removeAll(keepingCapacity: false)
            cachedLanguage = loc.language
        }
        if let cached = cachedVectors[languageKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var map: [String: [Double]] = [:]
        for command in commands {
            let blob = ([command.trigger]
                + command.aliases
                + [loc.s(command.titleKey), loc.s(command.subtitleKey)]
            ).joined(separator: " ")
            if let vector = averageEmbedding(for: blob, embedding: embedding) {
                map[command.id] = vector
            }
        }
        lock.lock()
        cachedVectors[languageKey] = map
        cachedLanguage = loc.language
        lock.unlock()
        return map
    }

    /// Mean of the in-vocabulary word vectors, with stopwords removed first.
    ///
    /// Averaging over `this`, `it`, `up` and `a` pulls every query toward the centroid of the
    /// language and flattens the differences the cosine is supposed to measure — which is how
    /// unrelated queries all came back with the same nearest neighbour.
    private static func averageEmbedding(for text: String, embedding: NLEmbedding) -> [Double]? {
        let tokens = text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
        let content = tokens.filter { !CommandPaletteCatalog.queryStopwords.contains($0) }
        // Same ceiling the lexical path uses. This runs on every keystroke over the whole
        // catalogue, and averaging a thousand pasted words says nothing a dozen would not.
        let effective = Array((content.isEmpty ? tokens : content)
            .prefix(CommandPaletteCatalog.maximumQueryTerms))
        guard !effective.isEmpty else { return nil }

        var sum: [Double] = []
        var count = 0
        for token in effective {
            guard let vector = embedding.vector(for: token) else { continue }
            if sum.isEmpty {
                sum = vector
            } else if sum.count == vector.count {
                for i in sum.indices {
                    sum[i] += vector[i]
                }
            }
            count += 1
        }
        guard count > 0, !sum.isEmpty else { return nil }
        return sum.map { $0 / Double(count) }
    }

    private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
