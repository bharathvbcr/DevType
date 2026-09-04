import AppKit
import Cocoa
import Foundation

/// Deep-links System Settings Privacy panes without terminating or otherwise changing the
/// lifecycle of another app. `didOpen` means macOS accepted one of the URLs; System Settings
/// does not expose an API that proves which pane it ultimately displayed.
public final class SettingsDeepLinker {
    public static let shared = SettingsDeepLinker()

    public struct OpenResult: Equatable {
        public let modernURL: URL
        public let legacyURL: URL
        public let usedModern: Bool
        public let didOpen: Bool

        public init(modernURL: URL, legacyURL: URL, usedModern: Bool, didOpen: Bool) {
            self.modernURL = modernURL
            self.legacyURL = legacyURL
            self.usedModern = usedModern
            self.didOpen = didOpen
        }
    }

    /// Bundle IDs for System Settings / System Preferences across macOS versions.
    public static let systemSettingsBundleIdentifiers: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.Preferences"
    ]

    private let openURL: (URL) -> Bool

    public convenience init() {
        self.init(openURL: { NSWorkspace.shared.open($0) })
    }

    public init(openURL: @escaping (URL) -> Bool) {
        self.openURL = openURL
    }

    public static let modernPrivacySecurityScheme = PermissionCopy.modernPrivacySecurityScheme
    public static let legacySecurityScheme = PermissionCopy.legacySecurityScheme

    /// Canonical `Privacy_*` reveal key for System Settings (nil → Privacy & Security root).
    /// Post Event has no dedicated pane — returns Accessibility.
    public static func privacyRevealKey(for kind: PermissionKind?) -> String? {
        switch kind {
        case .accessibility, .postEvent:
            return "Privacy_Accessibility"
        case .inputMonitoring:
            return "Privacy_ListenEvent"
        case .microphone:
            return "Privacy_Microphone"
        case .speechRecognition:
            return "Privacy_SpeechRecognition"
        case .none:
            return nil
        }
    }

    /// Builds preferred (modern) and fallback (legacy) Settings URLs.
    /// Post Event has no dedicated pane — both URLs point at Accessibility.
    public static func settingsURLs(for kind: PermissionKind?) -> (modern: URL, legacy: URL) {
        let modernQuery = privacyRevealKey(for: kind) ?? ""
        let legacyQuery = privacyRevealKey(for: kind) ?? "Privacy"

        let modernString: String
        if modernQuery.isEmpty {
            modernString = modernPrivacySecurityScheme
        } else {
            modernString = "\(modernPrivacySecurityScheme)?\(modernQuery)"
        }

        let legacyString: String
        if legacyQuery.isEmpty {
            legacyString = legacySecurityScheme
        } else {
            legacyString = "\(legacySecurityScheme)?\(legacyQuery)"
        }

        guard let modern = URL(string: modernString), let legacy = URL(string: legacyString) else {
            return (URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/"))
        }
        return (modern, legacy)
    }

    /// Prefer Input Monitoring when listen is missing; Accessibility when AX missing;
    /// Post Events (→ Open Accessibility) when only Post is missing.
    public static func preferredKindForMissingCapabilities(
        canListenTap: Bool,
        canUseAX: Bool,
        canPostEvents: Bool = true
    ) -> PermissionKind? {
        if !canListenTap { return .inputMonitoring }
        if !canUseAX { return .accessibility }
        if !canPostEvents { return .postEvent }
        return nil
    }

    /// Opens the modern deep link immediately, with one legacy fallback when macOS rejects it.
    public func open(for kind: PermissionKind? = nil, completion: ((OpenResult) -> Void)? = nil) {
        let kindLabel = kind.map { DevTypeLog.kindName($0) } ?? "PrivacyRoot"
        let urls = Self.settingsURLs(for: kind)
        DevTypeLog.permission.info(
            "[Permission] open Settings begin kind=\(kindLabel, privacy: .public) modernURL=\(urls.modern.absoluteString, privacy: .public) reveal=\(Self.privacyRevealKey(for: kind) ?? "root", privacy: .public)"
        )
        let result = performOpen(urls: urls, kindLabel: kindLabel)
        completion?(result)
    }

    private func performOpen(urls: (modern: URL, legacy: URL), kindLabel: String) -> OpenResult {
        if openURL(urls.modern) {
            DevTypeLog.permission.info(
                "[Permission] open Settings result kind=\(kindLabel, privacy: .public) urlAccepted=true usedModern=true"
            )
            return OpenResult(
                modernURL: urls.modern,
                legacyURL: urls.legacy,
                usedModern: true,
                didOpen: true
            )
        }
        let legacyOpened = openURL(urls.legacy)
        if legacyOpened {
            DevTypeLog.permission.info(
                "[Permission] open Settings result kind=\(kindLabel, privacy: .public) urlAccepted=true usedModern=false legacyURL=\(urls.legacy.absoluteString, privacy: .public)"
            )
        } else {
            DevTypeLog.permission.error(
                "[Permission] open Settings failed kind=\(kindLabel, privacy: .public) modern=\(urls.modern.absoluteString, privacy: .public) legacy=\(urls.legacy.absoluteString, privacy: .public)"
            )
        }
        return OpenResult(
            modernURL: urls.modern,
            legacyURL: urls.legacy,
            usedModern: false,
            didOpen: legacyOpened
        )
    }

    /// Kept for callers that close permission UI; opening is now synchronous and has no pending work.
    public func cancelPendingOpen() {}
}
