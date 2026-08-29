import Foundation

/// Decides whether a recognizer result continues the current utterance or begins a new one.
///
/// This exists because `SFSpeechRecognizer`, fed from an audio buffer, gives no signal at an
/// utterance boundary. Across a pause it keeps the same task, never reports `isFinal`, and
/// simply **replaces `bestTranscription.formattedString` with the new utterance** — the
/// previous one vanishes from its output. Captured from a live session:
///
///     rev=7   "What's the best way?"
///     rev=8   "To"                      ← same task, same result object, new utterance
///
/// Anything treating that string as cumulative sees the transcript shrink by twenty
/// characters and erases the document to match. The boundary has to be inferred, and this is
/// where that inference lives.
///
/// The rule compares **normalised characters**, not words. Word-level comparison looked
/// right and was not: the recognizer rewrites the head of a phrase mid-utterance, and
/// `"What is"` becoming `"What's the"` changes the first word while remaining the same
/// utterance. At character level, with case and punctuation stripped, `"whatis"` and
/// `"whatsthe"` still share `"what"` — while `"whatsthebestway"` and `"to"` share nothing.
///
/// So: two results belong to the same utterance when their normalised common prefix covers
/// a meaningful fraction of the shorter one. Erring toward "revision" is the safe direction
/// — a missed boundary costs a missing space between two sentences, while a false boundary
/// would seal text the recognizer is still editing.
public enum UtteranceBoundaryDetector {

    /// Minimum share of the shorter normalised string the common prefix must cover for the
    /// two results to count as the same utterance.
    ///
    /// A third is well below any real revision (re-casing keeps everything, head rewrites
    /// keep the first syllables) and well above a genuine restart, which typically shares
    /// nothing or a single incidental letter.
    static let minimumPrefixShare = 0.34

    /// Below this many normalised characters there is not enough signal to call a boundary,
    /// and a wrong call is costlier than a missed one.
    static let minimumComparableLength = 2

    /// Whether `current` starts a new utterance rather than revising `previous`.
    public static func isReset(previous: String, current: String) -> Bool {
        let old = normalized(previous)
        let new = normalized(current)

        guard old.count >= minimumComparableLength,
              new.count >= minimumComparableLength else { return false }

        let shared = commonPrefixLength(old, new)
        let shorter = Swift.min(old.count, new.count)
        return Double(shared) / Double(shorter) < minimumPrefixShare
    }

    /// Lowercased alphanumerics only. Case and punctuation are exactly what the recognizer
    /// revises, so they carry no information about whether the utterance changed.
    static func normalized(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func commonPrefixLength(_ a: [Character], _ b: [Character]) -> Int {
        var count = 0
        while count < a.count, count < b.count, a[count] == b[count] {
            count += 1
        }
        return count
    }
}
