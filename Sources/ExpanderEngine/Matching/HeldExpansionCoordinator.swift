import Foundation

/// Serializes every lifecycle transition of at most one held (prefix-debounced) expansion.
///
/// The hold is written to by three parties on three different threads:
///
///   * the tap thread, advancing the hold one keystroke at a time,
///   * the debounce timer on the main queue, firing a hold the user stopped typing after,
///   * cancel paths (buffer resets, stale expiry, a longer trigger winning).
///
/// The engine used to keep this state in two fields guarded by its hot-path lock, but the
/// *decision* about a keystroke was computed outside the lock: read the hold, unlock, call
/// `HeldExpansionState.advance`, then re-store the result. In the gap the debounce timer could
/// claim and expand the hold — and the keystroke path would then re-arm a hold whose trigger was
/// already expanded and erased, leaving a ghost record that could fire a second expansion later.
/// That interleaving needs exactly one collision: the first extension keystroke landing on the
/// debounce deadline.
///
/// This type closes the gap by making each transition a single critical section:
///
///   * `resolveKeystroke` computes the advance **and** applies it under one lock hold, so a
///     concurrent timer either runs before it (keystroke then sees no hold) or after it
///     (the generation moved, so the timer's claim is refused).
///   * `claimForTimeout` is compare-and-swap on the generation: only the newest hold can fire,
///     and only while nothing has been typed after its trigger.
///   * Every transition that consumes the hold bumps the generation, so a timer armed against
///     any earlier incarnation can never touch the new one.
///
/// The invariant the tests hammer: **each armed generation is consumed at most once** — by one
/// fire or one cancel, never both, never twice.
///
/// `advance` itself stays a pure value computation (`HeldExpansionState`), cheap enough to run
/// under an `os_unfair_lock` on the keystroke path. The coordinator never calls out while
/// holding its lock, so it cannot participate in a lock-ordering cycle with the engine.
public final class HeldExpansionCoordinator<Payload> {

    /// One armed hold. `payload` carries whatever the caller needs to perform the expansion
    /// (the engine stores its `SnippetMatch`); the coordinator never looks inside it.
    public struct Hold {
        public let payload: Payload
        public let state: HeldExpansionState
        public let focusPID: pid_t?
        /// CAS token: timers fire against the generation they were armed for, and any
        /// transition that touches the hold moves it.
        public let generation: UInt64
    }

    public enum CancelReason: String, Sendable {
        /// Backspace, a caret-moving key, or Return/Tab (which may have *submitted* the field).
        case editOrCaretMove
        /// Buffer reset — mouse click, chorded key, escape, app-level reset.
        case bufferReset
        /// A longer trigger completed and expands normally; the shorter hold must not also fire.
        case longerTriggerWon
        /// A hold with no firing timer outlived `heldExpansionStaleTimeout`.
        case stale
        /// Input reached the field that the hold could not observe (key autorepeat, keystrokes
        /// passing through while matching is disabled/suspended or Secure Input is active). The
        /// held erase is counted from *observed* keystrokes, so unobserved input breaks its
        /// integrity — the only safe resolution is to drop the hold.
        case unobservedInput
    }

    /// What one keystroke did to the hold. The caller performs side effects (scheduling,
    /// expanding, logging) *after* the transition has already been applied atomically.
    public enum KeystrokeOutcome {
        case noHold
        case cancelled(CancelReason)
        /// The user is still typing toward a longer trigger. The previous generation's timers
        /// are dead; schedule a stale-expiry cancel for `Hold.generation`.
        case rearmed(Hold)
        /// No longer trigger can follow. The hold has been claimed — expand it, erasing
        /// `Hold.state.trigger` + `suffix` and re-appending `suffix` after the expansion.
        case fire(Hold, suffix: String)
    }

    /// Counters for the diagnostic report. `racesAbsorbed` is the interesting one: each count
    /// is a timer that arrived against a hold the keystroke path had already moved — exactly
    /// the interleaving that used to double-fire.
    public struct Telemetry: Equatable, Sendable {
        public var armed = 0
        /// Re-arms while typing toward a longer trigger — each one is a debounce timer reset.
        public var extended = 0
        public var firedByTimeout = 0
        public var firedByKeystroke = 0
        public var cancelledByEdit = 0
        public var cancelledByReset = 0
        /// A longer trigger completed and expanded normally; the shorter hold stood down.
        /// This is the debounce *working* — kept separate from `cancelledByReset` so a field
        /// report can tell a successful longer-trigger expansion from a mouse click.
        public var cancelledLongerWon = 0
        public var expiredStale = 0
        /// Holds dropped because input the hold could not observe reached the field.
        public var cancelledUnobserved = 0
        /// Timeout claims refused by the generation CAS.
        public var racesAbsorbed = 0

        public init() {}

