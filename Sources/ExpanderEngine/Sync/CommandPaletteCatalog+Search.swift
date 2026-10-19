import Foundation
import NaturalLanguage

extension CommandPaletteCatalog {

    // MARK: - Query Caching & Command Index

    private static let paletteCacheLock = UnfairLock()

    private struct PaletteQueryCacheKey: Hashable {
        let query: String
        let libraryStamp: SearchLibraryStamp
        let commandStatsRevision: UInt64
        let snippetStatsRevision: UInt64
        let language: AppLanguage
        let commandLimit: Int
        let snippetLimit: Int
        let hasUndo: Bool
        /// Pasteboard `changeCount` when the caller supplies one; otherwise the preview's hash.
        let clipboardChangeCount: Int?
        let clipboardHash: Int
        let aiDisabledReason: String?
        let semanticBoostIDs: [String]
        let routedText: String?
        let context: PaletteContext
        /// Revision of whatever stores the caller's boost closures actually read. The two
        /// shared revisions above cannot stand in for them: a caller boosting from its own
        /// store would mutate that store without moving `shared.revision`, leaving the cache
        /// serving rankings computed from counts that had already changed.
        let boostRevision: UInt64
        let boostSource: ObjectIdentifier?
    }

    /// Test seam: number of `buildRows` calls served from the cache.
    ///
    /// Without it a caching test can only compare two identical computations, which is true
    /// whether or not a cache exists — it proves determinism, not caching.
    private(set) static var rowCacheHitCount = 0
    /// Hits of the per-`changeCount` count-summary cache. A query change used to rescan the
    /// whole clipboard for `.count` even when the pasteboard had not changed.
    private(set) static var countSummaryCacheHitCount = 0
    private static var cachedCountSummary: (changeCount: Int, summary: String)?

    private static var rowQueryCache: [PaletteQueryCacheKey: [PaletteListRow]] = [:]
    private static var rowQueryCacheKeys: [PaletteQueryCacheKey] = []
    private static let maxRowQueryCacheEntries = 64

    struct CommandIndexEntry {
        let command: PaletteCommand
        let foldedTrigger: String
        let foldedTitle: String
        let foldedSubtitle: String
        let foldedAliases: [String]
        let foldedAliasBlob: String
        let searchBlob: String
    }

    private struct CommandSearchIndex {
        let language: AppLanguage
        let entries: [CommandIndexEntry]
    }

    private static var cachedCommandIndex: CommandSearchIndex?

    private static func commandIndex(loc: LocalizationManager) -> CommandSearchIndex {
        let lang = loc.language
        paletteCacheLock.lock()
        if let cached = cachedCommandIndex, cached.language == lang {
            paletteCacheLock.unlock()
            return cached
        }
        paletteCacheLock.unlock()

        let entries = commands.map { cmd in
            CommandIndexEntry(
                command: cmd,
                foldedTrigger: cmd.trigger.lowercased(),
                foldedTitle: loc.s(cmd.titleKey).lowercased(),
                foldedSubtitle: loc.s(cmd.subtitleKey).lowercased(),
                foldedAliases: cmd.aliases,
                foldedAliasBlob: cmd.aliases.joined(separator: "\n"),
                searchBlob: cmd.searchBlob
            )
        }
        let fresh = CommandSearchIndex(language: lang, entries: entries)
        paletteCacheLock.lock()
        cachedCommandIndex = fresh
        paletteCacheLock.unlock()
        return fresh
    }

    /// Drops query-level caches, command indexes, and semantic embedding vectors.
    public static func invalidateCache() {
        paletteCacheLock.lock()
        rowQueryCache.removeAll(keepingCapacity: false)
        rowQueryCacheKeys.removeAll(keepingCapacity: false)
        cachedCommandIndex = nil
        cachedCommandsByID = nil
        rowCacheHitCount = 0
        countSummaryCacheHitCount = 0
        cachedCountSummary = nil
        paletteCacheLock.unlock()
        PaletteSemanticIndex.invalidateCache()
    }

