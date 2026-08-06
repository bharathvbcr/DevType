import AppKit
import Foundation

public final class SafeMathParser {
    /// Maximum expression length accepted by `{{calc:}}` (UTF-8 bytes / characters).
    public static let maxExpressionLength = 64
    /// Soft cap on nested parentheses / tokens to bound parse work.
    public static let maxTokenCount = 48

    public static func evaluate(_ expression: String) -> Double? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxExpressionLength else { return nil }
        let tokens = tokenize(trimmed)
        guard tokens.count <= maxTokenCount else { return nil }
        var index = 0
        guard let result = parseExpression(tokens: tokens, index: &index), index == tokens.count else {
            return nil
        }
        return result
    }

    private enum Token: Equatable {
        case number(Double)
        case op(Character)
        case openParen
        case closeParen
    }

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            if c == "(" {
                tokens.append(.openParen)
                i += 1
            } else if c == ")" {
                tokens.append(.closeParen)
                i += 1
            } else if "+-*/%^".contains(c) {
                if (c == "-" || c == "+") && (tokens.isEmpty || tokens.last == .openParen || isOperatorToken(tokens.last)) {
                    var numStr = String(c)
                    i += 1
                    while i < chars.count && (chars[i].isNumber || chars[i] == ".") {
                        numStr.append(chars[i])
                        i += 1
                    }
                    if let val = Double(numStr) {
                        tokens.append(.number(val))
                    }
                } else {
                    tokens.append(.op(c))
                    i += 1
                }
            } else if c.isNumber || c == "." {
                var numStr = ""
                while i < chars.count && (chars[i].isNumber || chars[i] == ".") {
                    numStr.append(chars[i])
                    i += 1
                }
                if let val = Double(numStr) {
                    tokens.append(.number(val))
                }
            } else {
                // Reject unknown characters instead of silently skipping (bounded / safer).
                return []
            }
        }
        return tokens
    }

    private static func isOperatorToken(_ token: Token?) -> Bool {
        if case .op? = token { return true }
        return false
    }

    private static func parseExpression(tokens: [Token], index: inout Int) -> Double? {
        return parseAddSub(tokens: tokens, index: &index)
    }

    private static func parseAddSub(tokens: [Token], index: inout Int) -> Double? {
        guard var lhs = parseMulDiv(tokens: tokens, index: &index) else { return nil }
        while index < tokens.count {
            if case .op(let op) = tokens[index], op == "+" || op == "-" {
                index += 1
                guard let rhs = parseMulDiv(tokens: tokens, index: &index) else { return nil }
                if op == "+" { lhs += rhs } else { lhs -= rhs }
            } else {
                break
            }
        }
        return lhs
    }

    private static func parseMulDiv(tokens: [Token], index: inout Int) -> Double? {
        guard var lhs = parsePower(tokens: tokens, index: &index) else { return nil }
        while index < tokens.count {
            if case .op(let op) = tokens[index], op == "*" || op == "/" || op == "%" {
                index += 1
                guard let rhs = parsePower(tokens: tokens, index: &index) else { return nil }
                if op == "*" {
                    lhs *= rhs
                } else if op == "/" {
                    if rhs == 0 { return nil }
                    lhs /= rhs
                } else if op == "%" {
                    if rhs == 0 { return nil }
                    lhs = lhs.truncatingRemainder(dividingBy: rhs)
                }
            } else {
                break
            }
        }
        return lhs
    }

    private static func parsePower(tokens: [Token], index: inout Int) -> Double? {
        guard var lhs = parsePrimary(tokens: tokens, index: &index) else { return nil }
        if index < tokens.count, case .op(let op) = tokens[index], op == "^" {
            index += 1
            guard let rhs = parsePower(tokens: tokens, index: &index) else { return nil }
            lhs = pow(lhs, rhs)
        }
        return lhs
    }

    private static func parsePrimary(tokens: [Token], index: inout Int) -> Double? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        switch token {
        case .number(let val):
            index += 1
            return val
        case .openParen:
            index += 1
            guard let expr = parseExpression(tokens: tokens, index: &index) else { return nil }
            if index < tokens.count, tokens[index] == .closeParen {
                index += 1
                return expr
            }
            return nil
        default:
            return nil
        }
    }
}

public final class DynamicTemplateEngine {
    public static let shared = DynamicTemplateEngine()

    private let lock = NSLock()
    private var cachedFormatters: [String: DateFormatter] = [:]
    private static let dateTagRegex = try? NSRegularExpression(pattern: "\\{\\{date:(.*?)\\}\\}", options: [])
    private static let calcTagRegex = try? NSRegularExpression(pattern: "\\{\\{calc:(.*?)\\}\\}", options: [])

    public init() {}

    public struct ExpansionResult: Equatable {
        public let text: String
        /// UTF-16 offset for caret placement (AX / HID arrow compatible).
        public let cursorOffset: Int?

