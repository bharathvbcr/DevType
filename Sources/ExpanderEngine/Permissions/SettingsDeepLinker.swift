import Cocoa
import Foundation

/// Deep-links System Settings Privacy panes. Never returns provisional `didOpen: true`.
///
/// On macOS 13+/27, System Settings often **ignores** a second `Privacy_*` deep link while it
/// is already open on another privacy sub-pane (e.g. Input Monitoring → Accessibility stays
/// stuck). `open(for:)` therefore quits System Settings first when it is running, then opens
/// the target URL so the correct pane appears.
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

    /// Single-flight token: a newer `open` invalidates in-flight prepare/open work.
    private var openGeneration: UInt64 = 0
    private var pendingPrepareWorkItem: DispatchWorkItem?

    public init() {}

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

    /// Soft-quit timeout before a single force-terminate attempt (longer = less aggressive UX).
    public static let softTerminateTimeout: TimeInterval = 3.0

    /// Quits running System Settings asynchronously, then invokes `completion` on the main queue.
    /// Uses timed polling (no main-thread `Thread.sleep`). Honors `generation` for single-flight.
    /// Prefers a longer soft terminate; force-quits at most once after timeout.
    public func prepareForDeepLinkAsync(
        timeout: TimeInterval = SettingsDeepLinker.softTerminateTimeout,
        generation: UInt64,
        completion: @escaping () -> Void
    ) {
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return Self.systemSettingsBundleIdentifiers.contains(id)
        }
        guard !running.isEmpty else {
            completion()
            return
        }

        DevTypeLog.permission.info(
            "[Permission] open Settings prepare: soft-quitting \(running.count, privacy: .public) System Settings instance(s) (timeout=\(timeout, privacy: .public)s) so Privacy deep link can navigate"
        )
        for app in running {
            app.terminate()
        }

        let deadline = Date().addingTimeInterval(max(0.5, timeout))
        schedulePreparePoll(deadline: deadline, generation: generation, forceAttempted: false, completion: completion)
    }

    private func schedulePreparePoll(
        deadline: Date,
        generation: UInt64,
        forceAttempted: Bool,
        completion: @escaping () -> Void
    ) {
        pendingPrepareWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.openGeneration else {
                DevTypeLog.permission.debug("[Permission] open Settings prepare discarded (stale generation)")
                return
            }

            let still = NSWorkspace.shared.runningApplications.contains { app in
                guard let id = app.bundleIdentifier else { return false }
                return Self.systemSettingsBundleIdentifiers.contains(id)
            }

            if !still {
                self.pendingPrepareWorkItem = nil
                completion()
                return
            }

            if Date() < deadline {
                self.schedulePreparePoll(
                    deadline: deadline,
                    generation: generation,
                    forceAttempted: forceAttempted,
                    completion: completion
                )
                return
            }

            if !forceAttempted {
                let leftover = NSWorkspace.shared.runningApplications.filter { app in
                    guard let id = app.bundleIdentifier else { return false }
                    return Self.systemSettingsBundleIdentifiers.contains(id)
                }
                // One force attempt only after soft timeout — prefer soft quit for UX.
                if let app = leftover.first {
                    DevTypeLog.permission.notice(
                        "[Permission] open Settings prepare: soft quit timed out — force-terminating System Settings once"
                    )
                    app.forceTerminate()
                }
                // Brief settle after force-quit, still async.
                self.pendingPrepareWorkItem = nil
                let settle = DispatchWorkItem { [weak self] in
                    guard let self, generation == self.openGeneration else { return }
                    self.pendingPrepareWorkItem = nil
                    completion()
                }
                self.pendingPrepareWorkItem = settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: settle)
                return
            }

            self.pendingPrepareWorkItem = nil
            completion()
        }
        pendingPrepareWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Opens Settings after async quit-before-open prepare. Single-flight: a newer open cancels prior work.
    public func open(for kind: PermissionKind? = nil, completion: ((OpenResult) -> Void)? = nil) {
        cancelPendingOpen()
        openGeneration &+= 1
        let generation = openGeneration
        let kindLabel = kind.map { DevTypeLog.kindName($0) } ?? "PrivacyRoot"
        let urls = Self.settingsURLs(for: kind)
        DevTypeLog.permission.info(
            "[Permission] open Settings begin kind=\(kindLabel, privacy: .public) modernURL=\(urls.modern.absoluteString, privacy: .public) reveal=\(Self.privacyRevealKey(for: kind) ?? "root", privacy: .public) generation=\(generation, privacy: .public)"
        )

        prepareForDeepLinkAsync(timeout: Self.softTerminateTimeout, generation: generation) { [weak self] in
            guard let self else { return }
            guard generation == self.openGeneration else {
                DevTypeLog.permission.debug(
                    "[Permission] open Settings aborted kind=\(kindLabel, privacy: .public) (superseded)"
                )
                return
            }
            let result = self.performOpen(urls: urls, kindLabel: kindLabel)
            completion?(result)
        }
    }

    private func performOpen(urls: (modern: URL, legacy: URL), kindLabel: String) -> OpenResult {
        if NSWorkspace.shared.open(urls.modern) {
            DevTypeLog.permission.info(
                "[Permission] open Settings result kind=\(kindLabel, privacy: .public) didOpen=true usedModern=true"
            )
            return OpenResult(
                modernURL: urls.modern,
                legacyURL: urls.legacy,
                usedModern: true,
                didOpen: true
            )
        }
        let legacyOpened = NSWorkspace.shared.open(urls.legacy)
        if legacyOpened {
            DevTypeLog.permission.info(
                "[Permission] open Settings result kind=\(kindLabel, privacy: .public) didOpen=true usedModern=false legacyURL=\(urls.legacy.absoluteString, privacy: .public)"
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

    public func cancelPendingOpen() {
        if pendingPrepareWorkItem != nil {
            DevTypeLog.permission.debug("[Permission] open Settings pending cancelled")
        }
        pendingPrepareWorkItem?.cancel()
        pendingPrepareWorkItem = nil
        openGeneration &+= 1
    }
}
