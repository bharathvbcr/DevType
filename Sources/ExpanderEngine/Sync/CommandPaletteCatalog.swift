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

    public init(
        id: String,
        section: PaletteSection,
        trigger: String,
        titleKey: String,
        subtitleKey: String,
        aliases: [String],
        action: PaletteCommandAction,
        searchBlob: String? = nil
    ) {
        self.id = id
        self.section = section
        self.trigger = trigger
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
        let loweredAliases = aliases.map { $0.lowercased() }
        self.aliases = loweredAliases
        self.action = action
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
                subtitleKey: "palette.ai.subtitle",
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
            let instructions = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instructions.isEmpty else { return nil }
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
        let patterns: [NSRegularExpression] = [
            try! NSRegularExpression(pattern: #"^date\s*([+-])\s*(\d{1,3})\s*d?$"#),
            try! NSRegularExpression(pattern: #"^([+-])\s*(\d{1,3})\s*d$"#)
        ]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in patterns {
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
            let recent = CommandUsageStatsStore.shared.recentCommandIDs(limit: 10)
            var suggestedIDs: [String] = recent
            let fallback = [
                "date.today", "date.tomorrow", "date.time", "tool.clipboard",
                "ai.proofread", "ai.formal", "ai.promptenhance",
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
                var score = 20 - index
                if let boost = commandUsageBoost?(command.id) {
                    score += boost
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
            return Array(hits.prefix(limit))
        }

        let terms = tokenize(trimmed)
        guard !terms.isEmpty else { return Array(hits.prefix(limit)) }

        let boostIndex = Dictionary(
            uniqueKeysWithValues: semanticBoostIDs.enumerated().map { ($0.element, 80 - $0.offset * 5) }
        )

        for command in commands {
            if case .undoAI = command.action, !AIUndoStore.hasUndo { continue }
            guard let score = score(command: command, terms: terms, loc: loc) else { continue }
            var adjusted = score
            if let boost = boostIndex[command.id] {
                adjusted += max(0, boost)
            }
            if let usage = commandUsageBoost?(command.id) {
                adjusted += usage
            }
            adjusted += conversationalBoost(query: trimmed, command: command)
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
        snippetLimit: Int = 40
    ) -> [PaletteListRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandHits = matchCommands(
            query: trimmed,
            loc: loc,
            clipboardPreview: clipboardPreview,
            semanticBoostIDs: semanticBoostIDs,
            commandUsageBoost: commandUsageBoost,
            aiDisabledReason: aiDisabledReason,
            limit: commandLimit
        )

        let snippetHits: [SearchHit]
        if trimmed.isEmpty {
            snippetHits = groups
                .filter(\.enabled)
                .flatMap { group in
                    group.snippets
                        .filter { $0.enabled && !$0.triggerKeyword.isEmpty }
                        .map { SearchHit(snippet: $0, groupID: group.id, groupName: group.name, score: 0) }
                }
                .sorted { $0.snippet.updatedAt > $1.snippet.updatedAt }
                .prefix(snippetLimit)
                .map { $0 }
        } else {
            snippetHits = SnippetSearch.run(
                query: trimmed,
                in: groups,
                includeDisabled: false,
                limit: snippetLimit,
                boost: usageBoost
            )
        }

        var rows: [PaletteListRow] = []

        let commandSection = commandHits.filter { $0.command.section == .commands }
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

    /// Token score for one command, or `nil` when no term matches.
    public static func score(
        command: PaletteCommand,
        terms: [String],
        loc: LocalizationManager = .shared
    ) -> Int? {
        guard !terms.isEmpty else { return nil }
        let title = loc.s(command.titleKey).lowercased()
        let subtitle = loc.s(command.subtitleKey).lowercased()
        let trigger = command.trigger.lowercased()
        let aliasBlob = command.aliases.joined(separator: "\n")
        let blob = command.searchBlob

        var total = 0
        for term in terms {
            guard let best = bestTermScore(
                term: term,
                trigger: trigger,
                title: title,
                subtitle: subtitle,
                aliases: command.aliases,
                aliasBlob: aliasBlob,
                searchBlob: blob
            ) else { return nil }
            total += best
        }
        return total / terms.count
    }

    /// Offline NLEmbedding semantic boost IDs (Stage 1). Returns empty on OOV / failure.
    public static func semanticBoostIDs(
        for query: String,
        limit: Int = 8
    ) -> [String] {
        PaletteSemanticIndex.boostIDs(for: query, commands: commands, limit: limit)
    }

    // MARK: - Private builders

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
                action: .insert
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
                action: .date(tool)
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
                action: .date(tool)
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
        case .ai, .aiCustom:
            return PaletteCommandHit(
                command: command,
                score: score,
                insertText: "",
                preview: loc.s(command.subtitleKey),
                disabledReason: aiDisabledReason
            )
        case .textOp, .navigate:
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
        case .proofread where q.contains("proof") || q.contains("grammar") || q.contains("spelling"):
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
        case .translate where q.contains("translat") || q.contains("english")
            || q.contains("meaning"):
            boost += 60
        // "fix telugu" / "telugu grammar" wants refine, not translate; a bare
        // language name is ambiguous, so both rows get the lift and the alias
        // scores decide the order.
        case .translate where q.contains("telugu") || q.contains("hindi"):
            boost += 40
        case .refine where q.contains("grammar") || q.contains("correct")
            || q.contains("fix") || q.contains("refine") || q.contains("polish"):
            boost += 50
        case .refine where q.contains("telugu") || q.contains("hindi"):
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
        case .translate:
            return [
                "translate", "translation", "translate to english", "to english",
                "english", "telugu", "hindi", "telugu to english", "hindi to english",
                "tenglish", "hinglish", "romanized telugu", "romanized hindi",
                "convert to english", "meaning in english", "what does this mean"
            ]
        case .refine:
            return [
                "refine", "polish", "fix telugu", "fix hindi", "correct telugu",
                "correct hindi", "telugu grammar", "hindi grammar", "grammar telugu",
                "grammar hindi", "proofread telugu", "proofread hindi",
                "fix tenglish", "fix hinglish", "keep language", "same language"
            ]
        case .custom:
            return ["custom"]
        }
    }
}

// MARK: - Semantic index (C4 Stage 1)

enum PaletteSemanticIndex {
    private static let lock = NSLock()
    private static var cachedVectors: [String: [Double]]?

    static func boostIDs(for query: String, commands: [PaletteCommand], limit: Int) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        guard let queryVector = averageEmbedding(for: trimmed) else { return [] }

        ensureCommandVectors(commands)
        lock.lock()
        let vectors = cachedVectors ?? [:]
        lock.unlock()

        var scored: [(String, Double)] = []
        for command in commands {
            guard let vector = vectors[command.id] else { continue }
            let sim = cosineSimilarity(queryVector, vector)
            if sim > 0.35 {
                scored.append((command.id, sim))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map(\.0)
    }

    private static func ensureCommandVectors(_ commands: [PaletteCommand]) {
        lock.lock()
        if cachedVectors != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        var map: [String: [Double]] = [:]
        for command in commands {
            let blob = ([command.trigger] + command.aliases).joined(separator: " ")
            if let vector = averageEmbedding(for: blob) {
                map[command.id] = vector
            }
        }
        lock.lock()
        cachedVectors = map
        lock.unlock()
    }

    private static func averageEmbedding(for text: String) -> [Double]? {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return nil }
        let tokens = text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var sum: [Double] = []
        var count = 0
        for token in tokens {
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
