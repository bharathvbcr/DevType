import AppKit
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// Selection drafts and relative date phrases. Both are pure: the draft is built
/// from text the palette already captured, and the phrase resolves through the
/// same catalogue row as `+3w`.
final class SelectionSnippetAndPhraseTests: XCTestCase {

    func testCapturedSelectionPrefillsReplacementAndLeavesTriggerEmpty() {
        let draft = SnippetManagerViewController.SelectionSnippetDraft.make(fromCapturedText: "Hello, selection")
        XCTAssertEqual(draft?.replacementText, "Hello, selection")
        XCTAssertEqual(draft?.triggerKeyword, "")
        XCTAssertEqual(draft?.title, "")
        XCTAssertEqual(draft?.isSecret, false)
        // SnippetModel's default is false. A blank new snippet's switch is on.
        XCTAssertEqual(draft?.isCaseSensitive, true)
    }

    func testBlankSelectionStaysOnTheEmptyDraftPath() {
        XCTAssertNil(SnippetManagerViewController.SelectionSnippetDraft.make(fromCapturedText: nil))
        XCTAssertNil(SnippetManagerViewController.SelectionSnippetDraft.make(fromCapturedText: ""))
        XCTAssertNil(SnippetManagerViewController.SelectionSnippetDraft.make(fromCapturedText: "  \n\t"))
        XCTAssertNil(SnippetManagerViewController.SelectionSnippetDraft.make(fromCapturedText: "\u{200B}"))
        XCTAssertNil(SnippetManagerViewController.SelectionSnippetDraft.make(fromCapturedText: "\u{FFFC}"))
    }

    func testSelectionPrefillTruncatesToTheLibraryLimit() {
        let limit = SnippetImporter.SnippetImportLimits.maxReplacementCharacters
        let captured = String(repeating: "a", count: limit + 25)
        let draft = SnippetManagerViewController.SelectionSnippetDraft.make(fromCapturedText: captured)
        XCTAssertEqual(draft?.replacementText.count, limit)
        XCTAssertEqual(draft?.triggerKeyword, "")
    }

    func testNewAliasRanksCreateSnippetFirst() {
        let hits = CommandPaletteCatalog.matchCommands(
            query: "new",
            loc: .shared,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            commandUsageBoost: { _ in 0 }
        )
        XCTAssertEqual(hits.first?.command.id, "nav.createSnippet")
    }

    func testRelativePhrasesMatchThePlusOffsetInsertText() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        func insert(_ query: String) -> String {
            CommandPaletteCatalog.matchCommands(
                query: query,
                loc: .shared,
                now: now,
                locale: locale,
                timeZone: timeZone,
                commandUsageBoost: { _ in 0 }
            ).first?.insertText ?? ""
        }

        let threeWeeks = insert("in 3 weeks")
        XCTAssertFalse(threeWeeks.isEmpty)
        XCTAssertEqual(threeWeeks, insert("+3w"))
        XCTAssertEqual(insert("3 weeks from now"), threeWeeks)
        XCTAssertEqual(insert("in a week"), insert("+1w"))
        XCTAssertEqual(insert("in 2 days"), insert("+2d"))

        let today = CommandPaletteCatalog.resolveDate(
            .offsetDays(0, format: "medium"),
            now: now,
            locale: locale,
            timeZone: timeZone
        )
        XCTAssertNotEqual(threeWeeks, today)

        guard case .relativeDays(let days, let format, _) = CommandPaletteCatalog.parseTypedQuery("in 3 weeks") else {
            return XCTFail("in 3 weeks did not resolve as a day offset")
        }
        XCTAssertEqual(days, 21)
        XCTAssertEqual(format, "medium")

        guard case .relativeOffset(let month, _, _) = CommandPaletteCatalog.parseTypedQuery("in 1 month") else {
            return XCTFail("in 1 month did not resolve as an offset")
        }
        XCTAssertEqual(month, DateOffset(months: 1))
        guard case .relativeOffset(let minute, _, _) = CommandPaletteCatalog.parseTypedQuery("+1m") else {
            return XCTFail("+1m did not resolve as an offset")
        }
        XCTAssertEqual(minute, DateOffset(minutes: 1))
        XCTAssertNotEqual(insert("in 1 month"), insert("+1m"))

        guard case .relativeDays(_, let fridayFormat, let fridayTrigger) = CommandPaletteCatalog.parseTypedQuery("next friday") else {
            return XCTFail("next friday did not stay on the weekday path")
        }
        XCTAssertEqual(fridayFormat, "full")
        XCTAssertEqual(fridayTrigger, "next friday")
    }

    func testOtherNaturalUnitsMatchThePlusOffsetAndOutOfRangeIsRejected() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        func insert(_ query: String) -> String {
            CommandPaletteCatalog.matchCommands(
                query: query,
                loc: .shared,
                now: now,
                locale: locale,
                timeZone: timeZone,
                commandUsageBoost: { _ in 0 }
            ).first?.insertText ?? ""
        }

        XCTAssertEqual(insert("in 2 hours"), insert("+2h"))
        XCTAssertEqual(insert("in an hour"), insert("+1h"))
        XCTAssertEqual(insert("in 45 minutes"), insert("+45m"))
        XCTAssertEqual(insert("in 10 seconds"), insert("+10s"))
        XCTAssertEqual(insert("in 2 years"), insert("+2y"))
        XCTAssertEqual(insert("next week"), insert("+1w"))
        XCTAssertEqual(insert("next month"), insert("in 1 month"))
        XCTAssertEqual(insert("in a month"), insert("next month"))
        XCTAssertEqual(insert("3 months from now"), insert("in 3 months"))
        XCTAssertEqual(insert("next year"), insert("+1y"))
        XCTAssertEqual(insert("next day"), insert("+1d"))
        XCTAssertFalse(insert("in 2 hours").isEmpty)

        XCTAssertNil(CommandPaletteCatalog.parseTypedQuery("in 0 days"))
        XCTAssertNil(CommandPaletteCatalog.parseTypedQuery("in 1000 days"))
        guard case .relativeDays(let days, _, _) = CommandPaletteCatalog.parseTypedQuery("in 999 days") else {
            return XCTFail("999 days is inside 1...999")
        }
        XCTAssertEqual(days, 999)
        guard case .relativeOffset(let seconds, _, _) = CommandPaletteCatalog.parseTypedQuery("in 999 seconds") else {
            return XCTFail("999 seconds did not resolve as an offset")
        }
        XCTAssertEqual(seconds, DateOffset(seconds: 999))
    }

    func testServiceReadsTheLegacyPasteboardTypeAndBlankSelectionDoesNotMentionThePalette() {
        let legacy = NSPasteboard.PasteboardType("NSStringPboardType")
        let board = NSPasteboard.withUniqueName()
        board.declareTypes([legacy], owner: nil)
        board.setString("Hello from Services", forType: legacy)
        XCTAssertEqual(
            SnippetManagerViewController.SelectionSnippetDraft.serviceText(from: board),
            "Hello from Services"
        )

        let blank = NSPasteboard.withUniqueName()
        blank.declareTypes([.string], owner: nil)
        blank.setString(" \n\t", forType: .string)
        let delegate = AppDelegate()
        var error: NSString?
        delegate.newSnippetFromSelection(blank, userData: nil, error: &error)
        XCTAssertEqual(error as String?, LocalizationManager.shared.s("ai.refuse.noSelection"))
        XCTAssertNotEqual(error as String?, LocalizationManager.shared.s("ai.alert.noSelection.message"))
        delegate.newSnippetFromSelection(blank, userData: nil, error: nil)
    }
}
