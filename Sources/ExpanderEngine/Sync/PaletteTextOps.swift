import CryptoKit
import Foundation

/// Instant text transforms and generators for the hybrid command palette.
///
/// Bridges the capabilities already present in `TextCaseTransform` / `MacroRandom`
/// / `SafeMathParser` into palette rows that act on selection or insert values.
public enum PaletteTextOp: String, Sendable, Equatable, CaseIterable {
    case upper
    case lower
    case title
    case sentence
    case sortLines
    case dedupeLines
    case trimLines
    case numberLines
    case base64Encode
    case base64Decode
    case urlEncode
    case urlDecode
    case htmlEscape
    case htmlUnescape
    case jsonPretty
    case jsonCompact
    case sha256
    case md5
}

public enum PaletteGenerateOp: String, Sendable, Equatable, CaseIterable {
    case uuid
    case lorem
    case password
}

public enum PaletteTextOps {
    public static func apply(_ op: PaletteTextOp, to text: String) -> String {
        switch op {
        case .upper:
            return TextCaseTransform.upper.apply(to: text)
        case .lower:
            return TextCaseTransform.lower.apply(to: text)
        case .title:
            return TextCaseTransform.title.apply(to: text)
        case .sentence:
            return TextCaseTransform.sentence.apply(to: text)
        case .sortLines:
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .joined(separator: "\n")
        case .dedupeLines:
            var seen = Set<String>()
            var out: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if seen.insert(line).inserted { out.append(line) }
            }
            return out.joined(separator: "\n")
        case .trimLines:
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .numberLines:
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        case .base64Encode:
            return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let decoded = String(data: data, encoding: .utf8) else {
                return text
            }
            return decoded
        case .urlEncode:
            return text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        case .urlDecode:
            return text.removingPercentEncoding ?? text
        case .htmlEscape:
            return text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        case .htmlUnescape:
            return text
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
        case .jsonPretty:
            return prettyJSON(text) ?? text
        case .jsonCompact:
            return compactJSON(text) ?? text
        case .sha256:
            let digest = SHA256.hash(data: Data(text.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        case .md5:
            // CryptoKit has no MD5; use Insecure.MD5 when available.
            let digest = Insecure.MD5.hash(data: Data(text.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    public static func generate(_ op: PaletteGenerateOp) -> String {
        switch op {
        case .uuid:
            return UUID().uuidString.lowercased()
        case .lorem:
            return "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."
        case .password:
            return MacroRandom.value(spec: "alnum:20")
        }
    }

    public static func countSummary(for text: String) -> String {
        let chars = text.count
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(chars) chars · \(words) words · \(lines) lines"
    }

    public static func formatMathResult(_ value: Double) -> String {
        if value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) {
            return String(Int(value))
        }
        var formatted = String(format: "%.8f", value)
        while formatted.contains("."), formatted.hasSuffix("0") {
            formatted.removeLast()
        }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return formatted
    }

    private static func prettyJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let out = String(data: pretty, encoding: .utf8) else { return nil }
        return out
    }

    private static func compactJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let out = String(data: compact, encoding: .utf8) else { return nil }
        return out
    }
}
