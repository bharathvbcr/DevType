import XCTest
@testable import ExpanderEngine

/// The diagnostic report must be able to explain a snippet that did not expand.
///
/// The report that prompted this work described a totally healthy app — tap running, engine
/// enabled, all permissions granted, 57 injects at 100% delivery, zero refusals — while the user
/// was watching triggers do nothing. Every counter in it described expansions that *happened*.
/// Nothing described one that never started, so the outage was invisible in the one artifact
/// that gets pasted into a bug report.
///
/// These tests pin the three sections that close that gap. They assert on the rendered text
/// because the rendered text is the deliverable: a field that is populated but never printed
/// helps nobody.
final class ExpansionOutageReportTests: XCTestCase {

    private func gate() -> DiagnosticReport.ExpandGateSnapshot {
        DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: true,
            isSecureField: false,
            hasIMEMarkedText: false,
            shouldBlockExpand: false,
            blockReason: "ok"
        )
    }

    private func context(
        matchingSuspensionLines: [String] = [],
        matchDropLines: [String] = [],
        unreachableSnippetLines: [String] = []
    ) -> DiagnosticReport.Context {
        DiagnosticReport.Context(
            bundleID: "com.devtype.app",
            appPath: "/Applications/DevType.app",
            executablePath: "/Applications/DevType.app/Contents/MacOS/DevType",
            cdHash: nil,
            designatedRequirement: nil,
            snapshot: PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true),
            tapRunning: true,
            engineEnabled: true,
            secureInputActive: false,
            displayStatus: "Status: Active",
            lastInjectOutcome: "succeeded",
            frontmostAppName: "Claude",
            frontmostBundleID: "com.anthropic.claudefordesktop",
            frontmostPID: 42,
            mutedApps: [],
            expandGate: gate(),
            expandGateAtLastRefuse: nil,
            siblingPaths: [],
            macOSVersion: "27.0",
            appVersion: "0.0.6 (55)",
            matchingSuspensionLines: matchingSuspensionLines,
            matchDropLines: matchDropLines,
            unreachableSnippetLines: unreachableSnippetLines
        )
    }

    /// The headline case: matching suspended by a leaked panel token. The report must say so in
    /// terms nobody can read past, and must name the holder.
    func testReportShowsASuspendedMatcherAndNamesTheHolder() {
        let report = DiagnosticReport.formatFullReport(
            context: context(
                matchingSuspensionLines: [
                    "Matching: SUSPENDED — typed triggers cannot expand while this is true",
                    "  held by AIActionPanel for 4210s"
                ]
            ),
            logLines: []
        )
        XCTAssertTrue(report.contains("-- Matching state --"), "The section must be printed.")
        XCTAssertTrue(report.contains("SUSPENDED"))
        XCTAssertTrue(
            report.contains("AIActionPanel"),
            "Naming the holder is what turns a day of bisecting into one line."
        )
    }

    /// The healthy case still has to be stated positively. "Matching: running" present and
    /// explicit is what lets a reader rule it out; an absent section reads as untested.
    func testReportStatesMatchingIsRunningWhenItIs() {
        let report = DiagnosticReport.formatFullReport(
            context: context(matchingSuspensionLines: ["Matching: running (not suspended)"]),
            logLines: []
        )
        XCTAssertTrue(report.contains("Matching: running (not suspended)"))
    }

    /// A trigger that matched and was dropped before injection produces no inject telemetry at
    /// all — it has to be counted separately or it is invisible.
    func testReportShowsMatchesDroppedBeforeInjection() {
        let report = DiagnosticReport.formatFullReport(
            context: context(
                matchDropLines: [
                    "Matched-then-dropped: 12 (planner-refused=12 secure-input=0 already-expanding=0)",
                    "  last: plannerRefused trigger=`name app=com.anthropic.claudefordesktop at 2026-08-10T19:00:00Z"
                ]
            ),
            logLines: []
        )
        XCTAssertTrue(report.contains("-- Matched but not expanded --"))
        XCTAssertTrue(report.contains("planner-refused=12"))
        XCTAssertTrue(report.contains("trigger=`name"))
    }

    /// Snippets that can never respond to typing must be named, because in the UI they look
    /// identical to ones that work.
    func testReportNamesSnippetsThatCanNeverExpandByTyping() {
        let report = DiagnosticReport.formatFullReport(
            context: context(
                unreachableSnippetLines: [
                    "4 secret snippet(s) never expand from a typed trigger by design —"
                        + " use the inline search panel instead:",
                    "  `apass",
                    "  `pass"
                ]
            ),
            logLines: []
        )
        XCTAssertTrue(report.contains("-- Snippets that never expand by typing --"))
        XCTAssertTrue(report.contains("`pass"))
        XCTAssertTrue(report.contains("secret snippet(s) never expand"))
    }

    /// All three sections are always present, even when everything is fine. A section that only
    /// appears when broken cannot be used to rule the failure out.
    func testAllOutageSectionsArePresentEvenWhenHealthy() {
        let report = DiagnosticReport.formatFullReport(context: context(), logLines: [])
        for section in [
            "-- Matching state --",
            "-- Matched but not expanded --",
            "-- Snippets that never expand by typing --"
        ] {
            XCTAssertTrue(report.contains(section), "Missing section: \(section)")
        }
    }

    // MARK: - End-to-end through the engine

    /// The engine's own diagnostics, not a hand-built context: the wiring between the counters
    /// and the report is exactly what was missing before.
    func testEngineReportsItsOwnSuspensionAndDropCounters() {
        let engine = EventTapEngine()
        XCTAssertEqual(engine.matchingSuspensionDiagnostics(), ["Matching: running (not suspended)"])
        XCTAssertEqual(engine.matchDropDiagnostics(), ["Matched-then-dropped: none"])

        let suspension = engine.suspendMatching(reason: "InlineSearchPanel")
        XCTAssertTrue(engine.matchingSuspensionDiagnostics().joined().contains("InlineSearchPanel"))

        engine.recordMatchDrop(
            reason: "plannerRefused",
            trigger: "`name",
            bundleID: "com.anthropic.claudefordesktop"
        )
        let drops = engine.matchDropDiagnostics().joined(separator: "\n")
        XCTAssertTrue(drops.contains("planner-refused=1"), drops)
        XCTAssertTrue(drops.contains("`name"), drops)

        suspension.release()
        XCTAssertEqual(engine.matchingSuspensionDiagnostics(), ["Matching: running (not suspended)"])
    }

    /// Secrets are filtered out of the matcher, so the diagnostics have to read the unfiltered
    /// library — the first version of this read the filtered snapshot and could never have
    /// reported a secret at all.
    func testSecretTriggersAreReportedFromTheUnfilteredLibrary() {
        let engine = EventTapEngine()
        engine.snippets = [
            SnippetModel(title: "Password", triggerKeyword: "`pass", replacementText: "", isSecret: true),
            SnippetModel(title: "Name", triggerKeyword: "`name", replacementText: "Bharath")
        ]
        let lines = engine.silentNoExpandDiagnostics().joined(separator: "\n")
        XCTAssertTrue(lines.contains("`pass"), "A secret trigger must be named: \(lines)")
        XCTAssertFalse(lines.contains("`name"), "A working trigger must not be listed as unreachable.")
    }

    /// Two snippets sharing a trigger: the second can never fire, and nothing used to say so.
    func testShadowedDuplicateTriggersAreReported() {
        let engine = EventTapEngine()
        engine.snippets = [
            SnippetModel(title: "First", triggerKeyword: "`dup", replacementText: "one"),
            SnippetModel(title: "Second", triggerKeyword: "`dup", replacementText: "two")
        ]
        let lines = engine.silentNoExpandDiagnostics().joined(separator: "\n")
        XCTAssertTrue(lines.contains("Second"), "The shadowed snippet must be named: \(lines)")
        XCTAssertTrue(lines.contains("shadowed by"), lines)
    }

    /// A clean library must produce no noise, or the section becomes something people skip.
    func testHealthyLibraryReportsNothingUnreachable() {
        let engine = EventTapEngine()
        engine.snippets = [
            SnippetModel(title: "Name", triggerKeyword: "`name", replacementText: "Bharath"),
            SnippetModel(title: "Mail", triggerKeyword: "`mail", replacementText: "a@b.c")
        ]
        XCTAssertEqual(engine.silentNoExpandDiagnostics(), [])
    }
}