    private static var cachedCommandsByID: [String: PaletteCommand]?

    /// Catalogue keyed by id. Cached because the rescue pass runs per keystroke and the
    /// catalogue is a `let` constant.
    static func commandsByID() -> [String: PaletteCommand] {
        paletteCacheLock.lock()
        if let cached = cachedCommandsByID {
            paletteCacheLock.unlock()
            return cached
        }
        paletteCacheLock.unlock()
        let fresh = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
        paletteCacheLock.lock()
        cachedCommandsByID = fresh
        paletteCacheLock.unlock()
        return fresh
    }

    // MARK: - Search

    /// Offline ranking: alias / trigger / localized title token match + fuzzy subsequence.
    /// Never blocks on a model. Optional semantic boost only reorders when `semanticBoostIDs` is set.
    public static func matchCommands(
        query: String,
        loc: LocalizationManager = .shared,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        clipboardPreview: String? = nil,
        semanticBoostIDs: [String] = [],
        commandUsageBoost: ((String) -> Int)? = nil,
        aiDisabledReason: String? = nil,
        context: PaletteContext = .none,
        clipboardChangeCount: Int? = nil,
        limit: Int = 40
    ) -> [PaletteCommandHit] {
        guard limit > 0 else { return [] }
        let trimmed = boundedQuery(query)
        var hits: [PaletteCommandHit] = []

        if let typed = parseTypedQuery(trimmed) {
            hits.append(contentsOf: hitsForTypedQuery(
                typed,
                loc: loc,
                now: now,
                locale: locale,
                timeZone: timeZone,
                aiDisabledReason: aiDisabledReason
            ))
        }

        if trimmed.isEmpty {
            let top = CommandUsageStatsStore.shared.topCommandIDs(limit: 10)
            let recent = CommandUsageStatsStore.shared.recentCommandIDs(limit: 10)
            var suggestedIDs: [String] = []
            for id in top where !suggestedIDs.contains(id) {
                suggestedIDs.append(id)
            }
            for id in recent where !suggestedIDs.contains(id) {
                suggestedIDs.append(id)
            }
            let fallback = suggestionIDs(for: context, aiEnabled: aiDisabledReason == nil)
            for id in fallback where !suggestedIDs.contains(id) {
                suggestedIDs.append(id)
            }
            if AIUndoStore.hasUndo, !suggestedIDs.contains("ai.undo") {
                suggestedIDs.insert("ai.undo", at: 0)
            }
            let byID = commandsByID()
            for (index, id) in suggestedIDs.enumerated() {
                guard let command = byID[id] else { continue }
                if case .undoAI = command.action, !AIUndoStore.hasUndo { continue }
                var score = (id == "ai.undo" ? 100 : max(1, 40 - index))
                if let boost = commandUsageBoost?(command.id) {
                    score = Saturating.adding(score, max(0, boost))
                } else {
                    score = Saturating.adding(score, CommandUsageStatsStore.shared.rankBoost(for: command.id))
                }
                // Habit still counts, but a live selection says more about the next step than
                // a tally does: the most-used command is often a date insert, and that is not
                // what a paragraph was selected for.
                score = Saturating.adding(score, contextBoost(
                    for: command, context: context, aiEnabled: aiDisabledReason == nil
                ))
                hits.append(makeHit(
                    command,
                    score: max(1, score),
                    loc: loc,
                    now: now,
                    locale: locale,
                    timeZone: timeZone,
                    clipboardPreview: clipboardPreview,
                    aiDisabledReason: aiDisabledReason,
                    clipboardChangeCount: clipboardChangeCount
                ))
            }
            hits.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.command.trigger.localizedCaseInsensitiveCompare(b.command.trigger) == .orderedAscending
            }
            var seen = Set<String>()
            hits = hits.filter { seen.insert($0.id).inserted }
            return Array(hits.prefix(limit))
        }

        let terms = tokenize(trimmed)
        guard !terms.isEmpty else { return Array(hits.prefix(limit)) }

