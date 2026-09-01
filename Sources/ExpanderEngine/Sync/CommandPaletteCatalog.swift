import Foundation
import NaturalLanguage

// MARK: - Palette model

/// Section headers in the hybrid command palette (⌘/).
public enum PaletteSection: String, Sendable, CaseIterable, Equatable {
    case commands
    case ai
    case snippets

    public var titleKey: String {
        switch self {
        case .commands: return "palette.section.commands"
        case .ai: return "palette.section.ai"
        case .snippets: return "palette.section.snippets"
        }
    }
}

/// Navigation targets opened from the palette (no text injection).
public enum PaletteNavigateAction: String, Sendable, Equatable {
    case preferences
    case manageSnippets
    case permissionRecovery
    case voicePreferences
    case createSnippet
    case toggleExpansion
    case importLibrary
    case exportLibrary
    case testExpansionLab
    case keyboardShortcuts
    case recentActivity
}

/// Date/time insert tools resolved through `DateFormatLibrary`.
public enum PaletteDateTool: Equatable, Sendable {
    /// Localized medium date for today (`days == 0`), tomorrow (`1`), yesterday (`-1`), etc.
    case offsetDays(Int, format: String)
    /// Arbitrary `DateOffset` (e.g. `+3w`).
    case offset(DateOffset, format: String)
    case timeNow
    case iso
    case datetime
    case full
    case epoch
    case fromEpoch
}

/// What happens when the user commits a palette command row.
public enum PaletteCommandAction: Equatable, Sendable {
    case ai(AITransformKind)
    /// One-shot custom instruction from `> …` free text.
    case aiCustom(instructions: String)
    case date(PaletteDateTool)
    case clipboard
    case navigate(PaletteNavigateAction)
    /// Instant transform of the current selection (or clipboard fallback).
    case textOp(PaletteTextOp)
    case generate(PaletteGenerateOp)
    /// Insert pre-resolved `insertText` (math result, etc.).
    case insert
    /// Preview-only character/word/line count of selection/clipboard.
    case count
    case undoAI
    /// Trigger Smart Dictation recording.
    case voiceDictation
}

/// One built-in command/tool row (not a user snippet).
public struct PaletteCommand: Equatable, Identifiable, Sendable {
    public let id: String
    public let section: PaletteSection
    /// Short badge shown like a trigger (`date+1`, `proofread`, …).
    public let trigger: String
    public let titleKey: String
    public let subtitleKey: String
    /// Lowercased English (and common misspellings) used for offline NL matching.
    public let aliases: [String]
    public let action: PaletteCommandAction
    /// Precomputed lowercased search blob (trigger + aliases + title key tokens).
    public let searchBlob: String

    /// Built from the query itself rather than drawn from the catalogue (`=2+2`, `+3w`, a
    /// routed answer), so its id is unique per keystroke.
    ///
    /// Usage must not be recorded against these. Their ids can never be resolved back to a
    /// catalogue entry, so the entries are dead weight the moment they are written — and one
    /// per distinct expression typed means a stats file that grows without bound and a
    /// `totalUsage()` that counts rows nothing can ever rank.
    public let isEphemeral: Bool

    public init(
        id: String,
        section: PaletteSection,
        trigger: String,
        titleKey: String,
        subtitleKey: String,
        aliases: [String],
        action: PaletteCommandAction,
        searchBlob: String? = nil,
        isEphemeral: Bool = false
    ) {
        self.id = id
        self.section = section
        self.trigger = trigger
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
        let loweredAliases = aliases.map { $0.lowercased() }
        self.aliases = loweredAliases
        self.action = action
        self.isEphemeral = isEphemeral
        if let searchBlob {
            self.searchBlob = searchBlob
        } else {
            self.searchBlob = ([trigger.lowercased()] + loweredAliases).joined(separator: "\n")
        }
    }
}

/// A scored command hit, with a live preview string when the action inserts text.
public struct PaletteCommandHit: Equatable, Identifiable, Sendable {
    public let command: PaletteCommand
    public let score: Int
    /// Resolved insert text for date/clipboard/math/generate, or empty for AI / navigate / textOp.
    public let insertText: String
    /// Display preview (often same as `insertText`, or a short hint).
    public let preview: String
    /// When set, the AI row is shown but not selectable (locale gate).
    public let disabledReason: String?

    public var id: String { command.id }

    public var isEnabled: Bool { disabledReason == nil }

    public init(
        command: PaletteCommand,
        score: Int,
        insertText: String,
        preview: String,
        disabledReason: String? = nil
    ) {
        self.command = command
        self.score = score
        self.insertText = insertText
        self.preview = preview
        self.disabledReason = disabledReason
    }
}

/// Flat list row for the hybrid palette UI (headers + command/snippet hits).
public enum PaletteListRow: Equatable {
    case header(PaletteSection)
    case command(PaletteCommandHit)
    case snippet(SearchHit)

    public var isSelectable: Bool {
        switch self {
        case .header: return false
        case .command(let hit): return hit.isEnabled
        case .snippet: return true
        }
    }
}

/// Result of the typed-query parser (`=`, `>`, date offsets, weekday phrases).
public enum TypedPaletteQuery: Equatable, Sendable {
    case math(expression: String)
    case customAI(instructions: String)
    case relativeDays(days: Int, format: String, trigger: String)
    case relativeOffset(DateOffset, format: String, trigger: String)
}

