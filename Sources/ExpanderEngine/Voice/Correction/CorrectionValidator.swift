import Foundation

public enum CorrectionValidator {

    /// Case-folded words with punctuation removed. Used to decide whether two transcripts
    /// say the same thing, independent of how they are punctuated.
    static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static let refusalMarkers = [
        "as an ai", "i am an ai", "an ai", "ai model", "language model", "i cannot", "i am unable", "unable to",
        "i'm sorry", "sorry,", "cannot fulfill", "cannot transcribe",
        "here is the", "here's the", "certainly!", "sure!", "corrected text:", "transcription:"
    ]

    public static func validate(
        candidate: CorrectionCandidate,
        raw: RawTranscript,
        policy: CorrectionPolicy,
        protectedSpans: [ProtectedSpan]
    ) -> ValidationOutcome {
        let candidateText = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawText = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Non-empty check
        if candidateText.isEmpty {
            if rawText.isEmpty {
                return .accepted(metrics: ["exactMatch": 1.0])
            }
            return .fallbackToRaw(reason: .correctionRefusal)
        }

        // 2. Verbatim policy is enforced, not merely requested.
        //
        // The prompt asks a model for a verbatim result, but a model that rewrites anyway
        // must not be trusted — verbatim is the one mode where a "better" transcript is
        // exactly the wrong answer. Only whitespace may differ.
        if policy.tone == .exact {
            if Self.contentWords(candidateText) != Self.contentWords(rawText) {
                return .fallbackToRaw(reason: .correctionUnsupportedEdit)
            }
            return .accepted(metrics: ["exactMatch": 1.0])
        }

        // 3. Refusal / AI preamble / Markdown fence check
        let lower = candidateText.lowercased()
        for marker in refusalMarkers {
            if lower.hasPrefix(marker) || (lower.contains(marker) && !rawText.lowercased().contains(marker)) {
                return .fallbackToRaw(reason: .correctionRefusal)
            }
        }
        if candidateText.contains("```") || candidateText.hasPrefix("<think>") || candidateText.contains("</think>") {
            return .fallbackToRaw(reason: .correctionRefusal)
        }

        // 4. Protected Spans Invariant Check
        if policy.preserveProtectedSpans {
            for span in protectedSpans {
                let canonical = span.canonicalForm
                if !candidateText.localizedCaseInsensitiveContains(canonical) {
                    // Check if numeric formatting changed (e.g. "100 px" vs "100px" or "$ 50" vs "$50")
                    let strippedCanonical = canonical.filter { !$0.isWhitespace }
                    let strippedCandidate = candidateText.filter { !$0.isWhitespace }
                    if !strippedCandidate.localizedCaseInsensitiveContains(strippedCanonical) {
                        return .fallbackToRaw(reason: .correctionProtectedSpanAltered)
                    }
                }
            }
        }

        // 5. Token & Length Boundaries
        let rawTokens = rawText.split(whereSeparator: \.isWhitespace)
        let candidateTokens = candidateText.split(whereSeparator: \.isWhitespace)

        if rawTokens.isEmpty {
            return .accepted(metrics: ["tokenCount": Double(candidateTokens.count)])
        }

        let rawCount = Double(rawTokens.count)
        let candidateCount = Double(candidateTokens.count)

        let additionRatio = max(0.0, (candidateCount - rawCount) / rawCount)
        let deletionRatio = max(0.0, (rawCount - candidateCount) / rawCount)

        if additionRatio > policy.maxAdditionRatio {
            return .fallbackToRaw(reason: .correctionHallucination)
        }
        if deletionRatio > policy.maxDeletionRatio {
            return .fallbackToRaw(reason: .correctionUnsupportedEdit)
        }

        // 5. Accepted with metrics
        let metrics: [String: Double] = [
            "rawTokens": rawCount,
            "candidateTokens": candidateCount,
            "additionRatio": additionRatio,
            "deletionRatio": deletionRatio,
            "latencyMs": candidate.latencyMs
        ]

        return .accepted(metrics: metrics)
    }
}
