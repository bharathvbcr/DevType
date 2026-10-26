import Foundation

extension TextInjectionPipeline {

    /// §2.4 + §3.1: the one owner of the state an inject and an undo must agree on, and the one
    /// lock that guards it.
    ///
    /// Everything here changes together. The undo record and its target, the counters that decide
    /// whether a blind undo is still honest, the input revision every queued step compares
    /// against, and the operation that is allowed to finish. Each method is exactly one critical
    /// section: the pairs that must not be split — invalidate the old record *and* claim the new
    /// operation, check the record *and* consume it, store the record *and* drain the delivery
    /// count into it — never come apart, because no caller can reach this state outside a
    /// method. `os_unfair_lock`, taken from the event tap thread, the inject queue and main.
    final class ExpansionLedger {

        private let lock = UnfairLock()
        private let defaults: UserDefaults
        private var lastExpansion: LastExpansion?
        private var target: PasteboardBroker.PasteTarget?
        private var undoGeneration: UInt64 = 0
        /// §3.1: input events (real keystrokes and type-ahead replays) that landed after the
        /// recorded expansion. When the field is AX-opaque, this is the only evidence about
        /// whether the caret still sits right after `injectedText` — a blind undo is permitted
        /// only at zero. Reset when a record is stored.
        private var inputEventsSinceExpansion = 0
        /// §3.1d: real input the tap observed *while an expansion was being delivered* — keys
        /// whose ordering relative to the paste could not be honoured and therefore passed
        /// straight through (`TypeAheadBuffer` flushes rather than queues them), and clicks,
        /// which bypass key events entirely. Such input reaches the field at an unknowable point
        /// around the paste, so the "caret sits right after `injectedText`" premise the new
        /// record would rest on is already broken when the record is written. The counter opens
        /// with `beginDeliveryWindow()` and is drained into `inputEventsSinceExpansion` by
        /// `record(_:target:)`, which used to reset that count to zero and silently forgive
        /// exactly these keys — the shape behind "backspace after an expansion mis-erases in
        /// AX-opaque apps": backspace #1 passes through mid-delivery and deletes one character of
        /// the arriving expansion, backspace #2 then triggers a blind erase computed from a caret
        /// that sits one unit left of where the record believes it does.
        private var deliveryInputUnits = 0
        private var inputRevision: UInt64 = 0
        private var activeOperation: InjectCompletionGuard?

        /// The trigger's final key, which the tap ate on this delivery's behalf: owed back to the
        /// field exactly once, by whichever path gets there first.
        private enum TerminatorDebt {
            case none
            case owed(SwallowedKey)
            case settled(SwallowedKey)
        }

        /// §8.3 hold surrender, per delivery window (`beginDeliveryWindow` … `endDeliveryWindow`).
        ///
        /// The type-ahead hold gives up on its first real key past the deadline, and the key (or the
        /// keys it flushes) reaches the field before whatever the expansion has yet to write. If
        /// the expansion has not yet mutated the field, that is harmless to give up on: nothing
        /// was erased, so the right answer is to abandon it and put the user's own keystrokes back
        /// in the order they were typed, terminator first. Once it *has* begun mutating, the
        /// terminator's place is no longer defined and the old behaviour stands. Those two
        /// outcomes race — the pipeline on main, the tap thread — so they are one test-and-set
        /// each under this lock: `beginMutation` and `surrenderHold` can never both win.
        private var deliveryMutated = false
        private var deliverySurrendered = false
        private var terminatorDebt = TerminatorDebt.none

        init(defaults: UserDefaults) {
            self.defaults = defaults
        }

        // MARK: Undo switch

        /// Enabled by default for existing installations. Disabling consumes every outstanding
        /// record and invalidates queued undo, including when the switch is re-enabled
        /// immediately.
        var undoEnabled: Bool {
            get { lock.withLock { undoEnabledLocked } }
            set {
                lock.withLock {
                    defaults.set(newValue, forKey: TextInjectionPipeline.expansionUndoEnabledDefaultsKey)
                    invalidateUndoLocked()
                }
            }
        }

        private var undoEnabledLocked: Bool {
            defaults.object(forKey: TextInjectionPipeline.expansionUndoEnabledDefaultsKey) == nil
                || defaults.bool(forKey: TextInjectionPipeline.expansionUndoEnabledDefaultsKey)
        }

        // MARK: Operations

