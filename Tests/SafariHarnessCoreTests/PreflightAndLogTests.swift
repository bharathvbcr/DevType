import ExpanderEngine
import XCTest
@testable import SafariHarnessCore

final class VersionCheckTests: XCTestCase {
    func testEqualBuildMatches() {
        XCTAssertEqual(VersionCheck.compare(installed: "438", expected: 438), .match(438))
        XCTAssertEqual(VersionCheck.compare(installed: " 438\n", expected: 438), .match(438))
    }

    func testDifferentBuildIsAMismatchThatNamesBothNumbers() {
        let result = VersionCheck.compare(installed: "437", expected: 438)
        XCTAssertEqual(result, .mismatch(installed: "437", expected: 438))
        XCTAssertTrue(result.summary.contains("437") && result.summary.contains("438"))
        XCTAssertFalse(result.isMatch)
    }

    func testUnreadableSidesAreNeverAMatch() {
        XCTAssertFalse(VersionCheck.compare(installed: nil, expected: 438).isMatch)
        XCTAssertFalse(VersionCheck.compare(installed: "", expected: 438).isMatch)
        XCTAssertFalse(VersionCheck.compare(installed: "438", expected: nil).isMatch)
        XCTAssertFalse(VersionCheck.compare(installed: "1.3.0", expected: 438).isMatch)
    }
}

final class StaleProcessTests: XCTestCase {
    func testProcessLaunchedBeforeTheBinaryWasWrittenIsStale() {
        let written = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(StaleProcessCheck.isStale(launchDate: Date(timeIntervalSince1970: 900), binaryModified: written), true)
        XCTAssertEqual(StaleProcessCheck.isStale(launchDate: Date(timeIntervalSince1970: 1001), binaryModified: written), false)
        XCTAssertEqual(StaleProcessCheck.isStale(launchDate: Date(timeIntervalSince1970: 1100), binaryModified: written), false)
    }

    func testUnknownTimesAreNeitherStaleNorFresh() {
        XCTAssertNil(StaleProcessCheck.isStale(launchDate: nil, binaryModified: Date()))
        XCTAssertNil(StaleProcessCheck.isStale(launchDate: Date(), binaryModified: nil))
    }
}

final class LibraryProbeTests: XCTestCase {
    private let spec = HarnessSnippetSpec()

    private func library(_ snippets: [SnippetModel], groupEnabled: Bool = true, includeApps: [String] = []) throws -> Data {
        let group = SnippetGroup(name: "G", enabled: groupEnabled, includeApps: includeApps, snippets: snippets)
        return try JSONEncoder().encode(SnippetDocument(groups: [group]))
    }

    private func mine(_ patch: (inout SnippetModel) -> Void = { _ in }) -> SnippetModel {
        var s = SnippetModel(title: "h", triggerKeyword: spec.trigger, replacementText: spec.expansion, isCaseSensitive: true)
        patch(&s)
        return s
    }

    func testValidSnippetPasses() throws {
        let report = LibraryProbe.evaluate(data: try library([mine()]), spec: spec)
        XCTAssertTrue(report.ok, "\(report.problems)")
        XCTAssertEqual(report.snippetCount, 1)
    }

    func testMissingSnippetIsReportedNotAssumed() throws {
        let other = SnippetModel(title: "x", triggerKeyword: ";other", replacementText: "y")
        let report = LibraryProbe.evaluate(data: try library([other]), spec: spec)
        XCTAssertFalse(report.found)
        XCTAssertFalse(report.ok)
    }

    func testWrongTextDisabledSecretAndRestrictionsAreEachProblems() throws {
        let bad: [(String, (inout SnippetModel) -> Void)] = [
            ("text", { $0.replacementText = "something else" }),
            ("disabled", { $0.enabled = false }),
            ("rich", { $0.isPlainText = false }),
            ("ai", { $0.aiTransform = "proofread" }),
            ("includeApps", { $0.includeApps = ["com.apple.Notes"] }),
            ("excludeApps", { $0.excludeApps = ["com.apple.Safari"] })
        ]
        for (name, patch) in bad {
            let report = LibraryProbe.evaluate(data: try library([mine(patch)]), spec: spec)
            XCTAssertFalse(report.ok, name)
        }
    }

    func testDisabledGroupAndGroupRestrictedAwayFromSafariAreProblems() throws {
        XCTAssertFalse(LibraryProbe.evaluate(data: try library([mine()], groupEnabled: false), spec: spec).ok)
        XCTAssertFalse(LibraryProbe.evaluate(data: try library([mine()], includeApps: ["com.apple.Notes"]), spec: spec).ok)
    }

