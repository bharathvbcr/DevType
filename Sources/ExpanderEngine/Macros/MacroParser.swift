// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// Parses TextExpander-compatible macros inside snippet content.
///
/// Supported syntax (verified against real TextExpander 5 data):
///   %filltext:name=X%  %filltext:name=X:default=Y%     single-line fill-in
///   %fillarea:name=X:default=Y%                        multi-line fill-in
///   %fillpopup:name=X:option one:option two:default=Y% popup fill-in
///   %fillpart:name=X:default=yes% ... %fillpartend%    optional section
///   %snippet:ABBREV%                                   nested snippet
///   %clipboard                                         current clipboard text
///   %key:enter%  %key:return%  %key:tab%               key press after expansion
///   %|                                                 cursor position
///   %date:FORMAT%                                      date/time (DateFormatter pattern)
///
/// §3.5 additions (all backwards compatible — previously these were left as literal text):
///   %date:iso:+1d%   %@+1D%                            date arithmetic
///   %uuid%           %random:1-100%   %counter:name%   generated values
///   %case:upper% ... %caseend%                         case transform block
///
/// §3.6: inside a macro body, `%%` is an escaped literal `%`, so
/// `%filltext:name=D:default=50%%off%` yields the default `50%off` instead of truncating at the
/// first `%`. When a body has no unescaped terminator the parser falls back to the historical
/// first-`%` rule, so templates written against the old parser keep rendering identically.
///
/// Unknown %-sequences (e.g. URL-encoded text like %EC%B0%A8) are left as-is.
public enum MacroToken: Equatable {
    case text(String)
    case fillText(name: String, defaultValue: String)
    case fillArea(name: String, defaultValue: String)
    case fillPopup(name: String, options: [String], defaultValue: String)
    case fillPartStart(name: String, defaultOn: Bool)
    case fillPartEnd
    case snippet(abbreviation: String)
    case clipboard
    case key(String)
    case cursor
    case date(format: String)
    // §3.5 — additive cases. Existing tokens keep their exact payloads.
    case uuid(spec: String)
    case random(spec: String)
    case counter(name: String, step: Int)
    case caseStart(TextCaseTransform)
    case caseEnd
}

/// A fill-in field presented to the user before expansion.
public struct FillField: Identifiable, Equatable {
    public enum Kind: Equatable {
        case text
        case area
        case popup(options: [String])
        case part // optional section toggle
    }
    public let id: Int
    public let name: String
    public let kind: Kind
    public let defaultValue: String

