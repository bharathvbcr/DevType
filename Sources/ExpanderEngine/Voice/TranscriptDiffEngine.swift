import Foundation

/// Engine to generate diff segments between verbatim transcript and cleaned transcript.
public enum TranscriptDiffEngine {
    
    /// A segment in the diff.
    public struct Segment: Equatable, Sendable {
        /// The text of the segment.
        public let text: String
        /// Whether the text was cut from the original transcript.
        public let isCut: Bool
        
        public init(text: String, isCut: Bool) {
            self.text = text
            self.isCut = isCut
        }
    }
    
    /// Generates segments highlighting differences between verbatim and cleaned texts.
    public static func segments(verbatim: String, cleaned: String) -> [Segment] {
        let trimmedVerbatim = verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedVerbatim.isEmpty && trimmedCleaned.isEmpty { return [] }
        
        let saidTokens = tokenize(trimmedVerbatim)
        let keptTokens = tokenize(trimmedCleaned)
        
        if saidTokens.isEmpty {
            return [Segment(text: trimmedCleaned, isCut: false)]
        }
        if keptTokens.isEmpty {
            return [Segment(text: trimmedVerbatim, isCut: true)]
        }
        
        let flags = lcsFlags(said: saidTokens, kept: keptTokens)
        
        var result: [Segment] = []
        var currentTokens: [String] = []
        var currentCut: Bool? = nil
        
        for (i, token) in saidTokens.enumerated() {
            let isKept = flags[i]
            let isCut = !isKept
            
            if let current = currentCut {
                if current == isCut {
                    currentTokens.append(token)
                } else {
                    result.append(Segment(text: currentTokens.joined(separator: " "), isCut: current))
                    currentTokens = [token]
                    currentCut = isCut
                }
            } else {
                currentTokens = [token]
                currentCut = isCut
            }
        }
        
        if let current = currentCut, !currentTokens.isEmpty {
            result.append(Segment(text: currentTokens.joined(separator: " "), isCut: current))
        }
        
        // If there's no overlap at all based on the flags, just return the cleaned text
        if !flags.contains(true) {
            return [Segment(text: trimmedCleaned, isCut: false)]
        }
        
        return result
    }
    
    private static func tokenize(_ text: String) -> [String] {
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }
    
    private static func normalizeToken(_ token: String) -> String {
        return token.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
    
    private static func lcsFlags(said: [String], kept: [String]) -> [Bool] {
        let m = said.count
        let n = kept.count
        guard m > 0 && n > 0 else { return Array(repeating: false, count: m) }
        
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        
        let saidNormalized = said.map(normalizeToken)
        let keptNormalized = kept.map(normalizeToken)
        
        for i in 1...m {
            for j in 1...n {
                if saidNormalized[i - 1] == keptNormalized[j - 1] && !saidNormalized[i - 1].isEmpty {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        
        var flags = Array(repeating: false, count: m)
        var i = m
        var j = n
        
        while i > 0 && j > 0 {
            if saidNormalized[i - 1] == keptNormalized[j - 1] && !saidNormalized[i - 1].isEmpty {
                flags[i - 1] = true
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        
        return flags
    }
}
