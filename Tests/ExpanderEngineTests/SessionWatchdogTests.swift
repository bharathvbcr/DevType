import XCTest
@testable import ExpanderEngine

/// The watchdog is the only thing that returns a stalled dictation to idle, so its
/// arm / disarm / fire behaviour is worth testing directly rather than inferring it from a
/// session that happens to finish.
///
/// **Coverage note.** `SessionWatchdog` defends the same contract twice: it cancels the
/// pending task, *and* it checks the generation before firing. Either alone is sufficient,
/// so removing just one is invisible to these tests — mutation-testing each mechanism in
/// isolation shows as "not caught". Removing both together is caught by four of these
/// cases. What is asserted here is therefore the contract — at most one deadline survives,
/// it carries the current generation, and a disarmed watchdog never fires — not the
/// individual mechanisms. That is deliberate: the redundancy is the point, and a test that
/// pinned one mechanism would break the moment the other was relied on instead.
final class SessionWatchdogTests: XCTestCase {

    /// Records expiries from the watchdog's detached task.
    private final class Recorder: @unchecked Sendable {
        private let lock = UnfairLock()
        private var fired: [SessionGeneration] = []

        func record(_ generation: SessionGeneration) {
            lock.withLock { fired.append(generation) }
        }
        var all: [SessionGeneration] { lock.withLock { fired } }
        var count: Int { lock.withLock { fired.count } }
    }

    private actor SuspensionGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var hasEntered = false