    public init(id: Int, name: String, kind: Kind, defaultValue: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

public struct RenderResult: Equatable {
    public var text: String
    /// Number of characters (graphemes) after the cursor marker; 0 = cursor at end.
    public var cursorOffsetFromEnd: Int
    /// Key names (e.g. "enter") to press after inserting the text.
    public var trailingKeys: [String]
}

public enum MacroParser {

    // MARK: - Parsing

    /// Keywords using the `%keyword:body%` shape.
    private static let delimitedKeywords = [
        "filltext", "fillarea", "fillpopup", "fillpart", "snippet", "key", "date",
        // §3.5
        "random", "counter", "case", "uuid",
    ]

    /// Keywords using the bare `%keyword%` shape (no body).
    private static let bareKeywords: [(literal: String, token: MacroToken)] = [
        (literal: "%fillpartend%", token: .fillPartEnd),
        // §3.5
        (literal: "%caseend%", token: .caseEnd),
        (literal: "%uuid%", token: .uuid(spec: "")),
    ]

    public static func parse(_ content: String) -> [MacroToken] {
        var tokens: [MacroToken] = []
        var text = ""
        var i = content.startIndex

        func flushText() {
            if !text.isEmpty { tokens.append(.text(text)); text = "" }
        }

        while i < content.endIndex {
            guard content[i] == "%" else {
                text.append(content[i])
                i = content.index(after: i)
                continue
            }
            let rest = content[i...]
            if rest.hasPrefix("%|") {
                flushText()
                tokens.append(.cursor)
                i = content.index(i, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("%clipboard"), !clipboardMatchIsGreedy(in: content, at: i) {
                flushText()
                tokens.append(.clipboard)
                i = content.index(i, offsetBy: "%clipboard".count)
                continue
            }
            if let bare = bareKeywords.first(where: { rest.hasPrefix($0.literal) }) {
                flushText()
                tokens.append(bare.token)
                i = content.index(i, offsetBy: bare.literal.count)
                continue
            }
            if let (token, consumed) = parseDelimitedMacro(rest) {
                flushText()
                tokens.append(token)
                i = content.index(i, offsetBy: consumed)
                continue
            }
            // Not a recognized macro — keep the literal '%'.
            text.append(content[i])
            i = content.index(after: i)
        }
        flushText()
        return tokens
    }

    /// §3.6: `%clipboard` has no terminator, so the old prefix match was greedy —
    /// `%clipboardless` rendered as `<clipboard>less`. Refuse the match when a word character
    /// follows; that text is almost certainly not a macro.
    private static func clipboardMatchIsGreedy(in content: String, at start: String.Index) -> Bool {
        let after = content.index(start, offsetBy: "%clipboard".count)
        guard after < content.endIndex else { return false }
        let next = content[after]
        return next.isLetter || next.isNumber || next == "_"
    }

    /// A macro body plus where it ended.
    private struct ScannedBody {
        /// Body text with `%%` escapes resolved to a single `%`.
        let text: String
        /// Characters consumed from the start of the macro, including the closing `%`.
        let consumed: Int
        /// Index of the closing `%` inside the scanned substring.
        let terminator: Substring.Index
    }

    /// §3.6: Scans a macro body, treating `%%` as an escaped literal `%`. Falls back to the
    /// historical "first `%` wins" rule when no unescaped terminator exists, so nothing that
    /// parsed before parses differently now.
    private static func scanBody(_ rest: Substring, from bodyStart: Substring.Index) -> ScannedBody? {
        var body = ""
        var index = bodyStart
        while index < rest.endIndex {
            let character = rest[index]
            if character == "%" {
                let next = rest.index(after: index)
                if next < rest.endIndex, rest[next] == "%" {
                    body.append("%")
                    index = rest.index(after: next)
                    continue
                }
                return ScannedBody(
                    text: body,
                    consumed: rest.distance(from: rest.startIndex, to: index) + 1,
                    terminator: index
                )
            }
            body.append(character)
            index = rest.index(after: index)
        }
        // No unescaped terminator — legacy behavior.
        guard let legacy = rest[bodyStart...].firstIndex(of: "%") else { return nil }
        return ScannedBody(
            text: String(rest[bodyStart..<legacy]),
            consumed: rest.distance(from: rest.startIndex, to: legacy) + 1,
            terminator: legacy
        )
    }

    /// Parses macros of the form %keyword:body% and returns the token plus
    /// the number of characters consumed.
    private static func parseDelimitedMacro(_ rest: Substring) -> (MacroToken, Int)? {
        // §3.5: TextExpander-style date math, `%@+1D%`.
        if rest.hasPrefix("%@") {
            let bodyStart = rest.index(rest.startIndex, offsetBy: 2)
            if let scanned = scanBody(rest, from: bodyStart),
               DateOffset.parse(scanned.text) != nil {
                return (.date(format: scanned.text), scanned.consumed)
            }
            return nil
        }
        for keyword in delimitedKeywords {
            let prefix = "%\(keyword):"
            guard rest.hasPrefix(prefix) else { continue }
            let bodyStart = rest.index(rest.startIndex, offsetBy: prefix.count)
            guard let scanned = scanBody(rest, from: bodyStart) else { return nil }
            guard let token = makeToken(keyword: keyword, body: scanned.text) else { return nil }
            return (token, scanned.consumed)
        }
        return nil
    }

    private static func makeToken(keyword: String, body: String) -> MacroToken? {
        switch keyword {
        case "snippet":
            return .snippet(abbreviation: body)
        case "key":
            // §3.6: keep the author's casing (`%key:Enter%`). `TextInjectionPipeline`'s
            // `keyCode(forTrailingKeyName:)` lower-cases at use time, so behavior is unchanged
            // while the text round-trips losslessly through `resolveNested`.
            return .key(body)
        case "date":
            return .date(format: body)
        case "uuid":
            return .uuid(spec: body)
        case "random":
            return .random(spec: body)
        case "counter":
            let spec = MacroCounterSpec.parse(body)
            return .counter(name: spec.name, step: spec.step)
        case "case":
            guard let transform = TextCaseTransform.named(body) else { return nil }
            return .caseStart(transform)
        case "filltext", "fillarea", "fillpopup", "fillpart":
            var name = ""
            var defaultValue = ""
            var options: [String] = []
            let beforeDefault: String
            if let clause = rangeOfDefaultClause(in: body) {
                defaultValue = String(body[clause.upperBound...])
                beforeDefault = String(body[..<clause.lowerBound])
            } else {
                beforeDefault = body
            }
            for part in beforeDefault.components(separatedBy: ":") {
                if part.hasPrefix("name=") {
                    name = String(part.dropFirst("name=".count))
                } else if part.hasPrefix("width=") || part.hasPrefix("height=") {
                    // Sizing hints are not modeled; `resolveNested` no longer re-serializes
                    // from the token model, so they survive nesting untouched (§3.6).
                    continue
                } else if !part.isEmpty {
                    options.append(part)
                }
            }
            switch keyword {
            case "filltext": return .fillText(name: name, defaultValue: defaultValue)
            case "fillarea": return .fillArea(name: name, defaultValue: defaultValue)
            case "fillpopup": return .fillPopup(name: name, options: options, defaultValue: defaultValue)
            case "fillpart":
                let on = defaultValue.lowercased() != "no"
                return .fillPartStart(name: name, defaultOn: on)
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func rangeOfDefaultClause(in body: String) -> Range<String.Index>? {
        let token = "default="
        if body.hasPrefix(token) {
            return body.startIndex..<body.index(body.startIndex, offsetBy: token.count)
        }
        return body.range(of: ":" + token)
    }

    // MARK: - Nested snippets

    /// Aggregate work bounds for one nested-snippet resolution pass.
    ///
    /// The per-level depth cap (10) bounds recursion *depth*, but not *fan-out*:
    /// a library where each snippet references ten others costs 10ᴸ leaf
    /// expansions for L levels, so an ordinary-looking chain could hang the event
    /// tap (or exhaust memory) when a single trigger is typed. This budget caps
    /// total resolutions and total produced output per pass; once exhausted,
    /// remaining references are emitted literally — the same fail-safe behavior as
    /// an unresolved reference or depth-cap exhaustion.
    public final class NestedSnippetBudget {
        /// Total `%snippet:` / `{{snippet:}}` substitutions one pass may perform.
        public static let defaultMaxResolutions = 10_000
        /// Hard ceiling on UTF-16 output produced by substitutions in one pass.
        public static let defaultMaxOutputUTF16Count = 2_000_000

        public let maxResolutions: Int
        public let maxOutputUTF16Count: Int
        private(set) var resolutionsPerformed = 0
        private(set) var outputUTF16Count = 0

        public init(
            maxResolutions: Int = NestedSnippetBudget.defaultMaxResolutions,
            maxOutputUTF16Count: Int = NestedSnippetBudget.defaultMaxOutputUTF16Count
        ) {
            self.maxResolutions = max(1, maxResolutions)
            self.maxOutputUTF16Count = max(1, maxOutputUTF16Count)
        }

        var canResolveMore: Bool {
            resolutionsPerformed < maxResolutions && outputUTF16Count < maxOutputUTF16Count
        }

        func recordResolution(producedUTF16Count: Int) {
            resolutionsPerformed += 1
            outputUTF16Count += max(0, producedUTF16Count)
        }
    }

    /// Resolves `%snippet:ABBREV%` references **in place**.
    ///
    /// §3.6: the previous implementation re-parsed the whole string into tokens and rebuilt it
    /// through `literal(of:)`, so any snippet that referenced another permanently lost fill-in
    /// `width=` / `height=` clauses and had `%key:Enter%` normalized to `%key:enter%`. Now
    /// everything outside a `%snippet:` macro is copied verbatim and only the reference itself is
    /// substituted, which makes the transform lossless by construction.
    ///
    /// Pass `budget` explicitly when this call is part of a larger resolution (e.g. the mustache
    /// engine resolving one reference of many) so aggregate work stays bounded across the whole
    /// expansion; the default creates a fresh budget per top-level call.
    public static func resolveNested(
        _ content: String,
        lookup: (String) -> String?,
        depth: Int = 0,
        budget: NestedSnippetBudget = NestedSnippetBudget()
    ) -> String {
        guard depth < 10, content.contains("%snippet:"), budget.canResolveMore else { return content }

        let marker = "%snippet:"
        var result = ""
        var i = content.startIndex

        while i < content.endIndex {
            guard content[i] == "%" else {
                result.append(content[i])
                i = content.index(after: i)
                continue
            }
            let rest = content[i...]
            guard rest.hasPrefix(marker) else {
                result.append(content[i])
                i = content.index(after: i)
                continue
            }
            let bodyStart = rest.index(rest.startIndex, offsetBy: marker.count)
            guard let scanned = scanBody(rest, from: bodyStart) else {
                result.append(content[i])
                i = content.index(after: i)
                continue
            }
            if let nested = lookup(scanned.text), budget.canResolveMore {
                let expanded = resolveNested(nested, lookup: lookup, depth: depth + 1, budget: budget)
                budget.recordResolution(producedUTF16Count: expanded.utf16.count)
                result += expanded
            } else {
                // Unresolved or over-budget: emit the original source text byte-for-byte.
                result += String(rest[rest.startIndex...scanned.terminator])
            }
            i = content.index(i, offsetBy: scanned.consumed)
        }
        return result
    }

    /// Best-effort re-serialization of a single token.
    ///
    /// §3.6: no longer used by `resolveNested` (it was the source of the sizing/casing loss).
    /// Kept public for editors and diagnostics that need a canonical macro string.
    public static func literal(of token: MacroToken) -> String {
        switch token {
        case .text(let s): return s
        case .fillText(let n, let d): return d.isEmpty ? "%filltext:name=\(n)%" : "%filltext:name=\(n):default=\(d)%"
        case .fillArea(let n, let d): return d.isEmpty ? "%fillarea:name=\(n)%" : "%fillarea:name=\(n):default=\(d)%"
        case .fillPopup(let n, let opts, let d):
            var body = "name=\(n)"
            for o in opts { body += ":\(o)" }
            if !d.isEmpty { body += ":default=\(d)" }
            return "%fillpopup:\(body)%"
        case .fillPartStart(let n, let on): return "%fillpart:name=\(n):default=\(on ? "yes" : "no")%"
        case .fillPartEnd: return "%fillpartend%"
        case .snippet(let a): return "%snippet:\(a)%"
        case .clipboard: return "%clipboard"
        case .key(let k): return "%key:\(k)%"
        case .cursor: return "%|"
        case .date(let f): return "%date:\(f)%"
        case .uuid(let spec): return spec.isEmpty ? "%uuid%" : "%uuid:\(spec)%"
        case .random(let spec): return "%random:\(spec)%"
        case .counter(let name, let step):
            return step == 1 ? "%counter:\(name)%" : "%counter:\(name):\(step > 0 ? "+" : "")\(step)%"
        case .caseStart(let transform): return "%case:\(transform.rawValue)%"
        case .caseEnd: return "%caseend%"
        }
    }

    // MARK: - Fill-in fields

    public static func fillFields(in tokens: [MacroToken]) -> [FillField] {
        var fields: [FillField] = []
        var id = 0
        for token in tokens {
            switch token {
            case .fillText(let name, let def):
                fields.append(FillField(id: id, name: name, kind: .text, defaultValue: def))
                id += 1
            case .fillArea(let name, let def):
                fields.append(FillField(id: id, name: name, kind: .area, defaultValue: def))
                id += 1
            case .fillPopup(let name, let options, let def):
                fields.append(FillField(id: id, name: name, kind: .popup(options: options), defaultValue: def))
                id += 1
            case .fillPartStart(let name, let on):
                fields.append(FillField(id: id, name: name, kind: .part, defaultValue: on ? "yes" : "no"))
                id += 1
            default:
                break
            }
        }
        return fields
    }

    public static func hasFillIns(_ tokens: [MacroToken]) -> Bool {
        tokens.contains { token in
            switch token {
            case .fillText, .fillArea, .fillPopup, .fillPartStart: return true
            default: return false
            }
        }
    }

    // MARK: - Rendering

    public static func render(
        tokens: [MacroToken],
        fillValues: [Int: String] = [:],
        clipboard: @autoclosure () -> String = "",
        now: Date = Date()
    ) -> RenderResult {
        render(tokens: tokens, fillValues: fillValues, clipboard: clipboard(), now: now, environment: .default)
    }

    /// §3.5: rendering with injectable locale / counter / random collaborators.
    public static func render(
        tokens: [MacroToken],
        fillValues: [Int: String] = [:],
        clipboard: @autoclosure () -> String = "",
        now: Date = Date(),
        environment: MacroEnvironment
    ) -> RenderResult {
        var out = ""
        var cursorPosition: Int? = nil
        var trailingKeys: [String] = []
        var fieldID = 0
        var skipDepth = 0
        var volatileOccurrence = 0
        // §3.5: open `%case:…%` blocks as (transform, out.count when the block opened).
        var caseStack: [(transform: TextCaseTransform, start: Int)] = []

        for token in tokens {
            if case .fillPartEnd = token {
                if skipDepth > 0 { skipDepth -= 1 }
                continue
            }
            if case .fillPartStart(_, let defaultOn) = token {
                if skipDepth > 0 {
                    // Inside an already-skipped block: track nesting depth but
                    // don't re-evaluate fill values.
                    skipDepth += 1
                } else {
                    let value = fillValues[fieldID] ?? (defaultOn ? "yes" : "no")
                    if value.lowercased() == "no" { skipDepth = 1 }
                }
                fieldID += 1
                continue
            }
            if skipDepth > 0 {
                switch token {
                case .fillText, .fillArea, .fillPopup: fieldID += 1
                default: break
                }
                continue
            }
            switch token {
            case .text(let s):
                out += s
            case .fillText(_, let def), .fillArea(_, let def):
                out += fillValues[fieldID] ?? def
                fieldID += 1
            case .fillPopup(_, let options, let def):
                out += fillValues[fieldID] ?? (def.isEmpty ? (options.first ?? "") : def)
                fieldID += 1
            case .snippet(let abbrev):
                out += "%snippet:\(abbrev)%"
            case .clipboard:
                // §1.12: the mustache engine strips `{{…}}` out of clipboard content before
                // substituting `{{clipboard}}`; this path used to insert the RAW clipboard and
                // `MacroRenderer` then fed the result straight into the mustache engine, so a
                // clipboard containing `{{calc:…}}` or `{{cursor}}` was evaluated. Same
                // sanitizer, both paths.
                out += DynamicTemplateEngine.sanitizeClipboardText(clipboard())
            case .key(let k):
                trailingKeys.append(k)
            case .cursor:
                // §3.6: first marker wins, matching TextExpander and the mustache engine
                // (`DynamicTemplateEngine` takes the first `{{cursor}}`). The two engines share
                // one pipeline and must not disagree.
                if cursorPosition == nil { cursorPosition = out.count }
            case .date(let format):
                // Named presets (us, full, iso, …), raw DateFormatter patterns, and `:+1d`
                // offsets (§3.5).
                out += DateFormatLibrary.format(
                    format,
                    now: now,
                    locale: environment.locale,
                    timeZone: environment.timeZone
                )
            case .uuid(let spec):
                out += environment.uuidValue(spec: spec)
            case .random(let spec):
                out += environment.randomValue(spec: spec, syntax: "te", occurrence: volatileOccurrence)
                volatileOccurrence += 1
            case .counter(let name, let step):
                out += environment.counterValue(name: name, step: step)
            case .caseStart(let transform):
                caseStack.append((transform: transform, start: out.count))
            case .caseEnd:
                guard let open = caseStack.popLast(), open.start <= out.count else { break }
                let head = String(out.prefix(open.start))
                let body = String(out.dropFirst(open.start))
                out = head + open.transform.apply(to: body, locale: environment.locale)
            case .fillPartStart, .fillPartEnd:
                break
            }
        }

        // Unbalanced `%case:…%` — apply to everything that followed rather than dropping it.
        while let open = caseStack.popLast(), open.start <= out.count {
            let head = String(out.prefix(open.start))
            let body = String(out.dropFirst(open.start))
            out = head + open.transform.apply(to: body, locale: environment.locale)
        }

        let offsetFromEnd = cursorPosition.map { out.count - $0 } ?? 0
        return RenderResult(text: out, cursorOffsetFromEnd: offsetFromEnd, trailingKeys: trailingKeys)
    }
}
