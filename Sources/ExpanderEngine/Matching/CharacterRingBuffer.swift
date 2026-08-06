import Foundation

/// §2.3: Fixed-capacity circular buffer of `Character`.
///
/// The engine's previous "ring buffer" was a plain `Array` plus
/// `removeFirst(count - capacity)` — an O(n) memmove on *every* keystroke once the buffer
/// reached steady state. This is a real ring: append and remove are O(1) and never move
/// existing elements.
///
/// Only `makeArray()` allocates, and it allocates exactly one array of the live length so the
/// matcher can index it 0-based (previously the callback built a `String` which the matcher
/// immediately converted back with `Array(buffer)` — two allocations to do nothing).
public struct CharacterRingBuffer {
    /// Maximum number of live characters. Appending past this drops the oldest.
    public let capacity: Int

    private var storage: [Character?]
    /// Index of the oldest live element.
    private var head: Int
    private var length: Int

    public init(capacity: Int = 64) {
        let clamped = max(1, capacity)
        self.capacity = clamped
        self.storage = [Character?](repeating: nil, count: clamped)
        self.head = 0
        self.length = 0
    }

    public var count: Int { length }

    public var isEmpty: Bool { length == 0 }

    /// Appends one character, evicting the oldest when full.
    public mutating func append(_ character: Character) {
        let index = (head + length) % capacity
        storage[index] = character
        if length == capacity {
            head = (head + 1) % capacity
        } else {
            length += 1
        }
    }

    public mutating func append<S: Sequence>(contentsOf characters: S) where S.Element == Character {
        for character in characters {
            append(character)
        }
    }

    /// Removes the newest character (backspace). No-op when empty.
    public mutating func removeLast() {
        guard length > 0 else { return }
        let index = (head + length - 1) % capacity
        // Drop the reference so the Character's storage is not pinned by a dead slot.
        storage[index] = nil
        length -= 1
    }

    public mutating func removeAll() {
        head = 0
        guard length > 0 else { return }
        for index in 0..<capacity {
            storage[index] = nil
        }
        length = 0
    }

    /// Oldest → newest copy. One allocation; safe to index 0-based.
    public func makeArray() -> [Character] {
        guard length > 0 else { return [] }
        var out: [Character] = []
        out.reserveCapacity(length)
        let tail = head + length
        if tail <= capacity {
            for index in head..<tail {
                if let character = storage[index] {
                    out.append(character)
                }
            }
        } else {
            for index in head..<capacity {
                if let character = storage[index] {
                    out.append(character)
                }
            }
            for index in 0..<(tail - capacity) {
                if let character = storage[index] {
                    out.append(character)
                }
            }
        }
        return out
    }

    /// Convenience for diagnostics / legacy String-based callers. Allocates.
    public var stringValue: String {
        String(makeArray())
    }
}
