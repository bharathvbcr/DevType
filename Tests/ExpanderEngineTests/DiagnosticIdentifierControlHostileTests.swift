import AppKit
import XCTest
@testable import ExpanderEngine

final class DiagnosticIdentifierControlHostileTests: XCTestCase {
    func testEveryC0ScalarHidesTheScalarAndTheSecretAfterIt() {
        for code in 0x00...0x1F {
            let scalar = Unicode.Scalar(code)!
            XCTAssertEqual(
                scalar.properties.generalCategory,
                .control,
                String(format: "U+%04X", code)
            )
            assertControlDoesNotEcho(scalar)
        }
    }

    func testDeleteAndNextLineUseTheControlPathWhenSwiftSaysControl() {
        let delete = Unicode.Scalar(0x007F)!
        XCTAssertEqual(delete.properties.generalCategory, .control, "U+007F")
        assertControlDoesNotEcho(delete)

        var notControl: [String] = []
        for code in 0x80...0x9F {
            let scalar = Unicode.Scalar(code)!
            let category = scalar.properties.generalCategory
            if category == .control {
                assertControlDoesNotEcho(scalar)
            } else {
                notControl.append(String(format: "U+%04X %@", code, String(describing: category)))
            }
        }
        let nel = Unicode.Scalar(0x0085)!
        if nel.properties.generalCategory != .control {
            XCTAssertNotEqual(
                nel.properties.generalCategory,
                .control,
                "NEL U+0085 generalCategory is \(nel.properties.generalCategory)"
            )
        }
        if !notControl.isEmpty {
            print("C1 scalars Swift does not classify as .control: \(notControl.joined(separator: ", "))")
        }
    }

    func testFormatAndCombiningScalarsInsideABundleIDStayVerbatim() {
        let samples = [
            "com.\u{200D}apple.TextEdit",
            "\u{202E}com.apple.TextEdit",
            "com.apple.TextE\u{0301}dit",
            "com.apple.TextEdit\u{200D}\u{202E}\u{0301}",
        ]
        for value in samples {
            XCTAssertLessThan(value.utf8.count, 512, value)
            XCTAssertFalse(
                value.unicodeScalars.contains { $0.properties.generalCategory == .control },
                value
            )
            XCTAssertEqual(
                DiagnosticPrivacy.boundedIdentifier(value, label: "field", domain: "hostile-format"),
                value
            )
        }
    }

    func testByteCapBoundariesWithAndWithoutATrailingNewline() {
        let atCap = String(repeating: "p", count: 512)
        XCTAssertEqual(atCap.utf8.count, 512)
        XCTAssertEqual(
            DiagnosticPrivacy.boundedIdentifier(atCap, label: "field", domain: "hostile-cap"),
            atCap
        )

        let secret = "SECRET"
        let filler = String(repeating: "z", count: 512 - secret.utf8.count - 1)
        let atCapWithNewline = secret + filler + "\n"
        XCTAssertEqual(atCapWithNewline.utf8.count, 512)
        XCTAssertEqual(atCapWithNewline.unicodeScalars.last, "\n")
        let shapedCap = DiagnosticPrivacy.boundedIdentifier(
            atCapWithNewline,
            label: "field",
            domain: "hostile-cap"
        )
        XCTAssertNotEqual(shapedCap, atCapWithNewline)
        XCTAssertFalse(shapedCap.unicodeScalars.contains("\n"), shapedCap)
        XCTAssertFalse(shapedCap.contains(secret), shapedCap)
        XCTAssertTrue(shapedCap.contains("Chars="), shapedCap)
        XCTAssertTrue(shapedCap.contains("Hash="), shapedCap)

        let overCap = String(repeating: "q", count: 513)
        XCTAssertEqual(overCap.utf8.count, 513)
        let shapedOver = DiagnosticPrivacy.boundedIdentifier(
            overCap,
            label: "field",
            domain: "hostile-cap"
        )
        XCTAssertNotEqual(shapedOver, overCap)
        XCTAssertTrue(shapedOver.contains("Chars="), shapedOver)
        XCTAssertTrue(shapedOver.contains("Hash="), shapedOver)
        XCTAssertFalse(shapedOver.contains("q"), shapedOver)
    }

    func testPublicIdentifierCapEmptyAndSecretAfterNewline() {
        XCTAssertEqual(DevTypeLog.boundedPublicIdentifier(nil, label: "bundleID"), "(unknown)")
        XCTAssertEqual(DevTypeLog.boundedPublicIdentifier("", label: "bundleID"), "(unknown)")
        XCTAssertEqual(DevTypeLog.boundedPublicIdentifier(" ", label: "bundleID"), " ")

        let plain = String(repeating: "m", count: 256)
        XCTAssertEqual(plain.utf8.count, 256)
        XCTAssertEqual(DevTypeLog.boundedPublicIdentifier(plain, label: "bundleID"), plain)

        let secret = "SECRET"
        let marked = "\n\(secret)\n"
        let raw = String(repeating: "m", count: 256 - marked.utf8.count) + marked
        XCTAssertEqual(raw.utf8.count, 256)
        XCTAssertEqual(raw.unicodeScalars.last, "\n")
        XCTAssertTrue(raw.contains("\n\(secret)"))
        let shaped = DevTypeLog.boundedPublicIdentifier(raw, label: "bundleID")
        XCTAssertNotEqual(shaped, raw)
        XCTAssertFalse(shaped.contains(secret), shaped)
        XCTAssertFalse(shaped.unicodeScalars.contains("\n"), shaped)
        XCTAssertTrue(shaped.contains("Chars="), shaped)
        XCTAssertTrue(shaped.contains("Hash="), shaped)
    }

