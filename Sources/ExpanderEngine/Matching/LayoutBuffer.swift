// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// Parallel buffer tracking composed (IME) and physical (US layout) keystrokes.
public struct LayoutBuffer {
    public struct Keystroke: Equatable {
        public let composed: String
        public let physical: Character
        public init(composed: String, physical: Character) {
            self.composed = composed
            self.physical = physical
        }
    }

    /// Fixed storage. `removeFirst` on an `Array` memmoves every live keystroke once the
    /// buffer is full, which is the steady state of typing. A ring makes append and
    /// `deleteLast` O(1). `maxCount <= 0` keeps an empty buffer: modulo-by-zero never runs.
    private var storage: [Keystroke?]
    private var head = 0
    private var length = 0
    private let maxCount: Int

    /// §3.9: hard cap on tracked keystrokes. A trigger longer than this can never fire; see
    /// `AbbreviationMatcher.matchableTriggerLimit` and `EventTapEngine.overlongTriggerDiagnostics()`.
    public static let defaultMaxCount = 64

    /// Empty snapshot for keystrokes that are not on the Korean 2-Set path. Copying this
    /// does not allocate a 64-slot buffer and does not retain the live ring.
    public static let idle = LayoutBuffer(maxCount: 0)

    public init(maxCount: Int = LayoutBuffer.defaultMaxCount) {
        let clamped = max(0, maxCount)
        self.maxCount = clamped
        self.storage = clamped == 0 ? [] : [Keystroke?](repeating: nil, count: clamped)
    }

    public var isEmpty: Bool { length == 0 }
    public var count: Int { length }

    public var physical: String { String(livePhysicalCharacters()) }

    /// §2.3: `[Character]` form for `AbbreviationMatcher.match(characters:)` — skips the
    /// `String` round trip the matcher used to undo with `Array(buffer)`.
    public var physicalCharacters: [Character] { livePhysicalCharacters() }

    public var composed: String {
        var parts: [String] = []
        parts.reserveCapacity(length)
        forEachLive { parts.append($0.composed) }
        return parts.joined()
    }

    public mutating func appendLiteral(composed: String, physical: Character) {
        guard maxCount > 0 else { return }
        let index = (head + length) % maxCount
        storage[index] = Keystroke(composed: composed, physical: physical)
        if length == maxCount {
            head = (head + 1) % maxCount
        } else {
            length += 1
        }
    }

    public mutating func deleteLast() {
        guard length > 0, maxCount > 0 else { return }
        let index = (head + length - 1) % maxCount
        storage[index] = nil
        length -= 1
    }

    public mutating func clear() {
        head = 0
        guard length > 0 else { return }
        for index in storage.indices { storage[index] = nil }
        length = 0
    }

    /// The engine's single layout mutation. When physical fallback is off this returns
    /// without appending, deleting, or walking the live storage.
    public mutating func recordKeystroke(
        allowPhysicalFallback: Bool,
        delete: Bool,
        composed: String = "",
        physical: Character = " "
    ) {
        guard allowPhysicalFallback else { return }
        if delete {
            deleteLast()
        } else {
            appendLiteral(composed: composed, physical: physical)
        }
    }

    public func visibleGraphemeCount(lastKeystrokes n: Int) -> Int {
        guard n > 0, length > 0 else { return 0 }
        let keys = livePhysicalCharacters()
        let take = min(n, keys.count)
        return HangulComposer.glyphCount(physicalKeys: Array(keys.suffix(take)))
    }

    public func lastComposed() -> String {
        guard length > 0, maxCount > 0 else { return "" }
        let index = (head + length - 1) % maxCount
        return storage[index]?.composed ?? ""
    }

    private func livePhysicalCharacters() -> [Character] {
        var chars: [Character] = []
        chars.reserveCapacity(length)
        forEachLive { chars.append($0.physical) }
        return chars
    }

    /// Oldest to newest. Every public walk uses this so a wrapped ring stays ordered.
    private func forEachLive(_ body: (Keystroke) -> Void) {
        guard length > 0, maxCount > 0 else { return }
        let tail = head + length
        if tail <= maxCount {
            for index in head..<tail {
                if let keystroke = storage[index] { body(keystroke) }
            }
        } else {
            for index in head..<maxCount {
                if let keystroke = storage[index] { body(keystroke) }
            }
            for index in 0..<(tail - maxCount) {
                if let keystroke = storage[index] { body(keystroke) }
            }
        }
    }
}

public struct BufferMatchDecision {
    public enum Source: Equatable { case composed, physical }

    public let match: AbbreviationMatch
    public let source: Source
    public let backspaces: Int
    public let terminator: String
    /// Trigger text as it appears in the target field, when known.
    ///
    /// `nil` on the physical-Hangul path: the buffer that matched holds US-layout keystrokes, not
    /// the composed Hangul the field actually shows, so there is nothing safe to compare against.
    /// Downstream that disables text verification and falls back to count-only erasing.
    public let fieldText: String?

    public init(
        match: AbbreviationMatch,
        source: Source,
        backspaces: Int,
        terminator: String,
        fieldText: String? = nil
    ) {
        self.match = match
        self.source = source
        self.backspaces = backspaces
        self.terminator = terminator
        self.fieldText = fieldText
    }
}

public func isTwoSetKoreanSourceID(_ id: String) -> Bool {
    id == "com.apple.inputmethod.Korean.2SetKorean"
}

public enum LayoutAwareMatcher {
    /// String-based shim kept for existing callers and tests.
    /// §2.3: prefer `decide(composedCharacters:…)` on the keystroke path.
    public static func decide(
        composedBuffer: String,
        layout: LayoutBuffer,
        matcher: AbbreviationMatcher,
        allowPhysicalFallback: Bool
    ) -> BufferMatchDecision? {
        decide(
            composedCharacters: Array(composedBuffer),
            layout: layout,
            matcher: matcher,
            allowPhysicalFallback: allowPhysicalFallback,
            bundleID: nil
        )
    }

    /// §2.3 / §4.4: allocation-free entry point for the tap callback.
    /// `bundleID` is the cached frontmost app used to filter app-scoped snippets.
    public static func decide(
        composedCharacters: [Character],
        layout: LayoutBuffer,
        matcher: AbbreviationMatcher,
        allowPhysicalFallback: Bool,
        bundleID: String? = nil
    ) -> BufferMatchDecision? {
        if let m = matcher.match(characters: composedCharacters, bundleID: bundleID) {
            return BufferMatchDecision(
                match: m, source: .composed,
                backspaces: m.backspaces, terminator: m.terminator,
                fieldText: m.matchedText
            )
        }

        guard allowPhysicalFallback else { return nil }

        if !layout.isEmpty,
           let m = matcher.match(characters: layout.physicalCharacters, bundleID: bundleID) {
            let visible = layout.visibleGraphemeCount(lastKeystrokes: m.backspaces)
            let terminator = m.terminator.isEmpty ? "" : layout.lastComposed()
            // The field shows composed Hangul, not the physical keys that matched — no text to verify.
            return BufferMatchDecision(
                match: m, source: .physical,
                backspaces: visible, terminator: terminator,
                fieldText: nil
            )
        }

        return nil
    }
}
