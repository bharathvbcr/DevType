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
