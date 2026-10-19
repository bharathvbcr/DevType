import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

extension AppDelegate {
    /// §4.8 / §1.10: unified import — one panel, format auto-detected, `.merge`
    /// mode, localized result. The duplicate copy in the manager now calls the
    /// same flow.
    @objc func importSnippets(_ sender: Any?) {
        SnippetImportFlow.present(from: nil)
    }

    /// §0.4: export — JSON / Espanso YAML / CSV via `NSSavePanel`.
    @objc func exportSnippets(_ sender: Any?) {
        LibraryExporter.present(from: nil)
    }

    /// §4.1: the settings window ⌘, now opens.
    @objc func openPreferences(_ sender: Any?) {
        openPreferences(sender, tab: nil)
    }

    func openPreferences(_ sender: Any?, tab: PreferencesTab?) {
        PreferencesWindowController.shared.show(tab: tab, hotkeyManager: hotkeyManager)
    }

    func warnIfCompetitorExpandersRunning() {
        let apps = NSWorkspace.shared.runningApplications
        for competitor in RunningAppCheck.warnedAtLaunch {
            let running = apps.contains {
                competitor.matches(bundleID: $0.bundleIdentifier, name: $0.localizedName)
            }
            guard running else { continue }
            DevTypeAlert.warn(
                title: loc.s(competitor.alertTitleKey),
                message: loc.s(competitor.alertMessageKey)
            )
        }
    }

    /// §0.3: this used to tell the user their library "was replaced with
    /// defaults" — which the store no longer does, and which offered no recovery
    /// path. `LibraryHealthMonitor` now owns the read/write/conflict state, and
    /// the escalation offers Reveal Backup / Retry / Overwrite-with-defaults.
    func presentLibraryHealthIfNeeded() {
        let monitor = LibraryHealthMonitor.shared
        monitor.start()
        libraryHealthToken = monitor.addObserver { [weak self] condition in
            guard let self else { return }
            self.refreshStatusItemUI()
            guard let condition else { return }
            let activityIssue: ActivitySignal.LibraryIssue
            let affectedCount: Int?
            switch condition {
            case .readBlocked:
                activityIssue = .readBlocked
                affectedCount = nil
            case .corrupted:
                activityIssue = .corrupted
                affectedCount = nil
            case .emptyFile:
                activityIssue = .emptyFile
                affectedCount = nil
            case .saveFailed:
                activityIssue = .saveFailed
                affectedCount = nil
            case .conflicts(let versions):
                activityIssue = .conflicts
                affectedCount = versions.count
            }
            ActivityHistoryStore.publish(
                .libraryIssue(activityIssue, affectedCount: affectedCount)
            )
            // Only a hard read block interrupts at launch; save failures and
            // iCloud conflicts ride the non-modal banner in the manager window.
            switch condition {
            case .readBlocked, .corrupted, .emptyFile:
                guard !self.libraryAlertShown else { return }
                self.libraryAlertShown = true
                // Deferred: `addObserver` fires synchronously, and running a
                // modal inside `applicationDidFinishLaunching` blocks launch.
                DispatchQueue.main.async {
                    LibraryHealthPresenter.present(condition, window: nil)
                }
            case .saveFailed, .conflicts:
                break
            }
        }
    }

    func presentTapFailedAlert() {
        // The wizard drives `refresh(presentTapFailureAlert: true)` from Request, Open Settings,
        // and each Verify/Done render, so a machine that cannot install the tap would throw a
        // modal alert in front of Setup repeatedly — over the one screen already reporting
        // "Tap: not running" and offering the fix. Setup speaks for itself while it is open.
        if isOnboardingVisible || isPermissionRecoveryVisible {
            DevTypeLog.eventTap.notice(
                "[EventTap] tap start failed while a permission UI is open — deferring to its inline status"
            )
            return
        }
        let permissionCopy = PermissionCopy.localized(using: loc)
        DevTypeAlert.present(
            title: loc.s("alert.tapFailed.title"),
            message: permissionCopy.tapCreateFailedDespiteListenGuidance,
            style: .critical,
            buttons: [loc.s("alert.tapFailed.openRecovery"), loc.s("common.ok")]
        ) { [weak self] index in
            guard let self else { return }
            DevTypeLog.eventTap.notice(
                "[EventTap] Tap Failed alert dismissed openRecovery=\(index == 0, privacy: .public)"
            )
            if index == 0 { self.openPermissionRecovery(nil) }
            self.refreshStatusItemUI()
        }
    }

    func startSecureInputMonitoring() {
        SecureInputMonitor.shared.startMonitoring(interval: 0.35) { [weak self] _ in
            // The notification is a wake-up, not an authoritative queued snapshot.
            self?.refreshStatusItemUI()
        }
    }
}
