// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// Side-effect-free preview renderer for the snippet editor.
public enum MacroPreview {

    public static func render(_ content: String, now: Date = Date()) -> String {
        let tokens = MacroParser.parse(content)
        var out = ""
        var i = 0

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
            }
            i += 1
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
