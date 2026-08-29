import Foundation

/// Markdown constructs a model volunteers, tracked individually so the stripper can
/// remove what the model added without touching what the author already wrote.
public struct AIMarkdownConstruct: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `# Heading`, and the `===` underline form.
    public static let heading = AIMarkdownConstruct(rawValue: 1 << 0)
    /// `*em*`, `_em_`, `**strong**`, `__strong__`, `***both***`.
    public static let emphasis = AIMarkdownConstruct(rawValue: 1 << 1)
    /// `~~struck~~`.
    public static let strikethrough = AIMarkdownConstruct(rawValue: 1 << 2)
    /// `` `code` `` — the backticks go, the code stays.
    public static let codeSpan = AIMarkdownConstruct(rawValue: 1 << 3)
    /// ```` ```lang ```` … ```` ``` ```` — the fence lines go, the body stays verbatim.
    public static let codeFence = AIMarkdownConstruct(rawValue: 1 << 4)
    /// `[text](url)`, `![alt](url)`, `[text][ref]`, `<https://…>`, and `[ref]: url`.
    public static let link = AIMarkdownConstruct(rawValue: 1 << 5)
    /// `> quoted`.
    public static let blockquote = AIMarkdownConstruct(rawValue: 1 << 6)
    /// `* item` / `+ item` normalised to `- item`. The bullet itself is kept: a list
    /// with its markers pulled off is not plain text, it is a mangled list.
    public static let list = AIMarkdownConstruct(rawValue: 1 << 7)
    /// Pipe tables — the `|---|---|` rule line goes, the outer pipes go, cells stay.
    public static let table = AIMarkdownConstruct(rawValue: 1 << 8)
    /// `---`, `***`, `___` on a line of their own.
    public static let thematicBreak = AIMarkdownConstruct(rawValue: 1 << 9)

    public static let all: AIMarkdownConstruct = [
        .heading, .emphasis, .strikethrough, .codeSpan, .codeFence,
        .link, .blockquote, .list, .table, .thematicBreak
    ]

    /// Stable probe order, so `constructs(in:)` is deterministic.
    static let individually: [AIMarkdownConstruct] = [
        .heading, .emphasis, .strikethrough, .codeSpan, .codeFence,
        .link, .blockquote, .list, .table, .thematicBreak
    ]
}

/// How much Markdown may be taken off a model's answer.
public enum AIMarkdownPolicy: String, Sendable, Equatable, CaseIterable {
    /// Remove every construct the input did not already use, including the block
    /// structure that changes how many lines the answer has.
    case strip
    /// Remove only what can be removed without adding, deleting, or blanking a line.
    /// For kinds that promise to hand back the author's own layout (`proofread`,
    /// the translations), where a dropped line is a broken promise.
    case stripPreservingLayout
    /// Leave the answer exactly as generated. For code and structured formats, where
    /// `*`, `_`, `#` and backticks are content rather than decoration.
    case preserve
}

/// Turns the Markdown a model volunteers back into the plain text the user asked for.
///
/// DevType writes into whatever field has focus — a Slack composer, a mail body, a
/// commit box, a form. None of them render Markdown, so `**launch**` arrives as four
/// literal asterisks around a word. The prompts already say "no markdown"; models this
/// size say it back and then emit a heading anyway. This is where that is enforced
/// rather than requested, and it is the only place that knows how: every model-backed
/// path (`AITextTransformer.generateRaw`, `CorrectionOutputSanitizer`) funnels through
/// here, so there is one answer to "what does DevType do with a bold marker" instead of
/// one per call site.
///
/// Three properties hold for every input, and are fuzzed in `AIMarkdownStripperTests`:
///
/// 1. **It never grows the text.** Every rule deletes characters or swaps one marker
///    for another of the same width. A result longer than its input is a bug, and is
///    rejected at the end of `strip` rather than returned.
/// 2. **It never empties the text.** A non-blank answer that strips to nothing is a
///    parse gone wrong; the original comes back untouched.
/// 3. **It is idempotent**, with one scoped exception. `strip(strip(x)) == strip(x)`
///    for every input that carries no fenced block and no code span. Where it does, the
///    exception is unavoidable and worth naming: once a fence's markers are gone, its
///    body is no longer marked as code, so a *second* pass reads `let a = b_c_d` as
///    prose and strips it. That is why every call site runs this exactly once —
///    `AITransformCorrector` hands the sanitizer `.preserve` because the transformer
///    already stripped, and `CorrectionOutputSanitizer` runs its wrapper loop to a fixed
///    point around a single Markdown pass rather than inside it.
///
/// And one rule about ownership: **a construct the input already uses is never removed
/// from the output.** Proofreading a README must not silently delete its headings.
/// `constructs(in:)` decides that by asking what the stripper itself would change, so
/// the two halves cannot drift apart.
///
/// Deliberately not handled: emphasis spanning a line break, and inline HTML. Both need
/// a scan that crosses lines, which is where a stray delimiter stops costing one marker
/// and starts eating paragraphs. Line-scoped is the safe bound.
public enum AIMarkdownStripper {