        let boostIndex = Dictionary(
            uniqueKeysWithValues: semanticBoostIDs.enumerated().map {
                ($0.element, semanticBoostWeight - $0.offset * semanticBoostDecay)
            }
        )

        let lexicalStart = hits.count
        var admitted = Set<String>()
        let index = commandIndex(loc: loc)
        let scoredTerms = contentTerms(terms)

        // Score every command against every term first. Admission depends on which terms the
        // catalogue as a whole understands, so no command can be judged until all of them have
        // been measured.
        var perCommand: [(entry: CommandIndexEntry, scores: [Int?])] = []
        perCommand.reserveCapacity(index.entries.count)
        var scoresByID: [String: [Int?]] = [:]
        var discriminating = [Bool](repeating: false, count: scoredTerms.count)
        for entry in index.entries {
            if case .undoAI = entry.command.action, !AIUndoStore.hasUndo { continue }
            let scores = termScores(entry: entry, terms: scoredTerms)
            for (i, value) in scores.enumerated()
            where (value ?? 0) >= minimumDiscriminatingTermScore {
                discriminating[i] = true
            }
            scoresByID[entry.command.id] = scores
            perCommand.append((entry, scores))
        }

        for (entry, scores) in perCommand {
            let command = entry.command
            guard let score = combinedScore(
                termScores: scores, discriminating: discriminating
            ) else { continue }
            var adjusted = score
            if let boost = boostIndex[command.id] {
                adjusted = Saturating.adding(adjusted, max(0, boost))
            }
            // Falls back to the shared store rather than silently dropping personalization.
            // The empty-query branch above has always done this; the typed branch did not, so
            // any caller that forgot the closure lost usage weighting with no symptom.
            adjusted = Saturating.adding(adjusted, max(0, commandUsageBoost?(command.id)
                ?? CommandUsageStatsStore.shared.rankBoost(for: command.id)))
            adjusted = Saturating.adding(adjusted, conversationalBoost(query: trimmed, command: command))
            adjusted = Saturating.adding(adjusted, contextBoost(
                for: command, context: context, aiEnabled: aiDisabledReason == nil
            ))
            admitted.insert(command.id)
            hits.append(makeHit(
                command,
                score: adjusted,
                loc: loc,
                now: now,
                locale: locale,
                timeZone: timeZone,
                clipboardPreview: clipboardPreview,
                aiDisabledReason: aiDisabledReason,
                clipboardChangeCount: clipboardChangeCount
            ))
        }

