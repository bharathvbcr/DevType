import XCTest
@testable import ExpanderEngine

final class DateFormatLibraryTests: XCTestCase {

    /// 2026-08-02 15:04:05 GMT — a Sunday.
    private var fixedNow: Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "GMT")
        components.year = 2026
        components.month = 8
        components.day = 2
        components.hour = 15
        components.minute = 4
        components.second = 5
        return components.date!
    }

    private let posix = Locale(identifier: "en_US_POSIX")
    private var gmt: TimeZone { TimeZone(identifier: "GMT")! }

    private func format(_ spec: String) -> String {
        DateFormatLibrary.format(spec, now: fixedNow, locale: posix, timeZone: gmt)
    }

    /// DateFormatter emits narrow no-break spaces (U+202F) around AM/PM on
    /// modern macOS — normalize for stable assertions.
    private func normalized(_ string: String) -> String {
        string.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: - Pattern presets

    func testUSPreset() {
        XCTAssertEqual(format("us"), "08/02/2026")
    }

    func testUSLongPreset() {
        XCTAssertEqual(format("uslong"), "August 2, 2026")
    }

    func testISOPreset() {
        XCTAssertEqual(format("iso"), "2026-08-02")
    }

    func testEUPreset() {
        XCTAssertEqual(format("eu"), "02/08/2026")
    }

    func testTime24Preset() {
        XCTAssertEqual(format("time24"), "15:04")
    }

    func testWeekdayPreset() {
        XCTAssertEqual(format("weekday"), "Sunday")
    }

    func testMonthYearPreset() {
        XCTAssertEqual(format("monthyear"), "August 2026")
    }

    func testDayAndYearPresets() {
        XCTAssertEqual(format("day"), "02")
        XCTAssertEqual(format("year"), "2026")
    }

    // MARK: - Style presets

    func testFullPreset() {
        XCTAssertEqual(format("full"), "Sunday, August 2, 2026")
    }

    func testLongPreset() {
        XCTAssertEqual(format("long"), "August 2, 2026")
    }

    func testMediumPreset() {
        XCTAssertEqual(format("medium"), "Aug 2, 2026")
    }

    func testShortPreset() {
        XCTAssertEqual(format("short"), "8/2/26")
    }

    func testTimePresets() {
        XCTAssertEqual(normalized(format("time")), "3:04:05 PM")
        XCTAssertEqual(normalized(format("timeshort")), "3:04 PM")
    }

    func testDateTimePreset() {
        XCTAssertEqual(normalized(format("datetime")), "Aug 2, 2026 at 3:04 PM")
    }

    // MARK: - Lookup behavior

    func testPresetLookupIsCaseInsensitive() {
        XCTAssertEqual(format("US"), "08/02/2026")
        XCTAssertEqual(format("Iso"), "2026-08-02")
        XCTAssertEqual(format(" FULL "), "Sunday, August 2, 2026")
    }

    func testUnknownSpecFallsBackToRawPattern() {
        XCTAssertEqual(format("yyyy-MM-dd HH:mm"), "2026-08-02 15:04")
        XCTAssertEqual(format("EEEE"), "Sunday")
    }

    func testEveryPresetHasUniqueIDAndTitle() {
        let ids = DateFormatLibrary.presets.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for preset in DateFormatLibrary.presets {
            XCTAssertFalse(preset.title.isEmpty)
            XCTAssertEqual(DateFormatLibrary.preset(named: preset.id), preset)
        }
    }

    // MARK: - Macro pipeline integration (local calendar → tz/locale independent)

    /// Same instant expressed in the *current* calendar, so rendered date fields
    /// are 2026-08-02 regardless of the test machine's time zone.
    private var localNow: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 2
        components.hour = 15
        components.minute = 4
        return Calendar.current.date(from: components)!
    }

    func testTEMacroRendersPresetName() {
        let tokens = MacroParser.parse("Date: %date:us%")
        let result = MacroParser.render(tokens: tokens, now: localNow)
        XCTAssertEqual(result.text, "Date: 08/02/2026")
    }

    func testTEMacroRawPatternStillWorks() {
        let tokens = MacroParser.parse("%date:yyyy-MM-dd%")
        let result = MacroParser.render(tokens: tokens, now: localNow)
        XCTAssertEqual(result.text, "2026-08-02")
    }

    func testMustacheDateTagRendersPresetName() {
        let result = DynamicTemplateEngine.shared.resolve("Today: {{date:iso}}", currentDate: localNow)
        XCTAssertEqual(result.text, "Today: 2026-08-02")
    }

    func testMacroPreviewRendersPresetName() {
        XCTAssertEqual(MacroPreview.render("%date:us%", now: localNow), "08/02/2026")
    }
}
