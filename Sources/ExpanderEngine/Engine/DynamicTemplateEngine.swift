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

    private static let dateTagRegex = try? NSRegularExpression(pattern: "\\{\\{date:(.*?)\\}\\}", options: [])
    private static let calcTagRegex = try? NSRegularExpression(pattern: "\\{\\{calc:(.*?)\\}\\}", options: [])
    // §3.5 — generated values. `[^{}]*` keeps the spec from swallowing a neighbouring tag.
    private static let uuidTagRegex = try? NSRegularExpression(pattern: "\\{\\{uuid(?::([^{}]*))?\\}\\}", options: [])
    private static let randomTagRegex = try? NSRegularExpression(pattern: "\\{\\{random(?::([^{}]*))?\\}\\}", options: [])
    private static let counterTagRegex = try? NSRegularExpression(pattern: "\\{\\{counter(?::([^{}]*))?\\}\\}", options: [])

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

    // MARK: - Clipboard sanitization (§1.12)

    /// Compiled once. `sanitizeClipboardText` sits on the expansion path and used to rebuild six
    /// `NSRegularExpression`s per call.
    private static let clipboardSanitizers: [NSRegularExpression] = {
        let patterns = [
            "\\{\\{clipboard\\}\\}",
            "\\{\\{cursor\\}\\}",
            "\\{\\{time\\}\\}",
            "\\{\\{date(?::[^}]*)?\\}\\}",
            "\\{\\{calc:[^}]*\\}\\}",
            "\\{\\{[^}]+\\}\\}"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    /// Strips nested template markers from clipboard before secondary `{{clipboard}}` injection.
    ///
    /// §1.12: also used by `MacroParser` for the TextExpander-style `%clipboard` token, which
    /// previously inserted the raw clipboard into text that was then fed to this engine.
    public static func sanitizeClipboardText(_ raw: String) -> String {
        // Fast path: nothing template-shaped, nothing to strip.
        guard raw.contains("{{") else { return raw }
        var output = raw
        for regex in clipboardSanitizers {
            let range = NSRange(location: 0, length: (output as NSString).length)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "")
        }
        return output
    }

    /// True when `template` (or intermediate output) still contains a clipboard placeholder.
    public static func templateNeedsClipboard(_ text: String) -> Bool {
        text.contains("{{clipboard}}")
    }

    // MARK: - Resolve

    public func resolve(_ template: String, currentDate: Date = Date(), clipboardText: String? = nil) -> ExpansionResult {
        resolve(template, currentDate: currentDate, clipboardText: clipboardText, environment: .default)
    }

    /// §3.5: resolution with injectable locale / counter / random collaborators.
    public func resolve(
        _ template: String,
        currentDate: Date = Date(),
        clipboardText: String? = nil,
        environment: MacroEnvironment
    ) -> ExpansionResult {
        var environment = environment
        if environment.memoSalt.isEmpty {
            // Scope volatile memo keys to this template so two different snippets expanded in the
            // same half-second cannot share a random value.
            environment.memoSalt = "mustache:\(template.hashValue)"
        }
        var output = template

        // 1. Process Date tags: {{date}} and {{date:FORMAT}} (offsets handled by DateFormatLibrary)
        output = processDateTags(in: output, currentDate: currentDate, environment: environment)

        // 2. Process Time tag: {{time}}
        let timeFormatter = getFormatter(timeStyle: .medium, environment: environment)
        output = output.replacingOccurrences(of: "{{time}}", with: timeFormatter.string(from: currentDate))

        // 3. Process Clipboard tag: {{clipboard}} — read pasteboard only when the tag is present.
        if Self.templateNeedsClipboard(output) {
            let rawClip = clipboardText ?? (NSPasteboard.general.string(forType: .string) ?? "")
            let clipText = Self.sanitizeClipboardText(rawClip)
            output = output.replacingOccurrences(of: "{{clipboard}}", with: clipText)
        }

        // 4. Process Calculation tags: {{calc: 12 + 4}}
        output = processCalcTags(in: output)

        // 5. §3.5 — generated values: {{uuid}}, {{random:1-100}}, {{counter:name}}
        output = processGeneratedTags(in: output, environment: environment)

        // 6. §3.5 — case transforms: {{upper:…}} / {{lower:…}} / {{title:…}} / {{sentence:…}}
        output = Self.processCaseTransformTags(in: output, locale: environment.locale)

        // 7. Process Cursor tag: {{cursor}} — UTF-16 offset for AX/HID. First marker wins, which
        //    is also what `MacroParser` does for `%|` (§3.6).
        var cursorOffset: Int? = nil
        if let firstCursorRange = output.range(of: "{{cursor}}") {
            let prefix = output[..<firstCursorRange.lowerBound]
            cursorOffset = prefix.utf16.count
        }
        output = output.replacingOccurrences(of: "{{cursor}}", with: "")

        return ExpansionResult(text: output, cursorOffset: cursorOffset)
    }

    private func processDateTags(in text: String, currentDate: Date, environment: MacroEnvironment) -> String {
        var output = text

        if let regex = Self.dateTagRegex {
            let nsString = output as NSString
            let matches = regex.matches(in: output, options: [], range: NSRange(location: 0, length: nsString.length))

            for match in matches.reversed() {
                let formatRange = match.range(at: 1)
                let customFormat = nsString.substring(with: formatRange)

                // Preset names (us, full, iso, …) resolve via the library; `:+1d` offsets are
                // applied there too (§3.5); anything else stays a raw DateFormatter pattern.
                let replacement = DateFormatLibrary.format(
                    customFormat,
                    now: currentDate,
                    locale: environment.locale,
                    timeZone: environment.timeZone
                )

                output = (output as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }

        let defaultFormatter = getFormatter(dateStyle: .medium, environment: environment)
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
                    let replacement = SafeMathParser.format(val)
                    output = (output as NSString).replacingCharacters(in: match.range, with: replacement)
                }
                // §3.6: otherwise leave the original tag text in place. Replacing it with an empty
                // string deleted user content mid-expansion with no signal that anything happened.
            }
        }
        return output
    }

    // MARK: - Generated values (§3.5)

    private func processGeneratedTags(in text: String, environment: MacroEnvironment) -> String {
        var output = text
        output = Self.replaceTags(in: output, regex: Self.uuidTagRegex) { spec, _ in
            environment.uuidValue(spec: spec)
        }
        output = Self.replaceTags(in: output, regex: Self.randomTagRegex) { spec, occurrence in
            environment.randomValue(spec: spec, syntax: "mustache", occurrence: occurrence)
        }
        output = Self.replaceTags(in: output, regex: Self.counterTagRegex) { spec, _ in
            let parsed = MacroCounterSpec.parse(spec)
            return environment.counterValue(name: parsed.name, step: parsed.step)
        }
        return output
    }

    private static func replaceTags(
        in text: String,
        regex: NSRegularExpression?,
        transform: (String, Int) -> String
    ) -> String {
        guard let regex else { return text }
        var output = text
        let nsString = output as NSString
        let matches = regex.matches(in: output, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return output }
        for (occurrence, match) in Array(matches.enumerated()).reversed() {
            var spec = ""
            if match.numberOfRanges >= 2 {
                let specRange = match.range(at: 1)
                if specRange.location != NSNotFound {
                    spec = nsString.substring(with: specRange)
                }
            }
            output = (output as NSString).replacingCharacters(
                in: match.range,
                with: transform(spec, occurrence)
            )
        }
        return output
    }

    // MARK: - Case transforms (§3.5)

    private static let caseTransformOpeners: [(marker: String, transform: TextCaseTransform)] = [
        (marker: "{{upper:", transform: .upper),
        (marker: "{{lower:", transform: .lower),
        (marker: "{{title:", transform: .title),
        (marker: "{{sentence:", transform: .sentence),
    ]

    /// Resolves `{{upper:…}}` and friends innermost-first with balanced `{{`/`}}` counting, so a
    /// nested tag inside the body does not terminate the transform early.
    static func processCaseTransformTags(in text: String, locale: Locale) -> String {
        guard text.contains("{{") else { return text }
        var output = text
        var iterations = 0
        while iterations < 32 {
            iterations += 1
            var opener: (range: Range<String.Index>, transform: TextCaseTransform)?
            for entry in caseTransformOpeners {
                guard let range = output.range(of: entry.marker, options: .backwards) else { continue }
                if opener == nil || range.lowerBound > opener!.range.lowerBound {
                    opener = (range: range, transform: entry.transform)
                }
            }
            guard let opener else { break }
            guard let close = matchingCloseRange(in: output, from: opener.range.upperBound) else { break }
            let body = String(output[opener.range.upperBound..<close.lowerBound])
            let transformed = applyPreservingCursorTag(opener.transform, to: body, locale: locale)
            output.replaceSubrange(opener.range.lowerBound..<close.upperBound, with: transformed)
        }
        if iterations >= 32, output.contains("{{upper:") || output.contains("{{lower:")
            || output.contains("{{title:") || output.contains("{{sentence:") {
            // The cap exists to bound adversarial input; a library that genuinely exceeds it
            // must not fail silently — the leftover literal tags are the user-visible symptom.
            DevTypeLog.app.notice(
                "[Macros] case-transform pass hit its 32-iteration bound — remaining {{…}} tags left literal"
            )
        }
        return output
    }

    private static func matchingCloseRange(in text: String, from start: String.Index) -> Range<String.Index>? {
        var depth = 0
        var index = start
        while index < text.endIndex {
            let next = text.index(after: index)
            if next < text.endIndex, text[index] == "{", text[next] == "{" {
                depth += 1
                index = text.index(after: next)
                continue
            }
            if next < text.endIndex, text[index] == "}", text[next] == "}" {
                if depth == 0 { return index..<text.index(after: next) }
                depth -= 1
                index = text.index(after: next)
                continue
            }
            index = next
        }
        return nil
    }

    /// `{{cursor}}` is resolved after transforms; never fold its case.
    private static func applyPreservingCursorTag(
        _ transform: TextCaseTransform,
        to body: String,
        locale: Locale
    ) -> String {
        guard body.contains("{{cursor}}") else { return transform.apply(to: body, locale: locale) }
        return body.components(separatedBy: "{{cursor}}")
            .map { transform.apply(to: $0, locale: locale) }
            .joined(separator: "{{cursor}}")
    }

    // MARK: - Formatters

    /// §2.9: previously a private per-engine cache that pinned `Locale.current` at fill time and
    /// never invalidated, while `processDateTags` bypassed it entirely by routing to
    /// `DateFormatLibrary.format`. Both paths now share one cache keyed by
    /// `(shape, locale, time zone)`.
    private func getFormatter(
        dateFormat: String? = nil,
        dateStyle: DateFormatter.Style = .none,
        timeStyle: DateFormatter.Style = .none,
        environment: MacroEnvironment = .default
    ) -> DateFormatter {
        if let dateFormat {
            return DateFormatLibrary.formatter(
                pattern: dateFormat,
                locale: environment.locale,
                timeZone: environment.timeZone
            )
        }
        return DateFormatLibrary.formatter(
            dateStyle: dateStyle,
            timeStyle: timeStyle,
            locale: environment.locale,
            timeZone: environment.timeZone
        )
    }
}
