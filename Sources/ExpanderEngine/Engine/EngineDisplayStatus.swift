import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Menu-bar / status-item display state derived from Listen + AX + tap + pause + Secure Input.
/// A swallowing `defaultTap` needs Listen **and** Accessibility. Post-only missing degrades
/// inject and does **not** force Needs Permissions while the tap is running.
public enum EngineDisplayStatus: Equatable {
    case needsPermissions
    case tapFailed
    case paused
    case secure
    case active

    /// True when the user should open Permission Recovery or fix TCC / tap.
    public var requiresAction: Bool {
        switch self {
        case .needsPermissions, .tapFailed:
            return true
        case .paused, .secure, .active:
            return false
        }
    }

    public var menuTitle: String {
        switch self {
        case .needsPermissions: return "Status: Needs Permissions"
        case .tapFailed: return "Status: Tap Failed"
        case .paused: return "Status: Paused"
        case .secure: return "Status: Secure"
        case .active: return "Status: Active"
        }
    }

    /// Menu title with a lightweight action badge when permissions or tap need attention.
    public var menuTitleWithActionHint: String {
        requiresAction ? "\(menuTitle) ⚠" : menuTitle
    }

    public var buttonTitle: String {
        switch self {
        case .needsPermissions: return "DevType (Needs Permissions)"
        case .tapFailed: return "DevType (Tap Failed)"
        case .paused: return "DevType (Paused)"
        case .secure: return "DevType (Secure)"
        case .active: return "DevType"
        }
    }

    public var toolTip: String {
        toolTip(snapshot: nil)
    }

    /// Tooltip listing missing capabilities (Listen / AX / Post).
    public func toolTip(snapshot: PermissionSnapshot?) -> String {
        toolTip(
            missingCapabilityNames: snapshot?.missingCapabilityNames ?? [],
            canListenTap: snapshot?.canListenTap ?? true,
            canUseAX: snapshot?.canUseAX ?? true,
            degradedInject: snapshot?.isDegradedInject ?? false
        )
    }

    public func toolTip(
        missingCapabilityNames: [String],
        canListenTap: Bool = true,
        canUseAX: Bool = true,
        degradedInject: Bool = false
    ) -> String {
        switch self {
        case .needsPermissions:
            if missingCapabilityNames.isEmpty {
                return "Grant Input Monitoring and Accessibility in Permission Recovery (⌘⇧P) so the event tap can start"
            }
            var tip = "\(PermissionSnapshot.missingSummary(from: missingCapabilityNames)). Open Permission Recovery (⌘⇧P)."
            if !canListenTap || !canUseAX {
                tip += " Input Monitoring and Accessibility are both required for the event tap."
            }
            return tip
        case .tapFailed:
            return "Event tap failed to start despite Listen + Accessibility — quit other DevType copies, re-open the packaged app, then use Permission Recovery (⌘⇧P)"
        case .paused:
            return "DevType is paused"
        case .secure:
            return LocalizationManager.shared.s("status.secure.copyHelp", LocalizationManager.shared.s("menu.copySecret"))
        case .active:
            if degradedInject {
                let names = missingCapabilityNames.filter { $0 != "Input Monitoring" && $0 != "Accessibility" }
                if !names.isEmpty {
                    return "\(PermissionSnapshot.missingSummary(from: names)). Tap active — inject degraded. Permission Recovery (⌘⇧P)."
                }
            }
            return "DevType Native macOS Text Expander"
        }
    }

    /// Guidance when Listen + AX are granted but the tap still will not start.
    public static let tapFailedRecoveryGuidance = """
    Tap Failed: Input Monitoring and Accessibility look granted but the event tap did not start. Quit any other DevType copies, then re-open \(ProcessIdentity.preferredInstalledAppPath) (or \(ProcessIdentity.developmentAppPathHint) while developing) so TCC matches this identity. If Settings toggles look ON for an older binary, run Scripts/reset-tcc.sh and Request again.
    """

    /// Active when Listen + AX allow a running tap, user has not paused, and Secure Input is off.
    /// Missing Post alone does not demote to Needs Permissions.
    ///
    /// A paused engine has no tap *by design*: `PermissionCoordinator.applyTapLifecycle` only calls
    /// `EventTapEngine.start()` when `isEnabled`. Blaming the tap before asking whether it was ever
    /// meant to run reported a one-click pause as Tap Failed, whose recovery copy sends the user
    /// after TCC identity and duplicate processes — a permissions hunt for a state no permission
    /// change can fix. Every prior test of the paused branch passed `isTapRunning: true` alongside
    /// `isEnabled: false`, a combination the running app cannot produce, so none of them saw it.
    public static func resolve(
        canListenTap: Bool,
        canUseAX: Bool = true,
        isTapRunning: Bool,
        isEnabled: Bool,
        isSecureInputActive: Bool,
        hasAttemptedTapStart: Bool = true
    ) -> EngineDisplayStatus {
        // `.defaultTap` needs both capabilities; missing either is Needs Permissions, not Tap Failed.
        if !canListenTap || !canUseAX {
            return .needsPermissions
        }
        // Only a tap that was asked to run can have failed — and `isEnabled` does not say that.
        // It is the user's pause preference, true from the first line of launch, while the tap
        // is not installed until the permission coordinator starts it tens of milliseconds
        // later. Reading the two together reported a tap that had never been asked to start as
        // one that had tried and failed, which is the launch-time Tap Failed flash.
        //
        // Defaulted to `true` so every caller that asks *after* startup — the recovery window,
        // Preferences, the diagnostic report — keeps its existing behaviour untouched.
        if isEnabled && hasAttemptedTapStart && !isTapRunning {
            return .tapFailed
        }
        if isSecureInputActive {
            return .secure
        }
        if !isEnabled {
            return .paused
        }
        return .active
    }

    /// Convenience from a full snapshot.
    public static func resolve(
        snapshot: PermissionSnapshot,
        isTapRunning: Bool,
        isEnabled: Bool,
        isSecureInputActive: Bool,
        hasAttemptedTapStart: Bool = true
    ) -> EngineDisplayStatus {
        resolve(
            canListenTap: snapshot.canListenTap,
            canUseAX: snapshot.canUseAX,
            isTapRunning: isTapRunning,
            isEnabled: isEnabled,
            isSecureInputActive: isSecureInputActive,
            hasAttemptedTapStart: hasAttemptedTapStart
        )
    }
}
