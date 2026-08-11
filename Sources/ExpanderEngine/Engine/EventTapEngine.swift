import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Menu-bar / status-item display state derived from Listen + AX + tap + pause + Secure Input.
/// A swallowing `defaultTap` needs Listen **and** Accessibility. Post-only missing degrades
/// inject and does **not** force Needs Permissions while the tap is running.
public enum EngineDisplayStatus: Equatable {
    case needsPermissions
    case tapFailed
    case paused
    case secure
    case active

    /// True when the user should open Permission Recovery or fix TCC / tap.
    public var requiresAction: Bool {
        switch self {
        case .needsPermissions, .tapFailed:
            return true
        case .paused, .secure, .active:
            return false
        }
    }

    public var menuTitle: String {
        switch self {
        case .needsPermissions: return "Status: Needs Permissions"
        case .tapFailed: return "Status: Tap Failed"
        case .paused: return "Status: Paused"
        case .secure: return "Status: Secure"
        case .active: return "Status: Active"
        }
    }

    /// Menu title with a lightweight action badge when permissions or tap need attention.
    public var menuTitleWithActionHint: String {
        requiresAction ? "\(menuTitle) ⚠" : menuTitle
    }

    public var buttonTitle: String {
        switch self {
        case .needsPermissions: return "DevType (Needs Permissions)"
        case .tapFailed: return "DevType (Tap Failed)"
        case .paused: return "DevType (Paused)"
        case .secure: return "DevType (Secure)"
        case .active: return "DevType"
        }
    }

    public var toolTip: String {
        toolTip(snapshot: nil)
    }

    /// Tooltip listing missing capabilities (Listen / AX / Post).
    public func toolTip(snapshot: PermissionSnapshot?) -> String {
        toolTip(
            missingCapabilityNames: snapshot?.missingCapabilityNames ?? [],
            canListenTap: snapshot?.canListenTap ?? true,
            canUseAX: snapshot?.canUseAX ?? true,
            degradedInject: snapshot?.isDegradedInject ?? false
        )
    }

    public func toolTip(
        missingCapabilityNames: [String],
        canListenTap: Bool = true,
        canUseAX: Bool = true,
        degradedInject: Bool = false
    ) -> String {
        switch self {
        case .needsPermissions:
            if missingCapabilityNames.isEmpty {
                return "Grant Input Monitoring and Accessibility in Permission Recovery (⌘⇧P) so the event tap can start"
            }
            var tip = "\(PermissionSnapshot.missingSummary(from: missingCapabilityNames)). Open Permission Recovery (⌘⇧P)."
            if !canListenTap || !canUseAX {
                tip += " Input Monitoring and Accessibility are both required for the event tap."
            }
            return tip
        case .tapFailed:
            return "Event tap failed to start despite Listen + Accessibility — quit other DevType copies, re-open the packaged app, then use Permission Recovery (⌘⇧P)"
        case .paused:
            return "DevType is paused"
        case .secure:
            return "Secure Input active — typed abbreviations muted. Use ⌘/ to paste into password fields (typing cannot work)."
        case .active:
            if degradedInject {
                let names = missingCapabilityNames.filter { $0 != "Input Monitoring" && $0 != "Accessibility" }
                if !names.isEmpty {
                    return "\(PermissionSnapshot.missingSummary(from: names)). Tap active — inject degraded. Permission Recovery (⌘⇧P)."
                }
            }
            return "DevType Native macOS Text Expander"
        }
    }

    /// Guidance when Listen + AX are granted but the tap still will not start.
    public static let tapFailedRecoveryGuidance = """
    Tap Failed: Input Monitoring and Accessibility look granted but the event tap did not start. Quit any other DevType copies, then re-open \(ProcessIdentity.preferredInstalledAppPath) (or \(ProcessIdentity.developmentAppPathHint) while developing) so TCC matches this identity. If Settings toggles look ON for an older binary, run Scripts/reset-tcc.sh and Request again.
    """

    /// Active when Listen + AX allow a running tap, user has not paused, and Secure Input is off.
    /// Missing Post alone does not demote to Needs Permissions.
    public static func resolve(
        canListenTap: Bool,
        canUseAX: Bool = true,
        isTapRunning: Bool,
        isEnabled: Bool,
        isSecureInputActive: Bool
    ) -> EngineDisplayStatus {
        // `.defaultTap` needs both capabilities; missing either is Needs Permissions, not Tap Failed.
        if !canListenTap || !canUseAX {
            return .needsPermissions
        }
        if !isTapRunning {
            return .tapFailed
        }
        if isSecureInputActive {
            return .secure
        }
        if !isEnabled {
            return .paused
        }
        return .active
    }

    /// Convenience from a full snapshot.
    public static func resolve(
        snapshot: PermissionSnapshot,
        isTapRunning: Bool,
        isEnabled: Bool,
        isSecureInputActive: Bool
    ) -> EngineDisplayStatus {
        resolve(
            canListenTap: snapshot.canListenTap,
            canUseAX: snapshot.canUseAX,
            isTapRunning: isTapRunning,
            isEnabled: isEnabled,
            isSecureInputActive: isSecureInputActive
        )
    }
}

public final class EventTapEngine {
    public static let shared = EventTapEngine()

    // MARK: - §1.1 tap thread

    /// §1.1 kill switch. When `true` (default) the tap source is attached to a dedicated
    /// `userInteractive` thread's run loop instead of the main run loop, so a slow AX probe or a
    /// disk write on the callback path can no longer stall the whole system's keyboard.
    ///
    /// Flip it back with `defaults write com.devtype.app DevTypeUseDedicatedTapThread -bool NO`
    /// (read once at first use) or by assigning before `start()`.
    public static let useDedicatedTapThreadDefaultsKey = "DevTypeUseDedicatedTapThread"

    public static var useDedicatedTapThread: Bool = {
        let key = "DevTypeUseDedicatedTapThread"
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return true
    }()

    private let tapThread = TapRunLoopThread()

    /// §1.11: `eventTapPort` / `runLoopSource` were mutated by `start`/`stop` and read by
    /// `reEnableTap()` (from the callback) and `checkTapHealth()` (main timer) with no lock at
    /// all, in a class where everything else is locked. Once §1.1 moves the callback off main
    /// that is a live data race, so they now sit behind their own lock.
    private let tapLock = UnfairLock()
    private var _eventTapPort: CFMachPort?
    private var _runLoopSource: CFRunLoopSource?
    private var _tapRunLoop: CFRunLoop?

    private let processingQueue = DispatchQueue(label: "com.devtype.eventprocessing", qos: .userInteractive)

    // MARK: - Buffer / flags

    /// §2.4: `os_unfair_lock` (via `UnfairLock`) rather than `NSLock` — `NSLock` does not donate
    /// priority, so the userInteractive tap callback could block behind a utility-QoS file-watch
    /// thread holding this lock in the `snippets` setter.
    private let lock = UnfairLock()
    /// Prefix-debounce state. Owns its own lock and serializes every hold transition — see
    /// `HeldExpansionCoordinator` for the interleavings this closes. Lock ordering: paths may
    /// take `lock` then the coordinator's lock (never nested the other way — the coordinator
    /// never calls out), so the pair cannot deadlock.
    private let heldCoordinator = HeldExpansionCoordinator<HeldPayload>()
    /// §2.3: a real fixed-capacity ring. The old "ring buffer" was an `Array` plus
    /// `removeFirst(...)` — an O(n) memmove on every keystroke at steady state.
    private var ringBuffer = CharacterRingBuffer(capacity: EventTapEngine.maxBufferCapacity)
    private var layoutBuffer = LayoutBuffer()
    /// §3.9: longest trigger the buffer can hold. Anything longer can never fire —
    /// see `overlongTriggerDiagnostics()`.
    public static let maxBufferCapacity = 64
    /// UTF-16 units fetched per keyDown. Stack scratch, not a heap allocation (§2.3).
    private static let unicodeScratchCapacity = 128
    /// UTF-16 length of the most recent keyDown that appended to the buffer (for AX erase math).
    private var lastEventUTF16Count: Int = 1

    private var _isEnabled: Bool = true
    private var _isTapRunning: Bool = false
    private var _isExpanding: Bool = false
    /// §8.3: keystrokes typed while an expansion is in flight, held so they cannot land ahead of
    /// the paste. Guarded by `lock` — mutated from the tap callback and from `endExpansion`.
    private var _typeAhead = TypeAheadBuffer()
    /// Nested suspend depth (fill-in + inline search / AI panels). Matching is skipped while > 0.
    private var _matchingSuspendCount: Int = 0
    /// Live suspension owners, newest last, for `matchingSuspensionDiagnostics()`. A leaked
    /// suspension is invisible in every other counter — the tap still runs, the engine is still
    /// enabled, permissions are still granted, and not one snippet expands.
    private var _matchingSuspendOwners: [(id: UUID?, reason: String, since: Date)] = []
    private var _isSecureInputActive: Bool = false

    // MARK: - §2.1 cached matcher

    /// §2.1 / §2.4: read-mostly `(snippets, matcher)` state, swapped as one immutable reference.
    /// The callback copies a single class pointer out from under this lock and never rebuilds
    /// anything — the matcher used to be reconstructed from scratch on *every keystroke*.
    private let matchStateLock = UnfairLock()
    private var _matchSnapshot: SnippetMatchSnapshot = .empty
    private var _snapshotRevision: UInt64 = 0

    /// The library **before** secrets are filtered out, for diagnostics only — see
    /// `silentNoExpandDiagnostics()`. Never read by the matcher or the keystroke path.
    private let libraryLock = UnfairLock()
    private var _fullLibrary: [SnippetModel] = []

    // MARK: - §2.3 cached frontmost context

    /// Everything the callback needs that would otherwise cost AppKit / Carbon IPC per keystroke.
    /// With §1.1 moving the callback off the main thread these caches are **mandatory**
    /// (`NSWorkspace` is AppKit), not merely an optimization.
    public struct FrontmostContext: Equatable {
        public var bundleID: String?
        public var processID: pid_t?
        /// `AppMuteStore` verdict for `bundleID`; refreshed on app switch and mute-list change.
        public var isMuted: Bool
        /// Dedicated terminal app — a pure bundle-ID set lookup, no AX and no NSWorkspace.
        public var isTerminal: Bool

        public init(
            bundleID: String? = nil,
            processID: pid_t? = nil,
            isMuted: Bool = false,
            isTerminal: Bool = false
        ) {
            self.bundleID = bundleID
            self.processID = processID
            self.isMuted = isMuted
            self.isTerminal = isTerminal
        }
    }

    private let contextLock = UnfairLock()
    private var _frontmostContext = FrontmostContext()
    /// Cached `isTwoSetKoreanSourceID(currentInputSourceID())`. The tap used to call
    /// `TISCopyCurrentKeyboardInputSource` + a CFString bridge per key just to test a constant.
    private var _allowPhysicalFallback = false
    private var muteObserverInstalled = false

    // MARK: - §2.10 tap disable telemetry

    /// §2.10: per-reason counters for `tapDisabledBy…`. `byTimeout` means *our callback was too
    /// slow* and is the actionable one; `byUserInput` is the user/system disabling the tap.
    public struct TapDisableCounters: Equatable {
        public var byTimeout: Int = 0
        public var byUserInput: Int = 0
        public var reEnables: Int = 0
        public var escalatedReinstalls: Int = 0
        public var lastTimeoutAt: Date?
        public var lastUserInputAt: Date?

        public init() {}

        public var summaryLine: String {
            "Tap disables: byTimeout=\(byTimeout) byUserInput=\(byUserInput)"
                + " reEnables=\(reEnables) reinstalls=\(escalatedReinstalls)"
        }
    }

    public enum TapDisableReason: Equatable {
        /// `kCGEventTapDisabledByTimeout` — the callback exceeded the system budget.
        case timeout
        /// `kCGEventTapDisabledByUserInput`.
        case userInput
        case unspecified
    }

    /// Timeout disables inside `tapDisableEscalationWindow` before a plain re-enable is treated
    /// as insufficient and a full tap reinstall is attempted.
    public static let tapDisableEscalationThreshold = 3
    public static let tapDisableEscalationWindow: TimeInterval = 10.0
    public static let tapReinstallInitialBackoff: TimeInterval = 5.0
    public static let tapReinstallMaxBackoff: TimeInterval = 60.0

    private let counterLock = UnfairLock()
    private var _tapDisableCounters = TapDisableCounters()
    private var _recentTimeoutStamps: [Date] = []
    private var _nextReinstallAllowedAt: Date?
    private var _reinstallBackoff: TimeInterval = EventTapEngine.tapReinstallInitialBackoff

    /// §2.10: public so `DiagnosticReport` can print them.
    public var tapDisableCounters: TapDisableCounters {
        counterLock.withLock { _tapDisableCounters }
    }

    /// Event-time quiescence clock (boot nanos via CGEvent.timestamp).
    public let inputClock = InputClock()

    private var appSwitchObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var healthTimer: DispatchSourceTimer?
    /// How often to probe `CGEvent.tapIsEnabled` for silent inert taps (macOS TCC/re-sign class).
    private let healthCheckInterval: TimeInterval = 2.0

