import XCTest
@testable import ExpanderEngine

/// The trace exists to diagnose a defect that has now survived two fixes, so it has to work
/// the first time it is switched on — a diagnostic that silently records nothing wastes the
/// one reproduction the user was willing to capture.
final class VoiceDiagnosticsTraceTests: XCTestCase {

    private var previousSettingObject: Any?
    private var temporaryDirectories: [URL] = []

    override func setUp() {
        super.setUp()
        previousSettingObject = UserDefaults.standard.object(
            forKey: VoicePreferences.voiceTracingKey
        )
    }

    override func tearDown() {
        if let previousSettingObject {
            UserDefaults.standard.set(
                previousSettingObject,
                forKey: VoicePreferences.voiceTracingKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: VoicePreferences.voiceTracingKey)
        }
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    private func makeTraceURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-voice-trace-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("voice-trace.jsonl")
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        return value.intValue & 0o777
    }

    // MARK: - Default state

    /// The trace records dictated text, so a fresh installation must keep it off until the
    /// user explicitly opts in. Release preflight independently enforces the same boundary.
    func testTracingDefaultsOffForShipping() {
        UserDefaults.standard.removeObject(forKey: VoicePreferences.voiceTracingKey)
        XCTAssertFalse(VoicePreferences.voiceTracingDefaultsOn)
        XCTAssertFalse(VoicePreferences.isVoiceTracingEnabled)
    }

    /// An explicit choice always wins over the default, in both directions.
    func testExplicitChoiceOverridesTheDefault() {
        VoicePreferences.isVoiceTracingEnabled = false
        XCTAssertFalse(VoicePreferences.isVoiceTracingEnabled,
            "Turning tracing off must stick")

        VoicePreferences.isVoiceTracingEnabled = true
        XCTAssertTrue(VoicePreferences.isVoiceTracingEnabled)

        UserDefaults.standard.removeObject(forKey: VoicePreferences.voiceTracingKey)
        XCTAssertEqual(VoicePreferences.isVoiceTracingEnabled, VoicePreferences.voiceTracingDefaultsOn)
    }

    /// This records what the user dictated. It must never run when switched off.
    func testNothingIsRecordedWhenDisabled() throws {
        VoicePreferences.isVoiceTracingEnabled = false
        let recorder = VoiceDiagnosticsRecorder(traceURL: try makeTraceURL())

        recorder.record(
            "reconcile",
            segment: SpeechSegment(segmentID: "live-0", text: "secret words", finality: .volatile),
            erase: 5
        )

        XCTAssertNil(recorder.read(),
            "Tracing wrote to disk while disabled")
    }

    // MARK: - Captures what a diagnosis needs

    func testTraceCapturesTheReconcileDecision() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let recorder = VoiceDiagnosticsRecorder(traceURL: try makeTraceURL())

        recorder.beginSession(engine: "apple_speech", liveDeliveryMode: "typeAsYouSpeak")
        recorder.record(
            "segment.ingested",
            segment: SpeechSegment(segmentID: "live-0", revision: 2, text: "hello world", finality: .volatile),
            settled: "",
            active: "hello world",
            cumulative: "hello world"
        )
        recorder.record(
            "reconcile",
            segment: SpeechSegment(segmentID: "live-1", revision: 1, text: "how", finality: .volatile),
            cumulative: "how",
            committedLength: 0,
            volatileLength: 11,
            erase: 11,
            inject: "how",
            suppressed: false
        )

