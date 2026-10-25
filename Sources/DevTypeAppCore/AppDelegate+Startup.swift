import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

extension AppDelegate {

    /// Accessory apps have no NIB-driven main menu, so ⌘Z/⌘X/⌘C/⌘V/⌘A key
    /// equivalents are dropped before they reach text fields in borderless
    /// panels (snippet editor, group editor, fill-in). Installing a minimal
    /// main menu with a standard Edit submenu restores them app-wide — the
    /// menu bar itself stays hidden under the accessory policy.
    func installEditMenu(force: Bool = false) {
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

    /// Automatic launch/activation retries run away from the main thread because securityd may
    /// stall. Their completion still has to invalidate the visible Advanced pane; without this,
    /// the store can be healthy while Preferences indefinitely shows an earlier cleanup failure.
    func requestOrphanSecretCleanupRetryRefreshingPreferences() {
        SnippetStore.shared.requestOrphanSecretCleanupRetry { _ in
            DispatchQueue.main.async {
                guard PreferencesWindowController.shared.window?.isVisible == true else { return }
                PreferencesWindowController.shared.refreshMaintenanceState()
            }
        }
    }

    func wireTapHealth() {
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
    func wireSecureClipboardPasteHint() {
        TextInjectionPipeline.shared.onSecureClipboardManualPasteHint = { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            let message = LocalizationManager.shared.s(TextInjectionPipeline.secureClipboardManualPasteHintKey)
            button.toolTip = message
            DevTypeLog.app.notice("[App] \(message, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.refreshStatusItemUI()
            }
        }
        // A replace refused because its selection was gone. The pipeline already put the result on
        // the clipboard; without this toast the user would see nothing happen and assume the
        // transform failed.
        TextInjectionPipeline.shared.onSelectionReplaceRefused = { copied in
            let key = copied
                ? TextInjectionPipeline.selectionReplaceRefusedHintKey
                : TextInjectionPipeline.selectionReplaceRefusedNoCopyHintKey
            ToastPanel.show(
                LocalizationManager.shared.s(key),
                symbol: copied ? "doc.on.clipboard.fill" : "exclamationmark.triangle.fill",
                preempt: true
            )
        }
        // A replace whose ⌘V went out but whose result was not found in the field. The result is
        // on the clipboard; the toast is how the user learns the transform did not simply vanish.
        TextInjectionPipeline.shared.onReplaceNotLanded = { copied in
            let key = copied
                ? TextInjectionPipeline.replaceNotLandedHintKey
                : TextInjectionPipeline.replaceNotLandedNoCopyHintKey
            ToastPanel.show(
                LocalizationManager.shared.s(key),
                symbol: copied ? "doc.on.clipboard.fill" : "exclamationmark.triangle.fill",
                preempt: true
            )
        }
    }

    func handleCoordinatorStatus(_ status: PermissionCoordinator.Status) {
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

    func presentOnboardingOrRecoveryIfNeeded() {
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
}
