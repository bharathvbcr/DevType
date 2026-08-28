import Foundation

public final class DeterministicCorrector: TranscriptCorrector, @unchecked Sendable {
    public let descriptor: CorrectionProviderDescriptor

    public init() {
        self.descriptor = CorrectionProviderDescriptor(
            id: "deterministic.local",
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

        // 1. Self-Correction Removal (e.g. "Tuesday -- sorry, Thursday")
        if request.policy.allowFalseStartRemoval {
            let selfCorrectionPatterns = [
                #"\b[a-zA-Z0-9]+\s*(?:,\s*sorry|\s*--\s*sorry|\s+no\s+wait|\s+I\s+mean)[,\s]+"#
            ]
            for pattern in selfCorrectionPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    text = regex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
                }
            }
        }

        // 2. Disfluency Removal
        if request.policy.allowDisfluencyRemoval {
            let disfluencyRegex = #"\b(um|uh|er|ah|hmm|you know)\b[\s,]*"#
            if let regex = try? NSRegularExpression(pattern: disfluencyRegex, options: [.caseInsensitive]) {
                text = regex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            }
        }

        // 3. Spoken Punctuation
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
