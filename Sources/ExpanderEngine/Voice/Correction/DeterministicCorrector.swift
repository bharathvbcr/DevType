import Foundation

public final class DeterministicCorrector: TranscriptCorrector, @unchecked Sendable {
    public static let providerID = "deterministic.local"
    public let descriptor: CorrectionProviderDescriptor

    public init() {
        self.descriptor = CorrectionProviderDescriptor(
            id: Self.providerID,
            displayName: "Deterministic Rules (Instant)",
            modelVersion: "rules-v1",
            privacyRoute: .onDeviceOnly,
            supportsStructuredOutput: false
        )
    }

    public func probe() async -> ProviderReadiness {
        let evidence = ProviderEvidence(
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            probeTimestamp: Date(),
            capabilities: ["spokenPunctuation", "disfluencyRemoval", "selfCorrection", "zeroLatency"]
        )
        return .ready(evidence)
    }

    public func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        let startTime = Date()
        var text = request.rawTranscript

        // 1. Spoken self-correction ("Tuesday, sorry, Thursday" → "Thursday").
        //
        // The marker must be punctuation-delimited. Without that requirement the same
        // words destroy ordinary sentences: "what I mean about the parser" loses its
        // subject, "there is no wait time" loses its verb. Punctuation is what actually
        // distinguishes a spoken retraction from the words used in a normal clause.
        if request.policy.allowFalseStartRemoval {
            let retraction = #"\b[\w'-]+\s*(?:,|--|—)\s*(?:sorry|no wait|i mean|scratch that|make that)\s*(?:,|--|—)?\s*"#
            if let regex = try? NSRegularExpression(pattern: retraction, options: [.caseInsensitive]) {
                text = regex.stringByReplacingMatches(
                    in: text, options: [],
                    range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: ""
                )
            }
        }

        // 2. Hesitation sounds.
        //
        // Matched case-**sensitively** against their lowercase forms. "er" is a hesitation;
        // "ER" is a hospital and "Er" may open a sentence. Case is the only signal available
        // without a language model, so acronyms are preserved by construction rather than by
        // an exception list that would inevitably be incomplete.
        //
        // Multi-word discourse markers ("you know", "I mean") are deliberately absent: they
        // are filler only when set off by commas, which is handled separately below.
        if request.policy.allowDisfluencyRemoval {
            let hesitation = #"\b(um|umm|uh|uhh|er|err|erm|ah|ahh|hmm|mm|mhm)\b[\s,]*"#
            if let regex = try? NSRegularExpression(pattern: hesitation, options: []) {
                text = regex.stringByReplacingMatches(
                    in: text, options: [],
                    range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: ""
                )
            }

            // Sentence-initial hesitations are capitalised by the recognizer.
            let leading = #"^(Um|Umm|Uh|Uhh|Er|Err|Erm|Ah|Ahh|Hmm|Mm|Mhm)\b[\s,]*"#
            if let regex = try? NSRegularExpression(pattern: leading, options: []) {
                text = regex.stringByReplacingMatches(
                    in: text, options: [],
                    range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: ""
                )
            }

            // Non-English hesitations. Only forms that cannot be ordinary words are listed.
            //
            // Korean 그 ("that"), 저 ("I"/"that") and 어 are all real words in normal use, and
            // Japanese あの without the prolonged mark means "that" — stripping any of them
            // unconditionally destroys sentences the same way stripping "like" does in
            // English. Only unambiguous hesitation forms are removed.
            let multilingual = #"(?:음|으음|에엥|えーと|えっと|うーん|あのー|あの〜)[\s、,]*"#
            if let regex = try? NSRegularExpression(pattern: multilingual, options: []) {
                text = regex.stringByReplacingMatches(
                    in: text, options: [],
                    range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: ""
                )
            }

            // Comma-delimited discourse filler: "the result, you know, was fine".
            let parenthetical = #"\s*(?:,|--|—)\s*(?:you know|i mean|sort of|kind of)\s*(?:,|--|—)\s*"#
            if let regex = try? NSRegularExpression(pattern: parenthetical, options: [.caseInsensitive]) {
                text = regex.stringByReplacingMatches(
                    in: text, options: [],
                    range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: ", "
                )
            }
        }

        // 3. Spoken punctuation
        if request.policy.allowSpokenPunctuation {
            let replacements: [(String, String)] = [
                (#"\s*\bperiod\b"#, "."),
                (#"\s*\bcomma\b"#, ","),
                (#"\s*\bquestion mark\b"#, "?"),
                (#"\s*\bexclamation mark\b"#, "!"),
                (#"\s*\bcolon\b"#, ":"),
                (#"\s*\bsemicolon\b"#, ";"),
                (#"\s*\bnew line\b"#, "\n"),
                (#"\s*\bnew paragraph\b"#, "\n\n"),
                (#"\s*\bopen parenthesis\b"#, " ("),
                (#"\s*\bclose parenthesis\b"#, ") "),
                (#"\s*\bopen quote\b"#, " \""),
                (#"\s*\bclose quote\b"#, "\" ")
            ]
            for (pattern, repl) in replacements {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    text = regex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: repl)
                }
            }
        }

        // 4. Clean up whitespace (preserve newlines)
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+([.,!?:;])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 5. Capitalize first letter of lines
        var formattedLines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let capitalized = String(trimmed.prefix(1)).uppercased() + String(trimmed.dropFirst())
                formattedLines.append(capitalized)
            } else {
                formattedLines.append("")
            }
        }
        text = formattedLines.joined(separator: "\n")

        let latency = Date().timeIntervalSince(startTime) * 1000
        return CorrectionCandidate(
            text: text,
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            edits: [],
            latencyMs: latency,
            promptVersion: "1.0",
            refusalDetected: false
        )
    }

    public func cancel(sessionID: VoiceSessionID) async {}
}
