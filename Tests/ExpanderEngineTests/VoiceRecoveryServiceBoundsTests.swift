import Foundation
import XCTest
@testable import ExpanderEngine

final class VoiceRecoveryServiceBoundsTests: XCTestCase {
    func testScanAcceptsEveryArtifactAtItsExactByteLimit() throws {
        let base = try makeTemporaryDirectory(named: "exact")
        defer { try? FileManager.default.removeItem(at: base) }

        let secret = "exact-boundary-private-transcript"
        let fixture = try writeSession(
            in: base,
            directoryName: "exact-session",
            createdAt: Date(timeIntervalSince1970: 10),
            transcript: secret
        )
        let report = VoiceRecoveryService(
            scanLimits: limits(for: fixture, maximumCandidateDirectories: 1)
        ).scanReport(baseDirectory: base)

        let session = try XCTUnwrap(report.sessions.first)
        XCTAssertEqual(report.sessions.count, 1)
        XCTAssertEqual(session.rawTranscript?.text, secret)
        XCTAssertEqual(session.finalTranscript?.text, "Final: \(secret)")
        XCTAssertNotNil(session.receipt)
        XCTAssertTrue(session.isDelivered)
        XCTAssertEqual(report.candidateDirectoriesObserved, 1)
        XCTAssertEqual(report.candidateDirectoriesInspected, 1)
        XCTAssertEqual(report.candidateDirectoriesSkippedByLimit, 0)
        XCTAssertEqual(report.candidateDirectoriesRejected, 0)
        XCTAssertEqual(report.corruptArtifactCount, 0)
        XCTAssertEqual(report.oversizedArtifactCount, 0)
        XCTAssertTrue(report.directoryEnumerationWasComplete)
        XCTAssertFalse(report.diagnosticSummary.contains(secret))
        XCTAssertFalse(report.diagnosticSummary.contains(base.path))
    }

    func testManifestAtLimitPlusOneRejectsCandidateBeforeDecode() throws {
        let base = try makeTemporaryDirectory(named: "manifest-plus-one")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try writeSession(in: base, directoryName: "session")

        var limits = limits(for: fixture, maximumCandidateDirectories: 1)
        limits.maximumManifestBytes = fixture.manifestData.count - 1
        let report = VoiceRecoveryService(scanLimits: limits).scanReport(baseDirectory: base)

        XCTAssertTrue(report.sessions.isEmpty)
        XCTAssertEqual(report.candidateDirectoriesInspected, 1)
        XCTAssertEqual(report.candidateDirectoriesRejected, 1)
        XCTAssertEqual(report.oversizedArtifactCount, 1)
        XCTAssertEqual(report.corruptArtifactCount, 0)
    }

    func testRawTranscriptAtLimitPlusOneIsOmittedWithoutRejectingSession() throws {
        let base = try makeTemporaryDirectory(named: "raw-plus-one")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try writeSession(in: base, directoryName: "session")

        var limits = limits(for: fixture, maximumCandidateDirectories: 1)
        limits.maximumRawTranscriptBytes = fixture.rawData.count - 1
        let report = VoiceRecoveryService(scanLimits: limits).scanReport(baseDirectory: base)

        let session = try XCTUnwrap(report.sessions.first)
        XCTAssertNil(session.rawTranscript)
        XCTAssertNotNil(session.finalTranscript)
        XCTAssertNotNil(session.receipt)
        XCTAssertEqual(report.candidateDirectoriesRejected, 0)
        XCTAssertEqual(report.oversizedArtifactCount, 1)
        XCTAssertEqual(report.corruptArtifactCount, 0)
    }

