import Foundation
@preconcurrency import AVFoundation

/// One opened microphone input: an engine whose tap feeds an `AudioBufferPool`.
///
/// `DurableVoiceCapture` owns the recording across a whole session; an input lives only until
/// its device changes. Keeping the engine behind this seam is what lets a device switch be
/// rebuilt — and lets that rebuild be driven by a test without a second microphone.
protocol CaptureInput: AnyObject, Sendable {
    /// The format the tap delivers, read from the hardware before `start`.
    var format: AVAudioFormat { get }
    /// How long this input may deliver nothing before it is declared stalled.
    var stallBound: TimeInterval { get }
    /// Installs the tap into `pool`, observes configuration changes, and starts the engine.
    /// `onDeviceChange` runs on an arbitrary thread after the engine stopped itself because the
    /// device or its format changed. On a throw the input is already stopped.
    func start(into pool: AudioBufferPool, onDeviceChange: @escaping @Sendable () -> Void) throws
    /// Stops observing, removes the tap and stops the engine. Idempotent. Returns after the
    /// in-flight tap callback, so no enqueue follows it.
    func stop()
}

/// Which tap API to install. `.automatic` takes the macOS 27 throwing tap where it exists;
/// `.legacy` forces the deprecated one so both stay exercised on a machine that has both.
enum MicrophoneTapAPI: Sendable {
    case automatic
    case legacy
}

/// The system default input through `AVAudioEngine`.
final class AVAudioEngineCaptureInput: CaptureInput, @unchecked Sendable {
    let format: AVAudioFormat
    let stallBound: TimeInterval

    /// `installTap`'s documented range is 100–400 ms (AVAudioNode.h); ask for the lower bound
    /// rather than a frame count the engine rounds up anyway.
    static let tapRequestSeconds: Double = 0.1

    private let engine: AVAudioEngine
    private let tapAPI: MicrophoneTapAPI
    private let lock = NSLock()
    private var monitor: EngineConfigurationMonitor?
    private var tapInstalled = false
    private var stopped = false

    /// Opens the current default input. Throws `.noMicrophone` when it reports no usable format.
    init(tapAPI: MicrophoneTapAPI = .automatic) throws {
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceFailure(
                stage: .audioCapture,
                code: .noMicrophone,
                userAction: .grantMicrophonePermission,
                redactedDetail: "Hardware input format unavailable or invalid"
            )
        }
        self.engine = engine
        self.format = format
        self.tapAPI = tapAPI
        self.stallBound = InputDeviceInspector.currentStallBound()
    }

    func start(into pool: AudioBufferPool, onDeviceChange: @escaping @Sendable () -> Void) throws {
        let frames = AVAudioFrameCount((format.sampleRate * Self.tapRequestSeconds).rounded(.up))
        try MicrophoneTap.install(on: engine.inputNode, frames: frames, format: format, api: tapAPI, into: pool)
        // Registered before start: a device switch during start-up must not go unseen.
        let monitor = EngineConfigurationMonitor(engine: engine, onChange: onDeviceChange)
        lock.withLock {
            tapInstalled = true
            self.monitor = monitor
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let teardown: (EngineConfigurationMonitor?, Bool)? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            defer { monitor = nil }
            return (monitor, tapInstalled)
        }
        guard let teardown else { return }
        teardown.0?.invalidate()
        if teardown.1 {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
    }
}

/// The only place a microphone tap is installed. Both closures copy synchronously into the pool
/// and capture nothing but the pool: the engine reuses its buffer after the callback returns,
/// and the realtime thread must not hop actors or tasks.
enum MicrophoneTap {
    static func install(
        on node: AVAudioNode,
        frames: AVAudioFrameCount,
        format: AVAudioFormat,
        api: MicrophoneTapAPI,
        into pool: AudioBufferPool
    ) throws {
        // The throwing tap exists from the macOS 27 SDK, which ships with Swift 6.4; the release
        // job's older SDK must still compile the legacy path alone.
        #if compiler(>=6.4)
        if api == .automatic, #available(macOS 27.0, *) {
            try node.installAudioTap(onBus: 0, bufferSize: frames, format: format) { buffer, time in
                _ = buffer.withUnsafeAudioBufferList { list in
                    pool.enqueue(
                        bufferList: list,
                        frameLength: AVAudioFrameCount(clamping: buffer.frameLength),
                        format: buffer.format,
                        sampleTime: Double(time.sampleTime),
                        hostTime: time.isHostTimeValid ? time.hostTime : 0
                    )
                }
            }
            return
        }
        #endif
        node.installTap(onBus: 0, bufferSize: frames, format: format) { buffer, time in
            _ = pool.enqueue(
                buffer: buffer,
                sampleTime: Double(time.sampleTime),
                hostTime: time.isHostTimeValid ? time.hostTime : 0
            )
        }
    }
}

/// AVAudioEngine stops itself when the input device or its format changes and posts
/// `AVAudioEngineConfigurationChange`; the tap then goes quiet without any error. Scoped to one
/// engine so another engine in the process cannot touch this capture.
final class EngineConfigurationMonitor: @unchecked Sendable {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    init(
        engine: AVAudioEngine,
        onChange: @escaping @Sendable () -> Void,
        center: NotificationCenter = .default
    ) {
        self.center = center
        token = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { note in
            // AVAudioEngine.h: the engine "stops itself" and then posts. A change it absorbed
            // while still running did not silence the tap. The engine is read from the
            // notification, never captured: the header warns that releasing the last reference
            // inside this handler can deadlock teardown.
            if let posted = note.object as? AVAudioEngine, posted.isRunning { return }
            onChange()
        }
    }

    func invalidate() {
        let removed: NSObjectProtocol? = lock.withLock {
            defer { token = nil }
            return token
        }
        if let removed { center.removeObserver(removed) }
    }

    deinit { invalidate() }
}