        public var summaryLine: String {
            "Prefix debounce: armed=\(armed) extended=\(extended)"
                + " fired(timeout=\(firedByTimeout) keystroke=\(firedByKeystroke))"
                + " cancelled(edit=\(cancelledByEdit) reset=\(cancelledByReset)"
                + " longer-won=\(cancelledLongerWon)"
                + " stale=\(expiredStale) unobserved=\(cancelledUnobserved))"
                + " races-absorbed=\(racesAbsorbed)"
        }
    }

    private let lock = UnfairLock()
    private var _hold: Hold?
    private var _generation: UInt64 = 0
    private var _telemetry = Telemetry()

    public init() {}

    /// Arms a fresh hold, replacing any existing one. Returns the hold so the caller can
    /// schedule the debounce timer against its generation.
    @discardableResult
    public func arm(payload: Payload, trigger: String, focusPID: pid_t?) -> Hold {
        lock.lock()
        _generation &+= 1
        let hold = Hold(
            payload: payload,
            state: HeldExpansionState(trigger: trigger),
            focusPID: focusPID,
            generation: _generation
        )
        _hold = hold
        _telemetry.armed += 1
        lock.unlock()
        return hold
    }

    /// Advances the hold by one keystroke — decision and mutation in one critical section.
    ///
    /// `typedNow` is what this keystroke put in the field, taken from the event itself (see
    /// `HeldExpansionState` for why a ring-buffer delta cannot substitute).
    public func resolveKeystroke(
        typedNow: String,
        isDelete: Bool,
        prefixIndex: TriggerPrefixIndex
    ) -> KeystrokeOutcome {
        lock.lock()
        guard let hold = _hold else {
            lock.unlock()
            return .noHold
        }
        switch hold.state.advance(typedNow: typedNow, isDelete: isDelete, prefixIndex: prefixIndex) {
        case .cancel:
            _hold = nil
            _generation &+= 1
            _telemetry.cancelledByEdit += 1
            lock.unlock()
            return .cancelled(.editOrCaretMove)

        case .keepWaiting(let next):
            _generation &+= 1
            let rearmed = Hold(
                payload: hold.payload,
                state: next,
                focusPID: hold.focusPID,
                generation: _generation
            )
            _hold = rearmed
            _telemetry.extended += 1
            lock.unlock()
            return .rearmed(rearmed)

        case .fire(let suffix):
            _hold = nil
            _generation &+= 1
            _telemetry.firedByKeystroke += 1
            lock.unlock()
            return .fire(hold, suffix: suffix)
        }
    }

    /// Claims the hold for the debounce timeout. Succeeds only if `generation` still names the
    /// live hold **and** nothing has been typed after its trigger — otherwise the timer lost a
    /// race the coordinator has already resolved, and the claim is refused.
    public func claimForTimeout(generation: UInt64) -> Hold? {
        lock.lock()
        guard let hold = _hold, hold.generation == generation, hold.state.mayFireOnTimeout else {
            if _hold != nil {
                _telemetry.racesAbsorbed += 1
            }
            lock.unlock()
            return nil
        }
        _hold = nil
        _generation &+= 1
        _telemetry.firedByTimeout += 1
        lock.unlock()
        return hold
    }

    /// Cancels the hold only if `generation` still names it (stale-expiry path).
    /// Returns whether anything was cancelled.
    @discardableResult
    public func cancel(generation: UInt64, reason: CancelReason) -> Bool {
        lock.lock()
        guard let hold = _hold, hold.generation == generation else {
            lock.unlock()
            return false
        }
        _hold = nil
        _generation &+= 1
        recordCancel(reason)
        lock.unlock()
        return true
    }

    /// Unconditionally drops any hold. Returns whether one existed.
    @discardableResult
    public func cancelAll(reason: CancelReason) -> Bool {
        lock.lock()
        let existed = _hold != nil
        _hold = nil
        _generation &+= 1
        if existed { recordCancel(reason) }
        lock.unlock()
        return existed
    }

    /// Must only be called with `lock` held.
    private func recordCancel(_ reason: CancelReason) {
        switch reason {
        case .editOrCaretMove: _telemetry.cancelledByEdit += 1
        case .bufferReset: _telemetry.cancelledByReset += 1
        case .longerTriggerWon: _telemetry.cancelledLongerWon += 1
        case .stale: _telemetry.expiredStale += 1
        case .unobservedInput: _telemetry.cancelledUnobserved += 1
        }
    }

    public var telemetry: Telemetry {
        lock.withLock { _telemetry }
    }

    public var hasHold: Bool {
        lock.withLock { _hold != nil }
    }

    /// Test hook: the live hold's generation, or nil.
    public var currentHoldGeneration: UInt64? {
        lock.withLock { _hold?.generation }
    }
}
