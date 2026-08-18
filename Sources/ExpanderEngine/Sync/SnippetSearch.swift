// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// Field a search term matched in. §4.7: `group` used to be display-only.
public enum SearchField: String, Equatable, Hashable, CaseIterable {
    case trigger
    case title
    case group
    case content
}

/// §4.7: where a query matched, so the UI can highlight instead of showing a flat string.
///
/// `ranges` are **Character (grapheme) offsets into the original, unfolded field text**, not
/// UTF-16 offsets — the index folds diacritics and width, which can change length, so offsets are
/// mapped back through a per-character origin table. Use `SnippetSearch.utf16Ranges(_:in:)` to
/// convert for `NSAttributedString`.
public struct SearchHighlight: Equatable {
    public let field: SearchField
    public let ranges: [Range<Int>]

    public init(field: SearchField, ranges: [Range<Int>]) {
        self.field = field
        self.ranges = ranges
    }
}

public struct SearchHit: Identifiable, Equatable {
    public let snippet: SnippetModel
    public let groupID: UUID
    public let groupName: String
    public let score: Int
    /// §4.7: match ranges for highlighting. Empty when built through the legacy initializer.
    public let highlights: [SearchHighlight]

    public var id: UUID { snippet.id }

    public init(snippet: SnippetModel, groupID: UUID, groupName: String, score: Int) {
        self.init(snippet: snippet, groupID: groupID, groupName: groupName, score: score, highlights: [])
    }

    public init(
        snippet: SnippetModel,
        groupID: UUID,
        groupName: String,
        score: Int,
        highlights: [SearchHighlight]
    ) {
        self.snippet = snippet
        self.groupID = groupID
        self.groupName = groupName
        self.score = score
        self.highlights = highlights
    }
}

// MARK: - Folded text

/// §4.7: A string folded for matching, plus the map back to original character offsets.
///
/// Folding uses `[.diacriticInsensitive, .caseInsensitive, .widthInsensitive]` so `résumé`
/// matches `resume` and full-width `ｓｉｇ` matches `sig`. Folding can change length (ligatures),
/// so the origin table exists to keep highlight ranges pointing at real characters.
struct FoldedText {
    /// Folded characters used for matching.
    let characters: [Character]
    /// `characters[i]` came from original character index `origin[i]`.
    let origin: [Int]
    let originalCount: Int

    static let foldingOptions: String.CompareOptions = [
        .diacriticInsensitive, .caseInsensitive, .widthInsensitive,
    ]

    static let empty = FoldedText(characters: [], origin: [], originalCount: 0)

    var isEmpty: Bool { characters.isEmpty }

    static func fold(_ text: String, locale: Locale?) -> FoldedText {
        guard !text.isEmpty else { return .empty }
        let folded = text.folding(options: foldingOptions, locale: locale)
        let foldedCharacters = Array(folded)
        let originalCharacters = Array(text)

        // Fast path: folding was 1:1 (true for ASCII and for every common accented Latin letter).
        if foldedCharacters.count == originalCharacters.count {
            return FoldedText(
                characters: foldedCharacters,
                origin: Array(0..<foldedCharacters.count),
                originalCount: originalCharacters.count
            )
        }

        // Slow path: rebuild character-by-character so offsets stay mappable.
        var characters: [Character] = []
        var origin: [Int] = []
        characters.reserveCapacity(foldedCharacters.count)
        origin.reserveCapacity(foldedCharacters.count)
        for (index, character) in originalCharacters.enumerated() {
            for piece in String(character).folding(options: foldingOptions, locale: locale) {
                characters.append(piece)
                origin.append(index)
            }
        }
        return FoldedText(characters: characters, origin: origin, originalCount: originalCharacters.count)
    }

    /// Maps folded ranges back to original character ranges, merging anything that becomes
    /// adjacent after mapping.
    func originalRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var mapped: [Range<Int>] = []
        for range in ranges {
            guard range.lowerBound >= 0, range.upperBound <= origin.count, !range.isEmpty else { continue }
            let lower = origin[range.lowerBound]
            let upper = origin[range.upperBound - 1] + 1
            guard lower < upper else { continue }
            if let last = mapped.last, last.upperBound >= lower {
                mapped[mapped.count - 1] = last.lowerBound..<Swift.max(last.upperBound, upper)
            } else {
                mapped.append(lower..<upper)
            }
        }
        return mapped
    }
}

// MARK: - Index

