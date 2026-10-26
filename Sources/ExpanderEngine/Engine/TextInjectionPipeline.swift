import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// The policy coordinator for text injection.
///
/// §8.1: the mechanics live in five collaborators this type owns — `HIDKeyPoster` (every CGEvent),
/// `PasteboardBroker` (the clipboard snapshot/restore invariant), `AXTextWriter` (the only code
/// touching `kAXSelectedText*`), `DeliveryVerifier` (did it land?) and `EraseExecutor` (what gets
/// deleted, and proving that is safe). What is left here is the decision-making: which path to
/// take, when to refuse, and what to tell the user afterwards.
///
/// The safety contract, unchanged:
/// * fail closed when AX is unavailable,
/// * refuse inside secure text fields, during IME composition, and in muted apps,
/// * the trigger key is swallowed only after a sync-safe planner allow; an asynchronous refuse
///   reinjects it unless input/focus changes made replay unsafe.
public final class TextInjectionPipeline {
    public static let shared = TextInjectionPipeline()

    /// Terminal result delivered to an inject caller after the pipeline has restored or retained
    /// the pasteboard. Callers must use this result for side effects; completion is not a synonym
    /// for success because refusals and delivery failures also need to release their state.
    public typealias InjectionCompletion = (PermissionCoordinator.InjectOutcome) -> Void

    /// §3.1: what the last delivered expansion did, so the user can take it back.
    ///
    /// Every competing expander reverts to the trigger when you press backspace right after an
    /// expansion. All the machinery for it already existed — `ErasePlan` knows the trigger text and
    /// both unit counts, and `restoreTriggerAfterFailedPaste` is a working "put the trigger back"
    /// implementation — it simply was not reachable by the user.
    public struct LastExpansion {
        /// The erase that made room for the expansion (i.e. the trigger side).
        public let erasePlan: ErasePlan
        /// Exactly what was injected. Undo erases this.
        public let injectedText: String
        /// What the user typed, restored by undo. This is the erased text plus the swallowed key,
        /// because the swallowed key never reached the field but the user did type it.
        public let triggerText: String
        public let bundleID: String?
        public let timestamp: Date

        public init(
            erasePlan: ErasePlan,
            injectedText: String,
            triggerText: String,
            bundleID: String?,
            timestamp: Date = Date()
        ) {
            self.erasePlan = erasePlan
            self.injectedText = injectedText
            self.triggerText = triggerText
            self.bundleID = bundleID
            self.timestamp = timestamp
        }

        public func isFresh(
            now: Date = Date(),
            window: TimeInterval = InjectTiming.effectiveUndoWindow
        ) -> Bool {
            let age = now.timeIntervalSince(timestamp)
            return window.isFinite && window > 0 && age >= 0
                && age <= min(window, InjectTiming.undoWindowCeiling)
        }
    }

    // MARK: - Collaborators

    /// Serializes inject + pasteboard restore so back-to-back expands cannot contaminate clipboard.
    private let injectQueue = DispatchQueue(label: "com.devtype.inject", qos: .userInteractive)
    private let planner = InjectionPlanner()

    private let hid: HIDKeyPoster
    private let ax: AXTextWriter
    private let verifier: DeliveryVerifier
    private let clipboard: PasteboardBroker
    /// Whether this app's AX mirror may be believed about a paste (`canConfirmDelivery`). A seam
    /// so a test's verdict is its own, not whatever this Mac learned about the test host's bundle.
    private let deliveryTrust: (_ bundleID: String?, _ role: String?) -> Bool
    private let eraser: EraseExecutor
    private let timing: InjectTimingStore

    /// §2.4 + §3.1: the undo record, the input revision and the current operation. One owner,
    /// one lock — the pipeline holds none of that state itself.
    private let ledger: ExpansionLedger

    public static let expansionUndoEnabledDefaultsKey = "DevTypeExpansionUndoEnabled"

    /// Enabled by default for existing installations. Disabling consumes every outstanding
    /// record and invalidates queued undo, including when the switch is re-enabled immediately.
    public var expansionUndoEnabled: Bool {
        get { ledger.undoEnabled }
        set { ledger.undoEnabled = newValue }
    }

    struct UndoAttempt {
        let record: LastExpansion
        let target: PasteboardBroker.PasteTarget
        let inputEvents: Int
        let inputRevision: UInt64
        let generation: UInt64
    }

    private enum InjectionPurpose {
        case expansion
        case undo(UndoAttempt)

        func deliveryPath(_ path: String) -> String {
            guard case .undo = self else { return path }
            switch path {
            case "axRange", "axOnlyRange": return "undoAXRange"
            case "axDirect": return "undoAXDirect"
            default: return "undoPaste"
            }
        }

        var eraseIntent: EraseExecutor.Intent {
            switch self {
            case .expansion: return .expansion
            case .undo(let attempt): return .undo(inputEventsSinceExpansion: attempt.inputEvents)
            }
        }

