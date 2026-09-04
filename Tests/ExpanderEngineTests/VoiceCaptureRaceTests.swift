import XCTest
import AVFoundation
import Foundation
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
        private(set) var isCapturing = false

        /// Runs inside `startCapture`, standing in for the window during which a real session
        /// can be superseded while the audio engine is spinning up. Synchronous because the
        /// protocol's `startCapture` is `throws`, not `async` — and retiring a generation is a
        /// lock-guarded synchronous call anyway, so this is the real shape of the interference.
        var duringStart: (@Sendable () -> Void)?
        /// Thrown from `startCapture` when set.
        var startError: (any Error)?
        /// Thrown from `stopCapture` when set; otherwise a stub artifact is returned.
        var stopError: (any Error)?
        /// Suspends finalization so watchdog-arm and terminal-cleanup ordering is deterministic.
        var duringStop: (@Sendable () async -> Void)?

        func setDuringStart(_ handler: (@Sendable () -> Void)?) { duringStart = handler }
        func setStartError(_ error: (any Error)?) { startError = error }
        func setStopError(_ error: (any Error)?) { stopError = error }
        func setDuringStop(_ handler: (@Sendable () async -> Void)?) { duringStop = handler }

        func setOnPCMBuffer(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {}
        func setOnAudioLevelUpdate(_ handler: (@Sendable (Float) -> Void)?) {}

        func startCapture(sessionDirectory: URL) throws {
            startCount += 1
            // The coordinator is suspended on this actor hop right now; retiring the generation
            // here is precisely the window the second guard exists to close.
            duringStart?()
            if let startError { throw startError }
            isCapturing = true
        }

        func stopCapture() async throws -> AudioArtifact {
            stopCount += 1
            await duringStop?()
            if let stopError { throw stopError }
            isCapturing = false
            return AudioArtifact(
                fileURL: URL(fileURLWithPath: "/dev/null"),
                frameCount: 16_000,
                durationSeconds: 1
            )
        }

        func cancelCapture() {
            cancelCount += 1
            isCapturing = false
        }
    }

    /// Synchronous, lock-guarded observation for the coordinator's `@Sendable` callback.
    /// Capturing a mutable local array here compiles with the newer local toolchain but is
    /// rejected by the macOS 14/Xcode 15 release runner's concurrency diagnostics.
    private final class PhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [SessionPhase] = []

        func append(_ phase: SessionPhase) {
            lock.lock()
            phases.append(phase)
            lock.unlock()
        }

        func containsFailure() -> Bool {
            lock.lock()
            let snapshot = phases
            lock.unlock()
            return snapshot.contains {
                String(describing: $0).lowercased().contains("fail")
            }
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        func read() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func markIfUnset() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !value else { return false }
            value = true
            return true
        }
    }

    private actor SuspensionGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: - Fixtures

    private func makeSnapshot(
        generation: SessionGeneration = SessionGeneration(rawValue: 1)
    ) -> VoiceSessionSnapshot {
        VoiceSessionSnapshot(
            generation: generation,
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

    func testAlreadyCancelledStartNeverCreatesACaptureSession() async {
        let spy = CaptureSpy()
        let coordinator = makeCoordinator(spy)
        let gate = SuspensionGate()
        let entered = expectation(description: "start task reached gate")
        let start = Task {
            entered.fulfill()
            await gate.wait()
            try await coordinator.startSession(
                snapshot: makeSnapshot(),
                mode: .handsFree,
                enableLiveRecognition: false
            )
        }
        await fulfillment(of: [entered], timeout: 1)

        start.cancel()
        await gate.open()

        do {
            try await start.value
            XCTFail("A cancelled controller start must not create a coordinator session.")
        } catch is CancellationError {
            // Expected cooperative cancellation.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let startCount = await spy.startCount
        XCTAssertEqual(startCount, 0)
    }

    /// Actor methods are reentrant at MainActor hops. A second caller may therefore be admitted
    /// after the first caller begins its insertion lease but before it installs `activeState`.
    /// The older continuation must fail as superseded, leave the newer bag/lease alone, and never
    /// overwrite the newer session state.
    func testConcurrentStartCannotResumePastNewerAdmissionAndInstallStaleState() async throws {
        let spy = CaptureSpy()
        let olderStartGate = SuspensionGate()
        let olderStartPaused = LockedFlag()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceConcurrentStartAdmission_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = VoiceSessionCoordinator(
            capture: spy,
            store: VoiceSessionStore(baseDirectory: directory),
            startStatePreparation: { generation in
                guard generation == SessionGeneration(rawValue: 1) else { return }
                olderStartPaused.set()
                await olderStartGate.wait()
            }
        )

        let olderStart = Task {
            try await coordinator.startSession(
                snapshot: self.makeSnapshot(generation: SessionGeneration(rawValue: 1)),
                mode: .handsFree,
                enableLiveRecognition: false
            )
        }
        let pauseDeadline = Date().addingTimeInterval(1)
        while !olderStartPaused.read(), Date() < pauseDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(olderStartPaused.read(), "The older start never reached the admission gate.")

        try await coordinator.startSession(
            snapshot: makeSnapshot(generation: SessionGeneration(rawValue: 2)),
            mode: .handsFree,
            enableLiveRecognition: false
        )
        await olderStartGate.open()

        do {
            try await olderStart.value
            XCTFail("The superseded start returned success after a newer session became active.")
        } catch is CancellationError {
            // Expected: ownership moved to the newer admission while this caller was suspended.
        } catch {
            XCTFail("Expected CancellationError for the superseded start, got \(error)")
        }

        let startCount = await spy.startCount
        let newerCaptureIsActive = await spy.isCapturing
        XCTAssertEqual(startCount, 1, "The stale start reached the microphone.")
        XCTAssertTrue(newerCaptureIsActive, "The stale start tore down the newer capture.")
        let cancelAccepted = await coordinator.cancelSession()
        XCTAssertTrue(cancelAccepted, "The stale start replaced the newer active session state.")
    }

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

        let reportedPhases = PhaseRecorder()
        await coordinator.setOnPhaseChange { phase in reportedPhases.append(phase) }

        await coordinator.performStartAudioCapture(
            sessionDir: scratchDirectory, snapshot: snapshot, generation: snapshot.generation
        )

        let cancels = await spy.cancelCount
        XCTAssertGreaterThan(cancels, 0, "a cancelled start must still release the device")
        XCTAssertFalse(
            reportedPhases.containsFailure(),
            "cancellation is a cooperative stop, not a failure to surface"
        )
    }

    /// A genuine device error must still be reported — the cancellation branch must not have
    /// swallowed the failure path it was carved out of.
    func testARealStartFailureIsReportedAsNoMicrophone() async throws {
        struct DeviceDown: Error {}
        let spy = CaptureSpy()
        await spy.setStartError(DeviceDown())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceRealStartFailure_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = VoiceSessionCoordinator(
            capture: spy,
            store: VoiceSessionStore(baseDirectory: directory)
        )
        let reportedPhases = PhaseRecorder()
        await coordinator.setOnPhaseChange { phase in reportedPhases.append(phase) }

        do {
            try await coordinator.startSession(
                snapshot: makeSnapshot(),
                mode: .handsFree,
                enableLiveRecognition: false
            )
            XCTFail("A real capture-device failure returned success.")
        } catch let failure as VoiceFailure {
            XCTAssertEqual(failure.stage, .audioCapture)
            XCTAssertEqual(failure.code, .noMicrophone)
        } catch {
            XCTFail("Expected VoiceFailure, got \(error)")
        }

        let starts = await spy.startCount
        XCTAssertEqual(starts, 1, "A real failure means the device was actually attempted.")
        XCTAssertTrue(reportedPhases.containsFailure(), "The failure was not published to observers.")
    }

    /// `startSession` schedules microphone setup. Stop must not report completion and launch
    /// finalization until that setup has resolved; otherwise `stopCapture` can run first and a
    /// delayed `startCapture` can turn the microphone on after the user pressed Stop.
    func testStopWaitsForInFlightCaptureSetup() async throws {
        let spy = CaptureSpy()
        let enteredStart = expectation(description: "capture start entered")
        let releaseStart = DispatchSemaphore(value: 0)
        await spy.setDuringStart {
            enteredStart.fulfill()
            releaseStart.wait()
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceStopStartRace_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let isolatedCoordinator = VoiceSessionCoordinator(
            capture: spy,
            store: VoiceSessionStore(baseDirectory: directory)
        )

        let start = Task {
            try? await isolatedCoordinator.startSession(
                snapshot: makeSnapshot(),
                mode: .handsFree,
                enableLiveRecognition: false
            )
        }
        await fulfillment(of: [enteredStart], timeout: 1)

        let stopReturned = LockedFlag()
        let stop = Task {
            await isolatedCoordinator.stopSession()
            stopReturned.set()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(
            stopReturned.read(),
            "Stop returned while capture setup was still blocked."
        )

        releaseStart.signal()
        await start.value
        await stop.value
        XCTAssertTrue(stopReturned.read())
    }

    func testCaptureDurationLimitFinalizesInsteadOfGrowingTheRecordingForever() async throws {
        let spy = CaptureSpy()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCaptureLimit_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = VoiceSessionCoordinator(
            capture: spy,
            store: VoiceSessionStore(baseDirectory: directory),
            maximumCaptureSeconds: 1
        )

        try await coordinator.startSession(
            snapshot: makeSnapshot(),
            mode: .handsFree,
            enableLiveRecognition: false
        )

        let deadline = Date().addingTimeInterval(2)
        while await spy.stopCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let stops = await spy.stopCount
        XCTAssertEqual(
            stops,
            1,
            "The finite capture budget must close and finalize the audio artifact."
        )
        _ = await coordinator.cancelSession()
    }

    /// A terminal cleanup is scheduled because reducer command execution is synchronous. A new
    /// generation must join that teardown; otherwise the old cancel can arrive after the new start
    /// and switch the microphone back off.
    func testNewGenerationWaitsForScheduledCaptureCleanup() async throws {
        struct DeviceDown: Error {}
        let spy = CaptureSpy()
        let cleanupGate = SuspensionGate()
        let cleanupEntered = expectation(description: "terminal capture cleanup scheduled")
        let reportedCleanup = LockedFlag()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCleanupStartRace_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = VoiceSessionCoordinator(
            capture: spy,
            store: VoiceSessionStore(baseDirectory: directory),
            captureCleanupPreparation: {
                if reportedCleanup.markIfUnset() {
                    cleanupEntered.fulfill()
                }
                await cleanupGate.wait()
            }
        )

        await spy.setStartError(DeviceDown())
        do {
            try await coordinator.startSession(
                snapshot: makeSnapshot(generation: SessionGeneration(rawValue: 1)),
                mode: .handsFree,
                enableLiveRecognition: false
            )
            XCTFail("The first capture should fail and schedule terminal cleanup.")
        } catch {
            // Expected device failure.
        }
        await fulfillment(of: [cleanupEntered], timeout: 1)

        await spy.setStartError(nil)
        let secondStart = Task {
            try await coordinator.startSession(
                snapshot: self.makeSnapshot(generation: SessionGeneration(rawValue: 2)),
                mode: .handsFree,
                enableLiveRecognition: false
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let startsWhileCleanupBlocked = await spy.startCount
        XCTAssertEqual(
            startsWhileCleanupBlocked,
            1,
            "A new microphone start overtook the prior generation's scheduled cleanup."
        )

        await cleanupGate.open()
        try await secondStart.value
        let finalStartCount = await spy.startCount
        let finalCaptureState = await spy.isCapturing
        XCTAssertEqual(finalStartCount, 2)
        XCTAssertTrue(finalCaptureState)
        _ = await coordinator.cancelSession()
    }

    /// Supersession creates its cleanup *inside* `startSession`, after the method's entry barrier.
    /// Joining only a cleanup that already existed on entry lets this newly-scheduled cancel land
    /// after the replacement generation opens the microphone.
    func testSupersessionWaitsForCleanupItSchedulesBeforeOpeningReplacementCapture() async throws {
        let spy = CaptureSpy()
        let cleanupGate = SuspensionGate()
        let cleanupEntered = expectation(description: "supersession cleanup scheduled")
        let reportedCleanup = LockedFlag()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceSupersessionCleanupRace_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = VoiceSessionCoordinator(
            capture: spy,
            store: VoiceSessionStore(baseDirectory: directory),
            captureCleanupPreparation: {
                if reportedCleanup.markIfUnset() {
                    cleanupEntered.fulfill()
                }
                await cleanupGate.wait()
            }
        )

        try await coordinator.startSession(
            snapshot: makeSnapshot(generation: SessionGeneration(rawValue: 1)),
            mode: .handsFree,
            enableLiveRecognition: false
        )

        let replacementStart = Task {
            try await coordinator.startSession(
                snapshot: self.makeSnapshot(generation: SessionGeneration(rawValue: 2)),
                mode: .handsFree,
                enableLiveRecognition: false
            )
        }
        await fulfillment(of: [cleanupEntered], timeout: 1)
        try await Task.sleep(nanoseconds: 100_000_000)

        let startsWhileSupersessionCleanupBlocked = await spy.startCount
        XCTAssertEqual(
            startsWhileSupersessionCleanupBlocked,
            1,
            "The replacement capture opened before its superseded generation finished teardown."
        )

        await cleanupGate.open()
        try await replacementStart.value

        let finalStartCount = await spy.startCount
        let replacementIsCapturing = await spy.isCapturing
        XCTAssertEqual(finalStartCount, 2)
        XCTAssertTrue(replacementIsCapturing)
        _ = await coordinator.cancelSession()
    }

    /// The arm command is asynchronous because the watchdog is a separate actor. Terminal cleanup
    /// can retire the session while that actor hop is delayed; the late arm must observe retirement
    /// and leave no deadline behind for the dead generation.
    func testTerminalCleanupBeforeDelayedPostCaptureWatchdogArmLeavesItDisarmed() async throws {
        let spy = CaptureSpy()
        let finalizeGate = SuspensionGate()
        let watchdogArmGate = SuspensionGate()
        let finalizeEntered = expectation(description: "audio finalization suspended")
        let watchdogArmEntered = expectation(description: "post-capture watchdog arm suspended")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceDelayedWatchdogArmRace_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        await spy.setDuringStop {
            finalizeEntered.fulfill()
            await finalizeGate.wait()
        }
        let coordinator = VoiceSessionCoordinator(
            capture: spy,
            store: VoiceSessionStore(baseDirectory: directory),
            postCaptureWatchdogArmPreparation: {
                watchdogArmEntered.fulfill()
                await watchdogArmGate.wait()
            }
        )

        try await coordinator.startSession(
            snapshot: makeSnapshot(generation: SessionGeneration(rawValue: 1)),
            mode: .handsFree,
            enableLiveRecognition: false
        )
        let stopAccepted = await coordinator.stopSession()
        XCTAssertTrue(stopAccepted)
        await fulfillment(of: [finalizeEntered, watchdogArmEntered], timeout: 1)

        let cancelAccepted = await coordinator.cancelSession()
        XCTAssertTrue(cancelAccepted, "Terminal cleanup did not retire the finalizing generation.")
        await watchdogArmGate.open()

        let watchdogIsArmed = await coordinator
            .postCaptureWatchdogIsArmedAfterPendingArmForTesting()
        XCTAssertFalse(
            watchdogIsArmed,
            "A delayed post-capture arm survived after its generation was cleaned up."
        )
        await finalizeGate.open()
    }

    /// Capture startup also crosses to a separate watchdog actor. Cancelling the session while
    /// that arm is delayed must not let the stale continuation install a recording deadline after
    /// terminal cleanup has already retired the generation.
    func testTerminalCleanupBeforeDelayedCaptureWatchdogArmLeavesItDisarmed() async throws {
        let spy = CaptureSpy()
        let watchdogArmGate = SuspensionGate()
        let watchdogArmEntered = expectation(description: "capture watchdog arm suspended")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceDelayedCaptureWatchdogArm_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = VoiceSessionCoordinator(
            capture: spy,
            store: VoiceSessionStore(baseDirectory: directory),
            captureWatchdogArmPreparation: {
                watchdogArmEntered.fulfill()
                await watchdogArmGate.wait()
            }
        )

        let start = Task {
            try await coordinator.startSession(
                snapshot: self.makeSnapshot(generation: SessionGeneration(rawValue: 1)),
                mode: .handsFree,
                enableLiveRecognition: false
            )
        }
        await fulfillment(of: [watchdogArmEntered], timeout: 1)

        let cancelAccepted = await coordinator.cancelSession()
        XCTAssertTrue(cancelAccepted, "Terminal cleanup did not retire the capturing generation.")
        await watchdogArmGate.open()
        do {
            try await start.value
            XCTFail("The start returned success after terminal cleanup retired its generation.")
        } catch is CancellationError {
            // Expected: the post-capture-start ownership check observes terminal retirement.
        } catch {
            XCTFail("Expected CancellationError for the retired start, got \(error)")
        }

        let watchdogIsArmed = await coordinator.captureWatchdogIsArmedForTesting()
        XCTAssertFalse(
            watchdogIsArmed,
            "A delayed capture watchdog arm survived after its generation was cleaned up."
        )
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

        let reportedPhases = PhaseRecorder()
        await coordinator.setOnPhaseChange { phase in reportedPhases.append(phase) }

        await coordinator.performFinalizeAudioCapture(generation: snapshot.generation)

        XCTAssertFalse(
            reportedPhases.containsFailure(),
            "a cancelled finalize must not surface a failure"
        )
    }
}