    /// Invoked on the main queue when health monitor clears / reinstalls a dead tap.
    public var onTapHealthChanged: (() -> Void)?

    /// Called on the main queue after a snippet expansion inject completes successfully.
    public var onExpansionSucceeded: ((SnippetModel) -> Void)?

    /// Present fill-in UI from the app target. `(title, fields, completion)` — completion nil = cancel.
    public var presentFillIn: ((String, [FillField], @escaping ([Int: String]?) -> Void) -> Void)?

    /// Typed-path / off-pipeline AI handoff. App target presents the preview (or action)
    /// panel. Called on the main queue after the trigger erase has finished and expansion ended.
    /// Parameters: captured selection text, transform kind, source app for reactivation,
    /// optional custom instructions (snippet body for `.custom`), erased trigger to restore on cancel.
    public var presentAITransform: ((
        _ input: String,
        _ kind: AITransformKind,
        _ sourceApp: NSRunningApplication?,
        _ customInstructions: String?,
        _ restoreOnCancel: String?
    ) -> Void)?

    /// Localization key for the typed-AI path when selection is absent or stale.
    /// UI should show a hint that points the user at the AI hotkey / palette.
    public static let aiSelectionUnavailableHintKey = "ai.typed.selectionUnavailable"

    /// Localization key when a fresh cache exists but the host is weak-AX (Chrome/Slack/Electron).
    public static let aiWeakAXHintKey = "ai.typed.weakAX"

    /// Typed AI path: selection unavailable. Invoked on the main queue with a localization key
    /// (see `aiSelectionUnavailableHintKey` / `aiWeakAXHintKey`).
    public var presentAITransformHint: ((String) -> Void)?

    /// Keycodes that desync the ring buffer. Return/Tab intentionally omitted — DevType may
    /// treat them as terminators and swallow (unlike SnipKey listenOnly clearBuffer).
    public static let bufferResetKeyCodes: Set<Int64> = [
        53, 115, 116, 117, 119, 121, 123, 124, 125, 126
    ]

