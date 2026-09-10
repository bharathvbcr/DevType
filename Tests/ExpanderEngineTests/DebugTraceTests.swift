import Foundation
import XCTest
@testable import ExpanderEngine

final class DebugTraceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testProjectedAppendRollsOverBeforeCrossingCapAndTightensExistingMode() throws {
        let url = try makeTraceURL()
        let limit = 512
        try Data(repeating: 0x61, count: limit - 8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: url.path
        )
        let writer = DebugTrace.Writer(fileURL: url, maxBytes: limit)

        writer.enqueue(recordData: Data(#"{"kind":"newest","padding":"xxxxxxxxxxxxxxxx"}"#.utf8))

        XCTAssertEqual(writer.writeStatus, .succeeded)
        let trace = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(trace.count, limit)
        XCTAssertTrue(String(decoding: trace, as: UTF8.self).contains(#""kind":"newest""#))
        XCTAssertEqual(try permissions(at: url), 0o600)
    }

    func testExactLimitRecordSucceedsAndNewFileStartsOwnerOnly() throws {
        let url = try makeTraceURL()
        let limit = 256
        let writer = DebugTrace.Writer(fileURL: url, maxBytes: limit)

        writer.enqueue(recordData: Data(repeating: 0x61, count: limit - 1))

        XCTAssertEqual(writer.writeStatus, .succeeded)
        XCTAssertEqual(try Data(contentsOf: url).count, limit)
        XCTAssertEqual(try permissions(at: url), 0o600)
    }

    func testRotationDecisionTreatsArithmeticOverflowAsOverTheCap() {
        XCTAssertTrue(
            DebugTrace.Writer.requiresRotation(
                currentBytes: UInt64.max,
                recordBytes: 1,
                maximumBytes: UInt64(DebugTrace.maxBytes)
            )
        )
        XCTAssertFalse(
            DebugTrace.Writer.requiresRotation(
                currentBytes: UInt64(DebugTrace.maxBytes - 1),
                recordBytes: 1,
                maximumBytes: UInt64(DebugTrace.maxBytes)
            )
        )
    }

    func testOversizedRecordIsRejectedWithoutCreatingOrChangingTrace() throws {
        let url = try makeTraceURL()
        let limit = 128
        let original = Data("existing\n".utf8)
        try original.write(to: url)
        let writer = DebugTrace.Writer(fileURL: url, maxBytes: limit)

        // The writer owns the newline, so a payload at the byte limit is one byte too large.
        writer.enqueue(recordData: Data(repeating: 0x78, count: limit))

        XCTAssertEqual(writer.writeStatus, .failed(.recordExceedsLimit))
        XCTAssertEqual(try Data(contentsOf: url), original)

        let newURL = url.deletingLastPathComponent().appendingPathComponent("new-trace.jsonl")
        let newWriter = DebugTrace.Writer(fileURL: newURL, maxBytes: limit)
        newWriter.enqueue(recordData: Data(repeating: 0x78, count: limit))
        XCTAssertEqual(newWriter.writeStatus, .failed(.recordExceedsLimit))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
    }

    func testPermissionFailureIsTypedAndDoesNotExposePathOrPayload() throws {
        let url = try makeTraceURL()
        let original = Data("existing\n".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: url.path
        )
        let writer = DebugTrace.Writer(
            fileURL: url,
            maxBytes: 512,
            permissionSetter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let privatePayload = "PRIVATE /Users/person/Client Alpha/secret.txt"

        writer.enqueue(recordData: Data(privatePayload.utf8))
        let status = writer.writeStatus

        XCTAssertEqual(status, .failed(.filePermissions))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(String(describing: status).contains(privatePayload))
        XCTAssertFalse(String(describing: status).contains(url.path))
    }

    func testMissingParentIsTypedFileCreationFailure() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-debug-trace-missing-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(root)
        let url = root.appendingPathComponent("missing/trace.jsonl")
        let writer = DebugTrace.Writer(fileURL: url, maxBytes: 512)

        writer.enqueue(recordData: Data(#"{"kind":"test"}"#.utf8))

        XCTAssertEqual(writer.writeStatus, .failed(.fileCreation))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDirectoryAtConfiguredPathIsRejectedWithoutChangingItsMode() throws {
        let url = try makeTraceURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let writer = DebugTrace.Writer(fileURL: url, maxBytes: 512)

        writer.enqueue(recordData: Data(#"{"kind":"test"}"#.utf8))

        XCTAssertEqual(writer.writeStatus, .failed(.notRegularFile))
        XCTAssertEqual(try permissions(at: url), 0o755)
    }

    func testHealthLineUsesOnlyFiniteContentFreeState() {
        let health = DebugTrace.Health(enabled: true, write: .failed(.filePermissions))

        XCTAssertEqual(
            health.diagnosticLine,
            "Debug trace: enabled; write=failed(file-permissions)"
        )
        XCTAssertFalse(health.diagnosticLine.contains("/Users/"))
    }

    func testHealthLineWhenDisabledAndNotAttemptedOrSucceeded() {
        let disabledHealth = DebugTrace.Health(enabled: false, write: .notAttempted)
        XCTAssertEqual(
            disabledHealth.diagnosticLine,
            "Debug trace: disabled; write=not-attempted"
        )
        let succeededHealth = DebugTrace.Health(enabled: true, write: .succeeded)
        XCTAssertEqual(
            succeededHealth.diagnosticLine,
            "Debug trace: enabled; write=succeeded"
        )
    }

    func testDebugTraceStaticWriteAndHealthDefaults() {
        // Since DebugTrace is disabled by default in tests:
        XCTAssertFalse(DebugTrace.isEnabled)
        XCTAssertEqual(DebugTrace.health, DebugTrace.Health(enabled: false, write: .notAttempted))
        let submission = DebugTrace.write(
            location: "testLoc",
            hypothesisId: "h1",
            message: "msg",
            data: ["key": "val"]
        )
        XCTAssertEqual(submission, .disabled)
    }

    func testWriterDirectRecordFailure() throws {
        let url = try makeTraceURL()
        let writer = DebugTrace.Writer(fileURL: url, maxBytes: 256)
        XCTAssertEqual(writer.writeStatus, .notAttempted)
        writer.recordFailure(.open)
        XCTAssertEqual(writer.writeStatus, .failed(.open))
        writer.recordFailure(.close)
        XCTAssertEqual(writer.writeStatus, .failed(.close))
        writer.recordFailure(.seek)
        XCTAssertEqual(writer.writeStatus, .failed(.seek))
        writer.recordFailure(.truncate)
        XCTAssertEqual(writer.writeStatus, .failed(.truncate))
        writer.recordFailure(.write)
        XCTAssertEqual(writer.writeStatus, .failed(.write))
        writer.recordFailure(.postconditionExceeded)
        XCTAssertEqual(writer.writeStatus, .failed(.postconditionExceeded))
    }

    func testDebugTraceActiveWriterExecution() throws {
        let url = try makeTraceURL()
        let customWriter = DebugTrace.Writer(fileURL: url, maxBytes: 1024)
        DebugTrace.writerOverride = customWriter
        defer { DebugTrace.writerOverride = nil }

        XCTAssertTrue(DebugTrace.isEnabled)
        XCTAssertEqual(DebugTrace.health.enabled, true)

        let accepted = DebugTrace.write(
            location: "TestClass.swift:10",
            hypothesisId: "H1",
            message: "Running trace test",
            data: ["count": 42, "flag": true]
        )
        XCTAssertEqual(accepted, .accepted)

        let rejected = DebugTrace.write(
            location: "TestClass.swift:20",
            hypothesisId: "H2",
            message: "Invalid payload test",
            data: ["bad": Double.nan]
        )
        XCTAssertEqual(rejected, .rejected(.encoding))
    }

    private func makeTraceURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-debug-trace-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("debug-trace.jsonl")
    }

    private func permissions(at url: URL) throws -> Int {
        let number = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        return number.intValue & 0o777
    }
}
