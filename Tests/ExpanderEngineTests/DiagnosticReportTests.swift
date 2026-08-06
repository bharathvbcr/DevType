import AppKit
import ApplicationServices
import XCTest
@testable import ExpanderEngine

final class DiagnosticReportTests: XCTestCase {
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
            appVersion: "1.0.0 (1)"
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
        let ok = DiagnosticReport.copyToPasteboard("devtype-diagnostic-test-\(UUID().uuidString)")
        XCTAssertTrue(ok)
        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertNotNil(pasted)
        XCTAssertTrue(pasted?.hasPrefix("devtype-diagnostic-test-") == true)
    }
}