        /// Makes `operation` the one allowed to finish and returns the input revision it must
        /// still match. The previous operation is cancelled in the same critical section, and an
        /// expansion (not an undo) consumes any outstanding record — so no window exists in which
        /// two operations are current, or a stale record survives into the new inject.
        func claim(_ operation: InjectCompletionGuard, consumingUndo: Bool) -> UInt64 {
            lock.withLock {
                if consumingUndo { invalidateUndoLocked() }
                activeOperation?.cancel()
                activeOperation = operation
                // A hold that surrendered before this inject existed (the gap between the tap's
                // claim and the pipeline's is a focus query and a render long) has already put
                // the user's keys back; this operation must not run over them.
                if deliverySurrendered { operation.cancel() }
                return inputRevision
            }
        }

        /// Whether `operation` is still the current one and no input has landed since `revision`.
        func isCurrent(_ operation: InjectCompletionGuard, revision: UInt64) -> Bool {
            lock.withLock { activeOperation === operation && inputRevision == revision }
        }

        /// Invalidates queued work as well as callbacks already scheduled on main.
        func cancelCurrent() {
            lock.withLock {
                invalidateUndoLocked()
                activeOperation?.cancel()
                activeOperation = nil
            }
        }

        // MARK: Input

        /// §3.1: input landed in the field after the recorded expansion. Cheap no-op for the
        /// count while no record exists, so the tap's hot path can call it unconditionally.
        func noteInputAfterExpansion(units: Int) {
            guard units > 0 else { return }
            lock.withLock {
                inputRevision &+= 1
                if lastExpansion != nil {
                    inputEventsSinceExpansion = Saturating.adding(inputEventsSinceExpansion, units)
                }
            }
        }

        /// §3.1d: opens the delivery-input window for one expansion.
        func beginDeliveryWindow() {
            lock.withLock {
                deliveryInputUnits = 0
                deliveryMutated = false
                deliverySurrendered = false
                terminatorDebt = .none
            }
        }

        /// Closes the window `beginDeliveryWindow` opened, on every path that ends the expansion,
        /// so a surrender recorded for this delivery cannot suppress a later, unrelated key
        /// replay (an undo's held backspace, for one).
        func endDeliveryWindow() {
            lock.withLock {
                deliveryMutated = false
                deliverySurrendered = false
                terminatorDebt = .none
            }
        }

        /// The tap swallowed `key` for the delivery whose window is open. Owed back once.
        func oweTerminator(_ key: SwallowedKey) {
            lock.withLock { terminatorDebt = .owed(key) }
        }

        /// Called by every path that is about to post the swallowed key back. `true` means the
        /// caller may post it (and, if it was the owed key, now has the debt); `false` means a
        /// hold surrender already put it back, so posting again would type it twice. A key that
        /// was never owed (an undo's held backspace) is not this ledger's to withhold.
        func consumeTerminator(matching key: SwallowedKey) -> Bool {
            lock.withLock {
                switch terminatorDebt {
                case .owed(let owed) where owed == key:
                    terminatorDebt = .settled(owed)
                    return true
                case .settled(let settled) where settled == key:
                    return false
                default:
                    return true
                }
            }
        }

        /// The pipeline is about to write to the field (an AX range replace or the first
        /// backspace). `false` when the operation is no longer the one allowed to, input has
        /// landed since its revision, or the hold has already surrendered — in all three the
        /// caller must not mutate. Winning is what stops a later `surrenderHold` from abandoning
        /// the inject: the two cannot both succeed.
        func beginMutation(_ operation: InjectCompletionGuard, revision: UInt64) -> Bool {
            lock.withLock {
                guard !deliverySurrendered, activeOperation === operation,
                      inputRevision == revision else { return false }
                deliveryMutated = true
                return true
            }
        }

        /// `beginMutation` for a mutation that owns no claimed operation (the typed AI
        /// transform's trigger erase): only the surrender can refuse it.
        func beginUnclaimedMutation() -> Bool {
            lock.withLock {
                guard !deliverySurrendered else { return false }
                deliveryMutated = true
                return true
            }
        }

        /// What the tap does about a hold giving up.
        enum HoldSurrender: Equatable {
            /// The expansion is already mutating the field; the old behaviour stands.
            case mutationBegun
            /// The in-flight inject is cancelled before it wrote anything. `replay` is the
            /// terminator it owed the field, to post ahead of the held keys; `nil` when none was
            /// swallowed or it was already put back.
            case abandoned(replay: SwallowedKey?)
        }