        let trace = try XCTUnwrap(recorder.read())
        let lines = trace.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "Expected one line per event")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let events = try lines.map { try decoder.decode(VoiceDiagnosticsRecorder.Event.self, from: Data($0.utf8)) }

        XCTAssertEqual(events[0].kind, "session.begin")
        XCTAssertEqual(events[1].cumulative, "hello world")

        // The line that identifies an over-erase: what was owned, and how much went.
        let reconcile = events[2]
        XCTAssertEqual(reconcile.kind, "reconcile")
        XCTAssertEqual(reconcile.erase, 11)
        XCTAssertEqual(reconcile.volatileLength, 11)
        XCTAssertEqual(reconcile.segment, "live-1")
        XCTAssertEqual(reconcile.revision, 1)
    }

    func testTraceIsValidJSONLine() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let recorder = VoiceDiagnosticsRecorder(traceURL: try makeTraceURL())
        recorder.record("segment.ingested",
            segment: SpeechSegment(segmentID: "live-0", text: "text with \"quotes\" and \nnewline", finality: .final))

        let trace = try XCTUnwrap(recorder.read())
        // Awkward content must not break the line format the file depends on.
        XCTAssertEqual(trace.split(separator: "\n").count, 1)
        XCTAssertNoThrow(
            try JSONDecoder().decode(
                VoiceDiagnosticsRecorder.Event.self,
                from: Data(trace.split(separator: "\n")[0].utf8)
            )
        )
    }

    func testTraceWriteTightensPreexistingDirectoryAndFilePermissions() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let url = try makeTraceURL()
        let directory = url.deletingLastPathComponent()
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        let recorder = VoiceDiagnosticsRecorder(traceURL: url)

        XCTAssertEqual(recorder.record("permission-hardening", note: "dictated secret"), .accepted)
        XCTAssertNotNil(recorder.read())

        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: url), 0o600)
        XCTAssertEqual(recorder.ioHealth.write, .succeeded)
    }

    func testTraceWriteCreatesOwnerOnlyDiagnosticsDirectoryAndFile() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-voice-trace-parent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true)
        let url = directory.appendingPathComponent("voice-trace.jsonl")
        let recorder = VoiceDiagnosticsRecorder(traceURL: url)

        XCTAssertEqual(recorder.record("new-permissions", note: "dictated secret"), .accepted)
        XCTAssertNotNil(recorder.read())

        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: url), 0o600)
        XCTAssertEqual(recorder.ioHealth.write, .succeeded)
    }

    func testDirectoryPermissionNoOpIsTypedAndNeverReportedAsSuccessful() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let url = try makeTraceURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        let recorder = VoiceDiagnosticsRecorder(
            traceURL: url,
            permissionSetter: { _, _ in }
        )

        XCTAssertEqual(recorder.record("directory-permission-failure"), .accepted)
        XCTAssertEqual(recorder.ioHealth.write, .failed(.directoryPermissions))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTracePermissionFailureIsTypedAndDoesNotRetainNewTranscriptFile() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let url = try makeTraceURL()
        let recorder = VoiceDiagnosticsRecorder(
            traceURL: url,
            permissionSetter: { candidate, mode in
                if mode == 0o600 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.setAttributes(
                    [.posixPermissions: mode],
                    ofItemAtPath: candidate.path
                )
            }
        )

        XCTAssertEqual(recorder.record("permission-failure", note: "dictated secret"), .accepted)
        XCTAssertEqual(recorder.ioHealth.write, .failed(.filePermissions))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTraceReadTightensPreexistingDirectoryAndFilePermissions() throws {
        let url = try makeTraceURL()
        let directory = url.deletingLastPathComponent()
        try Data("existing dictated trace".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        let recorder = VoiceDiagnosticsRecorder(traceURL: url)

        XCTAssertEqual(recorder.read(), "existing dictated trace")
        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: url), 0o600)
        XCTAssertEqual(recorder.ioHealth.read, .succeeded)
    }

    func testTraceReadPermissionFailureIsTypedAndNeverReportsSuccess() throws {
        let url = try makeTraceURL()
        try Data("existing dictated trace".utf8).write(to: url)
        let recorder = VoiceDiagnosticsRecorder(
            traceURL: url,
            permissionSetter: { candidate, mode in
                if mode == 0o600 { throw CocoaError(.fileReadNoPermission) }
                try FileManager.default.setAttributes(
                    [.posixPermissions: mode],
                    ofItemAtPath: candidate.path
                )
            }
        )

        XCTAssertNil(recorder.read())
        XCTAssertEqual(recorder.ioHealth.read, .failed(.filePermissions))
        XCTAssertTrue(recorder.ioHealth.hasFailure)
    }

    func testClearRemovesTheTrace() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let recorder = VoiceDiagnosticsRecorder(traceURL: try makeTraceURL())
        recorder.record("session.begin")
        XCTAssertNotNil(recorder.read())

        recorder.clear()
        XCTAssertNil(recorder.read())
    }

    // MARK: - Serialized I/O and retention

    func testAcceptedWriteIsVisibleToAnImmediateRead() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let recorder = VoiceDiagnosticsRecorder(
            traceURL: try makeTraceURL(),
            beforeAppendForTesting: {
                writeStarted.signal()
                releaseWrite.wait()
            }
        )

        XCTAssertEqual(recorder.record("immediate-read"), .accepted)
        guard writeStarted.wait(timeout: .now() + 1) == .success else {
            releaseWrite.signal()
            return XCTFail("The accepted append never reached the recorder queue.")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
            releaseWrite.signal()
        }

        let trace = try XCTUnwrap(recorder.read(), "read() must wait for every accepted write ahead of it")
        XCTAssertTrue(trace.contains("immediate-read"))
    }

    func testClearCannotBeUndoneByAnAlreadyQueuedAppend() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let appendFinished = DispatchSemaphore(value: 0)
        let recorder = VoiceDiagnosticsRecorder(
            traceURL: try makeTraceURL(),
            beforeAppendForTesting: {
                writeStarted.signal()
                releaseWrite.wait()
            },
            afterAppendForTesting: {
                appendFinished.signal()
            }
        )

        XCTAssertEqual(recorder.record("queued-before-clear"), .accepted)
        guard writeStarted.wait(timeout: .now() + 1) == .success else {
            releaseWrite.signal()
            return XCTFail("The accepted append never reached the recorder queue.")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
            releaseWrite.signal()
        }

        XCTAssertEqual(recorder.clear(), .succeeded)
        XCTAssertEqual(appendFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(recorder.read(), "A queued append recreated the trace after clear returned.")
    }

    func testProjectedWriteRollsOverBeforeCrossingFourMiB() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let url = try makeTraceURL()
        try Data(repeating: 0x61, count: VoiceDiagnosticsRecorder.maxBytes - 32).write(to: url)
        let recorder = VoiceDiagnosticsRecorder(traceURL: url)

        XCTAssertEqual(recorder.record("newest-after-rollover", note: "bounded"), .accepted)
        let trace = try XCTUnwrap(recorder.read())
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        ).intValue

        XCTAssertLessThanOrEqual(size, VoiceDiagnosticsRecorder.maxBytes)
        XCTAssertEqual(trace.split(separator: "\n").count, 1, "The stale prefix must be replaced.")
        XCTAssertTrue(trace.contains("newest-after-rollover"))
        XCTAssertEqual(recorder.ioHealth.write, .succeeded)
        let coverage = try XCTUnwrap(recorder.ioHealth.traceReadCoverage)
        XCTAssertFalse(coverage.isComplete, "A rotated trace is only the retained tail, not complete history.")
        XCTAssertEqual(
            coverage.droppedByteCount,
            UInt64(VoiceDiagnosticsRecorder.maxBytes - 32)
        )
        XCTAssertEqual(coverage.retainedByteCount, size)
        XCTAssertEqual(
            coverage.observedByteCount,
            coverage.droppedByteCount + UInt64(coverage.retainedByteCount)
        )
        let retainedEvent = try JSONDecoder().decode(
            VoiceDiagnosticsRecorder.Event.self,
            from: Data(trace.trimmingCharacters(in: .newlines).utf8)
        )
        XCTAssertEqual(retainedEvent.droppedBytes, coverage.droppedByteCount)

        let reloaded = VoiceDiagnosticsRecorder(traceURL: url)
        XCTAssertNotNil(reloaded.read())
        XCTAssertEqual(
            reloaded.ioHealth.traceReadCoverage,
            coverage,
            "Rollover coverage must be recoverable from the JSONL file after relaunch."
        )
    }

    func testLegacyTraceEventWithoutRolloverMetadataStillDecodes() throws {
        let legacyLine = #"{"at":0,"kind":"session.begin"}"#

        let event = try JSONDecoder().decode(
            VoiceDiagnosticsRecorder.Event.self,
            from: Data(legacyLine.utf8)
        )

        XCTAssertEqual(event.kind, "session.begin")
        XCTAssertNil(event.droppedBytes)
    }

    func testSingleOversizedEventIsRejectedWithoutBreakingTheCap() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let url = try makeTraceURL()
        let recorder = VoiceDiagnosticsRecorder(traceURL: url)
        let oversizedNote = String(repeating: "x", count: VoiceDiagnosticsRecorder.maxBytes)

        XCTAssertEqual(recorder.record("oversized", note: oversizedNote), .accepted)
        XCTAssertEqual(recorder.ioHealth.write, .failed(.eventExceedsLimit))
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .intValue ?? 0

        XCTAssertLessThanOrEqual(size, VoiceDiagnosticsRecorder.maxBytes)
        XCTAssertNil(recorder.read())
        XCTAssertEqual(
            recorder.ioHealth.write,
            .failed(.eventExceedsLimit),
            "A successful empty read must not erase the write failure."
        )
    }

    func testIOHealthReportsTypedContentFreeWriteFailure() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let root = try makeTraceURL().deletingLastPathComponent()
        let nonDirectory = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: nonDirectory)
        let impossibleURL = nonDirectory.appendingPathComponent("voice-trace.jsonl")
        let recorder = VoiceDiagnosticsRecorder(traceURL: impossibleURL)
        let privateText = "private dictated health sentinel"

        XCTAssertEqual(recorder.record("write-failure", note: privateText), .accepted)
        let health = recorder.ioHealth

        XCTAssertEqual(health.write, .failed(.directoryCreation))
        XCTAssertEqual(health.read, .notAttempted)
        XCTAssertEqual(health.delete, .notAttempted)
        XCTAssertFalse(String(describing: health).contains(privateText))
        XCTAssertFalse(String(describing: health).contains(impossibleURL.path))
    }

    func testInvalidTraceDataIsAReadFailureRatherThanAQuietEmptyTrace() throws {
        let url = try makeTraceURL()
        try Data([0xFF, 0xFE]).write(to: url)
        let recorder = VoiceDiagnosticsRecorder(traceURL: url)

        XCTAssertNil(recorder.read())
        XCTAssertEqual(recorder.ioHealth.read, .failed(.invalidUTF8))
        XCTAssertTrue(recorder.ioHealth.hasFailure)
    }

    func testTraceReadAcceptsTheExactInputByteLimit() throws {
        let url = try makeTraceURL()
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(VoiceDiagnosticsRecorder.maxBytes))
        try handle.close()
        let recorder = VoiceDiagnosticsRecorder(traceURL: url)

        let trace = try XCTUnwrap(recorder.read())

        XCTAssertEqual(trace.utf8.count, VoiceDiagnosticsRecorder.maxBytes)
        XCTAssertEqual(recorder.ioHealth.read, .succeeded)
        XCTAssertEqual(
            recorder.ioHealth.traceReadCoverage,
            VoiceDiagnosticsRecorder.TraceReadCoverage(
                observedByteCount: UInt64(VoiceDiagnosticsRecorder.maxBytes),
                retainedByteCount: VoiceDiagnosticsRecorder.maxBytes,
                droppedByteCount: 0,
                isComplete: true
            )
        )
    }

    func testTraceReadRejectsLimitPlusOneInsteadOfReturningACappedSampleAsComplete() throws {
        let url = try makeTraceURL()
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(VoiceDiagnosticsRecorder.maxBytes + 1))
        try handle.close()
        let recorder = VoiceDiagnosticsRecorder(traceURL: url)

        XCTAssertNil(recorder.read())
        XCTAssertEqual(recorder.ioHealth.read, .failed(.traceExceedsLimit))
        XCTAssertEqual(
            recorder.ioHealth.traceReadCoverage,
            VoiceDiagnosticsRecorder.TraceReadCoverage(
                observedByteCount: UInt64(VoiceDiagnosticsRecorder.maxBytes + 1),
                retainedByteCount: 0,
                droppedByteCount: UInt64(VoiceDiagnosticsRecorder.maxBytes + 1),
                isComplete: false
            )
        )
    }

    func testDeleteTraceLeavesCaptureEnabledButDisableAndDeleteStopsIt() throws {
        VoicePreferences.isVoiceTracingEnabled = true
        let recorder = VoiceDiagnosticsRecorder(traceURL: try makeTraceURL())
        XCTAssertEqual(recorder.record("before-delete"), .accepted)
        XCTAssertNotNil(recorder.read())

        XCTAssertEqual(recorder.deleteTrace(), .succeeded)
        XCTAssertTrue(recorder.isEnabled)
        XCTAssertNil(recorder.read())

        XCTAssertEqual(recorder.record("before-disable"), .accepted)
        XCTAssertNotNil(recorder.read())
        XCTAssertEqual(recorder.disableAndDelete(), .succeeded)
        XCTAssertFalse(recorder.isEnabled)
        XCTAssertNil(recorder.read())
        XCTAssertEqual(recorder.record("after-disable"), .disabled)
        XCTAssertNil(recorder.read())
    }

    // MARK: - Ordering precondition

    /// Segments must reach the assembler in the order the recognizer produced them.
    ///
    /// They are delivered with `DispatchQueue.main.async`, which is FIFO. An earlier version
    /// used `Task { @MainActor }`, which carries no ordering guarantee — several are in
    /// flight at speaking speed, and a later segment applied before an earlier one puts a
    /// new segment id into the transcript out of sequence.
    ///
    /// This test documents what that costs, so the precondition is not quietly dropped.
    func testOutOfOrderSegmentIdsCorruptTheTranscript() {
        var inOrder = LiveTranscriptAssembler()
        _ = inOrder.ingest(SpeechSegment(segmentID: "live-0", revision: 1, text: "first", finality: .volatile))
        _ = inOrder.ingest(SpeechSegment(segmentID: "live-1", revision: 1, text: "second", finality: .volatile))
        XCTAssertEqual(inOrder.cumulativeText, "first second")

        var reversed = LiveTranscriptAssembler()
        _ = reversed.ingest(SpeechSegment(segmentID: "live-1", revision: 1, text: "second", finality: .volatile))
        _ = reversed.ingest(SpeechSegment(segmentID: "live-0", revision: 1, text: "first", finality: .volatile))

        XCTAssertEqual(
            reversed.cumulativeText, "second first",
            """
            The assembler orders segments by arrival, so delivery must be FIFO. If this \
            expectation ever changes, check that segments are still dispatched on the main \
            queue rather than in unstructured tasks.
            """
        )
    }

    /// Whatever the order, no text is silently dropped — the words are all still there.
    func testOutOfOrderDeliveryNeverLosesText() {
        var assembler = LiveTranscriptAssembler()
        for id in ["live-2", "live-0", "live-3", "live-1"] {
            _ = assembler.ingest(SpeechSegment(segmentID: id, revision: 1, text: id, finality: .volatile))
        }
        for id in ["live-0", "live-1", "live-2", "live-3"] {
            XCTAssertTrue(assembler.cumulativeText.contains(id), "Lost \(id)")
        }
    }
}