    func testEarlierFiringPrefixTriggerIsAProblemButALongerTriggerIsOnlyAWarning() throws {
        let prefix = SnippetModel(title: "p", triggerKeyword: ";dth", replacementText: "x")
        XCTAssertFalse(LibraryProbe.evaluate(data: try library([mine(), prefix]), spec: spec).ok)
        let longer = SnippetModel(title: "l", triggerKeyword: spec.trigger + "2", replacementText: "x")
        let report = LibraryProbe.evaluate(data: try library([mine(), longer]), spec: spec)
        XCTAssertTrue(report.ok)
        XCTAssertFalse(report.warnings.isEmpty)
    }

    func testDuplicateTriggerIsAProblem() throws {
        XCTAssertFalse(LibraryProbe.evaluate(data: try library([mine(), mine()]), spec: spec).ok)
    }

    func testUndecodableLibraryRefuses() {
        let report = LibraryProbe.evaluate(data: Data("not a library".utf8), spec: spec)
        XCTAssertFalse(report.ok)
        XCTAssertFalse(report.problems.isEmpty)
    }

    func testSpecRulesRejectWordTriggersMultiLineAndMacroExpansions() {
        XCTAssertTrue(HarnessSnippetSpec().problems.isEmpty)
        XCTAssertFalse(HarnessSnippetSpec(trigger: "dtharness").problems.isEmpty)
        XCTAssertFalse(HarnessSnippetSpec(trigger: ";x").problems.isEmpty)
        XCTAssertFalse(HarnessSnippetSpec(trigger: ";dth é").problems.isEmpty)
        XCTAssertFalse(HarnessSnippetSpec(expansion: "a\nb").problems.isEmpty)
        XCTAssertFalse(HarnessSnippetSpec(expansion: "{{date}}").problems.isEmpty)
        XCTAssertFalse(HarnessSnippetSpec(trigger: ";abcd", expansion: "x;abcd").problems.isEmpty)
    }

    func testEditorURLRoundTripsThroughDevTypesOwnParser() throws {
        let url = HarnessSnippetSpec().editorURL
        guard case .command(.newSnippet(let title, let trigger, let text)) = DevTypeURLParser.parse(url) else {
            return XCTFail("DevType's parser rejected \(url)")
        }
        XCTAssertEqual(trigger, HarnessConstants.defaultTrigger)
        XCTAssertEqual(text, HarnessConstants.defaultExpansion)
        XCTAssertFalse(title.isEmpty)
    }

    func testLibraryLocationPrefersTheConfiguredPath() {
        let home = URL(fileURLWithPath: "/Users/u")
        XCTAssertEqual(LibraryLocation.resolve(storeFilePath: "/Volumes/x/snippets.json", home: home).path, "/Volumes/x/snippets.json")
        XCTAssertEqual(LibraryLocation.resolve(storeFilePath: nil, home: home).path, "/Users/u/Library/Application Support/DevType/snippets.json")
        XCTAssertEqual(LibraryLocation.resolve(storeFilePath: "", home: home).lastPathComponent, "snippets.json")
    }

