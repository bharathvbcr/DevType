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
                aliases: ["new", "new snippet", "create snippet", "add snippet", "make snippet"],
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

    // MARK: - Context

    /// What the palette knows about the caller's situation at the moment it opens.
    ///
    /// The empty palette used to show one hardcoded list regardless. For the most common
    /// reason to open it — select some text, then rewrite it — that list led with date
    /// insertion and put every transform below the navigation rows, so nothing above the fold
    /// was the thing the user came for.
    public enum PaletteContext: String, Equatable, Sendable {
        /// Text is selected in the frontmost app, so a transform is the likely next step.
        case selection
        /// Nothing is selected. Inserting something is the likely next step.
        case none
    }

    /// Empty-palette suggestions when text is selected: transforms first, in rough order of
    /// how often a selection is handed to them, and no navigation at all — nobody selects a
    /// paragraph in order to open Preferences.
    public static let selectionSuggestionIDs = [
        "ai.proofread", "ai.rewrite", "ai.condense", "ai.mergerewrite",
        "ai.formal", "ai.friendly", "ai.expand", "ai.bulletize", "ai.paraphrase",
        "ai.translate", "ai.totelugu", "ai.tohindi",
        "tool.upper", "tool.lower", "tool.count"
    ]

    /// Empty-palette suggestions when nothing is selected. Inserting a date or the clipboard
    /// is the likely next step, and the navigation rows are worth surfacing because there is
    /// no transform to compete with them.
    public static let idleSuggestionIDs = [
        "date.today", "date.tomorrow", "date.time", "tool.clipboard",
        "ai.proofread", "ai.translate", "ai.totelugu", "ai.tohindi",
        "ai.formal", "ai.promptenhance",
        "nav.preferences", "nav.snippets", "tool.upper", "tool.uuid"
    ]

    /// Registering a command is not the same as making it discoverable: anything missing from
    /// the list for a context stays invisible in it until the user already knows its name.
    public static func suggestionIDs(
        for context: PaletteContext,
        aiEnabled: Bool
    ) -> [String] {
        switch context {
        case .none:
            return idleSuggestionIDs
        case .selection:
            // With AI unavailable the transform rows would lead as greyed-out rows the user
            // cannot pick, which is worse than not promoting them. Local text ops still work
            // on a selection, so they keep the lead and the idle list fills in behind.
            guard aiEnabled else {
                let local = selectionSuggestionIDs.filter { !$0.hasPrefix("ai.") }
                return local + idleSuggestionIDs
            }
            return selectionSuggestionIDs + idleSuggestionIDs
        }
    }

    /// Context nudge, applied wherever commands are ranked.
    ///
    /// Small on purpose: at ±25 against lexical scores near 1000 it settles ties and reorders
    /// the empty palette, and cannot override what the user actually typed. Typing "pref" with
    /// a paragraph selected still finds Preferences.
    public static func contextBoost(
        for command: PaletteCommand,
        context: PaletteContext,
        aiEnabled: Bool
    ) -> Int {
        guard context == .selection else { return 0 }
        switch command.action {
        case .ai, .aiCustom:
            return aiEnabled ? 25 : 0
        case .textOp, .count:
            return 15
        case .navigate:
            // A selection is live and perishable: navigating away abandons it.
            return -25
        default:
            return 0
        }
    }

    // MARK: - Input bounds

    /// Longest query the ranking paths will consider.
    ///
    /// A palette query is something a person types; past this it is a paste. The cap bounds
    /// three separate unbounded costs at once: tokenization, the per-term scan across the
    /// catalogue, and the query string retained as a cache key.
    public static let maximumQueryCharacters = 512

    /// Most terms any one query contributes to ranking.
    ///
    /// Coverage scoring removed the old conjunctive early exit — the previous scorer returned
    /// on the first unmatched term, so a junk paste cost one comparison per command, while the
    /// replacement scores every term against every command to learn which terms the catalogue
    /// understands. Measured, that turned a 5,000-word paste into a 3-second synchronous
    /// freeze on the keystroke path. Bounding the term count restores a fixed ceiling without
    /// giving up the coverage rule: nobody narrows a palette with a thirteenth word.
    public static let maximumQueryTerms = 12

    /// Validate the complete input before ranking/cache normalization can drop a filter.
    public static func queryIssue(for query: String) -> SnippetSearch.QueryIssue? {
        if query.utf8.prefix(SnippetSearch.maximumQueryUTF8Bytes + 1).count > SnippetSearch.maximumQueryUTF8Bytes {
            return .tooLong
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.prefix(maximumQueryCharacters + 1).count > maximumQueryCharacters { return .tooLong }
        // Explicit command mode does not interpret snippet filters.
        return trimmed.hasPrefix(">") ? nil : SnippetSearch.queryIssue(for: query)
    }

    /// Clamps a raw query to the bounds above. Applied at every ranking entry point.
    public static func boundedQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumQueryCharacters else { return trimmed }
        return String(trimmed.prefix(maximumQueryCharacters))
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
}
