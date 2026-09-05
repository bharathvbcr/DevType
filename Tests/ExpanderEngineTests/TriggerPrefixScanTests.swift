import XCTest
@testable import ExpanderEngine

/// `TriggerPrefixScan` replaced two nested library-wide loops — `TriggerPrefixIndex`'s
/// ambiguity pass and `SnippetStore.triggerConflicts(in:)`'s prefix-shadow pass — with one
/// sorted view. Both were O(n²), both ran on the main thread, and the second folded its
/// candidate with `lowercased()` inside the inner loop.
///
/// These tests pin the two things the replacement has to get right: the same answers as an
/// exhaustive comparison (including the duplicate and empty-key cases that a sorted-run walk
/// is most likely to fumble), and a complexity that no longer squares.
final class TriggerPrefixScanTests: XCTestCase {

    /// The definition the sorted walk has to reproduce, written the slow, obvious way.
    private func exhaustiveExtensions(_ keys: [String], of index: Int) -> Set<Int> {
        var out: Set<Int> = []
        for (other, key) in keys.enumerated() where other != index {
            if key.count > keys[index].count && key.hasPrefix(keys[index]) {
                out.insert(other)
            }
        }
        return out
    }

    private func scanExtensions(_ keys: [String], of index: Int) -> Set<Int> {
        var out: Set<Int> = []
        TriggerPrefixScan(foldedKeys: keys).forEachStrictExtension(of: index) { out.insert($0) }
        return out
    }

    private func assertMatchesExhaustive(
        _ keys: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scan = TriggerPrefixScan(foldedKeys: keys)
        for index in keys.indices {
            let expected = exhaustiveExtensions(keys, of: index)
            var actual: Set<Int> = []
            scan.forEachStrictExtension(of: index) { actual.insert($0) }
            XCTAssertEqual(
                actual, expected,
                "extensions of \(index) (\"\(keys[index])\") in \(keys)",
                file: file, line: line
            )
            XCTAssertEqual(
                scan.hasStrictExtension(of: index), !expected.isEmpty,
                "hasStrictExtension of \(index) (\"\(keys[index])\") in \(keys)",
                file: file, line: line
            )
        }
    }

    // MARK: - Agreement with the exhaustive definition

    func testFindsTheStrictExtensionsOfEachKey() {
        assertMatchesExhaustive([";slm", ";slmabout", ";slmx", ";other", ";s"])
    }

    /// The run-walk starts at the end of the run of *equal* keys, which is exactly where an
    /// off-by-one would either revisit a duplicate or skip the first real extension.
    func testDuplicateKeysAreNotTheirOwnExtensions() {
        assertMatchesExhaustive([";sig", ";sig", ";sig", ";signature"])
    }

    /// A library where every trigger is identical has no extensions at all, and answering that
    /// must not cost a walk over the duplicates.
    func testAllKeysIdentical() {
        assertMatchesExhaustive(Array(repeating: ";sig", count: 12))
    }

    /// Deep nesting is the case where each key extends every shorter one before it.
    func testFullyNestedChain() {
        assertMatchesExhaustive(["a", "ab", "abc", "abcd", "abcde"])
    }

    func testEmptyKeyIsAPrefixOfEverythingElse() {
        assertMatchesExhaustive(["", ";a", ";ab", ""])
    }

    func testSingleKeyAndEmptyInput() {
        assertMatchesExhaustive([";only"])
        assertMatchesExhaustive([])
        XCTAssertFalse(TriggerPrefixScan(foldedKeys: []).hasStrictExtension(of: 0))
    }

    /// Out-of-range indices answer "nothing" rather than trapping — the callers index by
    /// position into their own arrays and a mismatch must fail closed.
    func testOutOfRangeIndexIsInert() {
        let scan = TriggerPrefixScan(foldedKeys: [";a", ";ab"])
        XCTAssertFalse(scan.hasStrictExtension(of: 7))
        var visited = 0
        scan.forEachStrictExtension(of: -1) { _ in visited += 1 }
        XCTAssertEqual(visited, 0)
    }

    /// Non-ASCII keys sort and compare by the same rule as the rest; a prefix relationship
    /// among multi-byte scalars must survive the sorted walk.
    func testUnicodeKeys() {
        assertMatchesExhaustive(["안녕", "안녕하세요", "こん", "こんにちは", "안"])
    }

    /// Randomised agreement over shapes the hand-written cases do not cover.
    func testAgreesWithExhaustiveScanUnderFuzz() {
        var seed: UInt64 = 0x5DEECE66D
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let alphabet = ["a", "b", ";", "x"]
        for _ in 0..<200 {
            var keys: [String] = []
            for _ in 0..<next(14) {
                var key = ""
                for _ in 0..<next(5) { key += alphabet[next(alphabet.count)] }
                keys.append(key)
            }
            assertMatchesExhaustive(keys)
        }
    }

    // MARK: - The complexity that motivated the type

    /// Guards the regression this replaced. The nested scan measured 118 ms (ambiguity) and
    /// 180 ms (prefix shadow) at this size; the sorted walk measures well under a millisecond.
    /// The bound is deliberately loose — it exists to catch a return to quadratic behaviour on
    /// a slow machine, not to assert a particular speed.
    func testTwoThousandTriggersScanInLinearishTime() {
        let keys = (0..<2_000).map { ";trigger\($0)" }
        let started = Date()
        let scan = TriggerPrefixScan(foldedKeys: keys)
        var hits = 0
        for index in keys.indices where scan.hasStrictExtension(of: index) { hits += 1 }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 0.5,
            "2,000-trigger prefix scan took \(elapsed)s — the quadratic scan is back"
        )
        // `;trigger1` is a prefix of `;trigger10`…`;trigger19`, and so on.
        XCTAssertGreaterThan(hits, 0)
    }
}