/// §2.8: Precomputed, normalized search fields.
///
/// The old scorer called `lowercased()` on the trigger, the title **and the full
/// `replacementText`** for every snippet on every keystroke — roughly 500 KB of allocation per
/// typed character at 1000 snippets. The index is built once per library revision and reused.
public struct SnippetSearchIndex {

    /// Cap on how much snippet body is indexed. Body matches are the weakest signal and a
    /// 100 KB snippet should not cost 100 KB of folding on every library change.
    public static let maxIndexedBodyCharacters = 2_000

    struct Entry {
        let snippet: SnippetModel
        let groupID: UUID
        let groupName: String

        let trigger: FoldedText
        /// Trigger with leading sigils (`:`, `~`, `;`) removed, so `sig` finds `:sig`.
        let bareTrigger: FoldedText
        /// Offset of `bareTrigger` inside the original trigger, for highlight mapping.
        let bareTriggerOffset: Int
        let title: FoldedText
        let group: FoldedText
        let body: FoldedText

        /// Folded indices where a word starts in `title`, and the initials at those positions.
        let titleWordStarts: [Int]
        let titleInitials: [Character]
    }

    let entries: [Entry]
    /// Cheap content fingerprint; the cached index is rebuilt when this changes.
    public let fingerprint: UInt64
    public let includesDisabled: Bool

    public var count: Int { entries.count }
}

// MARK: - Search

public enum SnippetSearch {

    // MARK: Cached index (§2.8)

    private static let cacheLock = UnfairLock()
    private static var cachedIndex: SnippetSearchIndex?

    private struct QueryCacheKey: Hashable {
        let query: String
        let fingerprint: UInt64
        let limit: Int?
        let statsRevision: UInt64
    }

    private static var queryCache: [QueryCacheKey: [SearchHit]] = [:]
    private static var queryCacheKeys: [QueryCacheKey] = []
    private static let maxQueryCacheEntries = 128

