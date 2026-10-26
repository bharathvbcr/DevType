import Foundation
import AVFoundation

/// The microphone operations `VoiceSessionCoordinator` drives.
///
/// Extracted so the coordinator's capture races are reachable from a test. The coordinator held
/// `DurableVoiceCapture.shared` directly, which meant the only way to observe "a superseded
/// session must tear the microphone back down" was to grep the source for the call — a check
/// that passes on code shaped correctly and wrong, because it never runs anything.
///
/// Deliberately narrow: exactly the six members the coordinator uses, no more. This is a seam
/// for testing an ordering rule, not an abstraction over audio capture, and a wider protocol
/// would invite a second implementation that drifts from the real one.
public protocol VoiceCaptureEngine: Actor {
    func setOnPCMBuffer(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?)
    func setOnAudioLevelUpdate(_ handler: (@Sendable (Float) -> Void)?)
    /// Called at most once per input, from an arbitrary thread, when capture cannot continue
    /// before the user stops it. A device switch the engine recovers from — the new input is
    /// reopened into the same recording, up to `DurableVoiceCapture.maximumInputRebuilds` times —
    /// is not reported. The recording is still owned by `stopCapture`, which delivers what was
    /// heard.
    func setOnInterruption(_ handler: (@Sendable (CaptureInterruption) -> Void)?)
    /// Async because opening an input waits out a device that is still settling after a switch.
    func startCapture(sessionDirectory: URL) async throws
    func stopCapture() async throws -> AudioArtifact
    func cancelCapture()
}

/// Why a capture stopped producing audio while the user was still speaking.
public enum CaptureInterruption: String, Sendable, Equatable {
    /// The input device or its format changed and the new input could not be reopened, or the
    /// per-capture rebuild budget is spent.
    case deviceChanged
    /// The tap delivered nothing for longer than the input's stall bound (see
    /// `InputDeviceInspector`), before or after its first buffer.
    case inputStalled
    /// The tap delivers buffers the capture pool refuses to copy; every later callback will too.
    case buffersRejected
}

/// The real engine already has every member; the conformance adds nothing to it.
extension DurableVoiceCapture: VoiceCaptureEngine {}
