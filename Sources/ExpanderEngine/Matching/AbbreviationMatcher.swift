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
///
/// §2.1: this is an immutable value type and is now built **once** per library revision
/// (see `SnippetMatchSnapshot`), never inside the tap callback.
public struct AbbreviationMatcher {
    public let maxLength: Int
    /// trigger keyword (exact) -> snippet
    public let exact: [String: SnippetModel]
    /// lowercased trigger -> snippet, for case-insensitive snippets
    public let insensitive: [String: SnippetModel]

    /// §4.4: additional snippets sharing a trigger, in library order. Only populated for keys
    /// that actually collide, so the common library carries no extra storage.
    private let exactVariants: [String: [SnippetModel]]
    private let insensitiveVariants: [String: [SnippetModel]]

    /// §4.4: `true` when any snippet declares `includeApps` / `excludeApps`. When `false` the
    /// matcher takes the original, allocation-identical lookup path and ignores `bundleID`.
    public let hasAppScopedSnippets: Bool

    /// §3.9: triggers longer than `matchableTriggerLimit`. The engine ring buffer and
    /// `LayoutBuffer` both cap at 64 characters, so these can *never* fire — and nothing used to
    /// say so. Surfaced through `EventTapEngine.overlongTriggerDiagnostics()`.
    public let overlongTriggers: [String]

    /// Longest trigger the engine's fixed-capacity buffers can ever hold.
    /// Kept in sync with `EventTapEngine.maxBufferCapacity` / `LayoutBuffer.defaultMaxCount`.
    public static let matchableTriggerLimit = 64

    public init(snippets: [SnippetModel]) {
        var exact: [String: SnippetModel] = [:]
        var insensitive: [String: SnippetModel] = [:]
        var exactVariants: [String: [SnippetModel]] = [:]
        var insensitiveVariants: [String: [SnippetModel]] = [:]
        var overlong: [String] = []
        var scoped = false
        var maxLen = 0
        for snippet in snippets where snippet.enabled && !snippet.triggerKeyword.isEmpty {
            let length = snippet.triggerKeyword.count
            maxLen = max(maxLen, length)
            if length > AbbreviationMatcher.matchableTriggerLimit {
                overlong.append(snippet.triggerKeyword)
            }
            if !snippet.includeApps.isEmpty || !snippet.excludeApps.isEmpty {
                scoped = true
            }
            if snippet.isCaseSensitive {
                // First wins on exact collisions (stable earlier-list preference).
                if exact[snippet.triggerKeyword] == nil {
                    exact[snippet.triggerKeyword] = snippet
                    exactVariants[snippet.triggerKeyword] = [snippet]
                } else {
                    exactVariants[snippet.triggerKeyword, default: []].append(snippet)
                }
            } else {
                let key = snippet.triggerKeyword.lowercased()
                if insensitive[key] == nil {
                    insensitive[key] = snippet
                    insensitiveVariants[key] = [snippet]
                } else {
                    insensitiveVariants[key, default: []].append(snippet)
                }
            }
        }
        self.maxLength = maxLen
        self.exact = exact
        self.insensitive = insensitive
        // Only keep the collision lists — single-entry buckets are answered from `exact` /
        // `insensitive` directly.
        self.exactVariants = exactVariants.filter { $0.value.count > 1 }
        self.insensitiveVariants = insensitiveVariants.filter { $0.value.count > 1 }
        self.hasAppScopedSnippets = scoped
        self.overlongTriggers = overlong
    }

    public init(maxLength: Int, exact: [String: SnippetModel], insensitive: [String: SnippetModel]) {
        let isScoped: (SnippetModel) -> Bool = { snippet in
            !snippet.includeApps.isEmpty || !snippet.excludeApps.isEmpty
        }
        let scopedExact = exact.values.contains(where: isScoped)
        let scopedInsensitive = insensitive.values.contains(where: isScoped)

        let limit = AbbreviationMatcher.matchableTriggerLimit
        var overlong: [String] = []
        for snippet in exact.values where snippet.triggerKeyword.count > limit {
            overlong.append(snippet.triggerKeyword)
        }
        for snippet in insensitive.values where snippet.triggerKeyword.count > limit {
            overlong.append(snippet.triggerKeyword)
        }

        self.maxLength = maxLength
        self.exact = exact
        self.insensitive = insensitive
        self.exactVariants = [:]
        self.insensitiveVariants = [:]
        self.hasAppScopedSnippets = scopedExact || scopedInsensitive
        self.overlongTriggers = overlong
    }

