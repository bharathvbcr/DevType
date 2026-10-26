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
        /// The chord that accepted a result, noted just before the delivery it starts is claimed;
        /// the next `claim` takes it if it is still fresh, so a chord that led to no delivery
        /// cannot attach to an unrelated one.
        private var pendingAcceptChord: (chord: DeliveryChord, at: Date)?
        /// The chord that started `activeOperation`, while that operation is in flight.
        private var deliveryChord: DeliveryChord?
        static let acceptChordWindow: TimeInterval = 3

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
        func claim(_ operation: InjectCompletionGuard, consumingUndo: Bool, now: Date = Date()) -> UInt64 {
            lock.withLock {
                if consumingUndo { invalidateUndoLocked() }
                activeOperation?.cancel()
                activeOperation = operation
                if let pending = pendingAcceptChord, now.timeIntervalSince(pending.at) <= Self.acceptChordWindow {
                    deliveryChord = pending.chord
                } else {
                    deliveryChord = nil
                }
                pendingAcceptChord = nil
                return inputRevision
            }
        }

        /// Records the chord that accepted a result, for the delivery claimed next.
        func noteAcceptChord(_ chord: DeliveryChord, now: Date = Date()) {
            lock.withLock { pendingAcceptChord = (chord, now) }
        }

        /// Whether `chord` is the one that started the operation in flight. False once that
        /// operation has completed, timed out, or been superseded, so a later press of the same key
        /// is real input again. Takes only the local state of the operation, never its caller's
        /// closure — this is asked from the event tap thread.
        func isDeliveryChord(_ chord: DeliveryChord) -> Bool {
            lock.withLock {
                guard let deliveryChord, deliveryChord == chord, let operation = activeOperation else { return false }
                return operation.terminalOutcome == nil && !operation.didTimeOut
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
            lock.withLock { deliveryInputUnits = 0 }
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
