import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

// MARK: - Main Application Delegate
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusItemContext = StatusItemContext()
    private var statusMenu: NSMenu?
    private var statusItemInteraction: StatusItemInteraction?
    private var menuRebuildPending = false
    private var secretsSubmenu: NSMenu?
    private var snippetWindowController: NSWindowController?
    private var snippetManagerRenderedLanguage: AppLanguage?
    private var permissionWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?
    private var statusToggleMenuItem: NSMenuItem?
    /// Shown only while `lastRecordedInjectOutcome` is a refuse/failure. See `refreshStatusItemUI`.
    private var restartEngineMenuItem: NSMenuItem?
    private var permissionRecoveryMenuItem: NSMenuItem?
    private var openAtLoginMenuItem: NSMenuItem?
    private var inlineSearchMenuItem: NSMenuItem?
    private var smartDictationMenuItem: NSMenuItem?
    private var shortcutsToggleMenuItem: NSMenuItem?
    private var conflictsToggleMenuItem: NSMenuItem?
    private var menuHeaderStatusPill: PillBadgeView?
    /// §5.1: the custom menu-header view whose AX label tracks the status pill.
    private var menuHeaderAccessibilityHost: NSView?
    private var menuHeaderVersion = "1.0.0"
    private var recentSubmenu: NSMenu?
    /// IDs only: each menu rebuild and click resolves through the live library so edits,
    /// disables, deletions, and secret conversions cannot insert a stale snapshot.
    private var recentSnippetIDs: [UUID] = []
    private var lastTapStartFailed = false
    private var lastLoggedDisplayStatus: EngineDisplayStatus?
    /// Single-flight: launch + CDHash callback must not open Setup twice.
    private var onboardingPresentationInFlight = false
    /// Set when the user dismisses Setup without completing it (Skip, or closing the window).
    ///
    /// `presentOnboardingOrRecoveryIfNeeded()` runs twice per launch — once directly, once from
    /// `onIdentityResolved` after `codesign` returns. Skipping only closes the window; it
    /// deliberately does not record completion. So a user who skipped before the hash resolved got
    /// the wizard thrown back in their face a beat later, on top of whatever they had moved on to.
    /// The latch is per-launch: the next launch still offers Setup, as it should.
    private var onboardingDismissedThisLaunch = false
    /// True while the Setup window is on screen. Recovery and the Tap Failed alert both defer to
    /// it rather than stacking a second permission surface over the first-run flow.
    private var isOnboardingVisible: Bool {
        onboardingWindowController?.window?.isVisible == true
    }
    /// Recovery already renders the failed tap, identity, and remediation actions inline. A
    /// second app-modal Tap Failed alert over that window blocks the very controls needed to fix
    /// the problem and can be re-created by each capability refresh.
    private var isPermissionRecoveryVisible: Bool {
        permissionWindowController?.window?.isVisible == true
    }
    /// Token for the Setup window's close observer, so re-creating the window cannot register a
    /// second one against the same notification.
    private var onboardingCloseObserver: NSObjectProtocol?
    private let hotkeyManager = HotkeyManager()
    private let loc = LocalizationManager.shared
    /// §5.2: token for the `accessibilityDisplayOptionsDidChange` observer.
    private var accessibilityObserver: NSObjectProtocol?
    /// §0.3: banner/alert state for an unreadable, unwritable, or conflicted library.
    private var libraryHealthToken: UUID?
    /// One launch-time escalation per run, not one per observer callback.
    private var libraryAlertShown = false
    private var activityTransitionTracker = ActivityTransitionTracker()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installLastResortExceptionLogger()
        installEditMenu()

        // §4.5: one-time migration of the legacy per-snippet `usageCount` field
        // into the coalesced sidecar the stats pane reads from.
        SnippetStore.shared.migrateLegacyUsageCounts()

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
        warnIfTextExpanderRunning()
        warnIfEspansoRunning()
        // Tap-failure alert is wired via coordinator `onTapStartFailed` (start + Finish refresh).
        refreshStatusItemUI()
    }

    /// Accessory apps have no NIB-driven main menu, so ⌘Z/⌘X/⌘C/⌘V/⌘A key
    /// equivalents are dropped before they reach text fields in borderless
    /// panels (snippet editor, group editor, fill-in). Installing a minimal
    /// main menu with a standard Edit submenu restores them app-wide — the
    /// menu bar itself stays hidden under the accessory policy.
    private func installEditMenu(force: Bool = false) {
        if !force {
            guard NSApp.mainMenu == nil || NSApp.mainMenu?.numberOfItems == 0 else { return }
        }
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        // §6.1: these were English literals. Prefer AppKit's own already-localized
        // menu titles (so they read exactly like every other Mac app in the user's
        // language) and fall back to our tables when the lookup misses.
        let editMenu = NSMenu(title: systemMenuTitle("Edit", fallback: loc.s("edit.menu")))
        editMenu.addItem(
            withTitle: systemMenuTitle("Undo", fallback: loc.s("edit.undo")),
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        editMenu.addItem(
            withTitle: systemMenuTitle("Redo", fallback: loc.s("edit.redo")),
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: systemMenuTitle("Cut", fallback: loc.s("edit.cut")),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: systemMenuTitle("Copy", fallback: loc.s("edit.copy")),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: systemMenuTitle("Paste", fallback: loc.s("edit.paste")),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: systemMenuTitle("Delete", fallback: loc.s("edit.delete")),
            action: #selector(NSText.delete(_:)),
            keyEquivalent: ""
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: systemMenuTitle("Select All", fallback: loc.s("edit.selectAll")),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    /// §6.1: AppKit ships localized menu-command strings. `localizedString(forKey:
    /// value:table:)` returns `value` when the key is absent, so a miss quietly
    /// falls through to DevType's own translation rather than to English.
    private func systemMenuTitle(_ key: String, fallback: String) -> String {
        guard let appKit = Bundle(identifier: "com.apple.AppKit") else { return fallback }
        return appKit.localizedString(forKey: key, value: fallback, table: "Menus")
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

    /// Automatic launch/activation retries run away from the main thread because securityd may
    /// stall. Their completion still has to invalidate the visible Advanced pane; without this,
    /// the store can be healthy while Preferences indefinitely shows an earlier cleanup failure.
    private func requestOrphanSecretCleanupRetryRefreshingPreferences() {
        SnippetStore.shared.requestOrphanSecretCleanupRetry { _ in
            DispatchQueue.main.async {
                guard PreferencesWindowController.shared.window?.isVisible == true else { return }
                PreferencesWindowController.shared.refreshMaintenanceState()
            }
        }
    }

    private func wireTapHealth() {
        EventTapEngine.shared.onTapHealthChanged = { [weak self] in
            let running = EventTapEngine.shared.isTapRunning
            DevTypeLog.eventTap.notice(
                "[EventTap] health callback tapRunning=\(running, privacy: .public)"
            )
            self?.lastTapStartFailed = !running
            // Re-probe TCC so a revoke becomes Needs Permissions instead of a stuck Tap Failed.
            let snapshot = PermissionProbe().snapshot()
            PermissionCoordinator.shared.refresh(
                presentTapFailureAlert: !running && !snapshot.blocksDefaultEventTap
            )
            self?.refreshStatusItemUI()
        }
    }

    /// Brief menu-bar hint when secure clipboard paste leaves the payload for a manual ⌘V.
    private func wireSecureClipboardPasteHint() {
        TextInjectionPipeline.shared.onSecureClipboardManualPasteHint = { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            let message = TextInjectionPipeline.secureClipboardManualPasteMessage
            button.toolTip = message
            DevTypeLog.app.notice("[App] \(message, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.refreshStatusItemUI()
            }
        }
    }

    private func handleCoordinatorStatus(_ status: PermissionCoordinator.Status) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleCoordinatorStatus(status) }
            return
        }

        for signal in activityTransitionTracker.signals(for: status) {
            ActivityHistoryStore.publish(signal)
        }

        if status.tapRunning {
            lastTapStartFailed = false
        }
        refreshStatusItemUI()
    }

    private func presentOnboardingOrRecoveryIfNeeded() {
        let snapshot = PermissionProbe().snapshot()
        let identity = ProcessIdentity.shared
        let onboardingDone = ProcessIdentity.isOnboardingCompleted()
        let identityChanged = ProcessIdentity.shouldReOnboardForIdentityChange(
            currentCDHash: identity.cachedCodeDirectoryHash,
            currentPath: identity.bundlePath,
            currentDesignatedRequirement: identity.cachedDesignatedRequirementString
        )

        DevTypeLog.permission.info(
            "[Permission] launch UI decision onboardingDone=\(onboardingDone, privacy: .public) identityChanged=\(identityChanged, privacy: .public) \(DevTypeLog.snapshotSummary(snapshot), privacy: .public)"
        )

        if !onboardingDone {
            // Avoid double-scheduling from launch + CDHash callback on the same run loop.
            if isOnboardingVisible || onboardingPresentationInFlight {
                DevTypeLog.permission.debug(
                    "[Permission] UI → skip duplicate onboarding schedule (single-flight)"
                )
                return
            }
            // The user already said "not now" this launch — do not re-present over their work.
            if onboardingDismissedThisLaunch {
                DevTypeLog.permission.info(
                    "[Permission] UI → onboarding dismissed this launch; not re-presenting"
                )
                return
            }
            DevTypeLog.permission.info("[Permission] UI → present onboarding")
            onboardingPresentationInFlight = true
            DispatchQueue.main.async { [weak self] in
                self?.openOnboarding()
            }
        } else if identityChanged {
            // Path or designated-requirement change. If Listen+AX still preflight granted
            // (cert rebuild edge / Settings still valid), refresh stored identity quietly.
            // Otherwise open Recovery so the user can re-grant for the new TCC identity.
            if !snapshot.blocksDefaultEventTap {
                let path = identity.bundlePath
                let hash = identity.cachedCodeDirectoryHash
                let requirement = identity.cachedDesignatedRequirementString
                if let hash, !hash.isEmpty {
                    ProcessIdentity.updateOnboardingIdentity(
                        cdHash: hash,
                        path: path,
                        designatedRequirement: requirement
                    )
                    DevTypeLog.identity.info(
                        "[Identity] identity marker changed but Listen+AX still granted — updated stored onboarding identity (no Recovery)"
                    )
                } else {
                    DevTypeLog.identity.notice(
                        "[Identity] identity marker changed; hash still loading — deferring stored identity update"
                    )
                    ProcessIdentity.shared.refreshCDHashAsync { resolved in
                        guard let resolved, !resolved.isEmpty else { return }
                        ProcessIdentity.updateOnboardingIdentity(
                            cdHash: resolved,
                            path: ProcessIdentity.shared.bundlePath,
                            designatedRequirement: ProcessIdentity.shared.cachedDesignatedRequirementString
                        )
                        DevTypeLog.identity.info(
                            "[Identity] deferred onboarding identity update after CDHash load"
                        )
                    }
                }
                PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
            } else {
                DevTypeLog.identity.notice(
                    "[Identity] path/requirement changed and Listen/AX missing — presenting Permission Recovery"
                )
                DispatchQueue.main.async { [weak self] in
                    self?.openPermissionRecovery(nil)
                }
            }
        } else if snapshot.blocksDefaultEventTap {
            DevTypeLog.permission.info(
                "[Permission] UI → present recovery (\(DevTypeLog.snapshotSummary(snapshot), privacy: .public))"
            )
            DispatchQueue.main.async { [weak self] in
                self?.openPermissionRecovery(nil)
            }
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = DevTypeTheme.statusItemImage(
                badge: (.paused, DevTypeTheme.statusGray),
                accessibilityLabel: loc.s("status.paused")
            )
            button.imagePosition = .imageOnly
            // §5.1: the app's only permanent affordance used to set image +
            // imagePosition and nothing else — completely unlabeled over AX.
            button.setAccessibilityRole(NSAccessibility.Role.menuButton)
            button.setAccessibilityLabel(loc.s("ax.status.item"))
            button.setAccessibilityHelp(loc.s("ax.status.item.help", loc.s("status.paused")))
        }
        statusMenu = buildMenu()
        if let button = statusItem?.button {
            statusItemInteraction = StatusItemInteraction(
                button: button,
                offersCopySecret: { [weak self] in
                    // Honor the visible action even if the click releases Secure Input.
                    self?.statusItemContext.offersCopySecret == true
                        || AXContextChecker.isSecureEventInputEnabledLive()
                },
                openSearchSecrets: { [weak self] in self?.openSecretSearch(nil) },
                openMenu: { [weak self] button in self?.showStatusMenu(from: button) }
            )
        }
        // Do not refresh here — Listen+AX can already be granted while the tap is not
        // installed yet. Refreshing would flash Tap Failed before coordinator.start().
    }

    private func rebuildMenu() {
        guard !statusItemContext.menuIsOpen else {
            menuRebuildPending = true
            refreshStatusItemUI()
            return
        }
        menuRebuildPending = false
        statusMenu = buildMenu()
        refreshStatusItemUI()
    }

    private func makeMenuHeaderView() -> NSView {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 252, height: 58))

        let logo = NSImageView()
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.image = DevTypeTheme.load3DLogoImage(size: NSSize(width: 34, height: 34))
        logo.wantsLayer = true
        logo.layer?.cornerRadius = 8
        logo.layer?.masksToBounds = true
        logo.layer?.borderColor = DevTypeTheme.accent.withAlphaComponent(0.40).cgColor
        logo.layer?.borderWidth = 1

        let titleLabel = DevTypeTheme.makeLabel("DevType", font: DevTypeTheme.font(13.5, .bold), color: DevTypeTheme.textPrimary)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let versionLabel = DevTypeTheme.makeLabel("v\(version)", font: DevTypeTheme.font(10, .medium), color: DevTypeTheme.textTertiary)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        let pill = PillBadgeView(text: loc.s("status.active"), tint: DevTypeTheme.statusGreen, showsDot: true)
        menuHeaderStatusPill = pill

        wrapper.addSubview(logo)
        wrapper.addSubview(titleLabel)
        wrapper.addSubview(versionLabel)
        wrapper.addSubview(pill)

        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 14),
            logo.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 34),
            logo.heightAnchor.constraint(equalToConstant: 34),

            titleLabel.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: logo.topAnchor, constant: 1),

            versionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            versionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),

            pill.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -10),
            pill.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8)
        ])
        // §5.1: a custom `NSMenuItem.view` is AX-invisible unless it is labelled.
        // Collapse the lockup into one utterance carrying version + status.
        wrapper.dtHideSubviewsFromAccessibility()
        wrapper.dtApplyAccessibility(
            role: NSAccessibility.Role.group,
            label: loc.s("ax.menu.header", version, loc.s("status.active"))
        )
        menuHeaderAccessibilityHost = wrapper
        menuHeaderVersion = version
        return wrapper
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let headerItem = NSMenuItem()
        headerItem.view = makeMenuHeaderView()
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        func item(
            _ title: String,
            _ symbol: String,
            _ action: Selector,
            key: String = "",
            modifiers: NSEvent.ModifierFlags = .command
        ) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.target = self
            menuItem.image = DevTypeTheme.menuIcon(symbol)
            if !key.isEmpty { menuItem.keyEquivalentModifierMask = modifiers }
            return menuItem
        }

        // §4.1: ⌘, is the platform convention for settings. It used to open the
        // snippet manager; the manager moves to ⌘⇧M.
        menu.addItem(item(loc.s("menu.preferences"), "slider.horizontal.3", #selector(openPreferences(_:)), key: ","))
        menu.addItem(item(
            loc.s("menu.manage"),
            "square.stack.3d.up",
            #selector(openSnippetManager(_:)),
            key: "M",
            modifiers: [.command, .shift]
        ))
        let inlineItem = item(
            loc.s("menu.inlineSearch"),
            "magnifyingglass",
            #selector(toggleInlineSearch(_:)),
            key: hotkeyMenuKeyEquivalent(),
            modifiers: hotkeyMenuModifiers()
        )
        menu.addItem(inlineItem)
        inlineSearchMenuItem = inlineItem

        let dictationItem = item(
            loc.s("menu.smartDictation"),
            "waveform.and.mic",
            #selector(startSmartDictation(_:)),
            key: voiceMenuKeyEquivalent(),
            modifiers: voiceMenuModifiers()
        )
        menu.addItem(dictationItem)
        smartDictationMenuItem = dictationItem
        // The two secure-field routes. Neither needs a keystroke DevType has to observe: the menu
        // is driven by the mouse, the clipboard write is an API call, and the ⌘V is the user's own
        // key going to their own app. That is the whole reason these exist — inside a password
        // field Secure Input withholds keyboard events from our tap *and* from hotkey
        // registration, so the palette shortcut above simply never fires there.
        menu.addItem(item(
            loc.s("menu.copySnippet"),
            "doc.on.clipboard",
            #selector(openCopyPalette(_:))
        ))

        let secretsItem = NSMenuItem(title: loc.s("menu.copySecret"), action: nil, keyEquivalent: "")
        secretsItem.image = DevTypeTheme.menuIcon("key.fill")
        let secretsMenu = NSMenu()
        secretsItem.submenu = secretsMenu
        secretsSubmenu = secretsMenu
        rebuildSecretsMenu()
        menu.addItem(secretsItem)

        menu.addItem(item(loc.s("menu.import"), "square.and.arrow.down", #selector(importSnippets(_:))))
        // §0.4: export — JSON, Espanso YAML, CSV — next to the existing import.
        menu.addItem(item(loc.s("menu.export"), "square.and.arrow.up", #selector(exportSnippets(_:))))

        // Recent expansions submenu.
        let recentItem = NSMenuItem(title: loc.s("menu.recent"), action: nil, keyEquivalent: "")
        recentItem.image = DevTypeTheme.menuIcon("clock.arrow.circlepath")
        let recentMenu = NSMenu()
        recentItem.submenu = recentMenu
        recentSubmenu = recentMenu
        rebuildRecentMenu()
        menu.addItem(recentItem)
        menu.addItem(item(
            loc.s("menu.recentActivity"),
            "list.bullet.rectangle",
            #selector(openRecentActivity(_:))
        ))

        menu.addItem(NSMenuItem.separator())

        let toggleItem = item(loc.s("status.menu", loc.s("status.active")), "pause.circle", #selector(toggleEngine(_:)))
        menu.addItem(toggleItem)
        statusToggleMenuItem = toggleItem

        // Appears only after an expansion refused or failed silently: one click tears the
        // engine down, clears the failure state, and brings the tap back up. Hidden the rest
        // of the time so the menu stays quiet when nothing is wrong.
        let restartItem = item(
            loc.s("menu.restartEngine"),
            "arrow.clockwise.circle",
            #selector(restartEngine(_:))
        )
        restartItem.isHidden = true
        menu.addItem(restartItem)
        restartEngineMenuItem = restartItem

        // §4.1: Open at Login, Language, and Muted Apps moved into Preferences.
        // `openAtLoginMenuItem` stays declared so `refreshOpenAtLoginMenuItem()`
        // keeps working for any caller that still holds it; it is simply nil now.
        openAtLoginMenuItem = nil

        menu.addItem(NSMenuItem.separator())

        let recoveryItem = item(loc.s("menu.recovery"), "checkmark.shield", #selector(openPermissionRecovery(_:)), key: "P", modifiers: [.command, .shift])
        menu.addItem(recoveryItem)
        permissionRecoveryMenuItem = recoveryItem

        // Straight to the evidence tab — logs, identity, Copy Logs — without
        // walking through Status & Fix first.
        menu.addItem(item(
            loc.s("menu.diagnostics"),
            "waveform.path.ecg",
            #selector(openDiagnostics(_:)),
            key: "D",
            modifiers: [.command, .shift]
        ))

        menu.addItem(item(loc.s("menu.diagnoseSecure"), "lock.shield", #selector(diagnoseSecureInput(_:)), key: "s", modifiers: []))

        menu.addItem(NSMenuItem.separator())

        // Checked = feature on. Unchecking "Keyboard Shortcuts" unregisters every Carbon
        // hotkey (inline search, AI palette, macros) without touching text expansion;
        // unchecking "Trigger Conflict Warnings" silences duplicate/shadow reporting in the
        // editor and library health without changing what the matcher does.
        let shortcutsItem = item(
            loc.s("menu.hotkeys.toggle"),
            "keyboard",
            #selector(toggleKeyboardShortcuts(_:))
        )
        shortcutsItem.state = HotkeyPreferences.shortcutsDisabled ? .off : .on
        menu.addItem(shortcutsItem)
        shortcutsToggleMenuItem = shortcutsItem

        let conflictsItem = item(
            loc.s("menu.conflicts.toggle"),
            "exclamationmark.triangle",
            #selector(toggleConflictDetection(_:))
        )
        conflictsItem.state = SnippetStore.isConflictDetectionEnabled ? .on : .off
        menu.addItem(conflictsItem)
        conflictsToggleMenuItem = conflictsItem

        menu.addItem(NSMenuItem.separator())

        // Muting the frontmost app is contextual, so it stays in the menu bar.
        // The *list* of muted apps is a list, so it lives in Preferences (§4.8).
        menu.addItem(item(loc.s("menu.mute.front"), "speaker.slash", #selector(muteFrontmostApp(_:))))
        menu.addItem(item(loc.s("menu.mute.apps"), "speaker.slash.fill", #selector(showMutedApps(_:))))

        menu.addItem(NSMenuItem.separator())

        // Always present, regardless of the automatic-check preference: the preference governs
        // whether DevType checks *on its own*, never whether the user may ask.
        menu.addItem(item(
            loc.s("menu.checkForUpdates"),
            "arrow.down.circle",
            #selector(checkForUpdates(_:))
        ))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(item(loc.s("menu.quit"), "power", #selector(quitApp(_:)), key: "q"))
        return menu
    }

    /// §7.5 — explicit user request; reports every outcome, including failures.
    ///
    /// `@MainActor` because `UpdateFlow` is main-actor isolated: menu actions already arrive on
    /// the main thread, and stating it lets the compiler prove it rather than assuming it.
    @MainActor
    @objc private func checkForUpdates(_ sender: Any?) {
        UpdateFlow.checkManually()
    }

    /// §4.2: the menu hint follows the user's recorded shortcut instead of
    /// claiming ⌘/ forever. Only single-character keys can be menu equivalents;
    /// anything else shows no hint (the Carbon hotkey still works).
    private func hotkeyMenuKeyEquivalent() -> String {
        // Advertising a chord that will not fire is worse than no hint.
        guard !HotkeyPreferences.shortcutsDisabled else { return "" }
        let name = DevTypeShortcut.keyName(for: hotkeyManager.inlineSearchShortcut.keyCode)
        return name.count == 1 ? name.lowercased() : ""
    }

    private func hotkeyMenuModifiers() -> NSEvent.ModifierFlags {
        let carbon = hotkeyManager.inlineSearchShortcut.carbonModifiers
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    private func voiceMenuKeyEquivalent() -> String {
        guard !HotkeyPreferences.shortcutsDisabled else { return "" }
        let name = DevTypeShortcut.keyName(for: hotkeyManager.voiceShortcut.keyCode)
        return name.count == 1 ? name.lowercased() : ""
    }

    private func voiceMenuModifiers() -> NSEvent.ModifierFlags {
        let carbon = hotkeyManager.voiceShortcut.carbonModifiers
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// Synchronize all preference-dependent and dynamic menu items.
    func updateDynamicMenuItems() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateDynamicMenuItems() }
            return
        }
        assertMainThread()
        inlineSearchMenuItem?.keyEquivalent = hotkeyMenuKeyEquivalent()
        inlineSearchMenuItem?.keyEquivalentModifierMask = hotkeyMenuModifiers()

        smartDictationMenuItem?.keyEquivalent = voiceMenuKeyEquivalent()
        smartDictationMenuItem?.keyEquivalentModifierMask = voiceMenuModifiers()

        shortcutsToggleMenuItem?.state = HotkeyPreferences.shortcutsDisabled ? .off : .on
        conflictsToggleMenuItem?.state = SnippetStore.isConflictDetectionEnabled ? .on : .off

        rebuildSecretsMenu()
        rebuildRecentMenu()
        refreshStatusItemUI()
    }

    private func rebuildRecentMenu() {
        assertMainThread()
        // Store/preference callbacks can arrive during menu tracking too.
        guard !statusItemContext.menuIsOpen else {
            menuRebuildPending = true
            return
        }
        guard let recentSubmenu else { return }
        let current = SnippetStore.expandableSnippets(in: SnippetStore.shared.loadGroups())
        recentSnippetIDs = RecentSnippetResolver.reconcile(recentSnippetIDs, with: current)
        recentSubmenu.removeAllItems()
        if recentSnippetIDs.isEmpty {
            let empty = NSMenuItem(title: loc.s("menu.recent.empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentSubmenu.addItem(empty)
            return
        }
        for id in recentSnippetIDs {
            guard let snippet = RecentSnippetResolver.resolve(id, in: current) else { continue }
            let title = snippet.triggerKeyword.isEmpty
                ? snippet.displayTitle
                : "\(snippet.triggerKeyword) — \(snippet.displayTitle)"
            let item = NSMenuItem(title: title, action: #selector(expandRecent(_:)), keyEquivalent: "")
            item.target = self
            item.image = DevTypeTheme.menuIcon("text.insert")
            item.representedObject = id
            recentSubmenu.addItem(item)
        }
    }

    // MARK: - Secrets (mouse-only path for password fields)

    private func rebuildSecretsMenu() {
        assertMainThread()
        // Store/preference callbacks can arrive during menu tracking too.
        guard !statusItemContext.menuIsOpen else {
            menuRebuildPending = true
            return
        }
        guard let secretsSubmenu else { return }
        secretsSubmenu.removeAllItems()

        let secrets = SecretMenuFlow.secretMenuEntries(from: SnippetStore.shared.loadSnippets())

        // Search first, always — a flat list stops being usable well before it stops being
        // buildable, and this is the entry that scales past the handful shown below it.
        if !secrets.isEmpty {
            let search = NSMenuItem(
                title: loc.s("menu.searchSecrets"),
                action: #selector(openSecretSearch(_:)),
                keyEquivalent: ""
            )
            search.target = self
            search.image = DevTypeTheme.menuIcon("magnifyingglass")
            secretsSubmenu.addItem(search)
            secretsSubmenu.addItem(NSMenuItem.separator())
        }

        guard !secrets.isEmpty else {
            let empty = NSMenuItem(title: loc.s("menu.copySecret.empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            secretsSubmenu.addItem(empty)
            let hint = NSMenuItem(title: loc.s("menu.copySecret.hint"), action: nil, keyEquivalent: "")
            hint.isEnabled = false
            secretsSubmenu.addItem(hint)
            appendBiometryToggle(to: secretsSubmenu)
            return
        }

        for snippet in secrets {
            // Title only. The value is not in the model to display even by accident, and the
            // trigger is omitted because a secret has no typed trigger to advertise.
            let item = NSMenuItem(
                title: snippet.displayTitle,
                action: #selector(copySecretFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.image = DevTypeTheme.menuIcon("key.fill")
            item.representedObject = snippet
            secretsSubmenu.addItem(item)
        }
        appendBiometryToggle(to: secretsSubmenu)
    }

    /// Copy palette narrowed to secrets, for libraries with more of them than a submenu can hold.
    @objc private func openSecretSearch(_ sender: Any?) {
        InlineSearchPanel.open(mode: .copySecrets) { [weak self] pick, _, _ in
            guard let self, case .snippet(let snippet) = pick else { return }
            self.copyToClipboard(snippet)
        }
    }

    /// The Touch ID switch, in the menu where the prompt actually appears.
    ///
    /// It also lives in Preferences → Snippets, which is the right home for it — but a user who
    /// has just been asked to authenticate is looking at *this* menu, not at Preferences, and a
    /// setting you cannot find is a setting that does not exist. Checkable, so its current state
    /// is legible at a glance rather than only after opening a window.
    private func appendBiometryToggle(to menu: NSMenu) {
        let availability = BiometricGate.shared.availability()
        guard availability.canGate else { return }

        let title: String
        switch availability {
        case .biometry(let name): title = loc.s("menu.requireTouchID", name)
        case .passwordOnly, .unavailable: title = loc.s("menu.requireTouchID.generic")
        }

        menu.addItem(NSMenuItem.separator())
        let item = NSMenuItem(
            title: title,
            action: #selector(toggleRequireBiometry(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.state = SecretPreferences.requireBiometry(availability: availability) ? .on : .off
        menu.addItem(item)
    }

    @objc private func toggleRequireBiometry(_ sender: NSMenuItem) {
        let availability = BiometricGate.shared.availability()
        let enabled = !SecretPreferences.requireBiometry(availability: availability)
        SecretPreferences.setRequireBiometry(enabled)
        // Turning it on must bite immediately rather than after the current reuse window.
        BiometricGate.shared.invalidate()
        rebuildSecretsMenu()
        // The same switch lives in Preferences; an open window must not show the opposite of what
        // is now in force.
        if PreferencesWindowController.shared.window?.isVisible == true {
            PreferencesWindowController.shared.refreshSecretsCard()
        }
    }

    @objc private func copySecretFromMenu(_ sender: NSMenuItem) {
        guard let snippet = sender.representedObject as? SnippetModel else { return }
        copyToClipboard(snippet)
    }

    /// Palette in copy mode: search, pick, and the value lands on the clipboard instead of being
    /// injected. Reachable from the menu, so it works when the palette *shortcut* cannot fire.
    @objc private func openCopyPalette(_ sender: Any?) {
        InlineSearchPanel.toggle(mode: .copy) { [weak self] pick, _, _ in
            guard let self else { return }
            switch pick {
            case .snippet(let snippet):
                self.copyToClipboard(snippet)
            case .command(let command, let insertText):
                // Date / clipboard tools resolve to literal text; copying that is the same
                // gesture. Anything else (AI, navigation) has no clipboard meaning — ignore it
                // rather than half-perform it.
                guard !insertText.isEmpty else { return }
                if !command.isEphemeral {
                    CommandUsageStatsStore.shared.recordUsage(for: command.id)
                }
                guard SecretClipboard.shared.copyResult(insertText).didCopy else {
                    ToastPanel.show(
                        self.loc.s("clipboard.write.failed"),
                        symbol: "exclamationmark.triangle.fill"
                    )
                    return
                }
                ToastPanel.show(self.loc.s("snippet.copied.toast", self.loc.s(command.titleKey)))
            }
        }
    }

    /// Resolve a snippet to text and put it on the clipboard, with an auto-clear timer.
    /// §8.10: the one-time flow that finishes moving pre-v2 secrets to the current keychain
    /// service. This alert is the **only doorway to a keychain password dialog** in DevType:
    /// it says up front how many dialogs are coming (at most one per old secret), and once the
    /// batch is done they are gone for good — every later copy is silent. An ordinary copy can
    /// never reach the dialog by itself; `SecretMenuFlow.resolve` fails into here instead.
    private func offerSecretMigration(for snippet: SnippetModel, pendingCount: Int, thenRetry retry: @escaping () -> Void) {
        DevTypeAlert.present(
            title: loc.s("secret.migrate.title"),
            message: loc.s("secret.migrate.message", "\(pendingCount)"),
            buttons: [loc.s("secret.migrate.continue"), loc.s("common.cancel")]
        ) { [weak self] index in
            guard let self, index == 0 else { return }
            let summary = SecretStore.shared.migrateLegacy(allowInteraction: true)
            let stillPending = SecretStore.shared.snippetIDsPendingMigration()

            if !stillPending.contains(snippet.id) {
                // The one the user actually asked for is upgraded — finish their copy now,
                // silently, and only mention any stragglers in passing.
                if summary.needsUser > 0 || summary.failed > 0 {
                    ToastPanel.show(
                        loc.s("secret.migrate.partial.toast", "\(stillPending.count)"),
                        symbol: "exclamationmark.triangle.fill"
                    )
                }
                retry()
            } else {
                // Their dialog was cancelled or refused; say so once, quietly, and stop. The
                // flow re-offers itself the next time this secret is asked for — it never loops
                // on its own.
                ToastPanel.show(
                    loc.s("secret.migrate.declined.toast", snippet.displayTitle),
                    symbol: "exclamationmark.lock.fill"
                )
            }
        }
    }

    /// §8.10: the login keychain is locked (auto-lock in Keychain Access, `security
    /// lock-keychain`, some sleep policies). Same doorway rule as migration: explain first,
    /// then let macOS show its own unlock dialog, then finish what the user asked for.
    private func offerKeychainUnlock(thenRetry retry: @escaping () -> Void) {
        DevTypeAlert.present(
            title: loc.s("secret.keychainLocked.title"),
            message: loc.s("secret.keychainLocked.message"),
            buttons: [loc.s("secret.keychainLocked.unlock"), loc.s("common.cancel")]
        ) { index in
            guard index == 0 else { return }
            if SecretStore.shared.requestKeychainUnlock() {
                retry()
            } else {
                // They cancelled the system dialog; their decision, already visible to them.
                ToastPanel.show(
                    LocalizationManager.shared.s("secret.keychainLocked.stillLocked"),
                    symbol: "lock.fill"
                )
            }
        }
    }

    private func copyToClipboard(_ snippet: SnippetModel) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        let lookup: (String) -> String? = { trigger in
            // Secrets are excluded from nested `{{snippet:…}}` lookups: resolving one here would
            // paste a password into whatever document the outer snippet lands in, with no
            // explicit gesture naming it.
            SnippetStore.shared.loadSnippets().first {
                !$0.isSecret && ($0.triggerKeyword == trigger
                    || (!$0.isCaseSensitive && $0.triggerKeyword.lowercased() == trigger.lowercased()))
            }?.replacementText
        }

        // Gated entry point: a secret asks for Touch ID here, before anything is read.
        SecretMenuFlow.resolve(
            snippet,
            clipboardText: clipboard,
            lookup: lookup,
            loc: loc
        ) { [weak self] result in
            guard let self else { return }
            self.applyCopyResult(result, for: snippet)
        }
    }

    private func applyCopyResult(
        _ result: Result<String, SecretMenuFlow.ResolveFailure>,
        for snippet: SnippetModel
    ) {
        switch result {
        case .success(let text):
            guard SecretClipboard.shared.copyResult(text).didCopy else {
                ToastPanel.show(
                    loc.s("clipboard.write.failed"),
                    symbol: "exclamationmark.triangle.fill"
                )
                return
            }
            SnippetStore.shared.incrementUsage(for: snippet.id)
            // Never an alert. A modal here made the user dismiss a dialog mid-task, and — because
            // an alert activates DevType — took focus off the very field they were about to paste
            // into. The toast neither activates the app nor takes the click.
            if snippet.isSecret {
                ToastPanel.show(
                    loc.s("secret.copied.toast", snippet.displayTitle),
                    detail: loc.s("secret.copied.toast.detail", "\(Int(SecretClipboard.defaultClearAfter))"),
                    symbol: "key.fill"
                )
            } else {
                ToastPanel.show(loc.s("snippet.copied.toast", snippet.displayTitle))
            }
        case .failure(.secretUnavailable):
            DevTypeAlert.present(
                title: loc.s("secret.missing.title"),
                message: loc.s("secret.missing.message", snippet.displayTitle),
                style: .warning,
                buttons: [loc.s("menu.manage"), loc.s("common.ok")]
            ) { index in
                if index == 0 { self.openSnippetManager(nil) }
            }
        case .failure(.imageSnippet(let path)):
            // Copy the picture itself. The clipboard is the one place an image snippet and a text
            // snippet mean the same gesture, so refusing here would be an arbitrary hole.
            guard let image = ImageAttachmentStore.shared.loadImage(path: path) else {
                ToastPanel.show(
                    loc.s("snippet.copied.empty"),
                    symbol: "exclamationmark.triangle.fill"
                )
                return
            }
            PasteboardBroker.shared.invalidatePendingRestore()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            SnippetStore.shared.incrementUsage(for: snippet.id)
            ToastPanel.show(loc.s("snippet.copied.toast", snippet.displayTitle), symbol: "photo")

        case .failure(.emptySnippet):
            // Copying "" would wipe whatever the user already had on the clipboard. A beep alone
            // left the user unsure whether anything had happened at all.
            ToastPanel.show(
                loc.s("snippet.copied.empty"),
                symbol: "exclamationmark.triangle.fill"
            )

        case .failure(.migrationRequired(let pendingCount)):
            offerSecretMigration(for: snippet, pendingCount: pendingCount) { [weak self] in
                self?.copyToClipboard(snippet)
            }

        case .failure(.keychainLocked):
            offerKeychainUnlock { [weak self] in
                self?.copyToClipboard(snippet)
            }

        case .failure(.authenticationCancelled):
            // Silence on purpose. The user dismissed the prompt; telling them they dismissed the
            // prompt is a dialog about their own decision.
            break

        case .failure(.authenticationFailed(let reason)):
            ToastPanel.show(
                loc.s("secret.auth.failed"),
                detail: reason,
                symbol: "exclamationmark.lock.fill"
            )
        }
    }

    private func recordRecent(_ snippet: SnippetModel) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentSnippetIDs = RecentSnippetResolver.record(
                snippet,
                in: self.recentSnippetIDs
            )
            self.rebuildRecentMenu()
        }
    }

    @objc private func expandRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        let current = SnippetStore.expandableSnippets(in: SnippetStore.shared.loadGroups())
        guard let snippet = RecentSnippetResolver.resolve(id, in: current) else {
            recentSnippetIDs = RecentSnippetResolver.reconcile(recentSnippetIDs, with: current)
            rebuildRecentMenu()
            ToastPanel.show(
                loc.s("menu.recent.unavailable"),
                symbol: "exclamationmark.triangle.fill"
            )
            return
        }
        expandFromSearch(snippet, sourceApp: nil)
    }

    private func bindSnippetStore() {
        SnippetStore.shared.addGroupListener { [weak self] groups in
            let snippets = SnippetStore.expandableSnippets(in: groups)
            EventTapEngine.shared.snippets = snippets
            DispatchQueue.main.async {
                guard let self else { return }
                self.recentSnippetIDs = RecentSnippetResolver.reconcile(
                    self.recentSnippetIDs,
                    with: snippets
                )
                self.rebuildSecretsMenu()
                self.rebuildRecentMenu()
            }
        }
    }

    /// Offers to turn a phrase you keep typing into a snippet.
    ///
    /// Presented once, when the phrase crosses the threshold — declining forgets that phrase so
    /// the same offer cannot come back on the next repeat and become nagging.
    private func wireRepetitionSuggestions() {
        EventTapEngine.shared.onRepetitionNoticed = { [weak self] candidate in
            guard let self else { return }
            let preview = candidate.text.count > 60
                ? String(candidate.text.prefix(60)) + "…"
                : candidate.text
            // You typed it three times by hand. If a snippet already covers it, what you needed
            // was the trigger — not a second copy of the same body in the library.
            if let existing = RepeatedPhraseLookup.existingSnippet(
                for: candidate.text, in: SnippetStore.shared.loadGroups()
            ) {
                DevTypeAlert.info(
                    title: self.loc.s("repetition.reminder.title"),
                    message: self.loc.s(
                        "repetition.reminder.body", existing.triggerKeyword, preview
                    )
                )
            } else {
                DevTypeAlert.confirm(
                    title: self.loc.s("repetition.offer.title"),
                    message: self.loc.s("repetition.offer.body", candidate.occurrences, preview),
                    confirmTitle: self.loc.s("repetition.offer.confirm"),
                    cancelTitle: self.loc.s("repetition.offer.dismiss"),
                    style: .informational
                ) {
                    self.presentSnippetEditorForRepetition(candidate)
                }
            }
            // Whether or not they take it, this phrase has had its one offer.
            TypedRepetitionDetector.shared.forget(phrase: candidate.text)
        }
    }

    private func presentSnippetEditorForRepetition(_ candidate: TypedRepetitionDetector.Candidate) {
        let draft = SnippetModel(
            title: SnippetEditorSheet.derivedTitle(from: candidate.text),
            triggerKeyword: "",
            replacementText: candidate.text
        )
        let store = SnippetStore.shared
        let groups = store.loadGroups()
        SnippetEditorSheet.present(
            from: nil,
            existing: nil,
            draft: draft,
            groups: groups,
            currentGroupID: groups.first?.id,
            completion: { snippet, chosenGroupID in
                .mutating(
                    store: store,
                    mutation: { latest in
                        guard let after = SnippetLibraryEdit.applying(
                            snippet: snippet,
                            existingID: nil,
                            chosenGroupID: chosenGroupID,
                            fallbackGroupID: latest.first?.id,
                            to: latest
                        ) else { return false }
                        latest = after
                        return true
                    },
                    finalize: { _, _ in }
                )
            }
        )
    }

    private func wireExpansionUsage() {
        EventTapEngine.shared.onExpansionSucceeded = { [weak self] snippet in
            SnippetStore.shared.incrementUsage(for: snippet.id)
            self?.recordRecent(snippet)
        }
        EventTapEngine.shared.presentFillIn = { title, fields, completion in
            _ = FillInPanel.present(title: title, fields: fields, completion: completion)
        }
        // Typed AI path handoff — always preview in phase 1.
        EventTapEngine.shared.presentAITransform = { [weak self] input, kind, sourceApp, customInstructions, restoreOnCancel in
            AITransformFlow.presentFromEngine(
                input: input,
                kind: kind,
                sourceApp: sourceApp,
                customInstructions: customInstructions,
                restoreOnCancel: restoreOnCancel
            ) { text, app in
                self?.injectAIReplacement(text: text, sourceApp: app)
            }
        }
        EventTapEngine.shared.presentAITransformHint = { [weak self] titleKey, messageKey in
            guard let self else { return }
            DevTypeAlert.info(
                title: self.loc.s(titleKey),
                message: self.loc.s(messageKey)
            )
        }
    }

    private func registerHotkeys() {
        hotkeyManager.onInlineSearch = { [weak self] in
            self?.toggleInlineSearch(nil)
        }
        hotkeyManager.onAIPalette = { [weak self] in
            self?.presentAIPalette()
        }
        hotkeyManager.onVoiceDictation = {
            VoiceDictationController.shared.toggleDictation()
        }
        hotkeyManager.onInsertText = { text in
            TextInjectionPipeline.shared.inject(
                snippet: SnippetModel(title: "Hotkey", triggerKeyword: "", replacementText: text),
                triggerLength: 0,
                swallowedFinalKey: false,
                eraseCountOverride: 0,
                preResolvedText: text,
                secureClipboardPaste: true,
                completion: nil
            )
        }
        hotkeyManager.onOpenURL = { urlString in
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
        // §4.2: `RegisterEventHotKey` failure used to be a log line and nothing
        // else, so a shortcut another app had claimed just never worked.
        hotkeyManager.onRegistrationFailed = { [weak self] label, status in
            guard let self else { return }
            DispatchQueue.main.async {
                ActivityHistoryStore.publish(
                    .hotkeyRegistrationFailed(status: Int32(status))
                )
                // Preferences reports its own failure inline; don't double-alert.
                if PreferencesWindowController.shared.window?.isVisible == true { return }
                DevTypeAlert.present(
                    title: self.loc.s("prefs.hotkeys.failed.title"),
                    message: self.loc.s("prefs.hotkeys.failed.message", label, Int(status)),
                    style: .warning,
                    buttons: [self.loc.s("menu.preferences"), self.loc.s("common.ok")]
                ) { index in
                    if index == 0 { self.openPreferences(nil, tab: .hotkeys) }
                }
            }
        }
        hotkeyManager.registerAll()
        VoiceDictationController.shared.performLaunchRecovery()
    }

    @objc private func startSmartDictation(_ sender: Any?) {
        VoiceDictationController.shared.toggleDictation()
    }

    /// Records the reason for an otherwise-silent `SIGABRT`.
    ///
    /// The two palette crashes that motivated §8.7 shipped `.ips` reports whose only
    /// application-specific information was `abort() called` — no exception name, no
    /// reason, because the raiser (`-[NSRemoteView containingWindowWillOrderOnScreen:]`)
    /// catches and rethrows, which loses AppKit's default logging. Diagnosing them cost a
    /// debugger session. This puts the name, a content-free reason fingerprint, and a bounded
    /// frame count into the unified log first, so the next one is correlatable without exporting
    /// filesystem paths embedded in symbolicated frames.
    ///
    /// This does not prevent the abort — nothing can, once an exception is uncaught. It
    /// only makes the crash diagnosable. Preventing a specific crash is the job of an
    /// ObjC `@catch` at the boundary that raises, as in
    /// `DTMakeKeyAndOrderFrontCatchingException`.
    private func installLastResortExceptionLogger() {
        NSSetUncaughtExceptionHandler { exception in
            DevTypeLog.app.fault(
                """
                [Crash] uncaught \(DevTypeLog.boundedPublicIdentifier(exception.name.rawValue, label: "exceptionName"), privacy: .public): \
                \(DevTypeLog.publicTextMetadata(exception.reason), privacy: .public)
                stackFrames=\(exception.callStackReturnAddresses.count, privacy: .public)
                """
            )
        }
    }

    @objc private func toggleInlineSearch(_ sender: Any?) {
        InlineSearchPanel.toggle { [weak self] pick, sourceApp, selection in
            guard let self else { return }
            switch pick {
            case .snippet(let snippet):
                self.expandFromSearch(snippet, sourceApp: sourceApp)
            case .command(let command, let insertText):
                self.handlePaletteCommand(
                    command,
                    insertText: insertText,
                    sourceApp: sourceApp,
                    selection: selection
                )
            }
        }
    }

    /// Hybrid palette commit: AI → `AITransformFlow`, date/clipboard → inject, navigate → windows.
    ///
    /// `selection` is captured at panel-open time by `InlineSearchPanel`. It must not be
    /// re-read here: the panel is key by now, so a live `SelectionReader` read resolves to
    /// our own search field and yields nil.
    private func handlePaletteCommand(
        _ command: PaletteCommand,
        insertText: String,
        sourceApp: NSRunningApplication?,
        selection: SelectionReader.Outcome
    ) {
        // Ephemeral rows are built from the query text, so their ids are unique per keystroke
        // and resolve to nothing in the catalogue. Recording them grew the stats file forever.
        if !command.isEphemeral {
            CommandUsageStatsStore.shared.recordUsage(for: command.id)
        }

        switch command.action {
        case .ai(let kind):
            runPaletteAI(
                kind: kind,
                customInstructions: nil,
                sourceApp: sourceApp,
                selection: selection
            )

        case .aiCustom(let instructions):
            runPaletteAI(
                kind: .custom,
                customInstructions: instructions,
                sourceApp: sourceApp,
                selection: selection
            )

        case .date, .clipboard, .generate, .insert:
            guard !insertText.isEmpty else {
                if case .clipboard = command.action {
                    DevTypeAlert.info(
                        title: loc.s("palette.tool.clipboard"),
                        message: loc.s("palette.tool.clipboard.empty")
                    )
                }
                sourceApp?.activate()
                return
            }
            injectPaletteText(insertText, sourceApp: sourceApp)

        case .textOp(let op):
            // Captured at panel-open; a live read here would always miss and silently
            // fall through to the clipboard, transforming the wrong text with no warning.
            let source = selection.result?.text
                ?? NSPasteboard.general.string(forType: .string)
                ?? ""
            guard !SelectionReader.isBlankSelection(source) else {
                DevTypeAlert.info(
                    title: loc.s(command.titleKey),
                    message: selection.failure?.message(loc: loc)
                        ?? loc.s("ai.alert.noSelection.message")
                )
                sourceApp?.activate()
                return
            }
            injectPaletteText(PaletteTextOps.apply(op, to: source), sourceApp: sourceApp)

        case .count:
            sourceApp?.activate()

        case .undoAI:
            guard let original = AIUndoStore.consume() else {
                sourceApp?.activate()
                return
            }
            injectPaletteText(original, sourceApp: sourceApp)

        case .voiceDictation:
            VoiceDictationController.shared.toggleDictation(sourceApp: sourceApp)

        case .navigate(let target):
            switch target {
            case .preferences:
                openPreferences(nil)
            case .manageSnippets:
                openSnippetManager(nil)
            case .permissionRecovery:
                openPermissionRecovery(nil)
            case .voicePreferences:
                openPreferences(nil, tab: .voice)
            case .createSnippet:
                openSnippetManager(nil)
                (snippetWindowController?.contentViewController as? SnippetManagerViewController)?.addSnippet()
            case .toggleExpansion:
                toggleEngine(NSMenuItem())
            case .importLibrary:
                openSnippetManager(nil)
                SnippetImportFlow.present(from: snippetWindowController?.window)
            case .exportLibrary:
                openSnippetManager(nil)
                LibraryExporter.present(from: snippetWindowController?.window)
            case .testExpansionLab:
                TestExpansionLab.run(from: snippetWindowController?.window)
            case .keyboardShortcuts:
                ShortcutReferenceWindowController.show()
            case .recentActivity:
                ActivityCenterViewController.show()
            }
        }
    }

    private func runPaletteAI(
        kind: AITransformKind,
        customInstructions: String?,
        sourceApp: NSRunningApplication?,
        selection: SelectionReader.Outcome
    ) {
        guard AIPreferences.isEnabled else {
            DevTypeAlert.info(
                title: loc.s("ai.alert.disabled.title"),
                message: loc.s("ai.alert.disabled.message")
            )
            return
        }
        // A local kind needs no model, so the availability gate does not apply to it.
        // The master AI switch above still does: this action lives on the AI surface, and
        // a user who turned that surface off should not find one of its rows still firing.
        if kind.requiresModel {
            switch AITextTransformSupport.availability {
            case .available:
                break
            case .unavailable(let reason):
                DevTypeAlert.info(
                    title: loc.s("ai.alert.unavailable.title"),
                    message: AITransformFlow.localizedAvailability(reason, loc: loc)
                )
                return
            }
        }

        switch selection {
        case .selection(let resolved):
            startPaletteAITransform(
                resolved,
                kind: kind,
                customInstructions: customInstructions,
                sourceApp: sourceApp
            )

        case .failure(.noFocusedElement):
            // The command palette captured before stealing focus, but some custom editors
            // (including Codex) publish no focused AX element. Do not synthesize ⌘C merely
            // because the general palette opened: wait until the user explicitly chooses an AI
            // action, return focus to the source, then use the same brokered fallback as the
            // dedicated AI hotkey. Polling the actual frontmost pid is load-bearing — posting
            // before activation completes would copy from DevType's own search field.
            guard let sourceApp else {
                presentPaletteSelectionFailure(.noFocusedElement, sourceApp: nil)
                return
            }
            sourceApp.activate()
            retryPaletteAISelectionAfterFocus(
                kind: kind,
                customInstructions: customInstructions,
                sourceApp: sourceApp
            )

        case .failure(let failure):
            presentPaletteSelectionFailure(failure, sourceApp: sourceApp)
        }
    }

    /// Wait for AppKit to finish activating the source before a fallback that may post ⌘C.
    /// Transition policy and bounds live in `SelectionReader`; this method only schedules.
    private func retryPaletteAISelectionAfterFocus(
        kind: AITransformKind,
        customInstructions: String?,
        sourceApp: NSRunningApplication,
        remainingPolls: Int = SelectionReader.sourceFocusMaxPolls
    ) {
        switch SelectionReader.sourceFocusRetryDecision(
            sourcePID: sourceApp.processIdentifier,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            sourceTerminated: sourceApp.isTerminated,
            remainingPolls: remainingPolls
        ) {
        case .wait(let nextRemainingPolls):
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SelectionReader.sourceFocusPollInterval
            ) { [weak self] in
                self?.retryPaletteAISelectionAfterFocus(
                    kind: kind,
                    customInstructions: customInstructions,
                    sourceApp: sourceApp,
                    remainingPolls: nextRemainingPolls
                )
            }

        case .read:
            switch SelectionReader.readSelectionForExplicitAIAction() {
            case .selection(let resolved):
                startPaletteAITransform(
                    resolved,
                    kind: kind,
                    customInstructions: customInstructions,
                    sourceApp: sourceApp
                )
            case .failure(let failure):
                presentPaletteSelectionFailure(failure, sourceApp: sourceApp)
            }

        case .fail:
            presentPaletteSelectionFailure(.noFocusedElement, sourceApp: sourceApp)
        }
    }

    private func startPaletteAITransform(
        _ resolved: SelectionReader.Result,
        kind: AITransformKind,
        customInstructions: String?,
        sourceApp: NSRunningApplication?
    ) {
        let picked = AIActionSelection(kind: kind, customInstructions: customInstructions)
        AITransformFlow.run(
            input: resolved.text,
            kind: picked.kind,
            sourceApp: sourceApp,
            customInstructions: picked.customInstructions,
            forcePreview: picked.requiresPreview,
            loc: loc
        ) { [weak self] text, app in
            self?.injectAIReplacement(text: text, sourceApp: app)
        }
    }

    private func presentPaletteSelectionFailure(
        _ failure: SelectionReader.Failure,
        sourceApp: NSRunningApplication?
    ) {
        DevTypeAlert.info(
            title: failure.title(loc: loc),
            message: failure.message(loc: loc)
        )
        sourceApp?.activate()
    }

    /// Insert resolved palette text (date tools / clipboard) with eraseCount 0, like hotkey insertText.
    private func injectPaletteText(_ text: String, sourceApp: NSRunningApplication?) {
        if let sourceApp {
            sourceApp.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
            TextInjectionPipeline.shared.inject(
                snippet: SnippetModel(title: "Palette", triggerKeyword: "", replacementText: text),
                triggerLength: 0,
                swallowedFinalKey: false,
                eraseCountOverride: 0,
                preResolvedText: text,
                secureClipboardPaste: true,
                completion: { [weak self] _ in
                    self?.refreshStatusItemUI()
                }
            )
        }
    }

    private func presentAIPalette() {
        AITransformFlow.presentFromHotkey { [weak self] text, sourceApp in
            self?.injectAIReplacement(text: text, sourceApp: sourceApp)
        }
    }

    /// Inject AI result after reactivating the source app. Uses `erasePlan: .empty`
    /// so clipboard paste replaces the live selection (hotkey) or inserts at the
    /// caret (typed path, where the trigger was already erased).
    ///
    /// This is the single delivery seam for every AI-generated result (hotkey direct,
    /// palette, preview Replace, typed-path preview Replace), so it carries the last
    /// line of prompt-leak defense: even if generation-side echo checks ever regress,
    /// a payload quoting unrecognized prompt text is refused here instead of being
    /// typed or pasted into a document. The stashed source selection exempts clauses
    /// the author's own text contains; refusal costs one alert and leaves the field
    /// untouched — never data loss.
    private func injectAIReplacement(text: String, sourceApp: NSRunningApplication?) {
        let verdict = AIPromptLeakGuard.injectionVerdict(
            payload: text,
            exempting: AIUndoStore.stashedOriginal()
        )
        guard verdict.isClean else {
            DevTypeLog.store.error(
                "[AI] injection refused at boundary — prompt leak guard matched"
            )
            AIDiagnosticsStore.shared.recordFailure(
                kind: "injection-boundary",
                error: "promptEcho",
                detail: "result still contained prompt text after generation checks"
            )
            DevTypeAlert.present(
                title: loc.s("ai.alert.failed.title"),
                message: AITransformFlow.localizedError(.promptEcho, loc: loc),
                style: .informational,
                buttons: [loc.s("common.ok")],
                handler: nil
            )
            sourceApp?.activate()
            return
        }
        if let sourceApp {
            sourceApp.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
            let snapshot = PermissionCoordinator.shared.cachedSnapshot
            let snippet = SnippetModel(
                title: "AI Transform",
                triggerKeyword: "",
                replacementText: text
            )
            let needsCursor = InjectionPlanner.needsCursorHID(
                cursorOffset: nil,
                totalUTF16Length: text.utf16.count
            )
            let isTerminal = AXContextChecker.shared.isFrontmostAppTerminal()
            let plan = InjectionPlanner().plan(
                snapshot: snapshot,
                isTerminal: isTerminal,
                needsCursorHID: needsCursor,
                isMultiLine: text.contains(where: \.isNewline)
            )
            if case .refuse = plan { return }

            let suspension = EventTapEngine.shared.suspendMatching(reason: "secretPaste")
            TextInjectionPipeline.shared.inject(
                snippet: snippet,
                triggerLength: 0,
                swallowedFinalKey: false,
                plan: plan,
                erasePlan: .empty,
                preResolvedText: text,
                secureClipboardPaste: true,
                completion: { _ in
                    suspension.release()
                    self.refreshStatusItemUI()
                }
            )
        }
    }

    private func expandFromSearch(_ snippet: SnippetModel, sourceApp: NSRunningApplication?) {
        if let sourceApp {
            sourceApp.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
            // Inline search: erase 0, no quiescence (palette typing would always abort).
            let snapshot = PermissionCoordinator.shared.cachedSnapshot
            let clipboard = NSPasteboard.general.string(forType: .string)
            let lookup: (String) -> String? = { trigger in
                SnippetStore.shared.loadSnippets().first {
                    $0.triggerKeyword == trigger
                        || (!$0.isCaseSensitive && $0.triggerKeyword.lowercased() == trigger.lowercased())
                }?.replacementText
            }
            // A secret is fetched at the moment of use and injected verbatim. Never through
            // `MacroRenderer`: a password containing `{{` or `%` is not a template, and expanding
            // one would corrupt it silently — or resolve a nested `{{snippet:…}}` inside it.
            if snippet.isSecret {
                // Same gate as the copy path, and the same reason for it being in the resolver
                // rather than here: a second surface reading secrets is a second place to forget.
                SecretMenuFlow.resolve(snippet, loc: loc) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let value):
                        self.injectSearchExpansion(
                            snippet: snippet,
                            resolved: MacroExpansionResult(
                                text: value,
                                cursorOffset: nil,
                                trailingKeys: [],
                                fillFields: [],
                                needsFillIn: false
                            ),
                            snapshot: snapshot
                        )
                    case .failure(.migrationRequired(let pendingCount)):
                        self.offerSecretMigration(for: snippet, pendingCount: pendingCount) { [weak self] in
                            self?.expandFromSearch(snippet, sourceApp: sourceApp)
                        }
                    case .failure(.keychainLocked):
                        self.offerKeychainUnlock { [weak self] in
                            self?.expandFromSearch(snippet, sourceApp: sourceApp)
                        }
                    case .failure(.authenticationCancelled):
                        break
                    case .failure(.authenticationFailed(let reason)):
                        ToastPanel.show(
                            self.loc.s("secret.auth.failed"),
                            detail: reason,
                            symbol: "exclamationmark.lock.fill"
                        )
                    case .failure:
                        DevTypeAlert.present(
                            title: self.loc.s("secret.missing.title"),
                            message: self.loc.s("secret.missing.message", snippet.displayTitle),
                            style: .warning,
                            buttons: [self.loc.s("common.ok")],
                            handler: nil
                        )
                    }
                }
                return
            }

            let resolved = MacroRenderer.expand(
                content: snippet.replacementText,
                lookup: lookup,
                clipboardText: clipboard
            )
            if resolved.needsFillIn {
                FillInPanel.present(title: snippet.displayTitle, fields: resolved.fillFields) { values in
                    guard let values else { return }
                    let filled = MacroRenderer.expand(
                        content: snippet.replacementText,
                        fillValues: values,
                        lookup: lookup,
                        clipboardText: clipboard
                    )
                    self.injectSearchExpansion(snippet: snippet, resolved: filled, snapshot: snapshot)
                }
                return
            }
            injectSearchExpansion(snippet: snippet, resolved: resolved, snapshot: snapshot)
        }
    }

    private func injectSearchExpansion(
        snippet: SnippetModel,
        resolved: MacroExpansionResult,
        snapshot: PermissionSnapshot
    ) {
        let needsCursor = InjectionPlanner.needsCursorHID(
            cursorOffset: resolved.cursorOffset,
            totalUTF16Length: resolved.text.utf16.count
        )
        let isTerminal = AXContextChecker.shared.isFrontmostAppTerminal()
        let plan = InjectionPlanner().plan(
            snapshot: snapshot,
            isTerminal: isTerminal,
            needsCursorHID: needsCursor,
            isMultiLine: resolved.text.contains(where: \.isNewline)
        )
        if case .refuse = plan { return }

        let suspension = EventTapEngine.shared.suspendMatching(reason: "expandFromSearch")
        TextInjectionPipeline.shared.inject(
            snippet: snippet,
            triggerLength: 0,
            swallowedFinalKey: false,
            plan: plan,
            eraseCountOverride: 0,
            preResolvedText: resolved.text,
            preResolvedCursorOffset: resolved.cursorOffset,
            trailingKeys: resolved.trailingKeys,
            secureClipboardPaste: true,
            completion: { [weak self] outcome in
                suspension.release()
                if outcome.isConfirmedSuccess {
                    SnippetStore.shared.incrementUsage(for: snippet.id)
                    self?.recordRecent(snippet)
                }
                self?.refreshStatusItemUI()
            }
        )
    }

    /// §4.8 / §1.10: unified import — one panel, format auto-detected, `.merge`
    /// mode, localized result. The duplicate copy in the manager now calls the
    /// same flow.
    @objc private func importSnippets(_ sender: Any?) {
        SnippetImportFlow.present(from: nil)
    }

    /// §0.4: export — JSON / Espanso YAML / CSV via `NSSavePanel`.
    @objc private func exportSnippets(_ sender: Any?) {
        LibraryExporter.present(from: nil)
    }

    /// §4.1: the settings window ⌘, now opens.
    @objc private func openPreferences(_ sender: Any?) {
        openPreferences(sender, tab: nil)
    }

    func openPreferences(_ sender: Any?, tab: PreferencesTab?) {
        PreferencesWindowController.shared.show(tab: tab, hotkeyManager: hotkeyManager)
    }

    private func warnIfTextExpanderRunning() {
        let apps = NSWorkspace.shared.runningApplications
        let teRunning = apps.contains {
            RunningAppCheck.isTextExpander(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }
        guard teRunning else { return }
        DevTypeAlert.warn(
            title: loc.s("alert.textExpander.title"),
            message: loc.s("menu.textExpanderWarning")
        )
    }

    private func warnIfEspansoRunning() {
        let apps = NSWorkspace.shared.runningApplications
        let running = apps.contains {
            RunningAppCheck.isEspanso(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }
        guard running else { return }
        DevTypeAlert.warn(
            title: loc.s("alert.espanso.title"),
            message: loc.s("menu.espansoWarning")
        )
    }

    /// §0.3: this used to tell the user their library "was replaced with
    /// defaults" — which the store no longer does, and which offered no recovery
    /// path. `LibraryHealthMonitor` now owns the read/write/conflict state, and
    /// the escalation offers Reveal Backup / Retry / Overwrite-with-defaults.
    private func presentLibraryHealthIfNeeded() {
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

    private func presentTapFailedAlert() {
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

    private func startSecureInputMonitoring() {
        SecureInputMonitor.shared.startMonitoring(interval: 0.35) { [weak self] _ in
            // The notification is a wake-up, not an authoritative queued snapshot.
            self?.refreshStatusItemUI()
        }
    }

    private func refreshStatusItemUI() {
        // `TextInjectionPipeline` fires its completion on the serial `com.devtype.inject`
        // queue, so every inject-completion call site reaches this off-main. Updating the
        // status item / `PillBadgeView` runs AutoLayout, and AutoLayout off the main thread
        // aborts the process outright (`_AssertAutoLayoutOnAllowedThreadsOnly` → SIGABRT),
        // not merely misbehaves. Funnel to main before touching any AppKit state.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshStatusItemUI() }
            return
        }
        assertMainThread()
        let secureInputActive = AXContextChecker.isSecureEventInputEnabledLive()
        if let signal = activityTransitionTracker.signalForSecureInput(active: secureInputActive) {
            ActivityHistoryStore.publish(signal)
        }
        EventTapEngine.shared.isSecureInputActive = secureInputActive
        statusItemContext.refresh(secureInputActive: secureInputActive)
        let snapshot = PermissionProbe().snapshot()
        let display = EngineDisplayStatus.resolve(
            snapshot: snapshot,
            isTapRunning: EventTapEngine.shared.isTapRunning,
            isEnabled: EventTapEngine.shared.isEnabled,
            isSecureInputActive: secureInputActive
        )
        if lastLoggedDisplayStatus != display {
            DevTypeLog.app.info(
                "[App] display status → \(display.menuTitle, privacy: .public) \(DevTypeLog.snapshotSummary(snapshot), privacy: .public) tapRunning=\(EventTapEngine.shared.isTapRunning, privacy: .public)"
            )
            lastLoggedDisplayStatus = display
        }
        let urgentInject: Bool = {
            switch PermissionCoordinator.shared.lastRecordedInjectOutcome {
            case .failedSilent, .refused:
                return true
            case .postedUnverified, .degradedAXOnly, .succeeded, .none:
                return false
            }
        }()
        restartEngineMenuItem?.isHidden = !urgentInject
        let presentation = StatusItemPresentation(
            display: display,
            snapshot: snapshot,
            isSecureInputActive: statusItemContext.offersCopySecret,
            urgentInject: urgentInject,
            libraryUnhealthy: LibraryHealthMonitor.shared.condition != nil,
            differentiateWithoutColor: DevTypeAccessibility.differentiateWithoutColor,
            highlighted: statusItemContext.menuIsOpen,
            loc: loc
        )
        let name = presentation.statusName
        let color = presentation.statusColor
        let needsAttention = presentation.needsAttention
        if let button = statusItem?.button {
            presentation.apply(to: button)
        }
        statusToggleMenuItem?.title = needsAttention
            ? loc.s("status.menu.attention", name)
            : loc.s("status.menu", name)
        statusToggleMenuItem?.image = DevTypeTheme.menuIcon(
            display == .paused ? "play.circle" : "pause.circle"
        )
        menuHeaderStatusPill?.update(text: name, tint: color)
        menuHeaderAccessibilityHost?.setAccessibilityLabel(
            loc.s("ax.menu.header", menuHeaderVersion, name)
        )
        if needsAttention {
            permissionRecoveryMenuItem?.title = "\(loc.s("menu.recovery")) ⚠"
        } else {
            permissionRecoveryMenuItem?.title = loc.s("menu.recovery")
        }
        refreshOpenAtLoginMenuItem()
    }

    private func refreshOpenAtLoginMenuItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        openAtLoginMenuItem?.state = enabled ? .on : .off
    }

    @objc func openSnippetManager(_ sender: Any?) {
        if snippetWindowController == nil || snippetWindowController?.window == nil {
            let viewController = SnippetManagerViewController()
            let window = NSWindow(contentViewController: viewController)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 920, height: 600))
            window.minSize = NSSize(width: 700, height: 460)
            // §6.1: window titles were hardcoded English.
            DevTypeTheme.styleWindow(window, title: loc.s("window.snippets"))
            window.center()
            window.isReleasedWhenClosed = false
            snippetWindowController = NSWindowController(window: window)
            snippetManagerRenderedLanguage = loc.language
        } else if snippetManagerRenderedLanguage != loc.language {
            refreshSnippetManagerLocalization()
        }

        guard let window = snippetWindowController?.window else { return }
        snippetWindowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Rebuilds AppKit labels that were materialized in the previous language while carrying
    /// transient manager navigation and its undo stack forward. A visible editor sheet owns
    /// unsaved input, so replacement is deferred until the next show rather than dropping it.
    private func refreshSnippetManagerLocalization() {
        guard let window = snippetWindowController?.window else { return }
        DevTypeTheme.styleWindow(window, title: loc.s("window.snippets"))
        guard snippetManagerRenderedLanguage != loc.language else { return }
        guard window.attachedSheet == nil,
              let current = window.contentViewController as? SnippetManagerViewController else {
            return
        }

        let replacement = SnippetManagerViewController(
            restorationState: current.localizationState(),
            snippetUndoManager: current.snippetUndoManager,
            snippetUndoTarget: current.snippetUndoTarget
        )
        window.contentViewController = replacement
        snippetManagerRenderedLanguage = loc.language
    }

    @objc private func openRecentActivity(_ sender: Any?) {
        ActivityCenterViewController.show()
    }

    /// Menu-bar "Diagnostics…": same window as Recovery, pre-selected on the
    /// Diagnostics tab so the OSLog dump is one click from the menu bar.
    @objc private func openDiagnostics(_ sender: Any?) {
        openPermissionRecovery(sender)
        (permissionWindowController?.contentViewController as? PermissionRecoveryController)?
            .showDiagnostics()
    }

    @objc func openPermissionRecovery(_ sender: Any?) {
        // Setup owns the screen while it is up. Recovery covers the same three capabilities from
        // the same probe, so stacking it over the wizard gives the user two windows disagreeing
        // about which button to press next — and two claims on the activation policy.
        if isOnboardingVisible {
            DevTypeLog.permission.info(
                "[Permission] UI → Recovery requested while Setup is open; focusing Setup instead"
            )
            onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        DevTypeLog.permission.info("[Permission] UI → open Permission Recovery")
        if permissionWindowController == nil || permissionWindowController?.window == nil {
            let viewController = PermissionRecoveryController { [weak self] in
                self?.refreshStatusItemUI()
            }
            let window = NSWindow(contentViewController: viewController)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            PermissionRecoveryWindowLayout.apply(to: window)
            DevTypeTheme.styleWindow(window, title: loc.s("window.recovery"))
            window.center()
            window.isReleasedWhenClosed = false
            permissionWindowController = NSWindowController(window: window)
        }

        guard let window = permissionWindowController?.window else { return }
        permissionWindowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openOnboarding() {
        // Single-flight: launch path + onIdentityResolved can both call presentOnboardingOrRecoveryIfNeeded.
        if let existing = onboardingWindowController?.window, existing.isVisible {
            DevTypeLog.permission.debug("[Permission] UI → onboarding already visible (single-flight)")
            onboardingPresentationInFlight = false
            PermissionRequester.shared.beginSetupActivation()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        DevTypeLog.permission.info("[Permission] UI → open onboarding wizard")
        if onboardingWindowController == nil || onboardingWindowController?.window == nil {
            let viewController = PermissionOnboardingController { [weak self] in
                self?.onboardingPresentationInFlight = false
                self?.refreshStatusItemUI()
                PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
            }
            let window = NSWindow(contentViewController: viewController)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 620, height: 640))
            DevTypeTheme.styleWindow(window, title: loc.s("window.setup"))
            window.center()
            window.isReleasedWhenClosed = false
            // Replace rather than accumulate: a re-created window would otherwise leave the
            // previous block-based observer registered against a dead window forever.
            if let onboardingCloseObserver {
                NotificationCenter.default.removeObserver(onboardingCloseObserver)
            }
            onboardingCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.onboardingPresentationInFlight = false
                PermissionRequester.shared.endSetupActivation()
                // Covers every dismissal, including the close button — which never reaches
                // Skip or Finish, so nothing else would refresh the menu or set the latch.
                if !ProcessIdentity.isOnboardingCompleted() {
                    DevTypeLog.permission.info(
                        "[Permission] Setup closed without completing — not re-presenting this launch"
                    )
                    self.onboardingDismissedThisLaunch = true
                }
                PermissionCoordinator.shared.refresh(presentTapFailureAlert: false)
                self.refreshStatusItemUI()
            }
            onboardingWindowController = NSWindowController(window: window)
        }
        PermissionRequester.shared.beginSetupActivation()
        onboardingWindowController?.showWindow(nil)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingPresentationInFlight = false
    }

    @objc private func toggleEngine(_ sender: NSMenuItem) {
        let engine = EventTapEngine.shared
        engine.isEnabled.toggle()
        DevTypeLog.app.info(
            "[App] user pause toggled enabled=\(engine.isEnabled, privacy: .public)"
        )

        if engine.isEnabled && !engine.isTapRunning {
            let snapshot = PermissionProbe().snapshot()
            if !snapshot.blocksDefaultEventTap {
                // Route through coordinator so cachedSnapshot, lastEmittedStatus,
                // and onStatus handlers stay in sync after tap start/fail.
                PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
            } else {
                DevTypeLog.permission.notice(
                    "[Permission] resume blocked — \(DevTypeLog.snapshotSummary(snapshot), privacy: .public); opening recovery"
                )
                openPermissionRecovery(nil)
            }
        }
        refreshStatusItemUI()
    }

    /// One-click recovery after a refused/failed expansion: full stop (tap + run-loop source
    /// down), clear the recorded failure so the status item stops flagging it, then bring the
    /// tap back up through the coordinator so cached snapshots and status handlers stay in
    /// sync. A permission problem still routes to the recovery window instead of pretending
    /// a restart fixed it.
    @objc private func restartEngine(_ sender: NSMenuItem) {
        DevTypeLog.app.notice("[App] user requested engine restart from status menu")
        let engine = EventTapEngine.shared
        engine.stop()
        engine.isEnabled = true
        PermissionCoordinator.shared.clearLastInjectOutcome()

        let snapshot = PermissionProbe().snapshot()
        if snapshot.blocksDefaultEventTap {
            DevTypeLog.permission.notice(
                "[Permission] restart blocked — \(DevTypeLog.snapshotSummary(snapshot), privacy: .public); opening recovery"
            )
            openPermissionRecovery(nil)
        } else {
            PermissionCoordinator.shared.refresh(presentTapFailureAlert: true)
        }
        refreshStatusItemUI()
    }

    /// Unchecking unregisters every Carbon hotkey; re-checking re-registers the persisted
    /// bindings. The menu is rebuilt so the inline-search item stops advertising a key
    /// equivalent that no longer fires.
    @objc private func toggleKeyboardShortcuts(_ sender: NSMenuItem) {
        HotkeyPreferences.shortcutsDisabled.toggle()
        DevTypeLog.app.info(
            "[App] keyboard shortcuts \(HotkeyPreferences.shortcutsDisabled ? "disabled" : "enabled", privacy: .public) from status menu"
        )
        hotkeyManager.registerAll()
        rebuildMenu()
    }

    /// Silences duplicate/shadow trigger reporting everywhere it surfaces (editor validation,
    /// library health). Matcher behaviour is unchanged — this is "stop warning me", not
    /// "resolve my collisions differently".
    @objc private func toggleConflictDetection(_ sender: NSMenuItem) {
        SnippetStore.isConflictDetectionEnabled.toggle()
        DevTypeLog.app.info(
            "[App] trigger conflict warnings \(SnippetStore.isConflictDetectionEnabled ? "enabled" : "disabled", privacy: .public) from status menu"
        )
        rebuildMenu()
    }

    @objc private func diagnoseSecureInput(_ sender: NSMenuItem) {
        let lockStatus = SecureInputMonitor.shared.checkLockStatus()
        DevTypeLog.secureInput.info(
            "[SecureInput] diagnose locked=\(lockStatus.isLocked, privacy: .public) frontmost=\(DevTypeLog.boundedPublicIdentifier(lockStatus.holdingAppName, label: "appName"), privacy: .public) frontmostPID=\(lockStatus.holdingPID.map(String.init) ?? "nil", privacy: .public)"
        )
        // §6.1 / §4.8: was a hardcoded-English hand-built NSAlert.
        let unknown = loc.s("alert.secureInput.unknown")
        if lockStatus.isLocked {
            DevTypeAlert.warn(
                title: loc.s("alert.secureInput.title"),
                message: loc.s(
                    "alert.secureInput.enabled",
                    lockStatus.holdingAppName ?? unknown,
                    lockStatus.holdingPID.map { String($0) } ?? unknown,
                    lockStatus.holdingExecutablePath ?? unknown
                )
            )
        } else {
            DevTypeAlert.info(
                title: loc.s("alert.secureInput.title"),
                message: loc.s("alert.secureInput.disabled")
            )
        }
    }

    @objc private func muteFrontmostApp(_ sender: NSMenuItem) {
        guard let bundleID = AppMuteStore.shared.muteFrontmost() else {
            DevTypeAlert.warn(
                title: loc.s("alert.muteFrontmost.failed.title"),
                message: loc.s("alert.muteFrontmost.failed.message")
            )
            return
        }
        DevTypeAlert.info(
            title: loc.s("alert.appMuted.title"),
            message: loc.s("alert.appMuted.message", bundleID)
        )
    }

    /// §4.8: this used to add one alert button per muted app and decode the
    /// choice with `response.rawValue - alertFirstButtonReturn.rawValue` — which
    /// silently mis-selects past ~3 apps and cannot scroll. A list belongs in a
    /// list view, so the menu item now opens the Muted Apps table in Preferences.
    @objc private func showMutedApps(_ sender: NSMenuItem) {
        openPreferences(sender, tab: .general)
    }

    /// Start/stop `SelectionMonitor` from persisted `devtype.ai.enabled` (default off).
    /// Preferences also toggles via `AIPreferences.isEnabled`; this covers cold launch.
    private func syncSelectionMonitorWithAIPreferences() {
        SelectionMonitor.shared.isFeatureEnabled = AIPreferences.isEnabled
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        DevTypeLog.app.info("[App] quit requested")
        SelectionMonitor.shared.stop()
        EventTapEngine.shared.stop()
        SecureInputMonitor.shared.stopMonitoring()
        PermissionCoordinator.shared.cancelPendingWork()
        PermissionCoordinator.shared.stop()
        NSApplication.shared.terminate(nil)
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
    }
}

// MARK: - Status menu tracking

extension AppDelegate {
    private func showStatusMenu(from button: NSButton) {
        guard let menu = statusMenu, !statusItemContext.menuIsOpen else { return }
        updateDynamicMenuItems()
        statusItemContext.openMenu(secureInputActive: statusItemContext.offersCopySecret)
        button.highlight(true)
        refreshStatusItemUI()
        defer {
            // popUp has finished tracking. AppKit forbids restructuring menus inside
            // menuWillOpen/menuDidClose; deferred store updates are safe here instead.
            button.highlight(false)
            statusItemContext.closeMenu(secureInputActive: AXContextChecker.isSecureEventInputEnabledLive())
            if menuRebuildPending {
                rebuildMenu()
            } else {
                refreshStatusItemUI()
            }
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.minY),
            in: button
        )
    }
}
