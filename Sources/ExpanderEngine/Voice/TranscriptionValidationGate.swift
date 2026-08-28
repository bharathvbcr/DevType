import Foundation

/// Gate for validating that LLM-cleaned text is not a hallucination, garbage, or artifact.
public enum TranscriptionValidationGate {
    
    /// The verdict of the validation.
    public struct Verdict: Equatable, Sendable {
        /// Whether the text was accepted.
        public let accepted: Bool
        /// The reason for rejection, if any.
        public let reason: String?
        
        /// An accepted verdict.
        public static let ok = Verdict(accepted: true, reason: nil)
        
        /// A failed verdict with a reason.
        public static func fail(_ reason: String) -> Verdict {
            return Verdict(accepted: false, reason: reason)
        }
    }
    
    public static let minLengthRatio = 0.20
    public static let maxLengthRatio = 1.60
    public static let minCleanedContainmentInRaw = 0.70
    public static let minTrigramSimilarity = 0.35
    
    /// Strips artifacts such as code fences, reasoning `<think>`/`<thought>` blocks, 'CLEAN:'/'Transcript:' labels, and wrapping quotes.
    public static func stripArtifacts(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Strip reasoning tags (DeepSeek R1, Qwen reasoning models)
        let reasoningPatterns = [
            "<think>[\\s\\S]*?</think>",
            "<thought>[\\s\\S]*?</thought>",
            "\\[think\\][\\s\\S]*?\\[/think\\]"
        ]
        for pattern in reasoningPatterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        
        // Remove code block markers
        if result.hasPrefix("```") {
            if let firstNewline = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: firstNewline)...])
            }
        }
        if result.hasSuffix("```") {
            if let lastNewline = result.lastIndex(of: "\n") {
                result = String(result[..<lastNewline])
            } else {
                result = String(result.dropLast(3))
            }
        }
        
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let prefixesToRemove = ["CLEAN:", "Clean:", "Transcript:", "TRANSCRIPT:", "Output:", "OUTPUT:"]
        for prefix in prefixesToRemove {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count >= 2 {
            result = String(result.dropFirst().dropLast())
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Validates the cleaned text against the raw text.
    public static func validate(raw: String, cleaned: String) -> Verdict {
        if raw.isEmpty && cleaned.isEmpty { return .ok }
        if raw.isEmpty { return .fail("Raw text is empty but cleaned is not") }
        if cleaned.isEmpty { return .fail("Cleaned text is empty but raw is not") }
        
        let strippedCleaned = stripArtifacts(cleaned)
        if strippedCleaned.isEmpty { return .fail("Cleaned text is empty after stripping artifacts") }
        
        let lengthRatio = Double(strippedCleaned.count) / Double(raw.count)
        if lengthRatio < minLengthRatio || lengthRatio > maxLengthRatio {
            return .fail("Length ratio \(String(format: "%.2f", lengthRatio)) outside bounds [\(minLengthRatio), \(maxLengthRatio)]")
        }
        
        // Check that the cleaned words actually come from the raw transcript (defends against hallucinations and answering questions)
        let cleanedContainment = cleanedWordContainmentInRaw(raw: raw, cleaned: strippedCleaned)
        if cleanedContainment < minCleanedContainmentInRaw {
            return .fail("Cleaned word containment \(String(format: "%.2f", cleanedContainment)) below minimum \(minCleanedContainmentInRaw)")
        }
        
        // Short phrase fast path: if raw is short (e.g. "Yes", "OK", "Sure") and all cleaned words match raw, accept directly
        let rawNormalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawNormalized.count <= 12 && cleanedContainment >= 0.99 {
            return .ok
        }
        
        let similarity = trigramSimilarity(raw, strippedCleaned)
        if similarity < minTrigramSimilarity {
            return .fail("Trigram similarity \(String(format: "%.2f", similarity)) below minimum \(minTrigramSimilarity)")
        }
        
        return .ok
    }
    
    /// Measures what fraction of words in `cleaned` were present in `raw`.
    /// High score means the model edited/trimmed existing words rather than inventing new content.
    private static func cleanedWordContainmentInRaw(raw: String, cleaned: String) -> Double {
        let normalizeWord: (String) -> String = { word in
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        
        let rawWords = raw.components(separatedBy: .whitespacesAndNewlines).map(normalizeWord).filter { !$0.isEmpty }
        if rawWords.isEmpty { return 1.0 }
        let rawSet = Set(rawWords)
        
        let cleanedWords = cleaned.components(separatedBy: .whitespacesAndNewlines).map(normalizeWord).filter { !$0.isEmpty }
        if cleanedWords.isEmpty { return 1.0 }
        
        var foundCount = 0
        for word in cleanedWords {
            if rawSet.contains(word) {
                foundCount += 1
            }
        }
        
        return Double(foundCount) / Double(cleanedWords.count)
    }
    
    private static func trigramSimilarity(_ a: String, _ b: String) -> Double {
        let setA = trigrams(of: a.lowercased())
        let setB = trigrams(of: b.lowercased())
        
        if setA.isEmpty && setB.isEmpty { return 1.0 }
        if setA.isEmpty || setB.isEmpty { return 0.0 }
        
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        
        return Double(intersection) / Double(union)
    }
    
    private static func trigrams(of text: String) -> Set<String> {
        let clean = text.filter { $0.isLetter || $0.isNumber }
        let chars = Array(clean)
        if chars.count < 3 { return [] }
        
        var result = Set<String>()
        for i in 0...(chars.count - 3) {
            let trigram = String(chars[i...(i + 2)])
            result.insert(trigram)
        }
        return result
    }
}
