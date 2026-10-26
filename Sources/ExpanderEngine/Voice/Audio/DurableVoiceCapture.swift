import Foundation
@preconcurrency import AVFoundation

public actor DurableVoiceCapture {
    public static let shared = DurableVoiceCapture()

    /// One input lifetime inside a capture. A device switch retires it and opens another that
    /// writes into the same recording.
    private struct Segment {
        let id: UUID
        let input: any CaptureInput
        let pool: AudioBufferPool
        let drain: PCMCaptureDrain
        let latch: CaptureInterruptionLatch
        let formatSummary: String
        /// When the input started, on the host clock (seconds).
        let startedAt: Double
    }

    /// Everything one capture owns, from `startCapture` until `stopCapture` or `cancelCapture`.
    private struct Session {
        let writer: CAFSessionWriter
        let directory: URL
        let startedAt: UInt64
        /// The live input; nil once it died and could not be reopened.
        var segment: Segment?
        var rebuilds = 0
        var acceptedFrames: Int64 = 0
        var droppedFrames: Int64 = 0
        var rejectedFrames: UInt64 = 0
        /// Frames estimated lost while a switched device was reopened. Counted into the
        /// artifact's `gapCount`, never into the classification of an empty recording.
        var gapFrames: Int64 = 0
        /// Host-clock seconds at which the audio of a replaced input ended; closed when the
        /// input that replaced it is retired.
        var openGapStartedAt: Double?
        /// A writer/converter failure must survive until `stopCapture()` so the coordinator
        /// reports the real failure instead of a seemingly valid artifact with missing frames.
        var captureError: VoiceFailure?
        var joinFailure: VoiceFailure?
        /// Why the input went quiet, if it did and was not recovered.
        var interruption: CaptureInterruption?
    }

    private var session: Session?
    /// True while `stopCapture` owns the session across its awaits; start, cancel and a device
    /// rebuild must not take the writer out from under it.
    private var stopping = false
    /// A device rebuild in flight. `stopCapture` joins it; `cancelCapture` (which cannot await)
    /// leaves the teardown to it.
    private var rebuildTask: Task<Void, Never>?
    private var cancelRequestedDuringRebuild = false
    /// True while `startCapture` waits out a device that is still settling; a cancel in that
    /// window is honoured when the start resumes.
    private var starting = false
    private var cancelRequestedDuringStart = false

    private let makeInput: @Sendable () throws -> any CaptureInput
    private let hasInputDevice: @Sendable () -> Bool

    /// Device switches absorbed per capture before the session stops instead. Bounds a device
    /// that flaps between profiles.
    static let maximumInputRebuilds = 2
    /// Below this, an empty recording is a stop before the first tap period could arrive; at or
    /// above it (2.5× the documented 400 ms maximum tap period) the input sent nothing.
    static let minimumStallEvidenceSeconds: TimeInterval = 1
    private static let recordingSampleRate: Double = 16_000
    /// `cancelCapture` cannot await, and the drain must still be joined. The drain queue never
    /// takes this actor, so the bounded wait cannot deadlock the executor.
    private static let drainJoinTimeout: TimeInterval = 2

    public var onAudioLevelUpdate: (@Sendable (Float) -> Void)?
    public var onPCMBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onInterruption: (@Sendable (CaptureInterruption) -> Void)?

    init(
        makeInput: @escaping @Sendable () throws -> any CaptureInput = { try AVAudioEngineCaptureInput() },
        hasInputDevice: @escaping @Sendable () -> Bool = { InputDeviceInspector.defaultInputDevice() != nil }
    ) {
        self.makeInput = makeInput
        self.hasInputDevice = hasInputDevice
    }

    public func setOnInterruption(_ handler: (@Sendable (CaptureInterruption) -> Void)?) {
        onInterruption = handler
        session?.segment?.latch.setHandler(handler)
    }

    /// Actor-isolated setters — the handlers are stored state, so they cannot be
    /// assigned from outside the actor.
    public func setOnPCMBuffer(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        onPCMBuffer = handler
        session?.segment?.drain.setPCMHandler(handler)
    }

    public func setOnAudioLevelUpdate(_ handler: (@Sendable (Float) -> Void)?) {
        onAudioLevelUpdate = handler
        session?.segment?.drain.setLevelHandler(handler)
    }

    public enum MicrophonePermissionStatus: String, Sendable, Equatable {
        case authorized
        case notDetermined
        case denied
        case restricted
    }

    public static func microphonePermissionStatus() -> MicrophonePermissionStatus {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
        #else
        return .authorized
        #endif
    }

    public static func checkMicrophonePermission() -> Bool {
        microphonePermissionStatus() == .authorized
    }

    /// Closure form for legacy/callback-driven callers. New permission flows should use the
    /// async overload so the main run loop remains available to the system prompt.
    public static func requestMicrophonePermission(completion: @escaping @Sendable (Bool) -> Void) {
        #if os(macOS)
        AVCaptureDevice.requestAccess(for: .audio) { granted in completion(granted) }
        #else
        completion(true)
        #endif
    }

    public static func requestMicrophonePermission() async -> Bool {
        #if os(macOS)
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return true
        #endif
    }

    public func startCapture(sessionDirectory: URL) async throws {
        guard session == nil else { return }
        guard !stopping, rebuildTask == nil, !starting else {
            // The previous capture is still closing or another start is in flight. Opening
            // nothing while reporting success would leave the user speaking into no recording.
            throw VoiceFailure(
                stage: .audioCapture,
                code: .captureProtocolViolation,
                retryClass: .immediateSameRoute,
                redactedDetail: "The previous capture was still closing"
            )
        }

        starting = true
        cancelRequestedDuringStart = false
        defer { starting = false }

        let writer = try CAFSessionWriter(
            outputURL: sessionDirectory.appendingPathComponent("capture.caf"),
            sampleRate: Self.recordingSampleRate,
            channelCount: 1
        )
        let segment: Segment
        do {
            segment = try await openInput(writer: writer)
        } catch {
            Self.finalizeQuietly(writer, context: "capture start failure")
            throw error
        }
        if cancelRequestedDuringStart {
            // Cancelled while waiting out a device settling: close what was opened.
            cancelRequestedDuringStart = false
            segment.input.stop()
            _ = segment.drain.stopAndJoin(timeout: Self.drainJoinTimeout)
            Self.finalizeQuietly(writer, context: "capture cancelled during start")
            throw CancellationError()
        }
        session = Session(
            writer: writer,
            directory: sessionDirectory,
            startedAt: DispatchTime.now().uptimeNanoseconds,
            segment: segment
        )
    }

    public func stopCapture() async throws -> AudioArtifact {
        // Join every rebuild scheduled while this was suspended; bounded by
        // `maximumInputRebuilds`, and none can start once `stopping` is set below.
        while let rebuildTask {
            await rebuildTask.value
        }
        guard !stopping, let current = session else {
            throw VoiceFailure(
                stage: .protocolViolation,
                code: .captureProtocolViolation,
                redactedDetail: "Capture was not active"
            )
        }

        stopping = true
        defer {
            stopping = false
            session = nil
        }

        if let segment = current.segment {
            await retire(segment)
        }
        guard let finished = session else {
            throw VoiceFailure(
                stage: .protocolViolation,
                code: .captureProtocolViolation,
                redactedDetail: "Capture session vanished during finalization"
            )
        }

        // Finalize CAF writer before reporting a conversion/write failure, so the partial file is
        // still a valid recovery artifact and the writer cannot remain open across sessions.
        let finalStats: (totalFrames: Int64, sha256Hex: String, byteCount: Int64)
        do {
            finalStats = try finished.writer.finalize()
        } catch {
            if let joinFailure = finished.joinFailure { throw joinFailure }
            throw error
        }

        if let joinFailure = finished.joinFailure { throw joinFailure }
        if let failure = finished.captureError
            ?? Self.rejectedAudioFailure(
                rejectedFrames: finished.rejectedFrames,
                acceptedFrames: finished.acceptedFrames
            ) {
            throw failure
        }

        guard finalStats.totalFrames > 0 else {
            throw Self.emptyCaptureFailure(
                droppedFrames: finished.droppedFrames,
                interruption: finished.interruption,
                elapsedSeconds: Self.seconds(since: finished.startedAt),
                hasInputDevice: hasInputDevice()
            )
        }
        if let interruption = finished.interruption {
            // The coordinator already stopped the session; what was heard is still delivered.
            DevTypeLog.voice.error(
                "[Voice] capture interrupted reason=\(interruption.rawValue, privacy: .public) keptFrames=\(finalStats.totalFrames, privacy: .public) rebuilds=\(finished.rebuilds, privacy: .public)"
            )
        }

        return AudioArtifact(
            fileURL: finished.directory.appendingPathComponent("capture.caf"),
            format: "caf",
            sampleRate: Self.recordingSampleRate,
            channelCount: 1,
            frameCount: finalStats.totalFrames,
            durationSeconds: Double(finalStats.totalFrames) / Self.recordingSampleRate,
            byteCount: finalStats.byteCount,
            sha256Hex: finalStats.sha256Hex,
            gapCount: Self.gapCount(for: Saturating.adding(finished.droppedFrames, finished.gapFrames))
        )
    }

    public func cancelCapture() {
        if stopping { return }
        if starting {
            cancelRequestedDuringStart = true
            return
        }
        if rebuildTask != nil {
            // The rebuild is joining the old drain; it tears the session down when it resumes
            // instead of opening the new device.
            cancelRequestedDuringRebuild = true
            return
        }
        guard let current = session else { return }
        session = nil
        if let segment = current.segment {
            segment.input.stop()
            let outcome = segment.drain.stopAndJoin(timeout: Self.drainJoinTimeout)
            if let failure = outcome.joinFailure ?? outcome.captureError {
                DevTypeLog.voice.error(
                    "[Voice] cancelled capture drain failed code=\(failure.code.rawValue, privacy: .public) detail=\(failure.redactedDetail ?? "", privacy: .public)"
                )
            }
        }
        Self.finalizeQuietly(current.writer, context: "cancelled capture")
    }

    // MARK: - Segments

    /// Waits between attempts to open an input. Verified on macOS 27.0.1: an engine started
    /// moments after the default input changed fails with -10868 "Input HW format is invalid"
    /// while the HAL settles — the moment a user starts dictating as AirPods connect, and the
    /// moment a rebuild reopens a switched device. Bounded: three attempts, 0.5 s in all.
    static let inputOpenRetryDelaysNanoseconds: [UInt64] = [150_000_000, 350_000_000]

    /// Opens the current default input into `writer`, retrying while the device settles. Each
    /// attempt builds a fresh input, because the stale one cached the invalid format. Throws
    /// the last attempt's error; cancellation is never retried.
    private func openInput(writer: CAFSessionWriter) async throws -> Segment {
        var lastError: Error?
        for attempt in 0...Self.inputOpenRetryDelaysNanoseconds.count {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: Self.inputOpenRetryDelaysNanoseconds[attempt - 1])
            }
            do {
                let input = try makeInput()
                return try openSegment(input: input, writer: writer)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                DevTypeLog.voice.error(
                    "[Voice] could not open the input attempt=\(attempt + 1, privacy: .public) \(DevTypeLog.errorMetadata(error), privacy: .public)"
                )
            }
        }
        throw lastError ?? CancellationError()
    }

    /// Builds and starts one input lifetime writing into `writer`. On a throw nothing is left
    /// running: the input stops itself and the drain was never started.
    private func openSegment(input: any CaptureInput, writer: CAFSessionWriter) throws -> Segment {
        let target = writer.targetFormat
        var converter: AVAudioConverter?
        if input.format != target {
            guard let built = AVAudioConverter(from: input.format, to: target) else {
                input.stop()
                throw VoiceFailure(
                    stage: .audioCapture,
                    code: .audioEncodingFailed,
                    retryClass: .afterUserAction,
                    artifactState: .absent,
                    redactedDetail: "No converter from \(Self.formatSummary(input.format)) to the recording format"
                )
            }
            converter = built
        }
        // Sized from the format the tap will actually deliver, never from defaults: a pool whose
        // chunk bound is smaller than one callback refuses every buffer and records nothing.
        let pool = AudioBufferPool(capturing: input.format)
        let latch = CaptureInterruptionLatch(handler: onInterruption)
        let drain = PCMCaptureDrain(
            pool: pool,
            writer: writer,
            converter: converter,
            targetFormat: target,
            onPCMBuffer: onPCMBuffer,
            onLevel: onAudioLevelUpdate,
            interruption: latch,
            inputStallSeconds: input.stallBound
        )
        let id = UUID()
        try input.start(into: pool) { [weak self] in
            Task { await self?.handleDeviceChange(segmentID: id) }
        }
        drain.start()
        return Segment(
            id: id,
            input: input,
            pool: pool,
            drain: drain,
            latch: latch,
            formatSummary: Self.formatSummary(input.format),
            startedAt: Self.hostClockNow()
        )
    }

    /// Stops a segment's input, joins its drain (which flushes the converter), and folds its
    /// counts into the session.
    @discardableResult
    private func retire(_ segment: Segment) async -> PCMCaptureDrain.Outcome {
        segment.input.stop()
        let outcome = await join(segment.drain)
        let poolDrops = Self.int64(saturating: segment.pool.droppedFrames)
        let rejected = segment.pool.rejectedFrames
        // Read-modify-write on a copy: `session?.x = f(session?.x)` reads the property while
        // the optional-chained write holds exclusive access to it.
        guard var updated = session else { return outcome }
        if let gapStart = updated.openGapStartedAt {
            // This segment was opened after a device change: the gap runs from the end of the
            // previous input's last buffer to the start of this one's first, both on the tap's
            // host clock. Without host times, fall back to when this input started, or — if it
            // never delivered anything — to now.
            let gapEnd = outcome.firstInputAt
                ?? (outcome.acceptedFrames > 0 ? segment.startedAt : Self.hostClockNow())
            let gapSeconds = max(0, gapEnd - gapStart)
            updated.gapFrames = Saturating.adding(
                updated.gapFrames,
                Int64((gapSeconds * Self.recordingSampleRate).rounded(.up))
            )
            updated.openGapStartedAt = nil
            VoiceDiagnosticsRecorder.shared.record(
                "capture.rebuildGap",
                note: "audioGapMs=\(Int(gapSeconds * 1_000)) measured=\(outcome.firstInputAt != nil)"
            )
        }
        updated.acceptedFrames = Saturating.adding(updated.acceptedFrames, outcome.acceptedFrames)
        updated.droppedFrames = Saturating.adding(
            updated.droppedFrames,
            Saturating.adding(outcome.processingDrops, poolDrops)
        )
        updated.rejectedFrames = Saturating.adding(updated.rejectedFrames, rejected)
        updated.captureError = updated.captureError ?? outcome.captureError
        updated.joinFailure = updated.joinFailure ?? outcome.joinFailure
        updated.interruption = updated.interruption ?? segment.latch.reason
        if updated.segment?.id == segment.id { updated.segment = nil }
        session = updated
        if rejected > 0 {
            DevTypeLog.voice.error(
                "[Voice] capture pool refused microphone buffers rejectedFrames=\(rejected, privacy: .public) acceptedFrames=\(outcome.acceptedFrames, privacy: .public) format=\(segment.formatSummary, privacy: .public)"
            )
        }
        return outcome
    }

    // MARK: - Device change

    /// AVAudioEngine stopped itself because the input device or its format changed. Reopen the
    /// new default input into the same recording, up to `maximumInputRebuilds` times; beyond
    /// that, or for a segment already stopping for another reason, let the session stop.
    private func handleDeviceChange(segmentID: UUID) {
        guard let current = session?.segment,
              current.id == segmentID,
              !stopping,
              rebuildTask == nil,
              current.latch.reason == nil else { return }
        guard (session?.rebuilds ?? 0) < Self.maximumInputRebuilds else {
            current.latch.trip(.deviceChanged)
            return
        }
        let detectedAt = Self.hostClockNow()
        rebuildTask = Task { await self.rebuildInput(replacing: current, detectedAt: detectedAt) }
    }

    private func rebuildInput(replacing old: Segment, detectedAt: Double) async {
        defer { rebuildTask = nil }
        let reopenStart = DispatchTime.now().uptimeNanoseconds
        let previous = await retire(old)
        guard let current = session else { return }

        if cancelRequestedDuringRebuild {
            cancelRequestedDuringRebuild = false
            session = nil
            Self.finalizeQuietly(current.writer, context: "capture cancelled during device rebuild")
            return
        }

        let attempt = current.rebuilds + 1
        do {
            let segment = try await openInput(writer: current.writer)
            // The open may have waited for the device to settle; the session and any cancel
            // are re-read after it.
            guard var updated = session else {
                segment.input.stop()
                _ = segment.drain.stopAndJoin(timeout: Self.drainJoinTimeout)
                return
            }
            if cancelRequestedDuringRebuild {
                cancelRequestedDuringRebuild = false
                segment.input.stop()
                _ = segment.drain.stopAndJoin(timeout: Self.drainJoinTimeout)
                session = nil
                Self.finalizeQuietly(updated.writer, context: "capture cancelled during device rebuild")
                return
            }
            let reopenMs = Int(Self.seconds(since: reopenStart) * 1_000)
            // The gap opens where the previous input's audio ended — earlier than the change
            // notification — and closes when the new input's first buffer is retired with it.
            updated.openGapStartedAt = previous.lastInputEnd ?? detectedAt
            updated.rebuilds = attempt
            updated.segment = segment
            session = updated
            VoiceDiagnosticsRecorder.shared.record(
                "capture.deviceRebuilt",
                note: "attempt=\(attempt) reopenMs=\(reopenMs) format=\(segment.formatSummary)"
            )
            DevTypeLog.voice.info(
                "[Voice] reopened input after device change attempt=\(attempt, privacy: .public) reopenMs=\(reopenMs, privacy: .public) format=\(segment.formatSummary, privacy: .public)"
            )
        } catch {
            // Nothing to record into: the session stops and delivers what was heard.
            session?.interruption = .deviceChanged
            VoiceDiagnosticsRecorder.shared.record(
                "capture.deviceRebuildFailed",
                note: "attempt=\(attempt) \((error as? VoiceFailure)?.code.rawValue ?? "error")"
            )
            DevTypeLog.voice.error(
                "[Voice] could not reopen input after device change \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            old.latch.trip(.deviceChanged)
        }
    }

    private func join(_ drain: PCMCaptureDrain) async -> PCMCaptureDrain.Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: drain.stopAndJoin(timeout: Self.drainJoinTimeout))
            }
        }
    }

    // MARK: - Classification

    /// A copy the pool refused is a format contract failure, not silence: it repeats on every
    /// callback, so a session that lost frames this way must fail as such instead of finishing
    /// with gaps or, when nothing survived, as "no speech".
    static func rejectedAudioFailure(rejectedFrames: UInt64, acceptedFrames: Int64) -> VoiceFailure? {
        guard rejectedFrames > 0 else { return nil }
        return VoiceFailure(
            stage: .audioCapture,
            code: .audioEncodingFailed,
            retryClass: .afterUserAction,
            artifactState: acceptedFrames > 0 ? .partial : .absent,
            redactedDetail: "The microphone delivered \(rejectedFrames) frames the capture buffer could not copy"
        )
    }

    /// Nothing reached the recording, and none of these is silence: frames lost to a full ring
    /// are backpressure, a switched device is an interruption, an input that sent nothing for
    /// longer than a tap period is a stalled microphone — or no microphone when the system has
    /// no input device at all. Only a stop before the first tap period could arrive is "no audio".
    static func emptyCaptureFailure(
        droppedFrames: Int64,
        interruption: CaptureInterruption? = nil,
        elapsedSeconds: TimeInterval = 0,
        hasInputDevice: Bool = true
    ) -> VoiceFailure {
        switch interruption {
        case .deviceChanged:
            return VoiceFailure(
                stage: .audioCapture,
                code: .deviceChangeInterrupted,
                retryClass: .immediateSameRoute,
                artifactState: .absent,
                redactedDetail: "The audio input device changed before any audio was recorded"
            )
        case .inputStalled:
            return silentInputFailure(hasInputDevice: hasInputDevice)
        case .buffersRejected, nil:
            break
        }
        if droppedFrames > 0 {
            return VoiceFailure(
                stage: .audioFinalization,
                code: .captureBackpressure,
                retryClass: .immediateSameRoute,
                artifactState: .absent,
                redactedDetail: "\(droppedFrames) microphone frames were dropped and none were recorded"
            )
        }
        if elapsedSeconds >= minimumStallEvidenceSeconds {
            return silentInputFailure(hasInputDevice: hasInputDevice)
        }
        return VoiceFailure(
            stage: .audioFinalization,
            code: .zeroFramesCaptured,
            artifactState: .absent,
            redactedDetail: "Capture stopped before the microphone delivered audio"
        )
    }

    private static func silentInputFailure(hasInputDevice: Bool) -> VoiceFailure {
        guard hasInputDevice else {
            return VoiceFailure(
                stage: .audioCapture,
                code: .noMicrophone,
                retryClass: .afterUserAction,
                artifactState: .absent,
                redactedDetail: "The system reports no audio input device"
            )
        }
        return VoiceFailure(
            stage: .audioCapture,
            code: .microphoneStalled,
            retryClass: .afterUserAction,
            artifactState: .absent,
            redactedDetail: "The microphone delivered no audio"
        )
    }

    // MARK: - Helpers

    private static func finalizeQuietly(_ writer: CAFSessionWriter, context: String) {
        do {
            _ = try writer.finalize()
        } catch {
            DevTypeLog.voice.error(
                "[Voice] failed to finalize CAF after \(context, privacy: .public) \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
        }
    }

    static func formatSummary(_ format: AVAudioFormat) -> String {
        "\(format.sampleRate)Hz ch=\(format.channelCount) common=\(format.commonFormat.rawValue) interleaved=\(format.isInterleaved)"
    }

    /// The tap's clock: `AVAudioTime` host times are `mach_absolute_time` ticks.
    static func hostClockNow() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    private static func seconds(since start: UInt64) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
    }

    private static func int64(saturating value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    private static func gapCount(for frames: Int64) -> Int {
        if frames <= 0 { return 0 }
        if frames > Int64(Int.max) { return Int.max }
        return Int(frames)
    }
}

