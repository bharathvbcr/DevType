import Foundation
import XCTest
@testable import ExpanderEngine

final class UsagePeriodSnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date { date("2026-09-03T12:30:00Z") }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeUsagePeriods-\(UUID().uuidString)")
            .appendingPathComponent(UsageStatsStore.fileName)
    }

    private func makeStore(fileURL: URL? = nil) -> UsageStatsStore {
        UsageStatsStore(
            fileURL: fileURL ?? temporaryFile(),
            flushInterval: 3_600,
            flushRetryDelay: 0.01
        )
    }

    private func record(
        _ count: Int,
        id: UUID,
        at timestamp: Date,
        in store: UsageStatsStore
    ) {
        for _ in 0..<count {
            store.recordUsage(for: id, at: timestamp, calendar: calendar)
        }
    }

    func testOldOnlyUsageRemainsLifetimeDataAndDoesNotLeakIntoRecentPeriods() {
        let store = makeStore()
        let id = UUID()
        record(4, id: id, at: date("2026-07-01T09:00:00Z"), in: store)

        let all = store.snapshot(period: .all, now: now, calendar: calendar)
        XCTAssertEqual(all.totalUsage, 4)
        XCTAssertEqual(all.usageCount(for: id), 4)
        XCTAssertEqual(all.topSnippetIDs(limit: 8), [id])
        XCTAssertEqual(all.recentSnippetIDs(limit: 8), [id])

        for period in [UsageStatsStore.Period.today, .sevenDays, .thirtyDays] {
            let snapshot = store.snapshot(period: period, now: now, calendar: calendar)
            XCTAssertEqual(snapshot.totalUsage, 0, "\(period) included old-only usage")
            XCTAssertEqual(snapshot.usageCount(for: id), 0)
            XCTAssertTrue(snapshot.topSnippetIDs(limit: 8).isEmpty)
            XCTAssertTrue(snapshot.recentSnippetIDs(limit: 8).isEmpty)
            XCTAssertEqual(snapshot.timeline.reduce(0) { $0 + $1.usageCount }, 0)
        }
    }

    func testRecentOnlyUsageAppearsInEveryContainingPeriod() {
        let store = makeStore()
        let id = UUID()
        record(3, id: id, at: date("2026-09-03T08:15:00Z"), in: store)

        for period in UsageStatsStore.Period.allCases {
            let snapshot = store.snapshot(period: period, now: now, calendar: calendar)
            XCTAssertEqual(snapshot.totalUsage, 3, "\(period) dropped recent-only usage")
            XCTAssertEqual(snapshot.usageCount(for: id), 3)
            XCTAssertEqual(snapshot.topSnippetIDs(limit: 8), [id])
            XCTAssertEqual(snapshot.recentSnippetIDs(limit: 8), [id])
            XCTAssertEqual(snapshot.timeline.reduce(0) { $0 + $1.usageCount }, 3)
        }
        XCTAssertEqual(store.stat(for: id)?.buckets.count, 1,
                       "repeated expansions in one hour should coalesce into one bounded bucket")
    }

    func testOneSnippetsOldAndRecentUsageIsSplitInsteadOfShowingItsLifetimeCount() {
        let store = makeStore()
        let mixed = UUID()
        record(9, id: mixed, at: date("2026-06-01T10:00:00Z"), in: store)
        record(2, id: mixed, at: date("2026-09-03T08:15:00Z"), in: store)

        XCTAssertEqual(
            store.snapshot(period: .all, now: now, calendar: calendar).usageCount(for: mixed),
            11
        )
        XCTAssertEqual(
            store.snapshot(period: .today, now: now, calendar: calendar).usageCount(for: mixed),
            2,
            "a recent last-used date must not pull old uses into a bounded period"
        )
    }

    func testMixedUsageConstrainsCountsRankingRecencyAndTimelineTogether() {
        let store = makeStore()
        let today = UUID()
        let yesterday = UUID()
        let olderThisMonth = UUID()
        let old = UUID()

        record(2, id: today, at: date("2026-09-03T08:15:00Z"), in: store)
        record(4, id: yesterday, at: date("2026-09-02T18:00:00Z"), in: store)
        record(5, id: olderThisMonth, at: date("2026-08-20T10:00:00Z"), in: store)
        record(7, id: old, at: date("2026-06-01T10:00:00Z"), in: store)

        let expectations: [(UsageStatsStore.Period, Int, [UUID])] = [
            (.all, 18, [old, olderThisMonth, yesterday, today]),
            (.today, 2, [today]),
            (.sevenDays, 6, [yesterday, today]),
            (.thirtyDays, 11, [olderThisMonth, yesterday, today])
        ]
        for (period, total, top) in expectations {
            let snapshot = store.snapshot(period: period, now: now, calendar: calendar)
            XCTAssertEqual(snapshot.totalUsage, total, "wrong total for \(period)")
            XCTAssertEqual(snapshot.topSnippetIDs(limit: 8), top, "wrong ranking for \(period)")
            XCTAssertEqual(snapshot.timeline.reduce(0) { $0 + $1.usageCount }, total)
        }

        XCTAssertEqual(
            store.snapshot(period: .all, now: now, calendar: calendar).recentSnippetIDs(limit: 8),
            [today, yesterday, olderThisMonth, old]
        )
        XCTAssertEqual(
            store.snapshot(period: .sevenDays, now: now, calendar: calendar).recentSnippetIDs(limit: 8),
            [today, yesterday]
        )
    }

    func testEachCalendarBoundaryIncludesTheExactStartAndExcludesThePriorInstant() {
        let starts: [(UsageStatsStore.Period, Date)] = [
            (.today, date("2026-09-03T00:00:00Z")),
            (.sevenDays, date("2026-08-28T00:00:00Z")),
            (.thirtyDays, date("2026-08-05T00:00:00Z"))
        ]

        for (period, start) in starts {
            let store = makeStore()
            let included = UUID()
            let excluded = UUID()
            record(1, id: included, at: start, in: store)
            record(1, id: excluded, at: start.addingTimeInterval(-1), in: store)

            let snapshot = store.snapshot(period: period, now: now, calendar: calendar)
            XCTAssertEqual(snapshot.usageCount(for: included), 1, "\(period) dropped its inclusive boundary")
            XCTAssertEqual(snapshot.usageCount(for: excluded), 0, "\(period) included the instant before its boundary")
            XCTAssertEqual(snapshot.totalUsage, 1)
        }
    }

    func testEmptyStoreProducesNoRankingsAndZeroedBoundedTimelines() {
        let store = makeStore()
        for period in UsageStatsStore.Period.allCases {
            let snapshot = store.snapshot(period: period, now: now, calendar: calendar)
            XCTAssertEqual(snapshot.totalUsage, 0)
            XCTAssertTrue(snapshot.entries.isEmpty)
            XCTAssertTrue(snapshot.topSnippetIDs(limit: 8).isEmpty)
            XCTAssertTrue(snapshot.recentSnippetIDs(limit: 8).isEmpty)
            XCTAssertEqual(snapshot.timeline.reduce(0) { $0 + $1.usageCount }, 0)
        }
    }

    func testSnippetProjectionAlsoConstrainsTotalsRankingAndTimeline() {
        let store = makeStore()
        let visible = UUID()
        let deleted = UUID()
        record(2, id: visible, at: date("2026-09-03T08:00:00Z"), in: store)
        record(20, id: deleted, at: date("2026-09-03T09:00:00Z"), in: store)

        let snapshot = store.snapshot(
            period: .today,
            snippetIDs: [visible],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(snapshot.totalUsage, 2)
        XCTAssertEqual(snapshot.topSnippetIDs(), [visible])
        XCTAssertEqual(snapshot.recentSnippetIDs(), [visible])
        XCTAssertEqual(snapshot.timeline.reduce(0) { $0 + $1.usageCount }, 2)
    }

    func testOutOfOrderRecordingDoesNotMoveRecencyBackward() {
        let store = makeStore()
        let id = UUID()
        let latest = date("2026-09-03T10:00:00Z")
        record(1, id: id, at: latest, in: store)
        record(1, id: id, at: date("2026-08-01T10:00:00Z"), in: store)

        XCTAssertEqual(store.lastUsedAt(for: id), latest)
        XCTAssertEqual(store.snapshot(period: .today, now: now, calendar: calendar).usageCount(for: id), 1)
        XCTAssertEqual(store.snapshot(period: .all, now: now, calendar: calendar).usageCount(for: id), 2)
    }

    func testPersistedBucketHistoryIsCappedWithoutChangingLifetimeTotals() throws {
        struct FixtureDocument: Codable {
            let schemaVersion: Int
            let stats: [String: UsageStatsStore.Stat]
        }

        let fileURL = temporaryFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let id = UUID()
        let count = UsageStatsStore.maximumBucketsPerSnippet + 5
        let buckets = (0..<count).map { index in
            let timestamp = now.addingTimeInterval(TimeInterval(index - count) * 3_600)
            return UsageStatsStore.UsageBucket(startedAt: timestamp, usageCount: 1, lastUsedAt: timestamp)
        }
        let document = FixtureDocument(
            schemaVersion: 2,
            stats: [id.uuidString: UsageStatsStore.Stat(
                usageCount: count,
                lastUsedAt: buckets.last?.lastUsedAt,
                buckets: buckets
            )]
        )
        try JSONEncoder().encode(document).write(to: fileURL, options: .atomic)

        let store = makeStore(fileURL: fileURL)
        let stat = try XCTUnwrap(store.stat(for: id))
        XCTAssertEqual(stat.buckets.count, UsageStatsStore.maximumBucketsPerSnippet)
        XCTAssertEqual(stat.usageCount, count, "the cap must not erase lifetime aggregates")
        let all = store.snapshot(period: .all, now: now, calendar: calendar)
        XCTAssertEqual(all.totalUsage, count)
        XCTAssertEqual(all.unbucketedUsageCount, 5)
        let thirtyDays = store.snapshot(period: .thirtyDays, now: now, calendar: calendar)
        XCTAssertEqual(
            thirtyDays.totalUsage,
            thirtyDays.timeline.reduce(0) { $0 + $1.usageCount },
            "the retention cap must still cover every timestamp needed by the 30-day view"
        )

        store.flush()
        let persisted = try JSONDecoder().decode(FixtureDocument.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(
            persisted.stats[id.uuidString]?.buckets.count,
            UsageStatsStore.maximumBucketsPerSnippet,
            "normalizing an oversized archive must also rewrite its bounded representation"
        )
    }

    func testVersionOneMigrationPreservesLifetimeAndStartsHonestTimestampHistory() throws {
        struct LegacyStat: Codable {
            let usageCount: Int
            let lastUsedAt: Date?
        }
        struct LegacyDocument: Codable {
            let schemaVersion: Int
            let stats: [String: LegacyStat]
        }

        let fileURL = temporaryFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let id = UUID()
        let legacy = LegacyDocument(
            schemaVersion: 1,
            stats: [id.uuidString: LegacyStat(usageCount: 7, lastUsedAt: date("2026-09-02T12:00:00Z"))]
        )
        try JSONEncoder().encode(legacy).write(to: fileURL, options: .atomic)

        let store = makeStore(fileURL: fileURL)
        let allBefore = store.snapshot(period: .all, now: now, calendar: calendar)
        XCTAssertEqual(allBefore.usageCount(for: id), 7)
        XCTAssertEqual(allBefore.unbucketedUsageCount, 7)
        XCTAssertEqual(store.snapshot(period: .sevenDays, now: now, calendar: calendar).usageCount(for: id), 0,
                       "legacy lifetime usage has no timestamps and must not be invented as recent")

        store.flush()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2,
                       "loading schema v1 must schedule an explicit schema v2 rewrite")

        store.recordUsage(for: id, at: date("2026-09-03T11:00:00Z"), calendar: calendar)
        store.flush()

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        let reloaded = makeStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.snapshot(period: .all, now: now, calendar: calendar).usageCount(for: id), 8)
        XCTAssertEqual(reloaded.snapshot(period: .today, now: now, calendar: calendar).usageCount(for: id), 1)
    }
}
