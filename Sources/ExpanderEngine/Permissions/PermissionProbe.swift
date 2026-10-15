import ApplicationServices
import CoreGraphics
import Foundation

/// CG + AX preflights only. No IOHID — DTS guidance is CG for Listen/Post registration.
public struct PermissionProbe: Sendable {
    public init() {}

    public func snapshot() -> PermissionSnapshot {
        return PermissionSnapshot(
            canListenTap: CGPreflightListenEventAccess(),
            canUseAX: canUseAX(),
            canPostEvents: CGPreflightPostEventAccess()
        )
    }

    public func canListenTap() -> Bool { CGPreflightListenEventAccess() }
    public func canUseAX() -> Bool { AccessibilityTrust.isProcessTrusted() }
    public func canPostEvents() -> Bool { CGPreflightPostEventAccess() }
}

/// The one Accessibility-trust probe. `PermissionProbe.canUseAX` and
/// `AXContextChecker.isProcessTrusted` both used to build this options dictionary.
public enum AccessibilityTrust {
    public static func isProcessTrusted(prompt: Bool = false) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
