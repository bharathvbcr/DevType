import CryptoKit
import Foundation

/// Every item on a pasteboard as type to bytes. Kept whole so it can be written back; the report
/// only ever prints types, byte counts and a short digest, never the contents.
public struct ClipboardSnapshot: Equatable, Sendable {
    public let items: [[String: Data]]

    public init(items: [[String: Data]]) { self.items = items }

    public static let empty = ClipboardSnapshot(items: [])

    public var summary: String {
        if items.isEmpty { return "empty" }
        let parts = items.enumerated().map { index, item -> String in
            let types = item.keys.sorted().map { type in "\(type)(\(item[type]?.count ?? 0)B)" }
            return "item\(index)[\(types.joined(separator: ", "))]"
        }
        return parts.joined(separator: " ") + " digest=" + digest
    }

    public var digest: String {
        var hasher = SHA256()
        for item in items {
            for type in item.keys.sorted() {
                hasher.update(data: Data(type.utf8))
                hasher.update(data: item[type] ?? Data())
            }
            hasher.update(data: Data([0xFF]))
        }
        return hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol ClipboardPort: AnyObject {
    func snapshot() throws -> ClipboardSnapshot
    func restore(_ snapshot: ClipboardSnapshot) throws
}

/// Dry runs use this: a dry run must not read or write the real general pasteboard.
public final class InMemoryClipboard: ClipboardPort {
    public private(set) var current: ClipboardSnapshot
    public private(set) var restoreCount = 0

    public init(_ initial: ClipboardSnapshot = .empty) { current = initial }

    public func snapshot() throws -> ClipboardSnapshot { current }
    public func restore(_ snapshot: ClipboardSnapshot) throws {
        current = snapshot
        restoreCount += 1
    }
    public func overwrite(_ snapshot: ClipboardSnapshot) { current = snapshot }
}

public enum ClipboardVerdict: Equatable, Sendable {
    case restored(String)
    /// DevType left something else on the board. The harness put the original back afterwards.
    case modified(before: String, after: String)
    case unchecked(String)

    public var isFailure: Bool { if case .modified = self { return true } else { return false } }

    public var summary: String {
        switch self {
        case .restored(let s): return "restored (\(s))"
        case .modified(let before, let after): return "NOT RESTORED: was \(before); now \(after)"
        case .unchecked(let why): return "unchecked: \(why)"
        }
    }
}
