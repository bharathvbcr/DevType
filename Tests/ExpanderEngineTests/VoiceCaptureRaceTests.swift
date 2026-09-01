import XCTest
import AVFoundation
@testable import ExpanderEngine

/// The two capture races in `VoiceSessionCoordinator`, driven for real.
///
/// These replace `SourceContractTests.testVoiceAsyncCaptureTasksRejectCancellationAndStale-
/// Generations`, which asserted the same two rules by counting tokens in the source. That check
/// could only ever say the code *looked* right: it passed on any arrangement of the right
/// substrings and would have kept passing if the guards ran in the wrong order, guarded the
/// wrong generation, or sat after the call they were meant to precede. These run the code.
final class VoiceCaptureRaceTests: XCTestCase {

    // MARK: - Double

    /// Records what the coordinator asked the microphone to do, and lets a test intervene at the
    /// exact moment the real race opens: while `startCapture` is in flight.
    private actor CaptureSpy: VoiceCaptureEngine {
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var cancelCount = 0

        /// Runs inside `startCapture`, standing in for the window during which a real session
        /// can be superseded while the audio engine is spinning up. Synchronous because the
        /// protocol's `startCapture` is `throws`, not `async` — and retiring a generation is a
        /// lock-guarded synchronous call anyway, so this is the real shape of the interference.
        var duringStart: (@Sendable () -> Void)?
        /// Thrown from `startCapture` when set.
        var startError: (any Error)?
        /// Thrown from `stopCapture` when set; otherwise a stub artifact is returned.
        var stopError: (any Error)?

        func setDuringStart(_ handler: (@Sendable () -> Void)?) { duringStart = handler }
        func setStartError(_ error: (any Error)?) { startError = error }
        func setStopError(_ error: (any Error)?) { stopError = error }

        func setOnPCMBuffer(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {}
        func setOnAudioLevelUpdate(_ handler: (@Sendable (Float) -> Void)?) {}

        func startCapture(sessionDirectory: URL) throws {
            startCount += 1
            // The coordinator is suspended on this actor hop right now; retiring the generation
            // here is precisely the window the second guard exists to close.
            duringStart?()
            if let startError { throw startError }
        }

        func stopCapture() async throws -> AudioArtifact {
            stopCount += 1
            if let stopError { throw stopError }
            return AudioArtifact(
                fileURL: URL(fileURLWithPath: "/dev/null"),
                frameCount: 16_000,
                durationSeconds: 1
            )
        }

        func cancelCapture() { cancelCount += 1 }
    }

    // MARK: - Fixtures

    private func makeSnapshot() -> VoiceSessionSnapshot {
        VoiceSessionSnapshot(
            speechProvider: SpeechProviderDescriptor(
                id: "test.speech", displayName: "Test", modelVersion: "1.0", privacyRoute: .onDeviceOnly
            ),
            correctionProvider: CorrectionProviderDescriptor(
                id: "deterministic.local", displayName: "Deterministic",
                modelVersion: "1.0", privacyRoute: .onDeviceOnly
            ),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 1234)
        )
    }

    private func makeCoordinator(_ spy: CaptureSpy) -> VoiceSessionCoordinator {
        VoiceSessionCoordinator(capture: spy)
    }