    func testFinalTranscriptAtLimitPlusOneIsOmittedWithoutRejectingSession() throws {
        let base = try makeTemporaryDirectory(named: "final-plus-one")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try writeSession(in: base, directoryName: "session")

        var limits = limits(for: fixture, maximumCandidateDirectories: 1)
        limits.maximumFinalTranscriptBytes = fixture.finalData.count - 1
        let report = VoiceRecoveryService(scanLimits: limits).scanReport(baseDirectory: base)

        let session = try XCTUnwrap(report.sessions.first)
        XCTAssertNotNil(session.rawTranscript)
        XCTAssertNil(session.finalTranscript)
        XCTAssertNotNil(session.receipt)
        XCTAssertEqual(report.candidateDirectoriesRejected, 0)
        XCTAssertEqual(report.oversizedArtifactCount, 1)
        XCTAssertEqual(report.corruptArtifactCount, 0)
    }

    func testReceiptAtLimitPlusOneRejectsCandidateWithUnknownDeliveryState() throws {
        let base = try makeTemporaryDirectory(named: "receipt-plus-one")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try writeSession(in: base, directoryName: "session")

        var limits = limits(for: fixture, maximumCandidateDirectories: 1)
        limits.maximumDeliveryReceiptBytes = fixture.receiptData.count - 1
        let report = VoiceRecoveryService(scanLimits: limits).scanReport(baseDirectory: base)

        XCTAssertTrue(
            report.sessions.isEmpty,
            "An existing unreadable receipt is unknown, not evidence that delivery never happened"
        )
        XCTAssertEqual(report.candidateDirectoriesRejected, 1)
        XCTAssertEqual(report.oversizedArtifactCount, 1)
        XCTAssertEqual(report.corruptArtifactCount, 0)
    }

    func testCorruptReceiptRejectsCandidateWithUnknownDeliveryState() throws {
        let base = try makeTemporaryDirectory(named: "receipt-corrupt")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try writeSession(in: base, directoryName: "session")
        try Data("not-a-delivery-receipt".utf8)
            .write(to: fixture.directoryURL.appendingPathComponent("delivery-receipt.json"))

        let report = VoiceRecoveryService(
            scanLimits: expandedLimits(for: fixture, maximumCandidateDirectories: 1)
        ).scanReport(baseDirectory: base)

        XCTAssertTrue(report.sessions.isEmpty)
        XCTAssertEqual(report.candidateDirectoriesRejected, 1)
        XCTAssertEqual(report.corruptArtifactCount, 1)
        XCTAssertEqual(report.oversizedArtifactCount, 0)
    }

    func testCandidateLimitAcceptsExactCountThenReportsLimitPlusOne() throws {
        let base = try makeTemporaryDirectory(named: "candidate-boundary")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date(timeIntervalSince1970: 1_000)

        let newest = try writeSession(
            in: base,
            directoryName: "newest",
            createdAt: now,
            transcript: "newest",
            directoryModificationDate: now
        )
        _ = try writeSession(
            in: base,
            directoryName: "second",
            createdAt: now.addingTimeInterval(-1),
            transcript: "second",
            directoryModificationDate: now.addingTimeInterval(-1)
        )
        let service = VoiceRecoveryService(
            scanLimits: expandedLimits(for: newest, maximumCandidateDirectories: 2)
        )

        let exact = service.scanReport(baseDirectory: base)
        XCTAssertEqual(exact.candidateDirectoriesObserved, 2)
        XCTAssertEqual(exact.candidateDirectoriesInspected, 2)
        XCTAssertEqual(exact.candidateDirectoriesSkippedByLimit, 0)
        XCTAssertEqual(
            exact.sessions.map { Self.recoveredText($0) },
            ["Final: newest", "Final: second"]
        )

        _ = try writeSession(
            in: base,
            directoryName: "oldest",
            createdAt: now.addingTimeInterval(-2),
            transcript: "oldest",
            directoryModificationDate: now.addingTimeInterval(-2)
        )
        let plusOne = service.scanReport(baseDirectory: base)
        XCTAssertEqual(plusOne.candidateDirectoriesObserved, 3)
        XCTAssertEqual(plusOne.candidateDirectoriesInspected, 2)
        XCTAssertEqual(plusOne.candidateDirectoriesSkippedByLimit, 1)
        XCTAssertEqual(
            plusOne.sessions.map { Self.recoveredText($0) },
            ["Final: newest", "Final: second"]
        )
        XCTAssertTrue(plusOne.directoryEnumerationWasComplete)
    }

