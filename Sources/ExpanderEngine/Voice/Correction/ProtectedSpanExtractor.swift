import Foundation

public enum ProtectedSpanExtractor {
    /// UTF-16 code units. Past this, `extract` returns `[]` without calling
    /// `NSDataDetector` or `NSRegularExpression`. The pathological version-span
    /// prompt is about 4_000 units and must still be scanned; a longer run of
    /// email-local characters makes the ICU email pattern quadratic.
    public static let maximumUTF16Length = 32_768

    /// Compiled once: `extract` runs per final transcript and these never change.
    /// The email expression stays compiled here, but `extract` does not execute it.
    /// ICU retries `[A-Z0-9a-z._%+-]+` from every index when `@` is absent.
    /// `appendLinearEmailSpans` is the O(n) scan that replaces that match.
    static let patterns: [(kind: ProtectedSpanKind, regex: NSRegularExpression)] = [
        (.email, #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}"#),
        (.filePath, #"(?:/[a-zA-Z0-9._-]+)+|~/[a-zA-Z0-9._/-]+"#),
        (.shellFlag, #"--[a-zA-Z0-9_-]+(?:=[^\s]+)?|-[a-zA-Z0-9]"#),
        (.versionNumber, #"\bv?\d+\.\d+(?:\.\d+)*(?:-[a-zA-Z0-9.]+)?\b"#),
        (.numberWithUnit, #"\b\d+(?:\.\d+)?\s*(?:px|ms|s|gb|mb|kb|tb|m|cm|mm|kg|g|%|\$|€|£)\b"#),
        (.currency, #"[\$€£¥]\s*\d+(?:\.\d{2})?"#)
    ].compactMap { kind, pattern in
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (kind, $0) }
    }

    public static func extract(from text: String, dictionaryTerms: [String] = []) -> [ProtectedSpan] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        if nsString.length > maximumUTF16Length {
            return []
        }

        var spans: [ProtectedSpan] = []

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

        // 2. Email, then the other regex patterns. Email is a linear scan; the
        // compiled email expression is not matched.
        appendLinearEmailSpans(Array(text.utf16), nsString: nsString, to: &spans)
        for (kind, regex) in patterns where kind != .email {
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

    /// Same alphabet as the email pattern, in one forward pass.
    /// `@` is in neither the local nor the domain class, so each code unit is
    /// visited a constant number of times.
    private static func appendLinearEmailSpans(
        _ units: [UInt16],
        nsString: NSString,
        to spans: inout [ProtectedSpan]
    ) {
        var emailEnd = 0
        var index = 0
        while index < units.count {
            if units[index] != 64 { // '@'
                index += 1
                continue
            }
            var localStart = index
            while localStart > emailEnd && isEmailLocal(units[localStart - 1]) {
                localStart -= 1
            }
            if localStart == index {
                index += 1
                continue
            }
            var domainEnd = index + 1
            while domainEnd < units.count && isEmailDomain(units[domainEnd]) {
                domainEnd += 1
            }
            var dot = domainEnd - 1
            var matchedEnd: Int?
            while dot >= index + 2 {
                if units[dot] == 46 { // '.'
                    var tld = 0
                    var cursor = dot + 1
                    while cursor < domainEnd && tld < 64 && isEmailLetter(units[cursor]) {
                        tld += 1
                        cursor += 1
                    }
                    if tld >= 2 {
                        matchedEnd = dot + 1 + tld
                        break
                    }
                }
                dot -= 1
            }
            guard let matchedEnd else {
                index += 1
                continue
            }
            let range = NSRange(location: localStart, length: matchedEnd - localStart)
            let overlaps = spans.contains { existing in
                NSIntersectionRange(range, NSRange(location: existing.utf16RangeStart, length: existing.utf16RangeLength)).length > 0
            }
            if !overlaps {
                let matchText = nsString.substring(with: range)
                spans.append(ProtectedSpan(
                    kind: .email,
                    originalText: matchText,
                    canonicalForm: matchText,
                    utf16RangeStart: range.location,
                    utf16RangeLength: range.length
                ))
            }
            emailEnd = matchedEnd
            index = matchedEnd
        }
    }

    private static func isEmailLocal(_ unit: UInt16) -> Bool {
        switch unit {
        case 48...57, 65...90, 97...122, 46, 95, 37, 43, 45:
            return true // 0-9 A-Z a-z . _ % + -
        default:
            return false
        }
    }

    private static func isEmailDomain(_ unit: UInt16) -> Bool {
        switch unit {
        case 48...57, 65...90, 97...122, 46, 45:
            return true // 0-9 A-Z a-z . -
        default:
            return false
        }
    }

    private static func isEmailLetter(_ unit: UInt16) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit)
    }
}
