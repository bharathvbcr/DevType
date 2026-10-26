import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Match lookup, expansion gating and type-ahead.
extension EventTapEngine {
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
    func tryBeginExpansion() -> Bool {
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
        _typeAhead.beginExpansion(focusPID: focusPID, now: now())
        // §3.1d: open the delivery-input window *before* the expanding flag is visible to the
        // tap thread. Resetting it after the flag was observable raced: a pass-through key could
        // increment the counter and then be wiped by the reset, losing exactly the contamination
        // evidence the window exists to keep. Nesting order is one-directional (engine →
        // pipeline); no path holds `lastExpansionLock` while taking this engine lock.
        pipeline.beginDeliveryWindow()
        lock.unlock()
        return true
    }

    func endExpansion() {
        // Before `lock`, like `tryBeginExpansion`: the context has its own lock.
        let currentPID = frontmostContext.processID
        // Before `lock`, for the same reason: the physical-layout buffer is cleared here and never
        // seeded, so on that path the ring must not claim text the layout buffer does not.
        contextLock.lock()
        let physicalLayoutPath = _allowPhysicalFallback
        contextLock.unlock()
        lock.lock()
        _isExpanding = false
        let holdPID = _typeAhead.holdPID
        let replay = _typeAhead.endExpansion()
        // Same nesting as `tryBeginExpansion` (engine → pipeline). A surrender recorded for this
        // delivery must not outlive it and withhold an unrelated key replay later.
        pipeline.endDeliveryWindow()
        ringBuffer.removeAll()
        layoutBuffer.clear()
        lastEventUTF16Count = 1
        // The replay is posted as synthetic events, which the tap ignores — so the buffer would
        // never learn of characters that are about to land in the field. Two triggers typed back
        // to back (`` `slm `` then `` `asu ``) lost the first characters of the second this way.
        // Seeded only when the replay will actually be posted, and only while the ring is the
        // whole story: `_replayInFlight` keeps a real key that races the posts out of it (see the
        // tap callback), so the ring is never in an order the field may not share.
        let seeded = !replay.isEmpty && !physicalLayoutPath
            && TypeAheadBuffer.mayReplay(heldFor: holdPID, intoFrontmost: currentPID)
        if seeded {
            ringBuffer.append(contentsOf: replay)
            lastEventUTF16Count = max(1, String(replay.last ?? " ").utf16.count)
            _replayInFlight = true
        }
        lock.unlock()
        // §8.3: outside the lock — replaying posts HID events, and the tap callback for those
        // events takes this same lock.
        replayTypeAhead(replay, heldFor: holdPID, reason: "expansion complete")
        if seeded {
            lock.lock()
            _replayInFlight = false
            lock.unlock()
        }
    }

    /// Decides one keystroke against the type-ahead hold. Runs on the tap thread, so it reads the
    /// event directly and never touches AppKit.
    func admitTypeAhead(
        event: CGEvent
    ) -> (decision: TypeAheadBuffer.Decision, contaminatesBlindUndo: Bool, holdPID: pid_t?) {
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
            if length > 0, let base = scratch.baseAddress {
                unicode = String(utf16CodeUnits: base, count: length)
            }
        }

        let focusPID = frontmostContext.processID
        lock.lock()
        // Read before `admit`: a decision that flushes clears the hold, and the app the
        // characters were typed in is the only app they may be posted to.
        let holdPID = _typeAhead.holdPID
        let decision = _typeAhead.admit(
            unicode: unicode,
            isSynthetic: false,
            resetsBuffer: resets,
            focusPID: focusPID,
            now: now()
        )
        lock.unlock()

