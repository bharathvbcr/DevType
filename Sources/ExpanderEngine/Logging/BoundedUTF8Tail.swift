import Foundation

/// A newest-last tail whose logical storage is bounded before every accepted append.
///
/// `utf8ByteCount` is supplied by the caller because the retained value is not necessarily a
/// `String`. Oversized values are observed and rejected without evicting useful existing history.
/// Older retained values are evicted *before* a fitting value is appended, so neither the entry
/// nor byte invariant is transiently exceeded by a projected write.
struct BoundedUTF8Tail<Element> {
    struct Statistics: Equatable {
        let observedCount: Int
        let retainedCount: Int
        let retainedUTF8Bytes: Int
        let oversizedCount: Int
        let evictedCount: Int
    }

    struct AppendResult {
        let accepted: Bool
        let evicted: [Element]
    }

    private struct Stored {
        let value: Element
        let utf8ByteCount: Int
    }

    let countLimit: Int
    let byteLimit: Int

    private var storage: [Stored?] = []
    private var head = 0
    private var retainedUTF8Bytes = 0
    private var observedCount = 0
    private var oversizedCount = 0
    private var evictedCount = 0

    init(countLimit: Int, byteLimit: Int) {
        self.countLimit = max(0, countLimit)
        self.byteLimit = max(0, byteLimit)
    }

    var statistics: Statistics {
        Statistics(
            observedCount: observedCount,
            retainedCount: storage.count - head,
            retainedUTF8Bytes: retainedUTF8Bytes,
            oversizedCount: oversizedCount,
            evictedCount: evictedCount
        )
    }

    var values: [Element] {
        storage[head...].compactMap { $0?.value }
    }

    mutating func append(_ value: Element, utf8ByteCount: Int) -> AppendResult {
        observedCount = Self.saturatingIncrement(observedCount)
        let resolvedByteCount = max(0, utf8ByteCount)
        guard resolvedByteCount <= byteLimit else {
            oversizedCount = Self.saturatingIncrement(oversizedCount)
            return AppendResult(accepted: false, evicted: [])
        }
        guard countLimit > 0 else {
            evictedCount = Self.saturatingIncrement(evictedCount)
            return AppendResult(accepted: false, evicted: [])
        }

        var evicted: [Element] = []
        while storage.count - head >= countLimit
            || retainedUTF8Bytes > byteLimit - resolvedByteCount {
            guard let oldest = storage[head] else {
                head += 1
                continue
            }
            storage[head] = nil
            head += 1
            retainedUTF8Bytes -= oldest.utf8ByteCount
            evictedCount = Self.saturatingIncrement(evictedCount)
            evicted.append(oldest.value)
        }

        compactIfNeeded()
        storage.append(Stored(value: value, utf8ByteCount: resolvedByteCount))
        retainedUTF8Bytes += resolvedByteCount
        return AppendResult(accepted: true, evicted: evicted)
    }

    private mutating func compactIfNeeded() {
        guard head > 0, head >= countLimit || head * 2 >= storage.count else { return }
        storage.removeFirst(head)
        head = 0
    }

    private static func saturatingIncrement(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }
}
