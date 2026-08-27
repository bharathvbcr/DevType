import Foundation

/// An edit operation calculated by `VoiceProgressiveTypingEngine` to transition the document
/// from the current live-injected text state to the target transcript state.
public struct VoiceTypingDiff: Equatable, Sendable {
    /// Number of characters (grapheme clusters) to erase from the end of the currently live-injected text.
    /// Invariant: `0 <= eraseCount <= currentInjectedLength`.
    public let eraseCount: Int

    /// Text to append/inject at the current insertion point after erasing `eraseCount` characters.
    public let textToInject: String

    /// The new total string that will be present in the document after applying this diff.
    public let resultingText: String

    public init(eraseCount: Int, textToInject: String, resultingText: String) {
        self.eraseCount = eraseCount
        self.textToInject = textToInject
        self.resultingText = resultingText
    }
}

/// A differential progressive typing engine for Smart Dictation.
///
/// Computes non-destructive, minimal edit operations (Longest Common Prefix diffing)
/// between in-flight live injected text and incoming speech recognition partials/utterances.
///
/// Guarantees:
/// 1. Earlier sentences and speech are strictly preserved across pauses and new utterances.
/// 2. Erase counts are mathematically bounded by `currentInjectedText.count` (cannot touch pre-existing document text).
/// 3. Common prefixes are never erased or re-typed, eliminating screen flicker and backspace spam.
/// 4. Unicode grapheme clusters and emojis are preserved intact.
public enum VoiceProgressiveTypingEngine: Sendable {

    /// Computes the minimal, safe non-destructive diff between what has been live-injected so far
    /// (`currentInjectedText`) and the new target transcript (`targetTranscript`).
    public static func computeDiff(
        currentInjectedText: String,
        targetTranscript: String
    ) -> VoiceTypingDiff {
        // Fast path 1: Exactly identical text (no-op)
        if currentInjectedText == targetTranscript {
            return VoiceTypingDiff(
                eraseCount: 0,
                textToInject: "",
                resultingText: currentInjectedText
            )
        }

        // Fast path 2: Initial injection from empty state
        if currentInjectedText.isEmpty {
            return VoiceTypingDiff(
                eraseCount: 0,
                textToInject: targetTranscript,
                resultingText: targetTranscript
            )
        }

        // Fast path 3: Complete cancellation / clear
        if targetTranscript.isEmpty {
            return VoiceTypingDiff(
                eraseCount: currentInjectedText.count,
                textToInject: "",
                resultingText: ""
            )
        }

        // Fast path 4: Pure monotonic extension (starts with current)
        if targetTranscript.hasPrefix(currentInjectedText) {
            let suffix = String(targetTranscript.dropFirst(currentInjectedText.count))
            return VoiceTypingDiff(
                eraseCount: 0,
                textToInject: suffix,
                resultingText: targetTranscript
            )
        }

        // General path: Longest Common Prefix (LCP) calculation
        let lcpCount = longestCommonPrefixCount(currentInjectedText, targetTranscript)
        let eraseCount = max(0, currentInjectedText.count - lcpCount)
        let textToInject = String(targetTranscript.dropFirst(lcpCount))

        return VoiceTypingDiff(
            eraseCount: eraseCount,
            textToInject: textToInject,
            resultingText: targetTranscript
        )
    }

    /// Computes the number of matching Unicode Characters (grapheme clusters) at the start of both strings.
    public static func longestCommonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var iterA = a.makeIterator()
        var iterB = b.makeIterator()

        while let charA = iterA.next(), let charB = iterB.next(), charA == charB {
            count += 1
        }

        return count
    }

    /// Combines previously committed utterances and the current active in-flight partial
    /// into a coherent, cumulative session transcript with appropriate spacing.
    public static func combineUtterances(
        committed: [String],
        activePartial: String
    ) -> String {
        let cleanCommitted = committed
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cleanPartial = activePartial.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleanCommitted.isEmpty {
            return cleanPartial
        }

        var result = ""
        for (index, segment) in cleanCommitted.enumerated() {
            if index == 0 {
                result = segment
            } else {
                result = appendSegment(result, next: segment)
            }
        }

        if !cleanPartial.isEmpty {
            result = appendSegment(result, next: cleanPartial)
        }

        return result
    }

    private static func appendSegment(_ base: String, next: String) -> String {
        guard !next.isEmpty else { return base }
        guard !base.isEmpty else { return next }

        if base.hasSuffix(" ") || base.hasSuffix("\n") || next.hasPrefix(" ") || next.hasPrefix("\n") {
            return base + next
        }

        return base + " " + next
    }
}
