import Foundation

public enum MacroRenderFailure: String, Error, Equatable {
    case sizeLimit, workLimit, invalidStructure, sourceChanged

    public var message: String {
        switch self {
        case .sizeLimit: return "Expansion exceeds the template size limit"
        case .workLimit: return "Expansion exceeds the template work limit"
        case .sourceChanged: return "The render operation belongs to a different template"
        case .invalidStructure: return "Template transformations overlap or have invalid boundaries"
        }
    }
}

/// Text plus literal provenance, zero-width cursor anchors, and pending transformations.
/// Generated values never become template source; offsets are resolved only after rendering.
struct MacroDocument {
    static let maximumUTF16 = 1_048_576
    static let maximumOperations = 4096
    static let maximumWork = 16_777_216

    enum OperationKind { case tag, transform(TextCaseTransform) }
    struct Operation {
        var range: NSRange
        let kind: OperationKind
        var occurrence: Int = 0
    }

    private(set) var text = ""
    private(set) var length = 0
    private(set) var literals: [NSRange] = []
    private(set) var cursors: [Int] = []
    var operations: [Operation] = []
    var failure: MacroRenderFailure?

    init(_ text: String = "", literal: Bool = false) { append(text, literal: literal) }

    mutating func append(_ value: String, literal: Bool = false) {
        guard failure == nil else { return }
        let count = value.utf16.prefix(Self.maximumUTF16 + 1).count
        guard count <= Self.maximumUTF16 - length else { failure = .sizeLimit; return }
        if literal, count > 0 { literals.append(NSRange(location: length, length: count)) }
        text += value
        length += count
    }

    mutating func cursor() { cursors.append(length) }

    mutating func addCase(_ transform: TextCaseTransform, from start: Int) {
        guard start >= 0, start <= length else { failure = .invalidStructure; return }
        operations.append(Operation(range: NSRange(location: start, length: length - start), kind: .transform(transform)))
        if operations.count > Self.maximumOperations { failure = .workLimit }
    }

    /// Every literal UTF-16 unit is masked only for lexing; actual content remains intact.
    /// The projection has exactly the original UTF-16 length, including astral characters.
    var templateProjection: [UInt16] {
        var units = Array(text.utf16)
        for range in literals {
            for i in range.location..<(range.location + range.length) { units[i] = 32 }
        }
        return units
    }

    mutating func compileMustacheTags() {
        let units = templateProjection
        var stack: [(start: Int, occurrence: Int)] = []
        var ordinal = 0
        var index = 0
        while index + 1 < units.count {
            if units[index] == 123, units[index + 1] == 123 {
                stack.append((index, ordinal))
                ordinal += 1
                if stack.count + operations.count > Self.maximumOperations { failure = .workLimit; return }
                index += 2
            } else if units[index] == 125, units[index + 1] == 125 {
                if let start = stack.popLast() {
                    operations.append(Operation(range: NSRange(location: start.start, length: index + 2 - start.start), kind: .tag, occurrence: start.occurrence))
                    if operations.count > Self.maximumOperations { failure = .workLimit; return }
                }
                index += 2
            } else { index += 1 }
        }
    }

    func isSource(_ range: NSRange) -> Bool {
        !literals.contains { NSIntersectionRange($0, range).length > 0 }
    }

    func slice(_ range: NSRange) -> MacroDocument {
        var result = MacroDocument((text as NSString).substring(with: range))
        let end = range.location + range.length
        result.literals = literals.compactMap {
            let intersection = NSIntersectionRange($0, range)
            return intersection.length == 0 ? nil : NSRange(location: intersection.location - range.location, length: intersection.length)
        }
        result.cursors = cursors.filter { $0 >= range.location && $0 <= end }.map { $0 - range.location }
        return result
    }

    func transformed(_ transform: TextCaseTransform, locale: Locale) -> MacroDocument {
        var result = MacroDocument(transform.apply(to: text, locale: locale), literal: true)
        result.cursors = cursors.map { offset in
            let prefix = (text as NSString).substring(to: offset)
            return transform.apply(to: prefix, locale: locale).utf16.count
        }
        if result.cursors.contains(where: { $0 < 0 || $0 > result.length }) { result.failure = .invalidStructure }
        return result
    }

    mutating func replace(_ range: NSRange, with replacement: MacroDocument, mapsInteriorCursors: Bool = false) {
        guard failure == nil else { return }
        if let reason = replacement.failure { failure = reason; return }
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location else { failure = .invalidStructure; return }
        let end = range.location + range.length
        let delta = replacement.length - range.length
        guard replacement.length <= Self.maximumUTF16 - (length - range.length) else { failure = .sizeLimit; return }
        var updated: [Operation] = []
        for var operation in operations {
            let otherEnd = operation.range.location + operation.range.length
            if operation.range.location >= end {
                operation.range.location += delta
            } else if otherEnd <= range.location {
                // Entirely before the replacement.
            } else if operation.range.location <= range.location, otherEnd >= end {
                operation.range.length += delta
            } else if operation.range.location >= range.location, otherEnd <= end {
                continue
            } else { failure = .invalidStructure; return }
            updated.append(operation)
        }
        cursors = cursors.compactMap { offset in
            if offset <= range.location { return offset }
            if offset >= end { return offset + delta }
            return mapsInteriorCursors ? nil : range.location + replacement.length
        } + replacement.cursors.map { range.location + $0 }
        var retained: [NSRange] = []
        for literal in literals {
            let literalEnd = literal.location + literal.length
            if literal.location < range.location {
                let count = min(literalEnd, range.location) - literal.location
                if count > 0 { retained.append(NSRange(location: literal.location, length: count)) }
            }
            if literalEnd > end {
                let start = max(literal.location, end)
                retained.append(NSRange(location: start + delta, length: literalEnd - start))
            }
        }
        literals = retained + replacement.literals.map { NSRange(location: range.location + $0.location, length: $0.length) }
        text = (text as NSString).replacingCharacters(in: range, with: replacement.text)
        length += delta
        operations = updated
    }
}