    func testExcessiveDirectoryTailIsCountedButNeverRead() throws {
        let base = try makeTemporaryDirectory(named: "excessive")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date(timeIntervalSince1970: 2_000)

        let newest = try writeSession(
            in: base,
            directoryName: "kept-c",
            createdAt: now,
            transcript: "first",
            directoryModificationDate: now
        )
        _ = try writeSession(
            in: base,
            directoryName: "kept-a",
            createdAt: now.addingTimeInterval(-1),
            transcript: "second",
            directoryModificationDate: now.addingTimeInterval(-1)
        )
        _ = try writeSession(
            in: base,
            directoryName: "kept-b",
            createdAt: now.addingTimeInterval(-2),
            transcript: "third",
            directoryModificationDate: now.addingTimeInterval(-2)
        )

        let limits = expandedLimits(for: newest, maximumCandidateDirectories: 3)
        for index in 0..<37 {
            let directory = base.appendingPathComponent("excluded-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data(repeating: 0x58, count: limits.maximumManifestBytes + 1)
                .write(to: directory.appendingPathComponent("manifest.json"))
            try setModificationDate(
                now.addingTimeInterval(-100 - Double(index)),
                for: directory
            )
        }

        let report = VoiceRecoveryService(scanLimits: limits).scanReport(baseDirectory: base)

        XCTAssertEqual(report.candidateDirectoriesObserved, 40)
        XCTAssertEqual(report.candidateDirectoriesInspected, 3)
        XCTAssertEqual(report.candidateDirectoriesSkippedByLimit, 37)
        XCTAssertEqual(report.candidateDirectoriesRejected, 0)
        XCTAssertEqual(report.corruptArtifactCount, 0)
        XCTAssertEqual(
            report.oversizedArtifactCount,
            0,
            "Oversized manifests outside the candidate cap must never be opened"
        )
        XCTAssertEqual(
            report.sessions.map { Self.recoveredText($0) },
            ["Final: first", "Final: second", "Final: third"]
        )
        XCTAssertTrue(report.directoryEnumerationWasComplete)
    }

    func testPruneTraversesWholeStoreAndPreservesRecoveriesWithoutDeletingUnrelatedEntries() throws {
        let base = try makeTemporaryDirectory(named: "whole-store-prune")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date(timeIntervalSince1970: 10_000)

        var firstFixture: SessionFixture?
        for index in 0..<50 {
            let fixture = try writeSession(
                in: base,
                directoryName: String(format: "delivered-%02d", index),
                createdAt: now.addingTimeInterval(-Double(index)),
                transcript: "delivered-\(index)",
                delivered: true,
                directoryModificationDate: now.addingTimeInterval(-Double(index))
            )
            if firstFixture == nil { firstFixture = fixture }
        }
        for index in 0..<30 {
            _ = try writeSession(
                in: base,
                directoryName: String(format: "recovery-%02d", index),
                createdAt: now.addingTimeInterval(-100 - Double(index)),
                transcript: "recovery-\(index)",
                delivered: false,
                directoryModificationDate: now.addingTimeInterval(-100 - Double(index))
            )
        }

        let unrelatedDirectory = base.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: false)
        let unrelatedPayload = unrelatedDirectory.appendingPathComponent("keep-me.txt")
        try Data("not a voice session".utf8).write(to: unrelatedPayload)
        let unrelatedFile = base.appendingPathComponent("also-keep-me.txt")
        try Data("top-level file".utf8).write(to: unrelatedFile)

        let fixture = try XCTUnwrap(firstFixture)
        let service = VoiceRecoveryService(
            scanLimits: expandedLimits(for: fixture, maximumCandidateDirectories: 50)
        )
        let removed = service.prune(
            olderThan: 365 * 24 * 60 * 60,
            keepingAtMost: 7,
            baseDirectory: base,
            now: now
        )

        let report = service.scanReport(baseDirectory: base)
        XCTAssertEqual(removed, 73)
        XCTAssertEqual(report.sessions.count, 7)
        XCTAssertEqual(
            report.sessions.map { Self.recoveredText($0) },
            (0..<7).map { "Final: recovery-\($0)" },
            "Undelivered recoveries must outrank newer delivered artifacts across the full store"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPayload.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
        XCTAssertEqual(report.candidateDirectoriesObserved, 8)
        XCTAssertEqual(report.candidateDirectoriesRejected, 1)
    }

    func testNewestFirstOrderingUsesStablePathTieBreak() throws {
        let base = try makeTemporaryDirectory(named: "stable-order")
        defer { try? FileManager.default.removeItem(at: base) }
        let createdAt = Date(timeIntervalSince1970: 3_000)

        let first = try writeSession(
            in: base,
            directoryName: "b-session",
            createdAt: createdAt,
            transcript: "b",
            directoryModificationDate: createdAt
        )
        _ = try writeSession(
            in: base,
            directoryName: "a-session",
            createdAt: createdAt,
            transcript: "a",
            directoryModificationDate: createdAt
        )
        let report = VoiceRecoveryService(
            scanLimits: expandedLimits(for: first, maximumCandidateDirectories: 2)
        ).scanReport(baseDirectory: base)

        XCTAssertEqual(report.sessions.map { $0.directoryURL.lastPathComponent }, ["a-session", "b-session"])
    }

    func testReportSeparatesCorruptionFromOversizeAndEnumerationFailure() throws {
        let base = try makeTemporaryDirectory(named: "reporting")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try writeSession(
            in: base,
            directoryName: "valid-manifest",
            transcript: "must-not-enter-recovery-diagnostics"
        )
        try Data("not-json-private-payload".utf8)
            .write(to: fixture.directoryURL.appendingPathComponent("raw-transcript.json"))

        let corruptManifestDirectory = base.appendingPathComponent("corrupt-manifest", isDirectory: true)
        try FileManager.default.createDirectory(
            at: corruptManifestDirectory,
            withIntermediateDirectories: false
        )
        try Data("not-json-private-manifest".utf8)
            .write(to: corruptManifestDirectory.appendingPathComponent("manifest.json"))

        let report = VoiceRecoveryService(
            scanLimits: expandedLimits(for: fixture, maximumCandidateDirectories: 2)
        ).scanReport(baseDirectory: base)

        XCTAssertEqual(report.candidateDirectoriesObserved, 2)
        XCTAssertEqual(report.candidateDirectoriesInspected, 2)
        XCTAssertEqual(report.candidateDirectoriesRejected, 1)
        XCTAssertEqual(report.corruptArtifactCount, 2)
        XCTAssertEqual(report.oversizedArtifactCount, 0)
        XCTAssertTrue(report.directoryEnumerationWasComplete)
        XCTAssertFalse(report.diagnosticSummary.contains("must-not-enter-recovery-diagnostics"))
        XCTAssertFalse(report.diagnosticSummary.contains("not-json-private"))
        XCTAssertFalse(report.diagnosticSummary.contains(base.path))

        let missing = base.appendingPathComponent("does-not-exist", isDirectory: true)
        let failed = VoiceRecoveryService(
            scanLimits: expandedLimits(for: fixture, maximumCandidateDirectories: 2)
        ).scanReport(baseDirectory: missing)
        XCTAssertFalse(failed.directoryEnumerationWasComplete)
        XCTAssertEqual(failed.candidateDirectoriesObserved, 0)
        XCTAssertEqual(failed.candidateDirectoriesSkippedByLimit, 0)
    }

    private struct SessionFixture {
        let directoryURL: URL
        let manifestData: Data
        let rawData: Data
        let finalData: Data
        let receiptData: Data
    }

    private func writeSession(
        in base: URL,
        directoryName: String,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        transcript: String = "private transcript",
        delivered: Bool = true,
        directoryModificationDate: Date? = nil
    ) throws -> SessionFixture {
        let sessionID = VoiceSessionID()
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        let target = TargetLease(
            bundleIdentifier: "com.example.target",
            processIdentifier: 42,
            acquiredAt: createdAt
        )
        let snapshot = VoiceSessionSnapshot(
            sessionID: sessionID,
            generation: SessionGeneration(rawValue: 1),
            createdAt: createdAt,
            speechProvider: SpeechProviderDescriptor(
                id: "test.speech",
                displayName: "Test Speech",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly,
                supportsStreaming: false,
                supportsContextualStrings: false
            ),
            correctionProvider: CorrectionProviderDescriptor(
                id: "test.correction",
                displayName: "Test Correction",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly,
                supportsStructuredOutput: false
            ),
            privacyRoute: .onDeviceOnly,
            targetLease: target
        )
        let raw = RawTranscript(
            text: transcript,
            localeIdentifier: "en_US",
            providerID: "test.speech",
            modelVersion: "1"
        )
        let final = FinalTranscript(
            text: "Final: \(transcript)",
            rawTranscript: raw,
            validationOutcome: .notApplicable,
            timestamp: createdAt
        )
        let receipt = DeliveryReceipt(
            sessionID: sessionID,
            generation: SessionGeneration(rawValue: 1),
            targetLease: target,
            deliveredTextLength: final.text.count,
            evidenceQuality: .verifiedDirectAX,
            deliveredAt: createdAt,
            latencyMs: 1
        )

        let manifestData = try JSONEncoder().encode(snapshot)
        let rawData = try JSONEncoder().encode(raw)
        let finalData = try JSONEncoder().encode(final)
        let receiptData = try JSONEncoder().encode(receipt)
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"))
        try rawData.write(to: directory.appendingPathComponent("raw-transcript.json"))
        try finalData.write(to: directory.appendingPathComponent("final-transcript.json"))
        if delivered {
            try receiptData.write(to: directory.appendingPathComponent("delivery-receipt.json"))
        }
        try setModificationDate(directoryModificationDate ?? createdAt, for: directory)

        return SessionFixture(
            directoryURL: directory,
            manifestData: manifestData,
            rawData: rawData,
            finalData: finalData,
            receiptData: receiptData
        )
    }

    private func limits(
        for fixture: SessionFixture,
        maximumCandidateDirectories: Int
    ) -> VoiceRecoveryService.ScanLimits {
        VoiceRecoveryService.ScanLimits(
            maximumCandidateDirectories: maximumCandidateDirectories,
            maximumManifestBytes: fixture.manifestData.count,
            maximumRawTranscriptBytes: fixture.rawData.count,
            maximumFinalTranscriptBytes: fixture.finalData.count,
            maximumDeliveryReceiptBytes: fixture.receiptData.count
        )
    }

    private func expandedLimits(
        for fixture: SessionFixture,
        maximumCandidateDirectories: Int
    ) -> VoiceRecoveryService.ScanLimits {
        VoiceRecoveryService.ScanLimits(
            maximumCandidateDirectories: maximumCandidateDirectories,
            maximumManifestBytes: fixture.manifestData.count + 1_024,
            maximumRawTranscriptBytes: fixture.rawData.count + 1_024,
            maximumFinalTranscriptBytes: fixture.finalData.count + 1_024,
            maximumDeliveryReceiptBytes: fixture.receiptData.count + 1_024
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceRecoveryBounds-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setModificationDate(_ date: Date, for directory: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: directory.path
        )
    }

    private static func recoveredText(_ session: RecoverableVoiceSession) -> String {
        VoiceRecoveryService.recoveredText(session)
    }
}