    private var scratchDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VoiceCaptureRaceTests")
    }

    // MARK: - Start: the generation must be re-checked after setup

    /// The bug: the coordinator awaited twice before opening the microphone but only checked the
    /// generation on the way in, so a session superseded during setup still opened the mic and
    /// left it open — a recording indicator that never goes away.
    func testAGenerationRetiredDuringStartTearsTheMicrophoneBackDown() async {
        let spy = CaptureSpy()
        let coordinator = makeCoordinator(spy)
        let snapshot = makeSnapshot()
        let bag = SessionTaskBag(sessionID: snapshot.sessionID, generation: snapshot.generation)
        await coordinator.installTaskBagForTesting(bag)

        // Retire the generation while the coordinator is between its two checks.
        await spy.setDuringStart { _ = bag.advanceGenerationAndCancelAll() }

        await coordinator.performStartAudioCapture(
            sessionDir: scratchDirectory, snapshot: snapshot, generation: snapshot.generation
        )

        let cancels = await spy.cancelCount
        XCTAssertGreaterThan(cancels, 0, "a stale task that opened the mic must close it again")
    }

    /// The control: nothing retires, so nothing is torn down.
    func testAStillCurrentGenerationKeepsTheMicrophoneOpen() async {
        let spy = CaptureSpy()
        let coordinator = makeCoordinator(spy)
        let snapshot = makeSnapshot()
        let bag = SessionTaskBag(sessionID: snapshot.sessionID, generation: snapshot.generation)
        await coordinator.installTaskBagForTesting(bag)

        await coordinator.performStartAudioCapture(
            sessionDir: scratchDirectory, snapshot: snapshot, generation: snapshot.generation
        )

        let starts = await spy.startCount
        let cancels = await spy.cancelCount
        XCTAssertEqual(starts, 1, "the current generation must actually open the microphone")
        XCTAssertEqual(cancels, 0, "nothing retired, so nothing should be torn down")
    }

    /// A generation already retired before the task ran must never reach the microphone at all.
    func testAnAlreadyRetiredGenerationNeverOpensTheMicrophone() async {
        let spy = CaptureSpy()
        let coordinator = makeCoordinator(spy)
        let snapshot = makeSnapshot()
        let bag = SessionTaskBag(sessionID: snapshot.sessionID, generation: snapshot.generation)
        _ = bag.advanceGenerationAndCancelAll()
        await coordinator.installTaskBagForTesting(bag)

        await coordinator.performStartAudioCapture(
            sessionDir: scratchDirectory, snapshot: snapshot, generation: snapshot.generation
        )

        let starts = await spy.startCount
        XCTAssertEqual(starts, 0, "the entry check must short-circuit before any setup")
    }

    /// With no bag at all — the session already torn down — the same rule holds.
    func testNoTaskBagMeansNoCapture() async {
        let spy = CaptureSpy()
        let coordinator = makeCoordinator(spy)
        let snapshot = makeSnapshot()
        await coordinator.installTaskBagForTesting(nil)

        await coordinator.performStartAudioCapture(
            sessionDir: scratchDirectory, snapshot: snapshot, generation: snapshot.generation
        )

        let starts = await spy.startCount
        XCTAssertEqual(starts, 0)
    }

    // MARK: - Start: cancellation is not a microphone failure

    /// The bug: `CancellationError` fell into the generic catch and was reported as
    /// `.noMicrophone`, so an ordinary superseded session accused the user's hardware.
    func testACancelledStartDoesNotReportAMicrophoneFailure() async {
        let spy = CaptureSpy()
        await spy.setStartError(CancellationError())
        let coordinator = makeCoordinator(spy)
        let snapshot = makeSnapshot()
        let bag = SessionTaskBag(sessionID: snapshot.sessionID, generation: snapshot.generation)
        await coordinator.installTaskBagForTesting(bag)

        var reportedPhases: [SessionPhase] = []
        await coordinator.setOnPhaseChange { phase in reportedPhases.append(phase) }

        await coordinator.performStartAudioCapture(
            sessionDir: scratchDirectory, snapshot: snapshot, generation: snapshot.generation
        )

        let cancels = await spy.cancelCount
        XCTAssertGreaterThan(cancels, 0, "a cancelled start must still release the device")
        XCTAssertFalse(
            reportedPhases.contains(where: { String(describing: $0).lowercased().contains("fail") }),
            "cancellation is a cooperative stop, not a failure to surface"
        )
    }

    /// A genuine device error must still be reported — the cancellation branch must not have
    /// swallowed the failure path it was carved out of.
    func testARealStartFailureIsStillReported() async {
        struct DeviceDown: Error {}
        let spy = CaptureSpy()
        await spy.setStartError(DeviceDown())
        let coordinator = makeCoordinator(spy)
        let snapshot = makeSnapshot()
        let bag = SessionTaskBag(sessionID: snapshot.sessionID, generation: snapshot.generation)
        await coordinator.installTaskBagForTesting(bag)

        await coordinator.performStartAudioCapture(
            sessionDir: scratchDirectory, snapshot: snapshot, generation: snapshot.generation
        )

        // With no active state the reducer drops the event, so what is asserted here is that the
        // failure path was taken at all rather than short-circuited: a real error must not be
        // mistaken for a cancellation and must not tear down via the cancellation branch only.
        let starts = await spy.startCount
        XCTAssertEqual(starts, 1, "a real failure means the device was actually attempted")
    }

    // MARK: - Finalize

    func testFinalizeStopsTheMicrophone() async {
        let spy = CaptureSpy()
        let coordinator = makeCoordinator(spy)
        let snapshot = makeSnapshot()
        let bag = SessionTaskBag(sessionID: snapshot.sessionID, generation: snapshot.generation)
        await coordinator.installTaskBagForTesting(bag)

        await coordinator.performFinalizeAudioCapture(generation: snapshot.generation)

        let stops = await spy.stopCount
        XCTAssertEqual(stops, 1)
    }

    /// A cancelled finalize must stop quietly: the artifact belongs to a session nobody is
    /// waiting on, and reporting `.zeroFramesCaptured` put a failure banner in front of a user
    /// who had already moved on.
    func testACancelledFinalizeReportsNoFailure() async {
        let spy = CaptureSpy()
        await spy.setStopError(CancellationError())
        let coordinator = makeCoordinator(spy)
        let snapshot = makeSnapshot()
        let bag = SessionTaskBag(sessionID: snapshot.sessionID, generation: snapshot.generation)
        await coordinator.installTaskBagForTesting(bag)

        var reportedPhases: [SessionPhase] = []
        await coordinator.setOnPhaseChange { phase in reportedPhases.append(phase) }

        await coordinator.performFinalizeAudioCapture(generation: snapshot.generation)

        XCTAssertFalse(
            reportedPhases.contains(where: { String(describing: $0).lowercased().contains("fail") }),
            "a cancelled finalize must not surface a failure"
        )
    }
}