    /// Fingerprint over the fields the index derives from. Deliberately hashes only short
    /// strings plus the body *length* — hashing every body byte would reintroduce the very cost
    /// the index exists to remove, while still catching every realistic edit (`updatedAt` moves
    /// on save, and a body edit changes its length in all but pathological cases).
    public static func fingerprint(of groups: [SnippetGroup], includeDisabled: Bool) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(includeDisabled)
        hasher.combine(groups.count)
        for group in groups {
            hasher.combine(group.id)
            hasher.combine(group.name)
            hasher.combine(group.enabled)
            hasher.combine(group.snippets.count)
            for snippet in group.snippets {
                hasher.combine(snippet.id)
                hasher.combine(snippet.enabled)
                hasher.combine(snippet.triggerKeyword)
                hasher.combine(snippet.displayTitle)
                hasher.combine(snippet.replacementText.count)
                hasher.combine(snippet.updatedAt)
            }
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Builds a normalized index. Callers that hold a library for a while can keep this and pass
    /// it to `run(query:index:limit:boost:)`; `run(query:in:…)` caches one internally.
    public static func makeIndex(
        for groups: [SnippetGroup],
        includeDisabled: Bool = true,
        locale: Locale? = Locale.current
    ) -> SnippetSearchIndex {
        var entries: [SnippetSearchIndex.Entry] = []
        for group in groups {
            let groupFolded = FoldedText.fold(group.name, locale: locale)
            for snippet in group.snippets {
                if !includeDisabled && !(snippet.enabled && group.enabled) { continue }

                let trigger = snippet.triggerKeyword
                let sigilCount = leadingSigilCount(of: trigger)
                let bare = String(trigger.dropFirst(sigilCount))
                let title = snippet.displayTitle
                let titleFolded = FoldedText.fold(title, locale: locale)
                let wordStarts = wordStartIndices(in: titleFolded.characters)
                let body = snippet.replacementText.count > SnippetSearchIndex.maxIndexedBodyCharacters
                    ? String(snippet.replacementText.prefix(SnippetSearchIndex.maxIndexedBodyCharacters))
                    : snippet.replacementText

                entries.append(SnippetSearchIndex.Entry(
                    snippet: snippet,
                    groupID: group.id,
                    groupName: group.name,
                    trigger: FoldedText.fold(trigger, locale: locale),
                    bareTrigger: FoldedText.fold(bare, locale: locale),
                    bareTriggerOffset: sigilCount,
                    title: titleFolded,
                    group: groupFolded,
                    body: FoldedText.fold(body, locale: locale),
                    titleWordStarts: wordStarts,
                    titleInitials: wordStarts.map { titleFolded.characters[$0] }
                ))
            }
        }
        return SnippetSearchIndex(
            entries: entries,
            fingerprint: fingerprint(of: groups, includeDisabled: includeDisabled),
            includesDisabled: includeDisabled
        )
    }

    private static func index(for groups: [SnippetGroup], includeDisabled: Bool) -> SnippetSearchIndex {
        let stamp = fingerprint(of: groups, includeDisabled: includeDisabled)
        cacheLock.lock()
        if let cached = cachedIndex, cached.fingerprint == stamp, cached.includesDisabled == includeDisabled {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let fresh = makeIndex(for: groups, includeDisabled: includeDisabled)
        cacheLock.lock()
        cachedIndex = fresh
        cacheLock.unlock()
        return fresh
    }

    /// Drops the cached index. Only needed by tests and by "the library moved" handling.
    public static func invalidateIndexCache() {
        cacheLock.lock()
        cachedIndex = nil
        queryCache.removeAll(keepingCapacity: false)
        queryCacheKeys.removeAll(keepingCapacity: false)
        cacheLock.unlock()
    }

    // MARK: Entry points

    /// Existing entry point, unchanged signature.
    public static func run(
        query: String,
        in groups: [SnippetGroup],
        includeDisabled: Bool = true,
        limit: Int? = nil
    ) -> [SearchHit] {
        run(query: query, in: groups, includeDisabled: includeDisabled, limit: limit, boost: nil)
    }

    /// §4.5/§4.7: ranked search with an optional usage boost.
    ///
    /// `boost` keeps `SnippetSearch` independent of `SnippetStore` / `UsageStatsStore` — pass
    /// `UsageStatsStore.shared.rankBoost(for:)` (or `SnippetStore.usageCount(forSnippetID:)`
    /// scaled) from the call site. The boost is additive and small by design, so a frequently
    /// used snippet re-orders ties without ever outranking an exact trigger match.
    public static func run(
        query: String,
        in groups: [SnippetGroup],
        includeDisabled: Bool = true,
        limit: Int? = nil,
        boost: ((UUID) -> Int)?
    ) -> [SearchHit] {
        run(query: query, index: index(for: groups, includeDisabled: includeDisabled), limit: limit, boost: boost)
    }

    /// Searches a caller-owned index.
    public static func run(
        query: String,
        index: SnippetSearchIndex,
        limit: Int? = nil,
        boost: ((UUID) -> Int)? = nil
    ) -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let statsRev = UsageStatsStore.shared.revision
        let cacheKey = QueryCacheKey(
            query: trimmed,
            fingerprint: index.fingerprint,
            limit: limit,
            statsRevision: boost != nil ? statsRev : 0
        )

        cacheLock.lock()
        if let cached = queryCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let terms = tokenize(trimmed)
        guard !terms.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for entry in index.entries {
            guard var evaluation = evaluate(entry: entry, terms: terms) else { continue }
            if let boost {
                evaluation.score += Swift.max(0, boost(entry.snippet.id))
            }
            hits.append(SearchHit(
                snippet: entry.snippet,
                groupID: entry.groupID,
                groupName: entry.groupName,
                score: evaluation.score,
                highlights: evaluation.highlights
            ))
        }

        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.snippet.triggerKeyword.count != b.snippet.triggerKeyword.count {
                return a.snippet.triggerKeyword.count < b.snippet.triggerKeyword.count
            }
            return a.snippet.triggerKeyword.localizedCaseInsensitiveCompare(b.snippet.triggerKeyword) == .orderedAscending
        }

        let result: [SearchHit]
        if let limit, hits.count > limit {
            result = Array(hits.prefix(limit))
        } else {
            result = hits
        }

        cacheLock.lock()
        if queryCache.count >= maxQueryCacheEntries, !queryCacheKeys.isEmpty {
            let oldest = queryCacheKeys.removeFirst()
            queryCache.removeValue(forKey: oldest)
        }
        queryCache[cacheKey] = result
        queryCacheKeys.append(cacheKey)
        cacheLock.unlock()

        return result
    }

