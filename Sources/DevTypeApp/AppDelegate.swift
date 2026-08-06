import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

// MARK: - Main Application Delegate
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var snippetWindowController: NSWindowController?
    private var permissionWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?
    private var statusToggleMenuItem: NSMenuItem?
    private var permissionRecoveryMenuItem: NSMenuItem?
    private var openAtLoginMenuItem: NSMenuItem?
    private var menuHeaderStatusPill: PillBadgeView?
    private var recentSubmenu: NSMenu?
    private var recentSnippets: [SnippetModel] = []
    private var lastTapStartFailed = false
    private var lastLoggedDisplayStatus: EngineDisplayStatus?
    /// Single-flight: launch + CDHash callback must not open Setup twice.
    private var onboardingPresentationInFlight = false
    private let hotkeyManager = HotkeyManager()
    private let loc = LocalizationManager.shared

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

        let identity = ProcessIdentity.shared
        DevTypeLog.app.info(
            "[App] launch bundleID=\(identity.bundleIdentifier, privacy: .public) packaged=\(identity.isPackaged, privacy: .public) path=\(identity.bundlePath, privacy: .public)"
        )

        setupStatusItem()
        bindSnippetStore()
        wireExpansionUsage()
        registerHotkeys()
        wireSecureClipboardPasteHint()
        presentCorruptionAlertIfNeeded()
        startSecureInputMonitoring()
        wireTapHealth()

        NotificationCenter.default.addObserver(
            forName: .devTypeLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildMenu()
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
    private func installEditMenu() {
        guard NSApp.mainMenu == nil || NSApp.mainMenu?.numberOfItems == 0 else { return }
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        PermissionCoordinator.shared.handleApplicationDidBecomeActive()
        if let recovery = permissionWindowController?.contentViewController as? PermissionRecoveryController {
            recovery.refreshFromAppActivation()
        }
        if let onboarding = onboardingWindowController?.contentViewController as? PermissionOnboardingController {
            onboarding.refreshFromAppActivation()
        }
        refreshStatusItemUI()
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
            if onboardingWindowController?.window?.isVisible == true || onboardingPresentationInFlight {
                DevTypeLog.permission.debug(
                    "[Permission] UI → skip duplicate onboarding schedule (single-flight)"
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
            button.image = DevTypeTheme.statusItemImage(dotColor: DevTypeTheme.statusGray)
            button.imagePosition = .imageOnly
        }
        statusItem?.menu = buildMenu()
        // Do not refresh here — Listen+AX can already be granted while the tap is not
        // installed yet. Refreshing would flash Tap Failed before coordinator.start().
    }

    private func rebuildMenu() {
        statusItem?.menu = buildMenu()
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

        let pill = PillBadgeView(text: "Active", tint: DevTypeTheme.statusGreen, showsDot: true)
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

        menu.addItem(item(loc.s("menu.manage"), "square.stack.3d.up", #selector(openSnippetManager(_:)), key: ","))
        menu.addItem(item(loc.s("menu.inlineSearch"), "magnifyingglass", #selector(toggleInlineSearch(_:)), key: "/"))
        menu.addItem(item(loc.s("menu.import"), "square.and.arrow.down", #selector(importSnippets(_:))))

        // Recent expansions submenu.
        let recentItem = NSMenuItem(title: loc.s("menu.recent"), action: nil, keyEquivalent: "")
        recentItem.image = DevTypeTheme.menuIcon("clock.arrow.circlepath")
        let recentMenu = NSMenu()
        recentItem.submenu = recentMenu
        recentSubmenu = recentMenu
        rebuildRecentMenu()
        menu.addItem(recentItem)

        menu.addItem(NSMenuItem.separator())

        let toggleItem = item("Status: Active", "pause.circle", #selector(toggleEngine(_:)))
        menu.addItem(toggleItem)
        statusToggleMenuItem = toggleItem

        let openAtLoginItem = item(loc.s("menu.openAtLogin"), "sunrise", #selector(toggleOpenAtLogin(_:)))
        menu.addItem(openAtLoginItem)
        openAtLoginMenuItem = openAtLoginItem
        refreshOpenAtLoginMenuItem()

        // Language submenu.
        let languageItem = NSMenuItem(title: loc.s("menu.language"), action: nil, keyEquivalent: "")
        languageItem.image = DevTypeTheme.menuIcon("globe")
        let languageMenu = NSMenu()
        for language in AppLanguage.allCases {
            let entry = NSMenuItem(title: language.endonym, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = language.rawValue
            entry.state = loc.language == language ? .on : .off
            languageMenu.addItem(entry)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(NSMenuItem.separator())

        let recoveryItem = item(loc.s("menu.recovery"), "checkmark.shield", #selector(openPermissionRecovery(_:)), key: "P", modifiers: [.command, .shift])
        menu.addItem(recoveryItem)
        permissionRecoveryMenuItem = recoveryItem

        menu.addItem(item(loc.s("menu.diagnoseSecure"), "lock.shield", #selector(diagnoseSecureInput(_:)), key: "s", modifiers: []))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(item(loc.s("menu.mute.front"), "speaker.slash", #selector(muteFrontmostApp(_:))))
        menu.addItem(item(loc.s("menu.mute.apps"), "speaker.slash.fill", #selector(showMutedApps(_:))))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(item(loc.s("menu.quit"), "power", #selector(quitApp(_:)), key: "q"))
        return menu
    }

    private func rebuildRecentMenu() {
        guard let recentSubmenu else { return }
        recentSubmenu.removeAllItems()
        if recentSnippets.isEmpty {
            let empty = NSMenuItem(title: loc.s("menu.recent.empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentSubmenu.addItem(empty)
            return
        }
        for snippet in recentSnippets {
            let title = snippet.triggerKeyword.isEmpty
                ? snippet.displayTitle
                : "\(snippet.triggerKeyword) — \(snippet.displayTitle)"
            let item = NSMenuItem(title: title, action: #selector(expandRecent(_:)), keyEquivalent: "")
            item.target = self
            item.image = DevTypeTheme.menuIcon("text.insert")
            item.representedObject = snippet
            recentSubmenu.addItem(item)
        }
    }

    private func recordRecent(_ snippet: SnippetModel) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentSnippets.removeAll { $0.id == snippet.id }
            self.recentSnippets.insert(snippet, at: 0)
            if self.recentSnippets.count > 6 {
                self.recentSnippets.removeLast(self.recentSnippets.count - 6)
            }
            self.rebuildRecentMenu()
        }
    }

    @objc private func expandRecent(_ sender: NSMenuItem) {
        guard let snippet = sender.representedObject as? SnippetModel else { return }
        expandFromSearch(snippet, sourceApp: nil)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        loc.language = language
    }

    private func bindSnippetStore() {
        SnippetStore.shared.addListener { snippets in
            EventTapEngine.shared.snippets = snippets
        }
    }

    private func wireExpansionUsage() {
        EventTapEngine.shared.onExpansionSucceeded = { [weak self] snippet in
            SnippetStore.shared.incrementUsage(for: snippet.id)
            self?.recordRecent(snippet)
        }
        EventTapEngine.shared.presentFillIn = { title, fields, completion in
            _ = FillInPanel.present(title: title, fields: fields, completion: completion)
        }
    }

    private func registerHotkeys() {
        hotkeyManager.onInlineSearch = { [weak self] in
            self?.toggleInlineSearch(nil)
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
        hotkeyManager.registerAll()
    }

    @objc private func toggleInlineSearch(_ sender: Any?) {
        InlineSearchPanel.toggle { [weak self] snippet, sourceApp in
            self?.expandFromSearch(snippet, sourceApp: sourceApp)
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

        EventTapEngine.shared.suspendMatching()
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
            completion: {
                EventTapEngine.shared.resumeMatching()
                SnippetStore.shared.incrementUsage(for: snippet.id)
                self.recordRecent(snippet)
                self.refreshStatusItemUI()
            }
        )
    }

    /// Unified import: one panel, format auto-detected (TextExpander or Espanso).
    @objc private func importSnippets(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a TextExpander settings folder, or an Espanso config folder, match directory, package, or .yml file"

        if let first = SnippetImporter.detectedSources().first {
            panel.directoryURL = first.kind == .textExpander
                ? first.url.deletingLastPathComponent()
                : first.url
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let result = try SnippetStore.shared.importSnippets(from: url)
                let alert = NSAlert()
                alert.messageText = "Import Complete"
                var text = """
                Imported \(result.snippetCount) snippets in \(result.groupCount) groups from \(result.kind.rawValue):
                \(result.sourcePath)
                """
                if !result.notes.isEmpty {
                    text += "\n\n" + result.notes.joined(separator: "\n")
                }
                alert.informativeText = text
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Import Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func warnIfTextExpanderRunning() {
        let apps = NSWorkspace.shared.runningApplications
        let teRunning = apps.contains {
            RunningAppCheck.isTextExpander(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }
        guard teRunning else { return }
        let alert = NSAlert()
        alert.messageText = "TextExpander Detected"
        alert.informativeText = loc.s("menu.textExpanderWarning")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func warnIfEspansoRunning() {
        let apps = NSWorkspace.shared.runningApplications
        let running = apps.contains {
            RunningAppCheck.isEspanso(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }
        guard running else { return }
        let alert = NSAlert()
        alert.messageText = "Espanso Detected"
        alert.informativeText = loc.s("menu.espansoWarning")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentCorruptionAlertIfNeeded() {
        guard let issue = SnippetStore.shared.consumeLastLoadIssue() else { return }
        if case .corrupted(let backupURL) = issue {
            let alert = NSAlert()
            alert.messageText = "Snippet File Recovered"
            alert.informativeText = """
            Your snippets.json could not be read and was replaced with defaults.
            A backup was saved at:
            \(backupURL.path)
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func presentTapFailedAlert() {
        let alert = NSAlert()
        alert.messageText = "Event Tap Failed"
        alert.informativeText = EngineDisplayStatus.tapFailedRecoveryGuidance
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open Permission Recovery")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        DevTypeLog.eventTap.notice(
            "[EventTap] Tap Failed alert dismissed openRecovery=\(response == .alertFirstButtonReturn, privacy: .public)"
        )
        if response == .alertFirstButtonReturn {
            openPermissionRecovery(nil)
        }
        refreshStatusItemUI()
    }

    private func startSecureInputMonitoring() {
        SecureInputMonitor.shared.startMonitoring(interval: 0.35) { [weak self] status in
            EventTapEngine.shared.isSecureInputActive = status.isLocked
            self?.refreshStatusItemUI()
        }
    }

    private func statusColor(for display: EngineDisplayStatus, urgent: Bool) -> NSColor {
        switch display {
        case .active:
            return urgent ? DevTypeTheme.statusOrange : DevTypeTheme.statusGreen
        case .secure:
            return NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 1.0)
        case .paused:
            return DevTypeTheme.statusGray
        case .needsPermissions, .tapFailed:
            return DevTypeTheme.accent
        }
    }

    private func refreshStatusItemUI() {
        let snapshot = PermissionProbe().snapshot()
        let display = EngineDisplayStatus.resolve(
            snapshot: snapshot,
            isTapRunning: EventTapEngine.shared.isTapRunning,
            isEnabled: EventTapEngine.shared.isEnabled,
            isSecureInputActive: EventTapEngine.shared.isSecureInputActive
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
        let color = statusColor(for: display, urgent: urgentInject || snapshot.isDegradedInject)
        if let button = statusItem?.button {
            button.image = DevTypeTheme.statusItemImage(dotColor: color)
            button.title = ""
            button.toolTip = display.toolTip(snapshot: snapshot)
        }
        if urgentInject, display == .active {
            statusToggleMenuItem?.title = "Status: Inject Issue ⚠"
        } else {
            statusToggleMenuItem?.title = display.menuTitleWithActionHint
        }
        statusToggleMenuItem?.image = DevTypeTheme.menuIcon(
            display == .paused ? "play.circle" : "pause.circle"
        )
        let shortStatus = display.menuTitle.replacingOccurrences(of: "Status: ", with: "")
        menuHeaderStatusPill?.update(text: shortStatus, tint: color)
        if display.requiresAction || snapshot.isDegradedInject || urgentInject {
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

    @objc private func openSnippetManager(_ sender: Any?) {
        if snippetWindowController == nil || snippetWindowController?.window == nil {
            let viewController = SnippetManagerViewController()
            let window = NSWindow(contentViewController: viewController)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 920, height: 600))
            window.minSize = NSSize(width: 700, height: 460)
            DevTypeTheme.styleWindow(window, title: "DevType — Snippets")
            window.center()
            window.isReleasedWhenClosed = false
            snippetWindowController = NSWindowController(window: window)
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

    @objc func openPermissionRecovery(_ sender: Any?) {
        DevTypeLog.permission.info("[Permission] UI → open Permission Recovery")
        if permissionWindowController == nil || permissionWindowController?.window == nil {
            let viewController = PermissionRecoveryController { [weak self] in
                self?.refreshStatusItemUI()
            }
            let window = NSWindow(contentViewController: viewController)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 720))
            DevTypeTheme.styleWindow(window, title: "DevType — Permission Recovery")
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
            DevTypeTheme.styleWindow(window, title: "DevType — Setup")
            window.center()
            window.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onboardingPresentationInFlight = false
                PermissionRequester.shared.endSetupActivation()
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

    @objc private func toggleOpenAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Open at Login"
            alert.informativeText = "Could not update login item: \(error.localizedDescription)\n\nOpen at Login requires the packaged DevType.app bundle."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refreshOpenAtLoginMenuItem()
    }

    @objc private func diagnoseSecureInput(_ sender: NSMenuItem) {
        let lockStatus = SecureInputMonitor.shared.checkLockStatus()
        DevTypeLog.secureInput.info(
            "[SecureInput] diagnose locked=\(lockStatus.isLocked, privacy: .public) frontmost=\(lockStatus.holdingAppName ?? "nil", privacy: .public) frontmostPID=\(lockStatus.holdingPID.map(String.init) ?? "nil", privacy: .public)"
        )
        let alert = NSAlert()
        alert.messageText = "Secure Input Diagnosis"
        if lockStatus.isLocked {
            alert.alertStyle = .warning
            alert.informativeText = """
            Secure Input is currently ENABLED by macOS.
            Expansions are muted until the lock is released.

            Secure Input holder: unknown on macOS 27+ (the private Secure Input PID API was removed). DevType cannot identify which process holds the lock.

            Frontmost app (NOT the Secure Input holder — context only):
            • Name: \(lockStatus.holdingAppName ?? "Unknown")
            • Frontmost PID: \(lockStatus.holdingPID.map { String($0) } ?? "Unknown")
            • Path: \(lockStatus.holdingExecutablePath ?? "Unknown")

            Resolution: Close or leave password / secure fields. Do not treat the frontmost PID as the lock holder.
            """
        } else {
            alert.alertStyle = .informational
            alert.informativeText = "Secure Input is currently DISABLED. Keyboard expansion is functioning normally."
        }
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    @objc private func muteFrontmostApp(_ sender: NSMenuItem) {
        guard let bundleID = AppMuteStore.shared.muteFrontmost() else {
            let alert = NSAlert()
            alert.messageText = "Mute Frontmost App"
            alert.informativeText = "Could not determine the frontmost application bundle identifier."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "App Muted"
        alert.informativeText = "Expansions are disabled in:\n\(bundleID)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showMutedApps(_ sender: NSMenuItem) {
        let muted = AppMuteStore.shared.allMuted()
        let alert = NSAlert()
        alert.messageText = "Muted Apps"
        if muted.isEmpty {
            alert.informativeText = "No apps are muted. Use “Mute Frontmost App” while the target app is active."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.informativeText = muted.joined(separator: "\n") + "\n\nSelect an app below to unmute, or Close."
        for id in muted {
            alert.addButton(withTitle: "Unmute \(id)")
        }
        alert.addButton(withTitle: "Close")
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index >= 0 && index < muted.count {
            AppMuteStore.shared.unmute(muted[index])
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        DevTypeLog.app.info("[App] quit requested")
        EventTapEngine.shared.stop()
        SecureInputMonitor.shared.stopMonitoring()
        PermissionCoordinator.shared.cancelPendingWork()
        PermissionCoordinator.shared.stop()
        NSApplication.shared.terminate(nil)
    }
}
