// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// Side-effect-free preview renderer for the snippet editor.
///
/// §3.5: "side-effect-free" is load-bearing — this renders on every row of the manager list and
/// the inline search panel, so counters are *peeked*, never advanced, and random values render as
/// a placeholder instead of churning.
public enum MacroPreview {

    /// Longest preview the editor's one-line stage will ever be asked to lay out.
    ///
    /// The stage is a fixed-height strip showing "trigger → what it becomes". Handing it the whole
    /// replacement made the *window* grow: a single-line label's intrinsic width counts toward the
    /// content view's fitting size, and a borderless panel is sized from that — so typing a long
    /// replacement widened the editor as you went. Truncating at the source bounds the layout, and
    /// as a bonus stops the text system measuring a 50 KB string on every keystroke.
    public static let stagePreviewLimit = 160

    /// Preview text clamped for a single-line display, with an ellipsis when it was cut.
    ///
    /// Counts *characters*, not UTF-16 units, so a run of emoji cannot be sliced through a
    /// surrogate pair — and returns the input untouched when it already fits, so the common case
    /// allocates nothing.
    public static func clampedForStage(_ text: String, limit: Int = stagePreviewLimit) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// Characters the `%case:…%` transforms may rewrite across one preview.
    ///
    /// A case block re-transforms everything written since it opened, so k blocks over n
    /// characters of output is k·n work — and the blocks need not even be closed. That is legal,
    /// trivial to write, and fits easily inside the importer's 100,000-character replacement cap;
    /// measured on a 99,000-character snippet it was over two seconds. This function renders once
    /// per row of the inline search list and once per keystroke in the editor, on the main thread.
    ///
    /// Composing case transforms cannot be made cheaper without changing what they mean, so the
    /// ceiling is on the total instead. Past it the remaining blocks are left untransformed — a
    /// preview showing a block in the wrong case is still a preview; a two-second preview is a
    /// frozen window. Ordinary snippets are thousands of times under this.
    static let maximumCaseTransformCharacters = 200_000

    public static func render(_ content: String, now: Date = Date()) -> String {
        let tokens = MacroParser.parse(content)
        // Bracket-match every `%fillpart…% … %fillpartend%` pair in one linear
        // pass. The old code re-scanned the remaining tokens for each skipped
        // default-off start, so a template of N unterminated starts cost N²/2 —
        // perceptible lag in the editor preview, which runs on the main thread.
        var endsByStart: [Int: Int] = [:]
        var openStarts: [Int] = []
        for (index, token) in tokens.enumerated() {
            switch token {
            case .fillPartStart:
                openStarts.append(index)
            case .fillPartEnd:
                if let start = openStarts.popLast() { endsByStart[start] = index }
            default:
                break
            }
        }

        var out = ""
        // Tracked alongside `out` rather than recomputed. `out.count` walks the whole string, and
        // it was read once per `%case:…%` opened — the same k·n the transforms below cost.
        var outCount = 0
        var i = 0
        // §3.5: open `%case:…%` blocks as (transform, output length when the block opened).
        var caseStack: [(transform: TextCaseTransform, start: Int)] = []
        var caseBudget = maximumCaseTransformCharacters

        func emit(_ text: String) {
            guard !text.isEmpty else { return }
            out += text
            outCount += text.count
        }

        func applyCase(_ open: (transform: TextCaseTransform, start: Int)) {
            guard open.start <= outCount else { return }
            // A spent budget stops further re-casing; it never drops text. Everything the
            // snippet produces is still shown, just not transformed again.
            guard caseBudget > 0 else { return }
            caseBudget -= outCount - open.start
            let head = String(out.prefix(open.start))
            let body = String(out.dropFirst(open.start))
            out = head + open.transform.apply(to: body)
            // Re-read rather than assumed: a transform can change length — `ß` uppercases to `SS`.
            outCount = out.count
        }

        while i < tokens.count {
            let token = tokens[i]
            switch token {
            case .text(let s):
                emit(s)

            case .fillText(let name, let def), .fillArea(let name, let def):
                emit(def.isEmpty ? "(\(name))" : def)

            case .fillPopup(let name, let options, let def):
                if !def.isEmpty {
                    emit(def)
                } else if let first = options.first {
                    emit(first)
                } else {
                    emit("(\(name))")
                }

            case .fillPartStart(_, let defaultOn):
                if !defaultOn, let end = endsByStart[i] {
                    i = end + 1
                    continue
                }
                i += 1
                continue

            case .fillPartEnd:
                break

            case .snippet(let abbrev):
                emit("[\(abbrev)]")

            case .clipboard:
                emit("[clipboard]")

            case .key:
                break

            case .cursor:
                break

            case .date(let format):
                emit(formattedDate(format, now: now))

            case .uuid:
                emit("[uuid]")

            case .random:
                emit("[random]")

            case .counter(let name, _):
                // Peek only — previewing a snippet must never advance a live counter.
                emit(String(MacroCounterStore.shared.value(for: name)))

            case .caseStart(let transform):
                caseStack.append((transform: transform, start: outCount))

            case .caseEnd:
                if let open = caseStack.popLast() { applyCase(open) }
            }
            i += 1
        }

        // Unterminated blocks close here, innermost first — the same rule, and the same budget.
        while let open = caseStack.popLast() { applyCase(open) }
        return out
    }

    private static func formattedDate(_ format: String, now: Date) -> String {
        guard !format.isEmpty else { return format }
        let result = DateFormatLibrary.format(format, now: now)
        return result.isEmpty ? format : result
    }
}