    /// Legacy single-snippet scorer, kept as a shim. Returns `nil` when the snippet does not
    /// match at all.
    public static func score(snippet: SnippetModel, needle: String) -> Int? {
        let terms = tokenize(needle)
        guard !terms.isEmpty else { return nil }
        let entry = SnippetSearchIndex.Entry(
            snippet: snippet,
            groupID: UUID(),
            groupName: "",
            trigger: FoldedText.fold(snippet.triggerKeyword, locale: Locale.current),
            bareTrigger: FoldedText.fold(
                String(snippet.triggerKeyword.dropFirst(leadingSigilCount(of: snippet.triggerKeyword))),
                locale: Locale.current
            ),
            bareTriggerOffset: leadingSigilCount(of: snippet.triggerKeyword),
            title: FoldedText.fold(snippet.displayTitle, locale: Locale.current),
            group: .empty,
            body: FoldedText.fold(snippet.replacementText, locale: Locale.current),
            titleWordStarts: [],
            titleInitials: []
        )
        return evaluate(entry: entry, terms: terms)?.score
    }

    /// Converts highlight ranges (character offsets) to `NSRange`s for `NSAttributedString`.
    public static func utf16Ranges(_ ranges: [Range<Int>], in text: String) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let characters = Array(text)
        var result: [NSRange] = []
        for range in ranges {
            guard range.lowerBound >= 0, range.upperBound <= characters.count, !range.isEmpty else { continue }
            let prefix = String(characters[0..<range.lowerBound])
            let slice = String(characters[range.lowerBound..<range.upperBound])
            result.append(NSRange(location: prefix.utf16.count, length: slice.utf16.count))
        }
        return result
    }

    // MARK: Scoring

    private struct Evaluation {
        var score: Int
        var highlights: [SearchHighlight]
    }

    /// Multi-term queries are AND: every term must match somewhere. The reported score is the
    /// average per-term score, so "email work" stays comparable to "email".
    private static func evaluate(entry: SnippetSearchIndex.Entry, terms: [[Character]]) -> Evaluation? {
        var total = 0
        var highlightsByField: [SearchField: [Range<Int>]] = [:]

        for term in terms {
            guard let best = bestMatch(entry: entry, term: term) else { return nil }
            total += best.score
            highlightsByField[best.field, default: []].append(contentsOf: best.ranges)
        }

        let highlights = SearchField.allCases.compactMap { field -> SearchHighlight? in
            guard let ranges = highlightsByField[field], !ranges.isEmpty else { return nil }
            return SearchHighlight(field: field, ranges: mergeRanges(ranges))
        }
        return Evaluation(score: total / terms.count, highlights: highlights)
    }

    private struct FieldMatch {
        let score: Int
        let field: SearchField
        let ranges: [Range<Int>]
    }

    private static func bestMatch(entry: SnippetSearchIndex.Entry, term: [Character]) -> FieldMatch? {
        // 1. Trigger — the strongest signal, exact-first.
        if !entry.trigger.isEmpty {
            let haystack = entry.trigger.characters
            if haystack == term {
                return FieldMatch(score: 1000, field: .trigger, ranges: [0..<entry.trigger.originalCount])
            }
            if haystack.starts(with: term) {
                return FieldMatch(
                    score: 900,
                    field: .trigger,
                    ranges: entry.trigger.originalRanges([0..<term.count])
                )
            }
        }
        if !entry.bareTrigger.isEmpty {
            let bare = entry.bareTrigger.characters
            let offset = entry.bareTriggerOffset
            if bare == term {
                return FieldMatch(
                    score: 980,
                    field: .trigger,
                    ranges: [offset..<(offset + entry.bareTrigger.originalCount)]
                )
            }
            if bare.starts(with: term) {
                let mapped = entry.bareTrigger.originalRanges([0..<term.count])
                return FieldMatch(score: 880, field: .trigger, ranges: shift(mapped, by: offset))
            }
        }
        if let range = firstOccurrence(of: term, in: entry.trigger.characters) {
            return FieldMatch(score: 700, field: .trigger, ranges: entry.trigger.originalRanges([range]))
        }

        // 2. Title (label / name).
        if !entry.title.isEmpty {
            if entry.title.characters.starts(with: term) {
                return FieldMatch(score: 620, field: .title, ranges: entry.title.originalRanges([0..<term.count]))
            }
            if let range = firstOccurrence(of: term, in: entry.title.characters) {
                return FieldMatch(score: 500, field: .title, ranges: entry.title.originalRanges([range]))
            }
            // Acronym: "cw" finds "Clear Warnings" (Alfred / Raycast style).
            if term.count >= 2, entry.titleInitials.starts(with: term) {
                let ranges = entry.titleWordStarts.prefix(term.count).map { $0..<($0 + 1) }
                return FieldMatch(score: 470, field: .title, ranges: entry.title.originalRanges(Array(ranges)))
            }
        }

        // 3. Group name — §4.7: previously display-only.
        if !entry.group.isEmpty {
            if entry.group.characters.starts(with: term) {
                return FieldMatch(score: 420, field: .group, ranges: entry.group.originalRanges([0..<term.count]))
            }
            if let range = firstOccurrence(of: term, in: entry.group.characters) {
                return FieldMatch(score: 380, field: .group, ranges: entry.group.originalRanges([range]))
            }
        }

        // 4. Fuzzy subsequence on the trigger — `sgn` finds `:signature`.
        if let fuzzy = subsequenceMatch(term: term, in: entry.trigger.characters) {
            return FieldMatch(
                score: 300 + fuzzy.bonus,
                field: .trigger,
                ranges: entry.trigger.originalRanges(fuzzy.ranges)
            )
        }
        if let fuzzy = subsequenceMatch(term: term, in: entry.title.characters) {
            return FieldMatch(
                score: 240 + fuzzy.bonus,
                field: .title,
                ranges: entry.title.originalRanges(fuzzy.ranges)
            )
        }

        // 5. Body, last and weakest.
        if let range = firstOccurrence(of: term, in: entry.body.characters) {
            return FieldMatch(score: 200, field: .content, ranges: entry.body.originalRanges([range]))
        }
        return nil
    }

    // MARK: Matching primitives

    /// Splits a query into folded terms. Whitespace separates AND-ed terms (§4.7).
    private static func tokenize(_ query: String) -> [[Character]] {
        query.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { Array(FoldedText.fold($0, locale: Locale.current).characters) }
            .filter { !$0.isEmpty }
    }

    private static func firstOccurrence(of needle: [Character], in haystack: [Character]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let last = haystack.count - needle.count
        var start = 0
        while start <= last {
            var offset = 0
            while offset < needle.count, haystack[start + offset] == needle[offset] {
                offset += 1
            }
            if offset == needle.count { return start..<(start + needle.count) }
            start += 1
        }
        return nil
    }

    /// Greedy left-to-right subsequence match with adjacency / word-start bonuses.
    private static func subsequenceMatch(
        term: [Character],
        in haystack: [Character]
    ) -> (ranges: [Range<Int>], bonus: Int)? {
        guard term.count >= 2, !haystack.isEmpty, term.count <= haystack.count else { return nil }
        var ranges: [Range<Int>] = []
        var cursor = 0
        var bonus = 0
        var previous = -2

        for character in term {
            var found = -1
            var probe = cursor
            while probe < haystack.count {
                if haystack[probe] == character {
                    found = probe
                    break
                }
                probe += 1
            }
            guard found >= 0 else { return nil }

            if found == previous + 1 { bonus += 8 }
            if found == 0 {
                bonus += 12
            } else if !haystack[found - 1].isLetter && !haystack[found - 1].isNumber {
                bonus += 10
            }

            if let last = ranges.last, last.upperBound == found {
                ranges[ranges.count - 1] = last.lowerBound..<(found + 1)
            } else {
                ranges.append(found..<(found + 1))
            }
            previous = found
            cursor = found + 1
        }

        guard let first = ranges.first, let last = ranges.last else { return nil }
        let span = last.upperBound - first.lowerBound
        let tightness = Swift.max(0, 30 - (span - term.count))
        return (ranges, Swift.min(bonus + tightness, 60))
    }

    private static func wordStartIndices(in characters: [Character]) -> [Int] {
        var starts: [Int] = []
        var previousWasSeparator = true
        for (index, character) in characters.enumerated() {
            let isWord = character.isLetter || character.isNumber
            if isWord && previousWasSeparator { starts.append(index) }
            previousWasSeparator = !isWord
        }
        return starts
    }

    private static func leadingSigilCount(of trigger: String) -> Int {
        var count = 0
        for character in trigger {
            if character.isLetter || character.isNumber { break }
            count += 1
        }
        return count
    }

    private static func shift(_ ranges: [Range<Int>], by offset: Int) -> [Range<Int>] {
        ranges.map { ($0.lowerBound + offset)..<($0.upperBound + offset) }
    }

    private static func mergeRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
