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

    /// How long it remains usable to an *explicit* command while DevType itself owns the focus.
    ///
    /// Six seconds is the right budget for the typed path, where the clock runs while the user is
    /// still in their app and the selection can change under us at any keystroke. It is the wrong
    /// budget once our own panel is frontmost: nothing the user does in DevType can alter the
    /// selection behind it, and *any* return to another app — including back to the source —
    /// clears the cache outright through `didActivateApplication`. So the only way to consume a
    /// stale entry here is for the source app to change its own selection with the user parked in
    /// our UI, and the panel shows the text before a single character is written.
    ///
    /// Bounded rather than infinite because a panel left open all afternoon should not transform
    /// this morning's paragraph. Two minutes covers "open the palette, get distracted, come back";
    /// past that, re-selecting is the honest answer.
    public static let ownFocusTTL: TimeInterval = 120.0

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
    private let environment: Environment

    /// The live-system facts this class consults, behind an injectable seam.
    ///
    /// Each was read through a global, and each is a property of the *machine and its preferences*
    /// rather than of the monitor: `IsSecureEventInputEnabled()` flips whenever anything anywhere
    /// focuses a password field, the frontmost app is whatever the user last clicked, and the mute
    /// list and typed-path allowlist live in `UserDefaults.standard`. That made the
    /// unit tests non-hermetic in the worst way — green on a quiet desktop, seven failures when a
    /// notification banner happened to be up while the suite ran, and no relation to the code
    /// under test. It also left the own-frontmost branch of `mayApplyRefresh` untestable through
    /// the funnel, since a test process cannot make itself frontmost.
    public struct Environment {
        public var isSecureInputActive: () -> Bool
        public var isOwnProcessFrontmost: () -> Bool
        public var isMuted: (String) -> Bool
        public var isTypedPathAllowed: (String) -> Bool

        public init(
            isSecureInputActive: @escaping () -> Bool,
            isOwnProcessFrontmost: @escaping () -> Bool,
            isMuted: @escaping (String) -> Bool,
            isTypedPathAllowed: @escaping (String) -> Bool
        ) {
            self.isSecureInputActive = isSecureInputActive
            self.isOwnProcessFrontmost = isOwnProcessFrontmost
            self.isMuted = isMuted
            self.isTypedPathAllowed = isTypedPathAllowed
        }

        /// What the app runs with: every fact read live at the moment it matters.
        public static let live = Environment(
            isSecureInputActive: { AXContextChecker.isSecureEventInputEnabledLive() },
            isOwnProcessFrontmost: { SelectionMonitor.isOwnProcessFrontmost() },
            isMuted: { AppMuteStore.shared.isMuted($0) },
            isTypedPathAllowed: { AIPreferences.isTypedPathAllowed(bundleID: $0) }
        )

        /// A pinned desktop and pinned preferences, for tests that are about the cache rather
        /// than about the machine they run on. Without this a developer who has muted an app —
        /// or a password field open anywhere on the system — reddens a suite that has nothing to
        /// do with either.
        public static func fixed(
            secureInput: Bool = false,
            ownProcessFrontmost: Bool = false,
            muted: Set<String> = [],
            typedPathAllowlist: Set<String> = []
        ) -> Environment {
            Environment(
                isSecureInputActive: { secureInput },
                isOwnProcessFrontmost: { ownProcessFrontmost },
                isMuted: { muted.contains($0) },
                isTypedPathAllowed: { typedPathAllowlist.isEmpty || typedPathAllowlist.contains($0) }
            )
        }
    }

    public init(defaults: UserDefaults = .standard, environment: Environment = .live) {
        self.defaults = defaults
        self.environment = environment
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
        if environment.isMuted(snapshot.bundleID) { return nil }
        if !environment.isTypedPathAllowed(snapshot.bundleID) { return nil }
        if rejectWeakAX, SelectionReader.isWeakAXApp(bundleID: snapshot.bundleID) { return nil }
        if environment.isSecureInputActive() { return nil }
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
        if environment.isMuted(snapshot.bundleID) { return false }
        if !environment.isTypedPathAllowed(snapshot.bundleID) { return false }
        if environment.isSecureInputActive() { return false }
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

        // Before `unregisterAXObserver()`: when *we* are frontmost there is nothing to observe and
        // nothing to invalidate. Rebinding here would tear the observer off the app whose selection
        // the cache describes and point it at our own panel — the state the app-switch observer
        // already refuses to enter, reachable from the other direction by toggling the AI feature
        // on in Preferences (DevType frontmost by definition) or by starting up while frontmost.
        guard !environment.isOwnProcessFrontmost() else { return }

        unregisterAXObserver()

        guard isFeatureEnabled, AXContextChecker.shared.isProcessTrusted() else {
            clearCache()
            return
        }
        if environment.isSecureInputActive() {
            clearCache()
            return
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            clearCache()
            return
        }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        if !bundleID.isEmpty, environment.isMuted(bundleID) {
            clearCache()
            return
        }
        // Not gated on `isTypedPathAllowed` — see `handleAXNotification`. Refusing to *observe* a
        // non-allowlisted app leaves the explicit paths with no cache at all in that app, which is
        // not what the allowlist means; `cachedSelection(…)` filters the typed path on read.

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
        if environment.isSecureInputActive() {
            clearCache()
            return
        }

        // §8.8: DevType coming forward — the palette, the AI action panel, an alert — is not evidence
        // about the user's selection, and every check below would evaluate it as if it were: our
        // bundle ID against the mute list and the typed-path allowlist, our panel's search field
        // against the cached element. Each of those paths ends in `clearCache()`.
        //
        // That is how last-known-good was being destroyed at precisely the moment the explicit
        // paths reach for it. The app the user just left fires `AXFocusedUIElementChanged` as it
        // resigns focus, the notification lands here with *us* frontmost, and the selection the
        // panel exists to transform is wiped microseconds before `SelectionReader` asks for it —
        // reported as `outcome=noFocus app=com.devtype.app systemWide:noValue`, i.e. blamed on an
        // app that had published the selection correctly all along.
        //
        // `installAppSwitchObserver` already encodes this rule for real activations; this is the
        // same invariant on the notification path. Nothing is leaked by holding the entry: a real
        // switch to another app still clears it, the TTL still retires it, and the typed path still
        // consumes it single-use.
        guard !environment.isOwnProcessFrontmost() else { return }

        let bundleID = AXContextChecker.shared.frontmostApplicationBundleIdentifier() ?? ""
        if !bundleID.isEmpty, environment.isMuted(bundleID) {
            clearCache()
            return
        }
        // Deliberately *not* gated on `isTypedPathAllowed`. That allowlist scopes the typed
        // trigger path, and `cachedSelection(…)` already enforces it on read. Enforcing it here
        // instead destroyed the entry the *explicit* paths depend on — the hotkey and the palette
        // read through `rawCachedSelection()` precisely because a hotkey types nothing into the
        // selection and so does not need the allowlist's protection. Configuring an allowlist
        // used to silently disable Prompt Enhance everywhere outside it.
        refreshCacheFromFocus(bundleID: bundleID)
    }

    // MARK: - Own-process guard

    /// Pure policy: may an AX refresh observed under these conditions touch last-known-good?
    ///
    /// Only when the evidence comes from another process. DevType owning focus says nothing about
    /// whether the user still has text selected in the app behind our panel — and "says nothing"
    /// must mean *leave the cache alone*, not "clear it", because the explicit AI paths reach for
    /// the cache in exactly that state (`SelectionGate.evaluate`, precedence rule 3).
    ///
    /// Both inputs matter and neither implies the other: a hotkey palette that calls
    /// `NSApp.activate` makes us frontmost, while a `.nonactivatingPanel` takes the focused element
    /// without ever becoming frontmost.
    public static func mayApplyRefresh(
        frontmostIsOwnProcess: Bool,
        focusedElementIsOwnProcess: Bool
    ) -> Bool {
        !frontmostIsOwnProcess && !focusedElementIsOwnProcess
    }

    static func isOwnProcessFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
    }

    /// True when `element` is owned by DevType itself.
    ///
    /// An element whose pid cannot be read counts as *not* ours, which keeps invalidation working
    /// for genuinely foreign elements; the cost of that choice is bounded by
    /// `SelectionGate.cacheMatchesFrontmost`, which will not hand another app's cached text to a
    /// third app anyway.
    static func elementBelongsToOwnProcess(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        return pid == ProcessInfo.processInfo.processIdentifier
    }

    /// Bundle ID of the app that owns `element`, or `nil` when the pid is unreadable or the
    /// process has no bundle. Callers fall back to the frontmost app's ID — a guess is better
    /// than an unlabelled entry, and every consumer re-checks the label against the app it is
    /// about to act in.
    static func bundleID(owning element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
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
        // Typed query, not `focusedElement()`: that collapses "this app has no focused element"
        // and "the AX round-trip failed" into the same `nil`, and only the first is evidence.
        // Chromium answers `.cannotComplete` mid-transition all the time — the whole
        // manual-accessibility dance exists because of it — and treating that as focus loss wipes
        // a good cache on an app that is about to answer perfectly well. Same principle as the
        // delivery-evidence rule: a failed read condemns nothing.
        let element: AXUIElement
        switch AXContextChecker.shared.queryFocusedElement() {
        case .available(let resolved):
            element = resolved
        case .missing:
            // The app answered, and the answer was "nothing is focused". That is evidence.
            clearCache()
            return
        case .axFailure, .untrusted:
            return
        }

        // Label the entry with the app that owns the *element*, never with whatever happens to be
        // frontmost at this instant. The two disagree exactly when it matters — mid app-switch the
        // system-wide focused element still resolves into the app being left — and a mislabelled
        // entry is not a cosmetic problem: `SelectionGate.cacheMatchesFrontmost` uses the label to
        // decide the text may be used *in that app*, so a wrong one both leaks app A's selection
        // into app B and walks around a mute on A.
        let owner = Self.bundleID(owning: element) ?? bundleID
        if !owner.isEmpty, environment.isMuted(owner) {
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
        applySelectionRefresh(text: text, bundleID: owner, element: element)
    }

    /// Shared refresh logic used by live AX notifications and unit tests.
    ///
    /// - Non-empty text → store (last-known-good update).
    /// - Empty / unreadable text on the **same** element → keep existing cache (TTL retires it).
    /// - Focus moved to a **different** AX element → clear, then store only if the new
    ///   element has a non-empty selection.
    private func applySelectionRefresh(text: String?, bundleID: String, element: AXUIElement?) {
        // §8.8: enforced at the mutation funnel rather than at each caller — nothing observed while
        // DevType owns the focus — frontmost, or merely holding the focused element behind a
        // `.nonactivatingPanel` like the inline search palette — may store *or* invalidate
        // last-known-good. Our own search field is a different element than the cached one, so
        // without this the refresh below reads as "focus moved" and clears the selection the
        // palette was opened to transform.
        guard Self.mayApplyRefresh(
            frontmostIsOwnProcess: environment.isOwnProcessFrontmost(),
            focusedElementIsOwnProcess: element.map(Self.elementBelongsToOwnProcess) ?? false
        ) else { return }

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