        // §3.1d: a key that reaches the field *now* — swallowed keys are replayed later and are
        // already counted by `replayTypeAhead` — edits or moves text around a paste whose final
        // geometry is unknowable. Poison the blind-undo premise of the record this delivery will
        // write. Pure predicate on the pipeline keeps this testable without an engine.
        let contaminates = ExpansionUndoPolicy.deliveryPassThroughContaminatesBlindUndo(
            resetsCaret: resets,
            isDelete: KeyClassifier.action(forKeyCode: Int(keyCode)) == .deleteLast,
            unicodeCount: length
        )
        return (decision, decision != .swallow && contaminates, holdPID)
    }

    /// The type-ahead hold has surrendered (`.flushThenPassThrough`, or a click flushing it). If
    /// the in-flight inject has not begun mutating the field, it is abandoned here and the
    /// terminator it swallowed is put back first, so the user's keystrokes reach the field in
    /// the order they typed them: terminator, then the keys the hold released, then the key that
    /// forced the surrender. Once the pipeline has begun mutating, nothing changes: that
    /// expansion is already past the point where the terminator's place is defined.
    ///
    /// Must be called on the tap thread, before `replayTypeAhead` posts the released keys and
    /// before the surrendering event is handed back. `reason` is a bounded label for the log.
    ///
    /// `postTerminator` false is the click: the surrender still abandons the inject, but the
    /// terminator is settled without being typed. A post from inside the callback may reach the
    /// app *after* the event being handed back — unverified either way until a live run settles
    /// it — and after a click that event has moved the caret, so a Return terminator could submit
    /// whatever field the user just clicked into. Losing it is what a click did before.
    func surrenderHoldPuttingTerminatorBack(heldFor sourcePID: pid_t?, reason: String, postTerminator: Bool = true) {
        // The surrender exists to keep the terminator ahead of the held keys *in the field they
        // were typed in*. A hold that ends because focus left that app — DevType's own fill-in
        // panel, which the expansion opened and will paste after, or another app — is not that:
        // the inject's own focus gates judge it, and its owed terminator stays with the refusal
        // that checks the target. Surrendering there cancelled every fill-in snippet the moment
        // its panel took a key. Only an app *known* to be the same counts: an unknown hold or
        // frontmost process is not evidence the field is the one the keys were held for.
        guard let sourcePID, let frontPID = frontmostContext.processID, sourcePID == frontPID else {
            return
        }
        guard case .abandoned(let terminator?) = pipeline.surrenderHold() else {
            return
        }
        guard postTerminator else {
            DevTypeLog.inject.notice("[TypeAhead] hold surrendered by a click — terminator not typed after the caret moved")
            return
        }
        let safeReason = DevTypeLog.boundedPublicIdentifier(reason, label: "replayReason")
        DevTypeLog.inject.notice(
            "[TypeAhead] hold surrendered before the erase — terminator put back ahead of the held keys, reason=\(safeReason, privacy: .public)"
        )
        postSurrenderedTerminator(terminator)
    }

    /// Re-posts keystrokes held during an expansion, in the order they were typed.
    ///
    /// The queue's invariant is that everything admitted is replayed exactly once, so this is the
    /// only exit and it must not be conditional on anything that could silently skip it — with
    /// the single exception the buffer documents: the app that was focused when the keys were
    /// typed. `sourcePID` is therefore required rather than defaulted, so a new call site has to
    /// state where its characters came from instead of inheriting a guess.
    func replayTypeAhead(_ text: String, heldFor sourcePID: pid_t?, reason: String) {
        guard !text.isEmpty else { return }

        // A replay is an HID post, and an HID post lands in whatever is frontmost *now*. If that
        // is provably not the app the characters were typed in, they are dropped: putting one
        // app's typing into another leaks it and corrupts the field it arrives in, and these
        // characters never reached the original app either way. The delivery-input window was
        // already charged for them above; over-counting input only makes a later blind undo more
        // reluctant, which is the safe direction to be wrong in.
        let currentPID = frontmostContext.processID
        guard TypeAheadBuffer.mayReplay(heldFor: sourcePID, intoFrontmost: currentPID) else {
            let safeReason = DevTypeLog.boundedPublicIdentifier(reason, label: "replayReason")
            DevTypeLog.inject.error(
                """
                [TypeAhead] dropped \(text.count, privacy: .public) held keystroke(s) — focus \
                left the app they were typed in; replaying would deliver them elsewhere. \
                reason=\(safeReason, privacy: .public)
                """
            )
            return
        }
        // `EventTapEngine` normally owns a dedicated tap run-loop thread. Replay must therefore
        // stay synchronous on whichever thread is ending the expansion: dispatching to main here
        // lets the triggering key pass through before the held characters and transposes input.
        // The HID poster is explicitly thread-safe and is already used from the inject queue.
        let safeReason = DevTypeLog.boundedPublicIdentifier(reason, label: "replayReason")
        DevTypeLog.inject.notice(
            """
            [TypeAhead] replaying \(text.count, privacy: .public) held keystroke(s) — \
            reason=\(safeReason, privacy: .public)
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
        pipeline.noteInputAfterExpansion(units: text.count)
        // HID only — deliberately *not* `attemptAXDirectInjection`. That call reports success
        // without writing in the whole Chromium/Electron false-success class, which is exactly
        // where this bug occurs, so an AX replay would silently eat the user's keystrokes: the
        // one outcome this design must never produce. A posted key can be dropped by the system,
        // but it is never a lie.
        for character in text {
            typeAheadReplayPoster(String(character))
        }
    }

    func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Caps Lock (keycode 57) toggles often imply caret/context change — reset.
        if keyCode == 57 {
            resetBuffer()
        }
        // Fn / Globe (keycode 63) is how the emoji picker and dictation open, and both insert text
        // with no key events at all — the buffer would lack it. Pressing Fn to reach an F-key or
        // a navigation key costs only a partially typed trigger.
        if keyCode == Int64(kVK_Function) {
            resetBuffer()
        }
    }
}