        public init(text: String, cursorOffset: Int?) {
            self.text = text
            self.cursorOffset = cursorOffset
        }
    }

    /// Strips nested template markers from clipboard before secondary `{{clipboard}}` injection.
    public static func sanitizeClipboardText(_ raw: String) -> String {
        var output = raw
        // Remove any template-like tokens so clipboard cannot inject {{calc}} / {{cursor}} / etc.
        let patterns = [
            "\\{\\{clipboard\\}\\}",
            "\\{\\{cursor\\}\\}",
            "\\{\\{time\\}\\}",
            "\\{\\{date(?::[^}]*)?\\}\\}",
            "\\{\\{calc:[^}]*\\}\\}",
            "\\{\\{[^}]+\\}\\}"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(location: 0, length: (output as NSString).length)
                output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "")
            }
        }
        return output
    }

    /// True when `template` (or intermediate output) still contains a clipboard placeholder.
    public static func templateNeedsClipboard(_ text: String) -> Bool {
        text.contains("{{clipboard}}")
    }

    public func resolve(_ template: String, currentDate: Date = Date(), clipboardText: String? = nil) -> ExpansionResult {
        var output = template

        // 1. Process Date tags: {{date}} and {{date:FORMAT}}
        output = processDateTags(in: output, currentDate: currentDate)

        // 2. Process Time tag: {{time}}
        let timeFormatter = getFormatter(dateFormat: nil, timeStyle: .medium)
        output = output.replacingOccurrences(of: "{{time}}", with: timeFormatter.string(from: currentDate))

        // 3. Process Clipboard tag: {{clipboard}} — read pasteboard only when the tag is present.
        if Self.templateNeedsClipboard(output) {
            let rawClip = clipboardText ?? (NSPasteboard.general.string(forType: .string) ?? "")
            let clipText = Self.sanitizeClipboardText(rawClip)
            output = output.replacingOccurrences(of: "{{clipboard}}", with: clipText)
        }

        // 4. Process Calculation tags: {{calc: 12 + 4}}
        output = processCalcTags(in: output)

        // 5. Process Cursor tag: {{cursor}} — UTF-16 offset for AX/HID.
        var cursorOffset: Int? = nil
        if let firstCursorRange = output.range(of: "{{cursor}}") {
            let prefix = output[..<firstCursorRange.lowerBound]
            cursorOffset = prefix.utf16.count
        }
        output = output.replacingOccurrences(of: "{{cursor}}", with: "")

        return ExpansionResult(text: output, cursorOffset: cursorOffset)
    }

    private func processDateTags(in text: String, currentDate: Date) -> String {
        var output = text

        if let regex = Self.dateTagRegex {
            let nsString = output as NSString
            let matches = regex.matches(in: output, options: [], range: NSRange(location: 0, length: nsString.length))

            for match in matches.reversed() {
                let formatRange = match.range(at: 1)
                let customFormat = nsString.substring(with: formatRange)

                // Preset names (us, full, iso, …) resolve via the library;
                // anything else stays a raw DateFormatter pattern.
                let replacement = DateFormatLibrary.format(customFormat, now: currentDate)

                output = (output as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }

        let defaultFormatter = getFormatter(dateStyle: .medium)
        output = output.replacingOccurrences(of: "{{date}}", with: defaultFormatter.string(from: currentDate))

        return output
    }

    private func processCalcTags(in text: String) -> String {
        var output = text
        if let regex = Self.calcTagRegex {
            let nsString = output as NSString
            let matches = regex.matches(in: output, options: [], range: NSRange(location: 0, length: nsString.length))

            for match in matches.reversed() {
                let exprRange = match.range(at: 1)
                let exprString = nsString.substring(with: exprRange).trimmingCharacters(in: .whitespacesAndNewlines)

                if let val = SafeMathParser.evaluate(exprString) {
                    let replacement: String
                    if val.truncatingRemainder(dividingBy: 1) == 0, val >= Double(Int64.min), val <= Double(Int64.max) {
                        replacement = String(Int64(val))
                    } else {
                        replacement = String(val)
                    }
                    output = (output as NSString).replacingCharacters(in: match.range, with: replacement)
                } else {
                    // Bound / invalid: leave empty rather than injecting raw expression.
                    output = (output as NSString).replacingCharacters(in: match.range, with: "")
                }
            }
        }
        return output
    }

    private func getFormatter(dateFormat: String? = nil, dateStyle: DateFormatter.Style = .none, timeStyle: DateFormatter.Style = .none) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }

        let key = "\(dateFormat ?? "")_\(dateStyle.rawValue)_\(timeStyle.rawValue)"
        if let existing = cachedFormatters[key] {
            return existing
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        if let dateFormat = dateFormat {
            formatter.dateFormat = dateFormat
        } else {
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
        }
        cachedFormatters[key] = formatter
        return formatter
    }
}
