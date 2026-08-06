import XCTest
@testable import ExpanderEngine

/// §3.5 — date arithmetic (`%@+1D%`, `{{date:iso:+1d}}`) is the highest-value macro gap. The
/// risk it introduces is that an ordinary `DateFormatter` pattern gets mistaken for an offset,
/// so `HH:mm` must keep meaning "hours:minutes" and not "+H hours".
final class DateOffsetTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let parsed = formatter.date(from: iso) else {
            XCTFail("Bad fixture date \(iso)")
            return Date(timeIntervalSince1970: 0)
        }
        return parsed
    }

    private func render(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private var calendar: Calendar {
        DateFormatLibrary.arithmeticCalendar(locale: posix, timeZone: utc)
    }

    // MARK: - parse: accepted forms

    func testSingleUnitOffsets() {
        XCTAssertEqual(DateOffset.parse("+1d"), DateOffset(days: 1))
        XCTAssertEqual(DateOffset.parse("-2w"), DateOffset(weeks: -2))
        XCTAssertEqual(DateOffset.parse("+3M"), DateOffset(months: 3))
        XCTAssertEqual(DateOffset.parse("+1y"), DateOffset(years: 1))
        XCTAssertEqual(DateOffset.parse("-45m"), DateOffset(minutes: -45))
        XCTAssertEqual(DateOffset.parse("+30s"), DateOffset(seconds: 30))
        XCTAssertEqual(DateOffset.parse("+6h"), DateOffset(hours: 6))
    }

    func testTextExpanderStyleUppercaseUnits() {
        XCTAssertEqual(DateOffset.parse("+1D"), DateOffset(days: 1))
        XCTAssertEqual(DateOffset.parse("-1W"), DateOffset(weeks: -1))
        XCTAssertEqual(DateOffset.parse("+2Y"), DateOffset(years: 2))
        XCTAssertEqual(DateOffset.parse("+2H"), DateOffset(hours: 2))
        XCTAssertEqual(DateOffset.parse("+15S"), DateOffset(seconds: 15))
    }

    /// The one case sensitivity that matters: `M` is months, `m` is minutes.
    func testMonthAndMinuteAreDistinguishedByCase() {
        XCTAssertEqual(DateOffset.parse("+1M"), DateOffset(months: 1))
        XCTAssertEqual(DateOffset.parse("+1m"), DateOffset(minutes: 1))
        XCTAssertNotEqual(DateOffset.parse("+1M"), DateOffset.parse("+1m"))
    }

    func testCompoundOffsets() {
        XCTAssertEqual(DateOffset.parse("+1y-3M"), DateOffset(years: 1, months: -3))
        XCTAssertEqual(
            DateOffset.parse("+1d+2h+3m"),
            DateOffset(days: 1, hours: 2, minutes: 3)
        )
        // Repeated units accumulate rather than overwrite.
        XCTAssertEqual(DateOffset.parse("+1d+1d"), DateOffset(days: 2))
    }

    func testSurroundingWhitespaceIsTolerated() {
        XCTAssertEqual(DateOffset.parse("  +1d  "), DateOffset(days: 1))
    }

    func testZeroOffsetParsesAndIsZero() {
        let zero = DateOffset.parse("+0d")
        XCTAssertEqual(zero, DateOffset())
        XCTAssertEqual(zero?.isZero, true)
    }

    // MARK: - parse: rejected forms (this is the whole point)

    func testTimePatternsAreNotOffsets() {
        // §3.5: the regression that would silently corrupt every `HH:mm` snippet.
        XCTAssertNil(DateOffset.parse("HH:mm"))
        XCTAssertNil(DateOffset.parse("mm"))
        XCTAssertNil(DateOffset.parse("hh:mm:ss"))
        XCTAssertNil(DateOffset.parse("yyyy-MM-dd"))
        XCTAssertNil(DateOffset.parse("MMMM d, yyyy"))
        XCTAssertNil(DateOffset.parse("EEEE"))
        XCTAssertNil(DateOffset.parse("iso"))
    }

    func testMalformedOffsetsAreRejected() {
        XCTAssertNil(DateOffset.parse(""))
        XCTAssertNil(DateOffset.parse("   "))
        XCTAssertNil(DateOffset.parse("1d"), "A sign is mandatory")
        XCTAssertNil(DateOffset.parse("+d"), "A magnitude is mandatory")
        XCTAssertNil(DateOffset.parse("+1"), "A unit is mandatory")
        XCTAssertNil(DateOffset.parse("+1q"), "Unknown unit")
        XCTAssertNil(DateOffset.parse("+1dx"), "Trailing junk")
        XCTAssertNil(DateOffset.parse("+1d+"), "Dangling sign")
        XCTAssertNil(DateOffset.parse("+1234567d"), "Absurd magnitudes are refused")
        XCTAssertNil(DateOffset.parse("+１d"), "Full-width digits are not ASCII numerals")
    }

    // MARK: - splitSpec

    func testSplitSpecSeparatesFormatFromOffset() {
        let iso = DateFormatLibrary.splitSpec("iso:+1d")
        XCTAssertEqual(iso.format, "iso")
        XCTAssertEqual(iso.offset, DateOffset(days: 1))

        let bare = DateFormatLibrary.splitSpec("+1d")
        XCTAssertEqual(bare.format, "")
        XCTAssertEqual(bare.offset, DateOffset(days: 1))
    }

    func testSplitSpecLeavesColonBearingPatternsAlone() {
        XCTAssertEqual(DateFormatLibrary.splitSpec("HH:mm").format, "HH:mm")
        XCTAssertNil(DateFormatLibrary.splitSpec("HH:mm").offset)
        XCTAssertEqual(DateFormatLibrary.splitSpec("yyyy-MM-dd").format, "yyyy-MM-dd")
        XCTAssertNil(DateFormatLibrary.splitSpec("yyyy-MM-dd").offset)
        XCTAssertEqual(DateFormatLibrary.splitSpec("HH:mm:ss").format, "HH:mm:ss")
        XCTAssertNil(DateFormatLibrary.splitSpec("HH:mm:ss").offset)
    }

    func testSplitSpecUsesTheLastColonOnly() {
        let spec = DateFormatLibrary.splitSpec("HH:mm:+30m")
        XCTAssertEqual(spec.format, "HH:mm")
        XCTAssertEqual(spec.offset, DateOffset(minutes: 30))
    }

    // MARK: - Arithmetic uses Calendar, not seconds

    func testDayOffsetAppliesThroughCalendar() {
        let base = date("2026-03-14 09:30:00")
        XCTAssertEqual(render(DateOffset(days: 1).apply(to: base, calendar: calendar)), "2026-03-15 09:30:00")
        XCTAssertEqual(render(DateOffset(days: -14).apply(to: base, calendar: calendar)), "2026-02-28 09:30:00")
    }

    func testWeekOffsetIsSevenDays() {
        let base = date("2026-01-01 00:00:00")
        XCTAssertEqual(render(DateOffset(weeks: 2).apply(to: base, calendar: calendar)), "2026-01-15 00:00:00")
    }

    /// The reason this must not be `days * 86_400`: Jan 31 + 1 month is Feb 28, not Mar 3.
    func testMonthArithmeticClampsToTheEndOfTheTargetMonth() {
        let jan31 = date("2026-01-31 12:00:00")
        XCTAssertEqual(
            render(DateOffset(months: 1).apply(to: jan31, calendar: calendar)),
            "2026-02-28 12:00:00"
        )
        // …and 2028 is a leap year, so the same operation lands on the 29th.
        let jan31Leap = date("2028-01-31 12:00:00")
        XCTAssertEqual(
            render(DateOffset(months: 1).apply(to: jan31Leap, calendar: calendar)),
            "2028-02-29 12:00:00"
        )
    }

    func testYearArithmeticClampsLeapDay() {
        let leapDay = date("2028-02-29 08:00:00")
        XCTAssertEqual(
            render(DateOffset(years: 1).apply(to: leapDay, calendar: calendar)),
            "2029-02-28 08:00:00"
        )
    }

    /// Deliberately picks a date where no component needs clamping, so the assertion does not
    /// depend on the order Calendar applies fields in.
    func testCompoundOffsetAppliesEveryComponent() {
        let base = date("2026-03-10 08:00:00")
        let offset = DateOffset(years: 1, months: 2, days: 3, hours: 4, minutes: 5, seconds: 6)
        XCTAssertEqual(
            render(offset.apply(to: base, calendar: calendar)),
            "2027-05-13 12:05:06"
        )
    }

    func testZeroOffsetIsIdentity() {
        let base = date("2026-06-15 10:00:00")
        XCTAssertEqual(DateOffset().apply(to: base, calendar: calendar), base)
    }

    // MARK: - End to end through DateFormatLibrary

    func testFormatAppliesTheOffsetBeforeFormatting() {
        let base = date("2026-03-14 09:30:00")
        XCTAssertEqual(
            DateFormatLibrary.format("iso:+1d", now: base, locale: posix, timeZone: utc),
            "2026-03-15"
        )
        XCTAssertEqual(
            DateFormatLibrary.format("iso", now: base, locale: posix, timeZone: utc),
            "2026-03-14"
        )
    }

    func testFormatDoesNotTreatATimePatternAsAnOffset() {
        let base = date("2026-03-14 09:30:00")
        XCTAssertEqual(
            DateFormatLibrary.format("HH:mm", now: base, locale: posix, timeZone: utc),
            "09:30",
            "`HH:mm` must format, never shift the date"
        )
    }

    func testFormatWithARawPatternPlusOffset() {
        let base = date("2026-03-14 09:30:00")
        XCTAssertEqual(
            DateFormatLibrary.format("yyyy-MM-dd:+1M", now: base, locale: posix, timeZone: utc),
            "2026-04-14"
        )
    }
}