/// First-wins record of why capture went quiet, shared by the drain and the actor. The handler
/// runs outside the lock, once, on whichever thread tripped it.
final class CaptureInterruptionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped: CaptureInterruption?
    private var handler: (@Sendable (CaptureInterruption) -> Void)?

    init(handler: (@Sendable (CaptureInterruption) -> Void)? = nil) {
        self.handler = handler
    }

    var reason: CaptureInterruption? {
        lock.withLock { tripped }
    }

    func setHandler(_ handler: (@Sendable (CaptureInterruption) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    /// Returns false when an earlier reason already won; that reason is kept.
    @discardableResult
    func trip(_ reason: CaptureInterruption) -> Bool {
        let notify: (@Sendable (CaptureInterruption) -> Void)?? = lock.withLock {
            guard tripped == nil else { return nil }
            tripped = reason
            return .some(handler)
        }
        guard let notify else { return false }
        notify?(reason)
        return true
    }
}

/// Consumes pool copies off the actor. The tap only enqueues; this queue rebuilds an owned
/// `AVAudioPCMBuffer` for the converter, the CAF writer, and `onPCMBuffer`.
final class PCMCaptureDrain: @unchecked Sendable {
    struct Outcome: Sendable {
        var joinFailure: VoiceFailure?
        var captureError: VoiceFailure?
        var acceptedFrames: Int64
        var processingDrops: Int64
        /// Host-clock seconds at which the first consumed buffer began, when the tap supplied
        /// host times.
        var firstInputAt: Double? = nil
        /// Host-clock seconds at which the last consumed buffer ended.
        var lastInputEnd: Double? = nil

        static let idle = Outcome(joinFailure: nil, captureError: nil, acceptedFrames: 0, processingDrops: 0)
    }

    private let pool: AudioBufferPool
    private let writer: CAFSessionWriter
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "com.devtype.voice.pcm-drain", qos: .userInitiated)
    private let finished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var pcmHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var stopRequested = false
    private var didFinish = false
    private var started = false
    private var acceptedFrames: Int64 = 0
    private var processingDrops: Int64 = 0
    private var captureError: VoiceFailure?
    private var firstInputAt: Double?
    private var lastInputEnd: Double?
    private let interruption: CaptureInterruptionLatch?
    private let inputStallSeconds: TimeInterval

    /// The bound for an input whose transport is unknown; see `InputDeviceInspector`.
    static let defaultInputStallSeconds: TimeInterval = InputDeviceInspector.wiredInputStallSeconds
    /// `AVAudioConverter.h`: a rate converter holds back its filter tail until it is told the
    /// input ended. More than one flush pass is a converter misbehaving, not a longer tail.
    private static let maximumFlushPasses = 4

    init(
        pool: AudioBufferPool,
        writer: CAFSessionWriter,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat?,
        onPCMBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        onLevel: (@Sendable (Float) -> Void)?,
        interruption: CaptureInterruptionLatch? = nil,
        inputStallSeconds: TimeInterval = PCMCaptureDrain.defaultInputStallSeconds
    ) {
        self.pool = pool
        self.writer = writer
        self.converter = converter
        self.targetFormat = targetFormat
        self.pcmHandler = onPCMBuffer
        self.levelHandler = onLevel
        self.interruption = interruption
        self.inputStallSeconds = inputStallSeconds
    }

    func setPCMHandler(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        stateLock.lock()
        pcmHandler = handler
        stateLock.unlock()
    }

    func setLevelHandler(_ handler: (@Sendable (Float) -> Void)?) {
        stateLock.lock()
        levelHandler = handler
        stateLock.unlock()
    }

    func start() {
        stateLock.lock()
        if started {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()
        queue.async { [weak self] in
            self?.run()
        }
    }

    func stopAndJoin(timeout: TimeInterval) -> Outcome {
        stateLock.lock()
        stopRequested = true
        let alreadyFinished = didFinish
        let wasStarted = started
        stateLock.unlock()
        pool.wakeWaiters()
        if !alreadyFinished, wasStarted {
            if finished.wait(timeout: .now() + timeout) != .success {
                return snapshot(
                    joinFailure: VoiceFailure(
                        stage: .audioFinalization,
                        code: .audioEncodingFailed,
                        retryClass: .afterUserAction,
                        artifactState: .partial,
                        userAction: .retryWithOtherProvider,
                        redactedDetail: "Audio drain did not finish before the deadline"
                    )
                )
            }
        }
        return snapshot(joinFailure: nil)
    }

    private func run() {
        var lastInputAt = DispatchTime.now().uptimeNanoseconds
        var lastDroppedFrames: UInt64 = 0
        while !isStopRequested() {
            _ = pool.waitForEnqueue(timeout: .now() + .milliseconds(200))
            if consumeAvailable() > 0 {
                lastInputAt = DispatchTime.now().uptimeNanoseconds
            }
            watchInput(lastInputAt: &lastInputAt, lastDroppedFrames: &lastDroppedFrames)
        }
        consumeAvailable()
        flushConverter()
        stateLock.lock()
        didFinish = true
        stateLock.unlock()
        finished.signal()
    }

    private func isStopRequested() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRequested
    }

    /// Returns how many chunks were consumed.
    @discardableResult
    private func consumeAvailable() -> Int {
        let chunks = pool.dequeueAll()
        for chunk in chunks {
            consume(chunk)
        }
        return chunks.count
    }

    /// Trips the interruption latch the moment the input is known to be useless, so the user is
    /// not left speaking into a recording that stopped growing. A refused copy repeats on every
    /// callback. Silence is still a stream of buffers, so an input that has delivered nothing —
    /// before or after its first buffer — for longer than the stall bound has stopped.
    private func watchInput(lastInputAt: inout UInt64, lastDroppedFrames: inout UInt64) {
        guard let interruption, interruption.reason == nil else { return }
        if pool.rejectedFrames > 0 {
            interruption.trip(.buffersRejected)
            return
        }
        let dropped = pool.droppedFrames
        if dropped != lastDroppedFrames {
            // Callbacks are arriving, only the ring is full: the input is alive.
            lastDroppedFrames = dropped
            lastInputAt = DispatchTime.now().uptimeNanoseconds
            return
        }
        let silent = Double(DispatchTime.now().uptimeNanoseconds &- lastInputAt) / 1_000_000_000
        if silent >= inputStallSeconds {
            interruption.trip(.inputStalled)
        }
    }

    private func consume(_ chunk: AudioBufferPool.Chunk) {
        noteInputTiming(chunk)
        if hasCaptureError() {
            addDrops(Int64(chunk.frameCount))
            return
        }
        guard let owned = chunk.makePCMBuffer() else {
            record(
                VoiceFailure(
                    stage: .audioCapture,
                    code: .audioEncodingFailed,
                    retryClass: .afterUserAction,
                    artifactState: .partial,
                    userAction: .retryWithOtherProvider,
                    redactedDetail: "Could not rebuild an owned PCM buffer"
                ),
                droppedFrames: Int64(chunk.frameCount)
            )
            return
        }
        publishLevel(owned)
        if let converter, let targetFormat {
            let ratio = targetFormat.sampleRate / owned.format.sampleRate
            let capacity = AVAudioFrameCount(Double(owned.frameLength) * ratio + 100)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                record(
                    VoiceFailure(
                        stage: .audioCapture,
                        code: .audioEncodingFailed,
                        retryClass: .afterUserAction,
                        artifactState: .partial,
                        userAction: .retryWithOtherProvider,
                        redactedDetail: "Could not allocate the converted audio buffer"
                    ),
                    droppedFrames: Int64(owned.frameLength)
                )
                return
            }

            var error: NSError?
            var allConsumed = false
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if allConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                allConsumed = true
                outStatus.pointee = .haveData
                return owned
            }

            if let conversionError = error {
                record(
                    VoiceFailure(
                        stage: .audioCapture,
                        code: .audioEncodingFailed,
                        retryClass: .afterUserAction,
                        artifactState: .partial,
                        userAction: .retryWithOtherProvider,
                        redactedDetail: "Audio conversion failed: \(conversionError.localizedDescription)"
                    ),
                    droppedFrames: Int64(owned.frameLength)
                )
                return
            }
            // A rate converter primes before it emits; the withheld frames come out on a later
            // call or in `flushConverter`.
            guard outputBuffer.frameLength > 0 else { return }
            writeAndPublish(outputBuffer)
        } else {
            writeAndPublish(owned)
        }
    }

    /// Records when this input's audio began and ended on the tap's host clock, so a device
    /// rebuild can measure the audio it lost instead of estimating it from wall-clock events.
    private func noteInputTiming(_ chunk: AudioBufferPool.Chunk) {
        guard chunk.hostTime != 0, chunk.sampleRate > 0 else { return }
        let start = AVAudioTime.seconds(forHostTime: chunk.hostTime)
        let end = start + Double(chunk.frameCount) / chunk.sampleRate
        stateLock.lock()
        if firstInputAt == nil { firstInputAt = start }
        lastInputEnd = max(lastInputEnd ?? end, end)
        stateLock.unlock()
    }

    /// Emits the converter's withheld tail. Without this every recording lost the last ~20
    /// output frames at 48 kHz → 16 kHz: the converter holds them until it sees end-of-stream.
    private func flushConverter() {
        guard let converter, let targetFormat, !hasCaptureError() else { return }
        for _ in 0..<Self.maximumFlushPasses {
            guard let tail = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { return }
            var error: NSError?
            let status = converter.convert(to: tail, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if let error {
                // The tail is a few milliseconds; losing it is logged, not a failed recording.
                DevTypeLog.voice.error(
                    "[Voice] converter flush failed \(DevTypeLog.errorMetadata(error), privacy: .public)"
                )
                return
            }
            if tail.frameLength > 0 {
                writeAndPublish(tail)
            }
            guard status == .haveData else { return }
        }
    }

    private func publishLevel(_ buffer: AVAudioPCMBuffer) {
        let handler = currentLevelHandler()
        guard let handler, let floatData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let length = Int(buffer.frameLength)
        guard channelCount > 0, length > 0 else {
            handler(0)
            return
        }
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = floatData[channel]
            for index in 0..<length {
                sum += samples[index] * samples[index]
            }
        }
        let rms = sqrt(sum / Float(length * channelCount))
        handler(min(max(rms * 5.0, 0.0), 1.0))
    }

    private func writeAndPublish(_ buffer: AVAudioPCMBuffer) {
        do {
            try writer.write(buffer: buffer)
            addAccepted(Int64(buffer.frameLength))
            currentPCMHandler()?(buffer)
        } catch {
            record(
                VoiceFailure(
                    stage: .audioCapture,
                    code: .audioEncodingFailed,
                    retryClass: .afterUserAction,
                    artifactState: .partial,
                    userAction: .freeDiskSpace,
                    redactedDetail: "CAF write failed: \(error.localizedDescription)"
                ),
                droppedFrames: Int64(buffer.frameLength)
            )
        }
    }

    private func record(_ error: VoiceFailure, droppedFrames: Int64) {
        stateLock.lock()
        if droppedFrames > 0 {
            processingDrops = Saturating.adding(processingDrops, droppedFrames)
        }
        let first = captureError == nil
        if first {
            captureError = error
        }
        let totalDrops = processingDrops
        stateLock.unlock()
        guard first else { return }
        DevTypeLog.voice.error(
            "[Voice] capture stopped accepting audio code=\(error.code.rawValue, privacy: .public) droppedFrames=\(totalDrops, privacy: .public)"
        )
    }

    private func addDrops(_ frames: Int64) {
        guard frames > 0 else { return }
        stateLock.lock()
        processingDrops = Saturating.adding(processingDrops, frames)
        stateLock.unlock()
    }

    private func addAccepted(_ frames: Int64) {
        guard frames > 0 else { return }
        stateLock.lock()
        acceptedFrames = Saturating.adding(acceptedFrames, frames)
        stateLock.unlock()
    }

    private func hasCaptureError() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captureError != nil
    }

    private func currentPCMHandler() -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pcmHandler
    }

    private func currentLevelHandler() -> (@Sendable (Float) -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return levelHandler
    }

    private func snapshot(joinFailure: VoiceFailure?) -> Outcome {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Outcome(
            joinFailure: joinFailure,
            captureError: captureError,
            acceptedFrames: acceptedFrames,
            processingDrops: processingDrops,
            firstInputAt: firstInputAt,
            lastInputEnd: lastInputEnd
        )
    }
}
