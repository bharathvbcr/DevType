import Foundation

public enum ProtectedSpanExtractor {
    /// UTF-16 code units. Past this, `extract` returns `[]` without calling
    /// `NSDataDetector` or `NSRegularExpression`. The pathological version-span
    /// prompt is about 4_000 units and must still be scanned.
    public static let maximumUTF16Length = 32_768

    /// Compiled once: `extract` runs per final transcript and these never change.
    /// Email is not in this list. ICU retries
    /// `[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}` from every index when
    /// `@` is absent. `appendLinearEmailSpans` is the O(n) scan that replaces it.
    static let patterns: [(kind: ProtectedSpanKind, regex: NSRegularExpression)] = [
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
        // One flag per UTF-16 unit. The transcript is already capped, so this is
        // bounded. A hit overlaps when any unit in its range is claimed.
        var occupied = [Bool](repeating: false, count: nsString.length)

        // 1. URLs and Emails via NSDataDetector
        if let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = urlDetector.matches(in: text, options: [], range: fullRange)
            for match in matches {
                guard claim(match.range, occupied: &occupied) else { continue }
                let matchText = nsString.substring(with: match.range)
                let isEmail = match.url?.scheme == "mailto" || (matchText.contains("@") && !matchText.contains("://"))
                let kind: ProtectedSpanKind = isEmail ? .email : .url
                spans.append(ProtectedSpan(
                    kind: kind,
                    originalText: matchText,
                    canonicalForm: matchText,
                    utf16RangeStart: match.range.location,
                    utf16RangeLength: match.range.length
                ))
            }
        }

        // 2. Email, then the other regex patterns. Email is a linear scan.
        appendLinearEmailSpans(Array(text.utf16), nsString: nsString, occupied: &occupied, to: &spans)
        for (kind, regex) in patterns {
            let matches = regex.matches(in: text, options: [], range: fullRange)
            for match in matches {
                guard claim(match.range, occupied: &occupied) else { continue }
                let matchText = nsString.substring(with: match.range)
                spans.append(ProtectedSpan(
                    kind: kind,
                    originalText: matchText,
                    canonicalForm: matchText,
                    utf16RangeStart: match.range.location,
                    utf16RangeLength: match.range.length
                ))
            }
        }

        // 3. Dictionary Terms. A repeated String was already searched across the
        // whole transcript, so it cannot claim another span. Case variants stay
        // distinct: `canonicalForm` is the term itself.
        var searchedTerms = Set<String>()
        for term in dictionaryTerms where !term.isEmpty {
            if !searchedTerms.insert(term).inserted { continue }
            var searchRange = fullRange
            while searchRange.location < nsString.length {
                let foundRange = nsString.range(of: term, options: [.caseInsensitive], range: searchRange)
                if foundRange.location != NSNotFound {
                    if claim(foundRange, occupied: &occupied) {
                        let matchText = nsString.substring(with: foundRange)
                        spans.append(ProtectedSpan(
                            kind: .customDictionary,
                            originalText: matchText,
                            canonicalForm: term,
                            utf16RangeStart: foundRange.location,
                            utf16RangeLength: foundRange.length
                        ))
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

    /// Claim `range` only when every unit is free. Returns false when any unit
    /// is already taken, and then leaves the mark unchanged.
    private static func claim(_ range: NSRange, occupied: inout [Bool]) -> Bool {
        let start = range.location
        let end = start + range.length
        guard range.length > 0, start >= 0, end <= occupied.count else { return false }
        for index in start..<end where occupied[index] {
            return false
        }
        for index in start..<end {
            occupied[index] = true
        }
        return true
    }

    /// Same alphabet as the old case-insensitive email pattern, in one forward pass.
    /// `@` is in neither the local nor the domain class, so each code unit is
    /// visited a constant number of times.
    private static func appendLinearEmailSpans(
        _ units: [UInt16],
        nsString: NSString,
        occupied: inout [Bool],
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
            if claim(range, occupied: &occupied) {
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

    /// ASCII `A-Z`/`a-z`, plus the only non-ASCII scalars whose simple case fold
    /// is one ASCII letter: U+017F ſ → s and U+212A K → k. ICU's case-insensitive
    /// class matches those. Other non-ASCII letters stay out.
    private static func isEmailLetter(_ unit: UInt16) -> Bool {
        switch unit {
        case 65...90, 97...122, 0x017F, 0x212A:
            return true
        default:
            return false
        }
    }

    private static func isEmailLocal(_ unit: UInt16) -> Bool {
        if isEmailLetter(unit) { return true }
        switch unit {
        case 48...57, 46, 95, 37, 43, 45:
            return true // 0-9 . _ % + -
        default:
            return false
        }
    }

    private static func isEmailDomain(_ unit: UInt16) -> Bool {
        if isEmailLetter(unit) { return true }
        switch unit {
        case 48...57, 46, 45:
            return true // 0-9 . -
        default:
            return false
        }
    }
}
