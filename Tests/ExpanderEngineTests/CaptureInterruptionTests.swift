import AVFoundation
import CoreAudio
import Foundation
import XCTest
@testable import ExpanderEngine

/// The input going quiet under the user — a switched device, a tap that stops calling back, or
/// buffers the pool refuses — must be noticed while they are still speaking, not reported as
/// "no speech" after they stop. A device switch is absorbed when the new input can be opened.
final class CaptureInterruptionTests: XCTestCase {
    // MARK: - Latch

    func testLatchKeepsTheFirstReasonAndNotifiesOnce() {
        let seen = ReasonRecorder()
        let latch = CaptureInterruptionLatch(handler: { seen.append($0) })

        XCTAssertNil(latch.reason)
        XCTAssertTrue(latch.trip(.inputStalled))
        XCTAssertFalse(latch.trip(.deviceChanged))
        XCTAssertFalse(latch.trip(.inputStalled))

        XCTAssertEqual(latch.reason, .inputStalled)
        XCTAssertEqual(seen.values, [.inputStalled])
    }

    func testLatchWithoutAHandlerStillRecordsTheReason() {
        let latch = CaptureInterruptionLatch()
        XCTAssertTrue(latch.trip(.deviceChanged))
        XCTAssertEqual(latch.reason, .deviceChanged)
    }

    // MARK: - Configuration-change monitor

    func testConfigurationChangeOfThisEngineIsReported() {
        let center = NotificationCenter()
        let engine = AVAudioEngine()
        let changes = Counter()
        let monitor = EngineConfigurationMonitor(engine: engine, onChange: { changes.increment() }, center: center)
        defer { monitor.invalidate() }

        center.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine())
        XCTAssertEqual(changes.value, 0, "another engine's change must not reach this capture")