// MARK: - Catalog + search

/// Built-in commands for the hybrid ⌘/ palette, plus offline synonym / token ranking.
public enum CommandPaletteCatalog {

    /// Static catalogue (AI transforms, date tools, text ops, clipboard, navigation).
    public static let commands: [PaletteCommand] = {
        var list: [PaletteCommand] = []

        for kind in AITransformKind.builtInPalette {
            list.append(PaletteCommand(
                id: "ai.\(kind.rawValue)",
                section: .ai,
                trigger: kind.rawValue,
                titleKey: kind.localizationKey,
                subtitleKey: kind.requiresModel ? "palette.ai.subtitle" : "palette.ai.local.subtitle",
                aliases: Self.aiAliases(for: kind),
                action: .ai(kind)
            ))
        }

        list.append(contentsOf: dateCommands())
        list.append(contentsOf: textOpCommands())
        list.append(contentsOf: generateCommands())

        list.append(PaletteCommand(
            id: "tool.count",
            section: .commands,
            trigger: "count",
            titleKey: "palette.tool.count",
            subtitleKey: "palette.tool.count.detail",
            aliases: ["count", "word count", "char count", "character count", "line count"],
            action: .count
        ))
        list.append(PaletteCommand(
            id: "tool.clipboard",
            section: .commands,
            trigger: "clip",
            titleKey: "palette.tool.clipboard",
            subtitleKey: "palette.tool.clipboard.detail",
            aliases: ["clipboard", "paste clipboard", "pasteboard", "clip", "insert clipboard"],
            action: .clipboard
        ))
        list.append(PaletteCommand(
            id: "ai.undo",
            section: .ai,
            trigger: "undo",
            titleKey: "palette.ai.undo",
            subtitleKey: "palette.ai.undo.detail",
            aliases: ["undo", "undo ai", "undo last ai", "restore selection", "revert ai"],
            action: .undoAI
        ))
        list.append(contentsOf: [
            PaletteCommand(
                id: "nav.preferences",
                section: .commands,
                trigger: "prefs",
                titleKey: "palette.nav.preferences",
                subtitleKey: "palette.nav.preferences.detail",
                aliases: ["preferences", "settings", "prefs", "options", "open preferences"],
                action: .navigate(.preferences)
            ),
            PaletteCommand(
                id: "nav.snippets",
                section: .commands,
                trigger: "snippets",
                titleKey: "palette.nav.snippets",
                subtitleKey: "palette.nav.snippets.detail",
                aliases: ["manage snippets", "snippets", "snippet manager", "library", "open snippets"],
                action: .navigate(.manageSnippets)
            ),
            PaletteCommand(
                id: "nav.recovery",
                section: .commands,
                trigger: "perms",
                titleKey: "palette.nav.recovery",
                subtitleKey: "palette.nav.recovery.detail",
                aliases: [
                    "permissions", "permission recovery", "accessibility", "input monitoring",
                    "fix recovery", "tcc"
                ],
                action: .navigate(.permissionRecovery)
            ),
            PaletteCommand(
                id: "voice.dictation",
                section: .commands,
                trigger: "voice",
                titleKey: "palette.voice.dictation",
                subtitleKey: "palette.voice.dictation.detail",
                aliases: ["voice", "dictate", "smart dictation", "transcribe", "speech", "speech to text", "whisper"],
                action: .voiceDictation
            ),
            PaletteCommand(
                id: "nav.voice",
                section: .commands,
                trigger: "voiceprefs",
                titleKey: "palette.nav.voice",
                subtitleKey: "palette.nav.voice.detail",
                aliases: ["voice preferences", "dictation preferences", "voice settings", "dictation settings", "model download"],
                action: .navigate(.voicePreferences)
            ),
            PaletteCommand(
                id: "nav.createSnippet",
                section: .commands,
                trigger: "newsnippet",
                titleKey: "palette.command.createSnippet",
                subtitleKey: "home.quickActions.title",
                aliases: ["new snippet", "create snippet", "add snippet", "make snippet"],
                action: .navigate(.createSnippet)
            ),
            PaletteCommand(
                id: "nav.toggleExpansion",
                section: .commands,
                trigger: "pause",
                titleKey: "palette.command.toggleExpansion",
                subtitleKey: "home.status.title",
                aliases: ["toggle expansion", "pause expansion", "resume expansion", "mute expansion", "stop engine"],
                action: .navigate(.toggleExpansion)
            ),
            PaletteCommand(
                id: "nav.import",
                section: .commands,
                trigger: "import",
                titleKey: "palette.command.importLibrary",
                subtitleKey: "menu.import",
                aliases: ["import library", "import snippets", "import espanso", "import json", "import csv"],
                action: .navigate(.importLibrary)
            ),
            PaletteCommand(
                id: "nav.export",
                section: .commands,
                trigger: "export",
                titleKey: "palette.command.exportLibrary",
                subtitleKey: "menu.export",
                aliases: ["export library", "export snippets", "export json", "backup library"],
                action: .navigate(.exportLibrary)
            ),
            PaletteCommand(
                id: "nav.lab",
                section: .commands,
                trigger: "lab",
                titleKey: "palette.command.openLab",
                subtitleKey: "lab.title",
                aliases: ["test expansion lab", "lab", "test injection", "diagnostics lab"],
                action: .navigate(.testExpansionLab)
            ),
            PaletteCommand(
                id: "nav.shortcuts",
                section: .commands,
                trigger: "shortcuts",
                titleKey: "palette.command.shortcuts",
                subtitleKey: "shortcuts.window.title",
                aliases: ["shortcuts", "hotkeys", "keyboard shortcuts", "cheatsheet", "keybindings"],
                action: .navigate(.keyboardShortcuts)
            ),
            PaletteCommand(
                id: "nav.activity",
                section: .commands,
                trigger: "activity",
                titleKey: "activity.title",
                subtitleKey: "activity.title",
                aliases: ["activity", "recent activity", "history", "notifications", "event log"],
                action: .navigate(.recentActivity)
            )
        ])

        return list
    }()

