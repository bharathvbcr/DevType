// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// A revision is meaningful only inside the library that owns it. Callers without that
/// identity use a complete content fingerprint, including the metadata returned in each hit.
struct SearchLibraryStamp: Hashable {
    let value: UInt64
    let libraryID: UUID?
    let localeID: String?

    static func resolve(groups: [SnippetGroup], includeDisabled: Bool,
                        revision: UInt64?, libraryID: UUID?, locale: Locale?) -> Self {
        if let revision, let libraryID {
            return Self(value: revision, libraryID: libraryID, localeID: locale?.identifier)
        }
        return Self(value: SnippetSearch.fingerprint(of: groups, includeDisabled: includeDisabled),
                    libraryID: nil, localeID: locale?.identifier)
    }
}

/// Field a search term matched in. §4.7: `group` used to be display-only.
public enum SearchField: String, Equatable, Hashable, CaseIterable {
    case trigger
    case title
    case group
    /// A curated search term from `SnippetModel.tags`. Carries no highlight ranges: a hit
    /// belongs to one of several tags, and the highlight table is keyed by field, not by which
    /// tag matched. `evaluate` drops range-less fields, so nothing renders.
    case tag
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
        let groupEnabled: Bool

        let trigger: FoldedText
        /// Trigger with leading sigils (`:`, `~`, `;`) removed, so `sig` finds `:sig`.
        let bareTrigger: FoldedText
        /// Offset of `bareTrigger` inside the original trigger, for highlight mapping.
        let bareTriggerOffset: Int
        let title: FoldedText
        let group: FoldedText
        /// Folded `SnippetModel.tags`. Both interchange formats DevType speaks call these
        /// search terms — Espanso imports `search_terms:` into them and `SnippetExporter`
        /// writes them back out under that name — so searching them is what the field is for.
        let tags: [FoldedText]
        let body: FoldedText

        /// Folded indices where a word starts in `title`, and the initials at those positions.
        let titleWordStarts: [Int]
        let titleInitials: [Character]
    }

    let entries: [Entry]
    let stamp: SearchLibraryStamp
    /// Separates caller-owned indices too, including differently folded locales.
    let cacheID: UUID
    /// Cheap content fingerprint; the cached index is rebuilt when this changes.
    /// Identifies the library this index was built from. Either a `SnippetStore` revision
    /// (cheap, exact) or a content fingerprint (for callers holding groups from nowhere in
    /// particular) — `stampIsRevision` says which, so the two numbering schemes can never be
    /// mistaken for each other in a cache key.
    public let fingerprint: UInt64
    public let stampIsRevision: Bool
    public let includesDisabled: Bool

    public var count: Int { entries.count }
}

// MARK: - Search

public enum SnippetSearch {

    public enum QueryIssue: Error, Equatable {
        case tooLong
        case tooManyTerms
        case incompleteFilter

        public func message(loc: LocalizationManager = .shared) -> String {
            switch self {
            case .tooLong: return loc.s("search.issue.tooLong")
            case .tooManyTerms: return loc.s("search.issue.tooManyTerms", SnippetSearch.maximumQueryTerms)
            case .incompleteFilter: return loc.s("search.issue.incompleteFilter")
            }
        }
    }

    /// Uses the same parser as matching so presentation cannot approve a partial query.
    public static func queryIssue(for query: String) -> QueryIssue? {
        if case .failure(let issue) = tokenize(query) { return issue }
        return nil
    }

    // MARK: Cached index (§2.8)

    private static let cacheLock = UnfairLock()
    /// One slot per `includeDisabled` value. A single slot meant two callers that disagreed
    /// about disabled snippets — the palette and the manager — evicted each other and paid a
    /// full rebuild on every alternation.
    private static var cachedIndices: [Bool: SnippetSearchIndex] = [:]

    private struct QueryCacheKey: Hashable {
        let query: String
        let indexID: UUID
        let limit: Int?
    }