        // A stopped engine is what AVAudioEngine.h says posts this notification.
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(changes.value, 1)
    }

    func testInvalidatedMonitorIgnoresLaterChanges() {
        let center = NotificationCenter()
        let engine = AVAudioEngine()
        let changes = Counter()
        let monitor = EngineConfigurationMonitor(engine: engine, onChange: { changes.increment() }, center: center)
        monitor.invalidate()
        monitor.invalidate()

        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(changes.value, 0)
    }

    // MARK: - Stall watchdog

    func testDrainReportsATapThatNeverCallsBack() throws {
        let fixture = try DrainFixture(pool: AudioBufferPool(capacity: 8, maxChunkFrames: 64, bytesPerFrame: 4))
        defer { fixture.cleanUp() }
        let drain = fixture.makeDrain(inputStallSeconds: 0.3)
        drain.start()
        defer { _ = drain.stopAndJoin(timeout: 2) }

        XCTAssertTrue(fixture.waitForReason(within: 2), "a silent tap was never reported")
        XCTAssertEqual(fixture.latch.reason, .inputStalled)
    }

    /// The watchdog used to disarm after the first chunk, so an input that went quiet mid-session
    /// (no configuration change) left the user speaking into a recording that stopped growing.
    func testDrainReportsAnInputThatStopsAfterItStarted() throws {
        let pool = AudioBufferPool(capacity: 8, maxChunkFrames: 64, bytesPerFrame: 4)
        let fixture = try DrainFixture(pool: pool)
        defer { fixture.cleanUp() }
        XCTAssertTrue(pool.enqueue(buffer: try Self.monoBuffer(frames: 16), sampleTime: 0))
        let drain = fixture.makeDrain(inputStallSeconds: 0.3)
        drain.start()
        defer { _ = drain.stopAndJoin(timeout: 2) }

        XCTAssertTrue(fixture.waitForReason(within: 2), "an input that stopped after its first buffer was never reported")
        XCTAssertEqual(fixture.latch.reason, .inputStalled)
    }

    func testDrainDoesNotReportAStallWhileInputKeepsArriving() throws {
        let pool = AudioBufferPool(capacity: 64, maxChunkFrames: 64, bytesPerFrame: 4)
        let fixture = try DrainFixture(pool: pool)
        defer { fixture.cleanUp() }
        let drain = fixture.makeDrain(inputStallSeconds: 0.3)
        drain.start()

        let deadline = Date().addingTimeInterval(1.2)
        var index = 0
        while Date() < deadline {
            XCTAssertTrue(pool.enqueue(buffer: try Self.monoBuffer(frames: 16), sampleTime: Double(index)))
            index += 1
            Thread.sleep(forTimeInterval: 0.05)
        }
        let outcome = drain.stopAndJoin(timeout: 2)
        XCTAssertNil(outcome.captureError)
        XCTAssertNil(fixture.latch.reason, "steady input must never be called stalled")
    }

    func testDrainReportsRefusedBuffersWithoutWaitingForTheStallBound() throws {
        let pool = AudioBufferPool(capacity: 4, maxChunkFrames: 2, bytesPerFrame: 4)
        let fixture = try DrainFixture(pool: pool)
        defer { fixture.cleanUp() }
        XCTAssertFalse(pool.enqueue(buffer: try Self.monoBuffer(frames: 4800), sampleTime: 0))
        let drain = fixture.makeDrain(inputStallSeconds: 60)
        drain.start()
        defer { _ = drain.stopAndJoin(timeout: 2) }

        XCTAssertTrue(fixture.waitForReason(within: 2))
        XCTAssertEqual(fixture.latch.reason, .buffersRejected)
    }

    // MARK: - Classification of an empty recording

    func testEmptyRecordingNamesTheFaultInsteadOfNoSpeech() {
        func code(
            dropped: Int64 = 0,
            _ interruption: CaptureInterruption?,
            elapsed: TimeInterval = 0,
            device: Bool = true
        ) -> FailureCode {
            DurableVoiceCapture.emptyCaptureFailure(
                droppedFrames: dropped,
                interruption: interruption,
                elapsedSeconds: elapsed,
                hasInputDevice: device
            ).code
        }
        XCTAssertEqual(code(.deviceChanged), .deviceChangeInterrupted)
        XCTAssertEqual(code(.inputStalled), .microphoneStalled)
        XCTAssertEqual(code(.inputStalled, device: false), .noMicrophone)
        // Stopped before the first tap period could arrive: nothing was captured, nothing failed.
        XCTAssertEqual(code(nil, elapsed: 0.4), .zeroFramesCaptured)
        // Stopped after a second of nothing, before the stall bound tripped: still a silent mic.
        XCTAssertEqual(code(nil, elapsed: 1.5), .microphoneStalled)
        XCTAssertEqual(code(nil, elapsed: 1.5, device: false), .noMicrophone)
        // Frames lost to a full ring are backpressure, never silence.
        XCTAssertEqual(code(dropped: 4800, .buffersRejected), .captureBackpressure)
        XCTAssertEqual(code(dropped: 4800, nil, elapsed: 3), .captureBackpressure)
        XCTAssertNil(DurableVoiceCapture.emptyCaptureFailure(droppedFrames: 0).userAction)
    }

    // MARK: - Input transport

    func testWirelessInputsGetTheLongerStallBound() {
        XCTAssertEqual(InputDeviceInspector.fourCharCode("blue"), kAudioDeviceTransportTypeBluetooth)
        XCTAssertEqual(InputDeviceInspector.fourCharCode("bltn"), kAudioDeviceTransportTypeBuiltIn)
        for wireless in [
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeContinuityCaptureWireless,
            InputDeviceInspector.fourCharCode("rscr"),
            InputDeviceInspector.fourCharCode("rstr"),
        ] {
            XCTAssertEqual(
                InputDeviceInspector.stallBound(forTransport: wireless),
                InputDeviceInspector.wirelessInputStallSeconds
            )
        }
        for wired in [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeUnknown,
        ] {
            XCTAssertEqual(
                InputDeviceInspector.stallBound(forTransport: wired),
                InputDeviceInspector.wiredInputStallSeconds
            )
        }
        XCTAssertEqual(
            InputDeviceInspector.stallBound(forTransport: nil),
            InputDeviceInspector.wiredInputStallSeconds,
            "an unreadable transport must not be given longer to stay silent"
        )
    }

    // MARK: - Capture lifecycle through the input seam

    func testStoppingACaptureThatNeverStartedIsAProtocolViolation() async {
        let capture = DurableVoiceCapture(makeInput: { throw CancellationError() }, hasInputDevice: { true })
        do {
            _ = try await capture.stopCapture()
            XCTFail("an inactive capture produced an artifact")
        } catch let failure as VoiceFailure {
            XCTAssertEqual(failure.code, .captureProtocolViolation)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// A device switch reopens the new input into the same recording: the session keeps going,
    /// the coordinator is not told to stop, and the lost interval is accounted as a gap.
    func testADeviceChangeIsRebuiltIntoTheSameRecording() async throws {
        let rig = try await CaptureRig.make(inputs: 2)
        defer { rig.cleanUp() }
        try await rig.capture.startCapture(sessionDirectory: rig.directory)
        let first = try rig.input(0)
        try first.deliver(chunks: 5)

        first.simulateDeviceChange()
        let second = try await rig.waitForInput(1)
        try second.deliver(chunks: 5)
        let artifact = try await rig.capture.stopCapture()

        XCTAssertEqual(rig.interruptions.values, [], "a recovered device change must not stop the session")
        // 2 × 5 × 4800 frames at 48 kHz, each segment flushed: exactly 16 000 frames at 16 kHz.
        XCTAssertEqual(artifact.frameCount, 16_000)
        XCTAssertGreaterThan(artifact.gapCount, 0, "the reopen interval must be recorded as a gap")
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertGreaterThanOrEqual(second.stopCount, 1)
    }

    /// The gap is the audio the switch lost: from the end of the old input's last buffer to the
    /// start of the new input's first, on the tap's host clock — not the reopen duration, which
    /// on real hardware missed ~0.5 s of notification and first-buffer latency.
    func testARebuildGapIsMeasuredFromTheAudioTimestamps() async throws {
        let rig = try await CaptureRig.make(inputs: 2)
        defer { rig.cleanUp() }
        try await rig.capture.startCapture(sessionDirectory: rig.directory)
        let origin = DurableVoiceCapture.hostClockNow()
        try rig.input(0).deliver(chunks: 5, hostSeconds: origin)          // audio ends at origin + 0.5
        try rig.input(0).simulateDeviceChange()
        try await rig.waitForInput(1).deliver(chunks: 5, hostSeconds: origin + 1.25)
        let artifact = try await rig.capture.stopCapture()

        // 0.75 s missing at 16 kHz.
        XCTAssertEqual(Double(artifact.gapCount), 12_000, accuracy: 2)
        XCTAssertEqual(artifact.frameCount, 16_000)
    }

    func testTheThirdDeviceChangeStopsTheSessionAndDeliversWhatWasHeard() async throws {
        let rig = try await CaptureRig.make(inputs: 3)
        defer { rig.cleanUp() }
        try await rig.capture.startCapture(sessionDirectory: rig.directory)
        try rig.input(0).deliver(chunks: 3)
        try rig.input(0).simulateDeviceChange()
        try await rig.waitForInput(1).simulateDeviceChange()
        let third = try await rig.waitForInput(2)
        try third.deliver(chunks: 3)
        third.simulateDeviceChange()

        let interrupted = await rig.waitForInterruption()
        XCTAssertTrue(interrupted, "the rebuild budget was never enforced")
        XCTAssertEqual(rig.interruptions.values, [.deviceChanged])
        let artifact = try await rig.capture.stopCapture()
        XCTAssertEqual(artifact.frameCount, 2 * 3 * 1600)
        XCTAssertEqual(rig.made, 3, "no input may be opened past the budget")
    }

    func testAFailedReopenStopsTheSessionAndDeliversWhatWasHeard() async throws {
        let rig = try await CaptureRig.make(inputs: 1)
        defer { rig.cleanUp() }
        try await rig.capture.startCapture(sessionDirectory: rig.directory)
        try rig.input(0).deliver(chunks: 3)
        try rig.input(0).simulateDeviceChange()

        let interrupted = await rig.waitForInterruption()
        XCTAssertTrue(interrupted)
        XCTAssertEqual(rig.interruptions.values, [.deviceChanged])
        let artifact = try await rig.capture.stopCapture()
        XCTAssertEqual(artifact.frameCount, 3 * 1600)
    }

    func testAFailedReopenWithNothingRecordedIsADeviceChangeFailure() async throws {
        let rig = try await CaptureRig.make(inputs: 1)
        defer { rig.cleanUp() }
        try await rig.capture.startCapture(sessionDirectory: rig.directory)
        try rig.input(0).simulateDeviceChange()
        let interrupted = await rig.waitForInterruption()
        XCTAssertTrue(interrupted)
        do {
            _ = try await rig.capture.stopCapture()
            XCTFail("an empty interrupted capture produced an artifact")
        } catch let failure as VoiceFailure {
            XCTAssertEqual(failure.code, .deviceChangeInterrupted)
        }
    }

    /// Stop and cancel may land at any point of a rebuild; whichever order the actor sees, no
    /// input is left open and the recording is finalized exactly once.
    func testStopOrCancelDuringARebuildLeavesNothingOpen() async throws {
        for iteration in 0..<20 {
            let rig = try await CaptureRig.make(inputs: 2)
            defer { rig.cleanUp() }
            rig.allowUnlimitedInputs()
            try await rig.capture.startCapture(sessionDirectory: rig.directory)
            try rig.input(0).deliver(chunks: 2)
            try rig.input(0).simulateDeviceChange()
            if iteration.isMultiple(of: 2) {
                let artifact = try await rig.capture.stopCapture()
                XCTAssertEqual(artifact.frameCount, 2 * 1600, "iteration \(iteration)")
            } else {
                await rig.capture.cancelCapture()
            }
            try await rig.waitUntilQuiescent()
            for input in rig.inputs where input.wasStarted {
                XCTAssertGreaterThanOrEqual(input.stopCount, 1, "iteration \(iteration): an input was left running")
            }
            // The actor is free for the next session.
            try await rig.capture.startCapture(sessionDirectory: rig.freshDirectory())
            await rig.capture.cancelCapture()
        }
    }

    // MARK: - Real microphone (opt-in)

    /// The real microphone, end to end through each tap API. Opt-in because it needs an input
    /// device and opens it: `DEVTYPE_HARDWARE_MIC=1 ./Scripts/test.sh --filter CaptureInterruptionTests`.
    func testRealMicrophoneThroughTheAutomaticTap() async throws {
        try await assertRealMicrophoneRecords(tapAPI: .automatic, seconds: 3)
    }

    func testRealMicrophoneThroughTheLegacyTap() async throws {
        try await assertRealMicrophoneRecords(tapAPI: .legacy, seconds: 3)
    }

    /// Validates the wireless stall bound: a Bluetooth/AirPlay input must start delivering before
    /// `wirelessInputStallSeconds`. Run with a headset as the default input and
    /// `DEVTYPE_HARDWARE_MIC_WIRELESS=1`.
    func testRealWirelessMicrophoneStartsWithinItsStallBound() async throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_HARDWARE_MIC_WIRELESS"] == "1" else {
            throw XCTSkip("set DEVTYPE_HARDWARE_MIC_WIRELESS=1 with a wireless default input")
        }
        let transport = InputDeviceInspector.defaultInputDevice().flatMap(InputDeviceInspector.transportType(of:))
        try XCTSkipUnless(
            transport.map(InputDeviceInspector.slowStartTransports.contains) == true,
            "the default input is not wireless"
        )
        try await assertRealMicrophoneRecords(
            tapAPI: .automatic,
            seconds: InputDeviceInspector.wirelessInputStallSeconds + 2,
            requireEnvironment: false
        )
    }

    /// A real input format change mid-capture: whether the engine absorbs it (the built-in mic on
    /// macOS 27.0.1 does — it keeps running and posts nothing that stops it) or stops and is
    /// rebuilt, no audio may be lost and the session must not stop. Changes the default input's
    /// nominal sample rate and restores it, so it is opt-in: `DEVTYPE_HARDWARE_MIC_SWITCH=1`.
    /// The rebuild path itself is exercised by the fake-input tests above; this one is what
    /// real hardware does.
    func testRealInputFormatChangeLosesNoAudio() async throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_HARDWARE_MIC_SWITCH"] == "1" else {
            throw XCTSkip("set DEVTYPE_HARDWARE_MIC_SWITCH=1 to change the input's sample rate mid-capture")
        }
        let device = try XCTUnwrap(InputDeviceInspector.defaultInputDevice(), "no default input device")
        let original = try XCTUnwrap(HardwareRate.nominal(of: device))
        let alternative = try XCTUnwrap(
            HardwareRate.available(on: device).first { $0 != original },
            "the default input supports only one sample rate"
        )
        defer {
            // The HAL applies a rate change asynchronously; wait for it before judging.
            XCTAssertEqual(HardwareRate.restore(original, on: device), original, "the input's sample rate was not restored")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardware-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = DurableVoiceCapture()
        let seen = ReasonRecorder()
        await capture.setOnInterruption { seen.append($0) }
        try await capture.startCapture(sessionDirectory: directory)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(HardwareRate.set(alternative, on: device), "could not change the input's sample rate")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let artifact = try await capture.stopCapture()

        XCTAssertEqual(seen.values, [], "a recoverable format change stopped the session")
        // 4 s were captured; a rebuild may cost its reopen interval (counted in gapCount), never more.
        let recordedPlusGap = artifact.durationSeconds + Double(artifact.gapCount) / 16_000
        XCTAssertGreaterThan(recordedPlusGap, 3.7, "audio after the change was lost")
        print("HARDWARE switch \(original)→\(alternative) rebuilt=\(artifact.gapCount > 0) frames=\(artifact.frameCount) gap=\(artifact.gapCount) seconds=\(artifact.durationSeconds)")
    }

    /// A real default-input switch on a Mac with one microphone: a temporary aggregate device
    /// wrapping the current input becomes the system default mid-capture, then the original
    /// default is restored and the aggregate destroyed. Opt-in: `DEVTYPE_HARDWARE_MIC_SWITCH=1`.
    func testRealDefaultInputSwitchKeepsRecording() async throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_HARDWARE_MIC_SWITCH"] == "1" else {
            throw XCTSkip("set DEVTYPE_HARDWARE_MIC_SWITCH=1 to switch the default input mid-capture")
        }
        let original = try XCTUnwrap(InputDeviceInspector.defaultInputDevice(), "no default input device")
        let originalUID = try XCTUnwrap(AudioDevices.uid(of: original))
        let aggregate = try AudioDevices.createAggregate(wrapping: originalUID)
        defer {
            XCTAssertEqual(AudioDevices.restoreDefaultInput(original), original, "the default input was not restored")
            XCTAssertEqual(AudioHardwareDestroyAggregateDevice(aggregate), noErr, "the test aggregate was not destroyed")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardware-default-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = DurableVoiceCapture()
        let seen = ReasonRecorder()
        await capture.setOnInterruption { seen.append($0) }
        try await capture.startCapture(sessionDirectory: directory)
        let started = Date()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(AudioDevices.setDefaultInput(aggregate), "could not make the aggregate the default input")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let wall = Date().timeIntervalSince(started)
        let artifact = try await capture.stopCapture()

        XCTAssertEqual(seen.values, [], "a switch to a working input stopped the session")
        let recordedPlusGap = artifact.durationSeconds + Double(artifact.gapCount) / 16_000
        XCTAssertGreaterThan(recordedPlusGap, wall - 0.3, "audio after the switch was lost")
        print("HARDWARE default-switch rebuilt=\(artifact.gapCount > 0) frames=\(artifact.frameCount) gapMs=\(artifact.gapCount / 16) recorded=\(artifact.durationSeconds) wall=\(String(format: "%.2f", wall))")
    }

    /// The recording device disappears mid-capture — what unplugging a USB mic or an AirPods
    /// disconnect does. A temporary aggregate is the default input when capture starts, then is
    /// destroyed; the system falls back to the original input and capture must reopen onto it.
    /// Opt-in: `DEVTYPE_HARDWARE_MIC_SWITCH=1`.
    func testRealRecordingDeviceRemovalIsRebuiltOntoTheFallbackInput() async throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_HARDWARE_MIC_SWITCH"] == "1" else {
            throw XCTSkip("set DEVTYPE_HARDWARE_MIC_SWITCH=1 to remove the recording device mid-capture")
        }
        let original = try XCTUnwrap(InputDeviceInspector.defaultInputDevice(), "no default input device")
        let originalUID = try XCTUnwrap(AudioDevices.uid(of: original))
        var aggregate: AudioObjectID? = try AudioDevices.createAggregate(wrapping: originalUID)
        defer {
            if let aggregate { _ = AudioHardwareDestroyAggregateDevice(aggregate) }
            XCTAssertEqual(AudioDevices.restoreDefaultInput(original), original, "the default input was not restored")
        }
        XCTAssertTrue(AudioDevices.setDefaultInput(try XCTUnwrap(aggregate)))
        let settle = Date().addingTimeInterval(3)
        while InputDeviceInspector.defaultInputDevice() != aggregate, Date() < settle {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(InputDeviceInspector.defaultInputDevice(), aggregate, "the aggregate never became the default")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardware-device-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = DurableVoiceCapture()
        let seen = ReasonRecorder()
        await capture.setOnInterruption { seen.append($0) }
        try await capture.startCapture(sessionDirectory: directory)
        let started = Date()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(AudioHardwareDestroyAggregateDevice(try XCTUnwrap(aggregate)), noErr)
        aggregate = nil
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let wall = Date().timeIntervalSince(started)
        let artifact = try await capture.stopCapture()

        print("HARDWARE device-removal interruptions=\(seen.values) rebuilt=\(artifact.gapCount > 0) frames=\(artifact.frameCount) gapMs=\(artifact.gapCount / 16) recorded=\(artifact.durationSeconds) wall=\(String(format: "%.2f", wall))")
        // Core Audio decides whether the engine was bound to the aggregate or already followed
        // the fallback: both outcomes have been observed on macOS 27.0.1. Either way the session
        // must continue, and the recording plus its measured gap must account for the wall time.
        XCTAssertEqual(seen.values, [], "removing the recording device stopped the session instead of reopening")
        let recordedPlusGap = artifact.durationSeconds + Double(artifact.gapCount) / 16_000
        XCTAssertGreaterThan(recordedPlusGap, wall - 0.3, "audio was lost without being counted as a gap")
    }

    /// Starting while the HAL is still settling after a default-input change: the field case
    /// "AirPods just connected, start dictating". Reproduced -10868 "Input HW format is invalid"
    /// before the start retried. Opt-in: `DEVTYPE_HARDWARE_MIC_SWITCH=1`.
    func testRealStartImmediatelyAfterADefaultInputChangeOpens() async throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_HARDWARE_MIC_SWITCH"] == "1" else {
            throw XCTSkip("set DEVTYPE_HARDWARE_MIC_SWITCH=1 to switch the default input before starting")
        }
        let original = try XCTUnwrap(InputDeviceInspector.defaultInputDevice(), "no default input device")
        let originalUID = try XCTUnwrap(AudioDevices.uid(of: original))
        var aggregate: AudioObjectID? = try AudioDevices.createAggregate(wrapping: originalUID)
        defer {
            XCTAssertEqual(AudioDevices.restoreDefaultInput(original), original, "the default input was not restored")
            if let aggregate { _ = AudioHardwareDestroyAggregateDevice(aggregate) }
        }

        for round in 0..<3 {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("hardware-start-after-switch-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            // Alternate the default and start at once, with no settle wait.
            let target = round.isMultiple(of: 2) ? try XCTUnwrap(aggregate) : original
            XCTAssertTrue(AudioDevices.setDefaultInput(target))
            let capture = DurableVoiceCapture()
            try await capture.startCapture(sessionDirectory: directory)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let artifact = try await capture.stopCapture()
            XCTAssertGreaterThan(artifact.durationSeconds, 0.5, "round \(round)")
            print("HARDWARE start-after-switch round=\(round) seconds=\(artifact.durationSeconds)")
        }
        XCTAssertEqual(AudioDevices.restoreDefaultInput(original), original)
        if let created = aggregate {
            XCTAssertEqual(AudioHardwareDestroyAggregateDevice(created), noErr)
            aggregate = nil
        }
    }

    /// Answers "does a format change lose audio?" against the run-to-run noise of the same
    /// capture without one: recorded seconds minus wall-clock seconds, several runs per arm.
    /// Opt-in: `DEVTYPE_HARDWARE_MIC_SWITCH=1`.
    func testRealFormatChangeDeficitIsWithinTheNoiseFloor() async throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_HARDWARE_MIC_SWITCH"] == "1" else {
            throw XCTSkip("set DEVTYPE_HARDWARE_MIC_SWITCH=1 to change the input's sample rate mid-capture")
        }
        let device = try XCTUnwrap(InputDeviceInspector.defaultInputDevice())
        let original = try XCTUnwrap(HardwareRate.nominal(of: device))
        let alternative = try XCTUnwrap(HardwareRate.available(on: device).first { $0 != original })
        defer {
            XCTAssertEqual(HardwareRate.restore(original, on: device), original, "the input's sample rate was not restored")
        }

        func deficit(changingRate: Bool) async throws -> Double {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("hardware-floor-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let capture = DurableVoiceCapture()
            try await capture.startCapture(sessionDirectory: directory)
            let started = Date()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            if changingRate {
                XCTAssertTrue(HardwareRate.set(alternative, on: device))
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let wall = Date().timeIntervalSince(started)
            let artifact = try await capture.stopCapture()
            if changingRate {
                HardwareRate.set(original, on: device)
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            return wall - (artifact.durationSeconds + Double(artifact.gapCount) / 16_000)
        }

        var baseline: [Double] = []
        var changed: [Double] = []
        // Interleaved so drift in the device or the machine hits both arms alike.
        for _ in 0..<4 {
            baseline.append(try await deficit(changingRate: false))
            changed.append(try await deficit(changingRate: true))
        }
        let format = { (values: [Double]) in values.map { String(format: "%.3f", $0) }.joined(separator: " ") }
        print("HARDWARE floor baseline=[\(format(baseline))] changed=[\(format(changed))]")
        // One tap period is 100 ms: a change that dropped a buffer would push the changed arm's
        // worst deficit past the baseline's worst by at least that much.
        let baselineWorst = try XCTUnwrap(baseline.max())
        let changedWorst = try XCTUnwrap(changed.max())
        XCTAssertLessThan(changedWorst, baselineWorst + 0.1, "a format change lost audio beyond the noise floor")
    }

    private enum AudioDevices {
        static func uid(of device: AudioObjectID) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
            return uid?.takeRetainedValue() as String?
        }

        static func createAggregate(wrapping subDeviceUID: String) throws -> AudioObjectID {
            let description: [String: Any] = [
                kAudioAggregateDeviceUIDKey: "com.devtype.tests.input-switch.\(UUID().uuidString)",
                kAudioAggregateDeviceNameKey: "DevType test input switch",
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: subDeviceUID]],
                kAudioAggregateDeviceMainSubDeviceKey: subDeviceUID,
                kAudioAggregateDeviceIsPrivateKey: 0,
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
            guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else {
                throw XCTSkip("could not create a test aggregate device (status \(status))")
            }
            return device
        }

        /// Makes `device` the default input again and waits for the HAL, which applies it
        /// asynchronously. Returns the default input it settled on.
        static func restoreDefaultInput(_ device: AudioObjectID) -> AudioObjectID? {
            setDefaultInput(device)
            let deadline = Date().addingTimeInterval(3)
            while InputDeviceInspector.defaultInputDevice() != device, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return InputDeviceInspector.defaultInputDevice()
        }

        @discardableResult
        static func setDefaultInput(_ device: AudioObjectID) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value = device
            return AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                UInt32(MemoryLayout<AudioObjectID>.size), &value
            ) == noErr
        }
    }

    private enum HardwareRate {
        static func nominal(of device: AudioObjectID) -> Float64? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var rate: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
            return rate
        }

        static func available(on device: AudioObjectID) -> [Float64] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
            var ranges = [AudioValueRange](
                repeating: AudioValueRange(),
                count: Int(size) / MemoryLayout<AudioValueRange>.size
            )
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == noErr else { return [] }
            return ranges.map(\.mMinimum).filter { $0 >= 16_000 }
        }

        /// Sets `rate` and waits for the HAL to apply it. Returns the rate it settled on.
        static func restore(_ rate: Float64, on device: AudioObjectID) -> Float64? {
            set(rate, on: device)
            let deadline = Date().addingTimeInterval(3)
            while nominal(of: device) != rate, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return nominal(of: device)
        }

        @discardableResult
        static func set(_ rate: Float64, on device: AudioObjectID) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value = rate
            return AudioObjectSetPropertyData(
                device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value
            ) == noErr
        }
    }

    private func assertRealMicrophoneRecords(
        tapAPI: MicrophoneTapAPI,
        seconds: TimeInterval,
        requireEnvironment: Bool = true
    ) async throws {
        if requireEnvironment, ProcessInfo.processInfo.environment["DEVTYPE_HARDWARE_MIC"] != "1" {
            throw XCTSkip("set DEVTYPE_HARDWARE_MIC=1 to open the real microphone")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardware-mic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = DurableVoiceCapture(makeInput: { try AVAudioEngineCaptureInput(tapAPI: tapAPI) })
        let seen = ReasonRecorder()
        await capture.setOnInterruption { seen.append($0) }
        try await capture.startCapture(sessionDirectory: directory)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let artifact = try await capture.stopCapture()

        XCTAssertEqual(seen.values, [], "a working microphone was reported as interrupted")
        XCTAssertGreaterThan(artifact.durationSeconds, seconds - 0.5)
        XCTAssertEqual(artifact.gapCount, 0)
        print("HARDWARE mic tap=\(tapAPI) frames=\(artifact.frameCount) seconds=\(artifact.durationSeconds)")
    }

    // MARK: - Fixtures

    static func monoBuffer(frames: AVAudioFrameCount, sampleRate: Double = 16_000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData?[0][frame] = sinf(Float(frame) * 0.05) * 0.5
        }
        return buffer
    }

    private final class ReasonRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CaptureInterruption] = []

        func append(_ reason: CaptureInterruption) {
            lock.withLock { storage.append(reason) }
        }

        var values: [CaptureInterruption] {
            lock.withLock { storage }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private struct DrainFixture {
        let pool: AudioBufferPool
        let writer: CAFSessionWriter
        let latch = CaptureInterruptionLatch()
        let directory: URL

        init(pool: AudioBufferPool) throws {
            self.pool = pool
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("capture-interruption-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            writer = try CAFSessionWriter(
                outputURL: directory.appendingPathComponent("capture.caf"),
                sampleRate: 16_000,
                channelCount: 1
            )
        }

        func makeDrain(inputStallSeconds: TimeInterval) -> PCMCaptureDrain {
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
            return PCMCaptureDrain(
                pool: pool,
                writer: writer,
                converter: source.flatMap { AVAudioConverter(from: $0, to: writer.targetFormat) },
                targetFormat: writer.targetFormat,
                onPCMBuffer: nil,
                onLevel: nil,
                interruption: latch,
                inputStallSeconds: inputStallSeconds
            )
        }

        func waitForReason(within seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while latch.reason == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            return latch.reason != nil
        }

        func cleanUp() {
            _ = try? writer.finalize()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// A microphone input the test drives: it delivers 48 kHz buffers on demand and posts a device
/// change when told to, exactly as `AVAudioEngineCaptureInput` would after the engine stopped.
final class FakeCaptureInput: CaptureInput, @unchecked Sendable {
    let format: AVAudioFormat
    let stallBound: TimeInterval = 60

    private let lock = NSLock()
    private var pool: AudioBufferPool?
    private var onDeviceChange: (@Sendable () -> Void)?
    private var started = false
    private var stops = 0
    private var shouldFailStart = false

    /// When set, `start` throws as an engine that cannot start does — already stopped.
    var failStart: Bool {
        get { lock.withLock { shouldFailStart } }
        set { lock.withLock { shouldFailStart = newValue } }
    }

    init() throws {
        format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
    }

    var wasStarted: Bool { lock.withLock { started } }
    var stopCount: Int { lock.withLock { stops } }

    func start(into pool: AudioBufferPool, onDeviceChange: @escaping @Sendable () -> Void) throws {
        if failStart {
            lock.withLock { stops += 1 }
            throw VoiceFailure(stage: .audioCapture, code: .noMicrophone, redactedDetail: "fake: engine did not start")
        }
        lock.withLock {
            self.pool = pool
            self.onDeviceChange = onDeviceChange
            started = true
        }
    }

    func stop() {
        lock.withLock {
            stops += 1
            pool = nil
        }
    }

    /// Enqueues `chunks` 100 ms buffers (4800 frames each). With `hostSeconds`, each buffer is
    /// stamped on the host clock as a real tap's would be, back to back from that time.
    func deliver(chunks: Int, hostSeconds: Double? = nil) throws {
        guard let pool = lock.withLock({ pool }) else {
            return XCTFail("delivered into a stopped input")
        }
        for index in 0..<chunks {
            let buffer = try CaptureInterruptionTests.monoBuffer(frames: 4800, sampleRate: 48_000)
            let hostTime = hostSeconds.map { AVAudioTime.hostTime(forSeconds: $0 + Double(index) * 0.1) } ?? 0
            XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: Double(index * 4800), hostTime: hostTime))
        }
    }

    func simulateDeviceChange() {
        lock.withLock { pool = nil }
        lock.withLock { onDeviceChange }?()
    }
}

/// A `DurableVoiceCapture` wired to a fixed list of fake inputs; asking for more than the list
/// holds fails the way an unopenable device does.
private final class CaptureRig: @unchecked Sendable {
    private let planned: [FakeCaptureInput]
    let directory: URL
    let capture: DurableVoiceCapture
    let interruptions = InterruptionLog()
    private let lock = NSLock()
    private var opened = 0
    private var extraInputs: [FakeCaptureInput] = []
    private var unlimited = false
    private var extraDirectories: [URL] = []

    /// The interruption handler is installed before the rig is returned, so no capture can start
    /// without it.
    static func make(inputs count: Int) async throws -> CaptureRig {
        let rig = try CaptureRig(inputs: count)
        let log = rig.interruptions
        await rig.capture.setOnInterruption { log.append($0) }
        return rig
    }

    private init(inputs count: Int) throws {
        planned = try (0..<count).map { _ in try FakeCaptureInput() }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-rig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let box = WeakRig()
        capture = DurableVoiceCapture(
            makeInput: {
                guard let rig = box.rig else { throw CancellationError() }
                return try rig.next()
            },
            hasInputDevice: { true }
        )
        box.rig = self
    }

    var made: Int { lock.withLock { opened } }
    var inputs: [FakeCaptureInput] { lock.withLock { planned + extraInputs } }

    func next() throws -> any CaptureInput {
        try lock.withLock {
            if opened < planned.count {
                defer { opened += 1 }
                return planned[opened]
            }
            guard unlimited else {
                throw VoiceFailure(stage: .audioCapture, code: .noMicrophone, redactedDetail: "fake: no more inputs")
            }
            let extra = try FakeCaptureInput()
            extraInputs.append(extra)
            opened += 1
            return extra
        }
    }

    /// From now on every reopen succeeds with a fresh fake.
    func allowUnlimitedInputs() {
        lock.withLock { unlimited = true }
    }

    func input(_ index: Int) throws -> FakeCaptureInput {
        let all = inputs
        guard index < made, index < all.count else {
            throw VoiceFailure(stage: .audioCapture, code: .noMicrophone, redactedDetail: "fake input \(index) was never opened")
        }
        return all[index]
    }

    func waitForInput(_ index: Int) async throws -> FakeCaptureInput {
        let deadline = Date().addingTimeInterval(3)
        while !opened(index), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(opened(index), "input \(index) was never opened")
        return try input(index)
    }

    private func opened(_ index: Int) -> Bool {
        let all = inputs
        return index < made && index < all.count && all[index].wasStarted
    }

    func waitForInterruption() async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while interruptions.values.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return !interruptions.values.isEmpty
    }

    /// Lets a scheduled rebuild finish; a later `startCapture` must then succeed.
    func waitUntilQuiescent() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func freshDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-rig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        lock.withLock { extraDirectories.append(url) }
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        for url in lock.withLock({ extraDirectories }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    final class InterruptionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CaptureInterruption] = []
        func append(_ reason: CaptureInterruption) { lock.withLock { storage.append(reason) } }
        var values: [CaptureInterruption] { lock.withLock { storage } }
    }

    private final class WeakRig: @unchecked Sendable {
        weak var rig: CaptureRig?
    }
}