        /// A new expansion replaces the undo point; an undo's own inject must not consume the
        /// record it is undoing.
        var consumesUndo: Bool {
            if case .expansion = self { return true }
            return false
        }
    }

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            selectionConfirmer: SelectionReplacementGuard.Confirmer(),
            keepRefusedReplacement: { PasteboardBroker.shared.writeUserClipboardString($0) }
        )
    }

    /// Tests supply the selection confirmer (so a lost selection can be scripted without a live
    /// field), where a refused replace's payload goes (so a test never writes the real clipboard),
    /// and the broker and verifier that paste and then read the field back (so a ⌘V and its
    /// aftermath run against a private pasteboard and a scripted field, not the user's).
    init(
        defaults: UserDefaults,
        selectionConfirmer: SelectionReplacementGuard.Confirmer,
        keepRefusedReplacement: @escaping (String) -> Bool,
        focusQuery: @escaping (@escaping (AXContextChecker.FocusQueryResult) -> Void) -> Void = {
            AXContextChecker.shared.queryFocusedElement(completion: $0)
        },
        clipboard: PasteboardBroker = .shared,
        verifier: DeliveryVerifier = .shared,
        deliveryTrust: @escaping (_ bundleID: String?, _ role: String?) -> Bool = {
            AXWriteCapabilityStore.shared.canConfirmDelivery(bundleID: $0, role: $1)
        }
    ) {
        self.focusQuery = focusQuery
        self.deliveryTrust = deliveryTrust
        ledger = ExpansionLedger(defaults: defaults)
        hid = HIDKeyPoster.shared
        ax = AXTextWriter.shared
        self.verifier = verifier
        self.clipboard = clipboard
        eraser = EraseExecutor.shared
        timing = InjectTimingStore.shared
        self.selectionConfirmer = selectionConfirmer
        self.keepRefusedReplacement = keepRefusedReplacement
    }

    /// Localization key (Permissions.strings) of the hint shown when secure clipboard paste cannot
    /// confirm delivery under Secure Input — the concealed payload stays on the pasteboard for a
    /// manual ⌘V.
    public static let secureClipboardManualPasteHintKey = "inject.secureClipboardManualPaste"

    /// Optional UI hook when secure clipboard paste leaves the payload for manual ⌘V.
    public var onSecureClipboardManualPasteHint: (() -> Void)?

    /// Localization keys (Permissions.strings) of the toast shown when a replace is refused
    /// because its selection was gone: with the result copied to the clipboard, and without.
    public static let selectionReplaceRefusedHintKey = "inject.selectionReplaceRefused"
    public static let selectionReplaceRefusedNoCopyHintKey = "inject.selectionReplaceRefusedNoCopy"

    /// Optional UI hook when a replace was refused rather than pasted beside the original.
    /// `copied` says whether the payload made it onto the clipboard.
    public var onSelectionReplaceRefused: ((_ copied: Bool) -> Void)?

    /// Localization keys (Permissions.strings) of the toast shown when a replace's ⌘V went out but
    /// the result may not be in the field — read back unchanged, or never posted: with the result
    /// kept on the clipboard, and without.
    public static let replaceNotLandedHintKey = "inject.replaceNotLanded"
    public static let replaceNotLandedNoCopyHintKey = "inject.replaceNotLandedNoCopy"

    /// Optional UI hook for the above. Separate from `onSelectionReplaceRefused` because the
    /// sentence differs: that one says the selection changed, which here is not what was seen.
    public var onReplaceNotLanded: ((_ copied: Bool) -> Void)?

    private let selectionConfirmer: SelectionReplacementGuard.Confirmer
    /// Resolves the focused element asynchronously. The live query in production; a test scripts
    /// it to see what the entry gate is shown after a confirm that waited.
    private let focusQuery: (@escaping (AXContextChecker.FocusQueryResult) -> Void) -> Void
    /// Where a refused replace's already-generated payload is kept. Returns whether it was kept.
    private let keepRefusedReplacement: (String) -> Bool

    // MARK: - Entry points

    /// Async inject on a dedicated queue. Calls `completion` with the terminal outcome only after
    /// clipboard restore settles (or immediately when no pasteboard path was used). Never blocks
    /// the event-tap run loop.
    ///
    /// §8.2: `swallowed` is the one description of the key the event tap ate on this inject's
    /// behalf; the four-parameter legacy list it replaced is gone.
    public func inject(
        snippet: SnippetModel,
        triggerLength: Int,
        swallowed: SwallowedKey,
        clipboardOverride: String? = nil,
        lastEventCharacterCount: Int = 1,
        plan: InjectionPlan? = nil,
        terminator: String = "",
        eraseCountOverride: Int? = nil,
        erasePlan: ErasePlan? = nil,
        preResolvedText: String? = nil,
        preResolvedCursorOffset: Int? = nil,
        trailingKeys: [String] = [],
        snippetLookup: ((String) -> String?)? = nil,
        secureClipboardPaste: Bool = false,
        eraseCaretVouched: Bool = true,
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        /// §2.2: where the target identity comes from. A typed expansion hands over the element its
        /// expand gate already resolved; explicit inserts resolve it here.
        targetFocus: FocusedElementSource = .live,
        /// Set when this delivery must *replace* a selection read earlier rather than insert at
        /// the caret. The selection is confirmed (or put back) on the live field before anything
        /// is posted, and the delivery is refused rather than pasted beside the original.
        replacingSelection: SelectionReplacement? = nil,
        completion: InjectionCompletion? = nil
    ) {
        enqueueInjection(
            snippet: snippet, triggerLength: triggerLength, swallowed: swallowed,
            clipboardOverride: clipboardOverride, lastEventCharacterCount: lastEventCharacterCount,
            plan: plan, terminator: terminator, eraseCountOverride: eraseCountOverride,
            erasePlan: erasePlan, preResolvedText: preResolvedText,
            preResolvedCursorOffset: preResolvedCursorOffset, trailingKeys: trailingKeys,
            snippetLookup: snippetLookup, secureClipboardPaste: secureClipboardPaste,
            eraseCaretVouched: eraseCaretVouched, shouldContinue: shouldContinue, targetFocus: targetFocus,
            replacingSelection: replacingSelection,
            completion: completion
        )
    }

    private func enqueueInjection(
        snippet: SnippetModel,
        triggerLength: Int,
        swallowed: SwallowedKey,
        clipboardOverride: String? = nil,
        lastEventCharacterCount: Int = 1,
        plan: InjectionPlan? = nil,
        terminator: String = "",
        eraseCountOverride: Int? = nil,
        erasePlan: ErasePlan? = nil,
        preResolvedText: String? = nil,
        preResolvedCursorOffset: Int? = nil,
        trailingKeys: [String] = [],
        snippetLookup: ((String) -> String?)? = nil,
        secureClipboardPaste: Bool = false,
        eraseCaretVouched: Bool = true,
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        targetFocus: FocusedElementSource = .live,
        purpose: InjectionPurpose = .expansion,
        replacingSelection: SelectionReplacement? = nil,
        completion: InjectionCompletion? = nil
    ) {
        let operation = InjectCompletionGuard(shouldContinue: shouldContinue)
        let revision = ledger.claim(operation, consumingUndo: purpose.consumesUndo)
        let target: PasteboardBroker.PasteTarget
        switch purpose {
        case .expansion: target = PasteboardBroker.PasteTarget.capture(focus: targetFocus)
        case .undo(let attempt): target = attempt.target
        }
        injectQueue.async {
            // Prefer the fully-specified plan. Fall back to count-only planning for callers that
            // cannot supply the matched text (tests, Test Expansion Lab, physical Hangul overrides);
            // those degrade to `.unavailable` in the precondition guard rather than blocking.
            let resolvedPlan: ErasePlan
            if let erasePlan {
                resolvedPlan = erasePlan
            } else if let eraseCountOverride {
                resolvedPlan = .counted(eraseCountOverride)
            } else {
                resolvedPlan = .counted(
                    EraseExecutor.eraseCountForMatch(
                        triggerUTF16Length: triggerLength,
                        terminator: terminator,
                        swallowedFinalKey: swallowed.didSwallow,
                        lastEventCharacterCount: lastEventCharacterCount
                    )
                )
            }

            // §1.3: `injectQueue` is serial and `group.wait()` had no timeout. One inject path that
            // failed to call its completion — most plausibly the fill-in panel being closed by
            // another route — blocked this queue forever *and* left `EventTapEngine._isExpanding`
            // set, so every keystroke was passed straight through. DevType stopped expanding until
            // relaunch, silently, with no log line. Both halves are now bounded and logged.
            let group = DispatchGroup()
            let completionGuard = operation
            group.enter()

            let request = InjectRequest(
                snippet: snippet,
                erasePlan: resolvedPlan,
                clipboardOverride: clipboardOverride,
                plan: plan,
                swallowed: swallowed,
                preResolvedText: preResolvedText,
                preResolvedCursorOffset: preResolvedCursorOffset,
                trailingKeys: trailingKeys,
                snippetLookup: snippetLookup,
                secureClipboardPaste: secureClipboardPaste,
                eraseCaretVouched: eraseCaretVouched,
                operation: operation, inputRevision: revision, target: target, purpose: purpose,
                replacing: replacingSelection, replacesSelection: replacingSelection != nil
            )
            DispatchQueue.main.async {
                self.injectOnMain(request) { outcome in
                    let invocation = completionGuard.markCompleted(outcome)
                    if invocation == 1 {
                        group.leave()
                    } else {
                        // §1.3: the other way a completion corrupts this queue — leaving a
                        // DispatchGroup twice traps, so this must be caught rather than forwarded.
                        DevTypeLog.inject.error(
                            "[Inject] §1.3 inject completion invoked \(invocation, privacy: .public)× — ignoring the duplicate (an inject path is calling completion on more than one exit)"
                        )
                    }
                    if completionGuard.didTimeOut {
                        DevTypeLog.inject.error(
                            "[Inject] §1.3 inject completed after the watchdog already fired — expansion state was force-cleared"
                        )
                    }
                }
            }

            if group.wait(timeout: .now() + InjectTiming.injectCompletionTimeout) == .timedOut {
                completionGuard.markTimedOut()
                DevTypeLog.inject.error(
                    "[Inject] §1.3 watchdog: inject did not complete within \(InjectTiming.injectCompletionTimeout, privacy: .public)s — releasing the inject queue and force-clearing expansion state"
                )
                PermissionCoordinator.shared.recordInjectOutcome(
                    .failedSilent,
                    refuseContext: nil,
                    path: "watchdogTimeout"
                )
            }
            // Runs on either exit: the caller's completion is what clears `isExpanding`, so it must
            // not be conditional on the inject having finished. A missing terminal callback is
            // itself a failure, and the watchdog path remains explicit rather than looking like a
            // successful completion.
            completion?(completionGuard.terminalOutcome ?? .failedSilent)
        }
    }

    /// Restores a swallowed trigger key after refuse. Prefers HID post; falls back to AX insert.
    /// Call while `EventTapEngine.isExpanding` so the tap does not rematch the reinjected key.
    @discardableResult
    public func reinjectSwallowedKey(_ swallowed: SwallowedKey) -> Bool {
        guard swallowed.hasPayload else { return false }

        if CGPreflightPostEventAccess() {
            if hid.postUnicodeKeyEvent(
                unicode: swallowed.unicode,
                keyCode: CGKeyCode(truncatingIfNeeded: swallowed.keyCode),
                flags: swallowed.flags
            ) {
                return true
            }
        }

        // AX-only hosts: insert the swallowed character at the caret (no Post Events). Live on
        // purpose: a refused key goes back wherever the user now is, which is what typing it would do.
        if !swallowed.unicode.isEmpty {
            return ax.attemptAXDirectInjection(text: swallowed.unicode, focus: .live)
        }
        return false
    }

    // MARK: - §3.1 Undo

    /// The last delivered expansion, if any. Consumed when undo is claimed or invalidated.
    public var lastExpansion: LastExpansion? {
        ledger.record
    }

    public func canUndoLastExpansion(now: Date = Date()) -> Bool {
        ledger.canUndo(now: now, frontmostPID: EventTapEngine.shared.frontmostContext.processID)
    }

    /// Claims one fresh record on the tap thread; no AX or AppKit calls occur here.
    /// False leaves the original backspace untouched. Accepted work still needs live target,
    /// input, permission and cancellation checks before each mutation on the main thread.
    @discardableResult
    public func undoLastExpansion(now: Date = Date(), heldBackspace: SwallowedKey? = nil) -> Bool {
        guard let attempt = takeUndoAttempt(
            now: now, frontmostPID: EventTapEngine.shared.frontmostContext.processID
        ) else { return false }
        DispatchQueue.main.async {
            self.performUndo(attempt, heldBackspace: heldBackspace)
        }
        return true
    }

    func takeUndoAttempt(now: Date, frontmostPID: pid_t?) -> UndoAttempt? {
        ledger.takeUndoAttempt(now: now, frontmostPID: frontmostPID)
    }

    func undoAttemptIsCurrent(_ attempt: UndoAttempt) -> Bool {
        ledger.undoAttemptIsCurrent(attempt)
    }

    /// Caret changes also revoke an undo already dispatched to main.
    public func clearLastExpansion() {
        ledger.invalidateUndo()
    }

    public func clearLastExpansion(ifInjectedTextIs text: String) {
        ledger.invalidateUndo(ifInjectedTextIs: text)
    }

    /// §3.1: input landed in the field after the recorded expansion — a real keystroke observed by
    /// the tap, or characters a type-ahead replay posted. Cheap no-op while no record exists, so
    /// the tap's hot path can call it unconditionally.
    ///
    /// This count is what makes a *blind* undo (AX-opaque field) honest: with zero events the
    /// caret provably still sits right after `injectedText` (clicks clear the record outright),
    /// so erasing `injectedText` backwards from the caret is well-founded. With any events, the
    /// geometry is unknowable without AX and the undo must refuse instead of guessing — guessing
    /// is the "Sch`slm" corruption in hosts where no precondition read can catch it.
    public func noteInputAfterExpansion(units: Int = 1) {
        ledger.noteInputAfterExpansion(units: units)
    }

    // MARK: - §3.1d Delivery input window

    /// Opens the delivery-input window for one expansion. Called when the tap claims the inject
    /// critical section — before any key can pass through that delivery.
    ///
    /// Increments outside a delivery are discarded by the next `beginDeliveryWindow()`.
    /// During delivery, the counter guards both erases and the eventual undo record.
    public func beginDeliveryWindow() {
        ledger.beginDeliveryWindow()
    }

    /// One real, field-touching event was observed while an expansion is being delivered.
    /// See `ExpansionLedger`'s delivery count for why this must poison the record's blind-undo
    /// premise.
    public func noteDeliveryInput(units: Int = 1) {
        ledger.noteDeliveryInput(units: units)
    }

    /// The chord that just accepted an AI result, noted before the delivery it starts is claimed.
    /// See `DeliveryChord`: only its autorepeat, only while that delivery is in flight.
    public func noteAcceptChord(_ chord: DeliveryChord) {
        ledger.noteAcceptChord(chord)
    }

    /// Whether a key-repeat of `chord` is the continuation of the press that started the delivery
    /// in flight. The tap swallows such a repeat instead of passing it to the field and moving the
    /// input revision: the press that began the delivery was consumed by the panel, and a repeat
    /// that reached the field would be real input the delivery could not account for.
    func isRepeatOfDeliveryChord(_ chord: DeliveryChord) -> Bool {
        ledger.isDeliveryChord(chord)
    }

    /// Invalidates queued work as well as callbacks already scheduled on main.
    public func cancelCurrentInjection() {
        ledger.cancelCurrent()
    }

    /// The operation half of `operationIsCurrent` — superseded, cancelled, timed out, the caller's
    /// own predicate, and (unless allowed) trust and Secure Input. Issues no focus query, so a
    /// caller that already holds a fresh focus reading compares the target against that instead.
    private func operationStateIsCurrent(
        _ operation: InjectCompletionGuard, revision: UInt64,
        allowSecureInput: Bool = false, observationOnly: Bool = false
    ) -> Bool {
        ledger.isCurrent(operation, revision: revision)
            && operation.allowsContinuation(observationOnly: observationOnly)
            && (allowSecureInput || (AXContextChecker.shared.isProcessTrusted()
                && !AXContextChecker.isSecureEventInputEnabledLive()))
    }

    /// §2.2: a documented re-check — the target half is a live `PasteTarget.liveMismatch`.
    private func operationIsCurrent(
        _ operation: InjectCompletionGuard, revision: UInt64, target: PasteboardBroker.PasteTarget,
        allowSecureInput: Bool = false, observationOnly: Bool = false,
        checkElement: Bool = true, checkRange: Bool = false
    ) -> Bool {
        operationStateIsCurrent(operation, revision: revision, allowSecureInput: allowSecureInput,
                                observationOnly: observationOnly)
            && target.isCurrent(checkRange: checkRange, checkElement: checkElement)
    }

    private func canContinue(
        _ context: InjectContext,
        observationOnly: Bool = false,
        phase: PasteboardBroker.SelectionRangeGate = .beforeMutation,
        checkRange: Bool = false
    ) -> Bool {
        operationIsCurrent(
            context.operation, revision: context.inputRevision, target: context.target,
            observationOnly: observationOnly,
            checkElement: PasteboardBroker.verifyFocusedElement(role: context.focusedRole, phase: phase),
            checkRange: checkRange
        )
    }

    /// Typed expansion with a vouched caret, and not a selection replace. Undo and voice pass
    /// the other values on purpose and must not follow an element swap.
    private func allowsEraseRetarget(_ request: InjectRequest) -> Bool {
        guard request.eraseCaretVouched, !request.replacesSelection else { return false }
        if case .expansion = request.purpose { return true }
        return false
    }

    /// The continue-check for everything after the erase: the plain check, and — only when that
    /// fails — the same vouched-replacement policy the erase and the verifier use. True means the
    /// work may go on against `context.target`, which `adoptVouchedContinuation` has re-pointed at
    /// the replacement when it was one. False leaves the refusal it stashed for the caller to record.
    private func followsVouchedReplacement(_ context: InjectContext) -> Bool {
        if canContinue(context, phase: .afterMutation) { return true }
        switch adoptVouchedContinuation(
            context, rangeGate: .afterMutation, checkRange: false, continuation: .beforeInsertion
        ) {
        case .proceed, .retarget: return true
        case .refuse: return false
        }
    }

    /// What the paste is offered when its captured control is no longer focused: the control this
    /// inject now follows, if — and only if — the continuation policy vouches for it.
    private func vouchedPasteTarget(_ context: InjectContext) -> PasteboardBroker.PasteTarget? {
        followsVouchedReplacement(context) ? context.adopted.target : nil
    }

    /// Whether the field now holds exactly what the posted backspaces should have left, compared
    /// with the picture taken before the first one — see `EraseContinuation.partialEraseLanded`.
    private func partialEraseLanded(_ context: InjectContext, posted: Int) -> Bool {
        guard let element = context.focusedElement else { return false }
        return EraseContinuation.partialEraseLanded(
            anchor: context.adopted.eraseAnchor,
            live: eraseFieldPicture(element),
            expectedText: context.erasePlan.expectedText,
            caseInsensitive: context.erasePlan.caseInsensitive,
            posted: posted
        )
    }

    /// Whether the field shows part, but not yet all, of the deletion `posted` authorizes — see
    /// `EraseContinuation.partialEraseMayLag`.
    private func partialEraseMayLag(_ context: InjectContext, posted: Int) -> Bool {
        guard let element = context.focusedElement else { return false }
        return EraseContinuation.partialEraseMayLag(
            anchor: context.adopted.eraseAnchor,
            live: eraseFieldPicture(element),
            expectedText: context.erasePlan.expectedText,
            caseInsensitive: context.erasePlan.caseInsensitive,
            posted: posted
        )
    }

    /// `canContinue` failed, or is about to be asked again from a closure that must not refuse
    /// on its own. Returns `.retarget` only after the adopted box names the element this call
    /// just read. `.proceed` means a fresh reading matches again. `.refuse` stashes the label
    /// the caller records — this method does not record it, so a closure that only needs a Bool
    /// cannot double-refuse.
    private func adoptVouchedContinuation(
        _ context: InjectContext,
        rangeGate: PasteboardBroker.SelectionRangeGate,
        checkRange: Bool,
        continuation: EraseContinuationPhase,
        removedGraphemes: Int = 0
    ) -> EraseContinuationDecision {
        let revisionCurrent = ledger.isCurrent(context.operation, revision: context.inputRevision)
        let block = context.operation.continuationBlock()
        let secureInputBlocked = AXContextChecker.isSecureEventInputEnabledLive()
        let axUntrusted = !AXContextChecker.shared.isProcessTrusted()
        let checkElement = PasteboardBroker.verifyFocusedElement(role: context.focusedRole, phase: rangeGate)
        let element = (checkElement || checkRange) ? AXContextChecker.shared.focusedElement() : nil
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let mismatch = context.target.mismatch(
            observing: element, pid: pid, checkRange: checkRange, checkElement: checkElement
        )
        let allows = allowsEraseRetarget(context.request)
        let operationBlocked = !revisionCurrent || block != nil || secureInputBlocked || axUntrusted
        let elementOrRange = mismatch == .elementChanged || mismatch == .rangeChanged
        var livePrecondition: ErasePreconditionResult?
        var liveRole: String?
        var reading: EraseFieldReading?
        var deletionMatched = false
        var deletionLagging = false
        var identityContradicted = false
        if !operationBlocked, allows, elementOrRange {
            // Read once, for every phase: the live control's published identity against the one
            // this inject started in. A different control at the same place passes the text and
            // frame evidence below, so this is checked ahead of all of it.
            var liveAttributes = ControlIdentity.Attributes.none
            if mismatch == .elementChanged, let element {
                AXContextChecker.applyMessagingTimeout(to: element)
                liveAttributes = verifier.controlAttributes(of: element)
                identityContradicted = ControlIdentity.conflict(context.adopted.baseline, liveAttributes) != nil
            }
            switch continuation {
            case .beforeErase:
                if let element {
                    liveRole = AXContextChecker.shared.focusedElementRole(element: element)
                    // A secure field or a non-text role is not read. The voucher would be a
                    // comparison against that control's value, and a match must not retarget there.
                    if ControlIdentity.roleAllowsInsertionRetarget(liveRole) {
                        livePrecondition = EraseContinuation.substantivePrecondition(
                            eraser.evaluateErasePrecondition(
                                plan: context.erasePlan,
                                focus: .resolved(element),
                                retryOnMismatch: false,
                                insertionPointFollowsExpectedText: context.eraseCaretVouched,
                                intent: context.purpose.eraseIntent
                            ),
                            expectedText: context.erasePlan.expectedText
                        )
                    }
                } else {
                    livePrecondition = .unavailable("no focused element")
                }
            case .beforeInsertion, .duringErase:
                liveRole = element.flatMap { AXContextChecker.shared.focusedElementRole(element: $0) }
                if mismatch == .elementChanged, ControlIdentity.roleAllowsInsertionRetarget(liveRole),
                   let element {
                    let live = eraseFieldPicture(element, attributes: liveAttributes)
                    let maxRemoved = continuation == .duringErase
                        ? removedGraphemes
                        : (context.erasePlan.expectedText?.count ?? 0)
                    deletionMatched = EraseContinuation.deletionConfirms(
                        phase: continuation,
                        anchor: context.adopted.eraseAnchor,
                        live: live,
                        expectedText: context.erasePlan.expectedText,
                        caseInsensitive: context.erasePlan.caseInsensitive,
                        maxRemovedGraphemes: maxRemoved
                    )
                    if continuation == .beforeInsertion {
                        deletionLagging = EraseContinuation.deletionIsLagging(
                            anchor: context.adopted.eraseAnchor,
                            live: live,
                            expectedText: context.erasePlan.expectedText,
                            caseInsensitive: context.erasePlan.caseInsensitive
                        )
                    }
                    reading = EraseContinuation.fieldReading(
                        expected: context.erasePlan.expectedText,
                        value: live.value,
                        caretLocation: live.caretLocation,
                        selectionLength: live.selectionLength,
                        caseInsensitive: context.erasePlan.caseInsensitive
                    )
                }
            }
        }
        let facts = EraseContinuationFacts(
            phase: continuation,
            revisionCurrent: revisionCurrent,
            continuationBlock: block,
            secureInputBlocked: secureInputBlocked,
            axUntrusted: axUntrusted,
            mismatch: mismatch,
            allowsRetarget: allows,
            deletionMatched: deletionMatched,
            livePrecondition: livePrecondition,
            liveRole: liveRole,
            fieldReading: reading,
            deletionLagging: deletionLagging,
            identityContradicted: identityContradicted
        )
        let decision = EraseContinuation.decide(facts)
        context.adopted.lastRefusalMayClear = false
        switch decision {
        case .proceed:
            context.adopted.lastRefusal = nil
        case .retarget:
            guard let element else {
                let refusal = EraseContinuation.unadoptedRefusal(continuation, mismatch)
                context.adopted.lastRefusal = refusal
                return .refuse(refusal)
            }
            let role = liveRole ?? AXContextChecker.shared.focusedElementRole(element: element)
            // `decide` already requires this. The second check is the adopt itself: a retarget
            // that arrived without a text-field role does not get written into the box.
            guard ControlIdentity.roleAllowsInsertionRetarget(role) else {
                let refusal = EraseContinuation.unadoptedRefusal(continuation, mismatch)
                context.adopted.lastRefusal = refusal
                return .refuse(refusal)
            }
            let range = DeliveryVerifier.selectedRange(for: element)
            context.adopted.target = PasteboardBroker.PasteTarget(pid: pid, element: element, range: range)
            context.adopted.element = element
            context.adopted.role = role
            context.adopted.lastRefusal = nil
        case .refuse(let refusal):
            context.adopted.lastRefusal = refusal
            context.adopted.lastRefusalMayClear = EraseContinuation.mayClearOnReread(facts)
        }
        return decision
    }

    /// Value, caret, selection, and screen frame of one element. The timeout is the same bound
    /// the undo read uses: a hung field must not stall the backspace loop for the default AX
    /// timeout. Called on the can-continue path once, to remember the field before any key, and
    /// again only when that continue-check has already failed.
    ///
    /// `attributes` is what the caller already knows the control publishes: the anchor passes the
    /// baseline read before the first key, a live read passes the attributes it just took. Without
    /// one, the element is asked.
    private func eraseFieldPicture(
        _ element: AXUIElement, attributes: ControlIdentity.Attributes? = nil
    ) -> EraseContinuation.EraseFieldPicture {
        AXContextChecker.applyMessagingTimeout(to: element)
        let observation = verifier.focusedTextObservation(for: element)
        return EraseContinuation.EraseFieldPicture(
            value: observation.value,
            caretLocation: observation.caretLocation,
            selectionLength: observation.selectedRange?.length,
            frame: verifier.controlFrame(of: element),
            attributes: attributes ?? verifier.controlAttributes(of: element)
        )
    }

    /// Internal test seam for the input-revision gate every post-erase continue-check consults:
    /// claims an operation the way an inject does, then answers whether it is still current.
    func claimOperationForTesting() -> (operation: InjectCompletionGuard, revision: UInt64) {
        let operation = InjectCompletionGuard()
        return (operation, ledger.claim(operation, consumingUndo: false))
    }

    func operationIsCurrentForTesting(_ operation: InjectCompletionGuard, revision: UInt64) -> Bool {
        ledger.isCurrent(operation, revision: revision)
    }

    /// Internal test reader for the delivery-window counter. Not public API.
    var deliveryInputUnitsForTesting: Int {
        ledger.currentDeliveryInputUnits
    }

    /// Re-check after asynchronous AX retries and immediately before erase. Clicks and
    /// pass-through keys already feed this counter through the event tap.
    func eraseContextIsCurrent(
        inputUnits: Int,
        targetPID: pid_t?,
        frontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
    ) -> Bool {
        guard let targetPID,
              frontmostPID == targetPID else { return false }
        return ledger.deliveryInputUnits(equal: inputUnits)
    }

    /// Reads AXValue + caret + selection length in one snapshot for the undo path. Returns all
    /// nils when unreadable. One consistent read: the precondition evaluation and the widening
    /// must judge the *same* field state, not two reads that an in-flight edit can split.
    private func readFieldForUndo() -> (value: String?, caret: Int?, selection: Int?) {
        guard let element = AXContextChecker.shared.focusedElement() else { return (nil, nil, nil) }
        AXContextChecker.applyMessagingTimeout(to: element)

        var value: String?
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success {
            value = valueRef as? String
        }
        var caret: Int?
        var selection: Int?
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range) {
                caret = range.location
                selection = range.length
            }
        }
        return (value, caret, selection)
    }

    private func finishRefusedUndo(
        _ reason: String, path: String, attempt: UndoAttempt, heldBackspace: SwallowedKey?
    ) {
        let safeReason = PermissionCoordinator.sanitizedRefusalReason(reason, path: path)
        PermissionCoordinator.shared.recordInjectOutcome(.refused(safeReason), refuseContext: nil, path: path)
        guard ExpansionUndoPolicy.classifyUndoExit(accepted: false, heldBackspace: heldBackspace)
                == .refusedWithBackspaceReturned, undoAttemptIsCurrent(attempt),
              attempt.target.isCurrent(checkRange: false),
              !AXContextChecker.isSecureEventInputEnabledLive(), CGPreflightPostEventAccess() else { return }
        if !hid.postUnicodeKeyEvent(unicode: "\u{7F}", keyCode: CGKeyCode(kVK_Delete), flags: []) {
            PermissionCoordinator.shared.recordInjectOutcome(.failedSilent, refuseContext: nil, path: "undoKeyReturn")
        }
    }

    private func performUndo(_ attempt: UndoAttempt, heldBackspace: SwallowedKey? = nil) {
        guard attempt.record.isFresh(), undoAttemptIsCurrent(attempt), attempt.target.isCurrent(checkRange: false),
              AXContextChecker.shared.isProcessTrusted(), !AXContextChecker.isSecureEventInputEnabledLive() else {
            finishRefusedUndo("context changed", path: "undoContextChanged", attempt: attempt, heldBackspace: nil)
            return
        }
        let field = readFieldForUndo()
        let record = attempt.record
        let plan: ErasePlan
        let restore: String
        switch ExpansionUndoPolicy.prepareUndo(record: record, originalRange: attempt.target.range,
                                inputEvents: attempt.inputEvents, field: field) {
        case .replacement(let preparedPlan, let text):
            plan = preparedPlan
            restore = text
        case .refused(let reason):
            finishRefusedUndo(reason.rawValue, path: reason.rawValue, attempt: attempt, heldBackspace: heldBackspace)
            return
        }
        // All mutation, timeout, cancellation, host capability learning, clipboard residency,
        // recovery and delivery evidence now have one owner. Undo never creates another undo.
        let target = PasteboardBroker.PasteTarget(
            pid: attempt.target.pid, element: attempt.target.element,
            range: field.caret.flatMap { caret in
                field.selection.map { NSRange(location: caret, length: $0) }
            }
        )
        let prepared = UndoAttempt(record: record, target: target, inputEvents: attempt.inputEvents,
                                   inputRevision: attempt.inputRevision, generation: attempt.generation)
        enqueueInjection(
            snippet: SnippetModel(title: "Undo expansion", triggerKeyword: "", replacementText: restore),
            triggerLength: 0, swallowed: .notSwallowed, erasePlan: plan, preResolvedText: restore,
            eraseCaretVouched: false,
            shouldContinue: { self.undoAttemptIsCurrent(attempt) }, purpose: .undo(prepared)
        )
    }

    // MARK: - Inject (main thread)

    /// What one inject was asked to do, fixed at enqueue time. §8.2: one value through
    /// `injectOnMain` and its focus continuation instead of fifteen parameters.
    private struct InjectRequest {
        let snippet: SnippetModel
        let erasePlan: ErasePlan
        let clipboardOverride: String?
        let plan: InjectionPlan?
        let swallowed: SwallowedKey
        let preResolvedText: String?
        let preResolvedCursorOffset: Int?
        let trailingKeys: [String]
        let snippetLookup: ((String) -> String?)?
        let secureClipboardPaste: Bool
        /// False when the caller cannot promise the caret still sits immediately after
        /// `erasePlan.expectedText`. The expand path can (the tap just watched the trigger keys
        /// land); voice dictation cannot — segments arrive seconds apart and the user is free to
        /// click elsewhere in between. See `ErasePreconditionChecker.evaluate`.
        let eraseCaretVouched: Bool
        let operation: InjectCompletionGuard
        let inputRevision: UInt64
        let target: PasteboardBroker.PasteTarget
        let purpose: InjectionPurpose
        /// Non-nil until `injectWithFocus` has confirmed the selection; the confirmed request is
        /// re-entered with this cleared, so the check runs exactly once per inject.
        let replacing: SelectionReplacement?
        /// Stays true after `selectionConfirmed()` clears `replacing`. A confirmed replace must
        /// not borrow the typed-expansion retarget: the payload is an already-generated result,
        /// and a replaced AX node is not evidence the selection is still the one that was read.
        let replacesSelection: Bool
        /// `.waivedBeforeErase` once `BoardHoldOff` spent its budget with a previous payload still
        /// unread: this inject publishes over it rather than wait again after the erase.
        var publicationGate: PasteboardBroker.PublicationGate = .wait

        /// The request after its selection was confirmed. `target` is recaptured when the guard
        /// had to re-select: the range moved on purpose, and a range-gated host would otherwise
        /// refuse the paste as "selection changed" against the collapsed caret captured earlier.
        func selectionConfirmed(target newTarget: PasteboardBroker.PasteTarget? = nil) -> InjectRequest {
            copy(target: newTarget ?? target, replacing: nil)
        }

        /// The same request aimed at another element, its selection still to be confirmed — for a
        /// field whose node was replaced while the confirm waited.
        func retargeted(to newTarget: PasteboardBroker.PasteTarget) -> InjectRequest {
            copy(target: newTarget, replacing: replacing)
        }

        private func copy(target newTarget: PasteboardBroker.PasteTarget, replacing newReplacing: SelectionReplacement?) -> InjectRequest {
            InjectRequest(
                snippet: snippet, erasePlan: erasePlan, clipboardOverride: clipboardOverride,
                plan: plan, swallowed: swallowed, preResolvedText: preResolvedText,
                preResolvedCursorOffset: preResolvedCursorOffset, trailingKeys: trailingKeys,
                snippetLookup: snippetLookup, secureClipboardPaste: secureClipboardPaste,
                eraseCaretVouched: eraseCaretVouched, operation: operation,
                inputRevision: inputRevision, target: newTarget, purpose: purpose,
                replacing: newReplacing, replacesSelection: replacesSelection,
                publicationGate: publicationGate
            )
        }
    }

    /// One inject's focus, shared by every copy of `InjectContext`. Escaping continue-closures
    /// copy the struct and would otherwise keep comparing against the element captured at the
    /// start, so a retarget written here is what the next `canContinue` and the next AX write see.
    /// Mutated on main only: the inject runs there, and the backspace post calls its guard there.
    private final class AdoptedInjectTarget {
        var target: PasteboardBroker.PasteTarget
        var element: AXUIElement?
        var role: String?
        /// The refusal the pre-write guard records. `canProceed` already made the decision; a
        /// second live read in the guard could name a different instant.
        var lastRefusal: EraseContinuationRefusal?
        /// Whether `lastRefusal` was a `.beforeInsertion` reading a second look may clear
        /// (`EraseContinuation.mayClearOnReread`). Set with the refusal from the same facts, so
        /// the caller never re-derives it from a different instant.
        var lastRefusalMayClear = false
        /// The field when the first backspace was authorized. Later deletion math stays against
        /// this picture; adopting a mid-erase node must not replace it with the field the
        /// deletes have already changed, or a different control would match itself.
        var eraseAnchor: EraseContinuation.EraseFieldPicture?
        /// What the control this inject started in published about itself, read before anything
        /// could swap its node. Never replaced by an adopt: the control a swap must be judged
        /// against is the one the user typed in, not the last replacement.
        let baseline: ControlIdentity.Attributes
        init(
            target: PasteboardBroker.PasteTarget, element: AXUIElement?, role: String?,
            baseline: ControlIdentity.Attributes = .none
        ) {
            self.target = target
            self.element = element
            self.role = role
            self.baseline = baseline
        }
    }

    /// Everything the main-thread inject needs after the gates have passed. §8.2: bundling these
    /// keeps the post-precondition continuation to one parameter instead of eleven.
    private struct InjectContext {
        let request: InjectRequest
        let snapshot: PermissionSnapshot
        /// Keep the optional: a bundle-less frontmost app must not be learned under the literal
        /// key "nil", which would then disable AX writes for every other bundle-less app.
        let frontBundleID: String?
        let frontPID: pid_t?
        let deliveryInputUnits: Int
        /// §2.2: the focused element resolved once at inject time and threaded through every AX
        /// read and write of this inject. `nil` when focus was missing or unreadable — the
        /// HID-only path, where nothing below may query AX for a substitute. Held by `adopted`
        /// so a vouched element swap is what later reads and writes use.
        let adopted: AdoptedInjectTarget
        let gateDecision: AXContextChecker.ExpandGateDecision

        var focusedElement: AXUIElement? { adopted.element }
        var focusedRole: String? { adopted.role }
        var snippet: SnippetModel { request.snippet }
        var erasePlan: ErasePlan { request.erasePlan }
        var clipboardOverride: String? { request.clipboardOverride }
        var plan: InjectionPlan? { request.plan }
        var swallowed: SwallowedKey { request.swallowed }
        var preResolvedText: String? { request.preResolvedText }
        var preResolvedCursorOffset: Int? { request.preResolvedCursorOffset }
        var trailingKeys: [String] { request.trailingKeys }
        var snippetLookup: ((String) -> String?)? { request.snippetLookup }
        var eraseCaretVouched: Bool { request.eraseCaretVouched }
        var operation: InjectCompletionGuard { request.operation }
        var inputRevision: UInt64 { request.inputRevision }
        var target: PasteboardBroker.PasteTarget { adopted.target }
        var purpose: InjectionPurpose { request.purpose }
        var replacesSelection: Bool { request.replacesSelection }
        var frontBundle: String { frontBundleID ?? "nil" }
    }

    /// Resolves focus once for the whole inject, then continues in `injectWithFocus`.
    ///
    /// §8.3: the asynchronous query keeps the `.cannotComplete` retry available here on main by
    /// scheduling it; it used to be a 30 ms `Thread.sleep` inside the query, stalling the tap.
    ///
    /// §2.2 — the focus-query budget of one inject:
    /// * **this resolution**, the only query whose answer the inject uses as its element. The
    ///   entry gate, IME probe, expand gate, erase guard, AX writes, delivery baseline and caret
    ///   placement all receive it instead of asking again;
    /// * **documented re-checks**, which compare the live focus against the captured target and
    ///   must stay live because they exist to catch the user moving: `PasteTarget.liveMismatch`
    ///   (every `canContinue` before a mutation, and `PasteboardBroker`'s pre-⌘V and
    ///   continuation checks) and `DeliveryVerifier.verifyFocusedTextDelivery` (each paste-hold
    ///   tick and the deferred re-verify);
    /// * **the erase guard's settle retry**, which re-resolves on purpose after a mismatch,
    ///   because the element held before the settle may be the stale one;
    /// * **a confirmed replace that waited**, which resolves again before re-entering, because
    ///   the focus it was handed predates the wait (see `confirmReplacementSelection`).
    private func injectOnMain(_ request: InjectRequest, completion: @escaping InjectionCompletion) {
        // Something is about to be erased, and a previous expansion's payload may still be waiting
        // to be read: the paste's own gate would hold *this* one after the erase, past the point
        // the held type-ahead gives up. Wait first, while the field is untouched — every gate
        // below (focus, entry, precondition) then runs after the wait. See `BoardHoldOff`.
        guard !request.erasePlan.isEmpty, !request.secureClipboardPaste else {
            focusQuery { focus in
                self.injectWithFocus(request, focus: focus, completion: completion)
            }
            return
        }
        BoardHoldOff.untilFree(
            remaining: { self.clipboard.publicationGateRemaining() },
            stillCurrent: {
                self.operationStateIsCurrent(request.operation, revision: request.inputRevision)
            },
            schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
            proceed: { waived in
                var request = request
                if waived {
                    request.publicationGate = .waivedBeforeErase
                    DevTypeLog.inject.notice(
                        "[Inject] previous payload still unread after the pre-erase budget — publishing over it"
                    )
                }
                self.focusQuery { focus in
                    self.injectWithFocus(request, focus: focus, completion: completion)
                }
            },
            abandon: {
                // Nothing was erased, so there is nothing to restore; the entry-gate refusal records
                // which condition ended the wait (input, cancellation, trust, Secure Input).
                self.refuseEntryGate(
                    operation: request.operation,
                    revision: request.inputRevision,
                    targetMismatch: nil,
                    allowSecureInput: false,
                    swallowed: request.swallowed,
                    completion: completion
                )
            }
        )
    }

    private func injectWithFocus(
        _ request: InjectRequest,
        focus: AXContextChecker.FocusQueryResult,
        completion: @escaping InjectionCompletion
    ) {
        let element = focus.element
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontBundleID = frontApp?.bundleIdentifier
        let focusedRole = element.flatMap { AXContextChecker.shared.focusedElementRole(element: $0) }
        let swallowed = request.swallowed
        // One reading of the target, shared by the decision below and by the label the refusal
        // reports. These used to be two readings taken at different moments under different
        // rules: the guard resolved the range gate inline, and `refuseEntryGate` — which could
        // not see it — took its own reading with the range gate off. So in an app whose AX
        // range is trusted (Notes, Xcode), a refusal *caused* by the caret moving re-checked
        // clean and was reported as `.unreproduced`, sending whoever read the report after a
        // condition that never fired. One reading cannot disagree with itself — and it is the
        // focus resolved above, so the gate does not pay a query of its own.
        let checkRange = PasteboardBroker.verifySelectionRange(
            bundleID: frontBundleID,
            role: focusedRole,
            phase: .beforeMutation
        )
        let targetMismatch = request.target.mismatch(
            observing: element,
            pid: frontApp?.processIdentifier,
            checkRange: checkRange
        )
        guard operationStateIsCurrent(request.operation, revision: request.inputRevision,
                                      allowSecureInput: request.secureClipboardPaste),
              targetMismatch == nil else {
            // Never a bare `completion(.refused(…))`: this gate drops a payload that is already
            // generated — an AI transform the model has finished, a voice segment already
            // dictated — and recording nothing made that loss invisible to the user *and* to the
            // diagnostic report, which then showed a successful transform with no inject attempt
            // beside it and no way to tell which condition fired.
            //
            // `allowKeyReplay: false`: the premise of this refusal is that the operation or the
            // target moved, so posting the swallowed key would type it into whatever is frontmost
            // now rather than into the field that was matched.
            refuseEntryGate(
                operation: request.operation,
                revision: request.inputRevision,
                targetMismatch: targetMismatch,
                allowSecureInput: request.secureClipboardPaste,
                swallowed: swallowed,
                completion: completion
            )
            return
        }
        // A replace pastes over whatever is selected *now*. The entry gate above only proves the
        // target has not moved since it was captured — and it was captured after the source app
        // came back to the front, by which time a host like Messages has already collapsed the
        // selection. So the selection itself is checked against the text that was read, here,
        // before any branch below can post ⌘V.
        if let replacement = request.replacing {
            confirmReplacementSelection(
                replacement, request: request, focus: focus, element: element, completion: completion
            )
            return
        }
        // Re-check Secure Input / IME / focus at inject time (may have changed since match).
        let snapshot = PermissionCoordinator.shared.cachedSnapshot

        // Probe IME only when focus is available — missing focus stays non-IME for the
        // explicit secure-clipboard intent (Chrome password fields often expose no AX focus).
        var hasIME = false
        if snapshot.canUseAX,
           AXContextChecker.shared.isProcessTrusted(),
           let element {
            hasIME = AXContextChecker.shared.hasActiveIMEMarkedText(element: element)
        }

        let allowSecureClipboard = AXContextChecker.mayAllowSecureClipboardPaste(
            intent: request.secureClipboardPaste,
            canPostEvents: snapshot.canPostEvents,
            eraseEmpty: request.erasePlan.isEmpty,
            hasIME: hasIME
        )

        if allowSecureClipboard {
            let operation = request.operation
            let revision = request.inputRevision
            let target = request.target
            injectSecureClipboardPasteOnMain(
                snippet: request.snippet,
                clipboardOverride: request.clipboardOverride,
                swallowed: swallowed,
                preResolvedText: request.preResolvedText,
                trailingKeys: request.trailingKeys,
                snippetLookup: request.snippetLookup,
                focus: .resolved(element),
                replacesSelection: request.replacesSelection,
                shouldContinue: { self.operationIsCurrent(operation, revision: revision, target: target, allowSecureInput: true) },
                operationIsCurrent: { self.operationStateIsCurrent(operation, revision: revision, allowSecureInput: true) },
                completion: completion
            )
            return
        }

        if AXContextChecker.isSecureEventInputEnabledLive() {
            let decision = AXContextChecker.shared.evaluateExpandGate(
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents,
                focus: focus
            )
            refuseInject(
                AXContextChecker.secureInputActiveReason,
                path: "gateSecureInput",
                swallowed: swallowed,
                refuseContext: .capture(
                    reason: AXContextChecker.secureInputActiveReason,
                    decision: decision
                ),
                completion: completion
            )
            return
        }

        let decision = AXContextChecker.shared.evaluateExpandGate(
            canUseAX: snapshot.canUseAX,
            canPostEvents: snapshot.canPostEvents,
            focus: focus
        )
        let deliveryInputUnits = ledger.currentDeliveryInputUnits
        let frontBundle = frontBundleID ?? "nil"
        let erasePlan = request.erasePlan
        // #region agent log
        TextInjectionPipeline.debugLogInject(
            hypothesisId: "M1",
            message: "injectOnMain gate",
            data: [
                "frontmostBundle": frontBundle,
                "shouldBlock": decision.shouldBlock,
                "reason": decision.reason,
                "focusedAvailable": decision.snapshot.focusedAvailable,
                "isSecure": decision.snapshot.isSecureField.map { $0 ? "true" : "false" } ?? "nil",
                "hasIME": decision.snapshot.hasIMEMarkedText.map { $0 ? "true" : "false" } ?? "nil",
                "eraseUTF16": erasePlan.utf16Count,
                "eraseBackspaces": erasePlan.backspaceCount,
                "triggerLen": request.snippet.triggerKeyword.utf16.count,
                "textLen": (request.preResolvedText ?? request.snippet.replacementText).utf16.count
            ]
        )
        // #endregion
        if decision.shouldBlock {
            refuseInject(
                decision.reason,
                path: "gateBlocked",
                swallowed: swallowed,
                refuseContext: .capture(reason: decision.reason, decision: decision),
                completion: completion
            )
            return
        }

        let context = InjectContext(
            request: request,
            snapshot: snapshot,
            frontBundleID: frontBundleID,
            frontPID: frontApp?.processIdentifier,
            deliveryInputUnits: deliveryInputUnits,
            adopted: AdoptedInjectTarget(
                target: request.target, element: element, role: focusedRole,
                // Only an inject that may follow a node swap ever compares it, so only that one
                // pays for the read. It is taken here, ahead of the erase, while the node is alive.
                baseline: allowsEraseRetarget(request)
                    ? element.map { verifier.controlAttributes(of: $0) } ?? .none : .none
            ),
            gateDecision: decision
        )

        // Backstop before anything destructive: if AX can read the field, the trigger must actually
        // be sitting left of the caret. A mismatch means our model of the field is wrong, and
        // erasing would eat the user's own text — refuse instead.
        //
        // §8.3: asynchronous, so the one-shot retry is available here (on main) without a 30 ms
        // `Thread.sleep` that would stall the event tap.
        let eraseCaretVouched = request.eraseCaretVouched
        let purpose = request.purpose
        eraser.evaluateErasePrecondition(plan: erasePlan, focus: .resolved(element),
                                          insertionPointFollowsExpectedText: eraseCaretVouched,
                                          intent: purpose.eraseIntent) { incoming in
            // One live re-check answers both questions two separate reads used to ask: the
            // operation is still current, and the target — with this host's range gate — has
            // not moved while the precondition may have waited out its settle. A failure here
            // is not yet a refusal: the same field's AX node (WebKit) or caret (a trusted app,
            // after the firing key) can change while the trigger is still at the caret. Only a
            // live `.ok` on that element may follow it. The captured element's reading is not
            // that voucher.
            let beforeEraseRangeCheck = PasteboardBroker.verifySelectionRange(
                bundleID: context.frontBundleID,
                role: context.focusedRole,
                phase: .beforeMutation
            )
            var eraseCheck = incoming
            if !self.canContinue(context, checkRange: beforeEraseRangeCheck) {
                switch self.adoptVouchedContinuation(
                    context,
                    rangeGate: .beforeMutation,
                    checkRange: beforeEraseRangeCheck,
                    continuation: .beforeErase
                ) {
                case .proceed:
                    break
                case .retarget:
                    eraseCheck = .ok
                case .refuse(let refusal):
                    self.refuseInject(
                        refusal.reason, path: refusal.path, swallowed: swallowed,
                        allowKeyReplay: false,
                        refuseContext: .capture(
                            reason: refusal.reason, decision: decision,
                            targetMismatch: refusal.recordedMismatch
                        ),
                        completion: completion
                    )
                    return
                }
            }
            // #region agent log
            if eraseCheck != .ok {
                let label: String
                switch eraseCheck {
                case .ok: label = "ok"
                case .unavailable(let why): label = "unavailable: \(why)"
                case .mismatch(let why): label = "mismatch: \(why)"
                }
                TextInjectionPipeline.debugLogInject(
                    hypothesisId: "M5",
                    message: "erase precondition",
                    data: [
                        "frontmostBundle": frontBundle,
                        "result": label,
                        "eraseUTF16": erasePlan.utf16Count,
                        "hasExpectedText": erasePlan.expectedText != nil
                    ]
                )
            }
            // #endregion
            if case .undo(let attempt) = request.purpose,
               let reason = ExpansionUndoPolicy.undoEraseRefusalReason(result: eraseCheck, inputEventsSinceExpansion: attempt.inputEvents) {
                let path: String
                if case .unavailable = eraseCheck { path = "undoUnverifiable" } else { path = "undo" }
                self.refuseInject(reason, path: path, swallowed: .notSwallowed, completion: completion)
                return
            }
            if case .mismatch(let why) = eraseCheck {
                DevTypeLog.inject.error(
                    "[Inject] erase precondition failed — \(why, privacy: .public)"
                )
                self.refuseInject(
                    "Erase precondition failed — \(why)",
                    path: "erasePrecondition",
                    swallowed: swallowed,
                    refuseContext: .capture(reason: "Erase precondition failed — \(why)", decision: decision),
                    completion: completion
                )
                return
            }
            self.performInject(context: context, eraseCheck: eraseCheck, completion: completion)
        }
    }

    /// Confirms a replace's selection on the live field, then re-enters `injectWithFocus` with the
    /// check cleared so every later gate runs exactly as it does for an insert.
    ///
    /// Re-entering re-runs the entry gate, but the gate compares `request.target` against the
    /// `focus` it is handed, and a confirm that waited (a settle, a re-select's read-back) hands it
    /// the focus resolved *before* the wait — or, when the confirmer refocused, the very element the
    /// target was just recaptured from. Either way the comparison is of a reading with itself, so it
    /// says nothing about the time the wait took. A confirm that waited therefore resolves focus
    /// afresh and re-enters with that, so the entry gate judges where focus is now; one that
    /// answered on its first reading has nothing to cover and keeps the focus it already has.
    private func confirmReplacementSelection(
        _ replacement: SelectionReplacement,
        request: InjectRequest,
        focus: AXContextChecker.FocusQueryResult,
        element: AXUIElement?,
        vouchedRetarget: Bool = false,
        completion: @escaping InjectionCompletion
    ) {
        let startedAt = Date()

        /// The payload is already generated — an AI result, a dictated rewrite. Refusing must not
        /// cost the user that work, so it goes to the clipboard for a manual ⌘V into a selection
        /// they can see.
        func refuse(_ refusal: SelectionReplacementGuard.Refusal, trail: SelectionReplacementGuard.Confirmer.Trail) {
            let payload = request.preResolvedText ?? request.snippet.replacementText
            let copied = keepRefusedReplacement(payload)
            // The roles are what tell "the host answered with the wrong element" apart from "the
            // right element answered blank" — the report cannot otherwise. `role` is the element
            // this inject started on; the trail names the one the settle ended on, which after a
            // refocus is a different element, and how many times it waited.
            let role = element.flatMap { AXContextChecker.shared.focusedElementRole(element: $0) } ?? "none"
            let confirmMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            DevTypeLog.inject.notice(
                "[Inject] replace refused — \(refusal.rawValue, privacy: .public); role=\(role, privacy: .public) \(trail.summary, privacy: .public) confirmMs=\(confirmMs, privacy: .public) result copied=\(copied, privacy: .public)"
            )
            refuseInject(
                refusal.reason,
                path: SelectionReplacementGuard.refusalPath,
                swallowed: request.swallowed,
                allowKeyReplay: false,
                completion: completion
            )
            onSelectionReplaceRefused?(copied)
        }

        selectionConfirmer.confirm(
            replacement, element: element,
            isCurrent: {
                self.operationStateIsCurrent(
                    request.operation, revision: request.inputRevision,
                    allowSecureInput: request.secureClipboardPaste
                )
            }
        ) { verdict in
            let confirmMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            switch verdict {
            case .confirmed(let reselected, let refocusedOn, let trail):
                var confirmed = request.selectionConfirmed()
                var focus = focus
                if reselected {
                    DevTypeLog.inject.notice(
                        "[Inject] replace: selection was lost on return to the source app — re-selected the original before pasting"
                    )
                }
                if trail.settles > 0 {
                    DevTypeLog.inject.info(
                        "[Inject] replace: selection confirmed after \(confirmMs, privacy: .public) ms; \(trail.summary, privacy: .public)"
                    )
                }
                if let refocusedOn {
                    // The focus this inject resolved had no element; the confirmer found one
                    // while the host settled, and every later gate must judge that one.
                    focus = .available(refocusedOn)
                }
                if reselected || refocusedOn != nil {
                    confirmed = request.selectionConfirmed(
                        target: PasteboardBroker.PasteTarget.capture(focus: .resolved(refocusedOn ?? element))
                    )
                }
                guard reselected || trail.settles > 0 else {
                    self.injectWithFocus(confirmed, focus: focus, completion: completion)
                    return
                }
                // Taken now, while the node the confirm just read is certainly alive: a node swap
                // during the wait below leaves nothing to measure the replacement against.
                let confirmedElement = confirmed.target.element
                let confirmedIdentity = confirmedElement.map { self.verifier.controlIdentity(of: $0) }
                self.focusQuery { live in
                    // Judged here rather than left to the entry gate, which would drop the
                    // generated payload; a replace that cannot land keeps it on the clipboard.
                    let moved = confirmed.target.mismatch(
                        observing: live.element,
                        pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                        checkRange: false
                    )
                    guard moved == nil else {
                        // WebKit swaps the focused text node under a selection change: same
                        // control, new element. That is the one move that is not the user's, and
                        // it is judged by `ControlIdentity`'s one same-control rule (same process,
                        // a text-entry role, the same on-screen frame, and no published identity
                        // attribute that disagrees) rather than a second one.
                        // Vouching proves the control, not the selection in it, so the replace is
                        // confirmed again on the new node — once: a second swap refuses.
                        if !vouchedRetarget, moved == .elementChanged,
                           let confirmedIdentity, let liveElement = live.element,
                           case let verdict = self.verifier.sameControlVerdict(
                               baseline: confirmedIdentity, live: liveElement
                           ), verdict.isSameControl {
                            DevTypeLog.inject.notice(
                                "[Inject] replace: the field's node was replaced while the confirm waited — confirming again on the replacement (\(verdict.label, privacy: .public))"
                            )
                            self.confirmReplacementSelection(
                                replacement,
                                request: request.retargeted(
                                    to: PasteboardBroker.PasteTarget.capture(focus: .resolved(liveElement))
                                ),
                                focus: live, element: liveElement, vouchedRetarget: true,
                                completion: completion
                            )
                            return
                        }
                        refuse(.focusMoved, trail: trail)
                        return
                    }
                    self.injectWithFocus(confirmed, focus: live, completion: completion)
                }
            case .unverified:
                DevTypeLog.inject.info(
                    "[Inject] replace: selection unreadable in an app read by copy — delivering unverified"
                )
                self.injectWithFocus(request.selectionConfirmed(), focus: focus, completion: completion)
            case .refused(let refusal, let trail):
                refuse(refusal, trail: trail)
            }
        }
    }

    private func performInject(
        context: InjectContext,
        eraseCheck: ErasePreconditionResult,
        completion: @escaping InjectionCompletion
    ) {
        // Element at entry. A vouched retarget writes `context.adopted` before the AX write,
        // and the `focus` read after that guard is the one those writes use.
        let initialFocus = FocusedElementSource.resolved(context.focusedElement)
        let swallowed = context.swallowed
        let erasePlan = context.erasePlan
        let frontBundle = context.frontBundle
        let canProceed = {
            if self.canContinue(context) { return true }
            switch self.adoptVouchedContinuation(
                context,
                rangeGate: .beforeMutation,
                checkRange: false,
                continuation: .beforeErase
            ) {
            case .proceed, .retarget:
                return true
            case .refuse:
                return false
            }
        }
        // After the erase the trigger is gone: a refusal here costs the user the trigger *and* the
        // expansion. So the check follows a replaced node the same way the erase did (one owner:
        // `EraseContinuation`, through `followsVouchedReplacement`) instead of re-pinning identity.
        let canProceedAfterMutation = {
            self.followsVouchedReplacement(context)
        }
        // How many times this closure has already returned true. `shouldContinue` runs before
        // each pair, so a failure is judged against keys already authorized, never against a
        // deletion this post has not sent. The anchor is `context.focusedElement`, the element
        // the box already accepted. A failed focus read is the replacement, and snapshotting
        // that read would let the replacement match itself.
        var postedBackspaces = 0
        let postingContinue: () -> Bool = {
            if self.canContinue(context, phase: .afterMutation) {
                if context.adopted.eraseAnchor == nil, let element = context.focusedElement {
                    context.adopted.eraseAnchor = self.eraseFieldPicture(element, attributes: context.adopted.baseline)
                }
                postedBackspaces += 1
                return true
            }
            if context.adopted.eraseAnchor == nil, let element = context.focusedElement {
                context.adopted.eraseAnchor = self.eraseFieldPicture(element, attributes: context.adopted.baseline)
            }
            guard context.adopted.eraseAnchor != nil else { return false }
            switch self.adoptVouchedContinuation(
                context,
                rangeGate: .afterMutation,
                checkRange: false,
                continuation: .duringErase,
                removedGraphemes: postedBackspaces
            ) {
            case .proceed, .retarget:
                postedBackspaces += 1
                return true
            case .refuse:
                return false
            }
        }

        if context.snippet.isImageSnippet {
            performImageInject(
                context: context, focus: initialFocus, beforeMutation: canProceed,
                afterMutation: canProceedAfterMutation, duringPost: postingContinue,
                completion: completion
            )
            return
        }

        let shellLike = AXContextChecker.shared.isFrontmostShellLikeContext(focus: initialFocus)
        guard let resolved = resolveText(context: context, completion: completion) else { return }
        let textToInject = resolved.text
        let cursorOffset = resolved.cursorOffset
        let keysToPress = resolved.trailingKeys
        let totalUTF16 = resolved.totalUTF16
        let needsCursor = InjectionPlanner.needsCursorHID(
            cursorOffset: cursorOffset,
            totalUTF16Length: totalUTF16
        )
        let isMultiLine = textToInject.contains(where: \.isNewline)

        let effectivePlan = context.plan ?? planner.plan(
            snapshot: context.snapshot,
            isTerminal: shellLike,
            needsCursorHID: needsCursor,
            isMultiLine: isMultiLine
        )

        // Shell-like + multi-line without Post: refuse (planner should already catch this).
        if shellLike, isMultiLine, !context.snapshot.canPostEvents {
            refuseInject(
                "Multi-line shell inject requires Post Events (clipboard paste)",
                path: "shellNoPostEvents",
                swallowed: swallowed,
                completion: completion
            )
            return
        }

        // #region agent log
        let planLabel: String
        switch effectivePlan {
        case .refuse: planLabel = "refuse"
        case .axOnly: planLabel = "axOnly"
        case .axPlusHID: planLabel = "axPlusHID"
        }
        TextInjectionPipeline.debugLogInject(
            hypothesisId: "M2",
            message: "injectOnMain plan",
            data: [
                "frontmostBundle": frontBundle,
                "shellLike": shellLike,
                "plan": planLabel,
                "isMultiLine": isMultiLine,
                "eraseUTF16": erasePlan.utf16Count,
                "eraseBackspaces": erasePlan.backspaceCount
            ]
        )
        // #endregion

        guard canProceed() else {
            let refusal = context.adopted.lastRefusal ?? EraseContinuationRefusal(
                path: "eraseContextChanged",
                reason: "Expansion cancelled — input or target application changed before erase",
                recordedMismatch: nil
            )
            refuseInject(
                refusal.reason,
                path: refusal.path, swallowed: swallowed,
                allowKeyReplay: false,
                refuseContext: .capture(
                    reason: refusal.reason,
                    decision: context.gateDecision,
                    targetMismatch: refusal.recordedMismatch
                ),
                completion: completion
            )
            return
        }

        // An unverifiable precondition cannot license writing through those same AX coordinates.
        // Also skip apps/roles known to report successful writes without mutating. Read after the
        // guard: a retarget may have replaced the element and the role.
        let focus = FocusedElementSource.resolved(context.focusedElement)
        let focusedRole = context.focusedRole
        var preferHID = eraseCheck.requiresHID || AXWriteCapabilityStore.shared.shouldSkipAXSelectedText(
            bundleID: frontBundle,
            role: focusedRole
        )
        // #region agent log
        if preferHID {
            TextInjectionPipeline.debugLogInject(
                hypothesisId: "M3",
                message: "skip AX range — unverified precondition or weak selected-text app",
                data: [
                    "frontmostBundle": frontBundle,
                    "preferHID": true,
                    "role": focusedRole ?? ""
                ]
            )
        }
        // #endregion

        switch effectivePlan {
        case .refuse(let reason):
            refuseInject(
                reason,
                path: "plannerRefuse",
                swallowed: swallowed,
                completion: completion
            )
            return

        case .axOnly:
            // AX only — no HID. Range replace + optional AX caret; never erase-less direct inject.
            // A known-lying app has no fallback here, so this correctly refuses rather than
            // pretending the expand happened.
            let axOnlyOutcome = (shellLike || preferHID)
                ? AXTextWriter.AXReplaceOutcome.notAttempted(shellLike ? "shell-like context" : "weak AX app")
                : ax.performAXRangeReplace(
                    text: textToInject,
                    eraseCount: erasePlan.utf16Count,
                    bundleID: context.frontBundleID,
                    focus: focus
                )
            if axOnlyOutcome == .replaced {
                // #region agent log
                TextInjectionPipeline.debugLogInject(
                    hypothesisId: "M3",
                    message: "inject path",
                    data: ["frontmostBundle": frontBundle, "path": "axOnlyRange", "outcome": "degradedAXOnly"]
                )
                // #endregion
                positionCursorIfNeeded(
                    text: textToInject,
                    cursorOffset: cursorOffset,
                    totalUTF16Length: totalUTF16,
                    allowHID: false,
                    focus: focus,
                    shouldContinue: canProceed
                ) {
                    self.finishSucceeded(
                        outcome: .degradedAXOnly,
                        path: "axOnlyRange",
                        context: context,
                        injectedText: textToInject,
                        undoable: resolved.undoable,
                        completion: completion
                    )
                }
                return
            }
            refuseInject(
                "AX-only inject failed — range replace required (no erase-less direct inject); Post Events needed for HID fallback",
                path: "axOnlyRange",
                swallowed: swallowed,
                completion: completion
            )
            return

        case .axPlusHID:
            break
        }

        // Tracks whether a text write actually *reached* the field. A non-`.replaced` outcome
        // does not prove nothing changed — some hosts mutate and then report a stale AXValue —
        // so the HID fallback below must not erase on unverifiable state. But the outcome's own
        // provenance decides: a `.notAttempted` return means the writer bailed before issuing
        // any write (no focused element, learned skip, unreadable range), and treating *that*
        // as "may have mutated" refused every expand in AX-opaque hosts — a Chrome PWA cannot
        // verify the field either, so the guard tripped on a write that never happened.
        var attemptedAXWrite = false
        if InjectionPlanner.mayWriteViaAX(shellLike: shellLike, preferHID: preferHID) {
            let axOutcome = ax.performAXRangeReplace(
                text: textToInject,
                eraseCount: erasePlan.utf16Count,
                bundleID: context.frontBundleID,
                focus: focus
            )
            attemptedAXWrite = axOutcome.fieldMayHaveMutated
            if axOutcome == .replaced {
                // #region agent log
                TextInjectionPipeline.debugLogInject(
                    hypothesisId: "M3",
                    message: "inject path",
                    data: ["frontmostBundle": frontBundle, "path": "axRange", "outcome": "succeeded"]
                )
                // #endregion
                positionCursorIfNeeded(
                    text: textToInject,
                    cursorOffset: cursorOffset,
                    totalUTF16Length: totalUTF16,
                    allowHID: true,
                    focus: focus,
                    shouldContinue: canProceed
                ) {
                    self.hid.postTrailingKeys(keysToPress, shouldContinue: canProceed)
                    self.finishSucceeded(
                        outcome: .succeeded,
                        path: "axRange",
                        context: context,
                        injectedText: textToInject,
                        undoable: resolved.undoable,
                        completion: completion
                    )
                }
                return
            }
            // Range replace did not apply. If this call just condemned the control (falseSuccess)
            // or the role was already marked weak, skip AX direct after erase — that path can
            // report succeeded after deleting the trigger when verification is unverifiable.
            if case .falseSuccess = axOutcome {
                preferHID = true
            } else if AXWriteCapabilityStore.shared.shouldSkipAXSelectedText(
                bundleID: frontBundle,
                role: focusedRole
            ) {
                preferHID = true
            }
        }

        // Fallback: HID backspaces then AX set or paste.
        // The guarded erase collapses any stray selection and re-verifies the trigger is still left
        // of the caret, so a half-applied AX edit above cannot be swallowed by backspace #1 and turn
        // the remaining backspaces loose on the user's text.
        // The continuation after the erase is a local function, not the call's trailing closure,
        // so a refusal that a second look may clear can re-enter it after a settle.
        var restoredPartialErase = false
        var settledPartialErase = false
        func afterErase(_ erased: Bool, settleAttempt: Int) {
            guard erased else {
                // The burst stopped part-way: the keys already posted removed the end of the
                // trigger, so replaying the swallowed key below would put it after a truncated
                // head. Put the removed tail back first — only into a field the continue-check
                // still vouches for, and without replaying the key here: the refusal below does,
                // after the tail. `postedBackspaces` counts authorized pairs, one more than were
                // posted when a CGEvent could not be created, so the field must show exactly the
                // head that count implies; a restore on a wrong count writes text the user never
                // typed. An unreadable field gets no restore — the refusal is what it got before.
                //
                // A mirror one key behind the backspaces reads the same as an overstated count,
                // and neither is a verdict on one read. A field that verifiably shows *less*
                // deleted than the count says gets one look after the mirror settles: only a
                // lagging one has caught up to exactly the count by then, so the checks below run
                // unchanged on that second reading, and an overstated one is refused as before.
                // A keystroke in the wait fails `canProceedAfterMutation` on re-entry. That check
                // runs first here too: it is what adopts a vouched replacement, and the lag is
                // read from the adopted element, not from a node a swap has already killed.
                if !restoredPartialErase, !settledPartialErase, postedBackspaces > 0,
                   canProceedAfterMutation(),
                   self.partialEraseMayLag(context, posted: postedBackspaces) {
                    settledPartialErase = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + AXSettleRetry.settleDelay) {
                        afterErase(false, settleAttempt: settleAttempt)
                    }
                    return
                }
                if !restoredPartialErase, postedBackspaces > 0, canProceedAfterMutation(),
                   let tail = erasePlan.erasedTail(graphemes: postedBackspaces),
                   let head = erasePlan.keptHead(graphemes: postedBackspaces),
                   self.eraser.evaluateErasePrecondition(
                       plan: head,
                       focus: FocusedElementSource.resolved(context.focusedElement),
                       retryOnMismatch: false
                   ) == .ok,
                   // A second, independent signal: the head check is a suffix check and cannot
                   // see how many graphemes of a repeating head are gone. The whole field must be
                   // the pre-erase field minus exactly the posted graphemes.
                   self.partialEraseLanded(context, posted: postedBackspaces) {
                    restoredPartialErase = true
                    self.restoreTriggerAfterFailedPaste(
                        erasePlan: tail,
                        swallowed: .notSwallowed,
                        focus: FocusedElementSource.resolved(context.focusedElement),
                        bundleID: context.frontBundleID,
                        countsAsDuplicateRisk: false,
                        shouldContinue: canProceedAfterMutation
                    ) {
                        afterErase(false, settleAttempt: settleAttempt)
                    }
                    return
                }
                self.refuseInject(
                    "Trigger erase did not complete — field may hold a partial trigger",
                    path: "eraseIncomplete",
                    swallowed: swallowed,
                    allowKeyReplay: canProceedAfterMutation(),
                    refuseContext: .capture(
                        reason: "Trigger erase did not complete",
                        decision: context.gateDecision
                    ),
                    completion: completion
                )
                return
            }
            if !canProceedAfterMutation() {
                // `followsVouchedReplacement` just judged this and stashed why: reading the stash
                // keeps the label, and the second-look decision, from describing a different
                // instant than the refusal they explain.
                let refusal = context.adopted.lastRefusal
                    ?? EraseContinuation.unadoptedRefusal(.beforeInsertion, nil)
                // The trigger is already gone. A reading WebKit produces while it replaces
                // the node (focus nothing, a web area, an AX value still behind the keys)
                // gets a bounded second look before it stands — the vouchers are unchanged.
                if context.adopted.lastRefusalMayClear,
                   EraseContinuation.rereadBudgetRemains(attempt: settleAttempt) {
                    DevTypeLog.inject.info(
                        "[Inject] focus not yet vouched after the erase — re-reading after settle (attempt \(settleAttempt + 1, privacy: .public)/\(EraseContinuation.maxSettleRereads, privacy: .public))"
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + AXSettleRetry.settleDelay) {
                        afterErase(true, settleAttempt: settleAttempt + 1)
                    }
                    return
                }
                self.refuseInject(
                    refusal.reason,
                    path: refusal.path,
                    swallowed: swallowed,
                    allowKeyReplay: false,
                    refuseContext: .capture(
                        reason: refusal.reason,
                        decision: context.gateDecision,
                        targetMismatch: refusal.recordedMismatch
                    ),
                    completion: completion
                )
                return
            }
            // The paste targets the element the continuation just adopted, not the one captured
            // before the backspaces.
            let focus = FocusedElementSource.resolved(context.focusedElement)
            let focusedRole = context.focusedRole
            switch InjectionPlanner.insertAfterErase(
                bundleID: context.frontBundleID,
                text: textToInject,
                shellLike: shellLike
            ) {
            case .nothing:
                self.finishSucceeded(
                    outcome: .succeeded,
                    path: "eraseOnly",
                    context: context,
                    injectedText: textToInject,
                    undoable: resolved.undoable,
                    completion: completion
                )
                return
            case .unicode:
                if let events = HIDKeyPoster.unicodeInsertEvents(for: textToInject) {
                    let posted = self.hid.postUnicodeInsert(
                        events,
                        shouldContinue: canProceedAfterMutation
                    )
                    if posted > 0 {
                        self.positionCursorIfNeeded(
                            text: textToInject,
                            cursorOffset: cursorOffset,
                            totalUTF16Length: totalUTF16,
                            allowHID: true,
                            focus: focus,
                            shouldContinue: canProceedAfterMutation
                        ) {
                            self.hid.postTrailingKeys(keysToPress, shouldContinue: canProceedAfterMutation)
                            self.finishSucceeded(
                                outcome: .postedUnverified,
                                path: posted == events.count ? "unicodeInsert" : "unicodeInsertPartial",
                                context: context,
                                injectedText: textToInject,
                                undoable: resolved.undoable,
                                completion: completion
                            )
                        }
                        return
                    }
                }
            case .clipboard:
                break
            }
            // Terminals and IDE shells take the clipboard path below unchanged — no AX direct set
            // (a terminal's AX mirror is a rendered screen, not an editable field), and no
            // synthesised bracketed-paste markers.
            //
            // Bracketed paste is a terminal→pty protocol, not clipboard content: when the shell
            // enables mode 2004 the *terminal emulator* wraps whatever is pasted, at paste time.
            // Delivery here is a synthetic ⌘V, so markers added to the payload land **inside** that
            // wrapper and the shell inserts them as literal text — `[200~…[201~` on the command
            // line, seen in cmux. A host that does not implement bracketed paste shows the same
            // garbage, and the pasted newline the markers were meant to neutralise executes anyway.
            // There is no receiver for which wrapping here is correct, so the payload is the
            // snippet text, byte for byte, everywhere.

            // Weak-AX apps and shells: skip direct AX set (same false-success class as range
            // replace, and the same predicate).
            if InjectionPlanner.mayWriteViaAX(shellLike: shellLike, preferHID: preferHID),
               self.ax.attemptAXDirectInjection(
                   text: textToInject,
                   bundleID: context.frontBundleID,
                   focus: focus
               ) {
                // #region agent log
                TextInjectionPipeline.debugLogInject(
                    hypothesisId: "M3",
                    message: "inject path",
                    data: ["frontmostBundle": frontBundle, "path": "axDirect", "outcome": "succeeded"]
                )
                // #endregion
                self.positionCursorIfNeeded(
                    text: textToInject,
                    cursorOffset: cursorOffset,
                    totalUTF16Length: totalUTF16,
                    allowHID: true,
                    focus: focus,
                    shouldContinue: canProceedAfterMutation
                ) {
                    self.hid.postTrailingKeys(keysToPress, shouldContinue: canProceedAfterMutation)
                    self.finishSucceeded(
                        outcome: .succeeded,
                        path: "axDirect",
                        context: context,
                        injectedText: textToInject,
                        undoable: resolved.undoable,
                        completion: completion
                    )
                }
                return
            }

            let hidPasteBaseline = self.verifier.captureFocusedTextObservation(focus: focus)
            self.clipboard.pasteViaClipboard(
                text: textToInject,
                expectedText: textToInject,
                baseline: hidPasteBaseline,
                focus: focus,
                bundleID: context.frontBundleID,
                focusedRole: focusedRole,
                staleProbe: erasePlan.expectedText,
                staleProbeCaseInsensitive: erasePlan.caseInsensitive,
                followVouchedReplacement: { self.vouchedPasteTarget(context) },
                publicationGate: context.request.publicationGate,
                shouldContinue: canProceedAfterMutation
            ) { result in
                // #region agent log
                TextInjectionPipeline.debugLogInject(
                    hypothesisId: "M4",
                    message: "inject path",
                    data: [
                        "frontmostBundle": frontBundle,
                        "path": "hidPaste",
                        "result": TextInjectionPipeline.pasteResultLabel(result)
                    ]
                )
                // #endregion
                self.finishPasteDelivery(
                    result: result,
                    expectedText: textToInject,
                    baseline: hidPasteBaseline,
                    context: context,
                    focusedRole: focusedRole,
                    path: "hidPaste",
                    cursorOffset: cursorOffset,
                    totalUTF16Length: totalUTF16,
                    trailingKeys: keysToPress,
                    completion: completion
                )
            }
        }

        eraser.performGuardedErase(
            plan: erasePlan,
            focus: focus,
            afterPossibleWrite: attemptedAXWrite,
            insertionPointFollowsExpectedText: context.eraseCaretVouched,
            intent: context.purpose.eraseIntent,
            canProceed: canProceed,
            postingContinue: postingContinue,
            onUnverifiableAfterWrite: { why in
                // Self-healing: an attempted AX write left the field unreadable even after the
                // settle retry — the Chromium/Electron signature (a fresh web-app shell hits
                // this on its very first expansion). Strikes escalate rather than condemn
                // outright: a transient (focus stolen mid-inject) looks identical on one
                // observation, and a wrong condemnation is effectively permanent. The second
                // strike condemns, so a genuinely broken shell heals on the user's next retry
                // and every expansion after that skips the AX write for the HID paste path.
                // `.mismatch` never reaches here, so a moved caret cannot strike a healthy app.
                guard let bundleID = context.frontBundleID, !bundleID.isEmpty else { return }
                let safeBundleID = DevTypeLog.boundedPublicIdentifier(bundleID, label: "bundleID")
                let safeWhy = DevTypeLog.boundedPublicIdentifier(why, label: "eraseOutcome")
                switch AXWriteCapabilityStore.shared.recordUnverifiableAfterWrite(
                    bundleID: bundleID,
                    role: focusedRole
                ) {
                case .struck(let count):
                    DevTypeLog.inject.notice(
                        "[Inject] unverifiable after AX write (\(safeWhy, privacy: .public)) — strike \(count, privacy: .public)/\(AXWriteCapabilityStore.unverifiableStrikesToCondemn, privacy: .public) for \(safeBundleID, privacy: .public)"
                    )
                case .condemned:
                    DevTypeLog.inject.notice(
                        "[Inject] unverifiable after AX write (\(safeWhy, privacy: .public)) — verdict learned for \(safeBundleID, privacy: .public); this expansion is refused, the next uses HID paste"
                    )
                case .alreadyCondemned:
                    break
                }
            },
            elementAfterContinue: { context.focusedElement }
        ) { erased in
            afterErase(erased, settleAttempt: 0)
        }
    }

    /// The text one inject delivers, resolved once: the caller's pre-resolved text or the
    /// rendered macros, the caret offset, and the `%key:` trailing keys.
    private struct ResolvedText {
        let text: String
        let cursorOffset: Int?
        let trailingKeys: [String]

        var totalUTF16: Int { text.utf16.count }

        /// §3.1: whether the delivered end state supports an undo point at all.
        var undoable: Bool {
            ExpansionUndoPolicy.undoPointAllowed(
                trailingKeys: trailingKeys, cursorOffset: cursorOffset, totalUTF16: totalUTF16
            )
        }
    }

    /// Renders the snippet (unless the caller already did) and refuses an inject that cannot
    /// proceed: a macro failure, a fill-in that was never presented, or an empty body with no
    /// caret marker. `nil` means the inject was refused and `completion` already ran.
    private func resolveText(
        context: InjectContext,
        completion: @escaping InjectionCompletion
    ) -> ResolvedText? {
        let swallowed = context.swallowed
        // Snapshot clipboard before any paste mutate when macros need it.
        let clipboardArg = context.clipboardOverride
        let cursorOffset: Int?
        let textToInject: String
        let keysToPress: [String]
        if let preResolvedText = context.preResolvedText {
            textToInject = preResolvedText
            cursorOffset = context.preResolvedCursorOffset
            keysToPress = context.trailingKeys
        } else {
            let lookup = context.snippetLookup ?? { _ in nil }
            let expanded = MacroRenderer.expand(
                content: context.snippet.replacementText,
                fillValues: [:],
                lookup: lookup,
                clipboardText: clipboardArg
            )
            if let failure = expanded.failure {
                refuseInject(failure.message, path: "macroPreparation", swallowed: swallowed, completion: completion)
                return nil
            }
            if expanded.needsFillIn {
                refuseInject(
                    "Fill-in required — present FillInPanel before inject",
                    path: "fillInRequired",
                    swallowed: swallowed,
                    completion: completion
                )
                return nil
            }
            textToInject = expanded.text
            cursorOffset = expanded.cursorOffset
            keysToPress = expanded.trailingKeys
        }
        if InjectionPlanner.emptyExpansionDecision(text: textToInject, cursorOffset: cursorOffset) == .refuse {
            refuseInject(
                "Expansion resolved to empty text — leaving the trigger in place",
                path: "emptyExpansion",
                swallowed: swallowed,
                completion: completion
            )
            return nil
        }
        return ResolvedText(text: textToInject, cursorOffset: cursorOffset, trailingKeys: keysToPress)
    }

    /// Image snippets bypass all text/AX paths: erase the trigger with HID backspaces, then
    /// paste the image through the clipboard.
    private func performImageInject(
        context: InjectContext,
        focus: FocusedElementSource,
        beforeMutation canProceed: @escaping () -> Bool,
        afterMutation canProceedAfterMutation: @escaping () -> Bool,
        duringPost postingContinue: @escaping () -> Bool,
        completion: @escaping InjectionCompletion
    ) {
        let swallowed = context.swallowed
        guard CGPreflightPostEventAccess() else {
            refuseInject(
                "Image expansion requires Post Events (clipboard paste)",
                path: "imagePaste",
                swallowed: swallowed,
                completion: completion
            )
            return
        }
        guard let image = ImageAttachmentStore.shared.loadImage(path: context.snippet.imagePath) else {
            refuseInject(
                "Image attachment missing or unreadable",
                path: "imagePaste",
                swallowed: swallowed,
                completion: completion
            )
            return
        }
        eraser.performGuardedErase(
            plan: context.erasePlan,
            focus: focus,
            canProceed: canProceed,
            postingContinue: postingContinue,
            elementAfterContinue: { context.focusedElement }
        ) { erased in
            guard erased else {
                self.refuseInject(
                    "Trigger erase did not complete — field may hold a partial trigger",
                    path: "eraseIncomplete",
                    swallowed: swallowed,
                    allowKeyReplay: canProceedAfterMutation(),
                    refuseContext: .capture(
                        reason: "Trigger erase did not complete",
                        decision: context.gateDecision
                    ),
                    completion: completion
                )
                return
            }
            if !canProceedAfterMutation() {
                switch self.adoptVouchedContinuation(
                    context,
                    rangeGate: .afterMutation,
                    checkRange: false,
                    continuation: .beforeInsertion
                ) {
                case .proceed, .retarget:
                    break
                case .refuse(let refusal):
                    self.refuseInject(
                        refusal.reason,
                        path: refusal.path,
                        swallowed: swallowed,
                        allowKeyReplay: false,
                        refuseContext: .capture(
                            reason: refusal.reason,
                            decision: context.gateDecision,
                            targetMismatch: refusal.recordedMismatch
                        ),
                        completion: completion
                    )
                    return
                }
            }
            let focus = FocusedElementSource.resolved(context.focusedElement)
            self.clipboard.pasteImageViaClipboard(
                image: image,
                imagePath: context.snippet.imagePath,
                bundleID: context.frontBundleID,
                focus: focus,
                publicationGate: context.request.publicationGate,
                shouldContinue: canProceedAfterMutation
            ) { result in
                guard canProceedAfterMutation() else {
                    self.finishAbandonedPaste(result: result, path: "imagePasteAbandoned", completion: completion)
                    return
                }
                // §3.4: the image path now reports what it actually observed instead of
                // "posted, therefore succeeded".
                let outcome: PermissionCoordinator.InjectOutcome
                switch result {
                case .delivered:
                    outcome = .succeeded
                case .unavailable:
                    outcome = .postedUnverified
                case .notPosted, .failed:
                    outcome = .failedSilent
                }
                PermissionCoordinator.shared.recordInjectOutcome(
                    outcome,
                    refuseContext: nil,
                    path: "imagePaste"
                )
                completion(outcome)
            }
        }
    }

    /// Explicit Inline Search / hotkey path: HID clipboard Cmd+V only (never AX).
    /// Bypasses live Secure Input, secure-field, and missing-focus-under-SI refuses.
    ///
    /// A selection replace (`replacesSelection`) is not left fire-and-forget: the selection was
    /// confirmed carefully, and the ⌘V that follows is the one step nothing used to watch. See
    /// `witnessReplacement`. `operationIsCurrent` is the operation half of `shouldContinue` — the
    /// part that says the user did not cancel, supersede or type, as opposed to focus moving.
    /// Internal rather than private so a test can drive it against a scripted field.
    func injectSecureClipboardPasteOnMain(
        snippet: SnippetModel,
        clipboardOverride: String?,
        swallowed: SwallowedKey,
        preResolvedText: String?,
        trailingKeys: [String],
        snippetLookup: ((String) -> String?)?,
        focus: FocusedElementSource,
        replacesSelection: Bool,
        shouldContinue: @escaping () -> Bool,
        operationIsCurrent: @escaping () -> Bool,
        completion: @escaping InjectionCompletion
    ) {
        if snippet.isImageSnippet {
            refuseInject(
                "Secure clipboard paste does not support image snippets",
                path: "secureClipboardPaste",
                swallowed: swallowed,
                completion: completion
            )
            return
        }

        let clipboardArg = clipboardOverride
        let textToInject: String
        let keysToPress: [String]
        if let preResolvedText {
            textToInject = preResolvedText
            keysToPress = trailingKeys
        } else {
            let lookup = snippetLookup ?? { _ in nil }
            let expanded = MacroRenderer.expand(
                content: snippet.replacementText,
                fillValues: [:],
                lookup: lookup,
                clipboardText: clipboardArg
            )
            if let failure = expanded.failure {
                refuseInject(failure.message, path: "macroPreparation", swallowed: swallowed, completion: completion)
                return
            }
            if expanded.needsFillIn {
                refuseInject(
                    "Fill-in required — present FillInPanel before inject",
                    path: "secureClipboardPaste",
                    swallowed: swallowed,
                    completion: completion
                )
                return
            }
            textToInject = expanded.text
            keysToPress = expanded.trailingKeys
        }

        let underSecureInput = AXContextChecker.isSecureEventInputEnabledLive()
        let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let frontBundle = frontBundleID ?? "nil"
        // #region agent log
        TextInjectionPipeline.debugLogInject(
            hypothesisId: "M4",
            message: "inject path",
            data: [
                "frontmostBundle": frontBundle,
                "path": "secureClipboardPaste",
                "underSecureInput": underSecureInput,
                "textLen": textToInject.utf16.count
            ]
        )
        // #endregion

        // No AX verification for password fields (often unreadable). Longer hold under SI so
        // the user can press ⌘V if synthetic paste is dropped.
        //
        // §1.7: `completeBeforeRestore` releases the inject queue while our payload is still on the
        // pasteboard for up to `secureClipboardPasteHoldTimeout`. That is deliberate — the user may
        // need to press ⌘V themselves — and it is safe only because `PasteboardBroker` now tracks
        // ownership: the next expansion inherits this pending restore instead of snapshotting our
        // concealed payload as if it were the user's clipboard.
        //
        // A replace over a field AX can read is the exception to "no AX verification": the guard
        // proved the selection, and nothing proved the paste. With a baseline the broker runs its
        // hold loop (reads only, and a real answer releases the board at once), and the role it is
        // given is the field's own so the after-mutation gate treats a combo box as the unstable
        // node it is. Under Secure Input, or over a field that cannot be read, the call is the one
        // it always was: the fields that need this path are the ones AX cannot read.
        let focusedRole = focus.element.flatMap { AXContextChecker.shared.focusedElementRole(element: $0) }
        let replaceBaseline = replacesSelection && !underSecureInput
            ? verifier.captureFocusedTextObservation(focus: focus).flatMap { observed in
                observed.target != nil && observed.value != nil && observed.selectedRange != nil ? observed : nil
            }
            : nil
        clipboard.pasteViaClipboard(
            text: textToInject,
            expectedText: replaceBaseline == nil ? nil : textToInject,
            baseline: replaceBaseline,
            focus: focus,
            bundleID: frontBundleID,
            focusedRole: focusedRole,
            leaveClipboardOnFailure: underSecureInput,
            holdTimeoutOverride: underSecureInput ? InjectTiming.secureClipboardPasteHoldTimeout : nil,
            completeBeforeRestore: true,
            allowSecureInput: true,
            // The witness below keeps judging the field for the miss window after the hold has
            // answered; the payload stays on the board for that long, so a late paste reads the
            // result rather than the user's restored clipboard.
            // Two polls of slack past the window: the witness stops on its own clock at the window,
            // and its last read can land one poll late.
            residencyAfterHold: replaceBaseline == nil
                ? 0
                : InjectTiming.replacementMissWindow + 2 * InjectTiming.pasteDeliverySettleDelay,
            shouldContinue: shouldContinue
        ) { result in
            guard shouldContinue() else {
                // Focus moved while the operation is still the user's: the very shape a paste that
                // lands nowhere has. Whether it did is a question for the field, not for this gate.
                if let replaceBaseline, result != .notPosted, operationIsCurrent() {
                    self.witnessReplacement(
                        payload: textToInject, baseline: replaceBaseline, role: focusedRole,
                        bundleID: frontBundleID, trailingKeys: keysToPress,
                        shouldContinue: shouldContinue, operationIsCurrent: operationIsCurrent,
                        completion: completion
                    )
                    return
                }
                self.finishAbandonedPaste(result: result, path: "secureClipboardAbandoned", completion: completion)
                return
            }
            switch result {
            case .delivered:
                self.hid.postTrailingKeys(keysToPress, shouldContinue: shouldContinue)
                PermissionCoordinator.shared.recordInjectOutcome(
                    .succeeded,
                    refuseContext: nil,
                    path: "secureClipboardPaste"
                )
                completion(.succeeded)

            case .unavailable:
                if let replaceBaseline {
                    self.witnessReplacement(
                        payload: textToInject, baseline: replaceBaseline, role: focusedRole,
                        bundleID: frontBundleID, trailingKeys: keysToPress,
                        shouldContinue: shouldContinue, operationIsCurrent: operationIsCurrent,
                        completion: completion
                    )
                    return
                }
                // Cmd+V posted; password fields usually cannot confirm via AX.
                if underSecureInput { self.notifySecureClipboardManualPaste() }
                PermissionCoordinator.shared.recordInjectOutcome(
                    .postedUnverified,
                    refuseContext: nil,
                    path: "secureClipboardPaste"
                )
                completion(.postedUnverified)

            case .notPosted, .failed:
                // No ⌘V went out, so the broker has restored the user's clipboard and the result
                // — generated, and not reproducible — would be gone. Under Secure Input the
                // broker already leaves the payload up for a manual ⌘V; everywhere else a
                // replace keeps it the way a refused selection does.
                var copied: Bool?
                if replacesSelection, !underSecureInput {
                    copied = self.keepRefusedReplacement(textToInject)
                    DevTypeLog.inject.notice(
                        "[Inject] replace not pasted — result copied=\(copied == true, privacy: .public)"
                    )
                }
                PermissionCoordinator.shared.recordInjectOutcome(
                    .failedSilent, refuseContext: nil, path: "secureClipboardPaste"
                )
                completion(.failedSilent)
                if let copied { self.onReplaceNotLanded?(copied) }
            }
        }
    }

    /// Reads a selection replace's field after its ⌘V and says what became of the result.
    ///
    /// The result is the only copy: the model produced it, the original is about to be (or
    /// has been) overwritten, and the broker restores the user's old clipboard moments after the
    /// paste. So a ⌘V that lands nowhere — focus slipped back to the window after the selection
    /// was confirmed — used to lose it silently as `postedUnverified`.
    ///
    /// - **landed**: `succeeded`, whether the node was replaced under the paste or not.
    /// - **not landed**, still true after `replacementMissWindow`: the result goes to the clipboard
    ///   through `keepRefusedReplacement` (invalidating the restore) and the outcome is a refusal
    ///   the report can name. **Nothing re-pastes**: a host that reads the board late would
    ///   duplicate the result, and the clipboard copy costs nothing if it did land.
    /// - anything else: `postedUnverified`, as before this existed.
    ///
    /// Bounded by attempt count, so a clock that stops cannot make it a loop, and by the clock, so
    /// a run loop that fires its polls late cannot stretch it past the window the broker keeps the
    /// payload on the board for (`residencyAfterHold`). The operation half of the continue-check
    /// ends it: a cancelled or superseded inject, or typing since, means the field is no longer
    /// ours to judge.
    private func witnessReplacement(
        payload: String,
        baseline: DeliveryVerifier.FocusedTextObservation,
        role: String?,
        bundleID: String?,
        trailingKeys: [String],
        shouldContinue: @escaping () -> Bool,
        operationIsCurrent: @escaping () -> Bool,
        attempt: Int = 0,
        startedAt: TimeInterval = InputClock.monotonicNow(),
        completion: @escaping InjectionCompletion
    ) {
        guard operationIsCurrent() else {
            finishAbandonedPaste(result: .unavailable, path: "secureClipboardAbandoned", completion: completion)
            return
        }
        let verdict = verifier.readReplacementOutcome(
            expectedText: payload, baseline: baseline,
            mirrorTrusted: deliveryTrust(bundleID, role)
        )
        if verdict == .landed {
            if shouldContinue() { hid.postTrailingKeys(trailingKeys, shouldContinue: shouldContinue) }
            PermissionCoordinator.shared.recordInjectOutcome(
                .succeeded, refuseContext: nil, path: "secureClipboardPaste"
            )
            completion(.succeeded)
            return
        }
        let budget = Int((InjectTiming.replacementMissWindow / InjectTiming.pasteDeliverySettleDelay).rounded(.up))
        let elapsed = InputClock.monotonicNow() - startedAt
        if attempt < budget, elapsed >= 0, elapsed < InjectTiming.replacementMissWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.pasteDeliverySettleDelay) {
                self.witnessReplacement(
                    payload: payload, baseline: baseline, role: role, bundleID: bundleID,
                    trailingKeys: trailingKeys, shouldContinue: shouldContinue,
                    operationIsCurrent: operationIsCurrent, attempt: attempt + 1,
                    startedAt: startedAt, completion: completion
                )
            }
            return
        }
        // A miss is only called while the result is still the board's content. Once the user's
        // clipboard is back, a host that pastes late pastes *that* over the selection, and copying
        // the result now would replace the user's clipboard for a paste that may yet land.
        guard verdict == .notLanded, clipboard.holdsPublishedPayload() else {
            if verdict == .notLanded {
                DevTypeLog.inject.notice(
                    "[Inject] replace unconfirmed — the board was already restored, so no miss is called"
                )
            }
            PermissionCoordinator.shared.recordInjectOutcome(
                .postedUnverified, refuseContext: nil, path: "secureClipboardPaste"
            )
            completion(.postedUnverified)
            return
        }
        let copied = keepRefusedReplacement(payload)
        DevTypeLog.inject.notice(
            "[Inject] replace not confirmed — field unchanged \(InjectTiming.replacementMissWindow, privacy: .public)s after ⌘V; result copied=\(copied, privacy: .public)"
        )
        refuseInject(
            SelectionReplacementGuard.Refusal.notLanded.reason,
            path: SelectionReplacementGuard.refusalPath,
            swallowed: .notSwallowed,
            allowKeyReplay: false,
            completion: completion
        )
        onReplaceNotLanded?(copied)
    }

    private func notifySecureClipboardManualPaste() {
        DevTypeLog.inject.notice(
            "[Inject] Secure clipboard paste unconfirmed — payload left on pasteboard for manual paste"
        )
        onSecureClipboardManualPasteHint?()
    }

    private static func pasteResultLabel(_ result: PasteboardBroker.PasteDeliveryResult) -> String {
        PasteboardBroker.label(for: result)
    }

    // MARK: - Terminal paths

    /// Records outcome, restores the erased trigger on confirmed paste failure, and finishes the expand.
    private func finishPasteDelivery(
        result: PasteboardBroker.PasteDeliveryResult,
        expectedText: String,
        baseline: DeliveryVerifier.FocusedTextObservation?,
        context: InjectContext,
        focusedRole: String? = nil,
        path: String,
        cursorOffset: Int?,
        totalUTF16Length: Int,
        trailingKeys: [String] = [],
        completion: @escaping InjectionCompletion
    ) {
        // The plain check first, then the vouched replacement: a paste that never went out (⌘V
        // refused, board lost) into a field whose node was swapped still owes the user their
        // trigger back, and the restore has to follow the swap exactly as the paste would have.
        // A paste that did land replaced the node with text the pre-erase picture does not predict,
        // so the vouching read refuses it and it falls through to the abandoned path as before.
        let stillOurs = { self.canContinue(context) || self.followsVouchedReplacement(context) }
        guard stillOurs() else {
            finishAbandonedPaste(result: result, path: "clipboardAbandoned", completion: completion)
            // The usual cause in a WebKit field is the paste itself replacing the focused node:
            // the text is there and the element is not `CFEqual` to the one captured. The
            // deferred, observation-only read may still prove it on a vouched replacement; for a
            // different field, or no focus, it proves nothing and leaves the outcome unverified.
            if result != .notPosted {
                scheduleDeferredPasteReverify(
                    context: context, expectedText: expectedText, baseline: baseline, path: path
                )
            }
            return
        }
        // Read after the guard: a vouched replacement re-points `context` at the new element.
        let focus = FocusedElementSource.resolved(context.focusedElement)
        let safeBundleID = DevTypeLog.boundedPublicIdentifier(
            context.frontBundleID,
            label: "bundleID"
        )
        // A readable miss cannot prove that an already-posted asynchronous paste
        // will never arrive. Preserve the unverified result and do not replay text.
        let result: PasteboardBroker.PasteDeliveryResult = result == .failed ? .unavailable : result
        switch result {
        case .delivered:
            positionCursorIfNeeded(
                text: expectedText,
                cursorOffset: cursorOffset,
                totalUTF16Length: totalUTF16Length,
                allowHID: true,
                focus: focus,
                shouldContinue: { self.canContinue(context) }
            ) {
                self.hid.postTrailingKeys(trailingKeys, shouldContinue: { self.canContinue(context) })
                self.finishSucceeded(
                    outcome: .succeeded,
                    path: path,
                    context: context,
                    injectedText: expectedText,
                    undoable: ExpansionUndoPolicy.undoPointAllowed(
                        trailingKeys: trailingKeys,
                        cursorOffset: cursorOffset,
                        totalUTF16: totalUTF16Length
                    ),
                    completion: completion
                )
            }

        case .unavailable:
            // Cmd+V posted; AX cannot confirm. Do not treat as urgent failure — common for
            // Chrome/Electron/terminals — but keep a deferred upgrade if the text appears later.
            // Trailing keys / cursor placement were not applied on this branch, but the snippet
            // *requested* them — judge undoability by the request, conservatively, so the two
            // branches cannot disagree about whether an undo point exists.
            finishSucceeded(
                outcome: .postedUnverified,
                path: path,
                context: context,
                injectedText: expectedText,
                undoable: ExpansionUndoPolicy.undoPointAllowed(
                    trailingKeys: trailingKeys,
                    cursorOffset: cursorOffset,
                    totalUTF16: totalUTF16Length
                ),
                completion: completion
            )
            scheduleDeferredPasteReverify(
                context: context, expectedText: expectedText, baseline: baseline, path: path
            )

        case .notPosted, .failed:
            DevTypeLog.inject.error(
                """
                [Inject] paste delivery \(TextInjectionPipeline.pasteResultLabel(result), privacy: .public) \
                — restoring trigger (app=\(safeBundleID, privacy: .public) path=\(path, privacy: .public))
                """
            )
            restoreTriggerAfterFailedPaste(
                erasePlan: context.erasePlan,
                swallowed: context.swallowed,
                focus: focus,
                bundleID: context.frontBundleID,
                countsAsDuplicateRisk: result != .notPosted,
                followVouchedReplacement: { self.vouchedPasteTarget(context) },
                shouldContinue: stillOurs
            ) {
                PermissionCoordinator.shared.recordInjectOutcome(
                    .failedSilent, refuseContext: nil, path: path
                )
                completion(.failedSilent)
            }
        }
    }

    /// One owner for the deferred, observation-only re-verification of a posted-but-unverified
    /// paste. It writes nothing and never re-pastes; the only thing it can do is upgrade the
    /// recorded outcome, and only on evidence.
    ///
    /// Only the operation half of the continue-check gates it (superseded, cancelled, user input
    /// since, trust, Secure Input). The target half is the verifier's: it compares the live
    /// element with the baseline's and, because WebKit can swap the node under a paste, accepts a
    /// replacement that is the same control and holds exactly the text the baseline predicts. A
    /// different field fails there as `.focusReplaced`, so a click elsewhere never verifies.
    private func scheduleDeferredPasteReverify(
        context: InjectContext,
        expectedText: String,
        baseline: DeliveryVerifier.FocusedTextObservation?,
        path: String
    ) {
        let safeBundleID = DevTypeLog.boundedPublicIdentifier(context.frontBundleID, label: "bundleID")
        DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.pasteReverifyDelay) {
            guard self.operationStateIsCurrent(
                context.operation, revision: context.inputRevision, observationOnly: true
            ) else { return }
            let reading = self.verifier.readFocusedTextDelivery(
                expectedText: expectedText,
                baseline: baseline,
                staleProbe: context.erasePlan.expectedText,
                staleProbeCaseInsensitive: context.erasePlan.caseInsensitive,
                vouchingReplacement: true
            )
            switch reading.verification {
            case .delivered:
                // Late confirmation upgrades the recorded outcome but deliberately does NOT
                // record delivery-read proof: a mirror that confirms only after the hold
                // window cannot be trusted to justify in-window corrections next time.
                if reading.replacementElement == nil {
                    DevTypeLog.inject.info("[Inject] paste re-verify: text confirmed after settle delay")
                } else {
                    DevTypeLog.inject.info("[Inject] paste re-verify: text confirmed on the replacement of the focused element")
                }
                PermissionCoordinator.shared.recordInjectOutcome(
                    .succeeded,
                    refuseContext: nil,
                    path: context.purpose.deliveryPath(path)
                )
            case .failed, .unavailable:
                // Not provable. The outcome stays `postedUnverified`, but the reason is logged
                // as what it was: an element that was replaced and could not be vouched is not
                // a host whose AX cannot be read, and a report must not say so.
                switch reading.unavailableReason {
                case .focusReplaced:
                    DevTypeLog.inject.info(
                        "[Inject] paste re-verify: focused element was replaced and is not the same control — delivery stays unverified (app=\(safeBundleID, privacy: .public))"
                    )
                case .noFocusedElement, .noBaselineTarget:
                    DevTypeLog.inject.info(
                        "[Inject] paste re-verify: no focused element to read — delivery stays unverified (app=\(safeBundleID, privacy: .public))"
                    )
                case .fieldUnreadable, nil:
                    // AX cannot read this field at all (common for Electron/terminal hosts).
                    DevTypeLog.inject.info(
                        "[Inject] paste re-verify: field unreadable — delivery stays unverified (app=\(safeBundleID, privacy: .public))"
                    )
                }
            }
        }
    }

    /// Best-effort: put the erased trigger back so a failed paste does not leave a hole in the field.
    ///
    /// §3.1 note: this is the same operation `undoLastExpansion` performs — the difference is only
    /// who asked for it.
    private func restoreTriggerAfterFailedPaste(
        erasePlan: ErasePlan,
        swallowed: SwallowedKey,
        focus: FocusedElementSource,
        bundleID: String? = nil,
        countsAsDuplicateRisk: Bool = true,
        followVouchedReplacement: (() -> PasteboardBroker.PasteTarget?)? = nil,
        shouldContinue: @escaping () -> Bool,
        completion: @escaping () -> Void
    ) {
        guard shouldContinue() else { completion(); return }
        if let text = erasePlan.expectedText, !text.isEmpty {
            // Counted, not just logged: a restore that runs after a paste which actually landed is
            // indistinguishable from a legitimate one in the outcome histogram, and both show up
            // to the user as text they did not type. `countsAsDuplicateRisk` is false only when
            // ⌘V provably never posted, where putting the trigger back cannot duplicate anything.
            if countsAsDuplicateRisk {
                InjectTelemetryLog.shared.recordTriggerRestore(bundleID: bundleID)
            }
            // Pass the real bundle so the write goes through the capability store like every
            // other AX site — in a learned false-success app this restore must not claim
            // success against a field it could not actually mutate.
            if ax.attemptAXDirectInjection(text: text, bundleID: bundleID, focus: focus) {
                if shouldContinue(), swallowed.mustReinjectOnRefuse {
                    _ = reinjectSwallowedKey(swallowed)
                }
                completion()
                return
            }
            // AX cannot restore — clipboard paste the trigger, then reinject the swallowed key.
            clipboard.pasteViaClipboard(
                text: text, expectedText: nil, baseline: nil, focus: focus, bundleID: bundleID,
                followVouchedReplacement: followVouchedReplacement,
                // The restore replaces this expansion's own payload (or follows an erase that
                // already waited out the board in `injectOnMain`): it must not sit behind it.
                publicationGate: .supersedesOwnPayload,
                shouldContinue: shouldContinue
            ) { _ in
                if shouldContinue(), swallowed.mustReinjectOnRefuse {
                    _ = self.reinjectSwallowedKey(swallowed)
                }
                completion()
            }
            return
        }
        if shouldContinue(), swallowed.mustReinjectOnRefuse {
            _ = reinjectSwallowedKey(swallowed)
        }
        completion()
    }

    /// §8.2: the single refuse path. There were nine near-identical eight-line call sites of this
    /// in `injectOnMain` differing only in a reason string.
    ///
    /// An asynchronous refuse owes the user the swallowed key while its target is unchanged.
    /// Once input/focus changes, replay could type (or press Return) into the wrong field.
    /// One owner for "the paste continuation was abandoned after ⌘V had been decided".
    ///
    /// All three post-paste continuations used to hand an outcome straight to the caller's
    /// completion and record nothing. The caller clears `isExpanding` either way, so the inject
    /// looked handled while the telemetry ring — the thing the diagnostic report reads — showed
    /// no attempt at all for it. `.notPosted` never reached the app and is a silent failure;
    /// anything else may still have landed, so it is recorded as posted-but-unverified rather
    /// than claimed as either success or failure.
    private func finishAbandonedPaste(
        result: PasteboardBroker.PasteDeliveryResult,
        path: String,
        completion: @escaping InjectionCompletion
    ) {
        let outcome: PermissionCoordinator.InjectOutcome =
            result == .notPosted ? .failedSilent : .postedUnverified
        PermissionCoordinator.shared.recordInjectOutcome(outcome, refuseContext: nil, path: path)
        completion(outcome)
    }

    /// Records and completes an entry-gate refusal. Re-reads the *live* conditions to label it;
    /// the gate above already made the decision, so a condition that flipped back in between
    /// costs an `.unreproduced` label, never a changed outcome.
    ///
    /// The target is the exception, and is handed in rather than re-read: it is the one
    /// condition whose label has to name a sub-reason, and re-reading it let the sub-reason
    /// describe a different instant — with a different range gate — from the decision it was
    /// explaining. `.targetChanged` on its own cannot be acted on, because an app switch, a
    /// caret landing in a different field, and focus that had not been published yet all print
    /// that one sentence, so the mismatch travels with the refusal into the diagnostic report.
    private func refuseEntryGate(
        operation: InjectCompletionGuard,
        revision: UInt64,
        targetMismatch: PasteboardBroker.PasteTarget.Mismatch?,
        allowSecureInput: Bool,
        swallowed: SwallowedKey,
        completion: @escaping InjectionCompletion
    ) {
        let revisionCurrent = ledger.isCurrent(operation, revision: revision)
        let refusal = EntryGateRefusal.classify(
            revisionCurrent: revisionCurrent,
            continuationBlock: operation.continuationBlock(),
            secureInputBlocked: !allowSecureInput && AXContextChecker.isSecureEventInputEnabledLive(),
            axUntrusted: !allowSecureInput && !AXContextChecker.shared.isProcessTrusted(),
            targetCurrent: targetMismatch == nil
        )
        refuseInject(
            refusal.reason,
            path: refusal.path,
            swallowed: swallowed,
            allowKeyReplay: false,
            refuseContext: PermissionCoordinator.InjectRefuseProvenance.capture(
                reason: refusal.reason,
                targetMismatch: EntryGateRefusal.recordedTargetMismatch(
                    refusal: refusal, mismatch: targetMismatch
                )
            ),
            completion: completion
        )
    }

    private func refuseInject(
        _ reason: String,
        path: String,
        swallowed: SwallowedKey,
        allowKeyReplay: Bool = true,
        refuseContext: PermissionCoordinator.InjectRefuseProvenance? = nil,
        completion: @escaping InjectionCompletion
    ) {
        if allowKeyReplay, swallowed.mustReinjectOnRefuse {
            _ = reinjectSwallowedKey(swallowed)
        }
        let safeReason = PermissionCoordinator.sanitizedRefusalReason(reason, path: path)
        var safeContext = refuseContext
        safeContext?.reason = safeReason
        PermissionCoordinator.shared.recordInjectOutcome(
            .refused(safeReason),
            refuseContext: safeContext,
            path: path
        )
        completion(.refused(safeReason))
    }

    /// §3.2 + §3.1: one place where a delivered expansion is recorded. The path string is the
    /// field `InjectTelemetryLog` was built for and could not be given, because only this file
    /// knows which branch ran. `undoable` comes from `undoPointAllowed` at the call site — only
    /// the branch that ran knows which trailing keys were posted and where the cursor went.
    private func finishSucceeded(
        outcome: PermissionCoordinator.InjectOutcome,
        path: String,
        context: InjectContext,
        injectedText: String,
        undoable: Bool,
        completion: @escaping InjectionCompletion
    ) {
        guard canContinue(context, phase: .afterMutation) else {
            // The text was posted; what is no longer provable is where it landed. Recorded like
            // every other abandoned delivery, so the report shows the attempt.
            finishAbandonedPaste(
                result: .unavailable, path: context.purpose.deliveryPath(path), completion: completion
            )
            return
        }
        PermissionCoordinator.shared.recordInjectOutcome(
            outcome,
            refuseContext: nil,
            path: context.purpose.deliveryPath(path)
        )
        if undoable, case .expansion = context.purpose {
            rememberExpansion(context: context, injectedText: injectedText)
        }
        completion(outcome)
    }

    /// §3.1: records the undo point. Only expansions that replaced a real trigger are recorded —
    /// an explicit hotkey / inline-search insert has nothing to revert *to*.
    private func rememberExpansion(context: InjectContext, injectedText: String) {
        guard !injectedText.isEmpty else { return }
        guard let trigger = context.erasePlan.expectedText, !trigger.isEmpty else { return }
        // The swallowed key never reached the field, but the user did type it, so undo restores it
        // along with the erased text — matching what every other expander puts back.
        let typed = context.swallowed.didSwallow
            ? trigger + context.swallowed.unicode
            : trigger
        let record = LastExpansion(
            erasePlan: context.erasePlan,
            injectedText: injectedText,
            triggerText: typed,
            bundleID: context.frontBundleID
        )
        recordUndoExpansion(record, target: PasteboardBroker.PasteTarget.capture(focus: .resolved(context.focusedElement)))
    }

    func recordUndoExpansion(_ record: LastExpansion, target: PasteboardBroker.PasteTarget) {
        ledger.record(record, target: target)
    }

    // MARK: - Cursor placement

    private func positionCursorIfNeeded(
        text: String,
        cursorOffset: Int?,
        totalUTF16Length: Int,
        allowHID: Bool,
        focus: FocusedElementSource,
        shouldContinue: @escaping () -> Bool,
        completion: @escaping () -> Void
    ) {
        guard shouldContinue(), let offset = cursorOffset, offset >= 0, offset <= totalUTF16Length else {
            completion()
            return
        }
        let utf16FromEnd = totalUTF16Length - offset
        guard utf16FromEnd > 0 else {
            completion()
            return
        }
        // Prefer AX caret (works for AX-only Finish-without-Post); HID arrows only when allowed.
        // The AX path is unit-correct: AX ranges and `utf16FromEnd` are both UTF-16 code units.
        if shouldContinue(), AXContextChecker.shared.isProcessTrusted(),
           ax.attemptAXCaretPosition(utf16OffsetFromEnd: utf16FromEnd, focus: focus) {
            completion()
            return
        }
        guard allowHID else {
            // AX caret failed and Post unavailable — accept inject without cursor placement.
            completion()
            return
        }
        // §1.6: a posted arrow moves one **grapheme cluster**, not one UTF-16 code unit. Posting
        // `utf16FromEnd` arrows overshot for every snippet with an emoji, an astral character or a
        // combining mark after `{{cursor}}` — and since the AX path above is correct, only the HID
        // fallback (Chrome/Electron, the majority path) was ever affected.
        let arrowCount = HIDKeyPoster.leftArrowCount(text: text, utf16OffsetFromEnd: utf16FromEnd)
        guard arrowCount > 0 else {
            completion()
            return
        }
        // Bounded: an unbounded burst of synthetic arrow keys is not caret placement in a host
        // with vim mode or an open autocomplete popup — it is input the user cannot account
        // for. Leaving the caret at the end is the honest failure, and the text still landed.
        guard InjectTiming.allowsCursorArrows(count: arrowCount) else {
            DevTypeLog.inject.notice(
                "[Inject] cursor placement skipped — needs \(arrowCount, privacy: .public) arrows, over the \(InjectTiming.maxCursorArrowKeys, privacy: .public) cap; text delivered, caret left at end"
            )
            completion()
            return
        }
        // Fixed settle before HID arrows — best-effort; CGEvent.post success ≠ delivery proof.
        DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.preArrowSettleDelay) {
            self.hid.sendLeftArrowsAsync(count: arrowCount, shouldContinue: shouldContinue, completion: completion)
        }
    }

    // #region agent log
    /// Opt-in and off-thread. See `DebugTrace` — this used to write synchronously to a hardcoded
    /// path on every inject. `data` is an autoclosure so the dictionary literals at the call sites
    /// are never allocated while tracing is off.
    ///
    /// Module-internal (not private) so the extracted collaborators can keep their trace lines.
    static func debugLogInject(
        hypothesisId: String,
        message: String,
        location: String = "TextInjectionPipeline",
        data: @autoclosure () -> [String: Any]
    ) {
        guard DebugTrace.isEnabled else { return }
        DebugTrace.write(
            location: location,
            hypothesisId: hypothesisId,
            message: message,
            data: data()
        )
    }
    // #endregion
}