    // MARK: - Typed query parser

    /// Unified parser for `= expr`, `> instruction`, `date±N`, `+3w`, `next friday`.
    public static func parseTypedQuery(_ raw: String) -> TypedPaletteQuery? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("=") {
            let expr = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expr.isEmpty else { return nil }
            return .math(expression: expr)
        }

        if trimmed.hasPrefix(">") {
            // Same normalization the AI action panel's instruction field uses, so the two
            // ways to author a custom transform cannot disagree about what counts as empty.
            guard let instructions = AIActionSelection.normalized(String(trimmed.dropFirst())) else {
                return nil
            }
            return .customAI(instructions: instructions)
        }

        if let relative = parseRelativeDayQuery(trimmed) {
            return .relativeDays(
                days: relative.days,
                format: relative.format,
                trigger: relative.trigger
            )
        }

        let lower = trimmed.lowercased()
        if let offset = DateOffset.parse(lower), !offset.isZero {
            // Full offset including weeks/months (e.g. +3w) — day-only already handled above.
            if !(offset.isDayOnly) {
                return .relativeOffset(offset, format: "medium", trigger: lower)
            }
        }

        if let weekday = parseNextWeekdayQuery(lower) {
            return .relativeDays(days: weekday.days, format: weekday.format, trigger: weekday.trigger)
        }

