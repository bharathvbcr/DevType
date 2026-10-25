import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Prefix-debounce held expansions and buffer reset.
extension EventTapEngine {
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
    func holdExpansion(
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

    /// A keystroke produced no match while an expansion was held.
    ///
    /// `typedNow` is what *this* keystroke put in the field, taken straight from the event
    /// rather than from the ring buffer — see `HeldExpansionState`. The decision and the state
    /// change are one atomic step inside the coordinator; this method only performs the side
    /// effects for the outcome it is handed.
    func resolveHeldExpansionOnNoMatch(
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
                swallowed: .notSwallowed,
                terminator: "",
                eraseCountOverride: nil,
                erasePlan: erasePlan,
                armedFocusPID: focusPID,
                textSuffix: suffix,
                caseShape: TriggerCaseShape.forExpansion(of: snippet, typedTrigger: trigger)
            )
        }
    }
    /// A real keystroke reached the field without passing through matching (pause, suspension,
    /// Secure Input, autorepeat).
    ///
    /// Two things stop describing the field at that moment, and both must go together:
    ///   * a live hold, whose erase is counted from *observed* keystrokes;
    ///   * the buffer — it still holds the characters typed before the bypass, so one more
    ///     character after matching resumes could complete a trigger that the field never
    ///     contained, and the erase that follows deletes whatever is there instead.
    /// Cheap enough for every bypassed key: an already-empty ring clears in O(1).
    func discardStateForBypassedInput(_ why: String) {
        if heldCoordinator.cancelAll(reason: .unobservedInput) {
            DevTypeLog.debounce.debug("[Debounce] hold cancelled — \(why, privacy: .public)")
        }
        resetBuffer()
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
}
