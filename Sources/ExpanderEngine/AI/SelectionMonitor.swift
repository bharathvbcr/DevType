import ApplicationServices
import Cocoa
import Foundation

/// Observes the frontmost app's selection via `AXObserver` and caches a short-TTL snapshot
/// for the typed AI-snippet path.
///
/// Runs only while the AI feature is enabled and Accessibility is granted. Honors
/// `AppMuteStore` and Secure Event Input. Does **not** use synthetic ⌘C.
///
/// Cache semantics are last-known-good: typing a trigger replaces the selection and fires
/// an empty `kAXSelectedTextChangedNotification`. That must **not** clear the cache —
/// otherwise the typed path never sees the selection it was meant to transform.
public final class SelectionMonitor {
    public static let shared = SelectionMonitor()

    /// Prefs key owned by the AI tab (`devtype.ai.*`). Default off.
    public static let featureEnabledDefaultsKey = "devtype.ai.enabled"

    /// How long a cached selection remains usable for the typed path.
    /// Long enough to type a short trigger; single-use + same-element carry the safety.
    public static let defaultTTL: TimeInterval = 6.0

    /// Minimum spacing between full-ladder cache refreshes.
    ///
    /// The monitor runs from an AX notification many apps fire on *every keystroke*, so the full
    /// attribute ladder cannot run unconditionally. But primary-only means the cache is never
    /// populated for Chromium or Electron — they answer `kAXSelectedText` with nothing and keep
    /// the selection in the range / text-marker forms — so the cache fallback that is supposed
    /// to rescue the hotkey path was empty in exactly the apps that need it. Rate-limiting bounds
    /// the extra IPC to a handful of round-trips a second while making the cache real.
    public static let fallbackLadderMinInterval: TimeInterval = 0.25

    public struct CachedSelection: Equatable {
        public let text: String
        public let bundleID: String
        public let changeToken: UInt64
        public let timestamp: Date

        public init(text: String, bundleID: String, changeToken: UInt64, timestamp: Date) {
            self.text = text
            self.bundleID = bundleID
            self.changeToken = changeToken
            self.timestamp = timestamp
        }

        public func isFresh(asOf now: Date = Date(), maxAge: TimeInterval = SelectionMonitor.defaultTTL) -> Bool {
            now.timeIntervalSince(timestamp) <= maxAge
        }
    }

