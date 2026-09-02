import AppKit
import ApplicationServices
import Foundation

/// The destructive-posting surface `EraseExecutor` needs from `HIDKeyPoster`. A protocol rather
/// than the concrete type so tests can simulate Post Events being revoked mid-session — the
/// exact condition where a silent "erase succeeded" would leave `trigger + replacement` in the
/// field.
public protocol BackspacePosting: AnyObject {
    /// Posts `count` delete key pairs; returns how many pairs were actually posted.
    @discardableResult
    func sendBackspaces(count: Int) -> Int
    /// Async wrapper. `completion(true)` only when **every** requested backspace was posted.
    func sendBackspacesAsync(count: Int, completion: @escaping (Bool) -> Void)
}

/// §8.1: the destructive half of expansion — deciding how much to delete, proving it is safe to
/// delete, and then deleting it. `ErasePlan.swift` owns the pure half (unit counting + the
/// precondition evaluator); this owns the AX reads and the posted backspaces.
public final class EraseExecutor {
    public static let shared = EraseExecutor()

    private let hid: any BackspacePosting
    private let ax: AXTextWriter

    public init(
        hid: any BackspacePosting = HIDKeyPoster.shared,
        ax: AXTextWriter = AXTextWriter.shared
    ) {
        self.hid = hid
        self.ax = ax
    }

    // MARK: - Counting

    /// UTF-16 code units still present in the focused field that must be erased before injection.
    /// When the event tap swallows the final trigger key (`return nil`), that key never
    /// reaches the field, so only `triggerLength - lastEventCharacterCount` units remain.
    /// Both `triggerLength` and `lastEventCharacterCount` are UTF-16 lengths.
    public static func eraseCount(
        triggerLength: Int,
        swallowedFinalKey: Bool,
        lastEventCharacterCount: Int = 1
    ) -> Int {
        guard triggerLength > 0 else { return 0 }
        if swallowedFinalKey {
            let swallowed = max(1, lastEventCharacterCount)
            return max(0, triggerLength - swallowed)
        }
        return triggerLength
    }

    /// Erase planning for AbbreviationMatcher results under DevType swallow.
    /// Bare-word terminator is swallowed and must **not** be re-appended (unlike SnipKey listenOnly).
    /// When `terminator` is non-empty, only the trigger remains in the field → erase trigger UTF-16.
    ///
    /// Count-only; prefer `ErasePlan.forMatch` which additionally carries the grapheme count used by
    /// the HID backspace path and the expected text used by the precondition guard.
    public static func eraseCountForMatch(
        triggerUTF16Length: Int,
        terminator: String,
        swallowedFinalKey: Bool,
        lastEventCharacterCount: Int = 1
    ) -> Int {
        if !terminator.isEmpty {
            return max(0, triggerUTF16Length)
        }
        return eraseCount(
            triggerLength: triggerUTF16Length,
            swallowedFinalKey: swallowedFinalKey,
            lastEventCharacterCount: lastEventCharacterCount
        )
    }

    // MARK: - Precondition

    /// Reads the focused field and decides whether the erase described by `plan` is safe to run.
    ///
    /// This is the backstop for the whole pipeline: no matter which path mis-planned the erase (unit
    /// confusion, a stale caret, a half-applied AX edit, a racing keystroke), if AX can read the
    /// field and the expected trigger is not sitting left of the caret, the expand is refused rather
    /// than deleting whatever *is* there.
    ///
    /// §8.3: this is the **asynchronous** form, and it is the one every inject-path caller uses.
    /// The retry used to be `guard … Thread.isMainThread else { return first }` followed by
    /// `Thread.sleep(0.03)` — so the safety net existed only on main, was implemented by blocking
    /// main (during which the tap callback cannot run), and silently did nothing for off-main
    /// callers. Scheduling the re-probe instead makes the retry available from any thread and
    /// blocks nothing.
    ///
    /// `completion` runs synchronously on the calling thread when no retry is needed (the common
    /// case, and the case on the keystroke path), and on main after the settle when it is.
    ///
    /// - Parameters:
    ///   - element: pre-resolved focused element. Pass one when the caller already holds it;
    ///     `AXContextChecker.focusedElement()` is not free and this runs on the keystroke path.
    ///   - retryOnMismatch: re-probe once, with a freshly resolved element, after a short settle.
    ///     The first read can catch the AX tree mid-transition — notably right after the fill-in
    ///     panel closes and focus returns to the target app — and a transient disagreement must
    ///     degrade to a retry, never to a refused expand.
    ///   - insertionPointFollowsExpectedText: see `ErasePreconditionChecker.evaluate`. The undo
    ///     path passes false so a mismatch surfaces instead of degrading to best-effort.
    public func evaluateErasePrecondition(
        plan: ErasePlan,
        element: AXUIElement? = nil,
        retryOnMismatch: Bool = true,
        insertionPointFollowsExpectedText: Bool = true,
        completion: @escaping (ErasePreconditionResult) -> Void
    ) {
        let first = evaluateErasePreconditionOnce(
            plan: plan,
            element: element,
            insertionPointFollowsExpectedText: insertionPointFollowsExpectedText
        )
        guard retryOnMismatch, first.blocksErase else {
            completion(first)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.erasePreconditionRetryDelay) {
            completion(self.evaluateErasePreconditionOnce(
                plan: plan,
                element: nil,
                insertionPointFollowsExpectedText: insertionPointFollowsExpectedText
            ))
        }
    }

