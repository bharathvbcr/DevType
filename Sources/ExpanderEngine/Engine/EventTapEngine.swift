import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

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

    let tapThread = TapRunLoopThread()

    /// §1.11: `eventTapPort` / `runLoopSource` were mutated by `start`/`stop` and read by
    /// `reEnableTap()` (from the callback) and `checkTapHealth()` (main timer) with no lock at
    /// all, in a class where everything else is locked. Once §1.1 moves the callback off main
    /// that is a live data race, so they now sit behind their own lock.
    let tapLock = UnfairLock()
    var _eventTapPort: CFMachPort?
    var _runLoopSource: CFRunLoopSource?
    var _tapRunLoop: CFRunLoop?

    let processingQueue = DispatchQueue(label: "com.devtype.eventprocessing", qos: .userInteractive)

    // MARK: - Buffer / flags

    /// §2.4: `os_unfair_lock` (via `UnfairLock`) rather than `NSLock` — `NSLock` does not donate
    /// priority, so the userInteractive tap callback could block behind a utility-QoS file-watch
    /// thread holding this lock in the `snippets` setter.
    let lock = UnfairLock()
    /// Prefix-debounce state. Owns its own lock and serializes every hold transition — see
    /// `HeldExpansionCoordinator` for the interleavings this closes. Lock ordering: paths may
    /// take `lock` then the coordinator's lock (never nested the other way — the coordinator
    /// never calls out), so the pair cannot deadlock.
    let heldCoordinator = HeldExpansionCoordinator<HeldPayload>()
    /// §2.3: a real fixed-capacity ring. The old "ring buffer" was an `Array` plus
    /// `removeFirst(...)` — an O(n) memmove on every keystroke at steady state.
    var ringBuffer = CharacterRingBuffer(capacity: EventTapEngine.maxBufferCapacity)
    var layoutBuffer = LayoutBuffer()
    /// §3.9: longest trigger the buffer can hold. Anything longer can never fire —
    /// see `overlongTriggerDiagnostics()`.
    public static let maxBufferCapacity = 64
    /// UTF-16 units fetched per keyDown. Stack scratch, not a heap allocation (§2.3).
    static let unicodeScratchCapacity = 128
    /// UTF-16 length of the most recent keyDown that appended to the buffer (for AX erase math).
    var lastEventUTF16Count: Int = 1

    var _isEnabled: Bool = true
    var _isTapRunning: Bool = false
    /// Latched by the first `start()`, never cleared: the question it answers is "has this
    /// process ever asked?", and a later stop does not make the answer no again.
    var _hasAttemptedTapStart: Bool = false
    var _isExpanding: Bool = false
    /// §8.3: keystrokes typed while an expansion is in flight, held so they cannot land ahead of
    /// the paste. Guarded by `lock` — mutated from the tap callback and from `endExpansion`.
    var _typeAhead = TypeAheadBuffer()
    /// True from the moment `endExpansion` seeds the ring with replayed type-ahead until the last
    /// of those characters has been posted. A real key in that gap lands in the field before or
    /// after them, and the buffer cannot know which, so such a key bypasses matching instead.
    /// Guarded by `lock`.
    var _replayInFlight = false
    /// Nested suspend depth (fill-in + inline search / AI panels). Matching is skipped while > 0.
    var _matchingSuspendCount: Int = 0
    /// Live suspension owners, newest last, for `matchingSuspensionDiagnostics()`. A leaked
    /// suspension is invisible in every other counter — the tap still runs, the engine is still
    /// enabled, permissions are still granted, and not one snippet expands.
    var _matchingSuspendOwners: [(id: UUID?, reason: String, since: Date)] = []
    var _isSecureInputActive: Bool = false

    // MARK: - §2.1 cached matcher

    /// §2.1 / §2.4: read-mostly `(snippets, matcher)` state, swapped as one immutable reference.
    /// The callback copies a single class pointer out from under this lock and never rebuilds
    /// anything — the matcher used to be reconstructed from scratch on *every keystroke*.
    let matchStateLock = UnfairLock()
    var _matchSnapshot: SnippetMatchSnapshot = .empty
    var _snapshotRevision: UInt64 = 0
    /// Serializes matcher builds started on the main thread. The `snippets` setter stays
    /// synchronous; only `applySnippetSnapshot` hops, and only when the caller is main.
    let snapshotQueue = DispatchQueue(label: "com.devtype.snippet-snapshot", qos: .userInitiated)
    var _lastSnippetSnapshotBuiltOnMain = false

    /// The library **before** secrets are filtered out, for diagnostics only — see
    /// `silentNoExpandDiagnostics()`. Never read by the matcher or the keystroke path.
    let libraryLock = UnfairLock()
    var _fullLibrary: [SnippetModel] = []

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

    let contextLock = UnfairLock()
    var _frontmostContext = FrontmostContext()
    /// Cached `KeyboardLayoutState.shared.snapshot().isTwoSetKorean`. The tap used to call
    /// `TISCopyCurrentKeyboardInputSource` + a CFString bridge per key just to test a constant.
    var _allowPhysicalFallback = false
    var muteObserverInstalled = false

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

    let counterLock = UnfairLock()
    var _tapDisableCounters = TapDisableCounters()
    var _recentTimeoutStamps: [Date] = []
    var _nextReinstallAllowedAt: Date?
    var _reinstallBackoff: TimeInterval = EventTapEngine.tapReinstallInitialBackoff

    /// §2.10: public so `DiagnosticReport` can print them.
    public var tapDisableCounters: TapDisableCounters {
        counterLock.withLock { _tapDisableCounters }
    }

    /// Event-time quiescence clock (boot nanos via CGEvent.timestamp).
    public let inputClock = InputClock()

    var appSwitchObserver: NSObjectProtocol?
    var layoutListener: UUID?
    var healthTimer: DispatchSourceTimer?
    /// How often to probe `CGEvent.tapIsEnabled` for silent inert taps (macOS TCC/re-sign class).
    let healthCheckInterval: TimeInterval = 2.0
    /// Kernel coalescing window for the health timer. The permission poll uses its own timer:
    /// a fully capable process can still lose the event tap, so the health check must keep
    /// running when the permission poll backs off.
    public static let healthCheckLeeway: DispatchTimeInterval = .milliseconds(500)

    /// Invoked on the main queue when health monitor clears / reinstalls a dead tap.
    public var onTapHealthChanged: (() -> Void)?

    /// Called on the main queue after a snippet expansion inject completes successfully.
    public var onExpansionSucceeded: ((SnippetModel) -> Void)?

    /// Fires once when a phrase reaches `TypedRepetitionDetector.repeatThreshold`, so the app
    /// can offer to turn it into a snippet. Never fires unless the user switched the feature on
    /// *and* confirmed the consent prompt.
    public var onRepetitionNoticed: ((TypedRepetitionDetector.Candidate) -> Void)?

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

    /// Localization key when the snippet's transform is `.custom` but its body — which *is* the
    /// instruction set for `.custom` — is blank.
    public static let aiCustomInstructionsMissingHintKey = "ai.typed.customInstructionsMissing"

    /// Titles paired with the hints above. A missing-instructions refusal is not a selection
    /// problem, and telling the user "No Selection" when their selection was fine sends them
    /// looking in the wrong place.
    public static let aiSelectionHintTitleKey = "ai.alert.noSelection.title"
    public static let aiRefusedHintTitleKey = "ai.alert.failed.title"

    /// Typed AI path: refused before anything was erased. Invoked on the main queue with a
    /// title key and a message key (see the `ai.typed.*` keys above).
    public var presentAITransformHint: ((_ titleKey: String, _ messageKey: String) -> Void)?

    /// Keycodes that desync the ring buffer. Return/Tab intentionally omitted — DevType may
    /// treat them as terminators and swallow (unlike SnipKey listenOnly clearBuffer).
    public static let bufferResetKeyCodes: Set<Int64> = [
        53, 115, 116, 117, 119, 121, 123, 124, 125, 126
    ]

    static let mouseDownTypes: Set<CGEventType> = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown
    ]

    /// Posts one replayed type-ahead character. Injectable so a test can observe the replay
    /// without sending keystrokes to the machine it runs on; production always uses the HID poster.
    var typeAheadReplayPoster: (String) -> Void = { character in
        _ = HIDKeyPoster.shared.postUnicodeKeyEvent(unicode: character, keyCode: 0, flags: [])
    }

    /// Puts the swallowed terminator back when the type-ahead hold surrenders before the
    /// expansion wrote anything. Injectable for the same reason as `typeAheadReplayPoster`.
    /// Production posts it as the key it was (code and flags, with the AX-insert fallback that
    /// `reinjectSwallowedKey` carries); the pipeline's ledger has already settled the debt by the
    /// time this runs, so it posts through `repostSettledKey`, not the debt-checked entry.
    var swallowedKeyPoster: (SwallowedKey) -> Void = { key in
        _ = TextInjectionPipeline.shared.repostSettledKey(key)
    }

    /// The non-IPC Secure Input read the tap trusts over its polled flag. Injectable so a test can
    /// stage "the flag says secure, the system says otherwise" without owning the real state.
    var liveSecureInputProbe: () -> Bool = { AXContextChecker.isSecureEventInputEnabledLive() }

    let matchDropLock = UnfairLock()
    var _matchDrops = MatchDropCounters()

    let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let engine = Unmanaged<EventTapEngine>.fromOpaque(refcon).takeUnretainedValue()
        // §1.1: this now runs on `TapRunLoopThread`, which (unlike the main run loop) does not
        // wrap each source callout in an autorelease pool of its own.
        return autoreleasepool { () -> Unmanaged<CGEvent>? in
            engine.handleTapEvent(type: type, event: event)
        }
    }

    public init() {
        let paused = UserDefaults.standard.bool(forKey: ProcessIdentity.userPausedDefaultsKey)
        _isEnabled = !paused
        installAppSwitchObserver()
        installInputSourceObserver()
        installMuteListObserver()
        refreshInputSourceCache()
        KeyboardLayoutState.shared.refreshOnMain()
        primeFrontmostContext()
    }

    deinit {
        removeAppSwitchObserver()
        removeInputSourceObserver()
        // §1.1: the worker parks in `CFRunLoopRun()` and keeps itself alive; without this a
        // discarded engine (tests) would leak a running thread.
        tapThread.shutdown()
    }
}
