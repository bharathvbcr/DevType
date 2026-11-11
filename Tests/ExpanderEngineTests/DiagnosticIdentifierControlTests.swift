import AppKit
import XCTest
@testable import ExpanderEngine

final class DiagnosticIdentifierControlTests: XCTestCase {
    func testShortControlIdentifiersUseShapeAndDoNotEchoTheControl() {
        let controls: [Unicode.Scalar] = [
            "\n",
            "\r",
            "\t",
            "\u{0000}",
            "\u{0001}",
            "\u{007F}",
            "\u{0085}",
        ]
        for scalar in controls {
            let raw = "Notes\(scalar)account: hunter2"
            XCTAssertLessThan(raw.utf8.count, 512, String(format: "U+%04X", scalar.value))
            assertShapeHidesControl(raw, control: scalar)
        }
    }

    func testNewlineIdentifierDoesNotEchoPlantedSecret() {
        let raw = "Notes\naccount: hunter2"
        XCTAssertLessThan(raw.utf8.count, 512)
        let shaped = DiagnosticPrivacy.boundedIdentifier(raw, label: "name", domain: "frontmost-name")
        XCTAssertNotEqual(shaped, raw)
        XCTAssertFalse(shaped.contains("hunter2"), shaped)
        XCTAssertFalse(shaped.contains("\n"), shaped)
        XCTAssertTrue(shaped.contains("Chars="), shaped)
        XCTAssertTrue(shaped.contains("Hash="), shaped)
    }

    func testBoundedPublicIdentifierDropsNewlineAndPlantedSecret() {
        let raw = "Notes\naccount: hunter2"
        XCTAssertLessThan(raw.utf8.count, 256)
        let shaped = DevTypeLog.boundedPublicIdentifier(raw, label: "appName")
        XCTAssertNotEqual(shaped, raw)
        XCTAssertFalse(shaped.contains("\n"), shaped)
        XCTAssertFalse(shaped.contains("hunter2"), shaped)
        XCTAssertTrue(shaped.contains("Chars="), shaped)
        XCTAssertTrue(shaped.contains("Hash="), shaped)
    }

    func testFormatHeaderKeepsCleanFrontmostIdentityAndShapesAControlName() {
        let clean = header(frontmostAppName: "TextEdit", frontmostBundleID: "com.apple.TextEdit")
        XCTAssertTrue(clean.contains("Name: TextEdit"), clean)
        XCTAssertTrue(clean.contains("Bundle ID: com.apple.TextEdit"), clean)

        let hostile = header(
            frontmostAppName: "Bad\naccount: hunter2",
            frontmostBundleID: "com.example.app"
        )
        XCTAssertTrue(hostile.contains("Bundle ID: com.example.app"), hostile)
        XCTAssertFalse(hostile.contains("hunter2"), hostile)
        XCTAssertFalse(hostile.contains("Bad\n"), hostile)
        XCTAssertTrue(hostile.contains("Chars="), hostile)
        XCTAssertTrue(hostile.contains("Hash="), hostile)
    }

    func testNonControlsStayVerbatimAndOneByteOverCapUsesShape() {
        let verbatim = [
            "café",
            "\u{1F468}\u{200D}\u{1F469}",
            "com.apple.TextEdit",
            "Notes Menu",
            "e\u{0301}",
            "left\u{202E}right",
        ]
        for value in verbatim {
            XCTAssertLessThan(value.utf8.count, 512, value)
            XCTAssertFalse(
                value.unicodeScalars.contains { $0.properties.generalCategory == .control },
                value
            )
            XCTAssertEqual(
                DiagnosticPrivacy.boundedIdentifier(value, label: "name", domain: "frontmost-name"),
                value
            )
        }

        let atCap = String(repeating: "b", count: 512)
        XCTAssertEqual(
            DiagnosticPrivacy.boundedIdentifier(atCap, label: "name", domain: "frontmost-name"),
            atCap
        )

        let overCap = String(repeating: "a", count: 513)
        XCTAssertEqual(overCap.utf8.count, 513)
        let shaped = DiagnosticPrivacy.boundedIdentifier(overCap, label: "name", domain: "frontmost-name")
        XCTAssertNotEqual(shaped, overCap)
        XCTAssertTrue(shaped.contains("Chars="), shaped)
        XCTAssertTrue(shaped.contains("Hash="), shaped)
        XCTAssertFalse(shaped.contains(overCap), shaped)
    }

    private func assertShapeHidesControl(
        _ raw: String,
        control: Unicode.Scalar,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let shaped = DiagnosticPrivacy.boundedIdentifier(raw, label: "name", domain: "frontmost-name")
        XCTAssertNotEqual(shaped, raw, file: file, line: line)
        XCTAssertFalse(shaped.unicodeScalars.contains(control), shaped, file: file, line: line)
        XCTAssertFalse(shaped.contains("hunter2"), shaped, file: file, line: line)
        XCTAssertTrue(shaped.contains("Chars="), shaped, file: file, line: line)
        XCTAssertTrue(shaped.contains("Hash="), shaped, file: file, line: line)
    }

    private func header(frontmostAppName: String, frontmostBundleID: String) -> String {
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
            frontmostAppName: frontmostAppName,
            frontmostBundleID: frontmostBundleID,
            frontmostPID: nil,
            mutedApps: [],
            expandGate: gate,
            siblingPaths: [],
            macOSVersion: "15.0",
            appVersion: "1.0.0"
        )
        return DiagnosticReport.formatHeader(context)
    }
}
