import AppKit
import ApplicationServices
import Security
import XCTest
@testable import ExpanderEngine

final class DiagnosticReportTests: XCTestCase {
    func testPublicErrorMetadataCannotEchoLocalizedDescriptionOrDomain() {
        let secret = "PRIVATE /Users/person/file.txt provider-response-body"
        let error = NSError(
            domain: secret,
            code: 4_321,
            userInfo: [NSLocalizedDescriptionKey: secret]
        )

        let metadata = DevTypeLog.errorMetadata(error)

        XCTAssertTrue(metadata.contains("code=4321"))
        XCTAssertTrue(metadata.contains("type="))
        XCTAssertFalse(metadata.contains(secret))
        XCTAssertFalse(metadata.contains("provider-response-body"))
    }

    func testPublicTextMetadataRetainsShapeWithoutThePayload() {
        let secret = "PRIVATE provider response with /Users/person/file.txt"

        let metadata = DevTypeLog.publicTextMetadata(secret)

        XCTAssertTrue(metadata.contains("textChars=53"), metadata)
        XCTAssertTrue(metadata.contains("textHash="), metadata)
        XCTAssertFalse(metadata.contains(secret))
        XCTAssertFalse(metadata.contains("provider response"))
    }

    func testPublicLogProjectionsBoundIdentifiersAndNeverExposeFilesystemPaths() {
        let privatePath = "/Users/person/Private Client/Customer Alpha/contract.txt"
        let pathMetadata = DevTypeLog.publicPathMetadata(privatePath)
        XCTAssertTrue(pathMetadata.contains("pathHash="), pathMetadata)
        XCTAssertFalse(pathMetadata.contains(privatePath))
        XCTAssertFalse(pathMetadata.contains("Private Client"))

        let marker = "PRIVATE-PUBLIC-IDENTIFIER"
        let hostileIdentifier = marker + String(repeating: "x", count: 8_192)
        let bounded = DevTypeLog.boundedPublicIdentifier(
            hostileIdentifier,
            label: "bundleID"
        )
        XCTAssertTrue(bounded.contains("bundleIDHash="), bounded)
        XCTAssertFalse(bounded.contains(marker))
        XCTAssertLessThan(bounded.utf8.count, 256)

        XCTAssertEqual(
            DevTypeLog.boundedPublicIdentifier("com.apple.TextEdit", label: "bundleID"),
            "com.apple.TextEdit",
            "Ordinary app identity evidence should remain readable"
        )
    }

    func testInjectRefusalRecordingRemovesUserControlledPathsAtTheCanonicalBoundary() throws {
        let privatePath = "/Users/person/Private/Client Alpha/signature.png"
        let unsafeReason = "Image attachment missing or unreadable: \(privatePath)"
        let coordinator = PermissionCoordinator()
        coordinator.recordInjectOutcome(
            .refused(unsafeReason),
            refuseContext: PermissionCoordinator.InjectRefuseProvenance(reason: unsafeReason),
            path: "imagePaste"
        )

        guard case .refused(let recordedReason) = coordinator.lastRecordedInjectOutcome else {
            return XCTFail("Expected the refusal to remain a typed refusal")
        }
        let provenance = try XCTUnwrap(coordinator.lastRecordedInjectRefuseProvenance)

        XCTAssertEqual(recordedReason, "Image attachment missing or unreadable")
        XCTAssertEqual(provenance.reason, recordedReason)
        XCTAssertFalse(recordedReason.contains(privatePath))
        XCTAssertFalse(provenance.reason.contains(privatePath))
    }

    func testGeminiCredentialProjectionIsContentFreeAndDistinguishesReadFailure() {
        let secret = "AIza-private-key-never-export"
        let configured = DiagnosticReport.geminiCredentialState(for: .available(secret))
        let missing = DiagnosticReport.geminiCredentialState(for: .missing)
        let unavailable = DiagnosticReport.geminiCredentialState(
            for: .unavailable(.keychainStatus(errSecInteractionNotAllowed))
        )

        XCTAssertEqual(configured, .configured)
        XCTAssertEqual(missing, .missing)
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertFalse(String(describing: configured).contains(secret))
        XCTAssertFalse(String(describing: unavailable).contains(String(errSecInteractionNotAllowed)))
    }

