import Foundation
import XCTest
@testable import ExpanderEngine

final class UncleanExitSentinelTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private var reports: URL!

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("unclean-exit-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        reports = root.appendingPathComponent("reports", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: reports, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            if let support {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
            }
            if let reports {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reports.path)
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testCleanLaunchWritesSentinelWithoutRecordingUnclean() throws {
        let result = launch()

        XCTAssertFalse(result.previousRunUnclean)
        XCTAssertNil(result.attachment)
        XCTAssertTrue(result.sentinelWritten)
        XCTAssertEqual(UncleanExitSentinel.diagnosticLines(for: result), [])
        XCTAssertEqual(try posixMode(sentinelURL), 0o600)
        XCTAssertEqual(try String(contentsOf: sentinelURL, encoding: .utf8), "devtype-unclean-exit\n")

        let report = DiagnosticReport.formatFullReport(
            context: reportContext(uncleanExitLines: UncleanExitSentinel.diagnosticLines(for: result)),
            logLines: []
        )
        XCTAssertFalse(report.contains("unclean: yes"))
        XCTAssertFalse(report.contains("-- Previous exit --"))
    }

    func testSentinelPresentRecordsUncleanAndRearms() throws {
        try Data("stale-sentinel".utf8).write(to: sentinelURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sentinelURL.path)

        let result = launch()

        XCTAssertTrue(result.previousRunUnclean)
        XCTAssertNil(result.attachment)
        XCTAssertTrue(result.sentinelWritten)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
        XCTAssertEqual(try posixMode(sentinelURL), 0o600)
        XCTAssertEqual(UncleanExitSentinel.diagnosticLines(for: result), ["unclean: yes"])
        let report = DiagnosticReport.formatFullReport(
            context: reportContext(uncleanExitLines: UncleanExitSentinel.diagnosticLines(for: result)),
            logLines: []
        )
        XCTAssertTrue(report.contains("-- Previous exit --"))
        XCTAssertTrue(report.contains("unclean: yes"))
    }

    func testCleanTerminationRemovesSentinelSoNextLaunchIsClean() throws {
        let armed = launch()
        XCTAssertTrue(armed.sentinelWritten)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))

        XCTAssertTrue(UncleanExitSentinel.noteCleanTermination(supportDirectory: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinelURL.path))

        let next = launch()
        XCTAssertFalse(next.previousRunUnclean)
        XCTAssertTrue(next.sentinelWritten)
        XCTAssertEqual(UncleanExitSentinel.diagnosticLines(for: next), [])
    }

    func testDiagnosticSectionIncludesMatchingIpsFactsWithoutPaths() throws {
        try Data("previous".utf8).write(to: sentinelURL)
        let procPath = "/Users/person/Applications/DevType.app/Contents/MacOS/DevType"
        let basename = "DevType-2026-10-11-120000.ips"
        let header = #"""
        {"app_name":"DevType","bundleID":"com.devtype.app","note":"brace } { still string","app_version":"1.2.1"}
        """#
        let body = """
        {
          "procName" : "DevType",
          "procPath" : "\(procPath)",
          "exception" : { "type" : "EXC_BREAKPOINT", "signal" : "SIGTRAP" },
          "faultingThread" : 0,
          "threads" : [
            { "triggered" : true, "queue" : "com.devtype.selection-read" }
          ]
        }
        """
        try writeReport(named: basename, created: date(10), contents: header + "\n" + body)

        let result = launch()
        let lines = UncleanExitSentinel.diagnosticLines(for: result)
        let report = DiagnosticReport.formatFullReport(
            context: reportContext(uncleanExitLines: lines),
            logLines: []
        )
        let section = try previousExitSection(in: report)

        XCTAssertTrue(result.previousRunUnclean)
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: \(basename)",
            "version: 1.2.1",
            "exception: EXC_BREAKPOINT",
            "queue: com.devtype.selection-read",
        ])
        for line in lines {
            XCTAssertTrue(section.contains(line), section)
            XCTAssertFalse(line.contains("/"), line)
        }
        XCTAssertFalse(section.contains("/Users/"))
        XCTAssertFalse(section.contains(procPath))
        XCTAssertFalse(section.contains("/Applications"))
    }

    func testPathLikeCrashFactsAreOmitted() throws {
        try Data("previous".utf8).write(to: sentinelURL)
        let json = """
        {
          "app_name": "DevType",
          "app_version": "/Users/person/secret-version",
          "exception": { "type": "EXC_BREAKPOINT" },
          "faultingThread": 0,
          "threads": [{ "triggered": true, "queue": "/Users/person/queue" }]
        }
        """
        try writeReport(named: "DevType-path-facts.ips", created: date(3), contents: json)

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-path-facts.ips",
            "exception: EXC_BREAKPOINT",
        ])
        XCTAssertFalse(lines.joined(separator: "\n").contains("/Users/"))
        XCTAssertFalse(lines.joined(separator: "\n").contains("/"))
    }

    func testOversizedReportDoesNotAttachOrThrow() throws {
        try Data("previous".utf8).write(to: sentinelURL)
        var payload = Data(#"{"app_name":"DevType","exception":{"type":"EXC_BREAKPOINT"},"threads":[{"queue":"com.devtype.oversized-marker"}]}"#.utf8)
        payload.append(Data(repeating: 0x20, count: UncleanExitSentinel.maximumCrashReportBytes))
        XCTAssertGreaterThan(payload.count, UncleanExitSentinel.maximumCrashReportBytes)
        let huge = reports.appendingPathComponent("DevType-huge.ips")
        try payload.write(to: huge)
        try setCreated(date(50), at: huge)
        try writeReport(
            named: "DevType-older-than-huge.ips",
            created: date(1),
            contents: matchJSON(version: "1.0.0", exception: "EXC_BAD_ACCESS", queue: "com.devtype.kept-older")
        )

        let result = launch()
        let lines = UncleanExitSentinel.diagnosticLines(for: result)
        XCTAssertTrue(result.previousRunUnclean)
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-older-than-huge.ips",
            "version: 1.0.0",
            "exception: EXC_BAD_ACCESS",
            "queue: com.devtype.kept-older",
        ])
        XCTAssertFalse(lines.joined(separator: "\n").contains("oversized-marker"))
    }

    func testMissingKeysOmitFieldsWithoutBorrowingAnOlderMatch() throws {
        try Data("previous".utf8).write(to: sentinelURL)
        try writeReport(
            named: "DevType-complete-older.ips",
            created: date(1),
            contents: matchJSON(version: "9.9.9", exception: "EXC_BAD_ACCESS", queue: "com.devtype.older-complete")
        )
        try writeReport(
            named: "DevType-missing-keys.ips",
            created: date(2),
            contents: #"{"app_name":"DevType","procName":"DevType"}"#
        )

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-missing-keys.ips",
        ])
        let rendered = lines.joined(separator: "\n")
        XCTAssertFalse(rendered.contains("version:"))
        XCTAssertFalse(rendered.contains("exception:"))
        XCTAssertFalse(rendered.contains("queue:"))
        XCTAssertFalse(rendered.contains("9.9.9"))
        XCTAssertFalse(rendered.contains("EXC_BAD_ACCESS"))
        XCTAssertFalse(rendered.contains("com.devtype.older-complete"))
    }

    func testSymlinkReportIsNotFollowed() throws {
        try Data("previous".utf8).write(to: sentinelURL)
        let marker = "com.devtype.symlink-should-not-leak"
        let secret = "/Users/unclean-exit-sentinel-secret"
        let target = root.appendingPathComponent("outside-target.json")
        try Data(matchJSON(version: "8.8.8", exception: "EXC_BREAKPOINT", queue: marker).utf8).write(to: target)
        let link = reports.appendingPathComponent("DevType-link.ips")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let leaked = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(leaked.contains(marker))
        XCTAssertFalse(leaked.contains(secret))
        try Data((leaked + "\n" + secret).utf8).write(to: target)

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        let rendered = lines.joined(separator: "\n")
        XCTAssertEqual(lines, ["unclean: yes"])
        XCTAssertFalse(rendered.contains(marker))
        XCTAssertFalse(rendered.contains(secret))
        XCTAssertFalse(rendered.contains("/Users/"))
        XCTAssertFalse(rendered.contains(target.path))
    }

    func testUnreadableReportIsSkipped() throws {
        guard geteuid() != 0 else {
            XCTFail("unreadable-file case cannot be proven when the test process is root")
            return
        }
        try Data("previous".utf8).write(to: sentinelURL)
        let marker = "com.devtype.unreadable-marker"
        let url = try writeReport(
            named: "DevType-unreadable.ips",
            created: date(4),
            contents: matchJSON(version: "7.7.7", exception: "EXC_BREAKPOINT", queue: marker)
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, ["unclean: yes"])
        XCTAssertFalse(lines.joined(separator: "\n").contains(marker))
        XCTAssertFalse(lines.joined(separator: "\n").contains("7.7.7"))
    }

    func testNewerNonMatchDoesNotHideOlderMatch() throws {
        try Data("previous".utf8).write(to: sentinelURL)
        try writeReport(
            named: "DevType-older.ips",
            created: date(1),
            contents: matchJSON(version: "1.2.1", exception: "EXC_BREAKPOINT", queue: "com.devtype.selection-read")
        )
        try writeReport(
            named: "Safari-newer.ips",
            created: date(3),
            contents: matchJSON(
                version: "17.0",
                exception: "EXC_BAD_ACCESS",
                queue: "com.apple.safari-hide",
                appName: "Safari",
                bundleID: "com.apple.Safari"
            )
        )
        try writeReport(
            named: "DevType-spoof.ips",
            created: date(4),
            contents: matchJSON(
                version: "99.0",
                exception: "EXC_CRASH",
                queue: "com.apple.spoof-hide",
                appName: "Safari",
                bundleID: "com.apple.Safari"
            )
        )

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-older.ips",
            "version: 1.2.1",
            "exception: EXC_BREAKPOINT",
            "queue: com.devtype.selection-read",
        ])
        let rendered = lines.joined(separator: "\n")
        XCTAssertFalse(rendered.contains("EXC_BAD_ACCESS"))
        XCTAssertFalse(rendered.contains("EXC_CRASH"))
        XCTAssertFalse(rendered.contains("safari-hide"))
        XCTAssertFalse(rendered.contains("spoof-hide"))
        XCTAssertFalse(rendered.contains("99.0"))
    }

    func testNewerMatchWinsOverOlderMatch() throws {
        try Data("previous".utf8).write(to: sentinelURL)
        try writeReport(
            named: "DevType-older.ips",
            created: date(1),
            contents: matchJSON(version: "1.0.0", exception: "EXC_BAD_ACCESS", queue: "com.devtype.older")
        )
        try writeReport(
            named: "DevType-newer.ips",
            created: date(2),
            contents: matchJSON(version: "1.2.1", exception: "EXC_BREAKPOINT", queue: "com.devtype.selection-read")
        )

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-newer.ips",
            "version: 1.2.1",
            "exception: EXC_BREAKPOINT",
            "queue: com.devtype.selection-read",
        ])
        let rendered = lines.joined(separator: "\n")
        XCTAssertFalse(rendered.contains("DevType-older.ips"))
        XCTAssertFalse(rendered.contains("1.0.0"))
        XCTAssertFalse(rendered.contains("EXC_BAD_ACCESS"))
        XCTAssertFalse(rendered.contains("com.devtype.older"))
    }

    func testSentinelWriteFailureDoesNotThrow() {
        let blocker = root.appendingPathComponent("not-a-directory")
        try? Data("x".utf8).write(to: blocker)

        let result = UncleanExitSentinel.noteLaunch(
            supportDirectory: blocker,
            diagnosticReportsDirectory: reports
        )

        XCTAssertFalse(result.previousRunUnclean)
        XCTAssertFalse(result.sentinelWritten)
        XCTAssertNil(result.attachment)
    }

    func testClearFailureStaysVisibleAndNextLaunchStillRecordsUnclean() throws {
        XCTAssertTrue(launch().sentinelWritten)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: support.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        }

        XCTAssertFalse(UncleanExitSentinel.noteCleanTermination(supportDirectory: support))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))

        let next = launch()
        XCTAssertTrue(next.previousRunUnclean)
        XCTAssertEqual(UncleanExitSentinel.diagnosticLines(for: next), ["unclean: yes"])
    }

    private var sentinelURL: URL {
        support.appendingPathComponent(UncleanExitSentinel.sentinelFileName)
    }

    private func launch() -> UncleanExitSentinel.LaunchResult {
        UncleanExitSentinel.noteLaunch(
            supportDirectory: support,
            diagnosticReportsDirectory: reports
        )
    }

    private func date(_ step: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + step * 86_400)
    }

    private func setCreated(_ created: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let recorded = try XCTUnwrap(attributes[.creationDate] as? Date)
        XCTAssertEqual(recorded.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
    }

    @discardableResult
    private func writeReport(named name: String, created: Date, contents: String) throws -> URL {
        let url = reports.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url, options: .atomic)
        try setCreated(created, at: url)
        return url
    }

    private func matchJSON(
        version: String,
        exception: String,
        queue: String,
        appName: String = "DevType",
        bundleID: String = "com.devtype.app"
    ) -> String {
        """
        {
          "app_name": "\(appName)",
          "bundleID": "\(bundleID)",
          "app_version": "\(version)",
          "procName": "\(appName)",
          "exception": { "type": "\(exception)" },
          "faultingThread": 0,
          "threads": [{ "triggered": true, "queue": "\(queue)" }]
        }
        """
    }

    private func posixMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return mode.intValue & 0o777
    }

    private func previousExitSection(in report: String) throws -> String {
        let start = try XCTUnwrap(report.range(of: "-- Previous exit --"))
        let end = try XCTUnwrap(report.range(of: "-- Identity --"))
        return String(report[start.lowerBound..<end.lowerBound])
    }

    private func reportContext(uncleanExitLines: [String]) -> DiagnosticReport.Context {
        let gate = DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: true,
            isSecureField: false,
            hasIMEMarkedText: false,
            shouldBlockExpand: false,
            blockReason: "ok"
        )
        return DiagnosticReport.Context(
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
            macOSVersion: "14.0",
            appVersion: "1.2.1",
            uncleanExitLines: uncleanExitLines
        )
    }
}
