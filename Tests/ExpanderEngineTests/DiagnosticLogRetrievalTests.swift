import XCTest
@testable import ExpanderEngine

/// §9.1 log-retrieval hardening.
///
/// Two defects this locks down:
///   * `fetchRecentLogLines` enumerated oldest-first and stopped at the limit — busy sessions
///     kept the quiet minutes from half an hour ago and cut the seconds around the incident.
///     `keepingMostRecent` is that window, pure.
///   * `DevLogMirror` extends retention past what logd holds; its merge must dedupe overlapping
///     polls, stay bounded, forget evicted identities, and survive fuzzed input without losing
///     ordering.
final class DiagnosticLogRetrievalTests: XCTestCase {

    // MARK: - keepingMostRecent

    func testShortHistoriesPassThroughUnchanged() {
        let lines = ["a", "b", "c"]
        XCTAssertEqual(DiagnosticReport.keepingMostRecent(lines, limit: 10), lines)
        XCTAssertEqual(DiagnosticReport.keepingMostRecent(lines, limit: 3), lines)
    }

    /// The regression: at the old `break`, an over-limit history kept its HEAD. The window is
    /// the tail — newest-last order preserved.
    func testOverLimitHistoryKeepsTheMostRecentTail() {
        let lines = (0..<500).map { "line-\($0)" }
        let window = DiagnosticReport.keepingMostRecent(lines, limit: 200)
        XCTAssertEqual(window.count, 200)
        XCTAssertEqual(window.first, "line-300")
        XCTAssertEqual(window.last, "line-499")
        XCTAssertEqual(window, Array(lines.suffix(200)))
    }

    func testZeroAndNegativeLimitsYieldNothing() {
        XCTAssertEqual(DiagnosticReport.keepingMostRecent(["a"], limit: 0), [])
        XCTAssertEqual(DiagnosticReport.keepingMostRecent(["a"], limit: -5), [])
    }

    func testEmptyHistoryStaysEmpty() {
        XCTAssertEqual(DiagnosticReport.keepingMostRecent([], limit: 100), [])
    }

    func testWindowUnderFuzzAlwaysSuffixOfExactSize() {
        var rng = SplitMix64(seed: 0x0DD57)
        for _ in 0..<500 {
            let count = Int(rng.next() % 300)
            let limit = Int(rng.next() % 120)
            let lines = (0..<count).map { "\($0)" }
            let window = DiagnosticReport.keepingMostRecent(lines, limit: limit)
            XCTAssertLessThanOrEqual(window.count, max(limit, 0))
            XCTAssertEqual(window, Array(lines.suffix(min(max(limit, 0), count))))
        }
    }

    // MARK: - DevLogMirror

    private func line(
        _ message: String,
        secondsAgo: TimeInterval,
        category: String = "Inject",
        level: String = "notice",
        now: Date
    ) -> DevLogMirror.Line {
        .init(date: now.addingTimeInterval(-secondsAgo), category: category, level: level, message: message)
    }

    /// A manual poll works with no timer running and stores what the fetcher returned.
    func testPollWorksWithoutStart() {
        let now = Date()
        let batch = [
            line("alpha", secondsAgo: 9, now: now),
            line("beta", secondsAgo: 3, now: now),
        ]
        let mirror = DevLogMirror(fetch: { _ in batch })
        let added = mirror.poll(now: now)
        XCTAssertEqual(added, 2)
        XCTAssertEqual(mirror.count, 2)
        XCTAssertTrue(mirror.recentLines().last!.contains("beta"))
    }

    /// A manual poll before `start()` lazily seeds its read window from `firstPollLookback`.
    func testFirstPollFetchesTheCatchUpWindow() {
        let now = Date()
        var receivedSince: Date?
        let mirror = DevLogMirror(fetch: { since in
            receivedSince = since
            return []
        })
        mirror.poll(now: now)
        XCTAssertNotNil(receivedSince)
        XCTAssertEqual(
            receivedSince!.timeIntervalSince(now),
            -DevLogMirror.firstPollLookback,
            accuracy: 1.0
        )
    }

    func testSubsequentPollsResumeFromThePreviousPositionWithOverlap() {
        let now = Date()
        var receivedSinces: [Date] = []
        let mirror = DevLogMirror(fetch: { since in
            receivedSinces.append(since)
            return []
        })
        mirror.poll(now: now)
        mirror.poll(now: now.addingTimeInterval(DevLogMirror.defaultPollInterval))
        XCTAssertEqual(receivedSinces.count, 2)
        // The second read resumes from the *previous poll's* position minus the overlap, so a
        // line logd flushed late after the first snapshot is seen by two polls.
        let expectedSecond = now.addingTimeInterval(-DevLogMirror.pollOverlap)
        XCTAssertEqual(
            receivedSinces[1].timeIntervalSince(expectedSecond),
            0,
            accuracy: 0.001
        )
    }

    func testRenderedLineFormatMatchesDiagnosticStyle() {
        let now = Date()
        let entry = line("undo widened over 2 unit(s)", secondsAgo: 5, category: "Inject", level: "info", now: now)
        let mirror = DevLogMirror()
        mirror.mergeLocked([entry])
        XCTAssertEqual(
            mirror.recentLines(),
            ["\(DevLogMirror.Line.timestampFormatter.string(from: entry.date)) [Inject] info undo widened over 2 unit(s)"]
        )
    }