        func wait() async {
            hasEntered = true
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func generation(_ value: UInt64) -> SessionGeneration {
        SessionGeneration(rawValue: value)
    }

    func testMalformedDurationsAreClampedBeforeNanosecondConversion() {
        XCTAssertEqual(
            SessionWatchdog.normalizedSeconds(.nan),
            SessionWatchdog.minimumSeconds
        )
        XCTAssertEqual(
            SessionWatchdog.normalizedSeconds(-Double.infinity),
            SessionWatchdog.minimumSeconds
        )
        XCTAssertEqual(
            SessionWatchdog.normalizedSeconds(Double.infinity),
            SessionWatchdog.maximumSeconds
        )
        XCTAssertEqual(
            SessionWatchdog.normalizedSeconds(0),
            SessionWatchdog.minimumSeconds
        )
    }

    func testSnapshotClampsUntrustedTimeoutBeforeDeadlineConstructionAndPersistence() {
        let snapshot = VoiceSessionSnapshot(
            speechProvider: SpeechProviderDescriptor(
                id: "test.speech",
                displayName: "Test Speech",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly
            ),
            correctionProvider: CorrectionProviderDescriptor(
                id: "test.correction",
                displayName: "Test Correction",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly
            ),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(
                bundleIdentifier: "com.example.target",
                processIdentifier: 42
            ),
            timeoutSeconds: .infinity
        )

        XCTAssertEqual(snapshot.timeoutSeconds, SessionWatchdog.maximumSeconds)
        XCTAssertTrue(
            Date().addingTimeInterval(snapshot.timeoutSeconds).timeIntervalSinceReferenceDate.isFinite
        )
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testSnapshotDecoderClampsNonconformingStoredTimeouts() throws {
        let snapshot = VoiceSessionSnapshot(
            speechProvider: SpeechProviderDescriptor(
                id: "test.speech",
                displayName: "Test Speech",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly
            ),
            correctionProvider: CorrectionProviderDescriptor(
                id: "test.correction",
                displayName: "Test Correction",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly
            ),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(
                bundleIdentifier: "com.example.target",
                processIdentifier: 42
            )
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let baselineObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        func decode(timeout: String) throws -> VoiceSessionSnapshot {
            var object = baselineObject
            object["timeoutSeconds"] = timeout
            let data = try JSONSerialization.data(withJSONObject: object)
            return try decoder.decode(VoiceSessionSnapshot.self, from: data)
        }

        XCTAssertEqual(
            try decode(timeout: "Infinity").timeoutSeconds,
            SessionWatchdog.maximumSeconds
        )
        XCTAssertEqual(
            try decode(timeout: "NaN").timeoutSeconds,
            SessionWatchdog.minimumSeconds
        )
        XCTAssertEqual(
            try decode(timeout: "-Infinity").timeoutSeconds,
            SessionWatchdog.minimumSeconds
        )
    }

    /// Exercises the actual conversion in `arm`, not only the normalization helper. The old
    /// UInt64-max-derived Double rounded back above UInt64.max and trapped in the task body.
    func testPositiveInfinityCanBeArmedAndDisarmedWithoutTrapping() async {
        let watchdog = SessionWatchdog()
        await watchdog.arm(seconds: .infinity, generation: generation(1)) { _ in }

        let armedBeforeDisarm = await watchdog.isArmed
        let pendingBeforeDisarm = await watchdog.pendingGeneration
        let didDisarm = await watchdog.disarm(ifArmedFor: generation(1))
        let armedAfterDisarm = await watchdog.isArmed
        XCTAssertTrue(armedBeforeDisarm)
        XCTAssertEqual(pendingBeforeDisarm, generation(1))
        XCTAssertTrue(didDisarm)
        XCTAssertFalse(armedAfterDisarm)
    }

    // MARK: - Firing

    func testFiresAfterTheDeadline() async throws {
        let watchdog = SessionWatchdog()
        let recorder = Recorder()

        // The floor is 1s, so anything shorter still waits a second.
        await watchdog.arm(seconds: 0, generation: generation(1)) { expired in
            recorder.record(expired)
        }
        let armed = await watchdog.isArmed
        XCTAssertTrue(armed)

        try await Task.sleep(nanoseconds: 1_400_000_000)

        XCTAssertEqual(recorder.count, 1, "Watchdog did not fire")
        XCTAssertEqual(recorder.all.first, generation(1))

        let stillArmed = await watchdog.isArmed
        XCTAssertFalse(stillArmed, "Watchdog stayed armed after firing")
    }

    func testDoesNotFireBeforeTheDeadline() async throws {
        let watchdog = SessionWatchdog()
        let recorder = Recorder()

        await watchdog.arm(seconds: 30, generation: generation(1)) { recorder.record($0) }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(recorder.count, 0, "Watchdog fired early")
        await watchdog.disarm()
    }

    // MARK: - Disarming

    /// The normal path: the session finishes, the watchdog is disarmed, nothing fires.
    func testDisarmPreventsFiring() async throws {
        let watchdog = SessionWatchdog()
        let recorder = Recorder()

        await watchdog.arm(seconds: 0, generation: generation(1)) { recorder.record($0) }
        await watchdog.disarm()

        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(recorder.count, 0, "A disarmed watchdog fired anyway")
    }

    func testDisarmWhenNotArmedIsSafe() async {
        let watchdog = SessionWatchdog()
        await watchdog.disarm()
        await watchdog.disarm()
        let armed = await watchdog.isArmed
        XCTAssertFalse(armed)
    }

    /// A cleanup task from generation one can reach the watchdog after generation two was armed.
    /// It must not clear the newer deadline.
    func testStaleGenerationDisarmCannotCancelNewerDeadline() async {
        let watchdog = SessionWatchdog()
        await watchdog.arm(seconds: 30, generation: generation(2)) { _ in }

        let staleDisarmed = await watchdog.disarm(ifArmedFor: generation(1))
        let stillArmed = await watchdog.isArmed
        let pending = await watchdog.pendingGeneration
        XCTAssertFalse(staleDisarmed)
        XCTAssertTrue(stillArmed)
        XCTAssertEqual(pending, generation(2))

        let currentDisarmed = await watchdog.disarm(ifArmedFor: generation(2))
        let armedAfterCurrentDisarm = await watchdog.isArmed
        XCTAssertTrue(currentDisarmed)
        XCTAssertFalse(armedAfterCurrentDisarm)
    }

    func testRepeatedDisarmAfterFiringIsSafe() async throws {
        let watchdog = SessionWatchdog()
        let recorder = Recorder()

        await watchdog.arm(seconds: 0, generation: generation(1)) { recorder.record($0) }
        try await Task.sleep(nanoseconds: 1_400_000_000)
        await watchdog.disarm()
        await watchdog.disarm()

        XCTAssertEqual(recorder.count, 1)
    }

    // MARK: - Re-arming

    /// Starting a new dictation while one is pending must replace the deadline, not add a
    /// second one that would later fail the new session.
    func testRearmingReplacesThePendingDeadline() async throws {
        let watchdog = SessionWatchdog()
        let recorder = Recorder()

        await watchdog.arm(seconds: 0, generation: generation(1)) { recorder.record($0) }
        await watchdog.arm(seconds: 0, generation: generation(2)) { recorder.record($0) }

        let pending = await watchdog.pendingGeneration
        XCTAssertEqual(pending, generation(2))

        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(recorder.count, 1, "Both deadlines fired; the first was not replaced")
        XCTAssertEqual(recorder.all.first, generation(2),
            "The superseded generation fired instead of the current one")
    }

    /// Cancellation alone cannot close the tiny race after the old task checks cancellation but
    /// before its actor-isolated `fire` runs. Re-arming the same generation in that window must
    /// retain the replacement deadline and suppress the old expiry closure.
    func testSameGenerationRearmRejectsOldFireJobAfterCancellationCheck() async throws {
        let gate = SuspensionGate()
        let watchdog = SessionWatchdog(expiryPreparation: { _ in await gate.wait() })
        let recorder = Recorder()
        let sessionGeneration = generation(7)

        await watchdog.arm(seconds: 0, generation: sessionGeneration) {
            recorder.record($0)
        }

        let gateDeadline = Date().addingTimeInterval(2)
        while !(await gate.hasEntered), Date() < gateDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let oldFireReachedGate = await gate.hasEntered
        XCTAssertTrue(oldFireReachedGate, "The old deadline never reached the pre-fire race gate.")

        await watchdog.arm(seconds: 30, generation: sessionGeneration) {
            recorder.record($0)
        }
        await gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)

        let replacementIsArmed = await watchdog.isArmed
        let pendingGeneration = await watchdog.pendingGeneration
        XCTAssertEqual(recorder.count, 0, "The cancelled arm fired after its replacement was installed.")
        XCTAssertTrue(replacementIsArmed, "The old fire job cleared the replacement deadline.")
        XCTAssertEqual(pendingGeneration, sessionGeneration)
        await watchdog.disarm()
    }

    /// Many rapid re-arms — the hotkey debounce is 150ms, so this is reachable by a user
    /// mashing the shortcut. Exactly one deadline may survive.
    func testRapidRearmingLeavesExactlyOneDeadline() async throws {
        let watchdog = SessionWatchdog()
        let recorder = Recorder()

        for index in 1...50 {
            await watchdog.arm(seconds: 0, generation: generation(UInt64(index))) {
                recorder.record($0)
            }
        }

        try await Task.sleep(nanoseconds: 1_600_000_000)

        XCTAssertEqual(recorder.count, 1, "Expected one survivor, got \(recorder.count)")
        XCTAssertEqual(recorder.all.first, generation(50))
    }

    /// Concurrent arms and disarms must not deadlock or leave a deadline behind.
    func testConcurrentArmAndDisarmIsSafe() async throws {
        let watchdog = SessionWatchdog()
        let recorder = Recorder()

        await withTaskGroup(of: Void.self) { group in
            for index in 1...40 {
                group.addTask {
                    await watchdog.arm(seconds: 0, generation: self.generation(UInt64(index))) {
                        recorder.record($0)
                    }
                }
                group.addTask { await watchdog.disarm() }
            }
        }

        await watchdog.disarm()
        try await Task.sleep(nanoseconds: 1_400_000_000)

        XCTAssertEqual(recorder.count, 0, "A deadline survived the final disarm")
        let armed = await watchdog.isArmed
        XCTAssertFalse(armed)
    }

    // MARK: - Stage attribution

    /// A timeout should name the stage that stalled, so the diagnostic points at the
    /// component rather than reporting a generic failure.
    func testTimeoutStageNamesTheStalledComponent() {
        let expectations: [(SessionPhase, FailureStage)] = [
            (.preparing, .audioCapture),
            (.capturing(mode: .handsFree), .audioCapture),
            (.finalizingAudio, .audioFinalization),
            (.recognizing, .recognition),
            (.validatingRaw, .rawValidation),
            (.correcting, .correction),
            (.validatingCorrection, .correctionValidation),
            (.readyForDelivery, .delivery),
            (.delivering, .delivery),
        ]

        for (phase, expected) in expectations {
            XCTAssertEqual(
                VoiceSessionCoordinator.stage(for: phase), expected,
                "Timeout in \(phase) was attributed to the wrong stage"
            )
        }
    }
}
