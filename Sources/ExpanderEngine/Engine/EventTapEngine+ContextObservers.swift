import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Cached frontmost context maintenance and observers.
extension EventTapEngine {
    // MARK: - §2.3 cached-context maintenance

    /// Reads `NSWorkspace` **on main** and refreshes the cached frontmost context.
    /// Public so the app can re-prime after a state change it knows about.
    public func primeFrontmostContext() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.primeFrontmostContext()
            }
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        updateFrontmostContext(bundleID: app?.bundleIdentifier, processID: app?.processIdentifier)
    }

    private func updateFrontmostContext(bundleID: String?, processID: pid_t?) {
        // Both of these are pure lookups (a `Set` membership test and a dictionary read behind
        // `AppMuteStore`'s own lock) — no AppKit, so the tap thread never has to repeat them.
        let muted = bundleID.map { AppMuteStore.shared.isMuted($0) } ?? false
        let terminal = bundleID.map { AXContextChecker.shared.isTerminalBundleID($0) } ?? false
        contextLock.lock()
        _frontmostContext = FrontmostContext(
            bundleID: bundleID,
            processID: processID,
            isMuted: muted,
            isTerminal: terminal
        )
        contextLock.unlock()
    }

    /// §2.3: copies the owner's snapshot into the tap's own flag once per input-source change
    /// instead of once per keystroke. Never calls TIS; any thread.
    func refreshInputSourceCache() {
        let allow = KeyboardLayoutState.shared.snapshot().isTwoSetKorean
        contextLock.lock()
        _allowPhysicalFallback = allow
        contextLock.unlock()
    }

    func installMuteListObserver() {
        guard !muteObserverInstalled else { return }
        muteObserverInstalled = true
        AppMuteStore.shared.addListener { [weak self] in
            self?.refreshMuteFlag()
        }
    }

    private func refreshMuteFlag() {
        contextLock.lock()
        let bundleID = _frontmostContext.bundleID
        contextLock.unlock()
        let muted = bundleID.map { AppMuteStore.shared.isMuted($0) } ?? false
        contextLock.lock()
        // An app switch may have landed between the two sections — only apply if still current.
        if _frontmostContext.bundleID == bundleID {
            _frontmostContext.isMuted = muted
        }
        contextLock.unlock()
    }

    func installAppSwitchObserver() {
        guard appSwitchObserver == nil else { return }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            pipeline.clearLastExpansion()
            // §2.3: refresh the cache here rather than calling NSWorkspace from the tap thread.
            // The notification already carries the application that just activated.
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self.updateFrontmostContext(
                    bundleID: app.bundleIdentifier,
                    processID: app.processIdentifier
                )
                // Ask a Chromium app to publish its accessibility tree now, on the switch,
                // rather than while a trigger is mid-expansion. Without the tree there is no
                // focused element, so the erase precondition cannot verify the field and every
                // expand in the app degrades to best-effort. `SelectionMonitor` does the same
                // poke, but only while the AI feature is on — expansion must not depend on that.
                // Memoized per pid. A cold app often times out the first 50 ms write; one follow-up
                // then settles "unsupported" or turns the Chromium tree on. Dispatched off this
                // notification thread so the tap never waits on AX IPC.
                let pid = app.processIdentifier
                if pid > 0, pid != ProcessInfo.processInfo.processIdentifier {
                    DispatchQueue.main.async {
                        AXContextChecker.shared.ensureManualAccessibility(pid: pid)
                    }
                }
            } else {
                self.primeFrontmostContext()
            }
            self.resetBuffer()
        }
    }

    func removeAppSwitchObserver() {
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    /// The layout owner refreshes on main (initial prime and every system layout change) and
    /// calls back here on main.
    func installInputSourceObserver() {
        guard layoutListener == nil else { return }
        layoutListener = KeyboardLayoutState.shared.addChangeListener { [weak self] in
            // §2.3: recompute the physical-fallback flag here, not per keystroke.
            self?.refreshInputSourceCache()
            self?.resetBuffer()
        }
    }

    func removeInputSourceObserver() {
        if let token = layoutListener {
            KeyboardLayoutState.shared.removeChangeListener(token)
            layoutListener = nil
        }
    }
}
