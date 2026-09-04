import XCTest
@testable import ExpanderEngine

// MARK: - On-device AI diagnostics

/// Regression cover for the reporting gap that made a guardrail refusal unexplainable:
/// `mapGenerationError` discarded `GenerationError.Context.debugDescription`, nothing logged
/// the failure, and `DiagnosticReport` had no AI section — so the artifact users actually
/// paste said nothing about the model.
final class AIDiagnosticsTests: XCTestCase {

    private func makeISO() -> ISO8601DateFormatter {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso
    }

    // MARK: - Store

    func testEmptyStoreStillReportsStateRatherThanNothing() {
        let store = AIDiagnosticsStore()
        let lines = store.diagnosticLines(
            enabled: false,
            availability: "unavailable — appleIntelligenceNotEnabled",
            localeNote: "supported (en_US)",
            iso: makeISO()
        )
        let text = lines.joined(separator: "\n")

        // A quiet section must still answer "is it on, and is the model usable?".
        XCTAssertTrue(text.contains("Enabled: false"))
        XCTAssertTrue(text.contains("appleIntelligenceNotEnabled"))
        XCTAssertTrue(text.contains("Last failure: (none)"))
        XCTAssertTrue(text.contains("Last success: (none)"))
        XCTAssertTrue(text.contains("Selection reads: (none this session)"))
    }

    // MARK: - Selection reads

    /// "Prompt Enhance says nothing is selected" was unfalsifiable from a diagnostic report:
    /// nothing recorded whether the read died on Accessibility, Secure Input, a mute, a missing
    /// focused element, or a genuinely empty selection.
    func testSelectionReadOutcomeReachesTheReport() {
        let store = AIDiagnosticsStore()
        store.recordSelectionRead(
            outcome: "secureInput",
            bundleID: "com.google.Chrome",
            candidateCount: 0,
            characters: 0
        )
        let text = store.diagnosticLines(
            enabled: true,
            availability: "available",
            localeNote: nil,
            iso: makeISO()
        ).joined(separator: "\n")

        XCTAssertTrue(text.contains("outcome=secureInput"))
        XCTAssertTrue(text.contains("app=com.google.Chrome"))
        XCTAssertTrue(text.contains("axCandidates=0"))
    }

    /// One failed read is noise; the same failure in the same app every time is the bug report.
    func testSelectionReadBreakdownSeparatesOneOffFromAlways() {
        let store = AIDiagnosticsStore()
        for _ in 0..<4 {
            store.recordSelectionRead(
                outcome: "emptySelection",
                bundleID: "com.microsoft.VSCode",
                candidateCount: 1,
                characters: 0
            )
        }
        store.recordSelectionRead(
            outcome: "live",
            bundleID: "com.apple.TextEdit",
            candidateCount: 2,
            characters: 42
        )
        let text = store.diagnosticLines(
            enabled: true,
            availability: "available",
            localeNote: nil,
            iso: makeISO()
        ).joined(separator: "\n")

        XCTAssertTrue(text.contains("Selection reads: 5"))
        XCTAssertTrue(text.contains("emptySelection=4"))
        XCTAssertTrue(text.contains("live=1"))
        XCTAssertTrue(text.contains("chars=42"), "The last read is spelled out in full.")
    }

    /// **Privacy:** the store records how much was selected, never what. A diagnostic report is
    /// pasted into issue trackers and chat.
    func testSelectionReadNeverStoresTheSelectedText() {
        let store = AIDiagnosticsStore()
        let secret = "my bank password is hunter2"
        store.recordSelectionRead(
            outcome: "live",
            bundleID: "com.apple.Safari",
            candidateCount: 1,
            characters: secret.count
        )
        let text = store.diagnosticLines(
            enabled: true,
            availability: "available",
            localeNote: nil,
            iso: makeISO()
        ).joined(separator: "\n")

        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertTrue(text.contains("chars=\(secret.count)"))
    }

    func testSelectionReadRingIsBounded() {
        let store = AIDiagnosticsStore()
        for index in 0..<(AIDiagnosticsStore.capacity + 25) {
            store.recordSelectionRead(
                outcome: "live",
                bundleID: "app.\(index)",
                candidateCount: 1,
                characters: index
            )
        }
        let reads = store.recentSelectionReads()
        XCTAssertEqual(reads.count, AIDiagnosticsStore.capacity)
        XCTAssertEqual(
            reads.last?.characters,
            AIDiagnosticsStore.capacity + 24,
            "The ring must keep the newest entries, not the oldest."
        )

        store.reset()
        XCTAssertTrue(store.recentSelectionReads().isEmpty)
    }

