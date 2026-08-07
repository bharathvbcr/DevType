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
    }

    /// The whole point: Apple's `debugDescription` is the only explanation for a guardrail
    /// refusal, so it must survive into the report verbatim.
    func testGuardrailFailureDetailSurvivesIntoTheReport() {
        let store = AIDiagnosticsStore()
        let detail = "Content flagged by safety classifier (input)"
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
        XCTAssertTrue(
            text.contains(detail),
            "Apple's Context.debugDescription is the only explanation available and must not be dropped."
        )
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
            store.recordFailure(kind: "k\(i)", error: "e", detail: "d")
        }
        let failures = store.recentFailures()

        XCTAssertEqual(failures.count, AIDiagnosticsStore.capacity, "Store must stay bounded.")
        XCTAssertEqual(
            failures.last?.kind,
            "k\(AIDiagnosticsStore.capacity + 9)",
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
        XCTAssertTrue(
            report.contains("flagged by safety classifier"),
            "The refusal detail must reach the pasted report, not just OSLog."
        )
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
