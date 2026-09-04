import AppKit
import Foundation
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

@MainActor
final class StatsPeriodPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        ISO8601DateFormatter().date(from: "2026-09-03T12:30:00Z")!
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func testEveryUISegmentMapsToTheCanonicalUsagePeriod() {
        XCTAssertEqual(StatsTimePeriod.allCases.map(\.rawValue), [0, 1, 2, 3])
        XCTAssertEqual(StatsTimePeriod.allCases.map(\.usagePeriod), [
            .all, .today, .sevenDays, .thirtyDays
        ])
    }

    func testChartAndPeriodSelectorExposeLocalizedNativeAccessibility() throws {
        _ = NSApplication.shared
        let storedLanguage = UserDefaults.standard.object(forKey: LocalizationManager.deviceKey)
        let localization = LocalizationManager()
        localization.language = .ja
        defer { restoreStoredLanguage(storedLanguage) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatsAccessibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnippetStore(
            location: .init(
                fileURL: directory.appendingPathComponent("snippets.json"),
                expectsExistingLibrary: false
            ),
            watcherFactory: { _ in nil },
            secretPurgeEnabled: false
        )
        let controller = StatsViewController(store: store, localization: localization)
        let views = descendants(of: controller.view)

        let period = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(period.accessibilityLabel(), localization.s("stats.period.accessibility.label"))
        XCTAssertEqual(period.accessibilityValue() as? String, localization.s("stats.period.all"))
        XCTAssertEqual((period.cell as? NSSegmentedCell)?.trackingMode, .selectOne)
        XCTAssertEqual(period.selectedSegment, StatsTimePeriod.all.rawValue)
        XCTAssertEqual(period.label(forSegment: StatsTimePeriod.sevenDays.rawValue),
                       localization.s("stats.period.sevenDays"))

        period.selectedSegment = StatsTimePeriod.sevenDays.rawValue
        _ = period.sendAction(period.action, to: period.target)
        XCTAssertEqual(
            period.accessibilityValue() as? String,
            localization.s("stats.period.sevenDays")
        )

        let chart = try XCTUnwrap(views.first {
            $0.accessibilityLabel() == localization.s("stats.chart.accessibility.label")
        })
        XCTAssertEqual(chart.accessibilityRole(), .image)
        XCTAssertEqual(
            chart.accessibilityValue() as? String,
            localization.s("stats.chart.accessibility.empty")
        )
    }

    func testRenderedStatisticsFormattingUsesTheSelectedAppLanguage() throws {
        _ = NSApplication.shared
        let storedLanguage = UserDefaults.standard.object(forKey: LocalizationManager.deviceKey)
        let localization = LocalizationManager()
        let currentIdentifier = Locale.current.identifier.lowercased()
        let selectedLanguage: AppLanguage = currentIdentifier.hasPrefix("ja") ? .ko : .ja
        localization.language = selectedLanguage
        defer { restoreStoredLanguage(storedLanguage) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatsLocale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnippetStore(
            location: .init(
                fileURL: directory.appendingPathComponent("snippets.json"),
                expectsExistingLibrary: false
            ),
            watcherFactory: { _ in nil },
            secretPurgeEnabled: false
        )
        let usage = UsageStatsStore(
            fileURL: directory.appendingPathComponent("usage.json"),
            flushInterval: 3_600
        )
        store.usageStatsStore = usage

        let snippet = SnippetModel(
            title: "Locale fixture",
            triggerKeyword: "a",
            replacementText: String(repeating: "x", count: 12_201)
        )
        XCTAssertEqual(
            store.saveGroups([SnippetGroup(name: "Statistics", snippets: [snippet])]),
            .saved
        )
        let usedAt = Date().addingTimeInterval(-7_200)
        usage.recordUsage(for: snippet.id, at: usedAt, calendar: .current)

        let controller = StatsViewController(store: store, localization: localization)
        _ = controller.view
        controller.refresh()
        let rendered = descendants(of: controller.view)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        let locale = Locale(identifier: localization.effectiveLanguageCode())

        let numberFormatter = NumberFormatter()
        numberFormatter.locale = locale
        numberFormatter.numberStyle = .decimal
        let expectedNumber = try XCTUnwrap(
            numberFormatter.string(from: NSNumber(value: 12_201))
        )

        let durationFormatter = DateComponentsFormatter()
        durationFormatter.unitsStyle = .abbreviated
        durationFormatter.allowedUnits = [.hour, .minute]
        durationFormatter.maximumUnitCount = 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        durationFormatter.calendar = calendar
        let expectedDuration = try XCTUnwrap(durationFormatter.string(from: 3_660))

        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.locale = locale
        relativeFormatter.unitsStyle = .abbreviated
        let expectedRelative = relativeFormatter.localizedString(
            for: usedAt,
            relativeTo: Date()
        )

        XCTAssertTrue(rendered.contains(expectedNumber), "number did not use \(locale.identifier)")
        XCTAssertTrue(rendered.contains(expectedDuration), "duration did not use \(locale.identifier)")
        XCTAssertTrue(rendered.contains(expectedRelative), "relative date did not use \(locale.identifier)")
    }

    func testSparklineAccessibilitySummaryIsLocalizedAndBoundedForEmptyAndLargeSeries() throws {
        _ = NSApplication.shared
        let storedLanguage = UserDefaults.standard.object(forKey: LocalizationManager.deviceKey)
        let localization = LocalizationManager()
        defer { restoreStoredLanguage(storedLanguage) }

        for language in [AppLanguage.en, .ko, .ja] {
            localization.language = language
            let chart = StatsSparklineView(localization: localization)

            chart.setPoints([])
            XCTAssertEqual(
                chart.accessibilityValue() as? String,
                localization.s("stats.chart.accessibility.empty")
            )

            chart.setPoints(Array(repeating: Int.max, count: 4_096) + [-1, 0])
            let summary = try XCTUnwrap(chart.accessibilityValue() as? String)
            XCTAssertLessThanOrEqual(
                summary.count,
                StatsLocalizedFormatter.maximumAccessibilitySummaryLength
            )
            XCTAssertFalse(summary.contains("["), "The AX value must summarize, not enumerate points.")
            XCTAssertFalse(summary.contains("-1"), "Invalid negative counts must not leak into the summary.")
        }
    }

    func testAllTimeTimelineDisclosesUsageOutsideRetainedBuckets() throws {
        _ = NSApplication.shared
        let storedLanguage = UserDefaults.standard.object(forKey: LocalizationManager.deviceKey)
        let localization = LocalizationManager()
        localization.language = .en
        defer { restoreStoredLanguage(storedLanguage) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatsPartialTimeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SnippetStore(
            location: .init(
                fileURL: directory.appendingPathComponent("snippets.json"),
                expectsExistingLibrary: false
            ),
            watcherFactory: { _ in nil },
            secretPurgeEnabled: false
        )
        let usage = UsageStatsStore(
            fileURL: directory.appendingPathComponent("usage.json"),
            flushInterval: 3_600
        )
        store.usageStatsStore = usage
        let snippet = SnippetModel(
            title: "Long-lived",
            triggerKeyword: ";long",
            replacementText: "Long-lived expansion"
        )
        XCTAssertEqual(
            store.saveGroups([SnippetGroup(name: "Statistics", snippets: [snippet])]),
            .saved
        )

        let count = UsageStatsStore.maximumBucketsPerSnippet + 1
        for hour in 0..<count {
            usage.recordUsage(
                for: snippet.id,
                at: now.addingTimeInterval(TimeInterval(-hour * 3_600)),
                calendar: calendar
            )
        }

        let period = usage.snapshot(
            period: .all,
            snippetIDs: [snippet.id],
            now: now,
            calendar: calendar
        )
        let presentation = StatsPresentationSnapshot.make(snippets: [snippet], usage: period)
        XCTAssertEqual(presentation.totalUses, count)
        XCTAssertEqual(presentation.unbucketedUsageCount, 1)
        XCTAssertEqual(presentation.sparklineCounts.reduce(0, +), count - 1)

        let controller = StatsViewController(store: store, localization: localization)
        _ = controller.view
        controller.refresh()
        let rendered = descendants(of: controller.view)
        XCTAssertTrue(rendered.compactMap { ($0 as? NSTextField)?.stringValue }.contains(
            localization.s("stats.chart.title.partial")
        ))
        let chart = try XCTUnwrap(rendered.first {
            $0.accessibilityLabel() == localization.s("stats.chart.accessibility.label")
        })
        let chartValue = try XCTUnwrap(chart.accessibilityValue() as? String)
        XCTAssertTrue(
            chartValue.contains(localization.s("stats.chart.accessibility.partial", "1"))
        )
    }

    func testStatisticsFormatterTracksAppLanguageChangesWithoutRecreation() throws {
        let storedLanguage = UserDefaults.standard.object(forKey: LocalizationManager.deviceKey)
        let localization = LocalizationManager()
        defer { restoreStoredLanguage(storedLanguage) }
        let formatter = StatsLocalizedFormatter(localization: localization)
        let reference = date("2026-09-03T12:30:00Z")
        let earlier = date("2026-09-02T12:30:00Z")

        localization.language = .en
        let englishNumber = formatter.number(1_234_567)
        let englishDuration = formatter.duration(minutes: 61)
        let englishRelative = formatter.relativeDate(earlier, relativeTo: reference)

        localization.language = .ja
        let japaneseNumber = formatter.number(1_234_567)
        let japaneseDuration = formatter.duration(minutes: 61)
        let japaneseRelative = formatter.relativeDate(earlier, relativeTo: reference)

        let expectedJapaneseNumber = NumberFormatter()
        expectedJapaneseNumber.locale = Locale(identifier: "ja")
        expectedJapaneseNumber.numberStyle = .decimal
        XCTAssertEqual(
            japaneseNumber,
            expectedJapaneseNumber.string(from: NSNumber(value: 1_234_567))
        )
        XCTAssertFalse(englishNumber.isEmpty)
        XCTAssertNotEqual(englishDuration, japaneseDuration)
        XCTAssertNotEqual(englishRelative, japaneseRelative)
    }

    func testEveryPeriodBuildsAllMetricsListsAndSparklineFromOneSnapshot() {
        let first = SnippetModel(
            title: "First",
            triggerKeyword: "a",
            replacementText: "AAAAA"
        )
        let second = SnippetModel(
            title: "Second",
            triggerKeyword: "bb",
            replacementText: "BBBBBBBB"
        )
        let third = SnippetModel(
            title: "Third",
            triggerKeyword: "ccc",
            replacementText: "CCCCCCCCC"
        )
        let fourth = SnippetModel(
            title: "Fourth",
            triggerKeyword: "dddd",
            replacementText: "DDDDDDDDDD"
        )
        let snippets = [first, second, third, fourth]
        let store = UsageStatsStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("StatsPresentation-\(UUID().uuidString).json"),
            flushInterval: 3_600
        )

        for _ in 0..<3 { store.recordUsage(for: first.id, at: date("2026-06-01T08:00:00Z"), calendar: calendar) }
        for _ in 0..<2 { store.recordUsage(for: first.id, at: date("2026-09-03T08:00:00Z"), calendar: calendar) }
        for _ in 0..<4 { store.recordUsage(for: second.id, at: date("2026-09-02T18:00:00Z"), calendar: calendar) }
        for _ in 0..<5 { store.recordUsage(for: third.id, at: date("2026-08-20T10:00:00Z"), calendar: calendar) }
        for _ in 0..<7 { store.recordUsage(for: fourth.id, at: date("2026-06-01T10:00:00Z"), calendar: calendar) }

        let expectedTotals: [StatsTimePeriod: Int] = [
            .all: 21,
            .today: 2,
            .sevenDays: 6,
            .thirtyDays: 11
        ]
        for period in StatsTimePeriod.allCases {
            let usage = store.snapshot(period: period.usagePeriod, now: now, calendar: calendar)
            let presentation = StatsPresentationSnapshot.make(snippets: snippets, usage: usage)

            XCTAssertEqual(presentation.totalUses, expectedTotals[period], "wrong cards for \(period)")
            XCTAssertEqual(presentation.top.reduce(0) { $0 + $1.usageCount }, expectedTotals[period])
            XCTAssertEqual(presentation.sparklineCounts.reduce(0, +), expectedTotals[period])
            XCTAssertEqual(Set(presentation.recent.map(\.snippet.id)), Set(presentation.top.map(\.snippet.id)))
            XCTAssertTrue(presentation.top.allSatisfy { $0.usageCount > 0 })
            XCTAssertTrue(presentation.recent.allSatisfy { $0.lastUsedAt != nil })

            let expectedCharacters = presentation.top.reduce(0) {
                $0 + $1.usageCount * $1.snippet.replacementText.count
            }
            let expectedKeystrokes = presentation.top.reduce(0) {
                $0 + $1.usageCount * max(
                    0,
                    $1.snippet.replacementText.count - $1.snippet.triggerKeyword.count
                )
            }
            XCTAssertEqual(presentation.charactersProduced, expectedCharacters)
            XCTAssertEqual(presentation.keystrokesSaved, expectedKeystrokes)
        }

        let today = StatsPresentationSnapshot.make(
            snippets: snippets,
            usage: store.snapshot(period: .today, now: now, calendar: calendar)
        )
        XCTAssertEqual(today.top.map(\.snippet.id), [first.id])
        XCTAssertEqual(today.top.first?.usageCount, 2,
                       "today must not display this snippet's five-use lifetime aggregate")
        XCTAssertEqual(today.recent.map(\.snippet.id), [first.id])

        let sevenDays = StatsPresentationSnapshot.make(
            snippets: snippets,
            usage: store.snapshot(period: .sevenDays, now: now, calendar: calendar)
        )
        XCTAssertEqual(sevenDays.top.map(\.snippet.id), [second.id, first.id])
        XCTAssertEqual(sevenDays.recent.map(\.snippet.id), [first.id, second.id])
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func restoreStoredLanguage(_ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: LocalizationManager.deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
        }
    }
}
