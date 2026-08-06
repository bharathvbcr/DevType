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

    private static var presetsByID: [String: DatePreset] {
        Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
    }

    public static func preset(named name: String) -> DatePreset? {
        presetsByID[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// Formats `now` according to `spec`: a preset name (case-insensitive) or a
    /// raw `DateFormatter` pattern. Locale/time zone injectable for tests.
    public static func format(
        _ spec: String,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let key = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let preset = presetsByID[key] {
            return format(preset: preset, now: now, locale: locale, timeZone: timeZone)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = spec
        return formatter.string(from: now)
    }

    public static func format(
        preset: DatePreset,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        switch preset.style {
        case .pattern(let pattern):
            formatter.dateFormat = pattern
        case .styles(let dateStyle, let timeStyle):
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
        }
        return formatter.string(from: now)
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
