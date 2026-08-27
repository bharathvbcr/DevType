import Foundation

/// Smart dictation post-processing engine inspired by Google Gemini Jot.
/// Handles hesitation stripping, thought revisions / self-corrections, tone adaptation,
/// custom vocabulary dictionaries, and code-identifier formatting.
public enum SmartDictationEngine: Sendable {

    // MARK: - Main Pipeline

    /// Processes raw speech transcript into clean, formatted text according to chosen tone and settings.
    public static func process(
        rawTranscript: String,
        tone: DictationTone = .natural,
        customDictionary: [String: String] = [:],
        removeDisfluencies: Bool = true,
        autoPunctuate: Bool = true
    ) -> String {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // If the transcript contains no alphanumeric characters or meaningful speech, return empty string
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else {
            return ""
        }

        if tone == .verbatim {
            return trimmed
        }

        var text = trimmed

        // 1. Resolve thought revisions & spoken self-corrections (e.g. "at 1pm... actually 2pm" -> "at 2pm")
        text = resolveSelfCorrections(text)

        // 2. Remove filler words and disfluencies ("um", "uh", "er", "ah", "음", "えーと")
        if removeDisfluencies {
            text = filterDisfluencies(text)
        }

        // 3. Apply user custom dictionary / jargon replacements
        text = applyCustomDictionary(text, dictionary: customDictionary)

        // 4. Tone-specific formatting
        text = applyTone(text, tone: tone)

        // 5. Smart punctuation and capitalization
        if autoPunctuate && tone != .code {
            text = formatPunctuationAndCapitalization(text)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 1. Self-Correction & Thought Revision (Jot Inspiration)

    /// Resolves speech patterns where the user changes their mind mid-sentence in linear time without regex backtracking.
    public static func resolveSelfCorrections(_ input: String) -> String {
        var text = input
        guard !text.isEmpty, text.count <= 10_000 else { return input }

        let correctionMarkers = [
            "actually",
            "no wait",
            "or rather",
            "scratch that",
            "make that",
            "i mean",
            "sorry"
        ]

        for marker in correctionMarkers {
            guard let markerRange = text.range(of: marker, options: [.caseInsensitive, .backwards]) else {
                continue
            }

            let beforeSlice = text[..<markerRange.lowerBound]
            let afterSlice = text[markerRange.upperBound...]

            let before = String(beforeSlice).trimmingCharacters(in: .whitespacesAndNewlines)
            var after = String(afterSlice).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !before.isEmpty, !after.isEmpty else { continue }

            // Strip leading punctuation from after
            while after.hasPrefix(",") || after.hasPrefix(";") || after.hasPrefix(":") || after.hasPrefix(".") {
                after = String(after.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Strip trailing punctuation from before (... or ,)
            var cleanBefore = before
            while cleanBefore.hasSuffix(".") || cleanBefore.hasSuffix(",") || cleanBefore.hasSuffix(";") || cleanBefore.hasSuffix("-") {
                cleanBefore = String(cleanBefore.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let beforeWords = cleanBefore.split(separator: " ")
            let afterWords = after.split(separator: " ")

            if beforeWords.count > afterWords.count && afterWords.count <= 2 {
                let prefix = beforeWords.dropLast(afterWords.count).joined(separator: " ")
                text = "\(prefix) \(after)"
            } else {
                text = after
            }
        }

        return text
    }

    // MARK: - 2. Disfluency & Filler Stripping

    /// Strips standalone hesitation sounds and conversational filler pauses across English, Korean, and Japanese.
    public static func filterDisfluencies(_ input: String) -> String {
        var text = input

        // English filler words
        let englishFillers = ["um", "uh", "er", "ah", "hmm", "umm", "uhh", "err", "ahh", "like", "you know"]
        for filler in englishFillers {
            text = text.replacingOccurrences(of: "(?i),\\s*\\b\(filler)\\b\\s*,?", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "(?i)(?:^|\\s*)\\b\(filler)\\b[,\\s]*", with: " ", options: .regularExpression)
        }

        // Korean filler words
        let koreanFillers = ["음", "어", "그", "저", "저기", "있잖아"]
        for filler in koreanFillers {
            text = text.replacingOccurrences(of: "(?:^|\\s+)\(filler)[,\\s]+", with: " ", options: .regularExpression)
        }

        // Japanese filler words
        let japaneseFillers = ["えーと", "あの", "うーん", "その"]
        for filler in japaneseFillers {
            text = text.replacingOccurrences(of: "(?:^|\\s+)\(filler)[,\\s]+", with: " ", options: .regularExpression)
        }

        // Clean up orphan commas, multiple commas, and multiple spaces
        text = text.replacingOccurrences(of: "\\s+,", with: ",")
        text = text.replacingOccurrences(of: ",\\s*,+", with: ",")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        while text.hasPrefix(",") || text.hasPrefix(".") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Capitalize first character if needed
        if let first = text.first {
            text = String(first).uppercased() + text.dropFirst()
        }

        return text
    }

    // MARK: - 3. Custom Vocabulary & Jargon Dictionary

    /// Replaces phonetic spoken equivalents with customized acronyms and jargon.
    public static func applyCustomDictionary(_ input: String, dictionary: [String: String]) -> String {
        guard !dictionary.isEmpty else { return input }

        var output = input
        let sortedPairs = dictionary.sorted { $0.key.count > $1.key.count }

        for (spokenPhrase, replacement) in sortedPairs {
            let trimmedKey = spokenPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { continue }

            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: trimmedKey) + "\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(output.startIndex..<output.endIndex, in: output)
                output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
            }
        }

        return output
    }

    // MARK: - 4. Tone Adaptation

    public static func applyTone(_ input: String, tone: DictationTone) -> String {
        switch tone {
        case .natural, .verbatim:
            return input

        case .email:
            var text = formatPunctuationAndCapitalization(input)
            let emailPhrases: [(String, String)] = [
                ("hi ", "Hi "),
                ("hello ", "Hello "),
                ("dear ", "Dear "),
                ("thanks,", "Thanks,"),
                ("thank you,", "Thank you,"),
                ("best regards,", "Best regards,"),
                ("sincerely,", "Sincerely,"),
                ("let me know", "Let me know"),
                ("looking forward", "Looking forward")
            ]
            for (lower, formatted) in emailPhrases {
                if let range = text.range(of: lower, options: .caseInsensitive) {
                    text.replaceSubrange(range, with: formatted)
                }
            }
            return text

        case .chat:
            var text = formatPunctuationAndCapitalization(input)
            let chatMap = [
                "do not": "don't",
                "cannot": "can't",
                "will not": "won't",
                "are not": "aren't",
                "is not": "isn't"
            ]
            for (formal, contraction) in chatMap {
                text = text.replacingOccurrences(of: "\\b\(formal)\\b", with: contraction, options: [.regularExpression, .caseInsensitive])
            }
            return text

        case .code:
            return formatCodeIdentifiers(input)
        }
    }

    /// Translates verbal coding patterns into programming identifiers and syntax.
    public static func formatCodeIdentifiers(_ input: String) -> String {
        var text = input

        // Common symbols and operators
        let symbolReplacements: [(String, String)] = [
            ("dot json", ".json"),
            ("dot swift", ".swift"),
            ("dot js", ".js"),
            ("dot ts", ".ts"),
            ("dot py", ".py"),
            ("dot yaml", ".yaml"),
            ("dot yml", ".yml"),
            ("dot md", ".md"),
            ("dot sh", ".sh"),
            ("fat arrow", "=>"),
            ("arrow", "->"),
            ("triple equal", "==="),
            ("strict equal", "==="),
            ("strict not equal", "!=="),
            ("equal equal", "=="),
            ("not equal", "!="),
            ("greater than or equal", ">="),
            ("less than or equal", "<="),
            ("plus plus", "++"),
            ("minus minus", "--"),
            ("logical and", "&&"),
            ("logical or", "||"),
            ("double pipe", "||"),
            ("spread", "...")
        ]

        for (verbal, symbol) in symbolReplacements {
            text = text.replacingOccurrences(of: "\\b\(verbal)\\b", with: symbol, options: [.regularExpression, .caseInsensitive])
        }

        // Identifier transformations:
        // "screaming snake case <words>"
        text = transformIdentifierCase(in: text, prefix: "screaming snake case") { words in
            words.map { $0.uppercased() }.joined(separator: "_")
        }

        // "constant case <words>"
        text = transformIdentifierCase(in: text, prefix: "constant case") { words in
            words.map { $0.uppercased() }.joined(separator: "_")
        }

        // "camel case <words>"
        text = transformIdentifierCase(in: text, prefix: "camel case") { words in
            guard let first = words.first?.lowercased() else { return "" }
            let rest = words.dropFirst().map { $0.capitalized }
            return ([first] + rest).joined()
        }

        // "pascal case <words>"
        text = transformIdentifierCase(in: text, prefix: "pascal case") { words in
            words.map { $0.capitalized }.joined()
        }

        // "snake case <words>"
        text = transformIdentifierCase(in: text, prefix: "snake case") { words in
            words.map { $0.lowercased() }.joined(separator: "_")
        }

        // "kebab case <words>"
        text = transformIdentifierCase(in: text, prefix: "kebab case") { words in
            words.map { $0.lowercased() }.joined(separator: "-")
        }

        // Default conversion: if plain multi-words remain in code mode, convert to camelCase
        let words = text.split(separator: " ").map(String.init)
        if words.count > 1 && !text.contains("->") && !text.contains("==") && !text.contains("=>") {
            let first = words[0].lowercased()
            let rest = words.dropFirst().map { $0.capitalized }
            return ([first] + rest).joined()
        }

        return text
    }

    private static func transformIdentifierCase(
        in text: String,
        prefix: String,
        formatter: ([String]) -> String
    ) -> String {
        let pattern = "(?i)\\b\(prefix)\\s+([a-zA-Z0-9\\s]+?)(?:(?=[,\\.;:\\n])|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastIndex = 0

        for match in matches {
            let fullRange = match.range
            let wordsRange = match.range(at: 1)

            if fullRange.location > lastIndex {
                result += nsText.substring(with: NSRange(location: lastIndex, length: fullRange.location - lastIndex))
            }

            let capturedWords = nsText.substring(with: wordsRange)
                .split(separator: " ")
                .map(String.init)
            let formatted = formatter(capturedWords)
            result += formatted

            lastIndex = fullRange.location + fullRange.length
        }

        if lastIndex < nsText.length {
            result += nsText.substring(from: lastIndex)
        }

        return result
    }

    // MARK: - 5. Smart Punctuation & Capitalization

    public static func formatPunctuationAndCapitalization(_ input: String) -> String {
        var text = input

        // Capitalize standalone "i" and contractions
        text = text.replacingOccurrences(of: "\\bi\\b", with: "I", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\bi'm\\b", with: "I'm", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "\\bi'll\\b", with: "I'll", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "\\bi've\\b", with: "I've", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "\\bi'd\\b", with: "I'd", options: [.regularExpression, .caseInsensitive])

        // First letter capitalized
        if let first = text.first {
            text = String(first).uppercased() + text.dropFirst()
        }

        // Capitalize after period, question mark, exclamation mark
        let sentencePattern = "([\\.?!]\\s+)([a-z])"
        if let regex = try? NSRegularExpression(pattern: sentencePattern, options: []) {
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
            for match in matches.reversed() {
                let charRange = match.range(at: 2)
                if let swiftRange = Range(charRange, in: text) {
                    let upper = String(text[swiftRange]).uppercased()
                    text.replaceSubrange(swiftRange, with: upper)
                }
            }
        }

        // Ensure closing punctuation if sentence length >= 3 words
        let wordCount = text.split(separator: " ").count
        if wordCount >= 3, let last = text.last, !".?!,:;\"')]}".contains(last) {
            text.append(".")
        }

        return text
    }
}