    func testHeaderNewlineOnlyNameKeepsBundleIDAndSpacesStayVerbatim() {
        let newlineHeader = header(frontmostAppName: "\n", frontmostBundleID: "com.apple.TextEdit")
        XCTAssertTrue(newlineHeader.contains("Bundle ID: com.apple.TextEdit"), newlineHeader)
        XCTAssertFalse(newlineHeader.contains("Name: \n"), newlineHeader)
        let newlineName = nameLine(newlineHeader)
        XCTAssertNotEqual(newlineName, "Name: ")
        XCTAssertFalse(newlineName.unicodeScalars.contains("\n"), newlineName)
        XCTAssertTrue(newlineName.contains("Chars="), newlineName)
        XCTAssertTrue(newlineName.contains("Hash="), newlineName)

        let spaces = String(repeating: " ", count: 7)
        let spaceHeader = header(frontmostAppName: spaces, frontmostBundleID: "com.apple.TextEdit")
        XCTAssertEqual(nameLine(spaceHeader), "Name: \(spaces)")
        XCTAssertFalse(nameLine(spaceHeader).contains("Chars="))
        XCTAssertTrue(spaceHeader.contains("Bundle ID: com.apple.TextEdit"), spaceHeader)
        XCTAssertEqual(
            newlineHeader.components(separatedBy: "\n").count,
            spaceHeader.components(separatedBy: "\n").count,
            "a newline-only name must not insert a line"
        )
    }

    func testTextShapeOfANewlineValueIsOneLine() {
        let raw = "alpha\nSECRET"
        let shaped = DiagnosticPrivacy.textShape(raw, label: "field", domain: "shape-line")
        XCTAssertEqual(shaped.components(separatedBy: "\n").count, 1, shaped)
        XCTAssertFalse(shaped.unicodeScalars.contains(Unicode.Scalar(0x000A)!), shaped)
        XCTAssertFalse(shaped.contains("alpha"), shaped)
        XCTAssertFalse(shaped.contains("SECRET"), shaped)
        XCTAssertTrue(shaped.contains("Chars="), shaped)
        XCTAssertTrue(shaped.contains("Hash="), shaped)

        let viaIdentifier = DiagnosticPrivacy.boundedIdentifier(raw, label: "field", domain: "shape-line")
        XCTAssertEqual(viaIdentifier.components(separatedBy: "\n").count, 1, viaIdentifier)
        XCTAssertFalse(viaIdentifier.unicodeScalars.contains(Unicode.Scalar(0x000A)!), viaIdentifier)
        XCTAssertFalse(viaIdentifier.contains("SECRET"), viaIdentifier)
    }

    private func assertControlDoesNotEcho(
        _ scalar: Unicode.Scalar,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let withName = "app\(scalar)name"
        XCTAssertLessThanOrEqual(withName.utf8.count, 512, file: file, line: line)
        let shapedName = DiagnosticPrivacy.boundedIdentifier(
            withName,
            label: "field",
            domain: "hostile-control"
        )
        XCTAssertNotEqual(shapedName, withName, file: file, line: line)
        XCTAssertFalse(shapedName.unicodeScalars.contains(scalar), shapedName, file: file, line: line)
        XCTAssertFalse(shapedName.contains("name"), shapedName, file: file, line: line)

        let withSecret = "ok\(scalar)SECRET"
        XCTAssertLessThanOrEqual(withSecret.utf8.count, 512, file: file, line: line)
        let shapedSecret = DiagnosticPrivacy.boundedIdentifier(
            withSecret,
            label: "field",
            domain: "hostile-control"
        )
        XCTAssertNotEqual(shapedSecret, withSecret, file: file, line: line)
        XCTAssertFalse(shapedSecret.contains("SECRET"), shapedSecret, file: file, line: line)
        XCTAssertFalse(shapedSecret.unicodeScalars.contains(scalar), shapedSecret, file: file, line: line)
        XCTAssertTrue(shapedSecret.contains("Chars="), shapedSecret, file: file, line: line)
        XCTAssertTrue(shapedSecret.contains("Hash="), shapedSecret, file: file, line: line)
    }

    private func nameLine(_ header: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let matches = header.components(separatedBy: "\n").filter { $0.hasPrefix("Name: ") }
        XCTAssertEqual(matches.count, 1, header, file: file, line: line)
        return matches[0]
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