    /// Synchronous form, kept for callers that cannot take a continuation.
    ///
    /// §8.3: the retry is now performed **only off main**, where sleeping is harmless — the
    /// inverse of the old condition. A main-thread caller that wants the retry must use the
    /// asynchronous form above; blocking main for 30 ms on the keystroke path is precisely the
    /// behaviour that starves the event tap.
    public func evaluateErasePrecondition(
        plan: ErasePlan,
        element: AXUIElement? = nil,
        retryOnMismatch: Bool = true,
        insertionPointFollowsExpectedText: Bool = true
    ) -> ErasePreconditionResult {
        let first = evaluateErasePreconditionOnce(
            plan: plan,
            element: element,
            insertionPointFollowsExpectedText: insertionPointFollowsExpectedText
        )
        guard retryOnMismatch, first.blocksErase, !Thread.isMainThread else { return first }
        Thread.sleep(forTimeInterval: InjectTiming.erasePreconditionRetryDelay)
        return evaluateErasePreconditionOnce(
            plan: plan,
            element: nil,
            insertionPointFollowsExpectedText: insertionPointFollowsExpectedText
        )
    }

    private func evaluateErasePreconditionOnce(
        plan: ErasePlan,
        element: AXUIElement?,
        insertionPointFollowsExpectedText: Bool = true
    ) -> ErasePreconditionResult {
        if plan.utf16Count == 0 { return .ok }
        guard ErasePreconditionChecker.isEnabled else {
            return .unavailable("erase precondition disabled by user default")
        }
        guard let axElement = element ?? AXContextChecker.shared.focusedElement() else {
            return .unavailable("no focused element")
        }

        var value: String?
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef) == .success {
            value = valueRef as? String
        }

