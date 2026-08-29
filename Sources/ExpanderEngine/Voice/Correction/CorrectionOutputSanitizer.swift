import Foundation

/// Strips the wrapper a language model puts around its answer, leaving the transcript.
///
/// Replaces two near-identical implementations (`TranscriptionValidationGate.stripArtifacts`
/// and `LocalLLMCleanupClient.sanitizeOutput`) that had drifted apart — one ran the
/// reasoning-tag pass twice by calling the other, and each knew a different set of
/// preambles. This is now the only one, and every model-backed corrector runs it.
///
/// Sanitising before validation matters: `CorrectionValidator` rejects a candidate that
/// still carries a fence or a preamble, which costs the user the whole correction. Most of
/// those rejections are recoverable — the transcript is right there behind the wrapper.
/// What must stay rejected is a model that *answered* the transcript instead of cleaning
/// it, and that is a judgement the validator makes on the sanitised text.
public enum CorrectionOutputSanitizer {

    /// Reasoning blocks emitted by models that think out loud (DeepSeek R1, Qwen, …).
    private static let reasoningPatterns = [
        "<think>[\\s\\S]*?</think>",
        "<thought>[\\s\\S]*?</thought>",
        "\\[think\\][\\s\\S]*?\\[/think\\]",
        "<reasoning>[\\s\\S]*?</reasoning>"
    ]

    /// Labels a model prepends when it narrates instead of answering. Longest first, so
    /// "Here is the cleaned text:" is matched before "Transcript:".
    private static let preambles = [
        "Here is the cleaned transcript:",
        "Here's the cleaned transcript:",
        "Here is the cleaned text:",
        "Here's the cleaned text:",
        "Sure! Here is the transcript:",
        "Cleaned transcript:",
        "Cleaned:",
        "Transcript:",
        "Output:",
        "Result:",
        "CLEAN:",
        "Clean:"
    ]

    /// - Parameters:
    ///   - text: the model's answer.
    ///   - original: the raw transcript it was asked to clean. Used only by the Markdown
    ///     pass, to leave alone any markup the speaker's own text already carried.
    ///   - markdown: how much Markdown may be taken off. Dictation is spoken, so a
    ///     heading or a bold marker in the result came from the model, not the speaker —
    ///     but the caller still owns the decision, because the user can turn the whole
    ///     behaviour off in Preferences.
    public static func sanitize(
        _ text: String,
        original: String = "",
        markdown: AIMarkdownPolicy = .strip
    ) -> String {
        // Unwrap, then take the Markdown off once, then unwrap again.
        //
        // Once, not inside the loop: the Markdown pass is idempotent everywhere except
        // over a fence it has already opened, where a second pass would read the code it
        // freed as prose and strip the underscores out of it. Running it between two
        // fixed-point unwrap passes still gets the case that motivated putting it in the
        // loop — a model answering `**Cleaned:** "hello"`, whose label the preamble pass
        // cannot see until the asterisks are gone — without ever running it twice.
        var result = unwrapping(text.trimmingCharacters(in: .whitespacesAndNewlines))
        result = AIMarkdownStripper.strip(result, policy: markdown, original: original)
        return unwrapping(result)
    }

    /// The wrapper passes, iterated to a fixed point.
    ///
    /// Wrappers nest — a model will answer `Result: ```…``` ` or `"Cleaned: …"` — and one
    /// pass in a fixed order only unwraps the outermost layer. Iterating makes the result
    /// independent of the order the model happened to stack them in, and makes this step
    /// idempotent, which matters because the correctors and the validator both run over
    /// this text.
    ///
    /// Bounded so a pathological input cannot spin: five layers is far more than any real
    /// model emits, and text that is still wrapped after that is left as-is for the
    /// validator to reject.
    private static func unwrapping(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for _ in 0..<5 {
            let before = result

            for pattern in reasoningPatterns {
                result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            result = strippingFence(result)
            result = strippingPreamble(result)
            result = strippingWrappingQuotes(result)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)

            if result == before { break }
        }

        return result
    }

    // MARK: - Steps

    /// Removes a surrounding ``` fence, with or without a language tag.
    private static func strippingFence(_ text: String) -> String {
        var result = text
        guard result.hasPrefix("```") else { return result }

        if let firstNewline = result.firstIndex(of: "\n") {
            result = String(result[result.index(after: firstNewline)...])
        } else {
            result = String(result.dropFirst(3))
        }

        if let closing = result.range(of: "```", options: .backwards) {
            result = String(result[..<closing.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes one leading label, case-insensitively.
    private static func strippingPreamble(_ text: String) -> String {
        for preamble in preambles {
            if text.lowercased().hasPrefix(preamble.lowercased()) {
                return String(text.dropFirst(preamble.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// Removes quotes wrapping the whole answer — but only when they wrap it. A transcript
    /// that legitimately opens and closes with quoted speech keeps them.
    private static func strippingWrappingQuotes(_ text: String) -> String {
        guard text.count >= 2 else { return text }

        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]
        guard let first = text.first, let last = text.last,
              pairs.contains(where: { $0.0 == first && $0.1 == last }) else { return text }

        let inner = String(text.dropFirst().dropLast())
        // If the interior still contains the same quote, the outer pair was part of the
        // sentence rather than a wrapper.
        guard !inner.contains(first) else { return text }
        return inner
    }
}