    /// Answers larger than this are returned untouched. The on-device context window
    /// cannot produce one; a value this size means something upstream is wrong, and a
    /// 512 KB scan in the injection path is not the place to find out.
    static let maximumInputBytes = 512_000

    /// Ceiling on delimiter-matching work, so an adversarial line of alternating
    /// delimiters cannot go quadratic on the path between a model and a text field.
    /// Exhausting it stops transforming and emits the remainder verbatim — the failure
    /// mode is "Markdown survived", never "text was corrupted".
    static let scanBudgetPerCharacter = 24
    static let scanBudgetFloor = 50_000

    /// Depth cap for the recursive inline pass (`[**a**](u)` nests text inside text).
    static let maximumInlineDepth = 4

    // MARK: - Entry point

    /// Strips Markdown from `text` under `policy`, preserving every construct `original`
    /// already used.
    ///
    /// - Parameters:
    ///   - text: the model's answer.
    ///   - policy: how much may be removed.
    ///   - original: the text the answer was generated from. Constructs it already uses
    ///     are the author's, not the model's, and are left alone. Pass `""` when there
    ///     is no source text (a dictated transcript has no Markdown to protect).
    public static func strip(
        _ text: String,
        policy: AIMarkdownPolicy = .strip,
        original: String = ""
    ) -> String {
        guard policy != .preserve else { return text }
        guard !text.isEmpty, text.utf8.count <= maximumInputBytes else { return text }

        let allowed = AIMarkdownConstruct.all.subtracting(constructs(in: original))
        guard !allowed.isEmpty else { return text }

        var budget = max(scanBudgetFloor, text.count * scanBudgetPerCharacter)
        let result = transform(
            text,
            allowed: allowed,
            allowsLineRemoval: policy == .strip,
            budget: &budget
        )

        // Post-conditions. Each one is a rule that would otherwise be enforced only by
        // the tests; a violation returns the untouched answer, because handing back the
        // model's Markdown is always better than handing back damage.
        guard result.count <= text.count else { return text }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }
        // Structurally guaranteed by `allowsLineRemoval: false` above, and checked anyway:
        // a future rule that learns to delete a line would otherwise break `proofread`'s
        // layout contract silently, and here it degrades to "no stripping" instead.
        if policy == .stripPreservingLayout, lineCount(result) != lineCount(text) {
            return text
        }
        return result
    }

    /// The constructs `text` actually uses — defined as the ones whose removal would
    /// change it.
    ///
    /// Defining it by probing the stripper rather than by a second set of patterns is
    /// the whole point: a detector that disagreed with the remover would either strip
    /// the author's own Markdown or refuse to strip the model's. `snake_case` is not
    /// emphasis here for exactly the same reason it is not emphasis there.
    ///
    /// Ten linear passes over the source text, recomputed on every `strip` — including
    /// once per streamed partial, where the source does not change. Left uncached on
    /// purpose: it is a few tens of thousands of character comparisons against a token
    /// of on-device model inference, and shared mutable state on this path would need a
    /// lock to buy nothing measurable.
    public static func constructs(in text: String) -> AIMarkdownConstruct {
        guard !text.isEmpty, text.utf8.count <= maximumInputBytes else { return [] }

        var found: AIMarkdownConstruct = []
        for construct in AIMarkdownConstruct.individually {
            var budget = max(scanBudgetFloor, text.count * scanBudgetPerCharacter)
            if transform(text, allowed: construct, allowsLineRemoval: true, budget: &budget) != text {
                found.insert(construct)
            }
        }
        return found
    }

    // MARK: - Policy resolution

    /// The policy for a transform kind, downgraded to `.preserve` when the user's own
    /// custom instructions asked for Markdown. `custom` is the one kind whose contract
    /// the user writes, so "format this as a markdown table" outranks the default.
    public static func policy(
        for kind: AITransformKind,
        customInstructions: String? = nil,
        enabled: Bool = true
    ) -> AIMarkdownPolicy {
        guard enabled else { return .preserve }
        let base = kind.markdownPolicy
        guard kind == .custom, let instructions = customInstructions else { return base }
        return requestsMarkdown(instructions) ? .preserve : base
    }

    /// Explicit formatting requests only. Deliberately narrow: a false positive costs
    /// one un-stripped answer, and the words here have no other reading in an
    /// instruction ("make it bold", "use a markdown table").
    static let markdownRequestPhrases = [
        "markdown", "md syntax", "bold", "italic", "heading", "headings",
        "code block", "code fence", "backtick", "asterisk", "rich text"
    ]

    static func requestsMarkdown(_ instructions: String) -> Bool {
        let lower = instructions.lowercased()
        return markdownRequestPhrases.contains { lower.contains($0) }
    }

    // MARK: - Line plumbing

    private struct Line {
        var content: String
        /// The exact newline that followed, so `\r\n` survives a round trip.
        var terminator: String
    }

    private static func lines(of text: String) -> [Line] {
        var result: [Line] = []
        var current = ""
        for character in text {
            if character.isNewline {
                result.append(Line(content: current, terminator: String(character)))
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(Line(content: current, terminator: ""))
        return result
    }

    private static func lineCount(_ text: String) -> Int {
        text.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
    }

    // MARK: - Core

    /// - Parameter allowsLineRemoval: when `false`, every rule that would delete a line
    ///   is skipped outright — fences, rules, Setext underlines, table rules, and
    ///   reference definitions. That is what `.stripPreservingLayout` buys, and skipping
    ///   the rules is why it buys it honestly: the alternative, letting them run and then
    ///   rejecting the result for changing the line count, throws away the inline
    ///   stripping that was perfectly fine.
    private static func transform(
        _ text: String,
        allowed: AIMarkdownConstruct,
        allowsLineRemoval: Bool,
        budget: inout Int
    ) -> String {
        let source = lines(of: text)
        let handlesTables = allowed.contains(.table) && allowsLineRemoval
        let tableRows: Set<Int> = handlesTables ? tableRowIndices(source.map(\.content)) : []

        var out: [Line] = []
        out.reserveCapacity(source.count)

        /// Removes the line at `index`, and with it one of the blank lines it sat
        /// between — `a\n\n---\n\nb` must come back as `a\n\nb`, not as a three-line gap
        /// the author never typed.
        func dropLine(at index: Int) {
            let nextIsBlank = index + 1 < source.count
                && source[index + 1].content.trimmingCharacters(in: .whitespaces).isEmpty
            guard nextIsBlank,
                  let last = out.last,
                  last.content.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            out.removeLast()
        }

        // Fence state. A fence that is never closed still has its opener removed and its
        // body kept: the body is the answer, the marker is the wrapper.
        var fenceMarker: Character?
        var fenceLength = 0

        for (index, line) in source.enumerated() {
            if let marker = fenceMarker {
                if closesFence(line.content, marker: marker, length: fenceLength) {
                    fenceMarker = nil
                    fenceLength = 0
                    dropLine(at: index)
                    continue
                }
                out.append(line)    // fenced body is content, never touched
                continue
            }

            // Every rule on a line runs to a fixed point together, because each one can
            // expose the next: `## |---|` is a table rule hiding behind a heading, `## > `
            // is a quote hiding behind one, and `*> x*` is a quote hiding behind emphasis.
            // Classifying once on the raw line and stripping once afterwards leaves those
            // for a second call to find — and a second call is exactly what must never be
            // needed. The line only shrinks, so this terminates.
            //
            // `previous` is the last line actually emitted rather than the raw source
            // line, so a Setext underline is judged against the text a reader would see
            // above it.
            var body = line.content
            var dropped = false
            var rounds = 0
            let maximumRounds = max(8, line.content.count)

            while rounds < maximumRounds {
                rounds += 1
                let before = body

                if allowsLineRemoval {
                    if allowed.contains(.codeFence), let open = opensFence(body) {
                        fenceMarker = open.marker
                        fenceLength = open.length
                        dropped = true
                        break
                    }
                    let previous = out.last?.content
                    if allowed.contains(.thematicBreak),
                       isThematicBreakOrSetextRule(body, previous: previous) {
                        dropped = true
                        break
                    }
                    if allowed.contains(.heading), isSetextUnderline(body, previous: previous) {
                        dropped = true
                        break
                    }
                    if allowed.contains(.table), isTableDelimiterRow(body) {
                        dropped = true
                        break
                    }
                    if allowed.contains(.link), isReferenceDefinition(body) {
                        dropped = true
                        break
                    }
                }

                if handlesTables, tableRows.contains(index) {
                    body = strippingOuterPipes(body)
                }
                body = strippingBlockPrefixes(body, allowed: allowed)
                body = strippingInline(body, allowed: allowed, depth: 0, budget: &budget)

                if body == before { break }
            }

            if dropped {
                dropLine(at: index)
                continue
            }
            out.append(Line(content: body, terminator: line.terminator))
        }

        // A dropped final line takes its predecessor's newline with it, or the answer
        // gains a trailing blank line it never had.
        if out.count < source.count, out.last?.terminator.isEmpty == false {
            out[out.count - 1].terminator = ""
        }

        return out.map { $0.content + $0.terminator }.joined()
    }

    // MARK: - Fences

    private static func opensFence(_ line: String) -> (marker: Character, length: Int)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3 else { return nil }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }

        let run = trimmed.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }

        // A backtick info string may not contain a backtick — otherwise `` `a` `b` ``
        // reads as a fence. Tildes have no such rule.
        let info = trimmed.dropFirst(run)
        if first == "`", info.contains("`") { return nil }
        return (first, run)
    }

    private static func closesFence(_ line: String, marker: Character, length: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 == marker }) else { return false }
        return trimmed.count >= length
    }

    // MARK: - Rules, breaks, and underlines

    private static func isThematicBreakOrSetextRule(_ line: String, previous: String?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
        let markers = trimmed.filter { !$0.isWhitespace }
        guard markers.allSatisfy({ $0 == first }) else { return false }
        if markers.count >= 3 { return true }
        // `--` under a line of text is a Setext underline, not content.
        return first == "-" && markers.count == 2 && !(previous ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isSetextUnderline(_ line: String, previous: String?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" }) else { return false }
        return !(previous ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `[docs]: https://example.com` — a definition that renders as nothing at all.
    /// The value must look like a target, so a line of prose that happens to open with
    /// a bracketed label survives.
    private static func isReferenceDefinition(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return false }
        let afterLabel = trimmed[trimmed.index(after: close)...]
        guard afterLabel.hasPrefix(":") else { return false }
        let value = afterLabel.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.contains(" ") else { return false }
        return value.contains("://") || value.hasPrefix("<") || value.hasPrefix("/")
            || value.hasPrefix("#") || value.hasPrefix("www.") || value.hasPrefix("mailto:")
    }

    // MARK: - Tables

    /// A pipe is only table syntax inside a run of pipe-bearing lines that contains a
    /// `|---|` rule. Prose with a stray `|` in it is prose — `ls | grep swift | wc -l`
    /// must come out of a rewrite exactly as it went in.
    ///
    /// The rule row itself is recognised line by line rather than from this set, because
    /// a heading marker can hide one (`## |---|`) and the set is built before any prefix
    /// comes off.
    private static func tableRowIndices(_ contents: [String]) -> Set<Int> {
        var rows: Set<Int> = []
        var blockStart = 0
        var index = 0

        func closeBlock(end: Int) {
            guard end > blockStart else { return }
            let range = blockStart..<end
            if range.contains(where: { isTableDelimiterRow(contents[$0]) }) {
                rows.formUnion(range)
            }
        }

        while index < contents.count {
            if contents[index].contains("|") && !contents[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            } else {
                closeBlock(end: index)
                index += 1
                blockStart = index
            }
        }
        closeBlock(end: contents.count)
        return rows
    }

    private static func isTableDelimiterRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// Outer pipes only. The cells and whatever separates them are the model's words,
    /// and re-spacing them is how a "strip" starts inventing layout — and how it starts
    /// growing the text.
    private static func strippingOuterPipes(_ line: String) -> String {
        let leading = String(line.prefix(while: { $0.isWhitespace }))
        var core = line.dropFirst(leading.count)
        let trailing = String(core.reversed().prefix(while: { $0.isWhitespace }).reversed())
        core = core.dropLast(trailing.count)

        if core.hasPrefix("|") { core = core.dropFirst() }
        if core.hasSuffix("|") { core = core.dropLast() }
        return leading + core.trimmingCharacters(in: .whitespaces) + trailing
    }

    // MARK: - Line prefixes

    /// Removes every stacked line prefix in one call — `> ## Title`, `## ## x`, `>  > q`.
    /// One layer per call would mean the result depended on how many times the caller ran
    /// it, which is the same bug as any other non-fixed-point pass.
    private static func strippingBlockPrefixes(_ line: String, allowed: AIMarkdownConstruct) -> String {
        var result = line
        // Each pass consumes from the front, so this is linear overall.
        for _ in 0..<max(1, line.count) {
            let next = strippingOneBlockPrefixLayer(result, allowed: allowed)
            if next == result { break }
            result = next
        }
        return result
    }

    private static func strippingOneBlockPrefixLayer(
        _ line: String,
        allowed: AIMarkdownConstruct
    ) -> String {
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        var rest = String(line.dropFirst(indent.count))

        if allowed.contains(.blockquote) {
            // Every nesting level in one pass, spaces between the markers included:
            // `>  > x` must reach `x` here, or a second call would strip the level this
            // one left behind and the result would depend on how many times it ran.
            var scan = Substring(rest)
            var unwrapped = false
            while true {
                let afterSpaces = scan.drop(while: { $0 == " " || $0 == "\t" })
                guard afterSpaces.hasPrefix(">") else { break }
                scan = afterSpaces.dropFirst()
                if scan.hasPrefix(" ") { scan = scan.dropFirst() }
                unwrapped = true
            }
            if unwrapped { rest = String(scan) }
        }

        if allowed.contains(.heading), rest.hasPrefix("#") {
            let hashes = rest.prefix(while: { $0 == "#" }).count
            let after = rest.dropFirst(hashes)
            if hashes <= 6, after.isEmpty || after.first == " " || after.first == "\t" {
                rest = String(after.drop(while: { $0 == " " || $0 == "\t" }))
                // Closing sequence: `## Title ##`
                let tail = rest.reversed().prefix(while: { $0 == "#" }).count
                if tail > 0 {
                    let withoutTail = String(rest.dropLast(tail))
                    if withoutTail.isEmpty || withoutTail.hasSuffix(" ") {
                        while rest.hasSuffix("#") { rest.removeLast() }
                        while rest.hasSuffix(" ") { rest.removeLast() }
                    }
                }
            }
        }

        if allowed.contains(.list), let marker = rest.first, marker == "*" || marker == "+" {
            let after = rest.dropFirst()
            if after.first == " " || after.first == "\t" {
                return indent + "-" + after
            }
        }

        return indent + rest
    }

    // MARK: - Inline

    private static func strippingInline(
        _ line: String,
        allowed: AIMarkdownConstruct,
        depth: Int,
        budget: inout Int
    ) -> String {
        guard depth <= maximumInlineDepth else { return line }
        guard line.contains(where: { "`*_~[]<!".contains($0) }) else { return line }

        let chars = Array(line)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var index = 0

        while index < chars.count {
            guard budget > 0 else {
                out.append(contentsOf: chars[index...])
                break
            }
            budget -= 1
            let character = chars[index]

            // An escaped delimiter is not a delimiter. The backslash stays: unescaping
            // would silently rewrite `\d` in a regex explanation and `C:\*` in a path,
            // and a stray backslash is one character of noise against that.
            if character == "\\", index + 1 < chars.count, isMarkdownPunctuation(chars[index + 1]) {
                out.append(character)
                out.append(chars[index + 1])
                index += 2
                continue
            }

            if character == "`", allowed.contains(.codeSpan) {
                let run = runLength(chars, from: index, of: "`")
                if let close = indexOfRun(chars, from: index + run, of: "`", length: run, budget: &budget) {
                    var inner = Array(chars[(index + run)..<close])
                    if inner.count >= 2, inner.first == " ", inner.last == " " {
                        inner = Array(inner.dropFirst().dropLast())
                    }
                    out.append(contentsOf: inner)   // code span content is literal
                    index = close + run
                    continue
                }
                out.append(contentsOf: chars[index..<(index + run)])
                index += run
                continue
            }

            if allowed.contains(.link) {
                if character == "!", index + 1 < chars.count, chars[index + 1] == "[",
                   let link = parseLink(chars, bracketAt: index + 1, budget: &budget) {
                    out.append(contentsOf: Array(strippingInline(
                        String(chars[link.textRange]), allowed: allowed, depth: depth + 1, budget: &budget
                    )))
                    index = link.end
                    continue
                }
                if character == "[", let link = parseLink(chars, bracketAt: index, budget: &budget) {
                    out.append(contentsOf: Array(strippingInline(
                        String(chars[link.textRange]), allowed: allowed, depth: depth + 1, budget: &budget
                    )))
                    index = link.end
                    continue
                }
                if character == "<", let autolink = parseAutolink(chars, from: index) {
                    out.append(contentsOf: chars[autolink.urlRange])
                    index = autolink.end
                    continue
                }
            }

            let isEmphasisMarker = (character == "*" || character == "_") && allowed.contains(.emphasis)
            let isStrikeMarker = character == "~" && allowed.contains(.strikethrough)
            if isEmphasisMarker || isStrikeMarker {
                if let span = parseDelimited(
                    chars,
                    from: index,
                    marker: character,
                    minimumRun: isStrikeMarker ? 2 : 1,
                    budget: &budget
                ) {
                    out.append(contentsOf: Array(strippingInline(
                        String(chars[span.contentRange]), allowed: allowed, depth: depth + 1, budget: &budget
                    )))
                    index = span.end
                    continue
                }
            }

            out.append(character)
            index += 1
        }

        return String(out)
    }

    private static func isMarkdownPunctuation(_ character: Character) -> Bool {
        "\\`*_{}[]()#+-.!|~<>".contains(character)
    }

    private static func runLength(_ chars: [Character], from index: Int, of marker: Character) -> Int {
        var length = 0
        var cursor = index
        while cursor < chars.count, chars[cursor] == marker {
            length += 1
            cursor += 1
        }
        return length
    }

    /// First run of `marker` of exactly `length` at or after `start`.
    private static func indexOfRun(
        _ chars: [Character],
        from start: Int,
        of marker: Character,
        length: Int,
        budget: inout Int
    ) -> Int? {
        var cursor = start
        while cursor < chars.count {
            guard budget > 0 else { return nil }
            budget -= 1
            if chars[cursor] == marker {
                let run = runLength(chars, from: cursor, of: marker)
                if run == length { return cursor }
                cursor += run
            } else {
                cursor += 1
            }
        }
        return nil
    }

    // MARK: - Links

    private struct ParsedLink {
        let textRange: Range<Int>
        let end: Int
    }

    /// `[text](target)` or `[text][ref]`. A bare `[text]` is left alone — it is as
    /// likely to be `[1]`, `[TODO]`, or `[redacted]` as it is to be a shortcut link.
    private static func parseLink(
        _ chars: [Character],
        bracketAt open: Int,
        budget: inout Int
    ) -> ParsedLink? {
        guard let close = matchingBracket(chars, from: open, open: "[", close: "]", budget: &budget) else {
            return nil
        }
        let text = (open + 1)..<close
        let next = close + 1
        guard next < chars.count else { return nil }

        if chars[next] == "(" {
            guard let end = matchingBracket(chars, from: next, open: "(", close: ")", budget: &budget) else {
                return nil
            }
            return ParsedLink(textRange: text, end: end + 1)
        }
        if chars[next] == "[" {
            guard let end = matchingBracket(chars, from: next, open: "[", close: "]", budget: &budget) else {
                return nil
            }
            return ParsedLink(textRange: text, end: end + 1)
        }
        return nil
    }

    private static func matchingBracket(
        _ chars: [Character],
        from open: Int,
        open openCharacter: Character,
        close closeCharacter: Character,
        budget: inout Int
    ) -> Int? {
        var depth = 0
        var cursor = open
        while cursor < chars.count {
            guard budget > 0 else { return nil }
            budget -= 1
            let character = chars[cursor]
            if character == "\\", cursor + 1 < chars.count {
                cursor += 2
                continue
            }
            if character == openCharacter {
                depth += 1
            } else if character == closeCharacter {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor += 1
        }
        return nil
    }

    private struct ParsedAutolink {
        let urlRange: Range<Int>
        let end: Int
    }

    /// `<https://example.com>` — angle brackets around a bare target. Anything with a
    /// space in it is not an autolink, which is what keeps `x < y and a > b` intact.
    private static func parseAutolink(_ chars: [Character], from open: Int) -> ParsedAutolink? {
        var cursor = open + 1
        while cursor < chars.count, chars[cursor] != ">" {
            if chars[cursor].isWhitespace || chars[cursor] == "<" { return nil }
            cursor += 1
        }
        guard cursor < chars.count, cursor > open + 1 else { return nil }
        let url = String(chars[(open + 1)..<cursor])
        guard url.contains("://") || url.hasPrefix("mailto:") || url.hasPrefix("www.") else { return nil }
        return ParsedAutolink(urlRange: (open + 1)..<cursor, end: cursor + 1)
    }

    // MARK: - Emphasis

    private struct ParsedSpan {
        let contentRange: Range<Int>
        let end: Int
    }

    /// A delimiter run opens a span only where prose opens one — at the start, after
    /// whitespace, or after an opening bracket or quote — and only when what follows it
    /// is not whitespace. It closes on the mirror of those rules.
    ///
    /// This is deliberately stricter than CommonMark, which allows `*` to open mid-word
    /// and after any punctuation. Under that reading `build/*.o and src/*.swift` is an
    /// emphasis and comes back as `build/.o and src/.swift` — a destroyed command, in a
    /// field the user is about to send. Models put their markers where prose puts them;
    /// globs, paths, identifiers, and `2 * 3 * 4` do not. Refusing those openers costs an
    /// italic nobody wrote and saves a filename everybody did.
    private static func parseDelimited(
        _ chars: [Character],
        from open: Int,
        marker: Character,
        minimumRun: Int,
        budget: inout Int
    ) -> ParsedSpan? {
        let run = min(runLength(chars, from: open, of: marker), 3)
        guard run >= minimumRun else { return nil }
        if marker == "~", run != 2 { return nil }

        guard canOpen(after: open > 0 ? chars[open - 1] : nil) else { return nil }
        let contentStart = open + run
        guard contentStart < chars.count, !chars[contentStart].isWhitespace else { return nil }

        var cursor = contentStart
        while cursor < chars.count {
            guard budget > 0 else { return nil }
            budget -= 1
            guard chars[cursor] == marker else {
                cursor += 1
                continue
            }
            let closeRun = runLength(chars, from: cursor, of: marker)
            guard closeRun >= run else {
                cursor += closeRun
                continue
            }
            guard !chars[cursor - 1].isWhitespace else {
                cursor += closeRun
                continue
            }
            let after = cursor + run
            guard canClose(before: after < chars.count ? chars[after] : nil) else {
                cursor += closeRun
                continue
            }
            let content = contentStart..<cursor
            // `__init__`, `__main__`: an underscore run around a bare identifier is far
            // more likely to be the identifier than emphasis of it.
            if marker == "_", run >= 2, chars[content].allSatisfy({ isWordCharacter($0) }) {
                return nil
            }
            return ParsedSpan(contentRange: content, end: after)
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Openers: start of line, whitespace, or an opening bracket / quote / dash.
    private static func canOpen(after character: Character?) -> Bool {
        guard let character else { return true }
        if character.isWhitespace { return true }
        return "([{<\"'\u{2018}\u{201C}\u{00AB}\u{2014}\u{2013}".contains(character)
    }

    /// Closers: end of line, whitespace, or the punctuation a sentence closes on.
    private static func canClose(before character: Character?) -> Bool {
        guard let character else { return true }
        if character.isWhitespace { return true }
        return ")]}>,.;:!?\"'\u{2019}\u{201D}\u{00BB}\u{2014}\u{2013}".contains(character)
    }
}
