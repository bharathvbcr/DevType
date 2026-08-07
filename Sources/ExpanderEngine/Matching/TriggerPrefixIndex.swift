import Foundation

/// Which triggers are ambiguous prefixes of longer ones, and whether a buffer can still grow
/// into a longer trigger.
///
/// `AbbreviationMatcher` fires the longest trigger available *at this instant*. That is not the
/// longest trigger the user is *in the middle of typing*: after `` `slm `` the buffer holds
/// exactly `` `slm ``, so `` `slm `` fires and `` `slmabout `` can never be reached.
///
/// This index lets the engine hold a match briefly — but only when holding could actually
/// change the outcome. A trigger no longer trigger extends fires with zero added latency, which
/// is the overwhelmingly common case (in the library that motivated this, 50 of 52 triggers).
///
/// Built once per library change inside `SnippetMatchSnapshot`, never on the keystroke path.
public struct TriggerPrefixIndex: Equatable, Sendable {

    /// Folded keys of triggers that are a strict prefix of at least one other enabled trigger
    /// **and** fire without a terminator. A trigger that waits for a terminator cannot shadow,
    /// so holding it would add latency for nothing.
    private let ambiguous: Set<String>
    /// Every folded trigger key, for viable-extension queries.
    private let allKeys: [String]
    /// Same keys as a set, for exact-completion queries.
    private let completeKeys: Set<String>
    /// Longest trigger, so extension scans can bail early.
    private let maxKeyLength: Int

    public init(snippets: [SnippetModel]) {
        var ambiguous: Set<String> = []
        var keys: [String] = []
        var longest = 0

        // Fold exactly as the matcher keys: case-insensitive triggers compare lowercased.
        var entries: [(key: String, firesWithoutTerminator: Bool)] = []
        for snippet in snippets where snippet.enabled && !snippet.triggerKeyword.isEmpty {
            let key = snippet.isCaseSensitive
                ? snippet.triggerKeyword
                : snippet.triggerKeyword.lowercased()
            let punctuationStarted = key.first.map { !AbbreviationMatcher.isWordCharacter($0) } ?? false
            entries.append((key, punctuationStarted || !snippet.requireWordBoundary))
            keys.append(key)
            longest = max(longest, key.count)
        }

        for entry in entries where entry.firesWithoutTerminator {
            for other in keys where other.count > entry.key.count && other.hasPrefix(entry.key) {
                ambiguous.insert(entry.key)
                break
            }
        }

        self.ambiguous = ambiguous
        self.allKeys = keys
        self.completeKeys = Set(keys)
        self.maxKeyLength = longest
    }

    /// True when this trigger is a strict prefix of a longer one, so firing it immediately
    /// would make that longer trigger unreachable.
    public func isAmbiguous(trigger: String, caseSensitive: Bool) -> Bool {
        ambiguous.contains(caseSensitive ? trigger : trigger.lowercased())
    }

    public var hasAnyAmbiguity: Bool { !ambiguous.isEmpty }

    /// True when at least one trigger *strictly* extends `text` — i.e. the user could still be
    /// mid-way through typing a longer trigger, so a held match should keep waiting.
    ///
    /// Compares case-insensitively: a case-sensitive trigger may still be the thing being typed,
    /// and waiting a moment longer is cheaper than firing the wrong trigger.
    public func hasViableExtension(after text: String) -> Bool {
        guard !text.isEmpty, text.count < maxKeyLength else { return false }
        let folded = text.lowercased()
        for key in allKeys where key.count > text.count {
            if key.lowercased().hasPrefix(folded) { return true }
        }
        return false
    }

    /// True when `text` **is** an enabled trigger, in full.
    ///
    /// The companion question to `hasViableExtension`, and the one it deliberately does not
    /// answer: `hasViableExtension` counts only *strictly longer* triggers, so text that has
    /// just spelled out a longer trigger exactly reads as a dead end. A held shorter trigger
    /// that fires on that answer fabricates `shorter + suffix` over text the user visibly typed
    /// as the longer trigger (`` `slm `` + `l` over `` `slml ``). Matches the same generous
    /// case folding as the extension scan: a false positive merely keeps a hold waiting, while
    /// a false negative fires the wrong trigger.
    public func isCompleteTrigger(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return completeKeys.contains(text) || completeKeys.contains(text.lowercased())
    }
}
