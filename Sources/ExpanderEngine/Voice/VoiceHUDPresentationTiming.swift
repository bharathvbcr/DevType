import Foundation

/// Canonical timing policy for the transient voice HUD.
public enum VoiceHUDPresentationTiming {
    public static let defaultFadeInDuration: TimeInterval = 0.14
    public static let defaultFadeOutDuration: TimeInterval = 0.14
    public static let defaultSuccessHoldDuration: TimeInterval = 0.75
    public static let defaultErrorHoldDuration: TimeInterval = 2.0

    public static var fadeInDuration: TimeInterval = defaultFadeInDuration
    public static var fadeOutDuration: TimeInterval = defaultFadeOutDuration
    public static var successHoldDuration: TimeInterval = defaultSuccessHoldDuration
    public static var errorHoldDuration: TimeInterval = defaultErrorHoldDuration

    public static func resetToDefaults() {
        fadeInDuration = defaultFadeInDuration
        fadeOutDuration = defaultFadeOutDuration
        successHoldDuration = defaultSuccessHoldDuration
        errorHoldDuration = defaultErrorHoldDuration
    }
}
