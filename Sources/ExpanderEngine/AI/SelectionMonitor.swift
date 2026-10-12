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
            let age = now.timeIntervalSince(timestamp)
            return maxAge.isFinite && maxAge >= 0 && age.isFinite && age >= 0 && age <= maxAge
        }
    }

    private let lock = UnfairLock()
    private var cache: CachedSelection?
    /// AX element that owned the cached text — used for same-element checks at expand time.
    private var cacheElement: AXUIElement?
    private var changeToken: UInt64 = 0
    /// When the full attribute ladder last ran, for `shouldRunFallbackLadder`.
    private var lastFallbackLadderAt: Date?

    /// Bumped (under `lock`) whenever what a refresh was reading stops being current: an app
    /// switch, `stop()`. A refresh stamped with an older value may not store or clear anything.
    private var epoch: UInt64 = 0
    /// The newest notification not yet picked up by `drainRefreshes`. A burst collapses into one
    /// pending refresh, so a stalled target app cannot grow a backlog of reads.
    private var pendingRefresh: RefreshContext?
    private var refreshDrainScheduled = false

    /// The single serial queue every notification-driven AX read runs on. Not `readQueue`: an
    /// explicit hotkey read must never wait behind a burst of per-keystroke refreshes.
    let refreshQueue = DispatchQueue(label: "com.devtype.selection-monitor", qos: .utility)

    /// What the main-thread callback hands to `refreshQueue`: facts that need `NSWorkspace`,
    /// resolved on main, plus the epoch the result must still match when it lands.
    private struct RefreshContext {
        let epoch: UInt64
        let frontmostBundleID: String
        let frontmostIsOwnProcess: Bool
    }

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
        /// **Main queue only** (`NSWorkspace`): called by the AX callback before it hops to
        /// `refreshQueue`, never from the queue itself.
        var frontmostBundleID: () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        /// The AX reads a notification triggers. They run on `refreshQueue`, never on main.
        var axReads: AXReads = .live

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

    /// The AX attribute reads behind a selection-changed notification, behind a seam so a test
    /// can prove none of them runs on the main thread.
    struct AXReads {
        var isProcessTrusted: () -> Bool
        var queryFocusedElement: () -> AXContextChecker.FocusQueryResult
        var ownerBundleID: (AXUIElement) -> String?
        var copySelectedText: (_ element: AXUIElement, _ allowFallbackAttributes: Bool) -> String?

        static let live = AXReads(
            isProcessTrusted: { AXContextChecker.shared.isProcessTrusted() },
            queryFocusedElement: { AXContextChecker.shared.queryFocusedElement() },
            ownerBundleID: { SelectionMonitor.bundleID(owning: $0) },
            // No `kAXValue` slice: that rung pulls the element's whole value (up to 2M
            // characters) over AX IPC, and an empty `kAXSelectedText` is the normal answer while
            // typing. Explicit reads (`SelectionReader.readSelection*`) keep it.
            copySelectedText: {
                SelectionReader.copySelectedText(
                    from: $0, allowFallbackAttributes: $1, allowValueSlice: false
                )
            }
        )
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

        guard let snapshot,
              isEligible(snapshot, maxAge: maxAge, now: now, rejectWeakAX: rejectWeakAX) else { return nil }
        return snapshot
    }

    private func isEligible(
        _ snapshot: CachedSelection, maxAge: TimeInterval, now: Date, rejectWeakAX: Bool
    ) -> Bool {
        guard snapshot.isFresh(asOf: now, maxAge: maxAge) else { return false }
        guard !snapshot.text.isEmpty else { return false }
        if environment.isMuted(snapshot.bundleID) { return false }
        if !environment.isTypedPathAllowed(snapshot.bundleID) { return false }
        if rejectWeakAX, SelectionReader.isWeakAXApp(bundleID: snapshot.bundleID) { return false }
        return !environment.isSecureInputActive()
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
    /// Returns `nil` (and clears) when `focusedElement` is not the element that produced the cache
    /// entry. Passing `requireSameElement: false` skips that check (unit tests that seed without
    /// a live focus).
    ///
    /// This never queries AX: the caller (the typed AI trigger, on main) has just resolved the
    /// focused element for its own gate (§2.2) and hands that same resolution in, rather than
    /// paying for a second live round-trip on the main thread. A caller with no resolved element
    /// passes `nil`, which fails closed — an unverifiable element is a mismatch.
    @discardableResult
    public func consumeSelection(
        maxAge: TimeInterval = defaultTTL,
        asOf now: Date = Date(),
        rejectWeakAX: Bool = true,
        requireSameElement: Bool = true,
        focusedElement: AXUIElement? = nil
    ) -> CachedSelection? {
        lock.lock()
        let snapshot = cache
        let storedElement = cacheElement
        lock.unlock()

        guard let snapshot,
              isEligible(snapshot, maxAge: maxAge, now: now, rejectWeakAX: rejectWeakAX) else { return nil }

        if requireSameElement {
            guard let storedElement,
                  let focusedElement,
                  CFEqual(storedElement, focusedElement) else {
                _ = takeCache(ifMatching: snapshot)
                return nil
            }
        }

        return takeCache(ifMatching: snapshot)
    }

    /// Validate outside the lock (AX and preference providers can reenter), then claim exactly
    /// the snapshot validated. A concurrent consumer or refresh must never be cleared here.
    private func takeCache(ifMatching snapshot: CachedSelection) -> CachedSelection? {
        lock.lock()
        defer { lock.unlock() }
        guard cache == snapshot else { return nil }
        cache = nil
        cacheElement = nil
        return snapshot
    }

    /// Test / recovery hook.
    public func clearCache() {
        lock.lock()
        cache = nil
        cacheElement = nil
        lock.unlock()
    }

    /// Clear on behalf of a refresh stamped `epoch`; a no-op once that epoch is stale (the app
    /// switched or the monitor stopped while the read was in flight). `nil` clears unconditionally.
    private func clearCache(ifEpoch epoch: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        if let epoch, epoch != self.epoch { return }
        cache = nil
        cacheElement = nil
    }

    /// Retire every read in flight or queued: its result describes a focus that is gone.
    private func invalidateInFlightRefreshes() {
        lock.lock()
        epoch &+= 1
        pendingRefresh = nil
        lock.unlock()
    }

    /// Benchmark hook: the whole refresh the callback used to run on main, run inline on the
    /// calling thread — the "before" arm of `SelectionMonitorBenchmarkTests`.
    func performRefreshInlineForBenchmark(bundleID: String) {
        lock.lock()
        let context = RefreshContext(epoch: epoch, frontmostBundleID: bundleID, frontmostIsOwnProcess: false)
        lock.unlock()
        performRefresh(context)
    }

    /// Test hook: returns once every queued and running notification refresh has finished.
    func waitForRefreshesForTesting() {
        refreshQueue.sync {}
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
        invalidateInFlightRefreshes()
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
            // A real switch to another app invalidates last-known-good from the previous one —
            // including any refresh of that app still reading on `refreshQueue`.
            self?.invalidateInFlightRefreshes()
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

        invalidateInFlightRefreshes()
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

        enqueueRefresh(bundleID: bundleID, frontmostIsOwnProcess: false)
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

    /// The AX observer callback, on the main run loop. It reads **no AX attribute**: it resolves
    /// the `NSWorkspace` facts (main-only) and hands the rest to `refreshQueue`, where every AX
    /// round-trip happens. A burst of notifications coalesces into one pending refresh.
    func handleAXNotification() {
        precondition(Thread.isMainThread)
        guard isFeatureEnabled else { return }
        enqueueRefresh(
            bundleID: environment.frontmostBundleID() ?? "",
            frontmostIsOwnProcess: environment.isOwnProcessFrontmost()
        )
    }

    private func enqueueRefresh(bundleID: String, frontmostIsOwnProcess: Bool) {
        lock.lock()
        pendingRefresh = RefreshContext(
            epoch: epoch,
            frontmostBundleID: bundleID,
            frontmostIsOwnProcess: frontmostIsOwnProcess
        )
        let schedule = !refreshDrainScheduled
        refreshDrainScheduled = true
        lock.unlock()
        guard schedule else { return }
        refreshQueue.async { [weak self] in self?.drainRefreshes() }
    }

    /// Runs on `refreshQueue`: serial, so a refresh never overlaps another, and each pass takes
    /// the *latest* pending context — an older notification's snapshot is never read after a newer
    /// one arrived.
    private func drainRefreshes() {
        while true {
            lock.lock()
            guard let context = pendingRefresh else {
                refreshDrainScheduled = false
                lock.unlock()
                return
            }
            pendingRefresh = nil
            lock.unlock()
            performRefresh(context)
        }
    }

    /// `refreshQueue` only. Every store or clear is stamped with `context.epoch`.
    private func performRefresh(_ context: RefreshContext) {
        guard isFeatureEnabled else { return }
        guard environment.axReads.isProcessTrusted() else {
            clearCache(ifEpoch: context.epoch)
            return
        }
        if environment.isSecureInputActive() {
            clearCache(ifEpoch: context.epoch)
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
        guard !context.frontmostIsOwnProcess else { return }

        let bundleID = context.frontmostBundleID
        if !bundleID.isEmpty, environment.isMuted(bundleID) {
            clearCache(ifEpoch: context.epoch)
            return
        }
        // Deliberately *not* gated on `isTypedPathAllowed`. That allowlist scopes the typed
        // trigger path, and `cachedSelection(…)` already enforces it on read. Enforcing it here
        // instead destroyed the entry the *explicit* paths depend on — the hotkey and the palette
        // read through `rawCachedSelection()` precisely because a hotkey types nothing into the
        // selection and so does not need the allowlist's protection. Configuring an allowlist
        // used to silently disable Prompt Enhance everywhere outside it.
        refreshCacheFromFocus(bundleID: bundleID, context: context)
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
        pid(owning: element) == ProcessInfo.processInfo.processIdentifier
    }

    /// Owning pid of `element`, or `nil` when AX cannot answer. The single reader of
    /// `AXUIElementGetPid` — the three call sites that each spelled it out were free to
    /// disagree about whether pid `0` counts as an answer. It does not.
    public static func pid(owning element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    /// Bundle ID of the app that owns `element`, or `nil` when the pid is unreadable or the
    /// process has no bundle. Callers fall back to the frontmost app's ID — a guess is better
    /// than an unlabelled entry, and every consumer re-checks the label against the app it is
    /// about to act in.
    static func bundleID(owning element: AXUIElement) -> String? {
        guard let pid = pid(owning: element) else { return nil }
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

    /// `refreshQueue` only: every AX read of a notification-driven refresh is here.
    private func refreshCacheFromFocus(bundleID: String, context: RefreshContext, now: Date = Date()) {
        // Typed query, not `focusedElement()`: that collapses "this app has no focused element"
        // and "the AX round-trip failed" into the same `nil`, and only the first is evidence.
        // Chromium answers `.cannotComplete` mid-transition all the time — the whole
        // manual-accessibility dance exists because of it — and treating that as focus loss wipes
        // a good cache on an app that is about to answer perfectly well. Same principle as the
        // delivery-evidence rule: a failed read condemns nothing.
        let element: AXUIElement
        switch environment.axReads.queryFocusedElement() {
        case .available(let resolved):
            element = resolved
        case .missing:
            // The app answered, and the answer was "nothing is focused". That is evidence.
            clearCache(ifEpoch: context.epoch)
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
        let owner = environment.axReads.ownerBundleID(element) ?? bundleID
        if !owner.isEmpty, environment.isMuted(owner) {
            clearCache(ifEpoch: context.epoch)
            return
        }

        // Cheap attribute first: this runs from an AX notification that many apps fire on every
        // keystroke, and the extra round-trips are wasted whenever the primary one answers.
        let primary = environment.axReads.copySelectedText(element, false)

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
            text = environment.axReads.copySelectedText(element, true)
        }
        applySelectionRefresh(
            text: text,
            bundleID: owner,
            element: element,
            frontmostIsOwnProcess: context.frontmostIsOwnProcess,
            epoch: context.epoch
        )
    }

    /// Shared refresh logic used by live AX notifications and unit tests.
    ///
    /// - Non-empty text → store (last-known-good update).
    /// - Empty / unreadable text on the **same** element → keep existing cache (TTL retires it).
    /// - Focus moved to a **different** AX element → clear, then store only if the new
    ///   element has a non-empty selection.
    ///
    /// `epoch` stamps a refresh read on `refreshQueue`: once the app has switched or the monitor
    /// stopped, its result is dropped rather than stored over the newer state. `nil` (the test
    /// hook) applies unconditionally, with the own-process fact read from `environment`.
    private func applySelectionRefresh(
        text: String?,
        bundleID: String,
        element: AXUIElement?,
        frontmostIsOwnProcess: Bool? = nil,
        epoch: UInt64? = nil
    ) {
        // §8.8: enforced at the mutation funnel rather than at each caller — nothing observed while
        // DevType owns the focus — frontmost, or merely holding the focused element behind a
        // `.nonactivatingPanel` like the inline search palette — may store *or* invalidate
        // last-known-good. Our own search field is a different element than the cached one, so
        // without this the refresh below reads as "focus moved" and clears the selection the
        // palette was opened to transform.
        guard Self.mayApplyRefresh(
            frontmostIsOwnProcess: frontmostIsOwnProcess ?? environment.isOwnProcessFrontmost(),
            focusedElementIsOwnProcess: element.map(Self.elementBelongsToOwnProcess) ?? false
        ) else { return }

        lock.lock()
        let previousElement = cacheElement
        lock.unlock()

        if let previousElement, let element, !CFEqual(previousElement, element) {
            clearCache(ifEpoch: epoch)
        } else if previousElement != nil, element == nil {
            clearCache(ifEpoch: epoch)
            return
        }

        guard let text, !text.isEmpty else {
            // Empty selection on the same element: keep last-known-good for TTL.
            return
        }
        storeCache(text: text, bundleID: bundleID, element: element, epoch: epoch)
    }

    private func storeCache(text: String, bundleID: String, element: AXUIElement?, epoch: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        if let epoch, epoch != self.epoch { return }
        changeToken &+= 1
        let token = changeToken
        cache = CachedSelection(
            text: text,
            bundleID: bundleID,
            changeToken: token,
            timestamp: Date()
        )
        cacheElement = element
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
    // The source sits on the main run loop, so this is main: it only hops to `refreshQueue`.
    monitor.handleAXNotification()
}
