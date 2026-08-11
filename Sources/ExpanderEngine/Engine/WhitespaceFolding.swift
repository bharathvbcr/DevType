import Foundation

/// Whitespace folding for field-text comparisons — the "`slm incident" (2026-08-11) class.
///
/// Rich-text hosts store visually identical whitespace under different code points: ProseMirror
/// (Claude Desktop) persists a trailing typed space as U+00A0, French keyboard layouts insert
/// U+202F, Word for Mac reports paragraph breaks as CR, and web views may surface U+2028/U+2029.
/// Any comparison between text DevType typed/injected and text an AX read handed back must fold
/// these before judging, or a byte-level mismatch refuses/re-pastes over text the user cannot
/// distinguish from a match.
///
/// **Invariant (load-bearing): folding is 1:1 in UTF-16 code units.** Every folded source is a
/// single BMP unit replaced by a single BMP unit, so UTF-16 offsets, caret windows, erase counts,
/// and backspace counts computed on raw text remain valid on folded text and vice versa. Never
/// add a mapping that changes length (e.g. CRLF→LF, canonical composition) — the erase math and
/// the §2.6 caret-window bounds both depend on this. `WhitespaceFoldingStressTests` sweeps the
/// entire BMP against the live Unicode tables to prove the fold covers every separator and
/// touches nothing else.
extension String {
    /// Folds one UTF-16 unit: Unicode space separators (category Zs) → U+0020, line/paragraph
    /// separators (Zl, Zp) and CR → U+000A. Everything else — including tab, which is visually
    /// and semantically distinct — passes through unchanged.
    @inline(__always)
    static func foldedWhitespaceUnit(_ unit: UInt16) -> UInt16 {
        switch unit {
        // Zs — space separators (all BMP, all single-unit).
        case 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            return 0x0020
        // Zl (U+2028), Zp (U+2029), and CR — visually a line break either way.
        case 0x2028, 0x2029, 0x000D:
            return 0x000A
        default:
            return unit
        }
    }

    /// The string with every foldable unit folded. Returns `self` (no allocation) when nothing
    /// needs folding — the overwhelmingly common case, checked in one pass.
    public var normalizedWhitespace: String {
        guard utf16.contains(where: { Self.foldedWhitespaceUnit($0) != $0 }) else { return self }
        let folded = utf16.map { Self.foldedWhitespaceUnit($0) }
        return String(utf16CodeUnits: folded, count: folded.count)
    }
}
