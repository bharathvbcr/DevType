import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

extension AppDelegate {
    @objc func openSnippetManager(_ sender: Any?) {
        if snippetWindowController == nil || snippetWindowController?.window == nil {
            let viewController = SnippetManagerViewController()
            let window = NSWindow(contentViewController: viewController)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 920, height: 600))
            window.minSize = NSSize(width: 700, height: 460)
            // §6.1: window titles were hardcoded English.
            DevTypeTheme.styleWindow(window, title: loc.s("window.snippets"))
            window.dtRestoreFrame(named: "DevTypeSnippetManagerWindow")
            window.isReleasedWhenClosed = false
            snippetWindowController = NSWindowController(window: window)
            snippetManagerRenderedLanguage = loc.language
        } else if snippetManagerRenderedLanguage != loc.language {
            refreshSnippetManagerLocalization()
        }

        guard let window = snippetWindowController?.window else { return }
        WindowOrdering.makeKeyAndOrderFront(window, context: "Snippets")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            WindowOrdering.makeKeyAndOrderFront(window, context: "Snippets")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func openSnippetManager(filteringBy filterChip: SnippetFilterChip) {
        // A navigation chip names a different window. Route before opening the snippet manager,
        // or asking for secrets would raise the snippet manager *and* the Secrets manager and
        // leave the wrong one in front.
        guard filterChip.listFilter != nil else {
            openSecretManager(nil)
            return
        }
        openSnippetManager(nil)
        (snippetWindowController?.contentViewController as? SnippetManagerViewController)?
            .showAllSnippets(filteredBy: filterChip)
    }

    /// Rebuilds AppKit labels that were materialized in the previous language while carrying
    /// transient manager navigation and its undo stack forward. A visible editor sheet owns
    /// unsaved input, so replacement is deferred until the next show rather than dropping it.
    func refreshSnippetManagerLocalization() {
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

    @objc func openRecentActivity(_ sender: Any?) {
        ActivityCenterViewController.show()
    }

    /// Menu-bar "Diagnostics…": same window as Recovery, pre-selected on the
    /// Diagnostics tab so the OSLog dump is one click from the menu bar.
    @objc func openDiagnostics(_ sender: Any?) {
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
            WindowOrdering.makeKeyAndOrderFront(onboardingWindowController?.window, context: "Onboarding")
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
            window.dtRestoreFrame(named: "DevTypePermissionRecoveryWindow")
            window.isReleasedWhenClosed = false
            permissionWindowController = NSWindowController(window: window)
        }

        guard let window = permissionWindowController?.window else { return }
        WindowOrdering.makeKeyAndOrderFront(window, context: "PermissionRecovery")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            WindowOrdering.makeKeyAndOrderFront(window, context: "PermissionRecovery")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func openOnboarding() {
        // Single-flight: launch path + onIdentityResolved can both call presentOnboardingOrRecoveryIfNeeded.
        if let existing = onboardingWindowController?.window, existing.isVisible {
            DevTypeLog.permission.debug("[Permission] UI → onboarding already visible (single-flight)")
            onboardingPresentationInFlight = false
            PermissionRequester.shared.beginSetupActivation()
            WindowOrdering.makeKeyAndOrderFront(existing, context: "Onboarding")
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
            // Deliberately not frame-restoring: setup is a fixed-size, non-resizable, one-time
            // flow, and centring is the right presentation every time it appears.
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
        WindowOrdering.makeKeyAndOrderFront(onboardingWindowController?.window, context: "Onboarding")
        NSApp.activate(ignoringOtherApps: true)
        onboardingPresentationInFlight = false
    }
}