    private let lock = UnfairLock()
    private var cache: CachedSelection?
    /// AX element that owned the cached text — used for same-element checks at expand time.
    private var cacheElement: AXUIElement?
    private var changeToken: UInt64 = 0
    /// When the full attribute ladder last ran, for `shouldRunFallbackLadder`.
    private var lastFallbackLadderAt: Date?

    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var appSwitchObserver: NSObjectProtocol?
    private var isRunning = false

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        stop()
    }

    // MARK: - Feature gate

    public var isFeatureEnabled: Bool {
        get { defaults.bool(forKey: Self.featureEnabledDefaultsKey) }
        set {
            defaults.set(newValue, forKey: Self.featureEnabledDefaultsKey)
            if newValue {
                start()
            } else {
                stop()
            }
        }
    }

    /// Begin observing when the feature is on and Accessibility is trusted.
    public func start() {
        DispatchQueue.main.async { [weak self] in
            self?.startOnMain()
        }
    }

    /// Tear down the AX observer and app-switch listener; clear the cache.
    public func stop() {
        let teardown: () -> Void = { [weak self] in
            self?.stopOnMain()
        }
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.sync(execute: teardown)
        }
    }

    // MARK: - Cache

    /// Latest cached selection, or `nil` when absent / expired / muted / weak-AX (typed path).
    public func cachedSelection(
        maxAge: TimeInterval = defaultTTL,
        asOf now: Date = Date(),
        rejectWeakAX: Bool = true
    ) -> CachedSelection? {
        lock.lock()
        let snapshot = cache
        lock.unlock()

        guard let snapshot, snapshot.isFresh(asOf: now, maxAge: maxAge) else { return nil }
        guard !snapshot.text.isEmpty else { return nil }
        if AppMuteStore.shared.isMuted(snapshot.bundleID) { return nil }
        if !AIPreferences.isTypedPathAllowed(bundleID: snapshot.bundleID) { return nil }
        if rejectWeakAX, SelectionReader.isWeakAXApp(bundleID: snapshot.bundleID) { return nil }
        if AXContextChecker.isSecureEventInputEnabledLive() { return nil }
        return snapshot
    }

    /// Unfiltered cache snapshot, freshness included, for the *explicit* command paths
    /// (AI hotkey / palette).
    ///
    /// `cachedSelection(…)` layers the typed-path rules on top — allowlist, weak-AX rejection —
    /// and those are wrong here. They exist because a typed trigger is keyed *into* the selection
    /// it means to transform, which is what makes a weak-AX app's stale report dangerous. A
    /// hotkey types nothing. `SelectionReader.evaluate` applies the checks that do belong
    /// (freshness, mute, same-app) so this stays a plain accessor.
    public func rawCachedSelection() -> CachedSelection? {
        lock.lock()
        let snapshot = cache
        lock.unlock()
        return snapshot
    }

    /// True when a fresh cache entry exists but is blocked solely by weak-AX rejection.
    /// Used to show a distinct typed-path hint (not the generic selection-unavailable message).
    public func hasWeakAXBlockedSelection(
        maxAge: TimeInterval = defaultTTL,
        asOf now: Date = Date()
    ) -> Bool {
        lock.lock()
        let snapshot = cache
        lock.unlock()

        guard let snapshot, snapshot.isFresh(asOf: now, maxAge: maxAge) else { return false }
        guard !snapshot.text.isEmpty else { return false }
        if AppMuteStore.shared.isMuted(snapshot.bundleID) { return false }
        if !AIPreferences.isTypedPathAllowed(bundleID: snapshot.bundleID) { return false }
        if AXContextChecker.isSecureEventInputEnabledLive() { return false }
        return SelectionReader.isWeakAXApp(bundleID: snapshot.bundleID)
    }

    /// Peek + single-use consume for the typed expand path.
    ///
    /// Returns `nil` (and clears) when the focused AX element no longer matches the element
    /// that produced the cache entry. Passing `requireSameElement: false` skips that check
    /// (unit tests that seed without a live focus).
    @discardableResult
    public func consumeSelection(
        maxAge: TimeInterval = defaultTTL,
        asOf now: Date = Date(),
        rejectWeakAX: Bool = true,
        requireSameElement: Bool = true
    ) -> CachedSelection? {
        guard let snapshot = cachedSelection(maxAge: maxAge, asOf: now, rejectWeakAX: rejectWeakAX) else {
            return nil
        }

        if requireSameElement {
            lock.lock()
            let storedElement = cacheElement
            lock.unlock()
            if let storedElement {
                guard let focused = AXContextChecker.shared.focusedElement(),
                      CFEqual(storedElement, focused) else {
                    clearCache()
                    return nil
                }
            }
        }

        clearCache()
        return snapshot
    }

    /// Test / recovery hook.
    public func clearCache() {
        lock.lock()
        cache = nil
        cacheElement = nil
        lock.unlock()
    }

    /// Inject a cache entry (unit tests).
    public func seedCacheForTesting(_ selection: CachedSelection, element: AXUIElement? = nil) {
        lock.lock()
        cache = selection
        cacheElement = element
        changeToken = max(changeToken, selection.changeToken)
        lock.unlock()
    }

    /// Simulates the AX selection-refresh path for unit tests (non-empty → empty must keep cache).
    public func testingApplySelectionRefresh(
        text: String?,
        bundleID: String,
        element: AXUIElement?
    ) {
        applySelectionRefresh(text: text, bundleID: bundleID, element: element)
    }

    // MARK: - Main-thread lifecycle

    private func startOnMain() {
        precondition(Thread.isMainThread)
        guard isFeatureEnabled else {
            stopOnMain()
            return
        }
        guard AXContextChecker.shared.isProcessTrusted() else {
            stopOnMain()
            return
        }
        if isRunning {
            reregisterForFrontmostApp()
            return
        }
        isRunning = true
        installAppSwitchObserver()
        reregisterForFrontmostApp()
    }

    private func stopOnMain() {
        precondition(Thread.isMainThread)
        removeAppSwitchObserver()
        unregisterAXObserver()
        isRunning = false
        clearCache()
    }

    private func installAppSwitchObserver() {
        guard appSwitchObserver == nil else { return }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // DevType activating its own panel (⌘/ , ⌘⌥A) is not a user app switch — the
            // selection in the source app is still there and is exactly what the panel is
            // about to act on. Clearing here would empty the cache precisely when it is
            // needed. Keep last-known-good and do not re-register onto ourselves.
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            if activated?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                return
            }
            // A real switch to another app invalidates last-known-good from the previous one.
            self?.clearCache()
            self?.reregisterForFrontmostApp()
        }
    }

    private func removeAppSwitchObserver() {
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }
    }

    private func reregisterForFrontmostApp() {
        precondition(Thread.isMainThread)
        unregisterAXObserver()

        guard isFeatureEnabled, AXContextChecker.shared.isProcessTrusted() else {
            clearCache()
            return
        }
        if AXContextChecker.isSecureEventInputEnabledLive() {
            clearCache()
            return
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            clearCache()
            return
        }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        if !bundleID.isEmpty, AppMuteStore.shared.isMuted(bundleID) {
            clearCache()
            return
        }
        if !AIPreferences.isTypedPathAllowed(bundleID: bundleID) {
            clearCache()
            return
        }

        // Ask a Chromium app to publish its accessibility tree *now*, on the app switch, rather
        // than when the user is already waiting on a hotkey. Without the tree there is no
        // focused element and no selection-changed notification to observe — the observer below
        // would install successfully and then never fire. Once per pid; a non-Chromium app
        // answers "unsupported" and costs one round-trip per launch.
        AXContextChecker.shared.ensureManualAccessibility(pid: pid)

        // New app, new element: let the first refresh pay for the full ladder rather than
        // inheriting the previous app's rate-limit window.
        lock.lock()
        lastFallbackLadderAt = nil
        lock.unlock()

        var observer: AXObserver?
        let createStatus = AXObserverCreate(pid, selectionObserverCallback, &observer)
        guard createStatus == .success, let observer else {
            clearCache()
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXContextChecker.applyMessagingTimeout(to: appElement)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let notifications = [
            kAXSelectedTextChangedNotification as String,
            kAXFocusedUIElementChangedNotification as String
        ]
        for name in notifications {
            let addStatus = AXObserverAddNotification(
                observer,
                appElement,
                name as CFString,
                refcon
            )
            // Some apps reject one or both; still keep whatever succeeded.
            _ = addStatus
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        axObserver = observer
        observedPID = pid

        refreshCacheFromFocus(bundleID: bundleID)
    }

    private func unregisterAXObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(axObserver),
                .defaultMode
            )
            if observedPID != 0 {
                let appElement = AXUIElementCreateApplication(observedPID)
                AXObserverRemoveNotification(
                    axObserver,
                    appElement,
                    kAXSelectedTextChangedNotification as CFString
                )
                AXObserverRemoveNotification(
                    axObserver,
                    appElement,
                    kAXFocusedUIElementChangedNotification as CFString
                )
            }
        }
        axObserver = nil
        observedPID = 0
    }

    fileprivate func handleAXNotification() {
        guard isFeatureEnabled else { return }
        guard AXContextChecker.shared.isProcessTrusted() else {
            clearCache()
            return
        }
        if AXContextChecker.isSecureEventInputEnabledLive() {
            clearCache()
            return
        }
        let bundleID = AXContextChecker.shared.frontmostApplicationBundleIdentifier() ?? ""
        if !bundleID.isEmpty, AppMuteStore.shared.isMuted(bundleID) {
            clearCache()
            return
        }
        if !AIPreferences.isTypedPathAllowed(bundleID: bundleID) {
            clearCache()
            return
        }
        refreshCacheFromFocus(bundleID: bundleID)
    }

    /// Pure policy: may this refresh pay for the range / attributed / marker attributes?
    ///
    /// Only when the cheap primary attribute found nothing (the ladder cannot improve on a hit)
    /// and the last ladder run is far enough back to keep per-keystroke cost bounded.
    static func shouldRunFallbackLadder(
        primaryFoundText: Bool,
        lastLadderAt: Date?,
        now: Date,
        minInterval: TimeInterval = fallbackLadderMinInterval
    ) -> Bool {
        if primaryFoundText { return false }
        guard let lastLadderAt else { return true }
        let elapsed = now.timeIntervalSince(lastLadderAt)
        // A backwards clock jump (NTP correction, sleep/wake) must not lock the ladder out until
        // wall-clock catches up — that would be minutes of a silently non-functioning cache.
        return elapsed < 0 || elapsed >= minInterval
    }

    private func refreshCacheFromFocus(bundleID: String, now: Date = Date()) {
        guard let element = AXContextChecker.shared.focusedElement() else {
            clearCache()
            return
        }
        // Cheap attribute first: this runs from an AX notification that many apps fire on every
        // keystroke, and the extra round-trips are wasted whenever the primary one answers.
        let primary = SelectionReader.copySelectedText(from: element, allowFallbackAttributes: false)

        lock.lock()
        let lastLadderAt = lastFallbackLadderAt
        lock.unlock()

        var text = primary
        if Self.shouldRunFallbackLadder(
            primaryFoundText: !(primary?.isEmpty ?? true),
            lastLadderAt: lastLadderAt,
            now: now
        ) {
            lock.lock()
            lastFallbackLadderAt = now
            lock.unlock()
            text = SelectionReader.copySelectedText(from: element, allowFallbackAttributes: true)
        }
        applySelectionRefresh(text: text, bundleID: bundleID, element: element)
    }

    /// Shared refresh logic used by live AX notifications and unit tests.
    ///
    /// - Non-empty text → store (last-known-good update).
    /// - Empty / unreadable text on the **same** element → keep existing cache (TTL retires it).
    /// - Focus moved to a **different** AX element → clear, then store only if the new
    ///   element has a non-empty selection.
    private func applySelectionRefresh(text: String?, bundleID: String, element: AXUIElement?) {
        lock.lock()
        let previousElement = cacheElement
        lock.unlock()

        if let previousElement, let element, !CFEqual(previousElement, element) {
            clearCache()
        } else if previousElement != nil, element == nil {
            clearCache()
            return
        }

        guard let text, !text.isEmpty else {
            // Empty selection on the same element: keep last-known-good for TTL.
            return
        }
        storeCache(text: text, bundleID: bundleID, element: element)
    }

    private func storeCache(text: String, bundleID: String, element: AXUIElement?) {
        lock.lock()
        changeToken &+= 1
        let token = changeToken
        cache = CachedSelection(
            text: text,
            bundleID: bundleID,
            changeToken: token,
            timestamp: Date()
        )
        cacheElement = element
        lock.unlock()
    }
}

private func selectionObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<SelectionMonitor>.fromOpaque(refcon).takeUnretainedValue()
    // AX callbacks arrive on the run-loop that owns the observer (main).
    monitor.handleAXNotification()
}