        var caretLocation: Int?
        var selectionLength: Int?
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range) {
                caretLocation = range.location
                selectionLength = range.length
            }
        }

        return ErasePreconditionChecker.evaluate(
            plan: plan,
            value: value,
            caretLocation: caretLocation,
            selectionLength: selectionLength,
            insertionPointFollowsExpectedText: insertionPointFollowsExpectedText
        )
    }

    // MARK: - Guarded erase

    /// Collapse stray selection → re-verify the erase precondition → post backspaces.
    ///
    /// The precondition is checked again here (not only at the top of `injectOnMain`) because
    /// everything between the two checks — an AX replace attempt, a macro resolve, a fill-in panel —
    /// can move the caret or change the field. This is the last gate before text is destroyed.
    /// `completion(false)` means the erase was refused and the caller must abort the expand.
    /// - Parameter afterPossibleWrite: pass `true` when an AX write was already **attempted**
    ///   against this field. `.unavailable` normally means "AX cannot tell us, proceed
    ///   best-effort", which is the right default for an untouched field. After an attempted
    ///   write it is not: the attempt may have mutated the field without our being able to
    ///   verify it (Safari / Chromium / Electron report stale or virtualised AXValue right
    ///   after a real edit), so erasing and injecting again duplicates the expansion — the
    ///   `ScholarLMScholarLM` shape. Under this flag, unverifiable state refuses instead.
    /// - Parameter onUnverifiableAfterWrite: invoked (with the reason) only when the refuse is
    ///   the `afterPossibleWrite` + `.unavailable` combination — an attempted AX write against a
    ///   field that still could not be read back *after* the settle retry. That signature is how
    ///   Chromium / Electron shells present, and the caller can use it to learn the app's
    ///   verdict so the next expansion skips the AX write instead of refusing forever. Never
    ///   invoked for `.mismatch` (a readable field that disagrees — usually a moved caret, not a
    ///   broken app).
    /// - Parameter canProceed: live input/focus guard, re-evaluated after retries and before
    ///   posting. A caller that observed a context change must not erase from the stale snapshot.
    public func performGuardedErase(
        plan: ErasePlan,
        afterPossibleWrite: Bool = false,
        insertionPointFollowsExpectedText: Bool = true,
        canProceed: @escaping () -> Bool = { true },
        onUnverifiableAfterWrite: ((String) -> Void)? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        guard plan.backspaceCount > 0 else {
            completion(true)
            return
        }
        guard canProceed() else {
            completion(false)
            return
        }
        // Resolve focus once and share it: `AXContextChecker.focusedElement()` is a multi-step AX
        // round trip and this sits on the keystroke path. Attribute reads through the handle stay
        // live, so the precondition still sees the post-collapse selection.
        let element = AXContextChecker.shared.focusedElement()
        ax.collapseSelectionToCaret(element: element)
        evaluateErasePrecondition(
            plan: plan,
            element: element,
            insertionPointFollowsExpectedText: insertionPointFollowsExpectedText
        ) { result in
            if afterPossibleWrite, case .unavailable = result {
                // Unverifiable after a write that reached the field is grounds to refuse — but
                // not on the first read. The AX tree is routinely mid-transition right after an
                // edit (the write itself can trigger a re-render), so give it one settle before
                // concluding the field cannot be verified at all.
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + InjectTiming.erasePreconditionRetryDelay
                ) {
                    let second = self.evaluateErasePrecondition(
                        plan: plan,
                        element: nil,
                        retryOnMismatch: false,
                        insertionPointFollowsExpectedText: insertionPointFollowsExpectedText
                    )
                    self.finishGuardedErase(
                        plan: plan,
                        afterPossibleWrite: afterPossibleWrite,
                        result: second,
                        canProceed: canProceed,
                        onUnverifiableAfterWrite: onUnverifiableAfterWrite,
                        completion: completion
                    )
                }
                return
            }
            self.finishGuardedErase(
                plan: plan,
                afterPossibleWrite: afterPossibleWrite,
                result: result,
                canProceed: canProceed,
                onUnverifiableAfterWrite: onUnverifiableAfterWrite,
                completion: completion
            )
        }
    }

    /// Internal (not private) for `BackspaceIntegrityTests`: takes the already-evaluated
    /// precondition result so the destructive-posting half can be exercised without live AX.
    func finishGuardedErase(
        plan: ErasePlan,
        afterPossibleWrite: Bool,
        result: ErasePreconditionResult,
        canProceed: () -> Bool = { true },
        onUnverifiableAfterWrite: ((String) -> Void)?,
        completion: @escaping (Bool) -> Void
    ) {
        guard canProceed() else {
            DevTypeLog.inject.error("[Inject] erase aborted — input or target application changed")
            completion(false)
            return
        }
        if afterPossibleWrite, case .unavailable(let why) = result {
            DevTypeLog.inject.error(
                "[Inject] erase refused after an attempted AX write — cannot verify field (\(why, privacy: .public)). Proceeding would risk injecting twice."
            )
            onUnverifiableAfterWrite?(why)
            completion(false)
            return
        }
        if case .mismatch(let why) = result {
            DevTypeLog.inject.error(
                "[Inject] erase aborted before backspaces — \(why, privacy: .public)"
            )
            // #region agent log
            TextInjectionPipeline.debugLogInject(
                hypothesisId: "M5",
                message: "guarded erase aborted",
                location: "EraseExecutor",
                data: ["why": why, "eraseBackspaces": plan.backspaceCount]
            )
            // #endregion
            completion(false)
            return
        }
        // The precondition passed, but posting can still fail (Post Events revoked mid-session,
        // CGEvent creation failure). Reporting success here would inject the replacement on top
        // of an unerased trigger — the exact `trigger + replacement` corruption this executor
        // exists to prevent — so a short post is a refused expand, same as a mismatch.
        hid.sendBackspacesAsync(count: plan.backspaceCount) { erased in
            if erased {
                completion(true)
                return
            }
            DevTypeLog.inject.error(
                "[Inject] backspace post incomplete count=\(plan.backspaceCount, privacy: .public) — refusing expand; field may hold a partial trigger"
            )
            TextInjectionPipeline.debugLogInject(
                hypothesisId: "M5",
                message: "guarded erase aborted — backspaces not fully posted",
                location: "EraseExecutor",
                data: ["eraseBackspaces": plan.backspaceCount]
            )
            completion(false)
        }
    }
}