        // Semantic rescue. The boost above can only reorder commands the lexical pass already
        // admitted, so a semantically obvious command that shares no token with the query
        // ("shorten this a bit" → condense) could never be surfaced by it. When the lexical
        // pass comes back thin, add the nearest commands it missed — scored below every real
        // lexical hit, so they fill the tail rather than displacing a command the user spelled.
        if hits.count - lexicalStart < semanticRescueThreshold, !semanticBoostIDs.isEmpty {
            let byID = commandsByID()
            for (offset, id) in semanticBoostIDs.enumerated() {
                guard !admitted.contains(id), let command = byID[id] else { continue }
                if case .undoAI = command.action, !AIUndoStore.hasUndo { continue }
                // Same veto the lexical pass applies: a command that misses a term the
                // catalogue understands is not a candidate, however close it looks in
                // embedding space. Without this, "fix telugu" could reach proofread through
                // the back door the lexical pass just closed.
                if let scores = scoresByID[id],
                   scores.indices.contains(where: { discriminating[$0] && scores[$0] == nil }) {
                    continue
                }
                var adjusted = max(1, semanticRescueBaseScore - offset * semanticRescueDecay)
                adjusted = Saturating.adding(adjusted, max(0, commandUsageBoost?(command.id)
                    ?? CommandUsageStatsStore.shared.rankBoost(for: command.id)))
                adjusted = Saturating.adding(adjusted, conversationalBoost(query: trimmed, command: command))
                adjusted = Saturating.adding(adjusted, contextBoost(
                    for: command, context: context, aiEnabled: aiDisabledReason == nil
                ))
                admitted.insert(id)
                hits.append(makeHit(
                    command,
                    score: adjusted,
                    loc: loc,
                    now: now,
                    locale: locale,
                    timeZone: timeZone,
                    clipboardPreview: clipboardPreview,
                    aiDisabledReason: aiDisabledReason,
                    clipboardChangeCount: clipboardChangeCount
                ))
            }
        }

        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.command.trigger.localizedCaseInsensitiveCompare(b.command.trigger) == .orderedAscending
        }

        var seen = Set<String>()
        hits = hits.filter { seen.insert($0.id).inserted }
        if hits.count > limit {
            hits = Array(hits.prefix(limit))
        }
        return hits
    }

    /// Merges command hits with `SnippetSearch` results into a sectioned list.
    public static func buildRows(
        query: String,
        groups: [SnippetGroup],
        loc: LocalizationManager = .shared,
        usageBoost: ((UUID) -> Int)? = nil,
        clipboardPreview: String? = nil,
        semanticBoostIDs: [String] = [],
        commandUsageBoost: ((String) -> Int)? = nil,
        aiDisabledReason: String? = nil,
        commandLimit: Int = 20,
        snippetLimit: Int = 40,
        boostRevision: UInt64? = nil,
        boostSource: ObjectIdentifier? = nil,
        clipboardChangeCount: Int? = nil,
        libraryRevision: UInt64? = nil,
        libraryID: UUID? = nil,
        routedResult: PaletteToolRouter.Routed? = nil,
        context: PaletteContext = .none
    ) -> [PaletteListRow] {
        guard queryIssue(for: query) == nil else { return [] }
        let trimmed = boundedQuery(query)
        let commandLimit = max(0, commandLimit)
        let snippetLimit = max(0, snippetLimit)
        // Boost closures cannot be compared, so rankings computed from them are cacheable only
        // when the caller names the object they read and its revision (both are part of the key).
        let canCache = (usageBoost == nil && commandUsageBoost == nil)
            || (boostRevision != nil && boostSource != nil)
        let cacheKey: PaletteQueryCacheKey? = canCache ? PaletteQueryCacheKey(
            query: trimmed,
            libraryStamp: SearchLibraryStamp.resolve(groups: groups, includeDisabled: false,
                                                     revision: libraryRevision, libraryID: libraryID,
                                                     locale: .current),
            commandStatsRevision: CommandUsageStatsStore.shared.revision,
            snippetStatsRevision: UsageStatsStore.shared.revision,
            language: loc.language,
            commandLimit: commandLimit,
            snippetLimit: snippetLimit,
            hasUndo: AIUndoStore.hasUndo,
            clipboardChangeCount: clipboardChangeCount,
            // Hashing the preview walks the whole clipboard; the change count names it for free.
            clipboardHash: clipboardChangeCount == nil ? (clipboardPreview?.hashValue ?? 0) : 0,
            aiDisabledReason: aiDisabledReason,
            semanticBoostIDs: semanticBoostIDs,
            routedText: routedResult.flatMap { $0.query == trimmed ? $0.text : nil },
            context: context,
            boostRevision: boostRevision ?? 0,
            boostSource: boostSource
        ) : nil

        paletteCacheLock.lock()
        if let cacheKey, let cached = rowQueryCache[cacheKey] {
            rowCacheHitCount &+= 1
            paletteCacheLock.unlock()
            // Cache ranking, not generated values or clock readings. Every opening gets a
            // fresh UUID/date preview, resolved through the same owner as an uncached hit.
            return cached.map { row in
                guard case .command(let hit) = row else { return row }
                switch hit.command.action {
                case .date, .generate:
                    return .command(makeHit(hit.command, score: hit.score, loc: loc, now: Date(),
                                            locale: .current, timeZone: .current,
                                            clipboardPreview: clipboardPreview, aiDisabledReason: aiDisabledReason))
                default: return row
                }
            }
        }
        paletteCacheLock.unlock()

        let isExplicitCommandQuery = commandLimit > 0 && trimmed.hasPrefix(">")
        let cmdQuery = isExplicitCommandQuery
            ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            : trimmed

        let commandHits = matchCommands(
            query: cmdQuery,
            loc: loc,
            clipboardPreview: clipboardPreview,
            semanticBoostIDs: semanticBoostIDs,
            commandUsageBoost: commandUsageBoost,
            aiDisabledReason: aiDisabledReason,
            context: context,
            clipboardChangeCount: clipboardChangeCount,
            limit: isExplicitCommandQuery ? max(commandLimit, 50) : commandLimit
        )

        let snippetHits: [SearchHit]
        if isExplicitCommandQuery {
            snippetHits = []
        } else if trimmed.isEmpty {
            // One locked copy of the stats instead of two lock round trips per comparison.
            let usageStats = UsageStatsStore.shared.allStats()
            snippetHits = groups
                .filter(\.enabled)
                .flatMap { group in
                    group.snippets
                        .filter { $0.enabled && ($0.isSecret || !$0.triggerKeyword.isEmpty) }
                        .map { snippet in
                            let boost = usageBoost?(snippet.id) ?? UsageStatsStore.shared.rankBoost(for: snippet.id)
                            return SearchHit(
                                snippet: snippet,
                                groupID: group.id,
                                groupName: group.name,
                                score: boost
                            )
                        }
                }
                .sorted { a, b in
                    if a.score != b.score { return a.score > b.score }
                    let aLast = usageStats[a.snippet.id]?.lastUsedAt ?? a.snippet.updatedAt
                    let bLast = usageStats[b.snippet.id]?.lastUsedAt ?? b.snippet.updatedAt
                    if aLast != bLast { return aLast > bLast }
                    return a.snippet.updatedAt > b.snippet.updatedAt
                }
                .prefix(snippetLimit)
                .map { $0 }
        } else {
            snippetHits = SnippetSearch.run(
                query: trimmed,
                in: groups,
                includeDisabled: false,
                limit: snippetLimit,
                boost: usageBoost,
                boostRevision: boostRevision,
                boostSource: boostSource,
                revision: libraryRevision,
                libraryID: libraryID
            )
        }

        var rows: [PaletteListRow] = []

        var commandSection = commandHits.filter { $0.command.section == .commands }

        // A routed answer leads the command section when it is still answering the query on
        // screen. Routing is debounced and asynchronous, so an answer to an older query is
        // dropped rather than shown against text the user has already moved past.
        if commandLimit > 0, let routed = routedResult, routed.query == trimmed, !isExplicitCommandQuery {
            commandSection.insert(routedHit(routed, loc: loc), at: 0)
        }
        let aiSection = commandHits.filter { $0.command.section == .ai }

        // Sections lead by their best hit, not by a fixed order.
        //
        // They used to be emitted commands-then-AI-then-snippets unconditionally, so an AI row
        // could outscore every command row and still render below all of them. With a
        // selection live that put the whole reason the palette was opened under the fold, and
        // no amount of scoring inside a section could fix it.
        //
        // Ties keep the canonical order, so the list does not jitter between keystrokes when
        // two sections happen to match equally well.
        let sections: [(section: PaletteSection, best: Int, rows: [PaletteListRow])] = [
            (.commands, commandSection.first?.score ?? Int.min, commandSection.map { .command($0) }),
            (.ai, aiSection.first?.score ?? Int.min, aiSection.map { .command($0) }),
            (.snippets, snippetHits.first?.score ?? Int.min, snippetHits.map { .snippet($0) })
        ]
        let canonical = PaletteSection.allCases
        let ordered = sections.sorted {
            $0.best != $1.best
                ? $0.best > $1.best
                : canonical.firstIndex(of: $0.section)! < canonical.firstIndex(of: $1.section)!
        }
        for entry in ordered where !entry.rows.isEmpty {
            rows.append(.header(entry.section))
            rows.append(contentsOf: entry.rows)
        }

        guard let cacheKey else { return rows }
        paletteCacheLock.lock()
        if rowQueryCache[cacheKey] != nil {
            paletteCacheLock.unlock()
            return rows
        }
        if rowQueryCache.count >= maxRowQueryCacheEntries, !rowQueryCacheKeys.isEmpty {
            let oldest = rowQueryCacheKeys.removeFirst()
            rowQueryCache.removeValue(forKey: oldest)
        }
        rowQueryCache[cacheKey] = rows
        rowQueryCacheKeys.append(cacheKey)
        paletteCacheLock.unlock()

        return rows
    }

    /// Full `countSummary` once per pasteboard change. A nil change count always scans `text`,
    /// so tests that pass a string without a change count stay honest. The same change count
    /// with different text is a stale read; production updates both together.
    private static func countSummary(for text: String, changeCount: Int?) -> String {
        if let changeCount, !text.isEmpty {
            paletteCacheLock.lock()
            if let cached = cachedCountSummary, cached.changeCount == changeCount {
                countSummaryCacheHitCount &+= 1
                paletteCacheLock.unlock()
                return cached.summary
            }
            paletteCacheLock.unlock()
        }
        let summary = PaletteTextOps.countSummary(for: text)
        if let changeCount, !text.isEmpty {
            paletteCacheLock.lock()
            cachedCountSummary = (changeCount, summary)
            paletteCacheLock.unlock()
        }
        return summary
    }

    private static func makeHit(
        _ command: PaletteCommand,
        score: Int,
        loc: LocalizationManager,
        now: Date,
        locale: Locale,
        timeZone: TimeZone,
        clipboardPreview: String?,
        aiDisabledReason: String?,
        clipboardChangeCount: Int? = nil
    ) -> PaletteCommandHit {
        switch command.action {
        case .date(let tool):
            let text = resolveDate(tool, now: now, locale: locale, timeZone: timeZone)
            return PaletteCommandHit(command: command, score: score, insertText: text, preview: text)
        case .clipboard:
            let text = clipboardPreview ?? ""
            let preview = text.isEmpty
                ? loc.s("palette.tool.clipboard.empty")
                : clippedClipboardPreview(text)
            return PaletteCommandHit(command: command, score: score, insertText: text, preview: preview)
        case .generate(let op):
            let text = PaletteTextOps.generate(op)
            return PaletteCommandHit(command: command, score: score, insertText: text, preview: text)
        case .insert:
            return PaletteCommandHit(
                command: command,
                score: score,
                insertText: "",
                preview: loc.s(command.subtitleKey)
            )
        case .count:
            let source = clipboardPreview ?? ""
            let summary = source.isEmpty
                ? loc.s("palette.tool.count.empty")
                : countSummary(for: source, changeCount: clipboardChangeCount)
            return PaletteCommandHit(command: command, score: score, insertText: "", preview: summary)
        case .undoAI:
            let preview = AIUndoStore.preview ?? loc.s("palette.ai.undo.detail")
            return PaletteCommandHit(command: command, score: score, insertText: "", preview: preview)
        case .ai(let kind) where !kind.requiresModel:
            // Runs locally (`AILocalTransform`), so the model's availability — and the
            // locale gate that goes with it — has nothing to say about this row.
            return PaletteCommandHit(
                command: command,
                score: score,
                insertText: "",
                preview: loc.s("palette.ai.local.subtitle")
            )
        case .ai, .aiCustom:
            return PaletteCommandHit(
                command: command,
                score: score,
                insertText: "",
                preview: loc.s(command.subtitleKey),
                disabledReason: aiDisabledReason
            )
        case .textOp, .navigate, .voiceDictation:
            return PaletteCommandHit(
                command: command,
                score: score,
                insertText: "",
                preview: loc.s(command.subtitleKey)
            )
        }
    }
}
