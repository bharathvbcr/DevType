import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

// MARK: - Main Application Delegate
public final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var statusItemContext = StatusItemContext()
    var statusMenu: NSMenu?
    var statusItemInteraction: StatusItemInteraction?
    var menuRebuildPending = false
    var secretsSubmenu: NSMenu?
    var secretWindowController: NSWindowController?
    var nestedResolverCache: (revision: UInt64, resolver: NestedSnippetResolver)?
    var snippetWindowController: NSWindowController?
    var snippetManagerRenderedLanguage: AppLanguage?
    var permissionWindowController: NSWindowController?
    var onboardingWindowController: NSWindowController?
    var statusToggleMenuItem: NSMenuItem?
    /// Shown only while `lastRecordedInjectOutcome` is a refuse/failure. See `refreshStatusItemUI`.
    var restartEngineMenuItem: NSMenuItem?
    var permissionRecoveryMenuItem: NSMenuItem?
    var diagnosticsMenuItem: NSMenuItem?
    var openAtLoginMenuItem: NSMenuItem?
    var inlineSearchMenuItem: NSMenuItem?
    var smartDictationMenuItem: NSMenuItem?
    var shortcutsToggleMenuItem: NSMenuItem?
    var conflictsToggleMenuItem: NSMenuItem?
    var menuHeaderStatusPill: PillBadgeView?
    /// §5.1: the custom menu-header view whose AX label tracks the status pill.
    var menuHeaderAccessibilityHost: NSView?
    var menuHeaderVersion = "1.0.0"
    var recentSubmenu: NSMenu?
    /// IDs only: each menu rebuild and click resolves through the live library so edits,
    /// disables, deletions, and secret conversions cannot insert a stale snapshot.
    var recentSnippetIDs: [UUID] = []
    var lastTapStartFailed = false
    var lastLoggedDisplayStatus: EngineDisplayStatus?
    /// The palette AI action whose focus wait / selection read may still act. Main-thread only.
    var paletteAIGeneration: UInt64 = 0
    /// Single-flight: launch + CDHash callback must not open Setup twice.
    var onboardingPresentationInFlight = false
    /// Set when the user dismisses Setup without completing it (Skip, or closing the window).
    ///
    /// `presentOnboardingOrRecoveryIfNeeded()` runs twice per launch — once directly, once from
    /// `onIdentityResolved` after `codesign` returns. Skipping only closes the window; it
    /// deliberately does not record completion. So a user who skipped before the hash resolved got
    /// the wizard thrown back in their face a beat later, on top of whatever they had moved on to.
    /// The latch is per-launch: the next launch still offers Setup, as it should.
    var onboardingDismissedThisLaunch = false
    /// True while the Setup window is on screen. Recovery and the Tap Failed alert both defer to
    /// it rather than stacking a second permission surface over the first-run flow.
    var isOnboardingVisible: Bool {
        onboardingWindowController?.window?.isVisible == true
    }
    /// Recovery already renders the failed tap, identity, and remediation actions inline. A
    /// second app-modal Tap Failed alert over that window blocks the very controls needed to fix
    /// the problem and can be re-created by each capability refresh.
    var isPermissionRecoveryVisible: Bool {
        permissionWindowController?.window?.isVisible == true
    }
    /// Token for the Setup window's close observer, so re-creating the window cannot register a
    /// second one against the same notification.
    var onboardingCloseObserver: NSObjectProtocol?
    let hotkeyManager = HotkeyManager()
    let loc = LocalizationManager.shared
    /// §5.2: token for the `accessibilityDisplayOptionsDidChange` observer.
    private var accessibilityObserver: NSObjectProtocol?
    /// §0.3: banner/alert state for an unreadable, unwritable, or conflicted library.
    var libraryHealthToken: UUID?
    /// One launch-time escalation per run, not one per observer callback.
    var libraryAlertShown = false
    var activityTransitionTracker = ActivityTransitionTracker()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        UncleanExitSentinel.noteLaunch()
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        installLastResortExceptionLogger()
        installEditMenu()

        // §4.5: one-time migration of the legacy per-snippet `usageCount` field
        // into the coalesced sidecar the stats pane reads from.
        SnippetStore.shared.migrateLegacyUsageCounts()

        // Bound rolling library backups and conflict-recovery folders once per launch. Both
        // passes run on utility queues; a failed pass is retried by the next trigger.
        SnippetStore.shared.scheduleRecoveryMaintenance()

        // §8.11: sweep keychain-resident secrets into the encrypted archive. Launch is the
        // moment v2 items are silently readable by the running identity, so this never shows
        // a dialog — after it, copies read the archive and touch no keychain at all.
        // Off the main thread because securityd can *stall* (not just fail) on items with a
        // mismatched identity — measured with a probe; launch must be unwedgeable.
        DispatchQueue.global(qos: .utility).async {
            SecretStore.shared.consolidateSecrets()
            // A failed destructive sweep from a prior run is not represented in the library
            // file, so waiting for another user save would retain that orphan forever. Sweep on
            // every launch after consolidation; failures remain aggregate-only in diagnostics
            // and can be retried from Advanced > Maintenance.
            self.requestOrphanSecretCleanupRetryRefreshingPreferences()
        }

        let identity = ProcessIdentity.shared
        DevTypeLog.app.info(
            "[App] launch bundleID=\(DevTypeLog.boundedPublicIdentifier(identity.bundleIdentifier, label: "bundleID"), privacy: .public) packaged=\(identity.isPackaged, privacy: .public) \(DevTypeLog.publicPathMetadata(identity.bundlePath), privacy: .public)"
        )

        setupStatusItem()
        bindSnippetStore()
        wireExpansionUsage()
        wireRepetitionSuggestions()
        registerHotkeys()
        wireSecureClipboardPasteHint()
        presentLibraryHealthIfNeeded()
        startSecureInputMonitoring()
        syncSelectionMonitorWithAIPreferences()
        wireTapHealth()
        // §9.1: start mirroring the unified log into process memory immediately, so the
        // diagnostic report can answer for incidents older than what logd retains.
        DevLogMirror.shared.start()

        // §7.5: no-op unless the user opted in AND a day has passed. It reports only a genuine
        // update — never a failure — so a launch without connectivity stays silent. Async and
        // off the launch path: a slow DNS lookup must not delay the status item appearing.
        UpdateFlow.checkAutomaticallyIfDue()

        NotificationCenter.default.addObserver(
            forName: .devTypeLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.installEditMenu(force: true)
            self?.rebuildMenu()
            PreferencesWindowController.shared.refreshLocalization()
            self?.refreshSnippetManagerLocalization()
            if let recovery = self?.permissionWindowController?.contentViewController
                as? PermissionRecoveryController,
               recovery.view.window?.isVisible == true {
                recovery.refreshLocalization()
            }
            if let onboarding = self?.onboardingWindowController?.contentViewController
                as? PermissionOnboardingController,
               onboarding.view.window?.isVisible == true {
                onboarding.refreshLocalization()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .devTypePreferencesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateDynamicMenuItems()
        }

        // §5.2: Differentiate Without Color / Reduce Motion / Reduce Transparency
        // / Increase Contrast can all change while we run. Nothing in `Sources/`
        // used to observe them at all.
        accessibilityObserver = DevTypeAccessibility.observeDisplayOptions { [weak self] in
            self?.refreshStatusItemUI()
        }

        PermissionCoordinator.shared.start(
            onStatusChanged: { [weak self] status in
                self?.handleCoordinatorStatus(status)
            },
            onTapStartFailed: { [weak self] in
                guard let self else { return }
                self.lastTapStartFailed = true
                DevTypeLog.permission.error(
                    "[Permission] tap start failed — presenting Tap Failed alert"
                )
                self.presentTapFailedAlert()
            },
            onIdentityResolved: { [weak self] hash in
                ProcessIdentity.backfillOnboardingCDHashIfNeeded(currentCDHash: hash)
                // Re-evaluate after nil→hash race; may open Recovery on identity change.
                self?.presentOnboardingOrRecoveryIfNeeded()
            }
        )

        presentOnboardingOrRecoveryIfNeeded()
        warnIfCompetitorExpandersRunning()
        // Tap-failure alert is wired via coordinator `onTapStartFailed` (start + Finish refresh).
        refreshStatusItemUI()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        PermissionCoordinator.shared.handleApplicationDidBecomeActive()
        if SnippetStore.shared.pendingSecretCleanupCount > 0 {
            requestOrphanSecretCleanupRetryRefreshingPreferences()
        }
        if let recovery = permissionWindowController?.contentViewController as? PermissionRecoveryController {
            recovery.refreshFromAppActivation()
        }
        if let onboarding = onboardingWindowController?.contentViewController as? PermissionOnboardingController {
            onboarding.refreshFromAppActivation()
        }
        if PreferencesWindowController.shared.window?.isVisible == true {
            PreferencesWindowController.shared.refreshPermissionState()
        }
        refreshStatusItemUI()
    }

    /// §4.5: usage counters live in a coalesced sidecar now — flush the tail of
    /// the current session so a quit does not lose the last few expansions.
    public func applicationDidResignActive(_ notification: Notification) {
        // Drop any standing Touch ID authorization when DevType goes to the background. The reuse
        // window exists so copying two secrets in a row is one prompt, not so that walking away
        // and coming back is still covered by a check made before you left.
        BiometricGate.shared.invalidate()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // A server DevType spawned must not outlive it.
        WhisperServerController.shared.stopIfManaged()

        // Before anything else can fail: quitting must not be the way a copied secret outlives
        // its clear timer, which dies with the process. Still guarded by change-count ownership,
        // so quitting never wipes something the user copied after us.
        SecretClipboard.shared.clearIfStillOurs()
        SnippetStore.shared.flushUsageStats()
        EventTapEngine.shared.shutdownTapThread()
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        if let libraryHealthToken {
            LibraryHealthMonitor.shared.removeObserver(libraryHealthToken)
        }
        DevTypeLog.app.info("[App] terminate — usage stats flushed")
        UncleanExitSentinel.noteCleanTermination()
    }
}

// MARK: - Internal test hooks

extension AppDelegate {
    var permissionRecoveryMenuItemForTesting: NSMenuItem? { permissionRecoveryMenuItem }
    var diagnosticsMenuItemForTesting: NSMenuItem? { diagnosticsMenuItem }
    func rebuildMenuForTesting() { rebuildMenu() }
    func refreshStatusItemUIForTesting() { refreshStatusItemUI() }
}