    func testOverlappingPollsDedupeByIdentity() {
        let now = Date()
        let shared = [
            line("first", secondsAgo: 30, now: now),
            line("second", secondsAgo: 20, now: now),
        ]
        let mirror = DevLogMirror(capacity: 50)
        mirror.mergeLocked(shared + [line("third", secondsAgo: 10, now: now)])
        mirror.mergeLocked(shared)   // re-delivered by the overlap window
        XCTAssertEqual(mirror.count, 3)
        XCTAssertEqual(mirror.recentLines().count, 3)
    }

    func testCapacityTrimsOldestAndForgetsTheirIdentities() {
        let now = Date()
        let mirror = DevLogMirror(capacity: 3)
        for index in 0..<6 {
            mirror.mergeLocked([line("m\(index)", secondsAgo: Double(100 - index * 10), now: now)])
        }
        XCTAssertEqual(mirror.count, 3)
        let rendered = mirror.recentLines()
        XCTAssertTrue(rendered[0].contains("m3"))
        XCTAssertTrue(rendered.last!.contains("m5"))

        // An evicted identity may legitimately re-enter (logd re-serving an old line after a
        // trim must not be swallowed forever). Arrival order governs: the re-added line lands
        // at the tail even though its timestamp is older.
        mirror.mergeLocked([line("m0", secondsAgo: 100, now: now)])
        XCTAssertEqual(mirror.count, 3, "re-added m0 should evict m3")
        XCTAssertTrue(mirror.recentLines().last!.contains("m0"))
    }

    func testRecentLinesLimitReturnsNewestSlice() {
        let now = Date()
        let mirror = DevLogMirror(capacity: 10)
        mirror.mergeLocked((0..<8).map { line("n\($0)", secondsAgo: Double(80 - $0 * 10), now: now) })
        let limited = mirror.recentLines(limit: 3)
        XCTAssertEqual(limited.count, 3)
        XCTAssertTrue(limited.last!.contains("n7"))
    }

    /// Fuzz: arbitrary batches with duplicates must leave the ring bounded, duplicate-free, and
    /// in arrival order — every invariant a diagnostic reader relies on. (Arrival order, not
    /// timestamp order: OSLog serves each poll oldest-first, and a line re-served after an
    /// eviction legitimately lands at the tail.)
    func testMergeInvariantsUnderFuzz() {
        var rng = SplitMix64(seed: 0x4E2D11)
        let capacity = 40
        let mirror = DevLogMirror(capacity: capacity)
        let now = Date()
        var fed: [DevLogMirror.Line] = []

        for round in 0..<2000 {
            var batch: [DevLogMirror.Line] = []
            let size = Int(rng.next() % 12)
            for _ in 0..<size {
                let id = Int(rng.next() % 60)   // collisions across rounds are the point
                batch.append(line("fuzz-\(id)", secondsAgo: Double(id), now: now))
            }
            fed.append(contentsOf: batch)
            mirror.mergeLocked(batch)

            let snapshot = mirror.storedLines
            XCTAssertLessThanOrEqual(snapshot.count, capacity, "round \(round)")
            let identities = snapshot.map(\.identity)
            XCTAssertEqual(identities.count, Set(identities).count, "duplicate identities, round \(round)")
            XCTAssertTrue(
                isSubsequence(snapshot, of: fed),
                "arrival order lost, round \(round)"
            )
        }
    }

    /// True when `needle`'s elements appear in `haystack` in the same relative order.
    private func isSubsequence(_ needle: [DevLogMirror.Line], of haystack: [DevLogMirror.Line]) -> Bool {
        var cursor = haystack.startIndex
        for element in needle {
            guard let found = haystack[cursor...].firstIndex(of: element) else { return false }
            cursor = haystack.index(after: found)
        }
        return true
    }

    // MARK: - Report mirror section

    func testMirrorSectionIsEmptyForAnEmptyRing() {
        XCTAssertEqual(DiagnosticReport.mirrorReportLines(mirror: DevLogMirror()), [])
    }

    func testMirrorSectionCarriesEverythingUnderTheCap() {
        let now = Date()
        let mirror = DevLogMirror(capacity: 50)
        mirror.mergeLocked((0..<10).map { line("r\($0)", secondsAgo: Double(50 - $0 * 5), now: now) })
        let lines = DiagnosticReport.mirrorReportLines(limit: 20, mirror: mirror)
        XCTAssertEqual(lines.count, 10)
        XCTAssertFalse(lines.contains { $0.contains("truncated") })
    }

    /// Over the cap: newest tail plus a truncation notice, never the whole ring.
    func testMirrorSectionTruncatesWithNotice() {
        let now = Date()
        let mirror = DevLogMirror(capacity: 100)
        mirror.mergeLocked((0..<100).map { line("s\($0)", secondsAgo: Double(200 - $0 * 2), now: now) })
        let lines = DiagnosticReport.mirrorReportLines(limit: 40, mirror: mirror)
        XCTAssertEqual(lines.count, 41, "notice + 40 lines")
        XCTAssertTrue(lines[0].contains("truncated"))
        XCTAssertTrue(lines[0].contains("60"))
        XCTAssertTrue(lines.last!.contains("s99"), "newest line must survive the cut")
    }
}
