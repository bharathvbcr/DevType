import XCTest
@testable import ExpanderEngine

/// §2.3 — the engine's old "ring buffer" was an `Array` plus `removeFirst(count - capacity)`, an
/// O(n) memmove on *every* keystroke at steady state, inside a CGEventTap callback macOS kills
/// for being slow. This is the real ring; ordering after wraparound is the thing that silently
/// breaks matching if it is wrong.
final class CharacterRingBufferTests: XCTestCase {

    private func buffer(_ text: String, capacity: Int) -> CharacterRingBuffer {
        var ring = CharacterRingBuffer(capacity: capacity)
        ring.append(contentsOf: text)
        return ring
    }

    // MARK: - Construction

    func testNewBufferIsEmpty() {
        let ring = CharacterRingBuffer(capacity: 8)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.makeArray(), [])
        XCTAssertEqual(ring.stringValue, "")
        XCTAssertEqual(ring.capacity, 8)
    }

    func testCapacityIsClampedToAtLeastOne() {
        var ring = CharacterRingBuffer(capacity: 0)
        XCTAssertEqual(ring.capacity, 1)
        ring.append("a")
        ring.append("b")
        XCTAssertEqual(ring.stringValue, "b")

        var negative = CharacterRingBuffer(capacity: -5)
        XCTAssertEqual(negative.capacity, 1)
        negative.append("z")
        XCTAssertEqual(negative.stringValue, "z")
    }

    // MARK: - Append

    func testAppendKeepsInsertionOrder() {
        let ring = buffer("abcd", capacity: 8)
        XCTAssertEqual(ring.count, 4)
        XCTAssertFalse(ring.isEmpty)
        XCTAssertEqual(ring.makeArray(), ["a", "b", "c", "d"])
        XCTAssertEqual(ring.stringValue, "abcd")
    }

    func testFillingExactlyToCapacityDoesNotWrap() {
        let ring = buffer("abcd", capacity: 4)
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.stringValue, "abcd")
    }

    func testOverflowDropsTheOldest() {
        let ring = buffer("abcde", capacity: 4)
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.stringValue, "bcde")
    }

    func testOverflowFarPastCapacityKeepsOnlyTheNewestWindow() {
        let ring = buffer("abcdefghijklmnop", capacity: 4)
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.stringValue, "mnop")
    }

    func testMakeArrayOrderingSurvivesRepeatedWraparound() {
        var ring = CharacterRingBuffer(capacity: 5)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        for (index, character) in alphabet.enumerated() {
            ring.append(character)
            let expected = Array(alphabet[max(0, index - 4)...index])
            XCTAssertEqual(
                ring.makeArray(),
                expected,
                "Wrong window after appending \(character) (i=\(index))"
            )
        }
    }

    // MARK: - removeLast (backspace)

    func testRemoveLastDropsTheNewest() {
        var ring = buffer("abc", capacity: 8)
        ring.removeLast()
        XCTAssertEqual(ring.stringValue, "ab")
        XCTAssertEqual(ring.count, 2)
    }

    func testRemoveLastOnEmptyIsANoOp() {
        var ring = CharacterRingBuffer(capacity: 4)
        ring.removeLast()
        ring.removeLast()
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.makeArray(), [])
    }

    func testRemoveLastAfterWraparoundKeepsTheRestInOrder() {
        // Head is mid-storage here, so the "remove newest" index arithmetic has to wrap too.
        var ring = buffer("abcdefg", capacity: 4)  // -> d e f g
        XCTAssertEqual(ring.stringValue, "defg")
        ring.removeLast()
        XCTAssertEqual(ring.stringValue, "def")
        ring.append("z")
        XCTAssertEqual(ring.stringValue, "defz")
    }

    func testAppendAfterDrainingBackToEmpty() {
        var ring = buffer("abcdef", capacity: 4)  // -> c d e f
        for _ in 0..<4 { ring.removeLast() }
        XCTAssertTrue(ring.isEmpty)
        ring.append(contentsOf: "xy")
        XCTAssertEqual(ring.stringValue, "xy")
    }

    // MARK: - removeAll

    func testRemoveAllResetsCompletely() {
        var ring = buffer("abcdefg", capacity: 4)
        ring.removeAll()
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.makeArray(), [])
        ring.append(contentsOf: "hi")
        XCTAssertEqual(ring.stringValue, "hi")
    }

    func testRemoveAllOnEmptyIsSafe() {
        var ring = CharacterRingBuffer(capacity: 4)
        ring.removeAll()
        XCTAssertEqual(ring.makeArray(), [])
    }

    // MARK: - Grapheme clusters

    func testStoresGraphemeClustersNotUTF16Units() {
        var ring = CharacterRingBuffer(capacity: 4)
        ring.append(contentsOf: "a😀🇰🇷b")
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.stringValue, "a😀🇰🇷b")
    }

    // MARK: - Value semantics

    func testCopyingDoesNotShareStorage() {
        var original = buffer("abc", capacity: 8)
        var copy = original
        copy.append("d")
        original.append("z")
        XCTAssertEqual(original.stringValue, "abcz")
        XCTAssertEqual(copy.stringValue, "abcd")
    }
}
