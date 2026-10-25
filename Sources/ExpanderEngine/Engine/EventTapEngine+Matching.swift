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
        _typeAhead.beginExpansion(focusPID: focusPID)
        // §3.1d: open the delivery-input window *before* the expanding flag is visible to the
        // tap thread. Resetting it after the flag was observable raced: a pass-through key could
        // increment the counter and then be wiped by the reset, losing exactly the contamination
        // evidence the window exists to keep. Nesting order is one-directional (engine →
        // pipeline); no path holds `lastExpansionLock` while taking this engine lock.
        TextInjectionPipeline.shared.beginDeliveryWindow()
        lock.unlock()
        return true
    }

    func endExpansion() {
        lock.lock()
        _isExpanding = false
        let holdPID = _typeAhead.holdPID
        let replay = _typeAhead.endExpansion()
        ringBuffer.removeAll()
        layoutBuffer.clear()
        lastEventUTF16Count = 1
        lock.unlock()
        // §8.3: outside the lock — replaying posts HID events, and the tap callback for those
        // events takes this same lock.
        replayTypeAhead(replay, heldFor: holdPID, reason: "expansion complete")
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
            focusPID: focusPID
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
        TextInjectionPipeline.shared.noteInputAfterExpansion(units: text.count)
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
    }
}
