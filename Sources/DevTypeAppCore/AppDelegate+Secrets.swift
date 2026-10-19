import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

extension AppDelegate {
    // MARK: - Secrets (mouse-only path for password fields)

    func rebuildSecretsMenu() {
        assertMainThread()
        // Store/preference callbacks can arrive during menu tracking too.
        guard !statusItemContext.menuIsOpen else {
            menuRebuildPending = true
            return
        }
        guard let secretsSubmenu else { return }
        secretsSubmenu.removeAllItems()

        let manage = NSMenuItem(title: loc.s("secrets.manage"), action: #selector(openSecretManager(_:)), keyEquivalent: "")
        manage.target = self
        manage.image = DevTypeTheme.menuIcon("key.fill")
        secretsSubmenu.addItem(manage)
        secretsSubmenu.addItem(.separator())
        let allEnabled = SnippetStore.shared.loadSecrets().filter(\.enabled)
        let secrets = SecretMenuFlow.secretMenuEntries(from: allEnabled.map(\.snippetAdapter))

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

        // The submenu is capped. Showing 20 of 25 with nothing to say so invites the reading that
        // the other five are gone — so say how many are not listed, and name the entry that finds
        // them. A capped sample is never presented as the whole set.
        let hidden = allEnabled.count - secrets.count
        if hidden > 0 {
            let more = NSMenuItem(title: loc.s("menu.copySecret.more", String(hidden)),
                                  action: nil, keyEquivalent: "")
            more.isEnabled = false
            secretsSubmenu.addItem(.separator())
            secretsSubmenu.addItem(more)
        }
        appendBiometryToggle(to: secretsSubmenu)
    }

    @objc func openSecretManager(_ sender: Any?) {
        if secretWindowController == nil {
            let controller = SecretManagerViewController(onCopy: { [weak self] secret in
                self?.copyToClipboard(secret.snippetAdapter)
            }, onRepair: { [weak self] in
                self?.openPreferences(nil, tab: .advanced)
            })
            let window = NSWindow(contentViewController: controller)
            window.title = loc.s("secrets.title")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 620, height: 470))
            window.minSize = NSSize(width: 620, height: 470)
            window.dtRestoreFrame(named: "DevTypeSecretsWindow")
            secretWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        WindowOrdering.makeKeyAndOrderFront(secretWindowController?.window, context: "Secrets")
    }

    /// Copy palette narrowed to secrets, for libraries with more of them than a submenu can hold.
    @objc func openSecretSearch(_ sender: Any?) {
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
        // Switching the requirement *off* is authenticated by the requirement itself, so the
        // menu is rebuilt from what ended up in force rather than from what was clicked.
        SecretPreferences.requestRequireBiometry(enabled) { [weak self] _ in
            guard let self else { return }
            self.rebuildSecretsMenu()
            // The same switch lives in Preferences; an open window must not show the opposite of
            // what is now in force.
            if PreferencesWindowController.shared.window?.isVisible == true {
                PreferencesWindowController.shared.refreshSecretsCard()
            }
        }
    }

    @objc private func copySecretFromMenu(_ sender: NSMenuItem) {
        guard let snippet = sender.representedObject as? SnippetModel else { return }
        copyToClipboard(snippet)
    }

    /// Palette in copy mode: search, pick, and the value lands on the clipboard instead of being
    /// injected. Reachable from the menu, so it works when the palette *shortcut* cannot fire.
    @objc func openCopyPalette(_ sender: Any?) {
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
                        symbol: "exclamationmark.triangle.fill",
                        preempt: true
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
    func offerSecretMigration(for snippet: SnippetModel, pendingCount: Int, thenRetry retry: @escaping () -> Void) {
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
    func offerKeychainUnlock(thenRetry retry: @escaping () -> Void) {
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

    /// Nested-snippet lookup for the current library. The index is rebuilt only when the store's
    /// revision moves; the revision and groups are read together so a save landing in between
    /// cannot pair an old index with a new revision.
    func nestedSnippetLookup() -> (String) -> String? {
        let (groups, revision) = SnippetStore.shared.loadGroupsWithRevision()
        if let cached = nestedResolverCache, cached.revision == revision {
            return cached.resolver.lookup
        }
        let resolver = NestedSnippetResolver(snippets: groups.flatMap(\.snippets))
        nestedResolverCache = (revision, resolver)
        return resolver.lookup
    }

    func copyToClipboard(_ snippet: SnippetModel) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        // Secrets are excluded from nested `{{snippet:…}}` lookups: resolving one here would
        // paste a password into whatever document the outer snippet lands in, with no explicit
        // gesture naming it.
        let lookup = nestedSnippetLookup()

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

    func applyCopyResult(
        _ result: Result<String, SecretMenuFlow.ResolveFailure>,
        for snippet: SnippetModel
    ) {
        switch result {
        case .success(let text):
            guard SecretClipboard.shared.copyResult(text).didCopy else {
                ToastPanel.show(
                    loc.s("clipboard.write.failed"),
                    symbol: "exclamationmark.triangle.fill",
                    preempt: true
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
        case .failure(.macroFailed(let reason)):
            ToastPanel.show(reason, symbol: "exclamationmark.triangle.fill", preempt: true)
        case .failure(.selectionChanged):
            ToastPanel.show(loc.s("manager.action.stale.message"), symbol: "exclamationmark.triangle.fill", preempt: true)
        case .failure(.secretUnavailable):
            DevTypeAlert.present(
                title: loc.s("secret.missing.title"),
                message: loc.s("secret.missing.message", snippet.displayTitle),
                style: .warning,
                buttons: [loc.s("secrets.manage"), loc.s("common.ok")]
            ) { index in
                if index == 0 { self.openSecretManager(nil) }
            }
        case .failure(.imageSnippet(let path)):
            // Copy the picture itself. The clipboard is the one place an image snippet and a text
            // snippet mean the same gesture, so refusing here would be an arbitrary hole.
            guard let image = ImageAttachmentStore.shared.loadImage(path: path) else {
                ToastPanel.show(
                    loc.s("snippet.copied.empty"),
                    symbol: "exclamationmark.triangle.fill",
                    preempt: true
                )
                return
            }
            guard PasteboardBroker.shared.writeUserClipboardImage(image) else {
                ToastPanel.show(
                    loc.s("clipboard.write.failed"),
                    symbol: "exclamationmark.triangle.fill",
                    preempt: true
                )
                return
            }
            SnippetStore.shared.incrementUsage(for: snippet.id)
            ToastPanel.show(loc.s("snippet.copied.toast", snippet.displayTitle), symbol: "photo")

        case .failure(.emptySnippet):
            // Copying "" would wipe whatever the user already had on the clipboard. A beep alone
            // left the user unsure whether anything had happened at all.
            ToastPanel.show(
                loc.s("snippet.copied.empty"),
                symbol: "exclamationmark.triangle.fill",
                preempt: true
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

    func recordRecent(_ snippet: SnippetModel) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentSnippetIDs = RecentSnippetResolver.record(
                snippet,
                in: self.recentSnippetIDs
            )
            self.rebuildRecentMenu()
        }
    }

    @objc func expandRecent(_ sender: NSMenuItem) {
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
}
