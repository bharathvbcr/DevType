import Foundation

/// Canonical timing policy for the transient voice HUD.
public enum VoiceHUDPresentationTiming {
    public static let fadeInDuration: TimeInterval = 0.14
    public static let fadeOutDuration: TimeInterval = 0.14
    public static let successHoldDuration: TimeInterval = 0.75
    public static let errorHoldDuration: TimeInterval = 2.0
}
