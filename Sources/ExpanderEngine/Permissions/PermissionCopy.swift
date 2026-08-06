import Foundation

/// Honest user-facing copy for Listen / Accessibility / Post Event.
public enum PermissionCopy {
    public static let expectedBundleIdentifier = ProcessIdentity.expectedBundleIdentifier

    public static let modernPrivacySecurityScheme =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    public static let legacySecurityScheme =
        "x-apple.systempreferences:com.apple.preference.security"
    public static let manualPrivacySecurityPath =
        "System Settings → Privacy & Security"

    public static func unlockDescription(for kind: PermissionKind) -> String {
        switch kind {
        case .accessibility:
            return "Focused-element context and Accessibility-based text injection. Expansions refuse without it (fail-closed)."
        case .inputMonitoring:
            return "Required for the keyboard event tap — without it, DevType cannot read keystrokes."
        case .postEvent:
            return "Synthetic backspace, paste, and arrow cursor moves. Separate TCC service (may appear under Accessibility). No dedicated Privacy_PostEvent pane."
        }
    }

    public static func settingsToggleDisplayName(for kind: PermissionKind) -> String {
        switch kind {
        case .accessibility, .postEvent:
            return "Accessibility"
        case .inputMonitoring:
            return "Input Monitoring"
        }
    }

    public static func openSettingsButtonTitle(for kind: PermissionKind) -> String {
        switch kind {
        case .accessibility, .inputMonitoring:
            return "Open Settings"
        case .postEvent:
            return "Open Accessibility"
        }
    }

    public static func openSettingsWithoutRequestHint(
        for kind: PermissionKind,
        bundleID: String
    ) -> String {
        let toggle = settingsToggleDisplayName(for: kind)
        switch kind {
        case .postEvent:
            return "Post Events has no Privacy list. Click Request for the CG prompt; Open Accessibility only deep-links. Enable \(bundleID) under Accessibility if listed."
        case .inputMonitoring:
            return "Open Settings only deep-links — it does not register DevType under Input Monitoring. Click Request first, wait for the macOS prompt, then look for \"DevType\" (scroll or use + if needed)."
        case .accessibility:
            return "Open Settings only deep-links — it does not register the app. If \(toggle) does not list \(bundleID) yet, click Request first, then enable that exact entry."
        }
    }

    public static func notListedInSettingsGuidance(
        for kind: PermissionKind,
        bundleID: String,
        appPath: String,
        siblingPaths: [String],
        binaryPath: String? = nil
    ) -> String {
        let toggle = settingsToggleDisplayName(for: kind)
        let resolvedBinary = binaryPath ?? ProcessIdentity.executablePath(forAppBundlePath: appPath)
        var lines: [String] = []

        switch kind {
        case .postEvent:
            lines.append(
                "Post Events is not a Settings list — use Request for the CG prompt, then enable Accessibility for \(bundleID)."
            )
        case .inputMonitoring:
            lines.append(
                "If Input Monitoring opens but DevType is absent: click Request in DevType, wait for the macOS prompt (Allow or dismiss), then look for \"DevType\" under Input Monitoring — scroll the list if needed. On some macOS versions use the + button and choose this app."
            )
            lines.append("Look for \(bundleID) or the name \"DevType\".")
        case .accessibility:
            lines.append(
                "If \(toggle) is empty or missing DevType: click Request first (registers this process), look for \(bundleID), enable it, then return here. Newly granted Accessibility may require Relaunch."
            )
        }

        lines.append("App path: \(appPath)")
        lines.append("Binary: \(resolvedBinary)")

        if let unpackaged = ProcessIdentity.unpackagedBinaryWarning(bundlePath: appPath) {
            lines.append(unpackaged)
        }
        if let dup = ProcessIdentity.duplicateProcessWarning(siblingPaths: siblingPaths) {
            lines.append(dup)
        } else {
            lines.append(
                "Quit duplicate DevType copies, then re-open \(ProcessIdentity.preferredInstalledAppPath) (or \(ProcessIdentity.developmentAppPathHint) while developing) if the list still looks wrong."
            )
        }

        return lines.joined(separator: "\n")
    }

    public static func settingsOpenFailureMessage(for kind: PermissionKind?) -> String {
        let pane: String
        switch kind {
        case .accessibility:
            pane = "Accessibility"
        case .inputMonitoring:
            pane = "Input Monitoring"
        case .postEvent:
            pane = "Accessibility (Post Events has no dedicated pane)"
        case .none:
            pane = "Privacy & Security"
        }
        return "Could not open System Settings automatically. Open \(manualPrivacySecurityPath) → \(pane) manually, then enable DevType (\(expectedBundleIdentifier))."
    }

    public static func binaryChangedGuidance(appPath: String, cdHash: String?) -> String {
        var lines = [
            "Binary identity changed (re-signed or different path) — re-enable permissions for this copy.",
            "Prefer \(ProcessIdentity.preferredInstalledAppPath); use \(ProcessIdentity.developmentAppPathHint) only while developing. Avoid re-packaging unless the binary changed.",
            "App path: \(appPath)"
        ]
        if let cdHash, !cdHash.isEmpty {
            lines.append("CDHash: \(cdHash)")
        }
        return lines.joined(separator: " ")
    }

    public static func degradedInjectTooltip(snapshot: PermissionSnapshot) -> String {
        var parts: [String] = []
        if !snapshot.canUseAX {
            parts.append("Accessibility missing — expansions refused (fail-closed)")
        }
        if !snapshot.canPostEvents {
            parts.append("Post Events missing — terminal paste / HID cursor disabled")
        }
        return parts.joined(separator: ". ")
    }

    /// LIVE CG/AX preflight line for Recovery / Setup (not Settings toggle state).
    public static func livePreflightSummary(snapshot: PermissionSnapshot) -> String {
        func label(_ granted: Bool) -> String { granted ? "Granted" : "Denied" }
        return "LIVE preflight — Listen: \(label(snapshot.canListenTap)) · AX: \(label(snapshot.canUseAX)) · Post: \(label(snapshot.canPostEvents))"
    }

    /// Distinct from "permissions denied": Listen+AX preflight OK but tapCreate failed.
    public static var tapCreateFailedDespiteListenGuidance: String {
        EngineDisplayStatus.tapFailedRecoveryGuidance
    }

    /// Settings toggles look ON but LIVE CG/AX preflight is still denied — classic stale
    /// CDHash-pinned grant after an ad-hoc resign. Point at the reset helper.
    public static var staleTCCRecordGuidance: String {
        """
        LIVE preflight still denies this capability while a Settings toggle may look ON. That usually means the stored TCC row authorizes an older code identity. Quit DevType, run Scripts/reset-tcc.sh, reopen \(ProcessIdentity.preferredInstalledAppPath), then click Request again (and remove any stale DevType row with the minus button if it remains).
        """
    }

    public static func relaunchAfterSettingsGuidance(missingNames: [String]) -> String {
        let what = missingNames.isEmpty ? "permissions" : missingNames.joined(separator: ", ")
        return "Settings toggles may have changed but LIVE preflight still denies \(what). Click Relaunch DevType — macOS often requires a relaunch after flipping Privacy toggles."
    }

    public static var staleLegacyBundleIdGuidance: String {
        """
        Privacy lists may still show \(ProcessIdentity.legacyStaleBundleIdentifier) (old identity). That entry does not grant \(ProcessIdentity.expectedBundleIdentifier). Remove the stale row, Request again for \(ProcessIdentity.preferredInstalledAppPath), enable that entry, then Relaunch.
        """
    }
}
