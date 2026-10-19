import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

extension AppDelegate {
    // MARK: - Menu bar

    func setupStatusItem() {
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

    func rebuildMenu() {
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
            key: hotkeyManager.inlineSearchShortcut.menuKeyEquivalent,
            modifiers: hotkeyManager.inlineSearchShortcut.menuModifierFlags
        )
        menu.addItem(inlineItem)
        inlineSearchMenuItem = inlineItem

        let dictationItem = item(
            loc.s("menu.smartDictation"),
            "waveform.and.mic",
            #selector(startSmartDictation(_:)),
            key: hotkeyManager.voiceShortcut.menuKeyEquivalent,
            modifiers: hotkeyManager.voiceShortcut.menuModifierFlags
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
        let diagnosticsItem = item(
            loc.s("menu.diagnostics"),
            "waveform.path.ecg",
            #selector(openDiagnostics(_:)),
            key: "D",
            modifiers: [.command, .shift]
        )
        menu.addItem(diagnosticsItem)
        diagnosticsMenuItem = diagnosticsItem

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

    /// Synchronize all preference-dependent and dynamic menu items.
    func updateDynamicMenuItems() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateDynamicMenuItems() }
            return
        }
        assertMainThread()
        inlineSearchMenuItem?.keyEquivalent = hotkeyManager.inlineSearchShortcut.menuKeyEquivalent
        inlineSearchMenuItem?.keyEquivalentModifierMask = hotkeyManager.inlineSearchShortcut.menuModifierFlags

        smartDictationMenuItem?.keyEquivalent = hotkeyManager.voiceShortcut.menuKeyEquivalent
        smartDictationMenuItem?.keyEquivalentModifierMask = hotkeyManager.voiceShortcut.menuModifierFlags

        shortcutsToggleMenuItem?.state = HotkeyPreferences.shortcutsDisabled ? .off : .on
        conflictsToggleMenuItem?.state = SnippetStore.isConflictDetectionEnabled ? .on : .off

        rebuildSecretsMenu()
        rebuildRecentMenu()
        refreshStatusItemUI()
    }

    func rebuildRecentMenu() {
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

    func refreshStatusItemUI() {
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
            isSecureInputActive: secureInputActive,
            hasAttemptedTapStart: EventTapEngine.shared.hasAttemptedTapStart
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
        // The status item keeps reporting that the last expansion did not land, but the
        // "Expansion Failed — Restart Engine" *action* is only offered when a restart could
        // plausibly change the outcome. Most refusals come from a guard that was working —
        // the erase precondition held the line, the target moved, Secure Input was up — and
        // leave a perfectly healthy engine behind. Offering a restart for those is what sent
        // users into Permission Recovery to read "All capabilities granted".
        let offersEngineRestart: Bool = {
            switch PermissionCoordinator.shared.lastRecordedInjectOutcome {
            case .failedSilent:
                return true
            case .refused:
                // Absent provenance we cannot prove the engine is fine, so keep the escape hatch.
                return PermissionCoordinator.shared
                    .lastRecordedInjectRefuseProvenance?.kind.warrantsEngineRestart ?? true
            case .postedUnverified, .degradedAXOnly, .succeeded, .none:
                return false
            }
        }()
        restartEngineMenuItem?.isHidden = !offersEngineRestart
        let presentation = StatusItemPresentation(
            display: display,
            snapshot: snapshot,
            isSecureInputActive: statusItemContext.offersCopySecret,
            urgentInject: urgentInject,
            libraryUnhealthy: LibraryHealthMonitor.shared.condition != nil,
            differentiateWithoutColor: DevTypeAccessibility.differentiateWithoutColor,
            highlighted: statusItemContext.menuIsOpen,
            // Urgent, but not a failure: a guard refused and the engine is fine.
            injectIssueIsSafeRefusal: urgentInject && !offersEngineRestart,
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
        permissionRecoveryMenuItem?.title = loc.s("menu.recovery")
        if needsAttention {
            diagnosticsMenuItem?.title = "\(loc.s("menu.diagnostics")) ⚠"
        } else {
            diagnosticsMenuItem?.title = loc.s("menu.diagnostics")
        }
        refreshOpenAtLoginMenuItem()
    }

    private func refreshOpenAtLoginMenuItem() {
        // The item is nil since §4.1, and `SMAppService.mainApp.status` is a synchronous
        // XPC round trip; skip it on every status refresh (each expansion, each menu open).
        guard let item = openAtLoginMenuItem else { return }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleEngine(_ sender: NSMenuItem) {
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
    func syncSelectionMonitorWithAIPreferences() {
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