    func testLibraryGuardIsByteExact() {
        let before = Data("abc".utf8)
        let sha = LibraryProbe.sha256(before)
        XCTAssertTrue(LibraryGuard.compare(beforeSHA: sha, after: before).isClean)
        XCTAssertFalse(LibraryGuard.compare(beforeSHA: sha, after: Data("abd".utf8)).isClean)
        XCTAssertFalse(LibraryGuard.compare(beforeSHA: sha, after: Data("abc\n".utf8)).isClean)
        XCTAssertFalse(LibraryGuard.compare(beforeSHA: sha, after: nil).isClean)
        XCTAssertEqual(sha, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class LogParserTests: XCTestCase {
    private let stamp = "2026-10-25 20:34:35.185123+0530"

    func line(_ text: String) -> String { "\(stamp)  0x1f  Info        0x0  123  0  DevType: [com.devtype.app:Inject] \(text)" }

    func testTimestampsParseAndNonLogLinesAreSkipped() {
        let lines = LogParser.parse("Filtering the log data using \"subsystem\"\n" + line("[Inject] outcome=succeeded") + "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].text.contains("outcome=succeeded"))
    }

    func testAllFiveOutcomeVariantsAreRecognised() {
        XCTAssertEqual(LogParser.injectOutcome(in: line("[Inject] outcome=succeeded")), .succeeded)
        XCTAssertEqual(LogParser.injectOutcome(in: line("[Inject] outcome=postedUnverified")), .postedUnverified)
        XCTAssertEqual(LogParser.injectOutcome(in: line("[Inject] outcome=refused reason=secure input")), .refused(reason: "secure input"))
        XCTAssertEqual(LogParser.injectOutcome(in: line("[Inject] outcome=degradedAXOnly (Post Events missing)")), .degradedAXOnly)
        XCTAssertEqual(LogParser.injectOutcome(in: line("[Inject] outcome=failedSilent")), .failedSilent)
        XCTAssertNil(LogParser.injectOutcome(in: line("[Inject] outcome=somethingNew")))
        XCTAssertNil(LogParser.injectOutcome(in: line("[Inject] backspace refused")))
    }

    func testMarkersIncludingTheSettleTrail() {
        XCTAssertEqual(LogParser.classify("[SourceFocus] read after 12 ms, 2 polls — settled on a field"), .sourceFocus)
        XCTAssertEqual(LogParser.classify("[Inject] focus not yet vouched after the erase — re-reading after settle (attempt 1/3)"), .settleTrail)
        XCTAssertEqual(LogParser.classify("[Debounce] hold armed gen=1"), .debounce)
        XCTAssertEqual(LogParser.classify("[Inject] outcome=succeeded"), .injectOutcome)
        XCTAssertEqual(LogParser.classify("[Inject] erase aborted"), .inject)
        XCTAssertNil(LogParser.classify("[Permission] fine"))
    }

    func testTimestampUnitsRatioAndItsVerdict() {
        let text = line("[Debounce] event timestamp units ratio=1.0003 (≈1 nanoseconds; ≈0.024 mach ticks)")
        XCTAssertEqual(LogParser.timestampUnitsRatio(in: text) ?? 0, 1.0003, accuracy: 1e-9)
        XCTAssertTrue(TimestampUnitsVerdict.assess(ratio: 1.0003).isPass)
        XCTAssertFalse(TimestampUnitsVerdict.assess(ratio: 0.024).isPass)
        XCTAssertFalse(TimestampUnitsVerdict.assess(ratio: nil).isPass)
        if case .notFound = TimestampUnitsVerdict.assess(ratio: nil) {} else { XCTFail("absence must be NOT FOUND, never a pass") }
        XCTAssertNil(LogParser.timestampUnitsRatio(in: line("[Debounce] hold armed ratio=1.0")))
    }

    /// A build that converts ticks logs both ratios; the converted one decides. A tick-reporting
    /// tap with no conversion (build 438's `ratio=0.0240`) is the failure this check exists for.
    func testTheConvertedRatioDecidesWhenTheBuildConverts() {
        let text = line("[Debounce] event timestamp units ratio=0.0240 unit=machTicks converted=1.0000")
        XCTAssertEqual(LogParser.timestampUnitsRatio(in: text) ?? 0, 0.024, accuracy: 1e-9)
        XCTAssertEqual(LogParser.timestampUnitsConvertedRatio(in: text) ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertTrue(TimestampUnitsVerdict.assess(ratio: 0.024, converted: 1.0).isPass)
        XCTAssertFalse(TimestampUnitsVerdict.assess(ratio: 0.024, converted: 0.024).isPass)
        XCTAssertFalse(TimestampUnitsVerdict.assess(ratio: 1.0, converted: 41.7).isPass,
                       "nanoseconds converted as ticks would put every key in the future")
        let unconverted = line("[Debounce] event timestamp units ratio=0.0240 (≈1 nanoseconds; ≈0.024 mach ticks)")
        XCTAssertNil(LogParser.timestampUnitsConvertedRatio(in: unconverted))
        XCTAssertFalse(TimestampUnitsVerdict.assess(ratio: 0.024, converted: nil).isPass)
    }

    func testExcerptCapsAndReportsWhatItDropped() {
        let base = LogParser.parse((0..<10).map { _ in line("[Inject] outcome=succeeded") }.joined(separator: "\n"))
        let all = LogParser.excerpt(base, from: .distantPast, to: .distantFuture, cap: 4)
        XCTAssertEqual(all.kept.count, 4)
        XCTAssertEqual(all.dropped, 6)
    }

    func testBuildSplitsLinesPerCaseWindowAndFindsTheUnitsLineOutsideIt() {
        let early = "2026-10-25 20:00:00.000000+0530  0x1  Info  0x0  1  0  DevType: [com.devtype.app:Debounce] [Debounce] event timestamp units ratio=1.0000 (x)"
        let inWindow = "2026-10-25 20:34:36.000000+0530  0x1  Info  0x0  1  0  DevType: [com.devtype.app:Inject] [Inject] outcome=succeeded"
        let outside = "2026-10-25 20:40:00.000000+0530  0x1  Info  0x0  1  0  DevType: [com.devtype.app:Inject] [Inject] outcome=failedSilent"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        let start = f.date(from: "2026-10-25 20:34:35.000000+0530")!
        var result = CaseResult(id: "c", title: "c", status: .pass, summary: "", started: start, ended: start.addingTimeInterval(2))
        result.plannedEvents = 1
        let logs = CollectedLogs.build(mainLines: LogParser.parse(inWindow + "\n" + outside), unitsLines: LogParser.parse(early),
                                       results: [result], queryNote: "q")
        XCTAssertEqual(logs.perCase["c"]?.kept.count, 1)
        XCTAssertEqual(logs.outcomes["c"], [.succeeded])
        XCTAssertTrue(logs.unitsVerdict.isPass)
    }
}
