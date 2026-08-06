// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// Side-effect-free preview renderer for the snippet editor.
///
/// §3.5: "side-effect-free" is load-bearing — this renders on every row of the manager list and
/// the inline search panel, so counters are *peeked*, never advanced, and random values render as
/// a placeholder instead of churning.
public enum MacroPreview {

    public static func render(_ content: String, now: Date = Date()) -> String {
        let tokens = MacroParser.parse(content)
        var out = ""
        var i = 0
        // §3.5: open `%case:…%` blocks as (transform, out.count when the block opened).
        var caseStack: [(transform: TextCaseTransform, start: Int)] = []

        while i < tokens.count {
            let token = tokens[i]
            switch token {
            case .text(let s):
                out += s

            case .fillText(let name, let def), .fillArea(let name, let def):
                out += def.isEmpty ? "(\(name))" : def

            case .fillPopup(let name, let options, let def):
                if !def.isEmpty {
                    out += def
                } else if let first = options.first {
                    out += first
                } else {
                    out += "(\(name))"
                }

            case .fillPartStart(_, let defaultOn):
                if defaultOn {
                    i += 1
                    continue
                }
                if let end = matchingEnd(after: i, in: tokens) {
                    i = end + 1
                    continue
                }
                i += 1
                continue

            case .fillPartEnd:
                break

            case .snippet(let abbrev):
                out += "[\(abbrev)]"

            case .clipboard:
                out += "[clipboard]"

            case .key:
                break

            case .cursor:
                break

            case .date(let format):
                out += formattedDate(format, now: now)

            case .uuid:
                out += "[uuid]"

            case .random:
                out += "[random]"

            case .counter(let name, _):
                // Peek only — previewing a snippet must never advance a live counter.
                out += String(MacroCounterStore.shared.value(for: name))

            case .caseStart(let transform):
                caseStack.append((transform: transform, start: out.count))

            case .caseEnd:
                if let open = caseStack.popLast(), open.start <= out.count {
                    let head = String(out.prefix(open.start))
                    let body = String(out.dropFirst(open.start))
                    out = head + open.transform.apply(to: body)
                }
            }
            i += 1
        }

        while let open = caseStack.popLast(), open.start <= out.count {
            let head = String(out.prefix(open.start))
            let body = String(out.dropFirst(open.start))
            out = head + open.transform.apply(to: body)
        }
        return out
    }

    private static func matchingEnd(after startIndex: Int, in tokens: [MacroToken]) -> Int? {
        var depth = 1
        var j = startIndex + 1
        while j < tokens.count {
            switch tokens[j] {
            case .fillPartStart:
                depth += 1
            case .fillPartEnd:
                depth -= 1
                if depth == 0 { return j }
            default:
                break
            }
            j += 1
        }
        return nil
    }

    private static func formattedDate(_ format: String, now: Date) -> String {
        guard !format.isEmpty else { return format }
        let result = DateFormatLibrary.format(format, now: now)
        return result.isEmpty ? format : result
    }
}