        return nil
    }

    /// Parses `date+1`, `date-2`, `date+3d`, `+1d` (bare), returning day offset + preferred format.
    /// Compiled once. These used to be built inside `parseRelativeDayQuery`, which
    /// `parseTypedQuery` calls from `matchCommands` — the palette's per-keystroke entry point —
    /// so every character typed compiled two regular expressions and threw them away.
    ///
    /// `try!` is safe here and was safe before: the patterns are literals, so a failure is a
    /// malformed pattern in this file, not anything a user can type.
    static let relativeDayPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"^date\s*([+-])\s*(\d{1,3})\s*d?$"#),
        try! NSRegularExpression(pattern: #"^([+-])\s*(\d{1,3})\s*d$"#)
    ]

    public static func parseRelativeDayQuery(_ raw: String) -> (days: Int, format: String, trigger: String, exactQuery: Bool)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        // Bare offset: +1d / -2d / +3w (day-equivalent for weeks via DateOffset)
        if let offset = DateOffset.parse(text), !offset.isZero {
            if offset.isDayOnly {
                return (offset.days, "medium", text, true)
            }
            // Convert weeks-only to days for the relative-days path.
            if offset.years == 0, offset.months == 0, offset.hours == 0,
               offset.minutes == 0, offset.seconds == 0,
               offset.weeks != 0, offset.days == 0 {
                return (offset.weeks * 7, "medium", text, true)
            }
        }

        // date+N / date-N / date+Nd
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in relativeDayPatterns {
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 3,
                  let signRange = Range(match.range(at: 1), in: text),
                  let numRange = Range(match.range(at: 2), in: text),
                  let magnitude = Int(text[numRange]) else { continue }
            let days = text[signRange] == "-" ? -magnitude : magnitude
            guard days != 0 else { continue }
            let format = text.contains("full") ? "full" : "medium"
            let trigger = "date\(days >= 0 ? "+" : "")\(days)"
            return (days, format, trigger, true)
        }

        // "next full date" without numeric offset → tomorrow full
        if text == "next full date" || text == "full date tomorrow" {
            return (1, "full", "date+1", true)
        }

        if let weekday = parseNextWeekdayQuery(text) {
            return (weekday.days, weekday.format, weekday.trigger, true)
        }

        return nil
    }

    // MARK: - Query Caching & Command Index

    private static let paletteCacheLock = UnfairLock()

    private struct PaletteQueryCacheKey: Hashable {
        let query: String
        let libraryFingerprint: UInt64
        let commandStatsRevision: UInt64
        let snippetStatsRevision: UInt64
        let language: AppLanguage
        let commandLimit: Int
        let snippetLimit: Int
        let hasUndo: Bool
        let clipboardHash: Int
        let aiDisabledReason: String?
        let semanticBoostIDs: [String]
        let routedText: String?
        /// Revision of whatever stores the caller's boost closures actually read. The two
        /// shared revisions above cannot stand in for them: a caller boosting from its own
        /// store would mutate that store without moving `shared.revision`, leaving the cache
        /// serving rankings computed from counts that had already changed.
        let boostRevision: UInt64
    }

    /// Test seam: number of `buildRows` calls served from the cache.
    ///
    /// Without it a caching test can only compare two identical computations, which is true
    /// whether or not a cache exists — it proves determinism, not caching.
    private(set) static var rowCacheHitCount = 0

    private static var rowQueryCache: [PaletteQueryCacheKey: [PaletteListRow]] = [:]
    private static var rowQueryCacheKeys: [PaletteQueryCacheKey] = []
    private static let maxRowQueryCacheEntries = 64

    private struct CommandIndexEntry {
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
        paletteCacheLock.unlock()
        PaletteSemanticIndex.invalidateCache()
    }

    // MARK: - Ranking weights

    /// Boost applied to the top semantic neighbour, decaying by rank.
    ///
    /// Deliberately smaller than it was (80, decaying by 5). The semantic index is an averaged
    /// static word embedding, not a model: it ranks `explainRegex` first for "tidy up my
    /// writing". At 80 a wrong neighbour outscored the personalization ceiling six times over
    /// and could unseat a confident lexical match. At 40 it breaks ties and reorders near-equal
    /// candidates, which is all a signal this noisy has earned.
    static let semanticBoostWeight = 40
    static let semanticBoostDecay = 3

    /// Score for a command surfaced *only* by semantic similarity. Below the weakest possible
    /// lexical hit (`minimumPartialTermScore * partialCoverageFloor` = 385), so a rescued row
    /// can never outrank a command the user actually spelled.
    static let semanticRescueBaseScore = 300
    static let semanticRescueDecay = 10

    /// Lexical hit count below which the rescue pass runs. Above it the lexical pass already
    /// filled the list and rescued rows would only crowd the tail.
    static let semanticRescueThreshold = 5

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
        limit: Int = 40
    ) -> [PaletteCommandHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
            // Shown when the palette opens with nothing typed. Registering a command is not
            // enough to make it discoverable — anything missing here stays invisible until
            // the user already knows its name.
            let fallback = [
                "date.today", "date.tomorrow", "date.time", "tool.clipboard",
                "ai.proofread", "ai.translate", "ai.totelugu", "ai.tohindi",
                "ai.formal", "ai.promptenhance",
                "nav.preferences", "nav.snippets", "tool.upper", "tool.uuid"
            ]
            for id in fallback where !suggestedIDs.contains(id) {
                suggestedIDs.append(id)
            }
            if AIUndoStore.hasUndo, !suggestedIDs.contains("ai.undo") {
                suggestedIDs.insert("ai.undo", at: 0)
            }
            let byID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
            for (index, id) in suggestedIDs.enumerated() {
                guard let command = byID[id] else { continue }
                if case .undoAI = command.action, !AIUndoStore.hasUndo { continue }
                var score = (id == "ai.undo" ? 100 : max(1, 40 - index))
                if let boost = commandUsageBoost?(command.id) {
                    score += boost
                } else {
                    score += CommandUsageStatsStore.shared.rankBoost(for: command.id)
                }
                hits.append(makeHit(
                    command,
                    score: max(1, score),
                    loc: loc,
                    now: now,
                    locale: locale,
                    timeZone: timeZone,
                    clipboardPreview: clipboardPreview,
                    aiDisabledReason: aiDisabledReason
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
            for (i, value) in scores.enumerated() where (value ?? 0) >= minimumPartialTermScore {
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
                adjusted += max(0, boost)
            }
            // Falls back to the shared store rather than silently dropping personalization.
            // The empty-query branch above has always done this; the typed branch did not, so
            // any caller that forgot the closure lost usage weighting with no symptom.
            adjusted += commandUsageBoost?(command.id)
                ?? CommandUsageStatsStore.shared.rankBoost(for: command.id)
            adjusted += conversationalBoost(query: trimmed, command: command)
            admitted.insert(command.id)
            hits.append(makeHit(
                command,
                score: adjusted,
                loc: loc,
                now: now,
                locale: locale,
                timeZone: timeZone,
                clipboardPreview: clipboardPreview,
                aiDisabledReason: aiDisabledReason
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
                adjusted += commandUsageBoost?(command.id)
                    ?? CommandUsageStatsStore.shared.rankBoost(for: command.id)
                adjusted += conversationalBoost(query: trimmed, command: command)
                admitted.insert(id)
                hits.append(makeHit(
                    command,
                    score: adjusted,
                    loc: loc,
                    now: now,
                    locale: locale,
                    timeZone: timeZone,
                    clipboardPreview: clipboardPreview,
                    aiDisabledReason: aiDisabledReason
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
        routedResult: PaletteToolRouter.Routed? = nil
    ) -> [PaletteListRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let libStamp = SnippetSearch.fingerprint(of: groups, includeDisabled: false)
        let cmdRev = CommandUsageStatsStore.shared.revision
        let snipRev = UsageStatsStore.shared.revision
        let clipHash = clipboardPreview?.hashValue ?? 0
        let cacheKey = PaletteQueryCacheKey(
            query: trimmed,
            libraryFingerprint: libStamp,
            commandStatsRevision: cmdRev,
            snippetStatsRevision: snipRev,
            language: loc.language,
            commandLimit: commandLimit,
            snippetLimit: snippetLimit,
            hasUndo: AIUndoStore.hasUndo,
            clipboardHash: clipHash,
            aiDisabledReason: aiDisabledReason,
            semanticBoostIDs: semanticBoostIDs,
            routedText: routedResult.flatMap { $0.query == trimmed ? $0.text : nil },
            boostRevision: boostRevision ?? 0
        )

        paletteCacheLock.lock()
        if let cached = rowQueryCache[cacheKey] {
            rowCacheHitCount &+= 1
            paletteCacheLock.unlock()
            return cached
        }
        paletteCacheLock.unlock()

        let isExplicitCommandQuery = trimmed.hasPrefix(">")
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
            limit: isExplicitCommandQuery ? max(commandLimit, 50) : commandLimit
        )

        let snippetHits: [SearchHit]
        if isExplicitCommandQuery {
            snippetHits = []
        } else if trimmed.isEmpty {
            snippetHits = groups
                .filter(\.enabled)
                .flatMap { group in
                    group.snippets
                        .filter { $0.enabled && !$0.triggerKeyword.isEmpty }
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
                    let aLast = UsageStatsStore.shared.lastUsedAt(for: a.snippet.id) ?? a.snippet.updatedAt
                    let bLast = UsageStatsStore.shared.lastUsedAt(for: b.snippet.id) ?? b.snippet.updatedAt
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
                boostRevision: boostRevision
            )
        }

        var rows: [PaletteListRow] = []

        var commandSection = commandHits.filter { $0.command.section == .commands }

        // A routed answer leads the command section when it is still answering the query on
        // screen. Routing is debounced and asynchronous, so an answer to an older query is
        // dropped rather than shown against text the user has already moved past.
        if let routed = routedResult, routed.query == trimmed, !isExplicitCommandQuery {
            commandSection.insert(routedHit(routed, loc: loc), at: 0)
        }
        let aiSection = commandHits.filter { $0.command.section == .ai }

        if !commandSection.isEmpty {
            rows.append(.header(.commands))
            rows.append(contentsOf: commandSection.map { .command($0) })
        }
        if !aiSection.isEmpty {
            rows.append(.header(.ai))
            rows.append(contentsOf: aiSection.map { .command($0) })
        }
        if !snippetHits.isEmpty {
            rows.append(.header(.snippets))
            rows.append(contentsOf: snippetHits.map { .snippet($0) })
        }

        paletteCacheLock.lock()
        if rowQueryCache.count >= maxRowQueryCacheEntries, !rowQueryCacheKeys.isEmpty {
            let oldest = rowQueryCacheKeys.removeFirst()
            rowQueryCache.removeValue(forKey: oldest)
        }
        rowQueryCache[cacheKey] = rows
        rowQueryCacheKeys.append(cacheKey)
        paletteCacheLock.unlock()

        return rows
    }

    // MARK: - Date resolution

    public static func resolveDate(
        _ tool: PaletteDateTool,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        switch tool {
        case .offsetDays(let days, let format):
            let spec: String
            if days == 0 {
                spec = format
            } else {
                let sign = days >= 0 ? "+" : ""
                spec = "\(format):\(sign)\(days)d"
            }
            return DateFormatLibrary.format(spec, now: now, locale: locale, timeZone: timeZone)
        case .offset(let offset, let format):
            let date = Calendar.current.date(byAdding: offset.dateComponents, to: now) ?? now
            return DateFormatLibrary.format(format, now: date, locale: locale, timeZone: timeZone)
        case .timeNow:
            return DateFormatLibrary.format("time", now: now, locale: locale, timeZone: timeZone)
        case .iso:
            return DateFormatLibrary.format("iso", now: now, locale: locale, timeZone: timeZone)
        case .datetime:
            return DateFormatLibrary.format("datetime", now: now, locale: locale, timeZone: timeZone)
        case .full:
            return DateFormatLibrary.format("full", now: now, locale: locale, timeZone: timeZone)
        case .epoch:
            return String(Int(now.timeIntervalSince1970))
        case .fromEpoch:
            return ""
        }
    }

    // MARK: - Scoring

    /// A partial match must land at least one term on a trigger, alias or title. Without
    /// this floor a single stray substring hit inside a search blob would admit the whole
    /// catalogue on any multi-word query.
    public static let minimumPartialTermScore = 700

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
        return content.isEmpty ? terms : content
    }

    /// Per-term match scores for one command; `nil` where the term did not match at all.
    private static func termScores(entry: CommandIndexEntry, terms: [String]) -> [Int?] {
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

    // MARK: - Private builders

    /// A palette row for a routed answer.
    ///
    /// Modelled on the `=` math row: a synthetic command carrying pre-resolved text through
    /// the existing `.insert` action, so a routed answer needs no new commit path and cannot
    /// reach anything a math result could not.
    static func routedHit(
        _ routed: PaletteToolRouter.Routed,
        loc: LocalizationManager
    ) -> PaletteCommandHit {
        let command = PaletteCommand(
            id: "routed.\(routed.query)",
            section: .commands,
            trigger: routed.query,
            titleKey: "palette.routed.title",
            subtitleKey: "palette.routed.detail",
            aliases: [],
            action: .insert,
            isEphemeral: true
        )
        return PaletteCommandHit(
            command: command,
            score: routedLeadScore,
            insertText: routed.text,
            preview: routed.text
        )
    }

    /// Above any lexical match, because a routed row is a direct answer to the phrase on
    /// screen rather than a command that resembles it.
    static let routedLeadScore = 1500

    private static func hitsForTypedQuery(
        _ typed: TypedPaletteQuery,
        loc: LocalizationManager,
        now: Date,
        locale: Locale,
        timeZone: TimeZone,
        aiDisabledReason: String?
    ) -> [PaletteCommandHit] {
        switch typed {
        case .math(let expression):
            let value = SafeMathParser.evaluate(expression)
            let result = value.map(PaletteTextOps.formatMathResult) ?? loc.s("palette.math.invalid")
            let insert = value.map(PaletteTextOps.formatMathResult) ?? ""
            let command = PaletteCommand(
                id: "math.\(expression)",
                section: .commands,
                trigger: "=\(expression)",
                titleKey: "palette.math.title",
                subtitleKey: "palette.math.detail",
                aliases: [],
                action: .insert,
                isEphemeral: true
            )
            return [PaletteCommandHit(
                command: command,
                score: 1200,
                insertText: insert,
                preview: result
            )]

        case .customAI(let instructions):
            let command = PaletteCommand(
                id: "ai.custom.oneshot",
                section: .ai,
                trigger: ">",
                titleKey: "ai.kind.custom",
                subtitleKey: "palette.ai.custom.detail",
                aliases: [],
                action: .aiCustom(instructions: instructions)
            )
            return [PaletteCommandHit(
                command: command,
                score: 1200,
                insertText: "",
                preview: instructions,
                disabledReason: aiDisabledReason
            )]

        case .relativeDays(let days, let format, let trigger):
            let tool = PaletteDateTool.offsetDays(days, format: format)
            let text = resolveDate(tool, now: now, locale: locale, timeZone: timeZone)
            let command = PaletteCommand(
                id: "date.relative.\(days).\(format)",
                section: .commands,
                trigger: trigger,
                titleKey: "palette.date.relative",
                subtitleKey: "palette.date.relative.detail",
                aliases: [],
                action: .date(tool),
                isEphemeral: true
            )
            return [PaletteCommandHit(
                command: command,
                score: 1100,
                insertText: text,
                preview: text
            )]

        case .relativeOffset(let offset, let format, let trigger):
            let tool = PaletteDateTool.offset(offset, format: format)
            let text = resolveDate(tool, now: now, locale: locale, timeZone: timeZone)
            let command = PaletteCommand(
                id: "date.offset.\(trigger)",
                section: .commands,
                trigger: trigger,
                titleKey: "palette.date.relative",
                subtitleKey: "palette.date.relative.detail",
                aliases: [],
                action: .date(tool),
                isEphemeral: true
            )
            return [PaletteCommandHit(
                command: command,
                score: 1100,
                insertText: text,
                preview: text
            )]
        }
    }

    private static func makeHit(
        _ command: PaletteCommand,
        score: Int,
        loc: LocalizationManager,
        now: Date,
        locale: Locale,
        timeZone: TimeZone,
        clipboardPreview: String?,
        aiDisabledReason: String?
    ) -> PaletteCommandHit {
        switch command.action {
        case .date(let tool):
            let text = resolveDate(tool, now: now, locale: locale, timeZone: timeZone)
            return PaletteCommandHit(command: command, score: score, insertText: text, preview: text)
        case .clipboard:
            let text = clipboardPreview ?? ""
            let preview = text.isEmpty
                ? loc.s("palette.tool.clipboard.empty")
                : text.replacingOccurrences(of: "\n", with: " ")
            let clipped = preview.count > 80 ? String(preview.prefix(77)) + "…" : preview
            return PaletteCommandHit(command: command, score: score, insertText: text, preview: clipped)
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
                : PaletteTextOps.countSummary(for: source)
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

    private static func conversationalBoost(query: String, command: PaletteCommand) -> Int {
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

    private static func tokenize(_ query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
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

    private static func parseNextWeekdayQuery(_ text: String) -> (days: Int, format: String, trigger: String)? {
        let names: [(String, Int)] = [
            ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
            ("thursday", 5), ("friday", 6), ("saturday", 7)
        ]
        for (name, weekday) in names {
            if text == "next \(name)" || text == "next \(name) date" {
                let days = daysUntilWeekday(weekday)
                return (days, "full", "next \(name)")
            }
        }
        return nil
    }

    /// Calendar weekday: 1 = Sunday … 7 = Saturday (Gregorian).
    private static func daysUntilWeekday(_ weekday: Int, from date: Date = Date()) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let current = calendar.component(.weekday, from: date)
        var delta = weekday - current
        if delta <= 0 { delta += 7 }
        return delta
    }

    private static func dateCommands() -> [PaletteCommand] {
        [
            PaletteCommand(
                id: "date.today",
                section: .commands,
                trigger: "today",
                titleKey: "palette.date.today",
                subtitleKey: "palette.date.today.detail",
                aliases: ["today", "todays date", "today's date", "current date", "date now", "date"],
                action: .date(.offsetDays(0, format: "medium"))
            ),
            PaletteCommand(
                id: "date.tomorrow",
                section: .commands,
                trigger: "date+1",
                titleKey: "palette.date.tomorrow",
                subtitleKey: "palette.date.tomorrow.detail",
                aliases: [
                    "tomorrow", "tomorrows date", "tomorrow's date", "date+1", "date +1",
                    "next day", "next full date", "full date tomorrow"
                ],
                action: .date(.offsetDays(1, format: "full"))
            ),
            PaletteCommand(
                id: "date.yesterday",
                section: .commands,
                trigger: "date-1",
                titleKey: "palette.date.yesterday",
                subtitleKey: "palette.date.yesterday.detail",
                aliases: ["yesterday", "yesterdays date", "yesterday's date", "date-1", "date -1", "previous day"],
                action: .date(.offsetDays(-1, format: "medium"))
            ),
            PaletteCommand(
                id: "date.iso",
                section: .commands,
                trigger: "iso",
                titleKey: "palette.date.iso",
                subtitleKey: "palette.date.iso.detail",
                aliases: ["iso", "iso date", "iso8601", "yyyy-mm-dd", "sortable date"],
                action: .date(.iso)
            ),
            PaletteCommand(
                id: "date.time",
                section: .commands,
                trigger: "time",
                titleKey: "palette.date.time",
                subtitleKey: "palette.date.time.detail",
                aliases: ["time", "time now", "current time", "now", "clock"],
                action: .date(.timeNow)
            ),
            PaletteCommand(
                id: "date.datetime",
                section: .commands,
                trigger: "datetime",
                titleKey: "palette.date.datetime",
                subtitleKey: "palette.date.datetime.detail",
                aliases: ["datetime", "date and time", "timestamp", "date time"],
                action: .date(.datetime)
            ),
            PaletteCommand(
                id: "date.full",
                section: .commands,
                trigger: "full",
                titleKey: "palette.date.full",
                subtitleKey: "palette.date.full.detail",
                aliases: ["full date", "long date", "weekday date", "complete date"],
                action: .date(.full)
            ),
            PaletteCommand(
                id: "date.epoch",
                section: .commands,
                trigger: "epoch",
                titleKey: "palette.date.epoch",
                subtitleKey: "palette.date.epoch.detail",
                aliases: ["epoch", "unix time", "unix timestamp", "epoch seconds"],
                action: .date(.epoch)
            )
        ]
    }

    private static func textOpCommands() -> [PaletteCommand] {
        let specs: [(PaletteTextOp, String, String, String, [String])] = [
            (.upper, "upper", "palette.tool.upper", "palette.tool.upper.detail", ["uppercase", "upper case", "caps", "all caps"]),
            (.lower, "lower", "palette.tool.lower", "palette.tool.lower.detail", ["lowercase", "lower case"]),
            (.title, "titlecase", "palette.tool.title", "palette.tool.title.detail", ["title case", "capitalize"]),
            (.sentence, "sentence", "palette.tool.sentence", "palette.tool.sentence.detail", ["sentence case"]),
            (.sortLines, "sort", "palette.tool.sort", "palette.tool.sort.detail", ["sort lines", "sort lines a-z"]),
            (.dedupeLines, "dedupe", "palette.tool.dedupe", "palette.tool.dedupe.detail", ["dedupe", "unique lines", "remove duplicates"]),
            (.trimLines, "trim", "palette.tool.trim", "palette.tool.trim.detail", ["trim", "trim lines", "strip whitespace"]),
            (.numberLines, "number", "palette.tool.number", "palette.tool.number.detail", ["number lines", "line numbers"]),
            (.base64Encode, "b64", "palette.tool.b64enc", "palette.tool.b64enc.detail", ["base64", "base64 encode"]),
            (.base64Decode, "b64d", "palette.tool.b64dec", "palette.tool.b64dec.detail", ["base64 decode"]),
            (.urlEncode, "urlenc", "palette.tool.urlenc", "palette.tool.urlenc.detail", ["url encode", "percent encode"]),
            (.urlDecode, "urldec", "palette.tool.urldec", "palette.tool.urldec.detail", ["url decode"]),
            (.htmlEscape, "htmlenc", "palette.tool.htmlenc", "palette.tool.htmlenc.detail", ["html escape", "html encode"]),
            (.htmlUnescape, "htmldec", "palette.tool.htmldec", "palette.tool.htmldec.detail", ["html unescape", "html decode"]),
            (.jsonPretty, "json", "palette.tool.jsonpretty", "palette.tool.jsonpretty.detail", ["json pretty", "pretty json", "format json"]),
            (.jsonCompact, "jsonc", "palette.tool.jsoncompact", "palette.tool.jsoncompact.detail", ["json compact", "minify json"]),
            (.sha256, "sha256", "palette.tool.sha256", "palette.tool.sha256.detail", ["sha256", "hash", "sha-256"]),
            (.md5, "md5", "palette.tool.md5", "palette.tool.md5.detail", ["md5", "md5 hash"])
        ]
        return specs.map { op, trigger, title, detail, aliases in
            PaletteCommand(
                id: "tool.\(op.rawValue)",
                section: .commands,
                trigger: trigger,
                titleKey: title,
                subtitleKey: detail,
                aliases: [trigger] + aliases,
                action: .textOp(op)
            )
        }
    }

    private static func generateCommands() -> [PaletteCommand] {
        [
            PaletteCommand(
                id: "tool.uuid",
                section: .commands,
                trigger: "uuid",
                titleKey: "palette.tool.uuid",
                subtitleKey: "palette.tool.uuid.detail",
                aliases: ["uuid", "guid", "generate uuid"],
                action: .generate(.uuid)
            ),
            PaletteCommand(
                id: "tool.lorem",
                section: .commands,
                trigger: "lorem",
                titleKey: "palette.tool.lorem",
                subtitleKey: "palette.tool.lorem.detail",
                aliases: ["lorem", "lorem ipsum", "placeholder text"],
                action: .generate(.lorem)
            ),
            PaletteCommand(
                id: "tool.password",
                section: .commands,
                trigger: "password",
                titleKey: "palette.tool.password",
                subtitleKey: "palette.tool.password.detail",
                aliases: ["password", "random password", "generate password"],
                action: .generate(.password)
            )
        ]
    }

    private static func aiAliases(for kind: AITransformKind) -> [String] {
        switch kind {
        case .proofread:
            // No Telugu / Hindi aliases: the on-device model cannot proofread either
            // language — it answers in native script or trips Apple's guardrail — and
            // an alias for something that only ever errors is worse than no alias.
            // Translation between them still works; those rows own it.
            return [
                "proofread", "proof read", "proof-read", "fix spelling", "fix grammar",
                "grammar", "spelling", "correct", "typo", "typos"
            ]
        case .rewrite:
            return ["rewrite", "re-write", "rephrase", "clarify", "make clearer", "improve writing"]
        case .paraphrase:
            return ["paraphrase", "reword", "say differently", "other words"]
        case .expand:
            return ["expand", "elaborate", "longer", "add detail", "flesh out"]
        case .condense:
            return ["condense", "shorten", "summarize", "summary", "tighter", "brief"]
        case .formal:
            return [
                "formal", "make formal", "make this formal", "professional",
                "make professional", "business tone"
            ]
        case .friendly:
            return [
                "friendly", "make friendly", "make this friendly", "casual",
                "warm", "approachable"
            ]
        case .bulletize:
            return ["bulletize", "bullets", "bullet list", "make a list", "to bullets", "bullet points"]
        case .promptEnhance:
            return [
                "prompt enhance", "enhance prompt", "improve prompt", "better prompt",
                "promptenhance", "prompt"
            ]
        case .explainCode:
            return [
                "explain code", "code explanation", "what does this code do", "understand code",
                "code walkthrough", "explain function"
            ]
        case .generateDocstring:
            return [
                "docstring", "generate docstring", "document code", "documentation",
                "add comments", "swift doc", "jsdoc", "doc comments"
            ]
        case .fixCode:
            return [
                "fix code", "fix bugs", "debug", "debug code", "find bug", "correct code",
                "fix syntax error", "refactor code"
            ]
        case .toJson:
            return [
                "to json", "convert to json", "parse json", "make json", "format json",
                "json object", "json string"
            ]
        case .generateUnitTests:
            return [
                "unit tests", "write unit tests", "generate tests", "test cases", "create tests",
                "xctest", "jest", "pytest"
            ]
        case .gitCommitMessage:
            return [
                "git commit", "commit message", "generate commit", "git message", "commit note",
                "conventional commit"
            ]
        case .explainRegex:
            return [
                "explain regex", "regular expression", "regex explanation", "what does this regex do",
                "regex breakdown", "pattern explanation"
            ]
        case .sqlQuery:
            return [
                "sql query", "generate sql", "write sql", "database query", "select query",
                "postgres", "mysql", "sql schema"
            ]
        case .translate:
            return [
                "translate", "translation", "translate to english", "to english",
                "english", "telugu", "hindi", "telugu to english", "hindi to english",
                "tenglish", "hinglish", "romanized telugu", "romanized hindi",
                "convert to english", "meaning in english", "what does this mean"
            ]
        case .translateTelugu:
            return [
                "telugu", "to telugu", "in telugu", "english to telugu",
                "translate to telugu", "say in telugu", "tenglish", "romanized telugu"
            ]
        case .translateHindi:
            return [
                "hindi", "to hindi", "in hindi", "english to hindi",
                "translate to hindi", "say in hindi", "hinglish", "romanized hindi"
            ]
        case .toMarkdown:
            return [
                "to markdown", "format as markdown", "convert to markdown", "make markdown",
                "markdownify", "markdown", "md", "add formatting", "format text",
                "markdown format", "md format", "structure as markdown", "prettify",
                "add headings", "add bullets"
            ]
        case .removeMarkdown:
            return [
                "remove markdown", "markdown removal", "strip markdown", "markdown",
                "md", "unmarkdown", "plain text", "to plain text", "plaintext",
                "remove formatting", "strip formatting", "remove bold", "remove asterisks",
                "clean markdown", "demarkdown", "unformat"
            ]
        case .custom:
            return ["custom"]
        }
    }
}

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
        let effective = content.isEmpty ? tokens : content
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

private extension DateOffset {
    /// True when only the `days` component is non-zero (used for palette `+1d` queries).
    var isDayOnly: Bool {
        days != 0
            && years == 0 && months == 0 && weeks == 0
            && hours == 0 && minutes == 0 && seconds == 0
    }
}
