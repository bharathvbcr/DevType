import XCTest
@testable import ExpanderEngine

/// §1.6 — `kVK_LeftArrow` moves one **grapheme cluster**; AX ranges are UTF-16 code units.
///
/// `positionCursorIfNeeded` used the UTF-16 count directly, so `{{cursor}}` placed before an
/// emoji, an astral CJK character, a combining sequence, or a flag overshot the caret. The AX
/// caret path was already correct, so this only ever bit the HID fallback — i.e. Chrome and
/// Electron, the majority path. Nothing here needs a window server.
final class HIDKeyPosterArrowCountTests: XCTestCase {

    // MARK: - Degenerate inputs

    func testZeroAndNegativeOffsetsNeedNoArrows() {
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: "hello", utf16OffsetFromEnd: 0), 0)
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: "hello", utf16OffsetFromEnd: -3), 0)
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: "", utf16OffsetFromEnd: 0), 0)
    }

    func testOffsetAtOrPastStartMovesOverEveryCharacter() {
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: "hello", utf16OffsetFromEnd: 5), 5)
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: "hello", utf16OffsetFromEnd: 99), 5)
        // 4 characters, 8 UTF-16 units — the whole-string case must count characters, not units.
        let emoji = "😀😀😀😀"
        XCTAssertEqual(emoji.utf16.count, 8)
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: emoji, utf16OffsetFromEnd: 8), 4)
    }

    // MARK: - BMP baseline (unit == grapheme)

    func testASCIIOffsetEqualsArrowCount() {
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: "func foo() {}", utf16OffsetFromEnd: 3), 3)
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: "abc", utf16OffsetFromEnd: 1), 1)
    }

    // MARK: - Emoji (surrogate pairs)

    func testEmojiCountsOneArrowPerCluster() {
        // "a😀b" — 4 UTF-16 units, 3 characters. The caret sits before "😀".
        let text = "a😀b"
        XCTAssertEqual(text.utf16.count, 4)
        XCTAssertEqual(text.count, 3)
        // 3 UTF-16 units from the end == "😀b" == 2 grapheme clusters.
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: text, utf16OffsetFromEnd: 3), 2)
        // 1 unit from the end == "b" == 1 cluster.
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: text, utf16OffsetFromEnd: 1), 1)
    }

    func testEmojiZWJSequenceIsOneArrow() {
        // 👨‍👩‍👧 — one user-perceived character built from 3 emoji + 2 ZWJ.
        let family = "👨‍👩‍👧"
        XCTAssertEqual(family.count, 1)
        let text = "x\(family)"
        XCTAssertEqual(
            HIDKeyPoster.leftArrowCount(text: text, utf16OffsetFromEnd: family.utf16.count),
            1,
            "A ZWJ family emoji is a single grapheme cluster — one arrow, not \(family.utf16.count)."
        )
    }

    // MARK: - Astral CJK

    func testAstralCJKCountsOneArrowPerIdeograph() {
        // U+20BB7 (𠮷) is outside the BMP: 2 UTF-16 units, 1 character.
        let text = "前\u{20BB7}後"
        XCTAssertEqual(text.utf16.count, 4)
        XCTAssertEqual(text.count, 3)
        // "𠮷後" == 3 UTF-16 units == 2 clusters.
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: text, utf16OffsetFromEnd: 3), 2)
    }

    // MARK: - Combining marks

    func testCombiningMarksCollapseIntoOneArrow() {
        // "e" + U+0301 combining acute — 2 UTF-16 units, 1 grapheme cluster.
        let decomposed = "e\u{0301}"
        XCTAssertEqual(decomposed.count, 1)
        XCTAssertEqual(decomposed.utf16.count, 2)
        let text = "caf\(decomposed)"
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: text, utf16OffsetFromEnd: 2), 1)
        // The precomposed form is 1 unit and 1 cluster — the two must agree on arrow count.
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: "café", utf16OffsetFromEnd: 1), 1)
    }

    // MARK: - Regional indicator (flag) sequences

    func testFlagSequenceIsOneArrow() {
        // 🇺🇸 — two regional indicators, 4 UTF-16 units, 1 grapheme cluster.
        let flag = "🇺🇸"
        XCTAssertEqual(flag.count, 1)
        XCTAssertEqual(flag.utf16.count, 4)
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: "go \(flag)", utf16OffsetFromEnd: 4), 1)
    }

    func testOffsetInsideAClusterRoundsDownToTheClusterStart() {
        // Splitting a flag between its two regional indicators is only reachable from a
        // hand-built offset. Rounding down moves over the whole cluster rather than half of it.
        let text = "a🇺🇸"
        XCTAssertEqual(HIDKeyPoster.leftArrowCount(text: text, utf16OffsetFromEnd: 2), 1)
    }

    // MARK: - The property that matters

    func testArrowCountNeverExceedsCharacterCount() {
        let samples = ["", "a", "😀", "👨‍👩‍👧", "🇺🇸🇰🇷", "e\u{0301}x", "前\u{20BB7}後", "plain ascii"]
        for text in samples {
            for offset in 0...(text.utf16.count + 2) {
                let arrows = HIDKeyPoster.leftArrowCount(text: text, utf16OffsetFromEnd: offset)
                XCTAssertGreaterThanOrEqual(arrows, 0, "text=\(text) offset=\(offset)")
                XCTAssertLessThanOrEqual(
                    arrows,
                    text.count,
                    "Overshoot: text=\(text) offset=\(offset) arrows=\(arrows)"
                )
                XCTAssertLessThanOrEqual(
                    arrows,
                    offset,
                    "An arrow can never move more clusters than there are UTF-16 units."
                )
            }
        }
    }
}
