import Foundation

public enum ProtectedSpanExtractor {
    public static func extract(from text: String, dictionaryTerms: [String] = []) -> [ProtectedSpan] {
        var spans: [ProtectedSpan] = []
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        // 1. URLs and Emails via NSDataDetector
        if let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = urlDetector.matches(in: text, options: [], range: fullRange)
            for match in matches {
                let matchText = nsString.substring(with: match.range)
                let isEmail = match.url?.scheme == "mailto" || (matchText.contains("@") && !matchText.contains("://"))
                let kind: ProtectedSpanKind = isEmail ? .email : .url
                let span = ProtectedSpan(
                    kind: kind,
                    originalText: matchText,
                    canonicalForm: matchText,
                    utf16RangeStart: match.range.location,
                    utf16RangeLength: match.range.length
                )
                spans.append(span)
            }
        }

        // 2. Regex Patterns
        let patterns: [(kind: ProtectedSpanKind, pattern: String)] = [
            (.email, #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}"#),
            (.filePath, #"(?:/[a-zA-Z0-9._-]+)+|~/[a-zA-Z0-9._/-]+"#),
            (.shellFlag, #"--[a-zA-Z0-9_-]+(?:=[^\s]+)?|-[a-zA-Z0-9]"#),
            (.versionNumber, #"\bv?\d+\.\d+(?:\.\d+)*(?:-[a-zA-Z0-9.]+)?\b"#),
            (.numberWithUnit, #"\b\d+(?:\.\d+)?\s*(?:px|ms|s|gb|mb|kb|tb|m|cm|mm|kg|g|%|\$|€|£)\b"#),
            (.currency, #"[\$€£¥]\s*\d+(?:\.\d{2})?"#)
        ]

        for (kind, pattern) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let matches = regex.matches(in: text, options: [], range: fullRange)
                for match in matches {
                    let matchText = nsString.substring(with: match.range)
                    // Check if already overlapped by an existing span
                    let isOverlapped = spans.contains { existing in
                        NSIntersectionRange(match.range, NSRange(location: existing.utf16RangeStart, length: existing.utf16RangeLength)).length > 0
                    }
                    if !isOverlapped {
                        let span = ProtectedSpan(
                            kind: kind,
                            originalText: matchText,
                            canonicalForm: matchText,
                            utf16RangeStart: match.range.location,
                            utf16RangeLength: match.range.length
                        )
                        spans.append(span)
                    }
                }
            }
        }

        // 3. Dictionary Terms
        for term in dictionaryTerms where !term.isEmpty {
            var searchRange = fullRange
            while searchRange.location < nsString.length {
                let foundRange = nsString.range(of: term, options: [.caseInsensitive], range: searchRange)
                if foundRange.location != NSNotFound {
                    let matchText = nsString.substring(with: foundRange)
                    let isOverlapped = spans.contains { existing in
                        NSIntersectionRange(foundRange, NSRange(location: existing.utf16RangeStart, length: existing.utf16RangeLength)).length > 0
                    }
                    if !isOverlapped {
                        let span = ProtectedSpan(
                            kind: .customDictionary,
                            originalText: matchText,
                            canonicalForm: term,
                            utf16RangeStart: foundRange.location,
                            utf16RangeLength: foundRange.length
                        )
                        spans.append(span)
                    }
                    let nextLoc = foundRange.location + foundRange.length
                    if nextLoc >= nsString.length { break }
                    searchRange = NSRange(location: nextLoc, length: nsString.length - nextLoc)
                } else {
                    break
                }
            }
        }

        // Sort by start location
        return spans.sorted { $0.utf16RangeStart < $1.utf16RangeStart }
    }
}
