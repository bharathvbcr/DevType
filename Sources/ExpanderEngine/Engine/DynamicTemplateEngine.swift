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
        // §3.6: `tokenize` now reports malformed input instead of silently dropping the offending
        // token — `{{calc:2--}}` used to lose the trailing operator and render a bare `2`.
        guard let tokens = tokenize(trimmed), !tokens.isEmpty else { return nil }
        guard tokens.count <= maxTokenCount else { return nil }
        var index = 0
        guard let result = parseExpression(tokens: tokens, index: &index), index == tokens.count else {
            return nil
        }
        // Overflow / division artifacts (`2^99999`) are not a usable expansion.
        guard result.isFinite else { return nil }
        return result
    }

    /// Renders a result as the text that gets typed.
    ///
    /// **Integers.** `Double(Int64.max)` rounds *up* to 2^63, which is one past `Int64.max`, so
    /// the old `val <= Double(Int64.max)` bound admitted exactly 2^63 — and `Int64(2^63)` traps.
    /// `{{calc: 2^63}}` therefore crashed the app, inside a keystroke interceptor, mid-expansion.
    /// The upper bound is now strict against 2^63; `Int64.min` needs no such care because it is
    /// -2^63 exactly and survives the round trip.
    ///
    /// **Everything else.** `String(someDouble)` prints the shortest round-trippable form, which
    /// is the *exact* binary value: `0.1 + 0.2` typed `0.30000000000000004` into the user's
    /// document. Twelve significant digits is past anything a text expander is doing arithmetic
    /// for and short enough to absorb IEEE-754 noise, and `%g` drops trailing zeros so `2.5`
    /// stays `2.5`.
    public static func format(_ value: Double) -> String {
        let twoToThe63 = 9_223_372_036_854_775_808.0
        if value.truncatingRemainder(dividingBy: 1) == 0,
           value >= -twoToThe63,
           value < twoToThe63 {
            return String(Int64(value))
        }
        return String(format: "%.12g", value)
    }

    private enum Token: Equatable {
        case number(Double)
        case op(Character)
        case openParen
        case closeParen
    }

    /// Returns `nil` when the input is not a well-formed arithmetic expression.
    private static func tokenize(_ input: String) -> [Token]? {
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
                // A leading `-` used to be glued onto the following digits here, which made
                // `-2^2` tokenize as `(-2)^2` = 4 instead of -(2^2) = -4, and made `-(3+4)`
                // unparseable because there were no digits to glue to. Signs are now handled by
                // `parseUnary`, at the precedence they actually have.
                tokens.append(.op(c))
                i += 1
            } else if c.isNumber || c == "." {
                var numStr = ""
                while i < chars.count && (chars[i].isNumber || chars[i] == ".") {
                    numStr.append(chars[i])
                    i += 1
                }
                // §3.6: rejects "1.2.3", lone ".", and non-ASCII digits rather than dropping them.
                guard let val = Double(numStr) else { return nil }
                tokens.append(.number(val))
            } else {
                // Reject unknown characters instead of silently skipping (bounded / safer).
                return nil
            }
        }
        return tokens
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
        guard var lhs = parseUnary(tokens: tokens, index: &index) else { return nil }
        while index < tokens.count {
            if case .op(let op) = tokens[index], op == "*" || op == "/" || op == "%" {
                index += 1
                guard let rhs = parseUnary(tokens: tokens, index: &index) else { return nil }
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

    /// Prefix `+` / `-`, binding *looser* than `^` — so `-2^2` is -(2^2) = -4, which is what
    /// every calculator and every reader of the expression expects.
    private static func parseUnary(tokens: [Token], index: inout Int) -> Double? {
        if index < tokens.count, case .op(let op) = tokens[index], op == "-" || op == "+" {
            index += 1
            guard let value = parseUnary(tokens: tokens, index: &index) else { return nil }
            return op == "-" ? -value : value
        }
        return parsePower(tokens: tokens, index: &index)
    }

    private static func parsePower(tokens: [Token], index: inout Int) -> Double? {
        guard var lhs = parsePrimary(tokens: tokens, index: &index) else { return nil }
        if index < tokens.count, case .op(let op) = tokens[index], op == "^" {
            index += 1
            // Right operand goes through `parseUnary` so `2^-1` still works, and right-associative
            // so `2^3^2` is 2^(3^2).
            guard let rhs = parseUnary(tokens: tokens, index: &index) else { return nil }
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
    public init() {}

    public struct ExpansionResult: Equatable {
        public let text: String
        public let cursorOffset: Int?
        public let failure: MacroRenderFailure?

        public init(text: String, cursorOffset: Int?, failure: MacroRenderFailure? = nil) {
            self.text = text
            self.cursorOffset = cursorOffset
            self.failure = failure
        }
    }

    /// Compatibility adapter. Literal safety belongs to the renderer's provenance, so external
    /// data is preserved byte-for-byte rather than deleting template-shaped user content.
    public static func sanitizeClipboardText(_ raw: String) -> String { raw }

    public static func templateNeedsClipboard(_ text: String) -> Bool { text.contains("{{clipboard}}") }

    public func resolve(_ template: String, currentDate: Date = Date(), clipboardText: String? = nil) -> ExpansionResult {
        resolve(template, currentDate: currentDate, clipboardText: clipboardText, environment: .default)
    }

    public func resolve(
        _ template: String, currentDate: Date = Date(), clipboardText: String? = nil,
        environment: MacroEnvironment
    ) -> ExpansionResult {
        let clipboard = clipboardText ?? (Self.templateNeedsClipboard(template)
            ? NSPasteboard.general.string(forType: .string) ?? "" : "")
        let document = render(MacroDocument(template), currentDate: currentDate, clipboardText: clipboard,
                              environment: environment)
        return result(document)
    }

    func result(_ document: MacroDocument) -> ExpansionResult {
        ExpansionResult(text: document.failure == nil ? document.text : "",
                        cursorOffset: document.failure == nil ? document.cursors.min() : nil,
                        failure: document.failure)
    }

    /// Compile template syntax once, then process inner nodes before their containing nodes.
    /// Replacements retain literal provenance and anchors; generated text is never reparsed.
    func render(
        _ input: MacroDocument, currentDate: Date, clipboardText: String,
        environment: MacroEnvironment, resolveMustache: Bool = true
    ) -> MacroDocument {
        var document = input
        if resolveMustache, document.failure == nil { document.compileMustacheTags() }
        var work = 0
        while document.failure == nil, !document.operations.isEmpty {
            guard document.length <= MacroDocument.maximumWork - work else { document.failure = .workLimit; break }
            work += document.length
            guard let index = document.operations.indices.min(by: { left, right in
                let a = document.operations[left], b = document.operations[right]
                if a.range.length != b.range.length { return a.range.length < b.range.length }
                if a.range.location != b.range.location { return a.range.location > b.range.location }
                if case .tag = a.kind, case .transform = b.kind { return true }
                return false
            }) else { break }
            let operation = document.operations.remove(at: index)
            switch operation.kind {
            case .transform(let transform):
                let body = document.slice(operation.range).transformed(transform, locale: environment.locale)
                document.replace(operation.range, with: body, mapsInteriorCursors: true)
            case .tag:
                let bodyRange = NSRange(location: operation.range.location + 2, length: operation.range.length - 4)
                let body = (document.text as NSString).substring(with: bodyRange)
                let colon = body.firstIndex(of: ":")
                let name = colon.map { String(body[..<$0]) } ?? body
                guard document.isSource(NSRange(location: bodyRange.location, length: name.utf16.count)) else { continue }
                let spec = colon.map { String(body[body.index(after: $0)...]) }
                var replacement: MacroDocument?
                if let transform = TextCaseTransform(rawValue: name), spec != nil {
                    let offset = name.utf16.count + 1
                    let range = NSRange(location: bodyRange.location + offset, length: bodyRange.length - offset)
                    replacement = document.slice(range).transformed(transform, locale: environment.locale)
                } else {
                    switch name {
                    case "cursor" where spec == nil:
                        var anchor = MacroDocument()
                        anchor.cursor()
                        replacement = anchor
                    case "clipboard" where spec == nil:
                        replacement = MacroDocument(clipboardText, literal: true)
                    case "date":
                        let value = spec.map { DateFormatLibrary.format($0, now: currentDate, locale: environment.locale, timeZone: environment.timeZone) }
                            ?? DateFormatLibrary.formatter(dateStyle: .medium, timeStyle: .none, locale: environment.locale, timeZone: environment.timeZone).string(from: currentDate)
                        replacement = MacroDocument(value, literal: true)
                    case "time" where spec == nil:
                        let formatter = DateFormatLibrary.formatter(dateStyle: .none, timeStyle: .medium,
                                                                   locale: environment.locale, timeZone: environment.timeZone)
                        replacement = MacroDocument(formatter.string(from: currentDate), literal: true)
                    case "calc":
                        if let spec, let value = SafeMathParser.evaluate(spec) {
                            replacement = MacroDocument(SafeMathParser.format(value), literal: true)
                        }
                    case "uuid":
                        replacement = MacroDocument(environment.uuidValue(spec: spec ?? "", syntax: "mustache", occurrence: operation.occurrence), literal: true)
                    case "random":
                        replacement = MacroDocument(environment.randomValue(spec: spec ?? "", syntax: "mustache", occurrence: operation.occurrence), literal: true)
                    case "counter":
                        let parsed = MacroCounterSpec.parse(spec ?? "")
                        replacement = MacroDocument(environment.counterValue(name: parsed.name, step: parsed.step), literal: true)
                    default: break
                    }
                }
                if let replacement {
                    let mapsAnchors = TextCaseTransform(rawValue: name) != nil || name == "cursor"
                    document.replace(operation.range, with: replacement, mapsInteriorCursors: mapsAnchors)
                }
            }
        }
        return document
    }
}
