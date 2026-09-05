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
    
    public enum OmissionReason: String, Error, Equatable, Sendable {
        case textBudget, tokenBudget, matrixBudget, cancelled
    }

    public enum Comparison: Equatable, Sendable {
        case compared([Segment])
        case omitted(OmissionReason)
    }

    public static let maximumTextUTF16 = 262_144
    public static let maximumTokens = 4096
    public static let maximumMatrixCells = 1_048_576

    /// Compatibility presentation: omitted comparisons show the complete cleaned text.
    /// Call `compare` when the caller needs to distinguish omission from a computed diff.
    public static func segments(verbatim: String, cleaned: String) -> [Segment] {
        switch compare(verbatim: verbatim, cleaned: cleaned) {
        case .compared(let segments): return segments
        case .omitted: return cleaned.isEmpty ? [] : [Segment(text: cleaned, isCut: false)]
        }
    }

    public static func compare(
        verbatim: String, cleaned: String, isCancelled: () -> Bool = { false }
    ) -> Comparison {
        guard !isCancelled() else { return .omitted(.cancelled) }
        guard verbatim.utf16.prefix(maximumTextUTF16 + 1).count <= maximumTextUTF16,
              cleaned.utf16.prefix(maximumTextUTF16 + 1).count <= maximumTextUTF16
        else { return .omitted(.textBudget) }
        let trimmedVerbatim = verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedVerbatim.isEmpty && trimmedCleaned.isEmpty { return .compared([]) }
        let saidTokens = tokenize(trimmedVerbatim)
        let keptTokens = tokenize(trimmedCleaned)
        guard saidTokens.count <= maximumTokens, keptTokens.count <= maximumTokens
        else { return .omitted(.tokenBudget) }
        if saidTokens.isEmpty { return .compared([Segment(text: trimmedCleaned, isCut: false)]) }
        if keptTokens.isEmpty { return .compared([Segment(text: trimmedVerbatim, isCut: true)]) }

        let flags: [Bool]
        switch lcsFlags(said: saidTokens, kept: keptTokens, isCancelled: isCancelled) {
        case .success(let result): flags = result
        case .failure(let reason): return .omitted(reason)
        }

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
            return .compared([Segment(text: trimmedCleaned, isCut: false)])
        }
        
        return .compared(result)
    }
    
    private static func tokenize(_ text: String) -> [String] {
        text.split(maxSplits: maximumTokens, whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    
    private static func normalizeToken(_ token: String) -> String {
        return token.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
    
    private static func lcsFlags(
        said: [String], kept: [String], isCancelled: () -> Bool
    ) -> Result<[Bool], OmissionReason> {
        let a = said.map(normalizeToken)
        let b = kept.map(normalizeToken)
        var flags = Array(repeating: false, count: a.count)
        var prefix = 0
        while prefix < min(a.count, b.count), !a[prefix].isEmpty, a[prefix] == b[prefix] {
            flags[prefix] = true
            prefix += 1
        }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              !a[a.count - 1 - suffix].isEmpty,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            flags[a.count - 1 - suffix] = true
            suffix += 1
        }
        let m = a.count - prefix - suffix
        let n = b.count - prefix - suffix
        guard !isCancelled() else { return .failure(.cancelled) }
        guard m > 0, n > 0 else { return .success(flags) }
        let width = n + 1
        guard m + 1 <= maximumMatrixCells / width else { return .failure(.matrixBudget) }
        // Token and cell budgets make both the allocation and multiplication bounded.
        var dp = Array(repeating: UInt16(0), count: (m + 1) * width)
        for i in 1...m {
            guard !isCancelled() else { return .failure(.cancelled) }
            for j in 1...n {
                if a[prefix + i - 1] == b[prefix + j - 1], !a[prefix + i - 1].isEmpty {
                    dp[i * width + j] = dp[(i - 1) * width + j - 1] + 1
                } else {
                    dp[i * width + j] = max(dp[(i - 1) * width + j], dp[i * width + j - 1])
                }
            }
        }
        var i = m
        var j = n
        while i > 0 && j > 0 {
            if a[prefix + i - 1] == b[prefix + j - 1], !a[prefix + i - 1].isEmpty {
                flags[prefix + i - 1] = true
                i -= 1
                j -= 1
            } else if dp[(i - 1) * width + j] > dp[i * width + j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return .success(flags)
    }
}
