// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

public struct AbbreviationMatch: Equatable {
    public let snippet: SnippetModel
    /// Grapheme count for erase planning.
    public let backspaces: Int
    public let terminator: String
    /// Trigger keyword character count (without terminator).
    public let triggerLength: Int
    /// The trigger **exactly as the user typed it** (original casing, original code points).
    ///
    /// `snippet.triggerKeyword` is not a substitute: a case-insensitive snippet matches text whose
    /// casing differs, and comparing against the wrong string is how erase guards produce false
    /// negatives. This is what the injection pipeline verifies against the live field.
    public let matchedText: String

    public init(
        snippet: SnippetModel,
        backspaces: Int,
        terminator: String,
        triggerLength: Int,
        matchedText: String = ""
    ) {
        self.snippet = snippet
        self.backspaces = backspaces
        self.terminator = terminator
        self.triggerLength = triggerLength
        self.matchedText = matchedText.isEmpty ? snippet.triggerKeyword : matchedText
    }
}

/// Snapshot used by the expansion engine (read from the event-tap thread).
public struct AbbreviationMatcher {
    public let maxLength: Int
    /// trigger keyword (exact) -> snippet
    public let exact: [String: SnippetModel]
    /// lowercased trigger -> snippet, for case-insensitive snippets
    public let insensitive: [String: SnippetModel]

    public init(snippets: [SnippetModel]) {
        var exact: [String: SnippetModel] = [:]
        var insensitive: [String: SnippetModel] = [:]
        var maxLen = 0
        for snippet in snippets where snippet.enabled && !snippet.triggerKeyword.isEmpty {
            maxLen = max(maxLen, snippet.triggerKeyword.count)
            if snippet.isCaseSensitive {
                // First wins on exact collisions (stable earlier-list preference).
                if exact[snippet.triggerKeyword] == nil {
                    exact[snippet.triggerKeyword] = snippet
                }
            } else {
                let key = snippet.triggerKeyword.lowercased()
                if insensitive[key] == nil {
                    insensitive[key] = snippet
                }
            }
        }
        self.maxLength = maxLen
        self.exact = exact
        self.insensitive = insensitive
    }

    public init(maxLength: Int, exact: [String: SnippetModel], insensitive: [String: SnippetModel]) {
        self.maxLength = maxLength
        self.exact = exact
        self.insensitive = insensitive
    }

    /// Unicode word character: letter, number, or underscore.
    public static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private func lookup(_ chars: [Character], _ range: Range<Int>) -> SnippetModel? {
        let key = String(chars[range])
        return exact[key] ?? insensitive[key.lowercased()]
    }

    /// Finds the longest trigger at the buffer suffix that satisfies firing rules.
    public func match(buffer: String) -> AbbreviationMatch? {
        guard maxLength > 0, !buffer.isEmpty else { return nil }
        let chars = Array(buffer)
        let n = chars.count
        let upper = min(maxLength, n)

        for len in stride(from: upper, through: 1, by: -1) {
            // (1) Punctuation-started trigger — buffer ends with trigger → fire immediately.
            let start = n - len
            if let snippet = lookup(chars, start..<n),
               !Self.isWordCharacter(chars[start]) {
                return AbbreviationMatch(
                    snippet: snippet,
                    backspaces: len,
                    terminator: "",
                    triggerLength: len,
                    matchedText: String(chars[start..<n])
                )
            }

            // (2) Bare word + requireWordBoundary == false → instant suffix match (DevType legacy).
            if let snippet = lookup(chars, start..<n),
               Self.isWordCharacter(chars[start]),
               !snippet.requireWordBoundary {
                return AbbreviationMatch(
                    snippet: snippet,
                    backspaces: len,
                    terminator: "",
                    triggerLength: len,
                    matchedText: String(chars[start..<n])
                )
            }

            // (3) Bare word + requireWordBoundary → <boundary><trigger><terminator>.
            let abbrevEnd = n - 1
            let abbrevStart = abbrevEnd - len
            if abbrevStart >= 0,
               !Self.isWordCharacter(chars[abbrevEnd]),
               let snippet = lookup(chars, abbrevStart..<abbrevEnd),
               Self.isWordCharacter(chars[abbrevStart]),
               snippet.requireWordBoundary,
               abbrevStart == 0 || !Self.isWordCharacter(chars[abbrevStart - 1]) {
                let terminator = String(chars[abbrevEnd])
                return AbbreviationMatch(
                    snippet: snippet,
                    backspaces: len + terminator.count,
                    terminator: terminator,
                    triggerLength: len,
                    matchedText: String(chars[abbrevStart..<abbrevEnd])
                )
            }
        }
        return nil
    }
}
