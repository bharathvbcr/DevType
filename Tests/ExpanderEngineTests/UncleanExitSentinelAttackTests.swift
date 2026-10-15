import Darwin
import Foundation
import XCTest
@testable import ExpanderEngine

final class UncleanExitSentinelAttackTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private var reports: URL!
    private var outsideSiblings: [URL] = []

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("unclean-exit-attack-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        reports = root.appendingPathComponent("reports", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: reports, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        if let root {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        if let support {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        }
        if let reports {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reports.path)
        }
        for sibling in outsideSiblings {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sibling.path)
            try? fileManager.removeItem(at: sibling)
        }
        outsideSiblings = []
        if let root {
            try? fileManager.removeItem(at: root)
        }
    }

    func testNewlineSlashAndNULFactsAreOmittedNotTruncated() throws {
        try armSentinel()

        try writeReport(
            named: "DevType-newline-version.ips",
            created: date(1),
            contents: try crashJSON(
                version: "1.2.1\n/Users/person/secret",
                exception: "EXC_BREAKPOINT",
                queue: "com.devtype.selection-read",
                faultingThread: 2
            )
        )
        var lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-newline-version.ips",
            "exception: EXC_BREAKPOINT",
            "queue: com.devtype.selection-read",
        ])
        assertAbsent(
            lines,
            [
                "1.2.1",
                "/Users/person/secret",
                "\n",
                "/",
                "version:",
            ]
        )

        try writeReport(
            named: "DevType-slash-exception.ips",
            created: date(2),
            contents: try crashJSON(
                version: "1.2.1",
                exception: "EXC_BREAKPOINT/../tmp",
                queue: "com.devtype.selection-read",
                faultingThread: 2
            )
        )
        lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-slash-exception.ips",
            "version: 1.2.1",
            "queue: com.devtype.selection-read",
        ])
        assertAbsent(lines, ["EXC_BREAKPOINT", "/", "..", "exception:"])

        try writeReport(
            named: "DevType-nul-queue.ips",
            created: date(3),
            contents: """
            {"app_name":"DevType","app_version":"1.2.1","exception":{"type":"EXC_BREAKPOINT"},"faultingThread":2,"threads":[{"queue":"com.devtype.wrong-zero"},{"queue":"com.devtype.wrong-one"},{"queue":"com.devtype.selection-read\\u0000../etc/passwd"}]}
            """
        )
        lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-nul-queue.ips",
            "version: 1.2.1",
            "exception: EXC_BREAKPOINT",
        ])
        assertAbsent(
            lines,
            [
                "com.devtype.selection-read",
                "com.devtype.wrong-zero",
                "com.devtype.wrong-one",
                "../etc/passwd",
                "\u{0}",
                "queue:",
            ]
        )
    }

    func testDotDotFactsAreOmittedNotCopied() throws {
        try armSentinel()
        try writeReport(
            named: "DevType-dotdot-facts.ips",
            created: date(1),
            contents: try crashJSON(version: "..", exception: "EXC..BREAK", queue: "com..devtype", faultingThread: 2)
        )

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-dotdot-facts.ips",
        ])
        assertAbsent(lines, ["..", "version:", "exception:", "queue:", "EXC..BREAK", "com..devtype"])
    }

    func testSafeQueueAndExceptionSurviveSanitizing() throws {
        try armSentinel()
        try writeReport(
            named: "DevType-safe-facts.ips",
            created: date(1),
            contents: try crashJSON(
                version: "1.2.1",
                exception: "EXC_BREAKPOINT",
                queue: "com.devtype.selection-read",
                faultingThread: 2
            )
        )

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-safe-facts.ips",
            "version: 1.2.1",
            "exception: EXC_BREAKPOINT",
            "queue: com.devtype.selection-read",
        ])
        let section = try previousExitSection(in: report(from: lines))
        for line in lines {
            XCTAssertTrue(section.contains(line), section)
        }
    }

    func testBasenamePathEscapeDoesNotOpenFixtureSibling() throws {
        try armSentinel()
        let marker = "com.devtype.outside-sibling"
        let siblingBytes = Data(
            try crashJSON(
                version: "9.9.9",
                exception: "EXC_GUARD",
                queue: marker,
                faultingThread: 2
            ).utf8
        )
        let sibling = try makeOutsideSibling(
            named: "fixture-sibling-\(UUID().uuidString).ips",
            contents: siblingBytes,
            mode: 0o640
        )
        let siblingBefore = try snapshot(sibling)
        XCTAssertEqual(siblingBefore.mode, 0o640)
        XCTAssertEqual(siblingBefore.bytes, siblingBytes)

        try writeReport(
            named: "DevType-inside.ips",
            created: date(1),
            contents: try crashJSON(
                version: "1.2.1",
                exception: "EXC_BREAKPOINT",
                queue: "com.devtype.selection-read",
                faultingThread: 2
            )
        )
        try FileManager.default.createSymbolicLink(
            at: reports.appendingPathComponent("DevType-...ips"),
            withDestinationURL: sibling
        )
        let relativeEscape = "../../\(sibling.lastPathComponent)"
        XCTAssertTrue(relativeEscape.contains("/"))
        XCTAssertTrue(relativeEscape.contains(".."))
        let slashLink = reports.appendingPathComponent("DevType-a..b.ips")
        XCTAssertEqual(Darwin.symlink(relativeEscape, slashLink.path), 0, "errno \(errno)")

        let rejected = reports.appendingPathComponent("DevType-bad$name.ips")
        try Data(
            try crashJSON(
                version: "/Users/person/rejected",
                exception: "EXC_BREAKPOINT",
                queue: "com.devtype.rejected-inside",
                faultingThread: 2
            ).utf8
        ).write(to: rejected)

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        let siblingAfter = try snapshot(sibling)
        XCTAssertEqual(siblingAfter.mode, siblingBefore.mode)
        XCTAssertEqual(siblingAfter.bytes, siblingBefore.bytes)
        XCTAssertEqual(siblingAfter.inode, siblingBefore.inode)
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-inside.ips",
            "version: 1.2.1",
            "exception: EXC_BREAKPOINT",
            "queue: com.devtype.selection-read",
        ])
        assertAbsent(
            lines,
            [
                marker,
                "9.9.9",
                "EXC_GUARD",
                "com.devtype.rejected-inside",
                "/Users/person/rejected",
                sibling.path,
                "..",
            ]
        )
    }

    func testSymlinkSentinelIsNotFollowedOrCountedUnclean() throws {
        let target = root.appendingPathComponent("sentinel-target")
        let original = Data("ORIGINAL-TARGET".utf8)
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        let targetBefore = try snapshot(target)
        try FileManager.default.createSymbolicLink(at: sentinelURL, withDestinationURL: target)

        let result = launch()
        let targetAfter = try snapshot(target)
        var sentinelInfo = stat()
        XCTAssertEqual(lstat(sentinelURL.path, &sentinelInfo), 0)

        XCTAssertFalse(result.previousRunUnclean)
        XCTAssertEqual(UncleanExitSentinel.diagnosticLines(for: result), [])
        XCTAssertEqual(targetAfter.bytes, targetBefore.bytes)
        XCTAssertEqual(targetAfter.mode, targetBefore.mode)
        XCTAssertEqual(targetAfter.inode, targetBefore.inode)
        XCTAssertEqual(targetAfter.bytes, original)
        XCTAssertTrue((sentinelInfo.st_mode & S_IFMT) == S_IFREG)
        XCTAssertNotEqual(sentinelInfo.st_ino, targetAfter.inode)
        XCTAssertEqual(try String(contentsOf: sentinelURL, encoding: .utf8), "devtype-unclean-exit\n")
        XCTAssertTrue(result.sentinelWritten)
    }

    func testDirectorySentinelDoesNotThrowOrDeleteChildren() throws {
        try FileManager.default.createDirectory(at: sentinelURL, withIntermediateDirectories: true)
        let child = sentinelURL.appendingPathComponent("child.txt")
        let nestedDir = sentinelURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nested = nestedDir.appendingPathComponent("kept.txt")
        let childBytes = Data("keep-child".utf8)
        let nestedBytes = Data("keep-nested".utf8)
        try childBytes.write(to: child)
        try nestedBytes.write(to: nested)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: child.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nested.path)
        let childBefore = try snapshot(child)
        let nestedBefore = try snapshot(nested)

        let result = launch()
        let cleared = UncleanExitSentinel.noteCleanTermination(supportDirectory: support)

        XCTAssertFalse(result.previousRunUnclean)
        XCTAssertFalse(result.sentinelWritten)
        XCTAssertFalse(cleared)
        var sentinelInfo = stat()
        XCTAssertEqual(lstat(sentinelURL.path, &sentinelInfo), 0)
        XCTAssertTrue((sentinelInfo.st_mode & S_IFMT) == S_IFDIR)
        XCTAssertEqual(try snapshot(child).bytes, childBefore.bytes)
        XCTAssertEqual(try snapshot(child).mode, childBefore.mode)
        XCTAssertEqual(try snapshot(nested).bytes, nestedBefore.bytes)
        XCTAssertEqual(try snapshot(nested).mode, nestedBefore.mode)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: sentinelURL.path)),
            ["child.txt", "nested"]
        )
    }

    func testHeaderForeignAndBodyDevTypeMatches() throws {
        try armSentinel()
        let header = #"{"app_name":"Safari","bundleID":"com.apple.Safari","procName":"Safari","app_version":"17.0","note":"brace } /Users/secret/header"}"#
        let body = try crashJSON(
            version: nil,
            exception: "EXC_BREAKPOINT",
            queue: "com.devtype.selection-read",
            faultingThread: 2,
            appName: "Mail",
            procName: "DevType"
        )
        try writeReport(named: "DevType-body-identity.ips", created: date(1), contents: header + "\n" + body)

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-body-identity.ips",
            "version: 17.0",
            "exception: EXC_BREAKPOINT",
            "queue: com.devtype.selection-read",
        ])
        assertAbsent(lines, ["/Users/secret/header", "Safari", "/"])
    }

    func testHeaderDevTypeAndForeignBodyUsesMergedFields() throws {
        try armSentinel()
        let header = #"{"app_name":"DevType","bundleID":"com.devtype.app","procName":"DevType","app_version":"1.2.1"}"#
        let body = try crashJSON(
            version: nil,
            exception: "EXC_CRASH",
            queue: "com.apple.mail.queue",
            faultingThread: 2,
            appName: "Mail",
            bundleID: "com.apple.mail",
            procName: "Mail"
        )
        try writeReport(named: "DevType-header-identity.ips", created: date(1), contents: header + "\n" + body)

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-header-identity.ips",
            "version: 1.2.1",
            "exception: EXC_CRASH",
            "queue: com.apple.mail.queue",
        ])
    }

    func testFaultingThreadOutOfRangeBoolAndStringDoNotSelectWrongQueue() throws {
        try armSentinel()

        try writeReport(
            named: "DevType-oob.ips",
            created: date(1),
            contents: indexedJSON(faultingThread: "99", queues: [
                "com.devtype.oob-zero",
                "com.devtype.oob-one",
            ])
        )
        var lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, ["unclean: yes", "ips: DevType-oob.ips", "exception: EXC_BREAKPOINT"])
        assertAbsent(lines, ["com.devtype.oob-zero", "com.devtype.oob-one", "queue:"])

        try writeReport(
            named: "DevType-bool.ips",
            created: date(2),
            contents: indexedJSON(faultingThread: "true", queues: [
                "com.devtype.bool-zero",
                "com.devtype.bool-one",
            ])
        )
        lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, ["unclean: yes", "ips: DevType-bool.ips", "exception: EXC_BREAKPOINT"])
        assertAbsent(lines, ["com.devtype.bool-zero", "com.devtype.bool-one", "queue:"])

        try writeReport(
            named: "DevType-string-index.ips",
            created: date(3),
            contents: indexedJSON(faultingThread: "\"1\"", queues: [
                "com.devtype.string-zero",
                "com.devtype.string-one",
            ])
        )
        lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-string-index.ips",
            "exception: EXC_BREAKPOINT",
        ])
        assertAbsent(lines, ["com.devtype.string-zero", "com.devtype.string-one", "queue:"])

        try writeReport(
            named: "DevType-negative.ips",
            created: date(4),
            contents: indexedJSON(faultingThread: "-1", queues: [
                "com.devtype.negative-zero",
            ])
        )
        lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, ["unclean: yes", "ips: DevType-negative.ips", "exception: EXC_BREAKPOINT"])
        assertAbsent(lines, ["com.devtype.negative-zero", "queue:"])
    }

    func testFaultingThreadZeroSelectsThatThreadNotTheTriggeredFlag() throws {
        try armSentinel()
        try writeReport(
            named: "DevType-fault-zero.ips",
            created: date(1),
            contents: """
            {
              "app_name": "DevType",
              "app_version": "1.2.1",
              "exception": { "type": "EXC_BREAKPOINT" },
              "faultingThread": 0,
              "threads": [
                { "queue": "com.devtype.faulting-zero" },
                { "triggered": true, "queue": "com.devtype.triggered-other" }
              ]
            }
            """
        )

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-fault-zero.ips",
            "version: 1.2.1",
            "exception: EXC_BREAKPOINT",
            "queue: com.devtype.faulting-zero",
        ])
        assertAbsent(lines, ["com.devtype.triggered-other"])
    }

    func testFaultingThreadOneSelectsThatThreadNotTheTriggeredFlag() throws {
        try armSentinel()
        try writeReport(
            named: "DevType-fault-one.ips",
            created: date(1),
            contents: """
            {
              "app_name": "DevType",
              "app_version": "1.2.1",
              "exception": { "type": "EXC_BREAKPOINT" },
              "faultingThread": 1,
              "threads": [
                { "triggered": true, "queue": "com.devtype.triggered-other" },
                { "queue": "com.devtype.faulting-one" }
              ]
            }
            """
        )

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-fault-one.ips",
            "version: 1.2.1",
            "exception: EXC_BREAKPOINT",
            "queue: com.devtype.faulting-one",
        ])
        assertAbsent(lines, ["com.devtype.triggered-other"])
    }

    func testFaultingThreadAboveOneSelectsThatIndex() throws {
        try armSentinel()
        try writeReport(
            named: "DevType-fault-two.ips",
            created: date(1),
            contents: """
            {
              "app_name": "DevType",
              "app_version": "1.2.1",
              "exception": { "type": "EXC_BREAKPOINT" },
              "faultingThread": 2,
              "threads": [
                { "triggered": true, "queue": "com.devtype.triggered-other" },
                { "queue": "com.devtype.unused-one" },
                { "queue": "com.devtype.faulting-two" }
              ]
            }
            """
        )

        let lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-fault-two.ips",
            "version: 1.2.1",
            "exception: EXC_BREAKPOINT",
            "queue: com.devtype.faulting-two",
        ])
        assertAbsent(lines, ["com.devtype.triggered-other", "com.devtype.unused-one"])
    }

    func testEmptyTruncatedAndEmbeddedBraceDoNotAttachPaths() throws {
        try armSentinel()
        let secret = "/Users/person/ips-secret"

        let empty = try writeReport(named: "DevType-empty.ips", created: date(3), contents: "")
        XCTAssertEqual(try Data(contentsOf: empty), Data())
        var lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, ["unclean: yes"])
        assertAbsent(lines, [secret, "ips:", "queue:", "exception:", "version:"])

        try writeReport(named: "DevType-truncated-brace.ips", created: date(4), contents: "{")
        try writeReport(
            named: "DevType-truncated-path.ips",
            created: date(5),
            contents: "{\"app_name\":\"DevType\",\"exception\":{\"type\":\"\(secret)\""
        )
        lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, ["unclean: yes"])
        assertAbsent(lines, [secret, "ips:", "/"])

        try writeReport(
            named: "DevType-brace-string.ips",
            created: date(6),
            contents: """
            {"app_name":"DevType","note":"brace } \(secret) { still string","app_version":"1.2.1","exception":{"type":"EXC_BREAKPOINT"},"faultingThread":2,"threads":[{"queue":"com.devtype.wrong-zero"},{"queue":"com.devtype.wrong-one"},{"queue":"com.devtype.selection-read"}]}
            """
        )
        lines = UncleanExitSentinel.diagnosticLines(for: launch())
        XCTAssertEqual(lines, [
            "unclean: yes",
            "ips: DevType-brace-string.ips",
            "version: 1.2.1",
            "exception: EXC_BREAKPOINT",
            "queue: com.devtype.selection-read",
        ])
        assertAbsent(lines, [secret, "/", "wrong-zero", "wrong-one"])
    }

    func testSecondCleanTerminationSucceedsWhenSentinelIsGone() throws {
        XCTAssertTrue(launch().sentinelWritten)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))

        XCTAssertTrue(UncleanExitSentinel.noteCleanTermination(supportDirectory: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinelURL.path))
        XCTAssertTrue(UncleanExitSentinel.noteCleanTermination(supportDirectory: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinelURL.path))
    }

    func testAppDelegateArmsAndClearsSentinelWithoutSignalHandler() throws {
        let source = try String(contentsOf: appDelegateURL, encoding: .utf8)
        XCTAssertTrue(source.contains("UncleanExitSentinel.noteLaunch()"))
        XCTAssertTrue(source.contains("UncleanExitSentinel.noteCleanTermination()"))
        XCTAssertFalse(source.contains("signal("))
        XCTAssertFalse(source.contains("sigaction"))
        XCTAssertFalse(source.contains("makeSignalSource"))
    }

    private var sentinelURL: URL {
        support.appendingPathComponent(UncleanExitSentinel.sentinelFileName)
    }

    private var appDelegateURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DevTypeAppCore/AppDelegate.swift")
    }

    private func launch() -> UncleanExitSentinel.LaunchResult {
        UncleanExitSentinel.noteLaunch(
            supportDirectory: support,
            diagnosticReportsDirectory: reports
        )
    }

    private func armSentinel() throws {
        try Data("previous".utf8).write(to: sentinelURL)
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
        if contents.isEmpty == false || created.timeIntervalSince1970 != 0 {
            try setCreated(created, at: url)
        }
        return url
    }

    private func makeOutsideSibling(named name: String, contents: Data, mode: Int) throws -> URL {
        let url = root.deletingLastPathComponent().appendingPathComponent(name)
        try contents.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        outsideSiblings.append(url)
        return url
    }

    private struct FileSnapshot {
        var mode: Int
        var bytes: Data
        var inode: ino_t
    }

    private func snapshot(_ url: URL) throws -> FileSnapshot {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        XCTAssertTrue((info.st_mode & S_IFMT) == S_IFREG)
        return FileSnapshot(
            mode: Int(info.st_mode & 0o777),
            bytes: try Data(contentsOf: url),
            inode: info.st_ino
        )
    }

    private func crashJSON(
        version: String?,
        exception: String,
        queue: String,
        faultingThread: Int,
        appName: String = "DevType",
        bundleID: String? = nil,
        procName: String? = nil
    ) throws -> String {
        var threads: [[String: String]] = []
        if faultingThread > 0 {
            for index in 0..<faultingThread {
                threads.append(["queue": "com.devtype.unused-\(index)"])
            }
        }
        threads.append(["queue": queue])
        var object: [String: Any] = [
            "app_name": appName,
            "exception": ["type": exception],
            "faultingThread": faultingThread,
            "threads": threads,
        ]
        if let version {
            object["app_version"] = version
        }
        if let bundleID {
            object["bundleID"] = bundleID
        }
        if let procName {
            object["procName"] = procName
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func indexedJSON(faultingThread literal: String, queues: [String]) -> String {
        let threads = queues.map { "{ \"queue\": \"\($0)\" }" }.joined(separator: ", ")
        return """
        {"app_name":"DevType","exception":{"type":"EXC_BREAKPOINT"},"faultingThread":\(literal),"threads":[\(threads)]}
        """
    }

    private func assertAbsent(
        _ lines: [String],
        _ forbidden: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rendered = lines.joined(separator: "\n")
        let section = previousExitSectionIfPresent(in: report(from: lines))
        let sectionLines = section?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
        // The projection summary uses `retained/limit` fractions. Judge the copied fact lines.
        let factLines = sectionLines.filter { lines.contains($0) }
        for token in forbidden {
            XCTAssertFalse(lines.contains { $0.contains(token) }, "lines contained \(token): \(rendered)", file: file, line: line)
            XCTAssertFalse(
                factLines.contains { $0.contains(token) },
                "report contained \(token): \(factLines)",
                file: file,
                line: line
            )
        }
    }

    private func report(from lines: [String]) -> String {
        DiagnosticReport.formatFullReport(
            context: reportContext(uncleanExitLines: lines),
            logLines: []
        )
    }

    private func previousExitSectionIfPresent(in report: String) -> String? {
        guard let start = report.range(of: "-- Previous exit --"),
              let end = report.range(of: "-- Identity --"),
              start.lowerBound < end.lowerBound
        else { return nil }
        return String(report[start.lowerBound..<end.lowerBound])
    }

    private func previousExitSection(in report: String) throws -> String {
        try XCTUnwrap(previousExitSectionIfPresent(in: report))
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
