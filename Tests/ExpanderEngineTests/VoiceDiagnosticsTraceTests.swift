import XCTest
@testable import ExpanderEngine

/// The trace exists to diagnose a defect that has now survived two fixes, so it has to work
/// the first time it is switched on — a diagnostic that silently records nothing wastes the
/// one reproduction the user was willing to capture.
final class VoiceDiagnosticsTraceTests: XCTestCase {

    private var previousSetting = false

    override func setUp() {
        super.setUp()
        previousSetting = VoicePreferences.isVoiceTracingEnabled
        VoiceDiagnosticsRecorder.shared.clear()
    }

    override func tearDown() {
        VoicePreferences.isVoiceTracingEnabled = previousSetting
        VoiceDiagnosticsRecorder.shared.clear()
        super.tearDown()
    }

    /// Flushes the recorder's background queue.
    private func settle() {
        let expectation = expectation(description: "trace flushed")
        DispatchQueue(label: "test.settle").asyncAfter(deadline: .now() + 0.25) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
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
    func testNothingIsRecordedWhenDisabled() {
        VoicePreferences.isVoiceTracingEnabled = false

        VoiceDiagnosticsRecorder.shared.record(
            "reconcile",
            segment: SpeechSegment(segmentID: "live-0", text: "secret words", finality: .volatile),
            erase: 5
        )
        settle()

        XCTAssertNil(VoiceDiagnosticsRecorder.shared.read(),
            "Tracing wrote to disk while disabled")
    }

    // MARK: - Captures what a diagnosis needs

    func testTraceCapturesTheReconcileDecision() throws {
        VoicePreferences.isVoiceTracingEnabled = true

        VoiceDiagnosticsRecorder.shared.beginSession(engine: "apple_speech", realTimeTyping: true)
        VoiceDiagnosticsRecorder.shared.record(
            "segment.ingested",
            segment: SpeechSegment(segmentID: "live-0", revision: 2, text: "hello world", finality: .volatile),
            settled: "",
            active: "hello world",
            cumulative: "hello world"
        )
        VoiceDiagnosticsRecorder.shared.record(
            "reconcile",
            segment: SpeechSegment(segmentID: "live-1", revision: 1, text: "how", finality: .volatile),
            cumulative: "how",
            committedLength: 0,
            volatileLength: 11,
            erase: 11,
            inject: "how",
            suppressed: false
        )
        settle()

        let trace = try XCTUnwrap(VoiceDiagnosticsRecorder.shared.read())
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
        VoiceDiagnosticsRecorder.shared.record("segment.ingested",
            segment: SpeechSegment(segmentID: "live-0", text: "text with \"quotes\" and \nnewline", finality: .final))
        settle()

        let trace = try XCTUnwrap(VoiceDiagnosticsRecorder.shared.read())
        // Awkward content must not break the line format the file depends on.
        XCTAssertEqual(trace.split(separator: "\n").count, 1)
        XCTAssertNoThrow(
            try JSONDecoder().decode(
                VoiceDiagnosticsRecorder.Event.self,
                from: Data(trace.split(separator: "\n")[0].utf8)
            )
        )
    }

    func testClearRemovesTheTrace() {
        VoicePreferences.isVoiceTracingEnabled = true
        VoiceDiagnosticsRecorder.shared.record("session.begin")
        settle()
        XCTAssertNotNil(VoiceDiagnosticsRecorder.shared.read())

        VoiceDiagnosticsRecorder.shared.clear()
        XCTAssertNil(VoiceDiagnosticsRecorder.shared.read())
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
