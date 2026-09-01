import Foundation

/// A named date/time output format usable from `%date:NAME%` and `{{date:NAME}}`.
///
/// Presets give users friendly, discoverable formats (US, full date, ISO, …)
/// without memorizing `DateFormatter` patterns. Any spec that does not match a
/// preset name is treated as a raw Unicode date-format pattern (backwards
/// compatible with the previous behavior).
public struct DatePreset: Equatable, Identifiable {
    public enum Style: Equatable {
        /// Fixed `DateFormatter.dateFormat` pattern (locale-independent shape).
        case pattern(String)
        /// Localized `DateFormatter` styles.
        case styles(date: DateFormatter.Style, time: DateFormatter.Style)
    }

    /// Preset name typed by the user, e.g. "us" in `%date:us%`.
    public let id: String
    /// Short human-readable title for menus ("US", "Full", …).
    public let title: String
    public let style: Style

    public init(id: String, title: String, style: Style) {
        self.id = id
        self.title = title
        self.style = style
    }
}

/// §3.5: A relative date offset parsed out of a date macro spec.
///
/// Grammar: one or more `[+-]<digits><unit>` groups, e.g. `+1d`, `-2w`, `+1y-3M`, `+1D`
/// (TextExpander writes the unit uppercase). Units:
///
/// | unit | meaning |
/// |---|---|
/// | `y` / `Y` | years |
/// | `M`       | months (**case sensitive** — uppercase) |
/// | `w` / `W` | weeks |
/// | `d` / `D` | days |
/// | `h` / `H` | hours |
/// | `m`       | minutes (**case sensitive** — lowercase) |
/// | `s` / `S` | seconds |
///
/// Arithmetic is always performed through `Calendar.date(byAdding:)`, never by adding a raw
/// `TimeInterval`, so DST transitions and variable month lengths behave the way users expect.
public struct DateOffset: Equatable, Sendable {
    public var years: Int
    public var months: Int
    public var weeks: Int
    public var days: Int
    public var hours: Int
    public var minutes: Int
    public var seconds: Int

    public init(
        years: Int = 0,
        months: Int = 0,
        weeks: Int = 0,
        days: Int = 0,
        hours: Int = 0,
        minutes: Int = 0,
        seconds: Int = 0
    ) {
        self.years = years
        self.months = months
        self.weeks = weeks
        self.days = days
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
    }

    public var isZero: Bool {
        years == 0 && months == 0 && weeks == 0 && days == 0
            && hours == 0 && minutes == 0 && seconds == 0
    }

    public var dateComponents: DateComponents {
        var components = DateComponents()
        components.year = years
        components.month = months
        components.weekOfYear = weeks
        components.day = days
        components.hour = hours
        components.minute = minutes
        components.second = seconds
        return components
    }

    /// Parses `+1d`, `-2w`, `+1y-3M`, `+1D`, … Returns `nil` for anything that is not a
    /// well-formed offset (so a raw `DateFormatter` pattern is never mistaken for one).
    public static func parse(_ raw: String) -> DateOffset? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var offset = DateOffset()
        var index = text.startIndex
        var matchedAny = false

        while index < text.endIndex {
            let sign = text[index]
            guard sign == "+" || sign == "-" else { return nil }
            let negative = (sign == "-")
            index = text.index(after: index)

            var digits = ""
            while index < text.endIndex, text[index].isNumber, text[index].isASCII {
                digits.append(text[index])
                index = text.index(after: index)
            }
            guard !digits.isEmpty, digits.count <= 6, let magnitude = Int(digits) else { return nil }
            guard index < text.endIndex else { return nil }

            let unit = text[index]
            index = text.index(after: index)
            let value = negative ? -magnitude : magnitude

            switch unit {
            case "y", "Y": offset.years += value
            case "M": offset.months += value
            case "w", "W": offset.weeks += value
            case "d", "D": offset.days += value
            case "h", "H": offset.hours += value
            case "m": offset.minutes += value
            case "s", "S": offset.seconds += value
            default: return nil
            }
            matchedAny = true
        }

        return matchedAny ? offset : nil
    }

    /// Applies the offset with calendar arithmetic. Falls back to the input date if the
    /// calendar cannot represent the result.
    public func apply(to date: Date, calendar: Calendar) -> Date {
        guard !isZero else { return date }
        return calendar.date(byAdding: dateComponents, to: date) ?? date
    }
}

public enum DateFormatLibrary {

    /// Menu / picker ordering. `id` is what appears in snippet macros.
    public static let presets: [DatePreset] = [
        DatePreset(id: "us",        title: "US",            style: .pattern("MM/dd/yyyy")),
        DatePreset(id: "uslong",    title: "US Long",       style: .pattern("MMMM d, yyyy")),
        DatePreset(id: "iso",       title: "ISO",           style: .pattern("yyyy-MM-dd")),
        DatePreset(id: "eu",        title: "EU",            style: .pattern("dd/MM/yyyy")),
        DatePreset(id: "full",      title: "Full",          style: .styles(date: .full, time: .none)),
        DatePreset(id: "long",      title: "Long",          style: .styles(date: .long, time: .none)),
        DatePreset(id: "medium",    title: "Medium",        style: .styles(date: .medium, time: .none)),
        DatePreset(id: "short",     title: "Short",         style: .styles(date: .short, time: .none)),
        DatePreset(id: "datetime",  title: "Date & Time",   style: .styles(date: .medium, time: .short)),
        DatePreset(id: "time",      title: "Time",          style: .styles(date: .none, time: .medium)),
        DatePreset(id: "timeshort", title: "Time Short",    style: .styles(date: .none, time: .short)),
        DatePreset(id: "time24",    title: "Time (24h)",    style: .pattern("HH:mm")),
        DatePreset(id: "weekday",   title: "Weekday",       style: .pattern("EEEE")),
        DatePreset(id: "monthyear", title: "Month & Year",  style: .pattern("MMMM yyyy")),
        DatePreset(id: "day",       title: "Day",           style: .pattern("dd")),
        DatePreset(id: "year",      title: "Year",          style: .pattern("yyyy")),
    ]

