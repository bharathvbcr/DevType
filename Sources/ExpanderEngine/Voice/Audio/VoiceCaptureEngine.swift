import Foundation
import AVFoundation

/// The microphone operations `VoiceSessionCoordinator` drives.
///
/// Extracted so the coordinator's capture races are reachable from a test. The coordinator held
/// `DurableVoiceCapture.shared` directly, which meant the only way to observe "a superseded
/// session must tear the microphone back down" was to grep the source for the call — a check
/// that passes on code shaped correctly and wrong, because it never runs anything.
///
/// Deliberately narrow: exactly the five members the coordinator uses, no more. This is a seam
/// for testing an ordering rule, not an abstraction over audio capture, and a wider protocol
/// would invite a second implementation that drifts from the real one.
public protocol VoiceCaptureEngine: Actor {
    func setOnPCMBuffer(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?)
    func setOnAudioLevelUpdate(_ handler: (@Sendable (Float) -> Void)?)
    func startCapture(sessionDirectory: URL) throws
    func stopCapture() async throws -> AudioArtifact
    func cancelCapture()
}

/// The real engine already has every member; the conformance adds nothing to it.
extension DurableVoiceCapture: VoiceCaptureEngine {}
