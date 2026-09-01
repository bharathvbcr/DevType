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

    /// Localized presentation copy for the permission surfaces. The parameterless methods below
    /// remain the stable English diagnostic vocabulary used by engine logs and existing clients;
    /// AppKit surfaces use this value type so a language change cannot leave the recovery wizard
    /// half-translated.
    public struct Localized {
        private let loc: LocalizationManager

        fileprivate init(localization: LocalizationManager) {
            self.loc = localization
        }

        public func unlockDescription(for kind: PermissionKind) -> String {
            loc.s("permission.description.\(kindKey(kind))")
        }

        public func settingsToggleDisplayName(for kind: PermissionKind) -> String {
            switch kind {
            case .accessibility, .postEvent:
                return loc.s("recovery.cap.accessibility")
            case .inputMonitoring:
                return loc.s("recovery.cap.inputMonitoring")
            case .microphone:
                return loc.s("permission.cap.microphone")
            case .speechRecognition:
                return loc.s("permission.cap.speechRecognition")
            }
        }

        public func openSettingsButtonTitle(for kind: PermissionKind) -> String {
            switch kind {
            case .accessibility, .inputMonitoring:
                return loc.s("permission.button.openSettings")
            case .postEvent:
                return loc.s("permission.button.openAccessibility")
            case .microphone:
                return loc.s("permission.button.openMicrophone")
            case .speechRecognition:
                return loc.s("permission.button.openSpeech")
            }
        }

        public func openSettingsWithoutRequestHint(for kind: PermissionKind, bundleID: String) -> String {
            switch kind {
            case .postEvent:
                return loc.s("permission.hint.postEvent", bundleID)
            case .inputMonitoring:
                return loc.s("permission.hint.inputMonitoring")
            case .accessibility:
                return loc.s("permission.hint.accessibility", bundleID)
            case .microphone:
                return loc.s("permission.hint.microphone")
            case .speechRecognition:
                return loc.s("permission.hint.speechRecognition", bundleID)
            }
        }

        public func notListedInSettingsGuidance(
            for kind: PermissionKind,
            bundleID: String,
            appPath: String,
            siblingPaths: [String],
            binaryPath: String? = nil
        ) -> String {
            var lines: [String] = []
            switch kind {
            case .postEvent:
                lines.append(loc.s("permission.notListed.postEvent", bundleID))
            case .inputMonitoring:
                lines.append(loc.s("permission.notListed.inputMonitoring"))
                lines.append(loc.s("permission.notListed.inputLookFor", bundleID))
            case .accessibility:
                lines.append(loc.s("permission.notListed.accessibility", bundleID))
            case .microphone:
                lines.append(loc.s("permission.notListed.microphone"))
            case .speechRecognition:
                lines.append(loc.s("permission.notListed.speechRecognition"))
            }

            let resolvedBinary = binaryPath ?? ProcessIdentity.executablePath(forAppBundlePath: appPath)
            lines.append(loc.s("permission.notListed.appPath", appPath))
            lines.append(loc.s("permission.notListed.binary", resolvedBinary))

            // These two diagnostics are produced by the identity subsystem and intentionally keep
            // their technical wording; the surrounding recovery instructions are localized here.
            if let unpackaged = ProcessIdentity.unpackagedBinaryWarning(bundlePath: appPath) {
                lines.append(unpackaged)
            }
            if let duplicate = ProcessIdentity.duplicateProcessWarning(siblingPaths: siblingPaths) {
                lines.append(duplicate)
            } else {
                lines.append(
                    loc.s(
                        "permission.notListed.quitCopies",
                        ProcessIdentity.preferredInstalledAppPath,
                        ProcessIdentity.developmentAppPathHint
                    )
                )
            }

            return lines.joined(separator: "\n")
        }

        public func settingsOpenFailureMessage(for kind: PermissionKind?) -> String {
            let pane: String
            switch kind {
            case .accessibility:
                pane = settingsToggleDisplayName(for: .accessibility)
            case .inputMonitoring:
                pane = settingsToggleDisplayName(for: .inputMonitoring)
            case .postEvent:
                pane = loc.s("permission.pane.postEvent")
            case .microphone:
                pane = settingsToggleDisplayName(for: .microphone)
            case .speechRecognition:
                pane = settingsToggleDisplayName(for: .speechRecognition)
            case .none:
                pane = loc.s("permission.pane.privacySecurity")
            }
            return loc.s(
                "permission.settings.failure",
                manualPrivacySecurityPath,
                pane,
                expectedBundleIdentifier
            )
        }

        public func binaryChangedGuidance(appPath: String, cdHash: String?) -> String {
            var lines = [
                loc.s("permission.identity.changed"),
                loc.s(
                    "permission.identity.preferPath",
                    ProcessIdentity.preferredInstalledAppPath,
                    ProcessIdentity.developmentAppPathHint
                ),
                loc.s("permission.identity.appPath", appPath)
            ]
            if let cdHash, !cdHash.isEmpty {
                lines.append(loc.s("permission.identity.cdHash", cdHash))
            }
            return lines.joined(separator: " ")
        }

        public func degradedInjectTooltip(snapshot: PermissionSnapshot) -> String {
            var parts: [String] = []
            if !snapshot.canUseAX {
                parts.append(loc.s("permission.degraded.accessibility"))
            }
            if !snapshot.canPostEvents {
                parts.append(loc.s("permission.degraded.postEvents"))
            }
            return parts.joined(separator: ". ")
        }

        public func livePreflightSummary(snapshot: PermissionSnapshot) -> String {
            loc.s(
                "permission.livePreflight",
                snapshot.canListenTap ? loc.s("permission.granted") : loc.s("permission.denied"),
                snapshot.canUseAX ? loc.s("permission.granted") : loc.s("permission.denied"),
                snapshot.canPostEvents ? loc.s("permission.granted") : loc.s("permission.denied")
            )
        }

        public var tapCreateFailedDespiteListenGuidance: String {
            loc.s("permission.tapCreateFailed")
        }

        public func relaunchAfterSettingsGuidance(missingNames: [String]) -> String {
            let what = missingNames.isEmpty
                ? loc.s("permission.capabilities")
                : missingNames.joined(separator: ", ")
            return loc.s("permission.relaunch", what)
        }

        public var staleTCCRecordGuidance: String {
            loc.s("permission.staleTCC", ProcessIdentity.preferredInstalledAppPath)
        }

        public var staleLegacyBundleIdGuidance: String {
            loc.s(
                "permission.staleLegacy",
                ProcessIdentity.legacyStaleBundleIdentifier,
                ProcessIdentity.expectedBundleIdentifier,
                ProcessIdentity.preferredInstalledAppPath
            )
        }

        public func missingCapabilityNames(_ snapshot: PermissionSnapshot) -> [String] {
            snapshot.missingCapabilityNames.map { name in
                switch name {
                case "Accessibility": return loc.s("recovery.cap.accessibility")
                case "Input Monitoring": return loc.s("recovery.cap.inputMonitoring")
                case "Post Events": return loc.s("recovery.cap.postEvents")
                default: return name
                }
            }
        }

        public func missingCapabilitiesSummary(_ snapshot: PermissionSnapshot) -> String {
            let names = missingCapabilityNames(snapshot)
            switch names.count {
            case 0:
                return loc.s("permission.summary.all")
            case 1:
                return loc.s("permission.summary.single", names[0])
            case 2:
                return loc.s("permission.summary.two", names[0], names[1])
            default:
                return loc.s("permission.summary.many", names.dropLast().joined(separator: ", "), names.last ?? "")
            }
        }

        private func kindKey(_ kind: PermissionKind) -> String {
            switch kind {
            case .accessibility: return "accessibility"
            case .inputMonitoring: return "inputMonitoring"
            case .postEvent: return "postEvent"
            case .microphone: return "microphone"
            case .speechRecognition: return "speechRecognition"
            }
        }
    }

    public static func localized(using localization: LocalizationManager = .shared) -> Localized {
        Localized(localization: localization)
    }

    public static func unlockDescription(for kind: PermissionKind) -> String {
        switch kind {
        case .accessibility:
            return "Focused-element context and Accessibility-based text injection. Expansions refuse without it (fail-closed)."
        case .inputMonitoring:
            return "Required for the keyboard event tap — without it, DevType cannot read keystrokes."
        case .postEvent:
            return "Synthetic backspace, paste, and arrow cursor moves. Separate TCC service (may appear under Accessibility). No dedicated Privacy_PostEvent pane."
        case .microphone:
            return "Required for Smart Speech-to-Text and Dictation. Audio stays strictly local on your Mac."
        case .speechRecognition:
            return "Required for on-device fallback speech recognition using Apple Speech framework."
        }
    }

    public static func settingsToggleDisplayName(for kind: PermissionKind) -> String {
        switch kind {
        case .accessibility, .postEvent:
            return "Accessibility"
        case .inputMonitoring:
            return "Input Monitoring"
        case .microphone:
            return "Microphone"
        case .speechRecognition:
            return "Speech Recognition"
        }
    }

    public static func openSettingsButtonTitle(for kind: PermissionKind) -> String {
        switch kind {
        case .accessibility, .inputMonitoring:
            return "Open Settings"
        case .postEvent:
            return "Open Accessibility"
        case .microphone:
            return "Open Microphone Settings"
        case .speechRecognition:
            return "Open Speech Settings"
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
        case .microphone:
            return "Open Settings only deep-links. Click Request Access or trigger Smart Dictation (⌘⌥V) to prompt macOS for Microphone permission."
        case .speechRecognition:
            return "Open Settings only deep-links. Enable \(bundleID) under Speech Recognition if listed."
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
        case .microphone:
            lines.append(
                "If Microphone is empty or missing DevType: click Request Access or use ⌘⌥V to register this process with macOS TCC."
            )
        case .speechRecognition:
            lines.append(
                "If Speech Recognition is empty: trigger smart dictation once to register this process."
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
        case .microphone:
            pane = "Microphone"
        case .speechRecognition:
            pane = "Speech Recognition"
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
