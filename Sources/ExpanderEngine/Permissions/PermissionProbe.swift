import ApplicationServices
import CoreGraphics
import Foundation

/// CG + AX preflights only. No IOHID — DTS guidance is CG for Listen/Post registration.
public struct PermissionProbe: Sendable {
    public init() {}

    public func snapshot() -> PermissionSnapshot {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: false] as CFDictionary
        return PermissionSnapshot(
            canListenTap: CGPreflightListenEventAccess(),
            canUseAX: AXIsProcessTrustedWithOptions(options),
            canPostEvents: CGPreflightPostEventAccess()
        )
    }

    public func canListenTap() -> Bool { CGPreflightListenEventAccess() }
    public func canUseAX() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    public func canPostEvents() -> Bool { CGPreflightPostEventAccess() }
}
