import CryptoKit
import Foundation

/// Content-free identifiers and shape metadata for user-controlled text in diagnostics.
///
/// The salt exists only for this process. That keeps repeated values correlatable inside one
/// report while preventing a copied report from becoming an offline dictionary of short triggers.
enum DiagnosticPrivacy {
    private static let salt: Data = {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }()

    static func fingerprint(_ value: String, domain: String) -> String {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(domain.utf8))
        hasher.update(data: Data([0]))
        // Avoid materializing an attacker-sized trigger/path as one second `Data` allocation.
        // The source string already exists in its owner; diagnostics hash it through a fixed-size
        // scratch buffer so report construction adds bounded memory.
        var chunk: [UInt8] = []
        chunk.reserveCapacity(4_096)
        for byte in value.utf8 {
            chunk.append(byte)
            if chunk.count == 4_096 {
                hasher.update(data: Data(chunk))
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            hasher.update(data: Data(chunk))
        }
        return hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Bundle IDs and other diagnostic identifiers are useful verbatim at normal sizes. An
    /// externally sourced outlier is represented only by bounded shape metadata so one field
    /// cannot dominate the report or echo an arbitrary path-like payload.
    static func boundedIdentifier(
        _ value: String,
        label: String,
        domain: String,
        maxUTF8Bytes: Int = 512
    ) -> String {
        guard value.utf8.count > max(0, maxUTF8Bytes) else { return value }
        return textShape(value, label: label, domain: domain)
    }

    /// Length and invisible-character counts preserve mismatch evidence without retaining text.
    static func textShape(_ value: String, label: String, domain: String) -> String {
        let scalars = value.unicodeScalars
        let whitespaceCount = scalars.filter(\.properties.isWhitespace).count
        let nonASCIIWhitespaceCount = scalars.filter {
            $0.properties.isWhitespace && $0 != " " && $0 != "\n" && $0 != "\t"
        }.count
        let formatCount = scalars.filter { $0.properties.generalCategory == .format }.count
        return "\(label)Chars=\(value.count) \(label)UTF16=\(value.utf16.count)"
            + " \(label)Whitespace=\(whitespaceCount)"
            + " \(label)NonASCIIWhitespace=\(nonASCIIWhitespaceCount)"
            + " \(label)Format=\(formatCount)"
            + " \(label)Hash=\(fingerprint(value, domain: domain))"
    }
}