    /// Unicode word character: letter, number, or underscore.
    public static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// §2.3: single lookup taking an already-built key.
    ///
    /// The old signature took `([Character], Range<Int>)` and was called with the *identical*
    /// range two or three times per loop iteration, allocating a fresh `String` plus a fresh
    /// `lowercased()` copy every time — up to 6 allocations × 64 iterations per keystroke.
    /// Callers now build the key once per iteration and the lowercase copy is only made when the
    /// case-sensitive table misses.
    private func lookup(_ key: String, bundleID: String?) -> SnippetModel? {
        guard hasAppScopedSnippets else {
            if let snippet = exact[key] { return snippet }
            return insensitive[key.lowercased()]
        }
        return lookupAppScoped(key, bundleID: bundleID)
    }

    /// §4.4: same precedence as the fast path (exact before insensitive), but a snippet that does
    /// not apply to the frontmost app is skipped rather than shadowing the ones that do.
    private func lookupAppScoped(_ key: String, bundleID: String?) -> SnippetModel? {
        if let variants = exactVariants[key] {
            if let hit = variants.first(where: { $0.appliesTo(bundleID: bundleID) }) {
                return hit
            }
        } else if let snippet = exact[key], snippet.appliesTo(bundleID: bundleID) {
            return snippet
        }

        let lowered = key.lowercased()
        if let variants = insensitiveVariants[lowered] {
            if let hit = variants.first(where: { $0.appliesTo(bundleID: bundleID) }) {
                return hit
            }
        } else if let snippet = insensitive[lowered], snippet.appliesTo(bundleID: bundleID) {
            return snippet
        }
        return nil
    }

    /// Finds the longest trigger at the buffer suffix that satisfies firing rules.
    ///
    /// §2.3: this is the real implementation. It takes `[Character]` so the event-tap callback can
    /// hand over its ring buffer contents directly instead of building a `String` that this
    /// method would immediately convert back with `Array(buffer)`.
    ///
    /// §4.4: `bundleID` is the cached frontmost app. `nil` means "unknown", which only matches
    /// snippets that are not restricted to a specific app list.
    public func match(characters chars: [Character], bundleID: String? = nil) -> AbbreviationMatch? {
        guard maxLength > 0, !chars.isEmpty else { return nil }
        let n = chars.count
        let upper = min(maxLength, n)

        for len in stride(from: upper, through: 1, by: -1) {
            let start = n - len
            // One key per iteration, shared by rules (1) and (2).
            let suffixKey = String(chars[start..<n])
            if let snippet = lookup(suffixKey, bundleID: bundleID) {
                // (1) Punctuation-started trigger — buffer ends with trigger → fire immediately.
                if !Self.isWordCharacter(chars[start]) {
                    return AbbreviationMatch(
                        snippet: snippet,
                        backspaces: len,
                        terminator: "",
                        triggerLength: len,
                        matchedText: suffixKey
                    )
                }
                // (2) Bare word + requireWordBoundary == false → instant suffix match (DevType legacy).
                if !snippet.requireWordBoundary {
                    return AbbreviationMatch(
                        snippet: snippet,
                        backspaces: len,
                        terminator: "",
                        triggerLength: len,
                        matchedText: suffixKey
                    )
                }
            }

            // (3) Bare word + requireWordBoundary → <boundary><trigger><terminator>.
            // Cheap character predicates first so the dictionary lookup (and its String key) is
            // only paid for candidates that can actually match.
            let abbrevEnd = n - 1
            let abbrevStart = abbrevEnd - len
            if abbrevStart >= 0,
               !Self.isWordCharacter(chars[abbrevEnd]),
               Self.isWordCharacter(chars[abbrevStart]),
               abbrevStart == 0 || !Self.isWordCharacter(chars[abbrevStart - 1]) {
                let innerKey = String(chars[abbrevStart..<abbrevEnd])
                if let snippet = lookup(innerKey, bundleID: bundleID), snippet.requireWordBoundary {
                    let terminator = String(chars[abbrevEnd])
                    return AbbreviationMatch(
                        snippet: snippet,
                        backspaces: len + terminator.count,
                        terminator: terminator,
                        triggerLength: len,
                        matchedText: innerKey
                    )
                }
            }
        }
        return nil
    }

    /// String-based shim kept for existing callers and tests. Prefer `match(characters:)` on the
    /// keystroke path — this allocates an extra `[Character]` copy.
    public func match(buffer: String) -> AbbreviationMatch? {
        match(characters: Array(buffer), bundleID: nil)
    }

    /// String-based shim with §4.4 app scoping.
    public func match(buffer: String, bundleID: String?) -> AbbreviationMatch? {
        match(characters: Array(buffer), bundleID: bundleID)
    }
}
