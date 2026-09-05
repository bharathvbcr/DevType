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

    /// Final character of a trigger -> the trigger lengths that end with it, descending.
    ///
    /// `match` used to try *every* length from the longest trigger down to 1, building a fresh
    /// `String` for each and a second one via `lowercased()` whenever the case-sensitive table
    /// missed. That is up to three allocations per candidate length on every keystroke, inside
    /// the CGEventTap callback — measured at 63 µs per keystroke when the longest trigger is 64
    /// characters, and paid whether or not that trigger is anywhere near the buffer.
    ///
    /// A trigger can only match at the buffer suffix if its last character is the character the
    /// user just typed. Indexing on that collapses the common keystroke — the one that completes
    /// no trigger at all — to a single failed dictionary lookup.
    private let lengthsByFinalCharacter: [Character: [Int]]
    /// Same, restricted to triggers that require a word boundary: match rule (3) looks one
    /// character further back, because the character just typed is the terminator.
    private let boundaryLengthsByFinalCharacter: [Character: [Int]]

    /// Longest trigger the engine's fixed-capacity buffers can ever hold.
    /// Kept in sync with `EventTapEngine.maxBufferCapacity` / `LayoutBuffer.defaultMaxCount`.
    public static let matchableTriggerLimit = 64

    /// Keys a trigger is filed under: its final character, and the final character of its
    /// lowercased form.
    ///
    /// Both, because `lookup` folds the whole key with `lowercased()` and Unicode's default
    /// case conversion is not always character-by-character — Greek final sigma is the case
    /// that bites: `"ΑΣ".lowercased()` ends in `ς` while `"Σ".lowercased()` is `σ`. Filing
    /// under both spellings and probing with both means the fold can never lose a match; the
    /// only cost of the extra key is a dictionary lookup that would have happened anyway.
    private static func indexKeys(forTrigger trigger: String) -> [Character] {
        guard let raw = trigger.last else { return [] }
        guard let folded = trigger.lowercased().last, folded != raw else { return [raw] }
        return [raw, folded]
    }

    /// Keys to probe for a character sitting in the buffer. Mirror of `indexKeys`.
    private static func probeKeys(for character: Character) -> (Character, Character?) {
        let lowered = String(character).lowercased()
        guard lowered.count == 1, let folded = lowered.first, folded != character else {
            return (character, nil)
        }
        return (character, folded)
    }

    /// Builds both length indices. Lengths are distinct and descending so `match` can keep
    /// visiting candidates longest-first without sorting on the keystroke path.
    private static func makeLengthIndices(
        _ triggers: [(trigger: String, requiresWordBoundary: Bool)]
    ) -> (all: [Character: [Int]], boundary: [Character: [Int]]) {
        var all: [Character: Set<Int>] = [:]
        var boundary: [Character: Set<Int>] = [:]
        for entry in triggers {
            let length = entry.trigger.count
            for key in indexKeys(forTrigger: entry.trigger) {
                all[key, default: []].insert(length)
                if entry.requiresWordBoundary {
                    boundary[key, default: []].insert(length)
                }
            }
        }
        return (
            all.mapValues { $0.sorted(by: >) },
            boundary.mapValues { $0.sorted(by: >) }
        )
    }

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
        let indices = Self.makeLengthIndices(
            snippets
                .filter { $0.enabled && !$0.triggerKeyword.isEmpty }
                .map { ($0.triggerKeyword, $0.requireWordBoundary) }
        )
        self.lengthsByFinalCharacter = indices.all
        self.boundaryLengthsByFinalCharacter = indices.boundary
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
        // This initializer is handed the tables directly, so the trigger a snippet is filed
        // under is the dictionary key rather than `snippet.triggerKeyword` — they can differ
        // (the insensitive table is keyed lowercased), and the index has to cover both or a
        // hand-built matcher would silently stop matching.
        var triggers: [(trigger: String, requiresWordBoundary: Bool)] = []
        for (key, snippet) in exact {
            triggers.append((key, snippet.requireWordBoundary))
            if key != snippet.triggerKeyword {
                triggers.append((snippet.triggerKeyword, snippet.requireWordBoundary))
            }
        }
        for (key, snippet) in insensitive {
            triggers.append((key, snippet.requireWordBoundary))
            if key != snippet.triggerKeyword {
                triggers.append((snippet.triggerKeyword, snippet.requireWordBoundary))
            }
        }
        let indices = Self.makeLengthIndices(triggers)
        self.lengthsByFinalCharacter = indices.all
        self.boundaryLengthsByFinalCharacter = indices.boundary
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

    /// Trigger lengths worth testing when a trigger would end at `character`, descending and
    /// capped at `atMost`.
    ///
    /// Returns the stored slice directly when nothing needs dropping, so the overwhelmingly
    /// common keystroke — one that ends no trigger at all — costs one or two dictionary
    /// lookups and no allocation.
    private func candidateLengths(
        endingAt character: Character,
        in index: [Character: [Int]],
        atMost limit: Int
    ) -> [Int] {
        guard limit > 0 else { return [] }
        let (raw, folded) = Self.probeKeys(for: character)
        let primary = index[raw]
        let secondary = folded.flatMap { index[$0] }

        func capped(_ lengths: [Int]) -> ArraySlice<Int> {
            // Descending, so everything too long sits at the front.
            var start = lengths.startIndex
            while start < lengths.endIndex && lengths[start] > limit { start += 1 }
            return lengths[start...]
        }

        switch (primary, secondary) {
        case (nil, nil):
            return []
        case let (lengths?, nil), let (nil, lengths?):
            let slice = capped(lengths)
            return slice.count == lengths.count ? lengths : Array(slice)
        case let (first?, second?):
            // Two spellings of the same final character (Greek final sigma and friends). Merge
            // descending and drop duplicates so the caller still sees each length once.
            var merged: [Int] = []
            merged.reserveCapacity(first.count + second.count)
            var i = capped(first).startIndex, j = capped(second).startIndex
            while i < first.endIndex || j < second.endIndex {
                let a = i < first.endIndex ? first[i] : Int.min
                let b = j < second.endIndex ? second[j] : Int.min
                let next = Swift.max(a, b)
                if a == next { i += 1 }
                if b == next { j += 1 }
                merged.append(next)
            }
            return merged
        }
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

        // Only lengths whose trigger could end at the buffer's last character are worth a
        // `String`. Rules (1) and (2) end the trigger on the character just typed; rule (3)
        // treats that character as the terminator and ends the trigger one earlier.
        let suffixLengths = candidateLengths(
            endingAt: chars[n - 1],
            in: lengthsByFinalCharacter,
            atMost: upper
        )
        let boundaryLengths = n >= 2
            ? candidateLengths(
                endingAt: chars[n - 2],
                in: boundaryLengthsByFinalCharacter,
                atMost: min(maxLength, n - 1)
            )
            : []
        if suffixLengths.isEmpty && boundaryLengths.isEmpty { return nil }

        // Merge both descending lists so candidates are still visited longest-first — a rule (3)
        // match of length L must keep beating a rule (1)/(2) match of length L-1, exactly as it
        // did when a single loop walked every length.
        var suffixCursor = 0
        var boundaryCursor = 0
        while suffixCursor < suffixLengths.count || boundaryCursor < boundaryLengths.count {
            let suffixCandidate = suffixCursor < suffixLengths.count ? suffixLengths[suffixCursor] : Int.min
            let boundaryCandidate = boundaryCursor < boundaryLengths.count ? boundaryLengths[boundaryCursor] : Int.min
            let len = Swift.max(suffixCandidate, boundaryCandidate)
            let trySuffix = suffixCandidate == len
            let tryBoundary = boundaryCandidate == len
            if trySuffix { suffixCursor += 1 }
            if tryBoundary { boundaryCursor += 1 }

            let start = n - len
            // One key per iteration, shared by rules (1) and (2).
            if trySuffix {
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
            }

            // (3) Bare word + requireWordBoundary → <boundary><trigger><terminator>.
            // Cheap character predicates first so the dictionary lookup (and its String key) is
            // only paid for candidates that can actually match.
            let abbrevEnd = n - 1
            let abbrevStart = abbrevEnd - len
            if tryBoundary,
               abbrevStart >= 0,
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