    func testCappedAIRingsReportObservedAndRetainedCountsTruthfully() {
        let store = AIDiagnosticsStore()
        let total = AIDiagnosticsStore.capacity + 31
        for index in 0..<total {
            store.recordFailure(kind: "proofread", error: "refusal", detail: "detail")
            store.recordSelectionRead(
                outcome: "emptySelection",
                bundleID: "com.example.\(index)",
                candidateCount: 1,
                characters: 0
            )
        }

        let report = store.diagnosticLines(
            enabled: true,
            availability: "available",
            localeNote: nil,
            iso: makeISO()
        ).joined(separator: "\n")

        XCTAssertTrue(
            report.contains("\(total) failed (retained \(AIDiagnosticsStore.capacity)/\(AIDiagnosticsStore.capacity)"),
            report
        )
        XCTAssertTrue(
            report.contains("Selection reads: \(total) (retained \(AIDiagnosticsStore.capacity)/\(AIDiagnosticsStore.capacity)"),
            report
        )
    }

    /// Provider error prose is not a trustworthy diagnostics payload: frameworks may echo the
    /// selected text, prompt, endpoint body, or a local path. Preserve correlation/size evidence
    /// without copying the prose into the report users paste into support channels.
    func testGuardrailFailureDetailReachesTheReportAsContentFreeShape() {
        let store = AIDiagnosticsStore()
        let detail = "PRIVATE selected text /Users/person/document.txt bearer-token"
        store.recordFailure(
            kind: "promptenhance",
            error: "guardrailViolation",
            detail: detail
        )

        let text = store.diagnosticLines(
            enabled: true,
            availability: "available",
            localeNote: nil,
            iso: makeISO()
        ).joined(separator: "\n")

        XCTAssertTrue(text.contains("kind=promptenhance"), "Transform kind must be reported.")
        XCTAssertTrue(text.contains("error=guardrailViolation"))
        XCTAssertFalse(text.contains(detail))
        XCTAssertFalse(text.contains("PRIVATE selected text"))
        XCTAssertFalse(text.contains("bearer-token"))
        XCTAssertTrue(text.contains("detailChars=61"), text)
        XCTAssertTrue(text.contains("detailHash="), text)
    }

    func testFailureBoundaryRejectsFreeFormKindAndErrorLabels() {
        let store = AIDiagnosticsStore()
        let attackerControlled = String(repeating: "private-user-content/", count: 1_000)

        store.recordFailure(
            kind: attackerControlled,
            error: attackerControlled,
            detail: attackerControlled
        )

        let failure = store.recentFailures().last
        let report = store.diagnosticLines(
            enabled: true,
            availability: "available",
            localeNote: nil,
            iso: makeISO()
        ).joined(separator: "\n")
        XCTAssertEqual(failure?.kind, "unknown")
        XCTAssertEqual(failure?.error, "unknown")
        XCTAssertLessThan(failure?.detail.utf8.count ?? .max, 160)
        XCTAssertFalse(report.contains(attackerControlled))
        XCTAssertFalse(report.contains("private-user-content"))
    }

    func testMissingDetailIsStatedRatherThanBlank() {
        let store = AIDiagnosticsStore()
        store.recordFailure(kind: "proofread", error: "rateLimited", detail: "")
        let text = store.diagnosticLines(
            enabled: true, availability: "available", localeNote: nil, iso: makeISO()
        ).joined(separator: "\n")

        XCTAssertTrue(
            text.contains("(none provided)"),
            "An empty detail must read as explicitly absent, not as a blank line."
        )
    }

    /// One refusal is noise; the same error repeating is a reproducible bug.
    func testRepeatedErrorsAreAggregated() {
        let store = AIDiagnosticsStore()
        for _ in 0..<3 {
            store.recordFailure(kind: "condense", error: "guardrailViolation", detail: "d")
        }
        store.recordFailure(kind: "expand", error: "rateLimited", detail: "d")

        let text = store.diagnosticLines(
            enabled: true, availability: "available", localeNote: nil, iso: makeISO()
        ).joined(separator: "\n")

        XCTAssertTrue(text.contains("guardrailViolation=3"), "Expected aggregated counts.")
        XCTAssertTrue(text.contains("rateLimited=1"))
    }

    func testStoreIsBoundedAndKeepsMostRecent() {
        let store = AIDiagnosticsStore()
        for i in 0..<(AIDiagnosticsStore.capacity + 10) {
            store.recordFailure(
                kind: "k\(i)",
                error: "e",
                detail: "d",
                at: Date(timeIntervalSince1970: TimeInterval(i))
            )
        }
        let failures = store.recentFailures()

        XCTAssertEqual(failures.count, AIDiagnosticsStore.capacity, "Store must stay bounded.")
        XCTAssertEqual(failures.last?.kind, "unknown")
        XCTAssertEqual(
            failures.last?.at,
            Date(timeIntervalSince1970: TimeInterval(AIDiagnosticsStore.capacity + 9)),
            "Eviction must drop the oldest entries, not the newest."
        )
    }

