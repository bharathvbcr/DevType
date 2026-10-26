import Foundation

public struct LogLine: Equatable, Sendable {
    public let timestamp: Date
    public let text: String
}

public enum InjectOutcome: Equatable, Sendable, CustomStringConvertible {
    case succeeded
    case postedUnverified
    case refused(reason: String)
    case degradedAXOnly
    case failedSilent

    public var description: String {
        switch self {
        case .succeeded: return "succeeded"
        case .postedUnverified: return "postedUnverified"
        case .refused(let r): return "refused (\(r))"
        case .degradedAXOnly: return "degradedAXOnly"
        case .failedSilent: return "failedSilent"
        }
    }
}

public enum LogMarker: String, Equatable, Sendable, CaseIterable {
    case sourceFocus = "SourceFocus"
    case settleTrail = "settle"
    case debounce = "Debounce"
    case injectOutcome = "Inject outcome"
    case inject = "Inject"
    case clipboard = "Clipboard"
    case secureInput = "SecureInput"
    case ai = "AI"
}

/// Parses `/usr/bin/log show` default-style output. Only the five `[Inject] outcome=` variants in
/// `PermissionCoordinator.swift` are recognised; any other `outcome=` text is left as a plain
/// inject line rather than guessed at.
public enum LogParser {
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    public static func parse(_ output: String) -> [LogLine] {
        var lines: [LogLine] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard raw.count > 31, let date = timestampFormatter.date(from: String(raw.prefix(31))) else { continue }
            lines.append(LogLine(timestamp: date, text: String(raw)))
        }
        return lines
    }

    public static func classify(_ text: String) -> LogMarker? {
        if text.contains("[Inject] outcome=") { return .injectOutcome }
        if text.contains("[SourceFocus]") { return .sourceFocus }
        if text.contains("[Debounce]") { return .debounce }
        if text.contains("re-reading after settle") || text.contains("after settle delay") || text.contains("settle retry") {
            return .settleTrail
        }
        if text.contains("[Inject]") { return .inject }
        if text.contains("[Clipboard]") { return .clipboard }
        if text.contains("[SecureInput]") { return .secureInput }
        if text.contains("[AI]") || text.contains("[Selection]") { return .ai }
        return nil
    }

    public static func injectOutcome(in text: String) -> InjectOutcome? {
        guard let range = text.range(of: "[Inject] outcome=") else { return nil }
        let rest = text[range.upperBound...]
        if rest.hasPrefix("succeeded") { return .succeeded }
        if rest.hasPrefix("postedUnverified") { return .postedUnverified }
        if rest.hasPrefix("degradedAXOnly") { return .degradedAXOnly }
        if rest.hasPrefix("failedSilent") { return .failedSilent }
        if rest.hasPrefix("refused") {
            let reason = rest.dropFirst("refused".count).trimmingCharacters(in: .whitespaces)
            return .refused(reason: reason.hasPrefix("reason=") ? String(reason.dropFirst("reason=".count)) : reason)
        }
        return nil
    }

    /// The ratio in `[Debounce] event timestamp units ratio=1.0000 (...)`.
    public static func timestampUnitsRatio(in text: String) -> Double? {
        guard text.contains("[Debounce] event timestamp units"),
              let range = text.range(of: "ratio=") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }

    /// Lines worth keeping, inside `[from, to]`, capped. The cap is reported, never hidden.
    public static func excerpt(_ lines: [LogLine], from: Date, to: Date, cap: Int) -> (kept: [LogLine], dropped: Int) {
        let relevant = lines.filter { $0.timestamp >= from && $0.timestamp <= to && classify($0.text) != nil }
        guard relevant.count > cap else { return (relevant, 0) }
        return (Array(relevant.prefix(cap)), relevant.count - cap)
    }
}

/// What the `[Debounce] event timestamp units` line proved about CGEvent timestamps.
public enum TimestampUnitsVerdict: Equatable, Sendable {
    case nanoseconds(ratio: Double)
    case other(ratio: Double)
    /// DevType logs the line once per process launch, at its first key event. Not finding it is not
    /// a pass: the log store may have rotated it away, or DevType saw no key event since launch.
    case notFound(String)

    public static func assess(ratio: Double?) -> TimestampUnitsVerdict {
        guard let ratio else { return .notFound("no [Debounce] event timestamp units line in the queried window") }
        return (0.9...1.1).contains(ratio) ? .nanoseconds(ratio: ratio) : .other(ratio: ratio)
    }

    public var isPass: Bool { if case .nanoseconds = self { return true } else { return false } }

    public var summary: String {
        switch self {
        case .nanoseconds(let r): return "PASS ratio=\(String(format: "%.4f", r)) (about 1: event timestamps are nanoseconds)"
        case .other(let r): return "FAIL ratio=\(String(format: "%.4f", r)) (not about 1: timestamps are not nanoseconds; 0.024 would be mach ticks)"
        case .notFound(let why): return "NOT FOUND: \(why)"
        }
    }
}