    private static var queryCache: [QueryCacheKey: [SearchHit]] = [:]
    /// FIFO order as a ring: the previous `Array` was drained with `removeFirst()`, an O(n)
    /// memmove on every eviction.
    private static var queryCacheKeys: [QueryCacheKey?] = []
    private static var queryCacheHead = 0
    private static let maxQueryCacheEntries = 128

    /// Hash every returned field; equal-length edits and delivery-policy changes matter too.
    /// Store-backed callers avoid this work by supplying both identity and revision.
    public static func fingerprint(of groups: [SnippetGroup], includeDisabled: Bool) -> UInt64 {
        #if DEBUG
        fingerprintCallLock.lock()
        fingerprintCallCountForTesting += 1
        fingerprintCallLock.unlock()
        #endif
        var hasher = Hasher()
        hasher.combine(includeDisabled)
        hasher.combine(groups)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Builds a normalized index. Callers that hold a library for a while can keep this and pass
    /// it to `run(query:index:limit:boost:)`; `run(query:in:…)` caches one internally.
    /// - Parameter revision: a `SnippetStore.libraryRevision`, when the caller has one. Supplying
    ///   it replaces the content fingerprint — which hashes every group and snippet — with a
    ///   counter comparison.
    public static func makeIndex(
        for groups: [SnippetGroup],
        includeDisabled: Bool = true,
        locale: Locale? = Locale.current,
        revision: UInt64? = nil,
        libraryID: UUID? = nil
    ) -> SnippetSearchIndex {
        makeIndex(
            for: groups,
            includeDisabled: includeDisabled,
            locale: locale,
            stamp: SearchLibraryStamp.resolve(groups: groups, includeDisabled: includeDisabled,
                                             revision: revision, libraryID: libraryID, locale: locale)
        )
    }

    /// Builds with a stamp the caller has already resolved.
    ///
    /// `index(for:)` computes the stamp to check the cache and would otherwise pay for a second
    /// identical content hash whenever the cache missed — the exact cost this whole path exists
    /// to avoid, just moved one line down.
    private static func makeIndex(
        for groups: [SnippetGroup],
        includeDisabled: Bool,
        locale: Locale?,
        stamp: SearchLibraryStamp
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
                let body = indexedBodyText(snippet.replacementText)

                entries.append(SnippetSearchIndex.Entry(
                    snippet: snippet,
                    groupID: group.id,
                    groupName: group.name,
                    groupEnabled: group.enabled,
                    trigger: FoldedText.fold(trigger, locale: locale),
                    bareTrigger: FoldedText.fold(bare, locale: locale),
                    bareTriggerOffset: sigilCount,
                    title: titleFolded,
                    group: groupFolded,
                    tags: snippet.tags.map { FoldedText.fold($0, locale: locale) },
                    body: FoldedText.fold(body, locale: locale),
                    titleWordStarts: wordStarts,
                    titleInitials: wordStarts.map { titleFolded.characters[$0] }
                ))
            }
        }
        return SnippetSearchIndex(
            entries: entries,
            stamp: stamp,
            cacheID: UUID(),
            fingerprint: stamp.value,
            stampIsRevision: stamp.libraryID != nil,
            includesDisabled: includeDisabled
        )
    }

    private static func index(
        for groups: [SnippetGroup],
        includeDisabled: Bool,
        revision: UInt64?,
        libraryID: UUID?
    ) -> SnippetSearchIndex {
        // A revision comparison is O(1); the fingerprint hashes every snippet's id, trigger,
        // title, tags and timestamp — 627 µs at 2,000 snippets, paid on every keystroke to
        // discover the library had not changed.
        let stamp = SearchLibraryStamp.resolve(groups: groups, includeDisabled: includeDisabled,
                                              revision: revision, libraryID: libraryID, locale: .current)

        cacheLock.lock()
        if let cached = cachedIndices[includeDisabled],
           cached.stamp == stamp {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let fresh = makeIndex(
            for: groups,
            includeDisabled: includeDisabled,
            locale: Locale.current,
            stamp: stamp
        )
        cacheLock.lock()
        cachedIndices[includeDisabled] = fresh
        // Results computed against the library we just replaced can never be served again —
        // their key no longer matches any live index — but nothing used to remove them, so
        // they sat pinning `SnippetModel` copies (replacement text included) until FIFO
        // eviction pushed them out 128 queries later.
        pruneQueryCacheLocked()
        cacheLock.unlock()
        return fresh
    }

    /// Drops query results whose stamp belongs to no live index. Caller holds `cacheLock`.
    private static func pruneQueryCacheLocked() {
        let live = Set(cachedIndices.values.map(\.cacheID))
        guard !queryCache.isEmpty else { return }
        queryCache = queryCache.filter { key, _ in
            live.contains(key.indexID)
        }
        // Rebuild the eviction ring from the survivors, oldest first.
        var survivors: [QueryCacheKey?] = []
        survivors.reserveCapacity(queryCache.count)
        var seen: Set<QueryCacheKey> = []
        for slot in queryCacheHead..<queryCacheKeys.count {
            guard let key = queryCacheKeys[slot], queryCache[key] != nil else { continue }
            // A key re-inserted after an earlier eviction can appear twice; keep the newest.
            if seen.insert(key).inserted { survivors.append(key) }
        }
        queryCacheKeys = survivors
        queryCacheHead = 0
    }

    #if DEBUG
    private static let fingerprintCallLock = UnfairLock()
    /// How many times the whole-library content hash has been computed. Debug-only, so a caller
    /// that supplies a revision can be proven not to pay it.
    private static var fingerprintCallCountForTesting = 0

    static func resetFingerprintCountForTesting() {
        fingerprintCallLock.lock()
        fingerprintCallCountForTesting = 0
        fingerprintCallLock.unlock()
    }

    static var fingerprintCountForTesting: Int {
        fingerprintCallLock.lock()
        defer { fingerprintCallLock.unlock() }
        return fingerprintCallCountForTesting
    }
    #endif

    /// Live query-cache entry count. Test seam for the pruning and bounding rules.
    static var cachedQueryCountForTesting: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return queryCache.count
    }

    /// Backing size of the eviction ring, which must not grow without bound.
    static var queryCacheRingSizeForTesting: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return queryCacheKeys.count
    }

    /// Drops the cached index. Only needed by tests and by "the library moved" handling.
    public static func invalidateIndexCache() {
        cacheLock.lock()
        cachedIndices.removeAll(keepingCapacity: false)
        queryCache.removeAll(keepingCapacity: false)
        queryCacheKeys.removeAll(keepingCapacity: false)
        queryCacheHead = 0
        cacheLock.unlock()
    }

    // MARK: Entry points

    /// Existing entry point, unchanged signature.
    public static func run(
        query: String,
        in groups: [SnippetGroup],
        includeDisabled: Bool = true,
        limit: Int? = nil,
        revision: UInt64? = nil,
        libraryID: UUID? = nil
    ) -> [SearchHit] {
        run(
            query: query,
            in: groups,
            includeDisabled: includeDisabled,
            limit: limit,
            boost: nil,
            revision: revision,
            libraryID: libraryID
        )
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
        boost: ((UUID) -> Int)?,
        boostRevision: UInt64? = nil,
        revision: UInt64? = nil,
        libraryID: UUID? = nil
    ) -> [SearchHit] {
        run(
            query: query,
            index: index(for: groups, includeDisabled: includeDisabled, revision: revision, libraryID: libraryID),
            limit: limit,
            boost: boost,
            boostRevision: boostRevision
        )
    }

    /// Searches a caller-owned index.
    public static func run(
        query: String,
        index: SnippetSearchIndex,
        limit: Int? = nil,
        boost: ((UUID) -> Int)? = nil,
        boostRevision: UInt64? = nil
    ) -> [SearchHit] {
        if let limit, limit <= 0 { return [] }
        guard case .success(let terms) = tokenize(query, locale: index.stamp.localeID.map { Locale(identifier: $0) }) else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let boost {
            // Cache lexical work independently of personalization. A closure's identity and
            // state cannot be inferred from a revision supplied by an arbitrary caller.
            let base = run(query: trimmed, index: index, limit: nil)
            return ranked(base.map { hit in
                SearchHit(snippet: hit.snippet, groupID: hit.groupID, groupName: hit.groupName,
                          score: Saturating.adding(hit.score, max(0, boost(hit.id))), highlights: hit.highlights)
            }, limit: limit)
        }

        let cacheKey = QueryCacheKey(
            query: trimmed,
            indexID: index.cacheID,
            limit: limit
        )

        cacheLock.lock()
        if let cached = queryCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard !terms.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for entry in index.entries {
            guard let evaluation = evaluate(entry: entry, terms: terms) else { continue }
            hits.append(SearchHit(
                snippet: entry.snippet,
                groupID: entry.groupID,
                groupName: entry.groupName,
                score: evaluation.score,
                highlights: evaluation.highlights
            ))
        }

        let result = ranked(hits, limit: limit)
        cacheLock.lock()
        if queryCache[cacheKey] != nil {
            cacheLock.unlock()
            return result
        }
        if queryCache.count >= maxQueryCacheEntries {
            // Walk forward past keys a prune already dropped until one real eviction lands.
            while queryCacheHead < queryCacheKeys.count {
                let candidate = queryCacheKeys[queryCacheHead]
                queryCacheKeys[queryCacheHead] = nil
                queryCacheHead += 1
                if let candidate, queryCache.removeValue(forKey: candidate) != nil { break }
            }
            // Reclaim the consumed prefix once it dominates the buffer, so the ring cannot
            // grow without bound. Amortised to one compaction per `maxQueryCacheEntries`
            // insertions rather than an O(n) memmove on every eviction.
            if queryCacheHead >= maxQueryCacheEntries {
                queryCacheKeys.removeFirst(queryCacheHead)
                queryCacheHead = 0
            }
        }
        queryCache[cacheKey] = result
        queryCacheKeys.append(cacheKey)
        cacheLock.unlock()

        return result
    }

    private static func ranked(_ hits: [SearchHit], limit: Int?) -> [SearchHit] {
        let hits = hits.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.snippet.triggerKeyword.count != b.snippet.triggerKeyword.count {
                return a.snippet.triggerKeyword.count < b.snippet.triggerKeyword.count
            }
            let order = a.snippet.triggerKeyword.localizedCaseInsensitiveCompare(b.snippet.triggerKeyword)
            if order != .orderedSame { return order == .orderedAscending }
            if a.id != b.id { return a.id.uuidString < b.id.uuidString }
            return a.groupID.uuidString < b.groupID.uuidString
        }

        let result: [SearchHit]
        if let limit, hits.count > limit {
            result = Array(hits.prefix(limit))
        } else {
            result = hits
        }

        return result
    }

    /// Body text as searched — capped at `maxIndexedBodyCharacters` exactly like
    /// `makeIndex`, so the legacy shim and the index path agree on huge snippets:
    /// same matches, same scores, and no unbounded folding work per call.
    private static func indexedBodyText(_ body: String) -> String {
        String(body.prefix(SnippetSearchIndex.maxIndexedBodyCharacters))
    }

    /// Legacy single-snippet scorer, kept as a shim. Returns `nil` when the snippet does not
    /// match at all.
    public static func score(snippet: SnippetModel, needle: String, groupName: String = "", groupEnabled: Bool = true) -> Int? {
        guard case .success(let terms) = tokenize(needle) else { return nil }
        guard !terms.isEmpty else { return nil }
        let entry = SnippetSearchIndex.Entry(
            snippet: snippet,
            groupID: UUID(),
            groupName: groupName,
            groupEnabled: groupEnabled,
            trigger: FoldedText.fold(snippet.triggerKeyword, locale: Locale.current),
            bareTrigger: FoldedText.fold(
                String(snippet.triggerKeyword.dropFirst(leadingSigilCount(of: snippet.triggerKeyword))),
                locale: Locale.current
            ),
            bareTriggerOffset: leadingSigilCount(of: snippet.triggerKeyword),
            title: FoldedText.fold(snippet.displayTitle, locale: Locale.current),
            group: FoldedText.fold(groupName, locale: Locale.current),
            tags: snippet.tags.map { FoldedText.fold($0, locale: Locale.current) },
            body: FoldedText.fold(indexedBodyText(snippet.replacementText), locale: Locale.current),
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
    private static func evaluate(entry: SnippetSearchIndex.Entry, terms: [QueryTerm]) -> Evaluation? {
        var total = 0
        var positiveCount = 0
        var highlightsByField: [SearchField: [Range<Int>]] = [:]

        for term in terms {
            let match = match(entry: entry, term: term)
            if term.excluded {
                if match != nil { return nil }
                continue
            }
            guard let best = match else { return nil }
            positiveCount += 1
            total += best.score
            highlightsByField[best.field, default: []].append(contentsOf: best.ranges)
        }

        let highlights = SearchField.allCases.compactMap { field -> SearchHighlight? in
            guard let ranges = highlightsByField[field], !ranges.isEmpty else { return nil }
            return SearchHighlight(field: field, ranges: mergeRanges(ranges))
        }
        return Evaluation(score: positiveCount == 0 ? 0 : total / positiveCount, highlights: highlights)
    }

    private struct QueryTerm {
        let text: [Character]
        let field: SearchField?
        let state: String?
        let literal: Bool
        let excluded: Bool
    }

    private static func match(entry: SnippetSearchIndex.Entry, term: QueryTerm) -> FieldMatch? {
        if let state = term.state {
            let matches: Bool
            switch state {
            case "enabled": matches = entry.snippet.enabled && entry.groupEnabled
            case "disabled": matches = !entry.snippet.enabled || !entry.groupEnabled
            case "secret": matches = entry.snippet.isSecret
            case "image": matches = entry.snippet.isImageSnippet
            case "ai": matches = !entry.snippet.aiTransform.isEmpty
            case "text": matches = !entry.snippet.isSecret && !entry.snippet.isImageSnippet && entry.snippet.aiTransform.isEmpty
            default: matches = false
            }
            return matches ? FieldMatch(score: 0, field: .tag, ranges: []) : nil
        }
        if !term.literal && term.field == nil && !term.excluded {
            return bestMatch(entry: entry, term: term.text)
        }
        // Explicit filters and exclusions are literal, never fuzzy. A negative term should
        // not unexpectedly remove a row merely because its letters form a subsequence.
        let fields: [(SearchField, FoldedText)] = [
            (.trigger, entry.trigger), (.title, entry.title), (.group, entry.group), (.content, entry.body)
        ]
        for (field, text) in fields where term.field == nil || term.field == field {
            if let range = firstOccurrence(of: term.text, in: text.characters) {
                return FieldMatch(score: field == .trigger ? 1_000 : 600, field: field,
                                  ranges: text.originalRanges([range]))
            }
        }
        if term.field == nil || term.field == .tag,
           entry.tags.contains(where: { firstOccurrence(of: term.text, in: $0.characters) != nil }) {
            return FieldMatch(score: 600, field: .tag, ranges: [])
        }
        return nil
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

        // 3. Tags. Above the group name because a tag is a deliberate statement about this
        // one snippet, where a group is an organisational bucket its neighbours share.
        for tag in entry.tags where !tag.isEmpty {
            let characters = tag.characters
            if characters == term {
                return FieldMatch(score: 560, field: .tag, ranges: [])
            }
            if characters.starts(with: term) {
                return FieldMatch(score: 520, field: .tag, ranges: [])
            }
        }
        for tag in entry.tags where !tag.isEmpty {
            if firstOccurrence(of: term, in: tag.characters) != nil {
                return FieldMatch(score: 440, field: .tag, ranges: [])
            }
        }

        // 4. Group name — §4.7: previously display-only.
        if !entry.group.isEmpty {
            if entry.group.characters.starts(with: term) {
                return FieldMatch(score: 420, field: .group, ranges: entry.group.originalRanges([0..<term.count]))
            }
            if let range = firstOccurrence(of: term, in: entry.group.characters) {
                return FieldMatch(score: 380, field: .group, ranges: entry.group.originalRanges([range]))
            }
        }

        // 5. Fuzzy subsequence on the trigger — `sgn` finds `:signature`.
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

        // 6. Body, last and weakest.
        if let range = firstOccurrence(of: term, in: entry.body.characters) {
            return FieldMatch(score: 200, field: .content, ranges: entry.body.originalRanges([range]))
        }
        return nil
    }

    // MARK: Matching primitives

    /// Splits a query into folded terms. Whitespace separates AND-ed terms (§4.7).
    /// Most terms one query contributes. Every term is scanned against every indexed field of
    /// every snippet, so an unbounded term count makes a paste into the search field a
    /// library-sized amount of work on the keystroke path.
    static let maximumQueryTerms = 12

    public static let maximumQueryUTF8Bytes = 4_096

    private static func tokenize(_ query: String, locale: Locale? = .current) -> Result<[QueryTerm], QueryIssue> {
        // Reject overflow without decoding a partial scalar or dropping trailing constraints.
        guard query.utf8.prefix(maximumQueryUTF8Bytes + 1).count <= maximumQueryUTF8Bytes else {
            return .failure(.tooLong)
        }
        let characters = Array(query)
        var terms: [QueryTerm] = []
        var index = 0
        while index < characters.count {
            if characters[index].isWhitespace { index += 1; continue }
            let allowsExclusion = characters[index] == "-"
            let startsQuoted = characters[index] == "\"" || (allowsExclusion && index + 1 < characters.count && characters[index + 1] == "\"")
            var token = ""
            var quoted = false
            var hadQuote = false
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace && !quoted { break }
                if character == "\\", index + 1 < characters.count,
                   characters[index + 1] == "\"" || characters[index + 1] == "\\" {
                    index += 1
                    token.append(characters[index])
                } else if character == "\"" {
                    quoted.toggle()
                    hadQuote = true
                } else {
                    token.append(character)
                }
                index += 1
            }
            // A lone hyphen remains searchable; a leading hyphen on a term excludes it.
            let excluded = allowsExclusion && token.hasPrefix("-") && token.count > 1
            if excluded { token.removeFirst() }
            var field: SearchField?
            var state: String?
            if !startsQuoted, let colon = token.firstIndex(of: ":") {
                let name = String(token[..<colon]).lowercased()
                let value = String(token[token.index(after: colon)...])
                if name == "is" { state = value.lowercased(); token = value }
                else if let known = SearchField(rawValue: name) { field = known; token = value }
            }
            let folded = FoldedText.fold(token, locale: locale).characters
            // Neither a positive nor a negative incomplete filter may widen the result set.
            if folded.isEmpty {
                if state != nil || field != nil { return .failure(.incompleteFilter) }
                continue
            }
            guard terms.count < maximumQueryTerms else { return .failure(.tooManyTerms) }
            terms.append(QueryTerm(text: folded, field: field, state: state,
                                   literal: hadQuote, excluded: excluded))
        }
        return .success(terms)
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