    /// §2.9: built **once**. This used to be a computed property, so the 16-entry dictionary
    /// was rebuilt on every `format()` call — i.e. on every date macro of every expansion.
    private static let presetsByID: [String: DatePreset] =
        Dictionary(presets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// Preset used when a date macro carries only an offset (`{{date:+1d}}`, `%@+1D%`).
    private static let bareOffsetPresetID = "medium"

    public static func preset(named name: String) -> DatePreset? {
        presetsByID[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    // MARK: - Formatter cache (§2.9)

    /// §2.9: `DateFormatter` allocation costs ~1 ms. The cache is keyed by
    /// `(shape, locale, time zone)` — **locale is part of the key**, which is what makes a
    /// region change safe: a new locale simply produces new keys instead of silently reusing a
    /// formatter that was pinned to `Locale.current` at first use.
    private static let formatterLock = UnfairLock()
    private static var formatterCache: [String: DateFormatter] = [:]
    /// Bounded so a template full of one-off `DateFormatter` patterns cannot grow without limit.
    private static let formatterCacheLimit = 64

    private static let keySeparator = "\u{1}"

    /// Cached formatter for a raw `DateFormatter` pattern.
    public static func formatter(pattern: String, locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let key = ["p", pattern, locale.identifier, timeZone.identifier].joined(separator: keySeparator)
        return cachedFormatter(key: key) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            return formatter
        }
    }

    /// Cached formatter for localized date/time styles.
    public static func formatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        locale: Locale,
        timeZone: TimeZone
    ) -> DateFormatter {
        let key = ["s", "\(dateStyle.rawValue)", "\(timeStyle.rawValue)", locale.identifier, timeZone.identifier]
            .joined(separator: keySeparator)
        return cachedFormatter(key: key) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
            return formatter
        }
    }

    /// `DateFormatter` is documented as safe for concurrent *formatting* once configured; the
    /// lock only guards configuration + dictionary mutation.
    private static func cachedFormatter(key: String, make: () -> DateFormatter) -> DateFormatter {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let existing = formatterCache[key] { return existing }
        if formatterCache.count >= formatterCacheLimit {
            formatterCache.removeAll(keepingCapacity: true)
        }
        let formatter = make()
        formatterCache[key] = formatter
        return formatter
    }

    // MARK: - Spec parsing (§3.5)

    /// Arithmetic calendar for date offsets. Gregorian so `+1M` means "next month" regardless
    /// of the user's preferred calendar display, with the caller's locale/zone attached so DST
    /// boundaries resolve correctly.
    public static func arithmeticCalendar(locale: Locale, timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }

    /// §3.5: splits a date macro spec into its format part and an optional trailing offset.
    ///
    ///     "iso:+1d"     -> ("iso", +1 day)
    ///     "+1d"         -> ("",    +1 day)
    ///     "HH:mm"       -> ("HH:mm", nil)   // "mm" is not offset syntax
    ///     "yyyy-MM-dd"  -> ("yyyy-MM-dd", nil)
    ///
    /// Only the segment after the **last** colon is considered, and only when it parses as a
    /// complete offset — so existing patterns containing colons are untouched.
    public static func splitSpec(_ spec: String) -> (format: String, offset: DateOffset?) {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (spec, nil) }
        if let whole = DateOffset.parse(trimmed) { return ("", whole) }
        guard let colon = trimmed.lastIndex(of: ":") else { return (spec, nil) }
        let tail = String(trimmed[trimmed.index(after: colon)...])
        guard let offset = DateOffset.parse(tail) else { return (spec, nil) }
        return (String(trimmed[..<colon]), offset)
    }

    // MARK: - Formatting

    /// Formats `now` according to `spec`: a preset name (case-insensitive), a raw
    /// `DateFormatter` pattern, or either of those followed by a `:+1d`-style offset (§3.5).
    /// Locale/time zone injectable for tests.
    public static func format(
        _ spec: String,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let (rawFormat, offset) = splitSpec(spec)
        let date: Date
        if let offset {
            date = offset.apply(to: now, calendar: arithmeticCalendar(locale: locale, timeZone: timeZone))
        } else {
            date = now
        }

        // Offset-only spec (`{{date:+1d}}`) — fall back to the localized medium date, which is
        // what a bare `{{date}}` produces.
        if rawFormat.isEmpty, offset != nil, let preset = presetsByID[bareOffsetPresetID] {
            return format(preset: preset, now: date, locale: locale, timeZone: timeZone)
        }

        let key = rawFormat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let preset = presetsByID[key] {
            return format(preset: preset, now: date, locale: locale, timeZone: timeZone)
        }
        // Unknown spec (including the empty string) stays a raw pattern — historical behavior.
        return formatter(pattern: rawFormat, locale: locale, timeZone: timeZone).string(from: date)
    }

    public static func format(
        preset: DatePreset,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        switch preset.style {
        case .pattern(let pattern):
            return formatter(pattern: pattern, locale: locale, timeZone: timeZone).string(from: now)
        case .styles(let dateStyle, let timeStyle):
            return formatter(dateStyle: dateStyle, timeStyle: timeStyle, locale: locale, timeZone: timeZone)
                .string(from: now)
        }
    }

    /// Live example shown next to preset names in menus.
    public static func example(
        for preset: DatePreset,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        format(preset: preset, now: now, locale: locale, timeZone: timeZone)
    }
}
