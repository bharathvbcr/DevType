import AppKit
import Carbon.HIToolbox
import ExpanderEngine

// MARK: - Snippet row cell

/// One-line preview of a replacement. Stops at the first newline or at `limit` characters so a
/// multi-megabyte body is not scanned once per visible row. The row tooltip still has the full text.
enum SnippetOneLinePreview {
    static func text(_ body: String, limit: Int = 160) -> String {
        guard limit > 0, !body.isEmpty else { return "" }
        var out = ""
        out.reserveCapacity(min(limit + 2, 162))
        var seen = 0
        for character in body {
            if character == "\n" || character == "\r" {
                if !out.isEmpty { out += " ↵" }
                return out
            }
            if seen >= limit { return out }
            out.append(character)
            seen += 1
        }
        return out
    }
}
