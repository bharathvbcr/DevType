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

    private var keystrokes: [Keystroke]
    private let maxCount: Int

    /// §3.9: hard cap on tracked keystrokes. A trigger longer than this can never fire; see
    /// `AbbreviationMatcher.matchableTriggerLimit` and `EventTapEngine.overlongTriggerDiagnostics()`.
    public static let defaultMaxCount = 64

    public init(maxCount: Int = LayoutBuffer.defaultMaxCount) {
        self.keystrokes = []
        self.maxCount = maxCount
    }

    public var physical: String { String(keystrokes.map(\.physical)) }
    /// §2.3: `[Character]` form for `AbbreviationMatcher.match(characters:)` — skips the
    /// `String` round trip the matcher used to undo with `Array(buffer)`.
    public var physicalCharacters: [Character] { keystrokes.map(\.physical) }
    public var composed: String { keystrokes.map(\.composed).joined() }
    public var isEmpty: Bool { keystrokes.isEmpty }
    public var count: Int { keystrokes.count }

    public mutating func appendLiteral(composed: String, physical: Character) {
        keystrokes.append(Keystroke(composed: composed, physical: physical))
        if keystrokes.count > maxCount {
            keystrokes.removeFirst(keystrokes.count - maxCount)
        }
    }

    public mutating func deleteLast() {
        if !keystrokes.isEmpty { keystrokes.removeLast() }
    }

    public mutating func clear() {
        keystrokes.removeAll(keepingCapacity: true)
    }

    public func visibleGraphemeCount(lastKeystrokes n: Int) -> Int {
        guard n > 0 else { return 0 }
        let take = min(n, keystrokes.count)
        let physicalKeys = keystrokes.suffix(take).map(\.physical)
        return HangulComposer.glyphCount(physicalKeys: physicalKeys)
    }

    public func lastComposed() -> String {
        keystrokes.last?.composed ?? ""
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