    func testFormatHeaderIncludesIdentityCapabilitiesAndGate() {
        let gate = DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: false,
            isSecureField: nil,
            hasIMEMarkedText: nil,
            shouldBlockExpand: true,
            blockReason: "No focused AX element — expand blocked (fail-closed)"
        )
        let refuseGate = DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: false,
            isSecureField: nil,
            hasIMEMarkedText: nil,
            shouldBlockExpand: true,
            blockReason: "AX focus query timed out — expand blocked (fail-closed)"
        )
        let refuse = PermissionCoordinator.InjectRefuseProvenance(
            refusedAt: Date(timeIntervalSince1970: 1_699_999_900),
            reason: "AX focus query timed out — expand blocked (fail-closed)",
            gateSnapshot: refuseGate,
            frontmostAppName: "Notes",
            frontmostBundleID: "com.apple.Notes",
            frontmostPID: 4321,
            axErrorRawValue: AXError.cannotComplete.rawValue
        )
        let context = DiagnosticReport.Context(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            bundleID: "com.devtype.app",
            appPath: "/Applications/DevType.app",
            executablePath: "/Applications/DevType.app/Contents/MacOS/DevType",
            cdHash: "deadbeef",
            designatedRequirement: "identifier \"com.devtype.app\"",
            snapshot: PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: false),
            tapRunning: true,
            engineEnabled: true,
            secureInputActive: false,
            displayStatus: "Status: Active",
            lastInjectOutcome: "refused — AX focus query timed out — expand blocked (fail-closed)",
            frontmostAppName: "Messages",
            frontmostBundleID: "com.apple.MobileSMS",
            frontmostPID: 1234,
            mutedApps: [],
            expandGate: gate,
            expandGateAtLastRefuse: refuse,
            siblingPaths: [],
            macOSVersion: "Version 15.0 (Build 24A)",
            appVersion: "1.0.0 (1)",
            voiceTerminalLines: [
                "(voice terminal retention — observed=1; retained=1/64)",
                "2026-09-03T00:00:00Z outcome=failed code=endpointUnreachable stage=recognition provider=whisperCpp locality=localNetwork recoverability=retryAfterDelay",
            ],
            voicePermissions: DiagnosticReport.VoicePermissionContext(
                microphone: .denied,
                speechRecognition: .restricted,
                selectedEngine: .gemini,
                effectiveEngine: .gemini,
                realTimeTypingEnabled: true,
                cloudAudioConsentGranted: false,
                geminiCredentialState: .unavailable
            ),
            debugTraceHealth: DebugTrace.Health(
                enabled: true,
                write: .failed(.filePermissions)
            )
        )

        let header = DiagnosticReport.formatHeader(context)
        XCTAssertTrue(header.contains("=== DevType Diagnostic Report ==="))
        XCTAssertTrue(header.contains("Bundle ID: com.devtype.app"))
        XCTAssertTrue(header.contains("CDHash: deadbeef"))
        XCTAssertTrue(header.contains("Secure Input active: false"))
        XCTAssertTrue(header.contains("-- Expand gate (live) --"))
        XCTAssertTrue(header.contains("-- Expand gate at last refuse --"))
        XCTAssertTrue(header.contains("Focused element: missing"))
        XCTAssertTrue(header.contains("No focused AX element"))
        XCTAssertTrue(header.contains("AX focus query timed out"))
        XCTAssertTrue(header.contains("com.apple.Notes"))
        XCTAssertTrue(header.contains("com.apple.MobileSMS"))
        XCTAssertTrue(header.contains("-- Voice permissions --"))
        XCTAssertTrue(header.contains("Microphone: denied"))
        XCTAssertTrue(header.contains("Speech Recognition: restricted"))
        XCTAssertTrue(header.contains("Selected engine: gemini"))
        XCTAssertTrue(header.contains("Cloud audio consent: not granted"))
        XCTAssertTrue(header.contains("Gemini credential: unavailable"))
        XCTAssertTrue(header.contains("-- Voice terminal diagnostics (content-free) --"))
        XCTAssertTrue(header.contains("code=endpointUnreachable"))
        XCTAssertTrue(header.contains("provider=whisperCpp"))
        XCTAssertTrue(header.contains("-- Opt-in debug trace --"))
        XCTAssertTrue(header.contains("Debug trace: enabled; write=failed(file-permissions)"))
        XCTAssertFalse(header.contains("DevTypeDebugTracePath"))
        XCTAssertTrue(header.contains("refused — AX focus query timed out"))
        XCTAssertTrue(header.contains("AX error: \(AXError.cannotComplete.rawValue)"))
        XCTAssertTrue(header.contains("Post: Denied"), header)
    }

    func testFormatHeaderShowsNoneWhenNeverRefused() {
        let gate = DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: true,
            isSecureField: false,
            hasIMEMarkedText: false,
            shouldBlockExpand: false,
            blockReason: "ok"
        )
        let context = DiagnosticReport.Context(
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
            frontmostAppName: nil,
            frontmostBundleID: nil,
            frontmostPID: nil,
            mutedApps: [],
            expandGate: gate,
            expandGateAtLastRefuse: nil,
            siblingPaths: [],
            macOSVersion: "15.0",
            appVersion: "1.0.0"
        )
        let header = DiagnosticReport.formatHeader(context)
        XCTAssertTrue(header.contains("-- Expand gate (live) --"))
        XCTAssertTrue(header.contains("-- Expand gate at last refuse --"))
        XCTAssertTrue(header.contains("(none)"))
        XCTAssertFalse(header.contains("Refuse reason:"))
    }

    func testFormatHeaderShowsPostedUnverifiedOutcome() {
        let gate = DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: true,
            isSecureField: false,
            hasIMEMarkedText: false,
            shouldBlockExpand: false,
            blockReason: "ok"
        )
        let context = DiagnosticReport.Context(
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
            lastInjectOutcome: "postedUnverified",
            frontmostAppName: "Notes",
            frontmostBundleID: "com.apple.Notes",
            frontmostPID: 99,
            mutedApps: [],
            expandGate: gate,
            expandGateAtLastRefuse: nil,
            siblingPaths: [],
            macOSVersion: "15.0",
            appVersion: "1.0.0"
        )

        let header = DiagnosticReport.formatHeader(context)
        XCTAssertTrue(header.contains("Last inject: postedUnverified"))
    }

    func testHeaderProjectionBoundsLargeInputsAndReportsEveryDrop() {
        let oversized = String(repeating: "x", count: 4_096)
        let input = (0..<4_096).map { "entry-\($0)-\(oversized)" }

        let projection = DiagnosticReport.boundedHeaderProjection(input)

        XCTAssertEqual(projection.observedCount, input.count)
        XCTAssertLessThanOrEqual(
            projection.retainedLines.count,
            DiagnosticReport.headerProjectionItemLimit
        )
        XCTAssertLessThanOrEqual(
            projection.retainedUTF8Bytes,
            DiagnosticReport.headerProjectionByteLimit
        )
        XCTAssertEqual(
            projection.droppedCount,
            projection.observedCount - projection.retainedLines.count
        )
        XCTAssertEqual(
            projection.retainedUTF8Bytes,
            projection.retainedLines.joined(separator: "\n").utf8.count
        )
        XCTAssertGreaterThan(projection.droppedCount, 0)
    }

    func testHeaderProjectionSkipsOversizedEntriesWithoutHidingLaterEvidence() {
        let projection = DiagnosticReport.boundedHeaderProjection(
            ["alpha", String(repeating: "z", count: 100), "beta", "gamma"],
            itemLimit: 2,
            byteLimit: 10
        )

        XCTAssertEqual(projection.retainedLines, ["alpha", "beta"])
        XCTAssertEqual(projection.observedCount, 4)
        XCTAssertEqual(projection.retainedUTF8Bytes, 10)
        XCTAssertEqual(projection.droppedCount, 2)
    }

    func testAXVerdictProjectionIsBoundedAtTheStoreBoundaryAndReportsEveryObservedEntry() {
        let store = AXWriteCapabilityStore()
        for index in 0..<2_048 {
            store.recordTrusted(bundleID: String(format: "com.example.%04d", index))
        }

        let projection = DiagnosticReport.captureAXWriteVerdictProjection(
            store: store,
            itemLimit: 7,
            byteLimit: 512
        )

        XCTAssertEqual(projection.observedCount, 2_048)
        XCTAssertLessThanOrEqual(projection.retainedLines.count, 7)
        XCTAssertLessThanOrEqual(projection.retainedUTF8Bytes, 512)
        XCTAssertEqual(
            projection.droppedCount,
            projection.observedCount - projection.retainedLines.count
        )
    }

    func testPreboundedHeaderProjectionKeepsItsOriginalObservedCountWhenRendered() {
        let gate = DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: true,
            isSecureField: false,
            hasIMEMarkedText: false,
            shouldBlockExpand: false,
            blockReason: "ok"
        )
        var context = DiagnosticReport.Context(
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
            lastInjectOutcome: nil,
            frontmostAppName: nil,
            frontmostBundleID: nil,
            frontmostPID: nil,
            mutedApps: [],
            expandGate: gate,
            siblingPaths: [],
            macOSVersion: "15.0",
            appVersion: "1.0.0"
        )
        context.axWriteVerdictProjection = DiagnosticReport.HeaderProjection(
            retainedLines: ["com.example.one: trusted (AX writes verified)"],
            observedCount: 2_048,
            retainedUTF8Bytes: 48,
            droppedCount: 2_047,
            itemLimit: 7,
            byteLimit: 512
        )

        let header = DiagnosticReport.formatHeader(context)

        XCTAssertTrue(
            header.contains("(ax-write-verdicts projection — observed=2048; retained=1/7;"),
            header
        )
        XCTAssertTrue(header.contains("dropped=2047"), header)
    }

    func testFormatHeaderAppliesBoundedTruthfulProjectionsToLargeDynamicCollections() {
        let gate = DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: true,
            isSecureField: false,
            hasIMEMarkedText: false,
            shouldBlockExpand: false,
            blockReason: "ok"
        )
        let entries = (0..<512).map { index in
            "item-\(index)-" + String(repeating: "q", count: 512)
        }
        let context = DiagnosticReport.Context(
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
            lastInjectOutcome: nil,
            frontmostAppName: nil,
            frontmostBundleID: nil,
            frontmostPID: nil,
            mutedApps: entries.map { "com.example.muted.\($0)" },
            expandGate: gate,
            siblingPaths: [],
            macOSVersion: "15.0",
            appVersion: "1.0.0",
            overlongTriggerLines: entries.map { "overlong \($0)" },
            axWriteVerdictLines: entries.map { "ax \($0)" },
            unreachableSnippetLines: entries.map { "silent \($0)" }
        )

        let header = DiagnosticReport.formatHeader(context)

        XCTAssertTrue(header.contains("(muted-apps projection — observed=512; retained="), header)
        XCTAssertTrue(header.contains("(overlong-triggers projection — observed=512; retained="), header)
        XCTAssertTrue(header.contains("(ax-write-verdicts projection — observed=512; retained="), header)
        XCTAssertTrue(header.contains("(silent-no-expand projection — observed=512; retained="), header)
        XCTAssertEqual(header.components(separatedBy: "observed=512").count - 1, 4)
        XCTAssertTrue(header.contains("dropped="))
    }

    func testFullReportBoundsEveryExternalScalarAndDynamicSection() {
        let marker = "PRIVATE-SCALAR-MARKER"
        let hostile = marker + String(repeating: "/Users/person/private", count: 20_000)
        let hostileLines = Array(repeating: hostile, count: 1_024)
        let gate = DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: true,
            isSecureField: false,
            hasIMEMarkedText: false,
            shouldBlockExpand: false,
            blockReason: hostile
        )
        let refuse = PermissionCoordinator.InjectRefuseProvenance(
            reason: hostile,
            gateSnapshot: gate,
            frontmostAppName: hostile,
            frontmostBundleID: hostile
        )
        let context = DiagnosticReport.Context(
            bundleID: hostile,
            appPath: hostile,
            executablePath: hostile,
            cdHash: hostile,
            designatedRequirement: hostile,
            snapshot: PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true),
            tapRunning: true,
            engineEnabled: true,
            secureInputActive: false,
            displayStatus: hostile,
            lastInjectOutcome: hostile,
            frontmostAppName: hostile,
            frontmostBundleID: hostile,
            frontmostPID: 42,
            mutedApps: hostileLines,
            expandGate: gate,
            expandGateAtLastRefuse: refuse,
            siblingPaths: hostileLines,
            macOSVersion: hostile,
            appVersion: hostile,
            tapDisableSummary: hostile,
            injectTelemetryLines: hostileLines,
            overlongTriggerLines: hostileLines,
            axWriteVerdictLines: hostileLines,
            aiLines: hostileLines,
            secretLines: hostileLines,
            prefixDebounceSummary: hostile,
            matchingSuspensionLines: hostileLines,
            matchDropLines: hostileLines,
            unreachableSnippetLines: hostileLines,
            logMirrorLines: hostileLines,
            voiceTerminalLines: hostileLines
        )

        let report = DiagnosticReport.formatFullReport(context: context, logLines: hostileLines)

        XCTAssertFalse(report.contains(marker), "Raw hostile scalar or collection entry escaped")
        XCTAssertTrue(report.contains("bundleIDHash="), report)
        XCTAssertTrue(report.contains("appPathHash="), report)
        XCTAssertTrue(report.contains("blockReasonHash="), report)
        XCTAssertTrue(report.contains("projection — observed=1024"), report)
        XCTAssertLessThan(report.utf8.count, 800_000, "The complete report needs a fixed upper bound")
    }

    func testSourceOwnedDynamicProjectionsRetainCountsWithoutMaterializingEverything() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let mutedURL = temp.appendingPathComponent("muted.json")
        let muted = (0..<2_048).map { String(format: "com.example.%04d", $0) }
        try JSONEncoder().encode(muted).write(to: mutedURL)
        let muteStore = AppMuteStore(fileURL: mutedURL)

        let mutedProjection = DiagnosticReport.captureMutedAppProjection(
            store: muteStore,
            itemLimit: 5,
            byteLimit: 512
        )

        XCTAssertEqual(mutedProjection.observedCount, 2_048)
        XCTAssertLessThanOrEqual(mutedProjection.retainedLines.count, 5)
        XCTAssertEqual(mutedProjection.droppedCount, 2_043)

        let engine = EventTapEngine()
        var tokens: [EventTapEngine.MatchingSuspension] = []
        for index in 0..<2_048 {
            tokens.append(engine.suspendMatching(reason: "owner-\(index)"))
        }
        let suspensionProjection = engine.matchingSuspensionDiagnosticProjection(
            itemLimit: 6,
            byteLimit: 512
        )
        XCTAssertEqual(suspensionProjection.observedCount, 2_049)
        XCTAssertLessThanOrEqual(suspensionProjection.retainedLines.count, 6)
        XCTAssertEqual(
            suspensionProjection.droppedCount,
            suspensionProjection.observedCount - suspensionProjection.retainedLines.count
        )

        let telemetry = InjectTelemetryLog()
        for index in 0..<2_048 {
            telemetry.recordPasteRetry(bundleID: "com.telemetry.\(index)")
        }
        let telemetryProjection = telemetry.diagnosticSummaryProjection(
            itemLimit: 7,
            byteLimit: 768
        )
        XCTAssertEqual(
            telemetryProjection.observedCount,
            InjectTelemetryLog.defaultCapacity + 3,
            "The retained app rows plus no-attempt, retention, and risk headings are observed"
        )
        XCTAssertTrue(
            telemetryProjection.retainedLines.contains(
                "Per-app aggregate retention: observed=2048; retained=256/256; dropped=1792"
            ),
            "Storage eviction must be reported separately from projection truncation."
        )
        XCTAssertLessThanOrEqual(telemetryProjection.retainedLines.count, 7)
        XCTAssertEqual(
            telemetryProjection.droppedCount,
            telemetryProjection.observedCount - telemetryProjection.retainedLines.count
        )
        _ = tokens
    }

    func testInjectTelemetryProjectionCountsRefusalReasonsOmittedByTopN() {
        let telemetry = InjectTelemetryLog()
        for index in 0..<10 {
            telemetry.record(
                outcome: .refused(String(format: "reason-%02d", index)),
                bundleID: "com.example.target",
                path: "test"
            )
        }

        let projection = telemetry.diagnosticSummaryProjection(
            topRefuseReasons: 8,
            itemLimit: 128,
            byteLimit: 32 * 1_024
        )
        let refusalRows = projection.retainedLines.filter { $0.contains("× reason-") }

        XCTAssertEqual(refusalRows.count, 8, "Visible output must preserve the ranked top-N cap.")
        XCTAssertTrue(refusalRows.contains("  1× reason-00"))
        XCTAssertTrue(refusalRows.contains("  1× reason-07"))
        XCTAssertFalse(projection.retainedLines.contains { $0.contains("reason-08") })
        XCTAssertFalse(projection.retainedLines.contains { $0.contains("reason-09") })
        XCTAssertEqual(
            projection.observedCount,
            projection.retainedLines.count + 2,
            "Every source reason must be counted even when the independent top-N cap omits it."
        )
        XCTAssertEqual(projection.droppedCount, 2)
    }

    func testInjectTelemetryProjectionRanksMostActionableAggregateRowsFirst() {
        let duplicateRisk = InjectTelemetryLog()
        duplicateRisk.recordPasteRetry(bundleID: "com.example.low")
        duplicateRisk.recordPasteRetry(bundleID: "com.example.high")
        duplicateRisk.recordPasteRetry(bundleID: "com.example.high")

        let riskProjection = duplicateRisk.diagnosticSummaryProjection(
            itemLimit: 4,
            byteLimit: 4 * 1_024
        )
        XCTAssertTrue(riskProjection.retainedLines.contains { $0.contains("com.example.high") })
        XCTAssertFalse(riskProjection.retainedLines.contains { $0.contains("com.example.low") })
        XCTAssertEqual(riskProjection.observedCount, 5)
        XCTAssertEqual(riskProjection.droppedCount, 1)

        let clipboardHolds = InjectTelemetryLog()
        clipboardHolds.recordUnverifiedClipboardHold(
            bundleID: "com.example.short",
            heldFor: 0.1
        )
        clipboardHolds.recordUnverifiedClipboardHold(
            bundleID: "com.example.long",
            heldFor: 9
        )

        let holdProjection = clipboardHolds.diagnosticSummaryProjection(
            itemLimit: 4,
            byteLimit: 4 * 1_024
        )
        XCTAssertTrue(holdProjection.retainedLines.contains { $0.contains("com.example.long") })
        XCTAssertFalse(holdProjection.retainedLines.contains { $0.contains("com.example.short") })
        XCTAssertEqual(holdProjection.observedCount, 5)
        XCTAssertEqual(holdProjection.droppedCount, 1)
    }

    func testInjectTelemetrySaturatesNonfiniteDurationsAndCharacterTotals() {
        let telemetry = InjectTelemetryLog()

        telemetry.recordUnverifiedClipboardHold(
            bundleID: "com.example.infinity",
            heldFor: .infinity
        )
        telemetry.recordUnverifiedClipboardHold(
            bundleID: "com.example.nan",
            heldFor: .nan
        )
        telemetry.recordUnverifiedClipboardHold(
            bundleID: "com.example.negative-infinity",
            heldFor: -.infinity
        )
        telemetry.recordTypeAheadReplay(bundleID: "com.example.typeahead", characters: Int.max)
        telemetry.recordTypeAheadReplay(bundleID: "com.example.typeahead", characters: Int.max)

        XCTAssertEqual(
            telemetry.clipboardHoldsByBundle()["com.example.infinity"]?.maxHeldMillis,
            Int.max
        )
        XCTAssertEqual(
            telemetry.clipboardHoldsByBundle()["com.example.nan"]?.maxHeldMillis,
            0
        )
        XCTAssertEqual(
            telemetry.clipboardHoldsByBundle()["com.example.negative-infinity"]?.maxHeldMillis,
            0
        )
        XCTAssertEqual(
            telemetry.duplicateRiskByBundle()["com.example.typeahead"]?.typeAheadCharacters,
            Int.max
        )
        XCTAssertEqual(
            telemetry.duplicateRiskByBundle()["com.example.typeahead"]?.typeAheadReplays,
            2
        )
    }

    func testInjectTelemetryLifetimeAggregatesEvictLeastRecentlyUsedWithTruthfulCounts() {
        let telemetry = InjectTelemetryLog(capacity: 2)
        telemetry.recordPasteRetry(bundleID: "com.example.alpha")
        telemetry.recordUnverifiedClipboardHold(bundleID: "com.example.beta", heldFor: 0.2)
        telemetry.recordTriggerRestore(bundleID: "com.example.alpha") // Refresh alpha.
        telemetry.recordPasteRetry(bundleID: "com.example.gamma")

        let retainedKeys = Set(telemetry.duplicateRiskByBundle().keys)
            .union(telemetry.clipboardHoldsByBundle().keys)
        XCTAssertEqual(retainedKeys, ["com.example.alpha", "com.example.gamma"])
        XCTAssertNil(
            telemetry.clipboardHoldsByBundle()["com.example.beta"],
            "The least-recently used aggregate must be evicted from every counter family."
        )
        XCTAssertEqual(
            telemetry.duplicateRiskByBundle()["com.example.alpha"]?.triggerRestores,
            1,
            "Refreshing an aggregate must retain both its identity and accumulated evidence."
        )

        let lines = telemetry.diagnosticSummaryProjection().retainedLines
        let retention = lines.first { $0.contains("Per-app aggregate retention") }
        XCTAssertEqual(
            retention,
            "Per-app aggregate retention: observed=3; retained=2/2; dropped=1"
        )
        XCTAssertFalse(lines.joined(separator: "\n").contains("com.example.beta"))
    }

    func testPreferencesTelemetrySummaryUsesTheCanonicalBoundedProjection() {
        let telemetry = InjectTelemetryLog(capacity: 512)
        telemetry.record(outcome: .succeeded, bundleID: "com.example.active", path: "ax")
        for index in 0..<512 {
            telemetry.recordPasteRetry(bundleID: String(format: "com.example.%04d", index))
        }

        let lines = telemetry.summaryLines()
        let joined = lines.joined(separator: "\n")

        XCTAssertLessThanOrEqual(
            lines.count,
            DiagnosticReport.headerProjectionItemLimit + 1,
            "The Preferences-facing adapter must not rebuild the lifetime maps without caps."
        )
        XCTAssertLessThanOrEqual(
            joined.utf8.count,
            DiagnosticReport.headerProjectionByteLimit + 512
        )
        XCTAssertTrue(lines.first?.contains("inject-telemetry projection") == true)
        XCTAssertTrue(joined.contains("Per-app aggregate retention"))
    }

    func testActivityHistoryPersistenceHealthIsVisibleWithoutLeakingFailurePayloads() {
        let healthy = DiagnosticReport.activityHistoryDiagnosticLine(
            health: .init(lastFailureKind: nil),
            retainedEventCount: 7
        )
        XCTAssertEqual(healthy, "Activity history: healthy retained=7/25")

        let privateFailure = "PRIVATE /Users/person/activity-history.json"
        let failed = DiagnosticReport.activityHistoryDiagnosticLine(
            health: .init(lastFailureKind: privateFailure),
            retainedEventCount: 0
        )
        XCTAssertEqual(failed, "Activity history: unavailable failure=unknown retained=0/25")
        XCTAssertFalse(failed.contains(privateFailure))

        let oversized = DiagnosticReport.activityHistoryDiagnosticLine(
            health: .init(
                lastFailureKind: ActivityHistoryStore.PersistenceFailureKind.fileTooLarge.rawValue
            ),
            retainedEventCount: 0
        )
        XCTAssertTrue(oversized.contains("failure=file_too_large"), oversized)
    }

    func testFormatFullReportIncludesLogSection() {
        let gate = DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: true,
            isSecureField: false,
            hasIMEMarkedText: false,
            shouldBlockExpand: false,
            blockReason: "ok"
        )
        let context = DiagnosticReport.Context(
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
            lastInjectOutcome: nil,
            frontmostAppName: nil,
            frontmostBundleID: nil,
            frontmostPID: nil,
            mutedApps: ["com.example.muted"],
            expandGate: gate,
            siblingPaths: ["/tmp/DevType.app"],
            macOSVersion: "15.0",
            appVersion: "1.0.0"
        )
        let report = DiagnosticReport.formatFullReport(
            context: context,
            logLines: ["2026-08-01T12:00:00Z [Inject] info hello"]
        )
        XCTAssertTrue(report.contains("-- Recent OSLog"))
        XCTAssertTrue(report.contains("[Inject] info hello"))
        XCTAssertTrue(report.contains("com.example.muted"))
        XCTAssertTrue(report.contains("/tmp/DevType.app"))
        XCTAssertTrue(report.contains("=== End DevType Diagnostic Report ==="))
    }

    func testFormatFullReportEmptyLogsPlaceholder() {
        let gate = DiagnosticReport.ExpandGateSnapshot(
            canUseAX: false,
            axTrusted: false,
            focusedAvailable: false,
            isSecureField: nil,
            hasIMEMarkedText: nil,
            shouldBlockExpand: true,
            blockReason: "Accessibility unavailable — expand blocked (fail-closed)"
        )
        let context = DiagnosticReport.Context(
            bundleID: "com.devtype.app",
            appPath: "/Applications/DevType.app",
            executablePath: "/Applications/DevType.app/Contents/MacOS/DevType",
            cdHash: nil,
            designatedRequirement: nil,
            snapshot: PermissionSnapshot(canListenTap: false, canUseAX: false, canPostEvents: false),
            tapRunning: false,
            engineEnabled: true,
            secureInputActive: true,
            displayStatus: "Status: Needs Permissions",
            lastInjectOutcome: nil,
            frontmostAppName: nil,
            frontmostBundleID: nil,
            frontmostPID: nil,
            mutedApps: [],
            expandGate: gate,
            siblingPaths: [],
            macOSVersion: "15.0",
            appVersion: nil
        )
        let report = DiagnosticReport.formatFullReport(context: context, logLines: [])
        XCTAssertTrue(report.contains("no recent entries"))
        XCTAssertTrue(report.contains("Secure Input active: true"))
    }

    func testCopyToPasteboardWritesPlainString() {
        // `NSPasteboard.general` is the real clipboard of whoever runs the suite, not a
        // fixture. Without this snapshot, every `swift test` silently destroys what the
        // person at the keyboard had copied — and the next ⌘V hands them a stray
        // `devtype-diagnostic-test-…` token instead of their own text.
        let pasteboard = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? [])
            .map { item in
                var flavors: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { flavors[type] = data }
                }
                return flavors
            }
            .filter { !$0.isEmpty }
        defer {
            pasteboard.clearContents()
            if !saved.isEmpty {
                pasteboard.writeObjects(saved.map { flavors in
                    let item = NSPasteboardItem()
                    for (type, data) in flavors { item.setData(data, forType: type) }
                    return item
                })
            }
        }

        let ok = DiagnosticReport.copyToPasteboard("devtype-diagnostic-test-\(UUID().uuidString)")
        XCTAssertTrue(ok)
        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertNotNil(pasted)
        XCTAssertTrue(pasted?.hasPrefix("devtype-diagnostic-test-") == true)
    }

    func testToolchainFormattingWithKeysPresentAndAbsent() {
        XCTAssertEqual(
            DiagnosticReport.formatToolchain(xcode: "2660", sdk: "macosx26.5"),
            "Built with Xcode 26.6 · SDK macosx26.5"
        )
        XCTAssertEqual(
            DiagnosticReport.formatToolchain(xcode: "1540", sdk: "macosx14.5"),
            "Built with Xcode 15.4 · SDK macosx14.5"
        )
        XCTAssertEqual(
            DiagnosticReport.formatToolchain(xcode: "26.6", sdk: "macosx26.5"),
            "Built with Xcode 26.6 · SDK macosx26.5"
        )
        XCTAssertEqual(
            DiagnosticReport.formatToolchain(xcode: nil as String?, sdk: nil as String?),
            "Built with Xcode unknown · SDK unknown"
        )
        XCTAssertEqual(
            DiagnosticReport.formatToolchain(xcode: "", sdk: ""),
            "Built with Xcode unknown · SDK unknown"
        )
        XCTAssertEqual(
            DiagnosticReport.formatToolchain(xcode: "2660", sdk: nil as String?),
            "Built with Xcode 26.6 · SDK unknown"
        )
        XCTAssertEqual(
            DiagnosticReport.formatToolchain(xcode: nil as String?, sdk: "macosx26.5"),
            "Built with Xcode unknown · SDK macosx26.5"
        )
    }

    func testHeaderRendersToolchainLine() {
        let gate = DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: false,
            isSecureField: nil,
            hasIMEMarkedText: nil,
            shouldBlockExpand: false,
            blockReason: "Allowed"
        )
        var context = DiagnosticReport.Context(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            bundleID: "com.devtype.app",
            appPath: "/Applications/DevType.app",
            executablePath: "/Applications/DevType.app/Contents/MacOS/DevType",
            cdHash: "deadbeef",
            designatedRequirement: "identifier \"com.devtype.app\"",
            snapshot: PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: false),
            tapRunning: true,
            engineEnabled: true,
            secureInputActive: false,
            displayStatus: "Status: Active",
            lastInjectOutcome: nil,
            frontmostAppName: nil,
            frontmostBundleID: nil,
            frontmostPID: nil,
            mutedApps: [],
            expandGate: gate,
            expandGateAtLastRefuse: nil,
            siblingPaths: [],
            macOSVersion: "Version 15.0 (Build 24A)",
            appVersion: "1.0.0 (1)",
            buildToolchain: "Built with Xcode 26.6 · SDK macosx26.5"
        )

        let headerWithToolchain = DiagnosticReport.formatHeader(context)
        XCTAssertTrue(headerWithToolchain.contains("Built with Xcode 26.6 · SDK macosx26.5"))

        context.buildToolchain = nil
        let headerWithoutToolchain = DiagnosticReport.formatHeader(context)
        XCTAssertTrue(headerWithoutToolchain.contains("Built with Xcode unknown · SDK unknown"))
    }
}