        /// The type-ahead hold surrendered. Atomic with `beginMutation`; when the surrender
        /// wins, the revision moves so every queued continue-check of the in-flight inject
        /// refuses, and the owed terminator is handed to the caller exactly once.
        func surrenderHold() -> HoldSurrender {
            lock.withLock {
                guard !deliveryMutated else { return .mutationBegun }
                deliverySurrendered = true
                inputRevision &+= 1
                guard case .owed(let key) = terminatorDebt else { return .abandoned(replay: nil) }
                terminatorDebt = .settled(key)
                return .abandoned(replay: key.hasPayload ? key : nil)
            }
        }

        /// A key reached the field mid-delivery that no unit count can describe (a dead key, an
        /// F-key: no character, no caret move the tap can name). It still may have edited the
        /// field, so the erase must not run over it, but it is not typed text and must not cost
        /// the undo record: the revision moves, the counters do not.
        func noteUncountedDeliveryKey() {
            lock.withLock { inputRevision &+= 1 }
        }

        /// §3.1d: one real, field-touching event was observed while an expansion is being
        /// delivered. See `deliveryInputUnits` for why this must poison the record's blind-undo
        /// premise.
        func noteDeliveryInput(units: Int) {
            guard units > 0 else { return }
            lock.withLock {
                deliveryInputUnits = Saturating.adding(deliveryInputUnits, units)
                inputRevision &+= 1
            }
        }

        var currentDeliveryInputUnits: Int {
            lock.withLock { deliveryInputUnits }
        }

        func deliveryInputUnits(equal units: Int) -> Bool {
            lock.withLock { deliveryInputUnits == units }
        }

        // MARK: Undo record

        var record: LastExpansion? {
            lock.withLock { lastExpansion }
        }

        func canUndo(now: Date, frontmostPID: pid_t?) -> Bool {
            lock.withLock {
                // Record first: it is almost always nil, and the setting costs two defaults reads.
                lastExpansion?.isFresh(now: now) == true && undoEnabledLocked
                    && target?.pid == frontmostPID && frontmostPID != nil
            }
        }

        /// Stores the undo point for a delivered expansion and drains the delivery-window count
        /// into it. Any earlier record is consumed first, whether or not this one is kept.
        func record(_ record: LastExpansion, target: PasteboardBroker.PasteTarget) {
            lock.withLock {
                invalidateUndoLocked()
                guard undoEnabledLocked, let pid = target.pid, pid > 0,
                      !record.injectedText.isEmpty, !record.triggerText.isEmpty else { return }
                lastExpansion = record
                self.target = target
                inputEventsSinceExpansion = max(0, deliveryInputUnits)
                deliveryInputUnits = 0
            }
        }

        /// Claims the fresh record for `frontmostPID`, consuming it. A stale, disabled or
        /// foreign record is invalidated instead and nothing is returned.
        func takeUndoAttempt(now: Date, frontmostPID: pid_t?) -> UndoAttempt? {
            lock.withLock {
                // Every bare backspace lands here, nearly always with no record; check that
                // before the setting so the common miss skips two defaults reads under the lock.
                guard let record = lastExpansion, record.isFresh(now: now), undoEnabledLocked,
                      let target, let pid = target.pid, pid > 0,
                      pid == frontmostPID else {
                    invalidateUndoLocked()
                    return nil
                }
                let attempt = UndoAttempt(record: record, target: target,
                                          inputEvents: inputEventsSinceExpansion,
                                          inputRevision: inputRevision, generation: undoGeneration)
                lastExpansion = nil
                self.target = nil
                inputEventsSinceExpansion = 0
                return attempt
            }
        }

        func undoAttemptIsCurrent(_ attempt: UndoAttempt) -> Bool {
            lock.withLock {
                undoEnabledLocked && undoGeneration == attempt.generation
                    && inputRevision == attempt.inputRevision
            }
        }

        func invalidateUndo() {
            lock.withLock { invalidateUndoLocked() }
        }

        func invalidateUndo(ifInjectedTextIs text: String) {
            lock.withLock {
                if lastExpansion?.injectedText == text { invalidateUndoLocked() }
            }
        }

        private func invalidateUndoLocked() {
            lastExpansion = nil
            target = nil
            inputEventsSinceExpansion = 0
            undoGeneration &+= 1
        }
    }
}