    private static let mouseDownTypes: Set<CGEventType> = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown
    ]

    /// §2.1: the setter is the **only** place the matcher is built. The tap callback used to
    /// reconstruct `AbbreviationMatcher(snippets:)` on every keystroke — at 1000 snippets that is
    /// ~2000 dictionary inserts + ~1000 string allocations per typed character, inside a
    /// CGEventTap callback macOS disables when it runs long.
    public var snippets: [SnippetModel] {
        get {
            matchStateLock.lock()
            defer { matchStateLock.unlock() }
            return _matchSnapshot.snippets
        }
        set {
            matchStateLock.lock()
            let revision = _snapshotRevision &+ 1
            _snapshotRevision = revision
            matchStateLock.unlock()

            // Secrets are filtered out here, at the one door into the matcher, rather than at the
            // callers. A keychain-backed snippet must never be reachable by typing: Secure Input
            // means the trigger cannot be seen where it would be wanted, and everywhere else a
            // trigger that fires on typing would put a password into the chat window the user was
            // mid-sentence in. Filtering in the setter means no future caller can reintroduce it,
            // and the value is not in the struct to leak even if one tried.
            let matchable = newValue.filter(\.isTypedTriggerExpandable)

            // Build outside the lock: a rebuild can take milliseconds at large libraries and the
            // tap callback reads this lock on the keystroke path.
            let snapshot = SnippetMatchSnapshot(snippets: matchable, revision: revision)

            // Kept **unfiltered** for `silentNoExpandDiagnostics()` only. The matcher must never
            // see it: the whole point of the filter above is that a secret is not reachable from
            // the keystroke path. This copy carries triggers, and a secret's `replacementText` is
            // empty by construction (`SnippetModel.init`), so no value is retained here.
            libraryLock.lock()
            _fullLibrary = newValue.map { snippet in
                var stripped = snippet
                stripped.replacementText = snippet.isSecret ? "" : snippet.replacementText
                return stripped
            }
            libraryLock.unlock()

            matchStateLock.lock()
            // Last writer wins; a slower build must never clobber a newer one.
            if snapshot.revision >= _matchSnapshot.revision {
                _matchSnapshot = snapshot
            }
            matchStateLock.unlock()

            logOverlongTriggers(in: snapshot)
        }
    }

    /// §2.1: current immutable `(snippets, matcher)` pair. Cheap — one reference copy.
    public var matchSnapshot: SnippetMatchSnapshot {
        matchStateLock.lock()
        defer { matchStateLock.unlock() }
        return _matchSnapshot
    }

    /// §2.3: last known frontmost app context (bundle ID, PID, mute + terminal verdicts).
    /// Updated from the `didActivateApplication` observer, never read from AppKit on the tap thread.
    public var frontmostContext: FrontmostContext {
        contextLock.lock()
        defer { contextLock.unlock() }
        return _frontmostContext
    }

    public var cachedFrontmostBundleID: String? {
        contextLock.lock()
        defer { contextLock.unlock() }
        return _frontmostContext.bundleID
    }

    /// User pause flag. When false, matching is skipped but the tap may still be installed.
    /// Persisted across launches so a deliberate pause survives relaunch / rebuild.
    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isEnabled
        }
        set {
            lock.lock()
            _isEnabled = newValue
            lock.unlock()
            if !newValue {
                // Pausing must silence everything already in motion, not just future matches: a
                // hold armed moments ago still has a live debounce timer, and firing it would
                // expand text while the user believes DevType is off.
                heldCoordinator.cancelAll(reason: .unobservedInput)
            }
            UserDefaults.standard.set(!newValue, forKey: ProcessIdentity.userPausedDefaultsKey)
        }
    }

    /// Whether a CGEvent tap is currently installed (independent of user pause).
    public var isTapRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isTapRunning
    }

    /// True while an expansion inject + clipboard restore is in flight; matching is suppressed.
    public var isExpanding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isExpanding
    }

    /// When true, the tap still runs but abbreviation matching is skipped (fill-in panels, inline search).
    /// True while the suspend reference count is greater than zero.
    public var matchingSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _matchingSuspendCount > 0
    }

    /// Increment the matching-suspend reference count. Nested callers must pair with `resumeMatching()`.
    ///
    /// Prefer `suspendMatching(reason:)`, which returns an owned token. This bare pair is the
    /// primitive underneath it: balancing it correctly is the caller's problem, and every
    /// historical way of getting that wrong stops the app expanding anything at all.
    public func suspendMatching() {
        // Deliberately does **not** go through `suspendMatching(reason:)`: that returns an owned
        // token, and a discarded token deallocates immediately and releases itself, so the
        // suspension would end on the same line it began.
        performSuspend(id: nil, reason: "unattributed")
    }

    /// Decrement the matching-suspend reference count (clamped at zero). Matching resumes only when count hits 0.
    ///
    /// Clamping at zero is a safety net, not a licence: a spurious resume with another owner's
    /// suspension live *steals* it, and matching restarts under a panel that is still collecting
    /// keystrokes. `MatchingSuspension` exists so neither mistake is expressible.
    public func resumeMatching() {
        releaseSuspension(id: nil)
    }

    // MARK: - Owned matching suspension

    /// A single owner's claim on "matching is suspended".
    ///
    /// The bare `suspendMatching()` / `resumeMatching()` pair is a global reference count with no
    /// record of *who* holds it, and both ways of unbalancing it are silent catastrophes:
    ///
    ///   * **one suspend too many** — a panel opened twice (its `isOpen` check reads
    ///     `panel?.isVisible`, which is already false while the panel animates out) leaves the
    ///     count pinned above zero. The tap keeps running, the engine stays enabled, permissions
    ///     stay granted, and no snippet ever expands again until relaunch. Nothing in the
    ///     diagnostic report said so.
    ///   * **one resume too many** — a `close()` that runs without a matching `open()` decrements
    ///     *someone else's* suspension, so matching restarts while a fill-in panel is still
    ///     collecting keystrokes and the user's typing starts triggering expansions into it.
    ///
    /// Ownership makes both unrepresentable. `release()` is idempotent, so a double close is a
    /// no-op, and `deinit` releases, so a token dropped on the floor — the double-open case, where
    /// the second `open()` overwrites the first token — cannot leak either.
    public final class MatchingSuspension {
        private let id: UUID
        private weak var engine: EventTapEngine?
        private let releaseLock = UnfairLock()
        private var isReleased = false

        fileprivate init(id: UUID, engine: EventTapEngine) {
            self.id = id
            self.engine = engine
        }

        /// Idempotent: only the first call releases the underlying suspension.
        public func release() {
            releaseLock.lock()
            let alreadyReleased = isReleased
            isReleased = true
            releaseLock.unlock()
            guard !alreadyReleased else { return }
            engine?.releaseSuspension(id: id)
        }

        deinit {
            release()
        }
    }

    /// Suspends matching until the returned token is released or deallocated.
    ///
    /// `reason` is carried into the diagnostic report so a suspension that outlives its panel can
    /// be identified by name rather than inferred from the absence of expansions.
    public func suspendMatching(reason: String) -> MatchingSuspension {
        let id = UUID()
        performSuspend(id: id, reason: reason)
        return MatchingSuspension(id: id, engine: self)
    }

    private func performSuspend(id: UUID?, reason: String) {
        lock.lock()
        _matchingSuspendCount += 1
        _matchingSuspendOwners.append((id: id, reason: reason, since: Date()))
        let depth = _matchingSuspendCount
        lock.unlock()
        DevTypeLog.eventTap.debug(
            "[EventTap] matching suspended by \(reason, privacy: .public) depth=\(depth, privacy: .public)"
        )
        // From this instant keystrokes bypass matching (fill-in panel, inline search), so a live
        // hold can no longer observe the field it would erase — and its debounce timer would
        // fire *into the panel's text view*. Drop it before the first bypassed key.
        heldCoordinator.cancelAll(reason: .unobservedInput)
    }

    /// Releases one suspension.
    ///
    /// A token releases **its own** claim: an `id` with no live owner is a no-op rather than a
    /// decrement, so a second close, or a close racing the token's `deinit`, cannot consume a
    /// suspension that belongs to a different panel. `id == nil` is the legacy unowned
    /// `resumeMatching()` path and can only drop the most recent owner.
    fileprivate func releaseSuspension(id: UUID?) {
        lock.lock()
        let index: Int?
        if let id {
            index = _matchingSuspendOwners.lastIndex { $0.id == id }
        } else {
            // Legacy `resumeMatching()` releases the newest *unowned* suspension. Falling back to
            // "the newest of any kind" would let an unbalanced legacy caller consume a panel's
            // token, which is the theft this type exists to prevent.
            index = _matchingSuspendOwners.lastIndex { $0.id == nil }
        }
        guard let index else {
            // Nothing of ours to release. Legacy callers with no owners at all still fall through
            // to the clamp below so the old contract (resume is always safe) is preserved.
            let hadOwners = !_matchingSuspendOwners.isEmpty
            if id == nil, !hadOwners {
                _matchingSuspendCount = max(0, _matchingSuspendCount - 1)
            }
            lock.unlock()
            return
        }
        _matchingSuspendOwners.remove(at: index)
        _matchingSuspendCount = max(0, _matchingSuspendCount - 1)
        let depth = _matchingSuspendCount
        lock.unlock()
        DevTypeLog.eventTap.debug(
            "[EventTap] matching suspension released depth=\(depth, privacy: .public)"
        )
    }

    /// Live suspension owners and how long each has held. Empty when matching is running.
    public func matchingSuspensionOwners() -> [(reason: String, seconds: TimeInterval)] {
        let now = Date()
        lock.lock()
        let owners = _matchingSuspendOwners
        lock.unlock()
        return owners.map { (reason: $0.reason, seconds: now.timeIntervalSince($0.since)) }
    }

    /// Report line. **Matching suspended is a total expansion outage**, so it must never be
    /// summarized as anything softer, and it must appear whether or not anything else is wrong.
    public func matchingSuspensionDiagnostics() -> [String] {
        let owners = matchingSuspensionOwners()
        guard !owners.isEmpty else { return ["Matching: running (not suspended)"] }
        var lines = ["Matching: SUSPENDED — typed triggers cannot expand while this is true"]
        for owner in owners {
            lines.append("  held by \(owner.reason) for \(Int(owner.seconds))s")
        }
        return lines
    }

    /// Whether DevType itself owns the frontmost app — i.e. one of our panels could legitimately
    /// be holding a suspension. Reads the cached frontmost context, never AppKit, so it is safe
    /// from the tap thread's health timer.
    func isDevTypeFrontmost() -> Bool {
        cachedFrontmostBundleID == ProcessIdentity.shared.bundleIdentifier
    }

    /// A suspension older than this with DevType in the background is orphaned, not in use.
    ///
    /// Every legitimate owner is a DevType panel that has keyboard focus (fill-in, inline search,
    /// AI action / preview). If DevType is not frontmost, no such panel is collecting keystrokes,
    /// so a suspension still standing after this long is a leak — and leaving it in place means
    /// the user types triggers into other apps forever with nothing happening.
    public static let orphanedSuspensionTimeout: TimeInterval = 30.0

    /// Force-clears suspensions that cannot belong to a live panel. Returns how many were cleared.
    ///
    /// Deliberately conditional on DevType not being frontmost: that is the one check that
    /// distinguishes "a panel is open and the user is typing into it" (must keep suspending) from
    /// "a panel closed without releasing" (must recover). Recovering on a timer alone would resume
    /// matching under a fill-in panel someone is still filling in.
    @discardableResult
    public func recoverOrphanedSuspensions(isDevTypeFrontmost: Bool, now: Date = Date()) -> Int {
        guard !isDevTypeFrontmost else { return 0 }
        lock.lock()
        let stale = _matchingSuspendOwners.filter {
            now.timeIntervalSince($0.since) >= Self.orphanedSuspensionTimeout
        }
        guard !stale.isEmpty else {
            lock.unlock()
            return 0
        }
        _matchingSuspendOwners.removeAll {
            now.timeIntervalSince($0.since) >= Self.orphanedSuspensionTimeout
        }
        _matchingSuspendCount = max(0, _matchingSuspendCount - stale.count)
        let depth = _matchingSuspendCount
        lock.unlock()
        for owner in stale {
            DevTypeLog.eventTap.error(
                """
                [EventTap] orphaned matching suspension recovered — \
                \(owner.reason, privacy: .public) held matching for \
                \(Int(now.timeIntervalSince(owner.since)), privacy: .public)s with DevType in the \
                background. Every typed trigger was silently ignored for that whole period.
                """
            )
        }
        matchDropLock.lock()
        _matchDrops.orphanedSuspensionsRecovered += stale.count
        matchDropLock.unlock()
        DevTypeLog.eventTap.notice(
            "[EventTap] matching resumed after orphan recovery depth=\(depth, privacy: .public)"
        )
        return stale.count
    }

    // MARK: - Matched-then-dropped telemetry

    /// Expansions that were **matched and then discarded**, by reason.
    ///
    /// This is the counter the field reports were missing. Every other number in the diagnostic
    /// report describes an expansion that reached the inject pipeline; a trigger that matched and
    /// was dropped before that point produced nothing at all — no outcome, no refuse provenance,
    /// no log line — which is indistinguishable, from the user's chair, from a snippet that does
    /// not exist. "It didn't expand" has to be answerable from the report.
    public struct MatchDropCounters: Equatable {
        /// `InjectionPlanner` refused on the cached permission snapshot (AX unavailable).
        public var plannerRefused = 0
        /// The live Secure Input check blocked the swallow after the polled flag said otherwise.
        public var secureInputLive = 0
        /// A held expansion was already in flight, so this match stood down.
        public var expansionInFlight = 0
        /// Suspensions force-cleared by `recoverOrphanedSuspensions`.
        public var orphanedSuspensionsRecovered = 0
        public var lastReason: String?
        public var lastTrigger: String?
        public var lastBundleID: String?
        public var lastAt: Date?

        public init() {}

        public var total: Int { plannerRefused + secureInputLive + expansionInFlight }

        public var isEmpty: Bool { total == 0 && orphanedSuspensionsRecovered == 0 }
    }

    private let matchDropLock = UnfairLock()
    private var _matchDrops = MatchDropCounters()

    public var matchDropCounters: MatchDropCounters {
        matchDropLock.withLock { _matchDrops }
    }

    /// Records a match that will not become an expansion. Never silent: a dropped match gets a
    /// counter *and* a log line, because the counter alone cannot say when it happened.
    func recordMatchDrop(reason: String, trigger: String?, bundleID: String?) {
        matchDropLock.lock()
        switch reason {
        case "plannerRefused": _matchDrops.plannerRefused += 1
        case "secureInputLive": _matchDrops.secureInputLive += 1
        case "expansionInFlight": _matchDrops.expansionInFlight += 1
        default: break
        }
        _matchDrops.lastReason = reason
        _matchDrops.lastTrigger = trigger
        _matchDrops.lastBundleID = bundleID
        _matchDrops.lastAt = Date()
        matchDropLock.unlock()
        DevTypeLog.eventTap.notice(
            """
            [EventTap] matched trigger dropped before expanding reason=\(reason, privacy: .public) \
            app=\(bundleID ?? "(unknown)", privacy: .public)
            """
        )
    }

    /// Report lines for matches that never became expansions.
    public func matchDropDiagnostics() -> [String] {
        let drops = matchDropCounters
        guard !drops.isEmpty else { return ["Matched-then-dropped: none"] }
        var lines = [
            "Matched-then-dropped: \(drops.total)"
                + " (planner-refused=\(drops.plannerRefused)"
                + " secure-input=\(drops.secureInputLive)"
                + " already-expanding=\(drops.expansionInFlight))"
        ]
        if drops.orphanedSuspensionsRecovered > 0 {
            lines.append(
                "  orphaned matching suspensions recovered: \(drops.orphanedSuspensionsRecovered)"
                    + " — matching was silently off before each recovery"
            )
        }
        if let reason = drops.lastReason, let at = drops.lastAt {
            lines.append(
                "  last: \(reason) trigger=\(drops.lastTrigger ?? "?")"
                    + " app=\(drops.lastBundleID ?? "(unknown)")"
                    + " at \(ISO8601DateFormatter().string(from: at))"
            )
        }
        return lines
    }

    /// Set when macOS Secure Event Input is active; matching is suppressed independently of user pause.
    public var isSecureInputActive: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSecureInputActive
        }
        set {
            lock.lock()
            let changed = _isSecureInputActive != newValue
            _isSecureInputActive = newValue
            if newValue && changed {
                ringBuffer.removeAll()
                layoutBuffer.clear()
                lastEventUTF16Count = 1
            }
            lock.unlock()
            if newValue && changed {
                // Secure Input can engage without a single keystroke reaching the tap (a
                // password sheet stealing focus). A hold armed just before that must not fire
                // on its timer — the deferred gate would refuse anyway where AX is readable,
                // but in an AX-opaque app the cancel here is the actual protection.
                heldCoordinator.cancelAll(reason: .unobservedInput)
            }
        }
    }

    /// Testable policy: whether this key should clear the ring buffer (no append / no match).
    public static func shouldResetBuffer(flags: CGEventFlags, keyCode: Int64) -> Bool {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return true
        }
        if KeyClassifier.action(forKeyCode: Int(keyCode)) == .clearBuffer {
            return true
        }
        if bufferResetKeyCodes.contains(keyCode) {
            return true
        }
        // Option / modified Backspace deletes a word or otherwise desyncs single-char removeLast.
        if keyCode == 51 {
            let modifiers: CGEventFlags = [.maskAlternate, .maskShift, .maskCommand, .maskControl]
            if !flags.intersection(modifiers).isEmpty {
                return true
            }
        }
        return false
    }

    /// Current TIS input source ID (empty on failure → physical Hangul fallback stays off).
    public static func currentInputSourceID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let cfID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return ""
        }
        return Unmanaged<CFString>.fromOpaque(cfID).takeUnretainedValue() as String
    }

    /// Autorepeat must not append or match — holding a key floods the ring buffer.
    public static func shouldIgnoreForMatching(isAutorepeat: Bool) -> Bool {
        isAutorepeat
    }

    /// InjectionPlanner contract: never keep a swallow if expand is refused.
    /// Sync-safe refuse (cached snapshot + planner) must pass the key through; async refuse must reinject.
    public static func shouldSwallowTrigger(plan: InjectionPlan) -> Bool {
        if case .refuse = plan { return false }
        return true
    }

    /// True when a deferred refuse must restore the swallowed final key to the target field.
    public static func mustReinjectOnRefuse(didSwallow: Bool) -> Bool {
        didSwallow
    }

    private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let engine = Unmanaged<EventTapEngine>.fromOpaque(refcon).takeUnretainedValue()
        // §1.1: this now runs on `TapRunLoopThread`, which (unlike the main run loop) does not
        // wrap each source callout in an autorelease pool of its own.
        return autoreleasepool { () -> Unmanaged<CGEvent>? in
            engine.handleTapEvent(type: type, event: event)
        }
    }

    /// The whole tap hot path. Extracted from the C callback so it can use `autoreleasepool`,
    /// early `return`s and instance state directly.
    ///
    /// Everything here must be safe off the main thread (§1.1): no AppKit, no synchronous AX IPC,
    /// no disk. AppKit-derived facts come from the caches refreshed by the app-switch /
    /// input-source observers (§2.3).
    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            handleTapDisabled(reason: .timeout)
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            handleTapDisabled(reason: .userInput)
            return Unmanaged.passUnretained(event)
        }

        let isSynthetic = event.getIntegerValueField(.eventSourceUserData) == SyntheticEventMarker.magicUserData
        if !isSynthetic {
            let eventTime = InputClock.seconds(sinceBootNanos: event.timestamp)
            if EventTapEngine.mouseDownTypes.contains(type) || type == .keyDown {
                inputClock.mark(at: eventTime)
            }
        }

        // Mouse clicks move the caret — buffer is no longer valid.
        if EventTapEngine.mouseDownTypes.contains(type) {
            // §8.3: and any keystrokes being held for an in-flight expansion must go out *now*,
            // at the caret they were typed at. Replaying them after the click would type them
            // wherever the user just clicked.
            lock.lock()
            let stranded = _typeAhead.flushForCaretChange()
            lock.unlock()
            replayTypeAhead(stranded, reason: "caret moved (click)")
            resetBuffer()
            // §3.1: same rule as escape/arrows below — the caret moved, so the recorded expansion
            // no longer describes what sits in front of it. Clicks were the one caret move that
            // kept the record alive, which let a click + backspace within the undo window fire a
            // blind erase at the click position in AX-opaque hosts.
            TextInjectionPipeline.shared.clearLastExpansion()
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // §2.4: one lock acquisition for all four gate flags instead of four.
        lock.lock()
        let expanding = _isExpanding
        let enabled = _isEnabled
        let secureFlag = _isSecureInputActive
        let suspended = _matchingSuspendCount > 0
        lock.unlock()

        // Pass through while inject+restore owns the critical section.
        // Must NOT swallow synthetic HID (backspace / ⌘V / arrows) we post ourselves.
        if expanding || isSynthetic {
            // §8.3: the expansion is still being delivered. Passing a real keystroke through here
            // is what let `a` land in front of `ScholarLM` — the paste was still in flight. Hold
            // it instead and replay after delivery, so ordering matches an instant expansion.
            if expanding, !isSynthetic {
                switch admitTypeAhead(event: event) {
                case .swallow:
                    return nil
                case .flushThenPassThrough(let replay):
                    replayTypeAhead(replay, reason: "hold released early")
                case .passThrough:
                    break
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard enabled && !secureFlag && !suspended else {
            // These keystrokes reach the field but bypass matching entirely. A live hold's
            // erase is counted from *observed* keystrokes, so anything landing unseen breaks
            // its integrity — drop the hold rather than fire a miscounted erase later.
            if heldCoordinator.cancelAll(reason: .unobservedInput) {
                DevTypeLog.debounce.debug(
                    "[Debounce] hold cancelled — keystroke bypassed matching (disabled/secure/suspended)"
                )
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if EventTapEngine.shouldIgnoreForMatching(isAutorepeat: isAutorepeat) {
            // Autorepeat appends characters the hold never sees (repeats are filtered from
            // matching). Same integrity rule as above: unobserved input, drop the hold.
            if heldCoordinator.cancelAll(reason: .unobservedInput) {
                DevTypeLog.debounce.debug(
                    "[Debounce] hold cancelled — autorepeat input is invisible to the hold"
                )
            }
            return Unmanaged.passUnretained(event)
        }

        if EventTapEngine.shouldResetBuffer(flags: flags, keyCode: keyCode) {
            resetBuffer()
            // §3.1: escape / arrows / chorded keys mean the caret probably moved, so the recorded
            // expansion no longer describes the text sitting in front of the caret. Undoing after
            // that would erase whatever happens to be there now — drop the record instead.
            TextInjectionPipeline.shared.clearLastExpansion()
            return Unmanaged.passUnretained(event)
        }

        // §2.3: stack scratch instead of `[UniChar](repeating: 0, count: 128)` — that was a
        // 256-byte heap allocation plus a zero-fill on every key event. The `String` is only
        // built when the key actually produced characters.
        var length = 0
        var unicodeStr = ""
        withUnsafeTemporaryAllocation(
            of: UniChar.self,
            capacity: EventTapEngine.unicodeScratchCapacity
        ) { scratch in
            guard let base = scratch.baseAddress else { return }
            var actual = 0
            event.keyboardGetUnicodeString(
                maxStringLength: EventTapEngine.unicodeScratchCapacity,
                actualStringLength: &actual,
                unicodeString: base
            )
            length = actual
            if actual > 0 {
                unicodeStr = String(utf16CodeUnits: base, count: actual)
            }
        }

        let shift = flags.contains(.maskShift)
        let physicalChar = USKeyboardLayout.character(forKeyCode: Int(keyCode), shift: shift)
            ?? unicodeStr.first
        let keyAction = KeyClassifier.action(forKeyCode: Int(keyCode))

        // §3.1: undo-expansion. A bare backspace within `InjectTiming.undoExpansionWindow` of a
        // delivered expansion reverts it — erase the injected text, put the trigger back. This is
        // the behaviour every competing expander ships, and all the machinery already existed in
        // the pipeline; nothing reached it.
        //
        // Deliberately narrow so it cannot fire by accident:
        //   - real key only (synthetic events were filtered above, so our own erase backspaces
        //     cannot re-enter here and walk backwards through the document),
        //   - autorepeat already filtered above, so holding backspace undoes at most once,
        //   - no modifiers: ⌥⌫ / ⌘⌫ delete by word or to line start, which is not an undo,
        //   - never while an expansion is in flight — already guaranteed, since the
        //     `expanding || isSynthetic` guard above returned early; re-reading it here would
        //     take `lock` again on the hot path for a value we have already proven false.
        // `undoLastExpansion()` is single-shot and does not block this callback (it hops to main
        // itself), and the erase still runs behind the erase-precondition guard — so if the user
        // typed more text after expanding, it refuses rather than destroying the field.
        if keyAction == .deleteLast,
           flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty,
           TextInjectionPipeline.shared.undoLastExpansion() {
            resetBuffer()
            return nil   // swallow: the undo replaces this backspace
        }

        // §3.1: any real key that mutates the field invalidates the "caret sits right after the
        // injected text" premise a *blind* (AX-opaque) undo rests on. Counted, not cleared:
        // readable fields can still widen over the typed tail; only the unverifiable blind path
        // refuses at a non-zero count. Runs after the undo check so the backspace that *is* the
        // undo never counts against the record it just consumed. No-op when no record exists.
        if keyAction == .deleteLast || length > 0 {
            TextInjectionPipeline.shared.noteInputAfterExpansion()
        }

        lock.lock()
        if keyAction == .deleteLast {
            ringBuffer.removeLast()
            layoutBuffer.deleteLast()
            lastEventUTF16Count = 1
        } else if length > 0 {
            // §2.3: the ring evicts its own oldest entry — no O(n) `removeFirst` memmove per key.
            ringBuffer.append(contentsOf: unicodeStr)
            if let physicalChar {
                layoutBuffer.appendLiteral(composed: unicodeStr, physical: physicalChar)
            }
            // AX ranges are UTF-16; keep erase math in the same units.
            lastEventUTF16Count = max(1, unicodeStr.utf16.count)
        }
        // §2.3: hand the matcher `[Character]` directly. The old path built a `String` here that
        // `AbbreviationMatcher.match` immediately undid with `Array(buffer)`.
        let bufferCharacters = ringBuffer.makeArray()
        let layoutSnapshot = layoutBuffer
        let lastUTF16Count = lastEventUTF16Count
        lock.unlock()

        // §2.3: cached frontmost facts. `AppMuteStore.isFrontmostMuted()` (NSWorkspace + NSLock),
        // `TISCopyCurrentKeyboardInputSource` and `isFrontmostAppTerminal()` all used to run per
        // key; with §1.1 they would also be AppKit/Carbon calls off the main thread.
        contextLock.lock()
        let context = _frontmostContext
        let allowPhysical = _allowPhysicalFallback
        contextLock.unlock()

        // Hot path: muted check + matcher + sync-safe planner gate only.
        // Heavy AX (secure/IME/focus) stays off-callback; refuse there reinjects the swallow.
        if context.isMuted {
            return Unmanaged.passUnretained(event)
        }

        // §2.1: cached matcher — one reference copy, no rebuild.
        let snapshotState = matchSnapshot
        let matchResult = findMatch(
            characters: bufferCharacters,
            layout: layoutSnapshot,
            allowPhysicalFallback: allowPhysical,
            snapshot: snapshotState,
            bundleID: context.bundleID
        )

        guard let match = matchResult else {
            // No match. If a shorter trigger is being held, this keystroke decides its fate:
            // either the user is still typing toward a longer trigger, or no longer trigger can
            // follow and the held one must fire now (with the characters typed meanwhile).
            resolveHeldExpansionOnNoMatch(
                typedNow: length > 0 ? unicodeStr : "",
                isDelete: keyAction == .deleteLast,
                prefixIndex: snapshotState.prefixIndex
            )
            return Unmanaged.passUnretained(event)
        }

        // A longer trigger won — drop any held shorter one and expand this normally. The final
        // key is swallowed as usual and the erase covers the whole matched trigger.
        if heldCoordinator.cancelAll(reason: .longerTriggerWon) {
            DevTypeLog.debounce.info("[Debounce] hold released — longer trigger matched and expands now")
        }

        // Prefix debounce: this trigger is a strict prefix of a longer one, so firing now would
        // make that longer trigger unreachable. Hold briefly instead. The key is NOT swallowed —
        // at this point we do not know which trigger the user is typing, and swallowing a key we
        // may never expand would silently eat input.
        // `fieldText` is nil for physical-Hangul matches, where the trigger cannot be
        // reconstructed — never hold one, since the erase could not be verified later.
        if let fieldText = match.fieldText,
           snapshotState.prefixIndex.isAmbiguous(
               trigger: fieldText,
               caseSensitive: match.snippet.isCaseSensitive
           ),
           Self.canHoldMatch(bundleID: context.bundleID) {
            holdExpansion(
                match: match,
                triggerText: fieldText,
                focusPID: context.processID
            )
            return Unmanaged.passUnretained(event)
        }

        let activeSnippets = snapshotState.snippets
        let snapshot = PermissionCoordinator.shared.cachedSnapshot
        let lookup: (String) -> String? = { trigger in
            activeSnippets.first { $0.triggerKeyword == trigger || (!$0.isCaseSensitive && $0.triggerKeyword.lowercased() == trigger.lowercased()) }?.replacementText
        }
        // Sync-safe shape for planner (no pasteboard; empty clipboard for refuse shape).
        let preview = MacroRenderer.expand(
            content: match.snippet.replacementText,
            fillValues: [:],
            lookup: lookup,
            clipboardText: ""
        )
        let previewText = preview.needsFillIn ? match.snippet.replacementText : preview.text
        let previewCursor = preview.needsFillIn ? nil : preview.cursorOffset
        let needsCursor = InjectionPlanner.needsCursorHID(
            cursorOffset: previewCursor,
            totalUTF16Length: previewText.utf16.count
        )
        // Dedicated terminals only on hot path (cached bundle ID); IDE shell needs AX → deferred.
        let isTerminal = context.isTerminal
        let plan = InjectionPlanner().plan(
            snapshot: snapshot,
            isTerminal: isTerminal,
            needsCursorHID: needsCursor,
            isMultiLine: previewText.contains(where: \.isNewline) || preview.needsFillIn
        )
        guard EventTapEngine.shouldSwallowTrigger(plan: plan) else {
            // InjectionPlanner refuse — must not swallow (pass key through).
            //
            // This exit used to be completely silent: the trigger matched, the plan refused, the
            // key passed through and nothing anywhere recorded that an expansion had been decided
            // against. The refuse provenance in the report covers the *deferred* gate, not this
            // one, so a stale cached snapshot could turn off every expansion in the app while the
            // report showed all capabilities granted.
            recordMatchDrop(
                reason: "plannerRefused",
                trigger: match.fieldText,
                bundleID: context.bundleID
            )
            return Unmanaged.passUnretained(event)
        }

        // §1.8: `_isSecureInputActive` comes from a 350 ms poll, so for up to 350 ms after a
        // password field takes focus a trigger would still be swallowed here and asynchronously
        // reinjected — REORDERING CHARACTERS IN A PASSWORD FIELD. `IsSecureEventInputEnabled()`
        // is a cheap non-IPC read; pay it once, only after a match (rare), before swallowing.
        // Deliberately does not mutate the polled flag: the monitor is edge-triggered, and
        // forcing it true here could latch matching off until the next real transition.
        if AXContextChecker.isSecureEventInputEnabledLive() {
            DevTypeLog.eventTap.notice(
                "[EventTap] live Secure Input check blocked a swallow (polled flag was stale)"
            )
            recordMatchDrop(
                reason: "secureInputLive",
                trigger: match.fieldText,
                bundleID: context.bundleID
            )
            return Unmanaged.passUnretained(event)
        }

        let focusPID = context.processID
        // Atomic claim on the inject pipeline. The `expanding` check at the top of this callback
        // ran before matching; a held expansion's debounce timer can begin an expansion in the
        // gap. Expanding here as well would write into the field twice — instead treat this
        // keystroke exactly as if `expanding` had been true at entry: admit it to type-ahead so
        // it replays after the in-flight delivery.
        guard tryBeginExpansion() else {
            DevTypeLog.debounce.notice(
                "[Debounce] immediate expansion suppressed — held expansion already in flight"
            )
            recordMatchDrop(
                reason: "expansionInFlight",
                trigger: match.fieldText,
                bundleID: context.bundleID
            )
            switch admitTypeAhead(event: event) {
            case .swallow:
                return nil
            case .flushThenPassThrough(let replay):
                replayTypeAhead(replay, reason: "hold released early")
            case .passThrough:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        resetBuffer()
        let utf16Trigger = match.eraseCount
        let charCount = lastUTF16Count
        let swallowedUnicode = unicodeStr
        let swallowedKeyCode = keyCode
        let swallowedFlags = flags
        let terminator = match.terminator
        let eraseOverride = match.source == .physical ? match.eraseCount : nil
        // Exact text expected left of the caret. Carries both unit systems (UTF-16 for AX
        // ranges, graphemes for backspaces) so neither path has to re-derive them.
        let erasePlan: ErasePlan
        if let fieldText = match.fieldText {
            erasePlan = ErasePlan.forMatch(
                matchedTrigger: fieldText,
                terminator: terminator,
                swallowedFinalKey: true,
                swallowedUnicode: swallowedUnicode,
                caseInsensitive: !match.snippet.isCaseSensitive
            )
        } else {
            erasePlan = .counted(match.eraseCount)
        }
        let matchedSnippet = match.snippet
        processingQueue.async { [weak self] in
            self?.performDeferredExpand(
                snippet: matchedSnippet,
                triggerUTF16Length: utf16Trigger,
                lastEventUTF16Count: charCount,
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags,
                terminator: terminator,
                eraseCountOverride: eraseOverride,
                erasePlan: erasePlan,
                armedFocusPID: focusPID
            )
        }
        return nil // Swallow only after sync-safe planner allow
    }

    public init() {
        let paused = UserDefaults.standard.bool(forKey: ProcessIdentity.userPausedDefaultsKey)
        _isEnabled = !paused
        installAppSwitchObserver()
        installInputSourceObserver()
        installMuteListObserver()
        refreshInputSourceCache()
        primeFrontmostContext()
    }

    deinit {
        removeAppSwitchObserver()
        removeInputSourceObserver()
        // §1.1: the worker parks in `CFRunLoopRun()` and keeps itself alive; without this a
        // discarded engine (tests) would leak a running thread.
        tapThread.shutdown()
    }

    public func start() -> Bool {
        let listenGranted = CGPreflightListenEventAccess()
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let axGranted = AXIsProcessTrustedWithOptions(axOptions)
        DevTypeLog.eventTap.info(
            "[EventTap] start begin listenPreflight=\(DevTypeLog.grantLabel(listenGranted), privacy: .public) ax=\(DevTypeLog.grantLabel(axGranted), privacy: .public)"
        )
        // `.defaultTap` (swallowing) needs Listen + Accessibility. Attempting create without AX
        // returns nil and used to be misreported as Tap Failed / identity mismatch.
        if !listenGranted || !axGranted {
            lock.lock()
            _isTapRunning = false
            lock.unlock()
            DevTypeLog.eventTap.error(
                "[EventTap] start refused — defaultTap requires Listen+Accessibility (listen=\(DevTypeLog.grantLabel(listenGranted), privacy: .public) ax=\(DevTypeLog.grantLabel(axGranted), privacy: .public))"
            )
            return false
        }
        tapLock.lock()
        let hadPort = _eventTapPort != nil
        tapLock.unlock()
        if hadPort {
            stop()
        }

        var mask: CGEventMask = 0
        mask |= 1 << CGEventType.keyDown.rawValue
        mask |= 1 << CGEventType.flagsChanged.rawValue
        mask |= 1 << CGEventType.leftMouseDown.rawValue
        mask |= 1 << CGEventType.rightMouseDown.rawValue
        mask |= 1 << CGEventType.otherMouseDown.rawValue

        let createdPort = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let port = createdPort else {
            lock.lock()
            _isTapRunning = false
            lock.unlock()
            DevTypeLog.eventTap.error(
                "[EventTap] start failed — CGEvent.tapCreate returned nil despite Listen+AX granted (check duplicate DevType processes / TCC identity)"
            )
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)

        // §1.1: attach to the dedicated tap thread's run loop so the callback (and everything it
        // synchronously touches) no longer runs on main. Falls back to the historical main
        // run loop if the worker did not come up, or if the kill switch is off.
        var targetRunLoop: CFRunLoop? = CFRunLoopGetMain()
        var onDedicatedThread = false
        if EventTapEngine.useDedicatedTapThread {
            if let workerLoop = tapThread.startAndWait() {
                targetRunLoop = workerLoop
                onDedicatedThread = true
            } else {
                DevTypeLog.eventTap.error(
                    "[EventTap] dedicated tap thread did not start — falling back to the main run loop"
                )
            }
        }

        CFRunLoopAddSource(targetRunLoop, source, .commonModes)
        CFRunLoopWakeUp(targetRunLoop)
        CGEvent.tapEnable(tap: port, enable: true)

        tapLock.lock()
        _eventTapPort = port
        _runLoopSource = source
        _tapRunLoop = targetRunLoop
        tapLock.unlock()

        lock.lock()
        _isTapRunning = true
        lock.unlock()
        // Refresh the AppKit-derived caches the callback depends on before the first key arrives.
        primeFrontmostContext()
        refreshInputSourceCache()
        startHealthMonitor()
        DevTypeLog.eventTap.info(
            "[EventTap] start success — defaultTap installed + health monitor (dedicatedThread=\(onDedicatedThread, privacy: .public))"
        )
        return true
    }

    /// Removes the tap. Safe from any thread, including the tap thread itself — `CFRunLoop` is the
    /// one Core Foundation class documented as thread-safe. The worker thread is left parked (it
    /// holds a keep-alive port) so a later `start()` does not have to churn threads; use
    /// `shutdownTapThread()` for a full teardown.
    public func stop() {
        let wasRunning = isTapRunning
        stopHealthMonitor()

        tapLock.lock()
        let port = _eventTapPort
        let source = _runLoopSource
        let loop = _tapRunLoop
        _eventTapPort = nil
        _runLoopSource = nil
        _tapRunLoop = nil
        tapLock.unlock()

        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source {
            // Falls back to main only for the degenerate case where the tap was installed on the
            // main run loop (kill switch off / worker thread failed to start).
            let hostLoop: CFRunLoop? = loop ?? CFRunLoopGetMain()
            CFRunLoopRemoveSource(hostLoop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let port {
            CFMachPortInvalidate(port)
        }
        if let loop {
            CFRunLoopWakeUp(loop)
        }

        lock.lock()
        _isTapRunning = false
        lock.unlock()
        // With the tap gone, nothing can observe or cancel a live hold — its debounce timer
        // would fire into a field DevType is no longer watching.
        heldCoordinator.cancelAll(reason: .unobservedInput)
        if wasRunning {
            DevTypeLog.eventTap.info("[EventTap] stop — tap removed")
        }
    }

    /// §1.1: full teardown of the dedicated tap thread. `stop()` alone leaves it parked.
    public func shutdownTapThread() {
        stop()
        tapThread.shutdown()
    }

    /// True when the tap source is attached to the dedicated §1.1 thread rather than main.
    public var isTapOnDedicatedThread: Bool {
        tapLock.lock()
        let loop = _tapRunLoop
        tapLock.unlock()
        guard let loop, let worker = tapThread.runLoop else { return false }
        return loop === worker
    }

    public func reEnableTap() {
        tapLock.lock()
        let port = _eventTapPort
        tapLock.unlock()
        guard let port else { return }
        // §2.10: the loud, counted line lives in `handleTapDisabled`; this stays quiet so a
        // re-enable storm does not drown the log it is trying to explain.
        DevTypeLog.eventTap.debug("[EventTap] tapEnable(true)")
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// §2.10: counted, rate-limited handling for `tapDisabledByTimeout` / `ByUserInput`.
    ///
    /// The old code re-enabled and logged one indistinguishable `notice`, which hid the fact that
    /// `byTimeout` means *our callback was too slow* — the actionable failure mode, and the one
    /// §1.1 exists to fix. Repeated timeouts in a short window now escalate to a full tap
    /// reinstall, with exponential backoff so a persistent problem cannot become a reinstall loop.
    ///
    /// Runs on the tap thread; the reinstall itself is hopped to main because it creates a new
    /// mach port and run loop source.
    public func handleTapDisabled(reason: TapDisableReason) {
        // The system disabled the tap, so keystrokes have been flowing straight to the field
        // unseen. A live hold's erase count is now unverifiable-by-construction — and its
        // timeout quiescence check is blind for the same reason the hold is (no events, no
        // marks). Cancel before anything else; the trigger stays literal.
        heldCoordinator.cancelAll(reason: .unobservedInput)
        let now = Date()

        counterLock.lock()
        switch reason {
        case .timeout:
            _tapDisableCounters.byTimeout += 1
            _tapDisableCounters.lastTimeoutAt = now
            _recentTimeoutStamps.append(now)
            _recentTimeoutStamps.removeAll {
                now.timeIntervalSince($0) > EventTapEngine.tapDisableEscalationWindow
            }
        case .userInput:
            _tapDisableCounters.byUserInput += 1
            _tapDisableCounters.lastUserInputAt = now
        case .unspecified:
            break
        }
        _tapDisableCounters.reEnables += 1
        let burst = _recentTimeoutStamps.count
        var escalate = false
        if reason == .timeout, burst >= EventTapEngine.tapDisableEscalationThreshold {
            let allowedAt = _nextReinstallAllowedAt ?? Date.distantPast
            if now >= allowedAt {
                escalate = true
                _tapDisableCounters.escalatedReinstalls += 1
                _nextReinstallAllowedAt = now.addingTimeInterval(_reinstallBackoff)
                _reinstallBackoff = min(
                    _reinstallBackoff * 2,
                    EventTapEngine.tapReinstallMaxBackoff
                )
                _recentTimeoutStamps.removeAll()
            }
        }
        let counters = _tapDisableCounters
        counterLock.unlock()

        // Cheap and safe from the tap thread: flip the enable bit back on immediately.
        reEnableTap()

        let reasonLabel: String
        switch reason {
        case .timeout: reasonLabel = "tapDisabledByTimeout"
        case .userInput: reasonLabel = "tapDisabledByUserInput"
        case .unspecified: reasonLabel = "tapDisabled"
        }

        if reason == .timeout {
            DevTypeLog.eventTap.error(
                "[EventTap] \(reasonLabel, privacy: .public) — callback exceeded the system budget (burst=\(burst, privacy: .public) \(counters.summaryLine, privacy: .public))"
            )
        } else {
            DevTypeLog.eventTap.notice(
                "[EventTap] \(reasonLabel, privacy: .public) re-enabled (\(counters.summaryLine, privacy: .public))"
            )
        }

        guard escalate else { return }
        DevTypeLog.eventTap.error(
            "[EventTap] \(burst, privacy: .public) timeout disables within \(EventTapEngine.tapDisableEscalationWindow, privacy: .public)s — reinstalling the tap"
        )
        DispatchQueue.main.async { [weak self] in
            self?.reinstallFromHealthMonitor(reason: "tapDisabledByTimeout burst")
        }
    }

    /// Starts a main-queue timer that re-enables or reinstalls an inert CGEvent tap.
    /// Called automatically from `start()`; safe to call again (resets the timer).
    public func startHealthMonitor() {
        stopHealthMonitor()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + healthCheckInterval, repeating: healthCheckInterval)
        timer.setEventHandler { [weak self] in
            self?.checkTapHealth()
        }
        healthTimer = timer
        timer.resume()
    }

    private func stopHealthMonitor() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    /// If the tap is expected to be live but `tapIsEnabled` is false (or the port is gone),
    /// try `tapEnable` then a full reinstall. Addresses silent disable after timeout/re-sign.
    private func checkTapHealth() {
        // A live tap with matching suspended is *also* a total expansion outage, and the tap
        // health check is the only thing already running on a timer that can notice. Checked
        // before the port checks below so an orphaned suspension is recovered even while the tap
        // itself is perfectly healthy — which is exactly how it presents.
        recoverOrphanedSuspensions(isDevTypeFrontmost: isDevTypeFrontmost())

        lock.lock()
        let expectRunning = _isTapRunning
        let userEnabled = _isEnabled
        lock.unlock()
        guard expectRunning, userEnabled else { return }

        // §1.11: never touch `_eventTapPort` unlocked — the tap thread reads it from `reEnableTap`.
        tapLock.lock()
        let currentPort = _eventTapPort
        tapLock.unlock()

        guard let port = currentPort else {
            DevTypeLog.eventTap.notice(
                "[EventTap] health: port missing while expected running — reinstalling"
            )
            // No tap, no observation — any hold armed before the port vanished is blind.
            heldCoordinator.cancelAll(reason: .unobservedInput)
            reinstallFromHealthMonitor(reason: "nil port")
            return
        }

        if CGEvent.tapIsEnabled(tap: port) {
            return
        }

        DevTypeLog.eventTap.notice(
            "[EventTap] health: tapIsEnabled=false — attempting tapEnable then reinstall"
        )
        // The tap was silently inert for up to one health interval — keystrokes reached the
        // field unseen, so any live hold is miscounted by construction.
        heldCoordinator.cancelAll(reason: .unobservedInput)
        CGEvent.tapEnable(tap: port, enable: true)
        if !CGEvent.tapIsEnabled(tap: port) {
            reinstallFromHealthMonitor(reason: "inert tap")
        } else {
            DevTypeLog.eventTap.info("[EventTap] health: tap re-enabled without reinstall")
        }
    }

    private func reinstallFromHealthMonitor(reason: String) {
        let snapshot = PermissionCoordinator.shared.cachedSnapshot
        if snapshot.blocksDefaultEventTap {
            DevTypeLog.eventTap.error(
                "[EventTap] health: reinstall skipped — Listen/AX missing (\(reason)); clearing running flag"
            )
            lock.lock()
            _isTapRunning = false
            lock.unlock()
            notifyTapHealthChanged()
            return
        }

        let ok = start()
        if !ok {
            DevTypeLog.eventTap.error(
                "[EventTap] health: reinstall failed after \(reason) (possible TCC revoke / identity)"
            )
            notifyTapHealthChanged()
        } else {
            DevTypeLog.eventTap.info("[EventTap] health: reinstall succeeded after \(reason)")
            notifyTapHealthChanged()
        }
    }

    private func notifyTapHealthChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onTapHealthChanged?()
        }
    }


    // MARK: - Prefix debounce (ambiguous triggers)

    /// How long a match is held when a longer trigger could still win.
    ///
    /// Only ambiguous triggers ever wait — one that no other trigger extends fires with zero
    /// added latency, which is the overwhelming majority. The window applies only to a hold
    /// with nothing typed after the trigger (see `holdExpansion`); once the user types onward toward
    /// a longer trigger, no timeout fires at all.
    ///
    /// So this governs exactly one gap: finishing `` `slm `` and starting the `a` of
    /// `` `slmabout ``. At 250 ms that gap was tighter than an ordinary pause-and-continue, and
    /// the longer trigger became unreachable whenever the user hesitated before it.
    ///
    /// The cost is paid by the shorter trigger: typing `` `slm `` and stopping now waits this
    /// long before expanding. That is the whole trade — every millisecond that makes
    /// `` `slmabout `` easier to reach makes `` `slm `` slower to fire, and no value avoids it.
    ///
    /// Default 500 ms; overridable in milliseconds via
    /// `defaults write com.devtype.app DevTypePrefixDebounceMs -int 650` (read once at first
    /// use, clamped to 100–2000 ms so a typo cannot make triggers feel dead or fire mid-word).
    public static let prefixDebounceMsDefaultsKey = "DevTypePrefixDebounceMs"

    public static var prefixDebounceInterval: TimeInterval = {
        let stored = UserDefaults.standard.integer(forKey: prefixDebounceMsDefaultsKey)
        guard stored > 0 else { return 0.5 }
        return min(max(TimeInterval(stored) / 1000.0, 0.1), 2.0)
    }()

    /// Upper bound on a hold that is waiting for a decisive keystroke.
    ///
    /// Such a hold has no firing timer, so without this it would live until the buffer reset —
    /// holding a snapshot of a snippet the user may since have edited, against a caret that may
    /// have moved in a way no reset caught. Expiry **cancels**; it never expands. The cost of
    /// being wrong is the user's literal text staying put, not an erase in the wrong place.
    public static let heldExpansionStaleTimeout: TimeInterval = 10.0

    /// Whether a match may be held at all in this app.
    ///
    /// Universal by design. Holding used to require a *verifiable* erase (AX-readable field),
    /// which excluded every Chromium/Electron shell — there, the shorter trigger fired
    /// immediately and `` `slmabout `` was unreachable. That restriction is no longer needed,
    /// because the hold now guarantees its own erase count without AX:
    ///
    ///   * every character typed after the trigger is accumulated from the observed keystrokes
    ///     themselves (`HeldExpansionState.typedAfter`), and the erase covers trigger + suffix;
    ///   * any input the hold cannot account for kills it instead — autorepeat, keystrokes
    ///     bypassing matching (disabled / suspended / Secure Input), chords, clicks, focus and
    ///     app switches, Return/Tab, and no-character keys all cancel;
    ///   * a timeout fire additionally proves quiescence: if *any* key event was marked on
    ///     `inputClock` after the hold was armed — including one still in flight through the
    ///     tap at the deadline — the fire aborts rather than run a miscounted erase;
    ///   * where AX *can* read the field, the erase precondition still verifies text
    ///     byte-for-byte before anything is destroyed, exactly as before.
    ///
    /// Under those invariants a held erase is no blinder than the immediate path already is in
    /// AX-opaque apps (counted backspaces after a swallowed key). The residual exposure —
    /// text inserted with no input event at all (dictation, app-side autofill) during the
    /// ≤500 ms window — is shared with the immediate path and bounded by the same refusal
    /// guards where AX is readable.
    static func canHoldMatch(bundleID: String?) -> Bool {
        // The user disabled the precondition guard; with verification off everywhere, keep the
        // most conservative behaviour: no holds at all.
        guard ErasePreconditionChecker.isEnabled else { return false }
        // No bundle ID: the frontmost context is unknown, so the fire-time focus-PID check
        // cannot anchor to anything — do not leave a trigger sitting in an unidentified field.
        guard let bundleID, !bundleID.isEmpty else { return false }
        return true
    }

    /// What the engine stores inside a hold: the match plus the input-clock reading at arm
    /// time. A legitimate timeout fire requires that no key event was marked after this value
    /// — see `expandHeld`.
    struct HeldPayload {
        let match: SnippetMatch
        let armInputMark: TimeInterval?
    }

    /// Begin holding `match`. Never swallows the key: at this point we do not know which trigger
    /// the user is typing, and swallowing one we may never expand would eat input.
    ///
    /// The debounce timer fires **only while nothing has been typed after the trigger**.
    /// Stopping on `` `slm `` means the user meant `` `slm ``, so it fires after the debounce.
    /// But once they have typed on toward a longer trigger, a timeout is the wrong answer:
    /// firing `` `slm `` part-way through `` `slmabout `` produces `ScholarLM` with `about`
    /// stranded after it, and it only takes one hesitation mid-word to trigger. There, the hold
    /// waits for a keystroke that actually decides — a divergent character, a terminator,
    /// backspace, or a focus change — bounded only by `heldExpansionStaleTimeout`.
    ///
    /// The timer is armed against the hold's generation and is never explicitly cancelled: the
    /// coordinator's generation CAS makes a stale timer a no-op, which is simpler than a
    /// cancellable timer source per hold and equivalent — the CAS, not the cancellation, is
    /// what guarantees at-most-one fire.
    private func holdExpansion(
        match: SnippetMatch,
        triggerText: String,
        focusPID: pid_t?
    ) {
        // The arming keystroke marked the clock at its own tap entry, so this reading is that
        // keystroke's timestamp. Anything marked later arrived during the hold.
        let payload = HeldPayload(match: match, armInputMark: inputClock.lastInputAt)
        let hold = heldCoordinator.arm(payload: payload, trigger: triggerText, focusPID: focusPID)
        DevTypeLog.debounce.info(
            "[Debounce] hold armed gen=\(hold.generation, privacy: .public) triggerLen=\(triggerText.count, privacy: .public) window=\(Int(Self.prefixDebounceInterval * 1000), privacy: .public)ms"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.prefixDebounceInterval) { [weak self] in
            self?.fireHeldExpansionOnTimeout(generation: hold.generation)
        }
    }

    /// Bounds the lifetime of a hold that has no firing timer (the user typed onward toward a
    /// longer trigger). Expiry **cancels**; it never expands — see `heldExpansionStaleTimeout`.
    private func scheduleStaleExpiry(generation: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.heldExpansionStaleTimeout) {
            [weak self] in
            guard let self else { return }
            if self.heldCoordinator.cancel(generation: generation, reason: .stale) {
                DevTypeLog.debounce.notice(
                    "[Debounce] hold expired stale gen=\(generation, privacy: .public) — cancelled, nothing expanded"
                )
            }
        }
    }

    /// Drop any held expansion. The generation bump inside the coordinator invalidates every
    /// pending timer, so a cancelled hold can never fire later.
    public func cancelHeldExpansion() {
        heldCoordinator.cancelAll(reason: .bufferReset)
    }

    /// A keystroke produced no match while an expansion was held.
    ///
    /// `typedNow` is what *this* keystroke put in the field, taken straight from the event
    /// rather than from the ring buffer — see `HeldExpansionState`. The decision and the state
    /// change are one atomic step inside the coordinator; this method only performs the side
    /// effects for the outcome it is handed.
    private func resolveHeldExpansionOnNoMatch(
        typedNow: String,
        isDelete: Bool,
        prefixIndex: TriggerPrefixIndex
    ) {
        switch heldCoordinator.resolveKeystroke(
            typedNow: typedNow,
            isDelete: isDelete,
            prefixIndex: prefixIndex
        ) {
        case .noHold:
            return

        case .cancelled(let reason):
            DevTypeLog.debounce.info(
                "[Debounce] hold cancelled reason=\(reason.rawValue, privacy: .public)"
            )

        case .rearmed(let hold):
            // Debounce timer reset: the previous generation's timer is now a no-op, and the
            // hold waits for a decisive keystroke, bounded only by stale expiry.
            DevTypeLog.debounce.debug(
                "[Debounce] hold extended gen=\(hold.generation, privacy: .public) typedAfterLen=\(hold.state.typedAfter.count, privacy: .public) — timer reset"
            )
            scheduleStaleExpiry(generation: hold.generation)

        case .fire(let hold, let suffix):
            // `kind` is a category, never content: it is what separates "fired on a space after
            // the short trigger" (correct) from "fired on a word character" (a longer trigger
            // the matcher failed to see) in a field report.
            let kind: String
            if let first = suffix.first {
                kind = first.isLetter || first.isNumber || first == "_"
                    ? "word" : (first.isWhitespace ? "space" : "punct")
            } else {
                kind = "empty"
            }
            DevTypeLog.debounce.info(
                "[Debounce] hold fired by keystroke gen=\(hold.generation, privacy: .public) suffixLen=\(suffix.utf16.count, privacy: .public) suffixKind=\(kind, privacy: .public)"
            )
            expandHeld(hold, suffix: suffix)
        }
    }

    /// Debounce deadline for `generation`. The claim is a generation CAS — if the user typed
    /// onward, a longer trigger won, or a reset moved the hold, the claim is refused and the
    /// timer dies silently (counted as an absorbed race in the telemetry).
    private func fireHeldExpansionOnTimeout(generation: UInt64) {
        guard let hold = heldCoordinator.claimForTimeout(generation: generation) else { return }
        DevTypeLog.debounce.info(
            "[Debounce] hold fired by timeout gen=\(generation, privacy: .public)"
        )
        expandHeld(hold, suffix: hold.state.pendingSuffix, firedByTimeout: true)
    }

    /// Expand a claimed hold. `suffix` is everything typed after the trigger during the hold —
    /// it is erased along with the trigger and re-appended after the expansion, so the field
    /// ends up exactly as firing immediately would have left it.
    ///
    /// Runs on the main queue (timeout) or the tap thread (decisive keystroke); both are fine —
    /// the heavy work happens on `processingQueue` either way.
    private func expandHeld(
        _ hold: HeldExpansionCoordinator<HeldPayload>.Hold,
        suffix: String,
        firedByTimeout: Bool = false
    ) {
        // The immediate-match path claims the pipeline the same way; whichever side loses the
        // race must stand down rather than write into the field twice.
        guard tryBeginExpansion() else {
            DevTypeLog.debounce.notice(
                "[Debounce] held expansion suppressed — another expansion already in flight"
            )
            return
        }

        // Timeout fires must prove quiescence: a successful claim already implies no keystroke
        // was *resolved* since the hold was armed, so any newer mark on the input clock is a
        // key event still in flight through the tap at the deadline. Keystroke-decided fires
        // never need this — they run on the tap thread, serial with all other key events.
        //
        // Ordering makes the check sound: every keystroke marks the clock at tap entry,
        // *before* the `expanding` gate. A keystroke that will slip past that gate has
        // therefore already marked by the time we read the clock here (after the gate went
        // up in `tryBeginExpansion`), so it cannot be missed; one that arrives later is
        // captured by type-ahead and replayed. Aborting leaves the trigger literal — in an
        // AX-opaque app a miscounted blind erase would eat the in-flight character instead.
        if firedByTimeout,
           let armMark = hold.payload.armInputMark,
           let lastInput = inputClock.lastInputAt,
           lastInput > armMark {
            DevTypeLog.debounce.notice(
                "[Debounce] timeout fire aborted — input arrived at the deadline (Δ=\(Int((lastInput - armMark) * 1000), privacy: .public)ms after arm); trigger left in place"
            )
            endExpansion()
            return
        }

        let trigger = hold.state.trigger
        let eraseText = trigger + suffix
        // No key was swallowed on this path, so the whole trigger is sitting in the field.
        let erasePlan = ErasePlan(
            text: eraseText,
            caseInsensitive: !hold.payload.match.snippet.isCaseSensitive
        )

        resetBuffer()

        let snippet = hold.payload.match.snippet
        let focusPID = hold.focusPID
        processingQueue.async { [weak self] in
            self?.performDeferredExpand(
                snippet: snippet,
                triggerUTF16Length: eraseText.utf16.count,
                lastEventUTF16Count: 0,
                swallowedUnicode: "",
                swallowedKeyCode: 0,
                swallowedFlags: [],
                terminator: "",
                eraseCountOverride: nil,
                erasePlan: erasePlan,
                armedFocusPID: focusPID,
                swallowedFinalKey: false,
                textSuffix: suffix
            )
        }
    }

    /// Prefix-debounce lifecycle counters for the manager UI / `DiagnosticReport`.
    public func prefixDebounceDiagnostics() -> String {
        heldCoordinator.telemetry.summaryLine
    }

    public func resetBuffer() {
        // A held expansion describes text at a caret position this reset invalidates (mouse
        // click, focus change, escape). Cancel it *first*: from the moment the invalidating
        // event is known, a debounce timer must not be able to claim the hold — the erase
        // precondition would still catch a bad fire, but there is no reason to leave the door
        // open. Outside `lock`: the coordinator has its own lock, and the established ordering
        // is `lock` → coordinator, never nested — keep it that way.
        heldCoordinator.cancelAll(reason: .bufferReset)
        lock.lock()
        ringBuffer.removeAll()
        layoutBuffer.clear()
        lastEventUTF16Count = 1
        lock.unlock()
    }

    // MARK: - §3.9 trigger-length diagnostics

    /// §3.9: triggers longer than `maxBufferCapacity`. They can never fire — the ring buffer and
    /// `LayoutBuffer` both cap at that length — and previously nothing said so.
    public func overlongTriggers() -> [String] {
        matchSnapshot.matcher.overlongTriggers
    }

    /// Human-readable form for the manager UI / `DiagnosticReport`. Empty when nothing is broken.
    public func overlongTriggerDiagnostics() -> [String] {
        let triggers = overlongTriggers()
        guard !triggers.isEmpty else { return [] }
        var lines = [
            "\(triggers.count) trigger(s) exceed the \(EventTapEngine.maxBufferCapacity)-character match buffer and can never fire:"
        ]
        for trigger in triggers.sorted() {
            lines.append("  \(trigger) (\(trigger.count) characters)")
        }
        return lines
    }

    /// Every snippet in the library that can **never** respond to typing, and why.
    ///
    /// Three distinct causes, one user experience: the snippet sits in the list looking perfectly
    /// healthy, its trigger is spelled right, and typing it does nothing. Only one of the three
    /// was reported before, so the other two were indistinguishable from a broken engine.
    ///
    /// Takes the full library — including the secrets `snippets` filters out of the matcher — so
    /// it can name what the matcher deliberately cannot see.
    public func silentNoExpandDiagnostics(library: [SnippetModel]? = nil) -> [String] {
        let all = library ?? libraryLock.withLock { _fullLibrary }
        var lines: [String] = []

        // 1. Secrets. Deliberate (a keychain-backed snippet must never fire from typing), but
        //    invisible: nothing in the UI or the old report said "this trigger is typing-proof".
        let secrets = all.filter { $0.enabled && $0.isSecret && !$0.triggerKeyword.isEmpty }
        if !secrets.isEmpty {
            lines.append(
                "\(secrets.count) secret snippet(s) never expand from a typed trigger by design —"
                    + " use the inline search panel instead:"
            )
            for snippet in secrets.map(\.triggerKeyword).sorted() {
                lines.append("  \(snippet)")
            }
        }

        // 2. Overlong. Already reported separately; folded in here so one call answers the whole
        //    question rather than the caller having to know there are two lists.
        lines.append(contentsOf: overlongTriggerDiagnostics())

        // 3. Duplicates. `AbbreviationMatcher` keeps the first snippet for a colliding trigger, so
        //    every later one is unreachable — and nothing said so.
        var seen: [String: String] = [:]
        var shadowed: [String] = []
        for snippet in all where snippet.enabled && !snippet.isSecret && !snippet.triggerKeyword.isEmpty {
            let key = snippet.isCaseSensitive
                ? snippet.triggerKeyword
                : snippet.triggerKeyword.lowercased()
            if let winner = seen[key] {
                shadowed.append("\(snippet.displayTitle) (trigger \(snippet.triggerKeyword), shadowed by \(winner))")
            } else {
                seen[key] = snippet.displayTitle
            }
        }
        if !shadowed.isEmpty {
            lines.append(
                "\(shadowed.count) snippet(s) share a trigger with an earlier one and can never fire:"
            )
            for entry in shadowed.sorted() {
                lines.append("  \(entry)")
            }
        }

        return lines
    }

    private func logOverlongTriggers(in snapshot: SnippetMatchSnapshot) {
        let triggers = snapshot.matcher.overlongTriggers
        guard !triggers.isEmpty else { return }
        DevTypeLog.eventTap.notice(
            "[EventTap] \(triggers.count, privacy: .public) trigger(s) longer than \(EventTapEngine.maxBufferCapacity, privacy: .public) characters can never fire — see overlongTriggerDiagnostics()"
        )
    }

    /// Off-callback expand: AX gates, macro resolve / fill-in, inject plan, then inject-owned lifetime.
    /// On refuse after swallow, reinjects the trigger key (InjectionPlanner contract).
    private func performDeferredExpand(
        snippet: SnippetModel,
        triggerUTF16Length: Int,
        lastEventUTF16Count: Int,
        swallowedUnicode: String,
        swallowedKeyCode: Int64,
        swallowedFlags: CGEventFlags,
        terminator: String,
        eraseCountOverride: Int?,
        erasePlan: ErasePlan,
        armedFocusPID: pid_t?,
        /// False when the trigger's final key was let through instead of swallowed — the
        /// prefix-debounce path never swallows, because at match time we do not yet know
        /// whether a longer trigger will win.
        swallowedFinalKey: Bool = true,
        /// Characters typed after the trigger while the match was held. They are inside
        /// `erasePlan`, so they must be re-appended to the injected text or they vanish.
        textSuffix: String = ""
    ) {
        let quiescence = inputClock.arm()

        // AX / AppKit / Secure Input must run on main (avoid off-main IPC flake + nested main.sync).
        let mainProbe = Self.runOnMainSync { () -> (
            decision: AXContextChecker.ExpandGateDecision,
            secureInput: Bool,
            clipboard: String?,
            currentPID: pid_t?,
            refuseContext: PermissionCoordinator.InjectRefuseProvenance?
        ) in
            let snapshot = PermissionCoordinator.shared.cachedSnapshot
            let decision = AXContextChecker.shared.evaluateExpandGate(
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents
            )
            let secureInput = AXContextChecker.isSecureEventInputEnabledLive()
            let clipboard = NSPasteboard.general.string(forType: .string)
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let refuseContext: PermissionCoordinator.InjectRefuseProvenance?
            if secureInput {
                refuseContext = .capture(
                    reason: AXContextChecker.secureInputActiveReason,
                    decision: decision
                )
            } else if decision.shouldBlock {
                refuseContext = .capture(reason: decision.reason, decision: decision)
            } else {
                refuseContext = nil
            }
            return (decision, secureInput, clipboard, currentPID, refuseContext)
        }

        if mainProbe.secureInput {
            refuseAfterSwallow(
                reason: AXContextChecker.secureInputActiveReason,
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags,
                refuseContext: mainProbe.refuseContext
            )
            return
        }

        if mainProbe.decision.shouldBlock {
            refuseAfterSwallow(
                reason: mainProbe.decision.reason,
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags,
                refuseContext: mainProbe.refuseContext
            )
            return
        }

        if let armedFocusPID, mainProbe.currentPID != armedFocusPID {
            refuseAfterSwallow(
                reason: "Focus moved — expand aborted",
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags
            )
            return
        }

        if case .abort = inputClock.decide(quiescence) {
            refuseAfterSwallow(
                reason: "User input after arm — expand aborted",
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags
            )
            return
        }

        // Typed AI transform: erase the trigger under fresh gates, end expansion immediately,
        // then hand off to the panel off-pipeline. Never hold `_isExpanding` across the model call.
        if !snippet.aiTransform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            handleTypedAITransformExpand(
                snippet: snippet,
                erasePlan: erasePlan,
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags,
                quiescence: quiescence,
                armedFocusPID: armedFocusPID
            )
            return
        }

        let clipboardSnapshot = mainProbe.clipboard
        let lookup: (String) -> String? = { [weak self] trigger in
            guard let self else { return nil }
            return self.snippets.first {
                $0.triggerKeyword == trigger
                    || (!$0.isCaseSensitive && $0.triggerKeyword.lowercased() == trigger.lowercased())
            }?.replacementText
        }

        let firstPass = MacroRenderer.expand(
            content: snippet.replacementText,
            fillValues: [:],
            lookup: lookup,
            clipboardText: clipboardSnapshot
        )

        if firstPass.needsFillIn {
            let fields = firstPass.fillFields
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let presenter = self.presentFillIn
                guard let presenter else {
                    self.refuseAfterSwallow(
                        reason: "Fill-in required but no presenter wired",
                        swallowedUnicode: swallowedUnicode,
                        swallowedKeyCode: swallowedKeyCode,
                        swallowedFlags: swallowedFlags
                    )
                    return
                }
                presenter(snippet.displayTitle, fields) { values in
                    self.processingQueue.async {
                        guard let values else {
                            self.refuseAfterSwallow(
                                reason: "Fill-in cancelled",
                                swallowedUnicode: swallowedUnicode,
                                swallowedKeyCode: swallowedKeyCode,
                                swallowedFlags: swallowedFlags
                            )
                            return
                        }
                        // Double-arm quiescence on panel close (panel Return must not abort).
                        let postPanel = self.inputClock.arm()
                        let resolved = MacroRenderer.expand(
                            content: snippet.replacementText,
                            fillValues: values,
                            lookup: lookup,
                            clipboardText: clipboardSnapshot
                        )
                        self.finishDeferredInject(
                            snippet: snippet,
                            triggerUTF16Length: triggerUTF16Length,
                            lastEventUTF16Count: lastEventUTF16Count,
                            swallowedUnicode: swallowedUnicode,
                            swallowedKeyCode: swallowedKeyCode,
                            swallowedFlags: swallowedFlags,
                            terminator: terminator,
                            eraseCountOverride: eraseCountOverride,
                            erasePlan: erasePlan,
                            resolved: resolved,
                            clipboardSnapshot: clipboardSnapshot,
                            quiescence: postPanel,
                            armedFocusPID: armedFocusPID,
                            swallowedFinalKey: swallowedFinalKey,
                            textSuffix: textSuffix
                        )
                    }
                }
            }
            return
        }

        finishDeferredInject(
            snippet: snippet,
            triggerUTF16Length: triggerUTF16Length,
            lastEventUTF16Count: lastEventUTF16Count,
            swallowedUnicode: swallowedUnicode,
            swallowedKeyCode: swallowedKeyCode,
            swallowedFlags: swallowedFlags,
            terminator: terminator,
            eraseCountOverride: eraseCountOverride,
            erasePlan: erasePlan,
            resolved: firstPass,
            clipboardSnapshot: clipboardSnapshot,
            quiescence: quiescence,
            armedFocusPID: armedFocusPID,
            swallowedFinalKey: swallowedFinalKey,
            textSuffix: textSuffix
        )
    }

    /// Off-pipeline typed AI path: fresh Secure Input + AX gates, selection cache, guarded erase,
    /// `endExpansion`, then `presentAITransform` on main. Model work must not run under `_isExpanding`.
    private func handleTypedAITransformExpand(
        snippet: SnippetModel,
        erasePlan: ErasePlan,
        swallowedUnicode: String,
        swallowedKeyCode: Int64,
        swallowedFlags: CGEventFlags,
        quiescence: InputQuiescenceGuard,
        armedFocusPID: pid_t?
    ) {
        guard let kind = AITransformKind.named(snippet.aiTransform) else {
            refuseAfterSwallow(
                reason: "Unknown AI transform kind",
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags
            )
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if case .abort = self.inputClock.decide(quiescence) {
                self.refuseAfterSwallow(
                    reason: "User input after arm — expand aborted",
                    swallowedUnicode: swallowedUnicode,
                    swallowedKeyCode: swallowedKeyCode,
                    swallowedFlags: swallowedFlags
                )
                return
            }

            // Re-check gates live — SecureInputMonitor's 350ms poll is stale; passwords must
            // never reach the model.
            let snapshot = PermissionCoordinator.shared.cachedSnapshot
            let decision = AXContextChecker.shared.evaluateExpandGate(
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents
            )
            let secureInput = AXContextChecker.isSecureEventInputEnabledLive()
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

            if secureInput {
                self.refuseAfterSwallow(
                    reason: AXContextChecker.secureInputActiveReason,
                    swallowedUnicode: swallowedUnicode,
                    swallowedKeyCode: swallowedKeyCode,
                    swallowedFlags: swallowedFlags,
                    refuseContext: .capture(
                        reason: AXContextChecker.secureInputActiveReason,
                        decision: decision
                    )
                )
                return
            }
            if decision.shouldBlock {
                self.refuseAfterSwallow(
                    reason: decision.reason,
                    swallowedUnicode: swallowedUnicode,
                    swallowedKeyCode: swallowedKeyCode,
                    swallowedFlags: swallowedFlags,
                    refuseContext: .capture(reason: decision.reason, decision: decision)
                )
                return
            }
            if let armedFocusPID, currentPID != armedFocusPID {
                self.refuseAfterSwallow(
                    reason: "Focus moved — expand aborted",
                    swallowedUnicode: swallowedUnicode,
                    swallowedKeyCode: swallowedKeyCode,
                    swallowedFlags: swallowedFlags
                )
                return
            }

            // Consume is single-use so a second trigger cannot reuse the same stale text.
            // Same-element check (CFEqual) makes the longer TTL safe.
            let weakAXBlocked = SelectionMonitor.shared.hasWeakAXBlockedSelection()
            guard let selection = SelectionMonitor.shared.consumeSelection() else {
                self.refuseAfterSwallow(
                    reason: weakAXBlocked ? "AI selection weak-AX" : "AI selection unavailable",
                    swallowedUnicode: swallowedUnicode,
                    swallowedKeyCode: swallowedKeyCode,
                    swallowedFlags: swallowedFlags
                )
                let hintKey = weakAXBlocked
                    ? Self.aiWeakAXHintKey
                    : Self.aiSelectionUnavailableHintKey
                self.presentAITransformHint?(hintKey)
                return
            }

            guard self.presentAITransform != nil else {
                self.refuseAfterSwallow(
                    reason: "AI transform required but no presenter wired",
                    swallowedUnicode: swallowedUnicode,
                    swallowedKeyCode: swallowedKeyCode,
                    swallowedFlags: swallowedFlags
                )
                return
            }

            let restoreOnCancel: String? = {
                guard let expected = erasePlan.expectedText, !expected.isEmpty else { return nil }
                return expected
            }()

            EraseExecutor.shared.performGuardedErase(plan: erasePlan) { [weak self] erased in
                guard let self else { return }
                if !erased {
                    self.refuseAfterSwallow(
                        reason: "AI trigger erase failed",
                        swallowedUnicode: swallowedUnicode,
                        swallowedKeyCode: swallowedKeyCode,
                        swallowedFlags: swallowedFlags
                    )
                    return
                }
                // Expansion ends here — panel owns the rest. Do not hold `_isExpanding`.
                self.endExpansion()
                let sourceApp = NSWorkspace.shared.frontmostApplication
                let selectedText = selection.text
                let customInstructions: String? = {
                    guard kind == .custom else { return nil }
                    let body = snippet.replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
                    return body.isEmpty ? nil : body
                }()
                guard let presenter = self.presentAITransform else {
                    DevTypeLog.eventTap.error(
                        "[EventTap] AI transform presenter cleared after erase — trigger already removed"
                    )
                    return
                }
                presenter(selectedText, kind, sourceApp, customInstructions, restoreOnCancel)
            }
        }
    }

    /// Inject an AI transform result without erasing again (trigger erase already happened, or
    /// hotkey path replaces the live selection via paste). Always passes `erasePlan: .empty`
    /// and `secureClipboardPaste: true` — do not rely on `eraseCountOverride: 0` alone.
    public func injectAITransformResult(
        text: String,
        snippet: SnippetModel? = nil,
        sourceApp: NSRunningApplication? = nil,
        completion: (() -> Void)? = nil
    ) {
        let work = { [weak self] in
            if let sourceApp {
                sourceApp.activate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard self != nil else {
                    completion?()
                    return
                }
                let snapshot = PermissionCoordinator.shared.cachedSnapshot
                let shellLike = AXContextChecker.shared.isFrontmostShellLikeContext()
                let plan = InjectionPlanner().plan(
                    snapshot: snapshot,
                    isTerminal: shellLike,
                    needsCursorHID: false,
                    isMultiLine: text.contains(where: \.isNewline)
                )
                if case .refuse(let reason) = plan {
                    DevTypeLog.eventTap.notice(
                        "[EventTap] AI inject refused — \(reason, privacy: .public)"
                    )
                    completion?()
                    return
                }

                let carrier = snippet ?? SnippetModel(
                    title: "AI",
                    triggerKeyword: "",
                    replacementText: text
                )
                let suspension = EventTapEngine.shared.suspendMatching(reason: "aiTransformInject")
                TextInjectionPipeline.shared.inject(
                    snippet: carrier,
                    triggerLength: 0,
                    swallowedFinalKey: false,
                    plan: plan,
                    erasePlan: .empty,
                    preResolvedText: text,
                    secureClipboardPaste: true,
                    completion: {
                        suspension.release()
                        completion?()
                    }
                )
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func finishDeferredInject(
        snippet: SnippetModel,
        triggerUTF16Length: Int,
        lastEventUTF16Count: Int,
        swallowedUnicode: String,
        swallowedKeyCode: Int64,
        swallowedFlags: CGEventFlags,
        terminator: String,
        eraseCountOverride: Int?,
        erasePlan: ErasePlan,
        resolved: MacroExpansionResult,
        clipboardSnapshot: String?,
        quiescence: InputQuiescenceGuard,
        armedFocusPID: pid_t?,
        swallowedFinalKey: Bool = true,
        textSuffix: String = ""
    ) {
        if case .abort = inputClock.decide(quiescence) {
            refuseAfterSwallow(
                reason: "User input after arm — expand aborted",
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags
            )
            return
        }

        let mainProbe = Self.runOnMainSync { () -> (currentPID: pid_t?, shellLike: Bool) in
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let shellLike = AXContextChecker.shared.isFrontmostShellLikeContext()
            return (currentPID, shellLike)
        }

        if let armedFocusPID, mainProbe.currentPID != armedFocusPID {
            refuseAfterSwallow(
                reason: "Focus moved — expand aborted",
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags
            )
            return
        }

        let snapshot = PermissionCoordinator.shared.cachedSnapshot
        let shellLike = mainProbe.shellLike
        let needsCursor = InjectionPlanner.needsCursorHID(
            cursorOffset: resolved.cursorOffset,
            totalUTF16Length: resolved.text.utf16.count
        )
        let plan = InjectionPlanner().plan(
            snapshot: snapshot,
            isTerminal: shellLike,
            needsCursorHID: needsCursor,
            isMultiLine: resolved.text.contains(where: \.isNewline)
        )
        if case .refuse(let reason) = plan {
            refuseAfterSwallow(
                reason: reason,
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags
            )
            return
        }

        let lookup: (String) -> String? = { [weak self] trigger in
            guard let self else { return nil }
            return self.snippets.first {
                $0.triggerKeyword == trigger
                    || (!$0.isCaseSensitive && $0.triggerKeyword.lowercased() == trigger.lowercased())
            }?.replacementText
        }

        TextInjectionPipeline.shared.inject(
            snippet: snippet,
            triggerLength: triggerUTF16Length,
            clipboardOverride: clipboardSnapshot,
            swallowedFinalKey: swallowedFinalKey,
            lastEventCharacterCount: lastEventUTF16Count,
            plan: plan,
            swallowedUnicode: swallowedUnicode,
            swallowedKeyCode: swallowedKeyCode,
            swallowedFlags: swallowedFlags,
            terminator: terminator,
            eraseCountOverride: eraseCountOverride,
            erasePlan: erasePlan,
            preResolvedText: resolved.text + textSuffix,
            preResolvedCursorOffset: resolved.cursorOffset,
            trailingKeys: resolved.trailingKeys,
            snippetLookup: lookup
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.onExpansionSucceeded?(snippet)
            }
            self?.endExpansion()
        }
    }

    /// Records refuse and reinjects the swallowed key while `isExpanding` still suppresses rematch.
    private func refuseAfterSwallow(
        reason: String,
        swallowedUnicode: String,
        swallowedKeyCode: Int64,
        swallowedFlags: CGEventFlags,
        refuseContext: PermissionCoordinator.InjectRefuseProvenance? = nil
    ) {
        if Self.mustReinjectOnRefuse(didSwallow: true) {
            _ = TextInjectionPipeline.shared.reinjectSwallowedKey(
                unicode: swallowedUnicode,
                keyCode: swallowedKeyCode,
                flags: swallowedFlags
            )
        }
        DispatchQueue.main.async {
            PermissionCoordinator.shared.recordInjectOutcome(
                .refused(reason),
                refuseContext: refuseContext
            )
        }
        endExpansion()
    }

    /// Hop to main for AppKit/AX without nested `main.sync` when already on main.
    private static func runOnMainSync<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    /// Pure match via AbbreviationMatcher (+ optional physical Hangul fallback).
    ///
    /// §2.1: the normal path (`snippets == nil`) reads the matcher built once in the `snippets`
    /// setter. Only an explicit override builds a transient matcher, which is exactly what the
    /// old code did on **every keystroke**.
    public func findMatch(
        in bufferSnapshot: String,
        layout: LayoutBuffer = LayoutBuffer(),
        allowPhysicalFallback: Bool = false,
        snippets: [SnippetModel]? = nil
    ) -> SnippetMatch? {
        let state: SnippetMatchSnapshot
        if let snippets {
            state = SnippetMatchSnapshot(snippets: snippets)
        } else {
            state = matchSnapshot
        }
        return findMatch(
            characters: Array(bufferSnapshot),
            layout: layout,
            allowPhysicalFallback: allowPhysicalFallback,
            snapshot: state,
            bundleID: nil
        )
    }

    /// §2.3 / §4.4: allocation-lean match used by the tap callback.
    /// `bundleID` is the cached frontmost app; app-scoped snippets (`includeApps` /
    /// `excludeApps`) that do not apply to it are skipped by the matcher.
    public func findMatch(
        characters: [Character],
        layout: LayoutBuffer = LayoutBuffer(),
        allowPhysicalFallback: Bool = false,
        snapshot: SnippetMatchSnapshot,
        bundleID: String? = nil
    ) -> SnippetMatch? {
        guard let decision = LayoutAwareMatcher.decide(
            composedCharacters: characters,
            layout: layout,
            matcher: snapshot.matcher,
            allowPhysicalFallback: allowPhysicalFallback,
            bundleID: bundleID
        ) else {
            return nil
        }
        let source: SnippetMatch.Source = decision.source == .physical ? .physical : .composed
        let erase: Int
        if decision.source == .physical {
            // Grapheme count from LayoutAwareMatcher — no text to verify against.
            erase = decision.backspaces
        } else {
            // Terminator (when present) is swallowed separately — erase the trigger only.
            // Measure the text the user actually typed, not the stored keyword: they can differ in
            // casing, and for astral characters they can differ in UTF-16 length too.
            erase = (decision.fieldText ?? decision.match.snippet.triggerKeyword).utf16.count
        }
        return SnippetMatch(
            snippet: decision.match.snippet,
            triggerLength: decision.match.triggerLength,
            terminator: decision.terminator,
            source: source,
            eraseCount: erase,
            fieldText: decision.fieldText
        )
    }

    /// Pure match check for tests and callers that only need a Bool. Does not inject.
    public func evaluateMatch(bufferSnapshot: String) -> Bool {
        findMatch(in: bufferSnapshot) != nil
    }

    /// Atomically claims the inject+restore critical section. Cleared only by `endExpansion`
    /// after inject completes.
    ///
    /// Test-and-set rather than a blind set: the immediate-match path and a held expansion's
    /// debounce timer can both decide to expand in the same instant (the tap thread's
    /// `expanding` check at callback entry ran before matching). Exactly one caller wins the
    /// claim; the loser must stand down instead of writing into the field a second time.
    private func tryBeginExpansion() -> Bool {
        // Read the frontmost context *before* taking `lock` — it has its own lock, and acquiring
        // the two in this order here but the reverse anywhere else is a deadlock.
        let focusPID = frontmostContext.processID
        lock.lock()
        guard !_isExpanding else {
            lock.unlock()
            return false
        }
        _isExpanding = true
        // §8.3: from here until `endExpansion`, keys the user types are held rather than passed
        // through, so they cannot overtake the paste still in flight.
        _typeAhead.beginExpansion(focusPID: focusPID)
        lock.unlock()
        return true
    }

    private func endExpansion() {
        lock.lock()
        _isExpanding = false
        let replay = _typeAhead.endExpansion()
        ringBuffer.removeAll()
        layoutBuffer.clear()
        lastEventUTF16Count = 1
        lock.unlock()
        // §8.3: outside the lock — replaying posts HID events, and the tap callback for those
        // events takes this same lock.
        replayTypeAhead(replay, reason: "expansion complete")
    }

    /// Decides one keystroke against the type-ahead hold. Runs on the tap thread, so it reads the
    /// event directly and never touches AppKit.
    private func admitTypeAhead(event: CGEvent) -> TypeAheadBuffer.Decision {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let resets = Self.shouldResetBuffer(flags: flags, keyCode: keyCode)

        var unicode = ""
        var length = 0
        withUnsafeTemporaryAllocation(
            of: UniChar.self,
            capacity: EventTapEngine.unicodeScratchCapacity
        ) { scratch in
            event.keyboardGetUnicodeString(
                maxStringLength: EventTapEngine.unicodeScratchCapacity,
                actualStringLength: &length,
                unicodeString: scratch.baseAddress
            )
            if length > 0 {
                unicode = String(utf16CodeUnits: scratch.baseAddress!, count: length)
            }
        }

        let focusPID = frontmostContext.processID
        lock.lock()
        let decision = _typeAhead.admit(
            unicode: unicode,
            isSynthetic: false,
            resetsBuffer: resets,
            focusPID: focusPID
        )
        lock.unlock()
        return decision
    }

    /// Re-posts keystrokes held during an expansion, in the order they were typed.
    ///
    /// The queue's invariant is that everything admitted is replayed exactly once, so this is the
    /// only exit and it must not be conditional on anything that could silently skip it.
    private func replayTypeAhead(_ text: String, reason: String) {
        guard !text.isEmpty else { return }
        // The tap source runs on the main run loop, so a flush from the tap callback lands here
        // already on main and posts *inline* — deliberately. That is what puts the replayed
        // characters ahead of the key that caused the flush, which is the order the user typed
        // them in. Hopping to main unconditionally would post them after it and reintroduce the
        // very transposition this type exists to prevent. The hop below is only for completion
        // callbacks arriving off-main.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.replayTypeAhead(text, reason: reason)
            }
            return
        }
        DevTypeLog.inject.notice(
            """
            [TypeAhead] replaying \(text.count, privacy: .public) held keystroke(s) — \
            reason=\(reason, privacy: .public)
            """
        )
        InjectTelemetryLog.shared.recordTypeAheadReplay(
            bundleID: cachedFrontmostBundleID,
            characters: text.count
        )
        // §3.1: replayed characters are user input landing *after* the recorded expansion (the
        // record is written before the "expansion complete" replay fires), but they are posted
        // synthetically so the tap's counter hook never sees them. Count them here or a blind
        // undo would under-count what sits between the injected text and the caret. Replays that
        // fire before a record exists are a harmless no-op.
        TextInjectionPipeline.shared.noteInputAfterExpansion(units: text.count)
        // HID only — deliberately *not* `attemptAXDirectInjection`. That call reports success
        // without writing in the whole Chromium/Electron false-success class, which is exactly
        // where this bug occurs, so an AX replay would silently eat the user's keystrokes: the
        // one outcome this design must never produce. A posted key can be dropped by the system,
        // but it is never a lie.
        for character in text {
            _ = TextInjectionPipeline.shared.postUnicodeKeyEvent(
                unicode: String(character),
                keyCode: 0,
                flags: []
            )
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Caps Lock (keycode 57) toggles often imply caret/context change — reset.
        if keyCode == 57 {
            resetBuffer()
        }
    }

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

    /// §2.3: `TISCopyCurrentKeyboardInputSource` + a CFString bridge, once per input-source
    /// change instead of once per keystroke (it was only being used to test a constant).
    private func refreshInputSourceCache() {
        let allow = isTwoSetKoreanSourceID(EventTapEngine.currentInputSourceID())
        contextLock.lock()
        _allowPhysicalFallback = allow
        contextLock.unlock()
    }

    private func installMuteListObserver() {
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

    private func installAppSwitchObserver() {
        guard appSwitchObserver == nil else { return }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
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
                // Memoized per pid (one AX round-trip per process lifetime; non-Chromium apps
                // answer once with "unsupported"), and dispatched off this notification thread
                // so the tap never waits on AX IPC.
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

    private func removeAppSwitchObserver() {
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    private func installInputSourceObserver() {
        guard inputSourceObserver == nil else { return }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // §2.3: recompute the physical-fallback flag here, not per keystroke.
            self?.refreshInputSourceCache()
            self?.resetBuffer()
        }
    }

    private func removeInputSourceObserver() {
        if let observer = inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            inputSourceObserver = nil
        }
    }

}
