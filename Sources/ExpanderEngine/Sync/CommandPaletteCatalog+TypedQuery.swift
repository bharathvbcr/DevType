import Foundation
import NaturalLanguage

extension CommandPaletteCatalog {

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
        // Months, years, hours and the rest. Day and week phrases already returned above,
        // on the same path as `+3w`, so this branch cannot disagree with it.
        if let natural = naturalDateOffset(in: lower), !natural.isZero {
            return .relativeOffset(natural, format: "medium", trigger: lower)
        }
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

        // "in 3 weeks" / "3 days from now" / "in a week" — the same day count as +3w / +3d / +1w.
        if let natural = naturalDateOffset(in: text), !natural.isZero {
            if natural.isDayOnly {
                return (natural.days, "medium", text, true)
            }
            if natural.years == 0, natural.months == 0, natural.hours == 0,
               natural.minutes == 0, natural.seconds == 0,
               natural.weeks != 0, natural.days == 0 {
                return (natural.weeks * 7, "medium", text, true)
            }
        }

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
            subtitleKey: routedSubtitleKey(routed.lappiNote),
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

    /// The routed row's subtitle. A Lappi note only changes this annotation (contract §3:
    /// annotate, never insert or run); the row's text and its insert action are untouched.
    static func routedSubtitleKey(_ note: PaletteToolRouter.LappiNote?) -> String {
        switch note {
        case .none: return "palette.routed.detail"
        case .agrees?: return "palette.routed.detail.lappiAgrees"
        case .differs?: return "palette.routed.detail.lappiDiffers"
        }
    }

    /// Above any lexical match, because a routed row is a direct answer to the phrase on
    /// screen rather than a command that resembles it.
    static let routedLeadScore = 1500

    static func hitsForTypedQuery(
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

    /// Preview window only. Folding newlines on the whole clipboard, then taking 80 characters,
    /// scans a megabyte paste on every palette keystroke. Newline and space are both one
    /// character, so the first 80 of the folded string are the first 80 of this window.
    /// `insertText` stays the full clipboard string.
    static func clippedClipboardPreview(_ text: String) -> String {
        let head = text.prefix(81)
        let folded = String(head).replacingOccurrences(of: "\n", with: " ")
        if head.count > 80 {
            return String(folded.prefix(77)) + "…"
        }
        return folded
    }

    /// Natural offsets the `+3w` grammar does not spell: "in 3 weeks", "3 weeks from now",
    /// "in a day", "next month". `nil` for weekday phrases such as "next friday", which
    /// `parseNextWeekdayQuery` owns. The unit `M` stays a month here; the `+3w` parser
    /// lowercases its input, and a lowercased `m` is a minute.
    static func naturalDateOffset(in raw: String) -> DateOffset? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let fromNow = text.range(of: " from now"), fromNow.upperBound == text.endIndex {
            text = String(text[..<fromNow.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("in ") {
            text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 2 else { return nil }
        let magnitude: Int
        let unit: String
        if parts[0] == "next" {
            magnitude = 1
            unit = parts[1]
        } else if parts[0] == "a" || parts[0] == "an" {
            magnitude = 1
            unit = parts[1]
        } else if let value = Int(parts[0]), (1...999).contains(value),
                  parts[0].count <= 3, parts[0].allSatisfy(\.isNumber) {
            magnitude = value
            unit = parts[1]
        } else {
            return nil
        }
        switch unit {
        case "day", "days": return DateOffset(days: magnitude)
        case "week", "weeks": return DateOffset(weeks: magnitude)
        case "month", "months": return DateOffset(months: magnitude)
        case "year", "years": return DateOffset(years: magnitude)
        case "hour", "hours": return DateOffset(hours: magnitude)
        case "minute", "minutes": return DateOffset(minutes: magnitude)
        case "second", "seconds": return DateOffset(seconds: magnitude)
        default: return nil
        }
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
}

private extension DateOffset {
    /// True when only the `days` component is non-zero (used for palette `+1d` queries).
    var isDayOnly: Bool {
        days != 0
            && years == 0 && months == 0 && weeks == 0
            && hours == 0 && minutes == 0 && seconds == 0
    }
}