    func testSuccessesAndFailuresAreCountedSeparately() {
        let store = AIDiagnosticsStore()
        store.recordSuccess(kind: "proofread")
        store.recordSuccess(kind: "rewrite")
        store.recordFailure(kind: "condense", error: "guardrailViolation", detail: "d")

        XCTAssertEqual(store.successes(), 2)
        XCTAssertEqual(store.recentFailures().count, 1)

        let text = store.diagnosticLines(
            enabled: true, availability: "available", localeNote: nil, iso: makeISO()
        ).joined(separator: "\n")
        XCTAssertTrue(text.contains("2 succeeded, 1 failed"))
        XCTAssertTrue(text.contains("Last success:"))
        XCTAssertTrue(text.contains("kind=rewrite"), "Last success should name the most recent kind.")
    }

    // MARK: - Report wiring

    /// Guards the actual gap: the section must reach `formatHeader`, not merely exist.
    func testFormatHeaderRendersTheAISection() {
        let store = AIDiagnosticsStore()
        store.recordFailure(
            kind: "promptenhance",
            error: "guardrailViolation",
            detail: "flagged by safety classifier"
        )
        let aiLines = store.diagnosticLines(
            enabled: true, availability: "available", localeNote: nil, iso: makeISO()
        )

        let context = DiagnosticReport.Context(
            bundleID: "com.devtype.app",
            appPath: "/Applications/DevType.app",
            executablePath: "/Applications/DevType.app/Contents/MacOS/DevType",
            cdHash: nil,
            designatedRequirement: nil,
            snapshot: PermissionSnapshot(
                canListenTap: true,
                canUseAX: true,
                canPostEvents: true
            ),
            tapRunning: true,
            engineEnabled: true,
            secureInputActive: false,
            displayStatus: "Active",
            lastInjectOutcome: nil,
            frontmostAppName: nil,
            frontmostBundleID: nil,
            frontmostPID: nil,
            mutedApps: [],
            expandGate: DiagnosticReport.ExpandGateSnapshot(
                canUseAX: true,
                axTrusted: true,
                focusedAvailable: true,
                isSecureField: false,
                hasIMEMarkedText: false,
                shouldBlockExpand: false,
                blockReason: "ok"
            ),
            siblingPaths: [],
            macOSVersion: "Version 26.0",
            appVersion: "test",
            aiLines: aiLines
        )

        let report = DiagnosticReport.formatHeader(context)
        XCTAssertTrue(report.contains("-- On-device AI --"), "Report must carry an AI section.")
        XCTAssertTrue(report.contains("guardrailViolation"))
        XCTAssertTrue(report.contains("detailChars=28"), report)
        XCTAssertTrue(report.contains("detailHash="), report)
        XCTAssertFalse(report.contains("flagged by safety classifier"))
    }

    /// A report built without AI lines must say so rather than render an empty heading.
    func testAbsentAILinesRenderExplicitPlaceholder() {
        let context = DiagnosticReport.Context(
            bundleID: "com.devtype.app",
            appPath: "/x", executablePath: "/x",
            cdHash: nil, designatedRequirement: nil,
            snapshot: PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true),
            tapRunning: true, engineEnabled: true, secureInputActive: false,
            displayStatus: "Active", lastInjectOutcome: nil,
            frontmostAppName: nil, frontmostBundleID: nil, frontmostPID: nil,
            mutedApps: [],
            expandGate: DiagnosticReport.ExpandGateSnapshot(
                canUseAX: true, axTrusted: true, focusedAvailable: true,
                isSecureField: false, hasIMEMarkedText: false,
                shouldBlockExpand: false, blockReason: "ok"
            ),
            siblingPaths: [], macOSVersion: "Version 26.0", appVersion: "test"
        )
        let report = DiagnosticReport.formatHeader(context)
        XCTAssertTrue(report.contains("-- On-device AI --"))
        XCTAssertTrue(report.contains("(not captured)"))
    }

    /// Live capture must not trap or return an empty section on any host, including
    /// macOS 14 where FoundationModels is absent and the transformer is a stub.
    func testLiveCaptureProducesUsableLinesOnAnyHost() {
        let lines = DiagnosticReport.captureAILines(store: AIDiagnosticsStore(), enabled: false)
        XCTAssertFalse(lines.isEmpty)
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Availability:"))
        XCTAssertTrue(text.contains("Enabled: false"))
    }
}
