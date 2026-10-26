import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Tap callback and per-event handling.
extension EventTapEngine {
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


    /// A real key the tap hands to the field without matching it (matching suspended or disabled,
    /// Secure Input, autorepeat, a caret-moving or chorded key, a key racing the type-ahead
    /// replay). It reaches the field, so an operation in flight — an AI delivery, whose matching
    /// suspension is exactly why this branch is taken, or a replace confirm about to write focus —
    /// must see the input revision move. Only a key swallowed into type-ahead never does, and that
    /// path returns before any of these.
    private func noteBypassedRealKey() {
        TextInjectionPipeline.shared.noteDeliveryInput()
    }

    /// The whole tap hot path. Extracted from the C callback so it can use `autoreleasepool`,
    /// early `return`s and instance state directly.
    ///
    /// Everything here must be safe off the main thread (§1.1): no AppKit, no synchronous AX IPC,
    /// no disk. AppKit-derived facts come from the caches refreshed by the app-switch /
    /// input-source observers (§2.3).
    func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            handleTapDisabled(reason: .timeout)
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            handleTapDisabled(reason: .userInput)
            return Unmanaged.passUnretained(event)
        }

        let isSynthetic = event.getIntegerValueField(.eventSourceUserData) == SyntheticEventMarker.magicUserData
        var clockMark: InputClock.Mark?
        if !isSynthetic {
            if EventTapEngine.mouseDownTypes.contains(type) || type == .keyDown {
                clockMark = inputClock.mark(at: inputClock.seconds(fromEventTimestamp: event.timestamp))
            }
        }

        // Mouse clicks move the caret — buffer is no longer valid.
        if EventTapEngine.mouseDownTypes.contains(type) {
            // §8.3: and any keystrokes being held for an in-flight expansion must go out *now*,
            // at the caret they were typed at. Replaying them after the click would type them
            // wherever the user just clicked.
            lock.lock()
            let holdPID = _typeAhead.holdPID
            let stranded = _typeAhead.flushForCaretChange()
            lock.unlock()
            replayTypeAhead(stranded, heldFor: holdPID, reason: "caret moved (click)")
            resetBuffer()
            // §3.1: same rule as escape/arrows below — the caret moved, so the recorded expansion
            // no longer describes what sits in front of it. Clicks were the one caret move that
            // kept the record alive, which let a click + backspace within the undo window fire a
            // blind erase at the click position in AX-opaque hosts.
            TextInjectionPipeline.shared.clearLastExpansion()
            // §3.1d: a click during an *in-flight* delivery moves the caret around text whose
            // final geometry the record cannot know. The counter is drained into that record's
            // input count when delivery completes; outside a delivery it is discarded at the next
            // `beginDeliveryWindow()`.
            TextInjectionPipeline.shared.noteDeliveryInput()
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
        let polledSecureFlag = _isSecureInputActive
        let suspended = _matchingSuspendCount > 0
        let replayInFlight = _replayInFlight
        lock.unlock()

        // Pass through while inject+restore owns the critical section.
        // Must NOT swallow synthetic HID (backspace / ⌘V / arrows) we post ourselves.
        if expanding || isSynthetic {
            // §8.3: the expansion is still being delivered. Passing a real keystroke through here
            // is what let `a` land in front of `ScholarLM` — the paste was still in flight. Hold
            // it instead and replay after delivery, so ordering matches an instant expansion.
            if expanding, !isSynthetic {
                let admission = admitTypeAhead(event: event)
                // §3.1d: count before acting on the decision. The key itself counts when it is
                // field-touching; a flush additionally counts its replayed characters, which
                // land mid-delivery even when the trigger key was inert (F-key flush).
                let units = ExpansionUndoPolicy.deliveryInputUnits(
                    keyContaminates: admission.contaminatesBlindUndo,
                    flushReplayCount: admission.decision.replayCount
                )
                if units > 0 {
                    TextInjectionPipeline.shared.noteDeliveryInput(units: units)
                }
                switch admission.decision {
                case .swallow:
                    // Held for replay after delivery, so it never touches the field under the
                    // erase: it must not count as input that invalidates the expansion.
                    if let clockMark { inputClock.retract(clockMark) }
                    return nil
                case .flushThenPassThrough(let replay):
                    replayTypeAhead(replay, heldFor: admission.holdPID, reason: "hold released early")
                case .passThrough:
                    break
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // The polled flag is refreshed from the main queue after a 350 ms poll, so it can say
        // "secure" for a while after the system stopped being. Trusting it blindly dropped every
        // key typed in that window from the buffer — a trigger typed right after leaving a
        // password field lost its first characters and never matched. One live read, only when
        // the flag claims secure, settles it and corrects the flag.
        var secureFlag = polledSecureFlag
        if secureFlag, !liveSecureInputProbe() {
            isSecureInputActive = false
            secureFlag = false
        }

        // A real key while `endExpansion` is still posting the replayed type-ahead lands in the
        // field before or after those characters, and the ring was seeded as if it knew which.
        // Matching on it could erase text that is not the trigger, so it bypasses like any other
        // input the buffer cannot account for.
        if replayInFlight {
            noteBypassedRealKey()
            TextInjectionPipeline.shared.clearLastExpansion()
            discardStateForBypassedInput("keystroke raced the type-ahead replay")
            return Unmanaged.passUnretained(event)
        }

        guard enabled && !secureFlag && !suspended else {
            noteBypassedRealKey()
            TextInjectionPipeline.shared.clearLastExpansion()
            discardStateForBypassedInput(
                "keystroke bypassed matching (disabled/secure/suspended)"
            )
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if EventTapEngine.shouldIgnoreForMatching(isAutorepeat: isAutorepeat) {
            noteBypassedRealKey()
            TextInjectionPipeline.shared.clearLastExpansion()
            // Autorepeat appends characters the matcher never sees (repeats are filtered from
            // matching), so from the first repeat on the buffer no longer describes the field:
            // `` `sl `` + a held `l` leaves the buffer at `` `sl `` while the field reads
            // `` `slllll ``, and the next `m` would complete a trigger that is not there. Same
            // integrity rule as above — the hold and the buffer both go.
            discardStateForBypassedInput("autorepeat input is invisible to matching")
            return Unmanaged.passUnretained(event)
        }

        if EventTapEngine.shouldResetBuffer(flags: flags, keyCode: keyCode) {
            noteBypassedRealKey()
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
        // A preflight refusal returns the key only while its source context remains current.
        // Later input revokes queued undo through the shared injection continuation guard.
        if keyAction == .deleteLast,
           flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty,
           TextInjectionPipeline.shared.undoLastExpansion(
               heldBackspace: SwallowedKey(
                   didSwallow: true,
                   unicode: unicodeStr.isEmpty ? "\u{7F}" : unicodeStr,
                   keyCode: keyCode,
                   flags: []
               )
           ) {
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

        // §2.3: cached frontmost facts, read before the layout buffer is touched. The mute
        // lookup, TIS, and the terminal check used to run per key. The physical-layout buffer
        // is Korean 2-Set only: updating or copying it on every other keystroke did work the
        // matcher ignores (`LayoutAwareMatcher` returns before reading it). The two locks are
        // never held together.
        contextLock.lock()
        let context = _frontmostContext
        let allowPhysical = _allowPhysicalFallback
        contextLock.unlock()

        lock.lock()
        if keyAction == .deleteLast {
            ringBuffer.removeLast()
            lastEventUTF16Count = 1
        } else if length > 0 {
            // §2.3: the ring evicts its own oldest entry — no O(n) `removeFirst` memmove per key.
            ringBuffer.append(contentsOf: unicodeStr)
            // AX ranges are UTF-16; keep erase math in the same units.
            lastEventUTF16Count = max(1, unicodeStr.utf16.count)
        }
        if allowPhysical {
            if keyAction == .deleteLast {
                layoutBuffer.recordKeystroke(allowPhysicalFallback: true, delete: true)
            } else if length > 0, let physicalChar {
                layoutBuffer.recordKeystroke(
                    allowPhysicalFallback: true,
                    delete: false,
                    composed: unicodeStr,
                    physical: physicalChar
                )
            }
        } else if !layoutBuffer.isEmpty {
            // Drop stale 2-Set keystrokes once, when the input source leaves that layout.
            // Steady-state non-Korean keys see an empty buffer and do not walk it.
            layoutBuffer.clear()
        }
        // §2.3: hand the matcher `[Character]` directly. The old path built a `String` here that
        // `AbbreviationMatcher.match` immediately undid with `Array(buffer)`.
        let bufferCharacters = ringBuffer.makeArray()
        let layoutSnapshot = allowPhysical ? layoutBuffer : LayoutBuffer.idle
        let lastUTF16Count = lastEventUTF16Count
        lock.unlock()

        // Hot path: muted check + matcher + sync-safe planner gate only.
        // Heavy AX (secure/IME/focus) stays off-callback; refuse there reinjects the swallow.
        if context.isMuted {
            // The buffer above stayed in step with the field, but a hold armed before the app
            // was muted never sees this key, so its erase count is already short.
            if heldCoordinator.cancelAll(reason: .unobservedInput) {
                DevTypeLog.debounce.debug("[Debounce] hold cancelled — frontmost app is muted")
            }
            return Unmanaged.passUnretained(event)
        }

        // Typed-repetition detection. Deliberately *after* the mute check and behind a live
        // Secure Input read, and it introduces no new retention: the phrase is the ring buffer
        // that already exists for matching, is already capped at 64 characters, and is already
        // emptied when Secure Input turns on. `TypedRepetitionDetector` keeps only a salted
        // hash of it. Runs on Return / Enter / Tab, so this is not a per-keystroke cost.
        if KeyClassifier.endsPhrase(keyCode: Int(keyCode)),
           TypedRepetitionPreferences.isActive,
           !AXContextChecker.isSecureEventInputEnabledLive() {
            let phrase = String(bufferCharacters)
            if let candidate = TypedRepetitionDetector.shared.record(
                phrase: phrase, bundleID: context.bundleID
            ) {
                let handler = onRepetitionNoticed
                DispatchQueue.main.async { handler?(candidate) }
            }
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

        let snapshot = PermissionCoordinator.shared.cachedSnapshot
        // Dedicated terminals only on hot path (cached bundle ID); IDE shell needs AX → deferred.
        let isTerminal = context.isTerminal
        // This used to render the whole snippet first — macros, nested `{{snippet:…}}` lookups
        // and all — purely to derive `needsCursorHID` and `isMultiLine` for the call below.
        // `InjectionPlanner.plan` discards both (`_ = needsCursorHID`, `_ = isMultiLine`): they
        // are retained for API compatibility and inject-path logging, and are not refuse gates.
        // The decision rests entirely on AX, Post and terminal-ness, so the render was a full
        // macro expansion per expansion, inside the CGEventTap callback, for two values nobody
        // read. The real render still happens on the inject path, where its result is used.
        let plan = InjectionPlanner().plan(
            snapshot: snapshot,
            isTerminal: isTerminal
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
        if liveSecureInputProbe() {
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
            let admission = admitTypeAhead(event: event)
            // §3.1d: same delivery-window rule as the callback's expanding gate — the claim
            // lost, so this key (and any flush it forces) lands inside the other delivery.
            let units = ExpansionUndoPolicy.deliveryInputUnits(
                keyContaminates: admission.contaminatesBlindUndo,
                flushReplayCount: admission.decision.replayCount
            )
            if units > 0 {
                TextInjectionPipeline.shared.noteDeliveryInput(units: units)
            }
            switch admission.decision {
            case .swallow:
                if let clockMark { inputClock.retract(clockMark) }
                return nil
            case .flushThenPassThrough(let replay):
                replayTypeAhead(replay, heldFor: admission.holdPID, reason: "hold released early")
            case .passThrough:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        resetBuffer()
        let utf16Trigger = match.eraseCount
        let charCount = lastUTF16Count
        let swallowed = SwallowedKey(didSwallow: true, unicode: unicodeStr, keyCode: keyCode, flags: flags)
        let terminator = match.terminator
        let eraseOverride = match.source == .physical ? match.eraseCount : nil
        // Exact text expected left of the caret. Carries both unit systems (UTF-16 for AX
        // ranges, graphemes for backspaces) so neither path has to re-derive them.
        let erasePlan: ErasePlan
        if let fieldText = match.fieldText {
            erasePlan = ErasePlan.forMatch(
                matchedTrigger: fieldText,
                terminator: terminator,
                swallowed: swallowed,
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
                swallowed: swallowed,
                terminator: terminator,
                eraseCountOverride: eraseOverride,
                erasePlan: erasePlan,
                armedFocusPID: focusPID,
                caseShape: match.caseShape
            )
        }
        return nil // Swallow only after sync-safe planner allow
    }
}
