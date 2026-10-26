import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Deferred expand, AI transform and inject.
extension EventTapEngine {
    /// Off-callback expand: AX gates, macro resolve / fill-in, inject plan, then inject-owned lifetime.
    /// On refuse after swallow, reinjects the trigger key (InjectionPlanner contract).
    func performDeferredExpand(
        snippet: SnippetModel,
        triggerUTF16Length: Int,
        lastEventUTF16Count: Int,
        swallowed: SwallowedKey,
        terminator: String,
        eraseCountOverride: Int?,
        erasePlan: ErasePlan,
        armedFocusPID: pid_t?,
        /// Characters typed after the trigger while the match was held. They are inside
        /// `erasePlan`, so they must be re-appended to the injected text or they vanish.
        textSuffix: String = "",
        /// Enhancement plan 1.4: the case of the trigger as typed, for both render passes.
        caseShape: TriggerCaseShape = .asWritten
    ) {
        let quiescence = inputClock.arm()

        // AX / AppKit / Secure Input must run on main (avoid off-main IPC flake + nested main.sync).
        // §8.3: this caller is off main, so it owns the focus-query retry — each attempt hops to
        // main, and the settle between them sleeps here on `processingQueue`, never on main.
        let mainProbe = AXSettleRetry.live.run({ attempt in Self.runOnMainSync { () -> (
            decision: AXContextChecker.ExpandGateDecision,
            secureInput: Bool,
            clipboard: String?,
            currentPID: pid_t?,
            refuseContext: PermissionCoordinator.InjectRefuseProvenance?
        ) in
            let snapshot = PermissionCoordinator.shared.cachedSnapshot
            let decision = AXContextChecker.shared.evaluateExpandGate(
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents,
                focus: AXContextChecker.shared.queryFocusedElement(attempt: attempt)
            )
            let secureInput = AXContextChecker.isSecureEventInputEnabledLive()
            let clipboard = NSPasteboard.general.string(forType: .string)
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let refuseContext: PermissionCoordinator.InjectRefuseProvenance?
            if secureInput {
                refuseContext = .capture(
                    reason: AXContextChecker.secureInputActiveReason,
                    decision: decision
                )
            } else if decision.shouldBlock {
                refuseContext = .capture(reason: decision.reason, decision: decision)
            } else {
                refuseContext = nil
            }
            return (decision, secureInput, clipboard, currentPID, refuseContext)
        } }, retryIf: { AXContextChecker.shouldRetryFocusQuery($0.decision.focus) })

        if mainProbe.secureInput {
            refuseAfterSwallow(
                reason: AXContextChecker.secureInputActiveReason,
                drop: .secureInputLive,
                erasePlan: erasePlan,
                swallowed: swallowed,
                refuseContext: mainProbe.refuseContext
            )
            return
        }

        if mainProbe.decision.shouldBlock {
            refuseAfterSwallow(
                reason: mainProbe.decision.reason,
                drop: .gateRefused,
                erasePlan: erasePlan,
                swallowed: swallowed,
                refuseContext: mainProbe.refuseContext
            )
            return
        }

        if let armedFocusPID, mainProbe.currentPID != armedFocusPID {
            refuseAfterSwallow(
                reason: "Focus moved — expand aborted",
                drop: .focusMoved,
                erasePlan: erasePlan,
                swallowed: swallowed
            )
            return
        }

        if case .abort = inputClock.decide(quiescence) {
            refuseAfterSwallow(
                reason: "User input after arm — expand aborted",
                drop: .userInputAfterArm,
                erasePlan: erasePlan,
                swallowed: swallowed
            )
            return
        }

        // Typed AI transform: erase the trigger under fresh gates, end expansion immediately,
        // then hand off to the panel off-pipeline. Never hold `_isExpanding` across the model call.
        if !snippet.aiTransform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            handleTypedAITransformExpand(
                snippet: snippet,
                erasePlan: erasePlan,
                swallowed: swallowed,
                quiescence: quiescence,
                armedFocusPID: armedFocusPID
            )
            return
        }

        let clipboardSnapshot = mainProbe.clipboard
        let lookup = matchSnapshot.nestedResolver.lookup
        let renderContext = MacroRenderContext(clipboardText: clipboardSnapshot ?? "")

        let firstPass = MacroRenderer.expand(
            content: snippet.replacementText,
            fillValues: [:],
            lookup: lookup,
            clipboardText: clipboardSnapshot,
            context: renderContext,
            caseShape: caseShape
        )

        if firstPass.needsFillIn {
            let fields = firstPass.fillFields
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let presenter = self.presentFillIn
                guard let presenter else {
                    self.refuseAfterSwallow(
                        reason: "Fill-in required but no presenter wired",
                        drop: .fillInAborted,
                        erasePlan: erasePlan,
                        swallowed: swallowed
                    )
                    return
                }
                presenter(snippet.displayTitle, fields) { values in
                    self.processingQueue.async {
                        guard let values else {
                            self.refuseAfterSwallow(
                                reason: "Fill-in cancelled",
                                drop: .fillInAborted,
                                erasePlan: erasePlan,
                                swallowed: swallowed
                            )
                            return
                        }
                        // Double-arm quiescence on panel close (panel Return must not abort).
                        let postPanel = self.inputClock.arm()
                        let resolved = MacroRenderer.expand(
                            content: snippet.replacementText,
                            fillValues: values,
                            lookup: lookup,
                            clipboardText: clipboardSnapshot,
                            context: renderContext,
                            caseShape: caseShape
                        )
                        self.finishDeferredInject(
                            snippet: snippet,
                            triggerUTF16Length: triggerUTF16Length,
                            lastEventUTF16Count: lastEventUTF16Count,
                            swallowed: swallowed,
                            terminator: terminator,
                            eraseCountOverride: eraseCountOverride,
                            erasePlan: erasePlan,
                            resolved: resolved,
                            clipboardSnapshot: clipboardSnapshot,
                            quiescence: postPanel,
                            armedFocusPID: armedFocusPID,
                            textSuffix: textSuffix
                        )
                    }
                }
            }
            return
        }

        finishDeferredInject(
            snippet: snippet,
            triggerUTF16Length: triggerUTF16Length,
            lastEventUTF16Count: lastEventUTF16Count,
            swallowed: swallowed,
            terminator: terminator,
            eraseCountOverride: eraseCountOverride,
            erasePlan: erasePlan,
            resolved: firstPass,
            clipboardSnapshot: clipboardSnapshot,
            quiescence: quiescence,
            armedFocusPID: armedFocusPID,
            textSuffix: textSuffix,
            // §2.2: no panel came between the gate and the inject, so the element the gate
            // approved is the target. The fill-in path above re-resolves: focus left for the panel.
            gateFocus: mainProbe.decision.focus.element
        )
    }

    /// Off-pipeline typed AI path: fresh Secure Input + AX gates, selection cache, guarded erase,
    /// `endExpansion`, then `presentAITransform` on main. Model work must not run under `_isExpanding`.
    private func handleTypedAITransformExpand(
        snippet: SnippetModel,
        erasePlan: ErasePlan,
        swallowed: SwallowedKey,
        quiescence: InputQuiescenceGuard,
        armedFocusPID: pid_t?
    ) {
        guard let kind = AITransformKind.named(snippet.aiTransform) else {
            refuseAfterSwallow(
                reason: "Unknown AI transform kind",
                drop: .aiTransformRefused,
                erasePlan: erasePlan,
                swallowed: swallowed
            )
            return
        }

        // For `.custom` the snippet body *is* the prompt — the kind contributes only a wrapper
        // that defers to it. A blank body is therefore not a transform, and refusing here (before
        // the guarded erase, alongside the unknown-kind guard) is what keeps the user's trigger
        // on screen instead of erasing it to run the model on nothing. `AITextTransformer`
        // refuses the same case for callers that get this far.
        let customInstructions: String? = kind == .custom
            ? AIActionSelection.normalized(snippet.replacementText)
            : nil
        if kind == .custom, customInstructions == nil {
            refuseAfterSwallow(
                reason: "Custom AI transform has no instructions",
                drop: .aiTransformRefused,
                erasePlan: erasePlan,
                swallowed: swallowed
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentAITransformHint?(
                    Self.aiRefusedHintTitleKey,
                    Self.aiCustomInstructionsMissingHintKey
                )
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // §8.3: the asynchronous focus query keeps the `.cannotComplete` retry on this main-
            // thread path by scheduling it; the gate and the guarded erase then share that one
            // resolution (§2.2) instead of each asking AX again. Everything after it — the
            // quiescence check included — runs once focus is known, so a scheduled retry cannot
            // let input typed during the settle slip past the gate.
            AXContextChecker.shared.queryFocusedElement { focus in
                if case .abort = self.inputClock.decide(quiescence) {
                    self.refuseAfterSwallow(
                        reason: "User input after arm — expand aborted",
                        drop: .userInputAfterArm,
                        erasePlan: erasePlan,
                        swallowed: swallowed
                    )
                    return
                }

                // Re-check gates live — SecureInputMonitor's 350ms poll is stale; passwords must
                // never reach the model.
                let snapshot = PermissionCoordinator.shared.cachedSnapshot
                let decision = AXContextChecker.shared.evaluateExpandGate(
                    canUseAX: snapshot.canUseAX,
                    canPostEvents: snapshot.canPostEvents,
                    focus: focus
                )
                let secureInput = AXContextChecker.isSecureEventInputEnabledLive()
                let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

                if secureInput {
                    self.refuseAfterSwallow(
                        reason: AXContextChecker.secureInputActiveReason,
                        drop: .secureInputLive,
                        erasePlan: erasePlan,
                        swallowed: swallowed,
                        refuseContext: .capture(
                            reason: AXContextChecker.secureInputActiveReason,
                            decision: decision
                        )
                    )
                    return
                }
                if decision.shouldBlock {
                    self.refuseAfterSwallow(
                        reason: decision.reason,
                        drop: .gateRefused,
                        erasePlan: erasePlan,
                        swallowed: swallowed,
                        refuseContext: .capture(reason: decision.reason, decision: decision)
                    )
                    return
                }
                if let armedFocusPID, currentPID != armedFocusPID {
                    self.refuseAfterSwallow(
                        reason: "Focus moved — expand aborted",
                        drop: .focusMoved,
                        erasePlan: erasePlan,
                        swallowed: swallowed
                    )
                    return
                }

                // Consume is single-use so a second trigger cannot reuse the same stale text.
                // Same-element check (CFEqual) makes the longer TTL safe.
                let weakAXBlocked = SelectionMonitor.shared.hasWeakAXBlockedSelection()
                // The element comes from the focus resolution this closure already holds (§2.2) —
                // `consumeSelection` runs no AX query of its own on this main-thread path.
                guard let selection = SelectionMonitor.shared.consumeSelection(
                    focusedElement: focus.element
                ) else {
                    self.refuseAfterSwallow(
                        reason: weakAXBlocked ? "AI selection weak-AX" : "AI selection unavailable",
                        drop: .aiTransformRefused,
                        erasePlan: erasePlan,
                        swallowed: swallowed
                    )
                    let hintKey = weakAXBlocked
                        ? Self.aiWeakAXHintKey
                        : Self.aiSelectionUnavailableHintKey
                    self.presentAITransformHint?(Self.aiSelectionHintTitleKey, hintKey)
                    return
                }

                guard self.presentAITransform != nil else {
                    self.refuseAfterSwallow(
                        reason: "AI transform required but no presenter wired",
                        drop: .aiTransformRefused,
                        erasePlan: erasePlan,
                        swallowed: swallowed
                    )
                    return
                }

                let restoreOnCancel: String? = {
                    guard let expected = erasePlan.expectedText, !expected.isEmpty else { return nil }
                    return expected
                }()

                // This path owns no claimed inject operation, so its first write claims the
                // mutation itself: a hold that surrendered before it is refused here (the keys
                // are already back in the field, terminator first), and one that surrenders
                // after cannot abandon an erase that has begun. The executor asks more than once;
                // only the first ask is a claim.
                var mutationClaimed = false
                let claimMutation: () -> Bool = {
                    if mutationClaimed { return true }
                    mutationClaimed = TextInjectionPipeline.shared.beginUnclaimedMutation()
                    return mutationClaimed
                }
                EraseExecutor.shared.performGuardedErase(
                    plan: erasePlan, focus: .resolved(focus.element), canProceed: claimMutation
                ) { [weak self] erased in
                    guard let self else { return }
                    if !erased {
                        self.refuseAfterSwallow(
                            reason: "AI trigger erase failed",
                            drop: .aiTransformRefused,
                            erasePlan: erasePlan,
                            swallowed: swallowed
                        )
                        return
                    }
                    // Expansion ends here — panel owns the rest. Do not hold `_isExpanding`.
                    self.endExpansion()
                    let sourceApp = NSWorkspace.shared.frontmostApplication
                    let selectedText = selection.text
                    guard let presenter = self.presentAITransform else {
                        DevTypeLog.eventTap.error(
                            "[EventTap] AI transform presenter cleared after erase — trigger already removed"
                        )
                        return
                    }
                    presenter(selectedText, kind, sourceApp, customInstructions, restoreOnCancel)
                }
            }
        }
    }

    /// Inject an AI transform result without erasing again (trigger erase already happened, or
    /// hotkey path replaces the live selection via paste). Always passes `erasePlan: .empty`
    /// and `secureClipboardPaste: true` — do not rely on `eraseCountOverride: 0` alone.
    ///
    /// `origin` must be declared so the prompt-leak guard knows whether this payload is
    /// model output (checked against the full static prompt corpus, refused on match) or
    /// authored text (never blocked). The only current caller restores an erased trigger
    /// on cancel; a future caller passing model output cannot forget the check.
    public func injectAITransformResult(
        text: String,
        snippet: SnippetModel? = nil,
        sourceApp: NSRunningApplication? = nil,
        origin: AIPromptLeakGuard.PayloadOrigin,
        completion: (() -> Void)? = nil
    ) {
        switch origin {
        case .aiResult(let sourceSelection):
            let verdict = AIPromptLeakGuard.injectionVerdict(payload: text, exempting: sourceSelection)
            guard verdict.isClean else {
                DevTypeLog.store.error(
                    "[EventTap] AI inject refused at boundary — prompt leak guard matched"
                )
                AIDiagnosticsStore.shared.recordFailure(
                    kind: "injection-boundary",
                    error: "promptEcho",
                    detail: "result still contained prompt text after generation checks"
                )
                completion?()
                return
            }
        case .authoredText:
            break
        }
        let work = { [weak self] in
            if let sourceApp {
                sourceApp.activate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard let self else {
                    completion?()
                    return
                }
                let snapshot = PermissionCoordinator.shared.cachedSnapshot
                let shellLike = AXContextChecker.shared.isFrontmostShellLikeContext(focus: .live)
                guard let plan = self.planAITransformInject(
                    text: text, snapshot: snapshot, shellLike: shellLike,
                    bundleID: self.cachedFrontmostBundleID
                ) else {
                    completion?()
                    return
                }

                let carrier = snippet ?? SnippetModel(
                    title: "AI",
                    triggerKeyword: "",
                    replacementText: text
                )
                let suspension = EventTapEngine.shared.suspendMatching(reason: "aiTransformInject")
                TextInjectionPipeline.shared.inject(
                    snippet: carrier,
                    triggerLength: 0,
                    swallowed: .notSwallowed,
                    plan: plan,
                    erasePlan: .empty,
                    preResolvedText: text,
                    secureClipboardPaste: true,
                    completion: { _ in
                        suspension.release()
                        completion?()
                    }
                )
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// The planner's verdict on an AI transform's finished result, or `nil` after a refusal has
    /// been recorded.
    ///
    /// This refusal used to be a log line and a bare `completion?()`: the generated result was
    /// dropped and neither the matched-then-dropped counters nor the inject-outcome ring held any
    /// trace, so a report showed a transform that succeeded with no attempt to deliver it. It now
    /// lands in both, like every other abort of an AI transform (`aiTransformRefused`), with the
    /// planner's own reason on the outcome. No trigger key is owed back here — the trigger was
    /// erased before the model ran — so this is the recording half of `refuseAfterSwallow` only.
    func planAITransformInject(
        text: String,
        snapshot: PermissionSnapshot,
        shellLike: Bool,
        bundleID: String?
    ) -> InjectionPlan? {
        let plan = InjectionPlanner().plan(
            snapshot: snapshot,
            isTerminal: shellLike,
            needsCursorHID: false,
            isMultiLine: text.contains(where: \.isNewline)
        )
        guard case .refuse(let reason) = plan else { return plan }
        let safeReason = DevTypeLog.boundedPublicIdentifier(reason, label: "injectRefusal")
        DevTypeLog.eventTap.notice(
            "[EventTap] AI inject refused — \(safeReason, privacy: .public)"
        )
        recordMatchDrop(
            reason: MatchDropReason.aiTransformRefused.rawValue,
            trigger: nil,
            bundleID: bundleID
        )
        PermissionCoordinator.shared.recordInjectOutcome(
            .refused(reason),
            refuseContext: nil,
            path: "aiTransformPlannerRefused"
        )
        return nil
    }

    func finishDeferredInject(
        snippet: SnippetModel,
        triggerUTF16Length: Int,
        lastEventUTF16Count: Int,
        swallowed: SwallowedKey,
        terminator: String,
        eraseCountOverride: Int?,
        erasePlan: ErasePlan,
        resolved: MacroExpansionResult,
        clipboardSnapshot: String?,
        quiescence: InputQuiescenceGuard,
        armedFocusPID: pid_t?,
        textSuffix: String = "",
        gateFocus: AXUIElement? = nil
    ) {
        if let failure = resolved.failure {
            refuseAfterSwallow(
                reason: failure.message,
                drop: .renderFailed,
                erasePlan: erasePlan,
                swallowed: swallowed
            )
            return
        }
        if case .abort = inputClock.decide(quiescence) {
            refuseAfterSwallow(
                reason: "User input after arm — expand aborted",
                drop: .userInputAfterArm,
                erasePlan: erasePlan,
                swallowed: swallowed
            )
            return
        }

        let mainProbe = Self.runOnMainSync { () -> (currentPID: pid_t?, shellLike: Bool) in
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let shellLike = AXContextChecker.shared.isFrontmostShellLikeContext(
                focus: gateFocus.map { .resolved($0) } ?? .live
            )
            return (currentPID, shellLike)
        }

        if let armedFocusPID, mainProbe.currentPID != armedFocusPID {
            refuseAfterSwallow(
                reason: "Focus moved — expand aborted",
                drop: .focusMoved,
                erasePlan: erasePlan,
                swallowed: swallowed
            )
            return
        }

        let snapshot = PermissionCoordinator.shared.cachedSnapshot
        let shellLike = mainProbe.shellLike
        let needsCursor = InjectionPlanner.needsCursorHID(
            cursorOffset: resolved.cursorOffset,
            totalUTF16Length: resolved.text.utf16.count
        )
        let plan = InjectionPlanner().plan(
            snapshot: snapshot,
            isTerminal: shellLike,
            needsCursorHID: needsCursor,
            isMultiLine: resolved.text.contains(where: \.isNewline)
        )
        if case .refuse(let reason) = plan {
            refuseAfterSwallow(
                reason: reason,
                drop: .plannerRefused,
                erasePlan: erasePlan,
                swallowed: swallowed
            )
            return
        }

        let lookup = matchSnapshot.nestedResolver.lookup

        TextInjectionPipeline.shared.inject(
            snippet: snippet,
            triggerLength: triggerUTF16Length,
            swallowed: swallowed,
            clipboardOverride: clipboardSnapshot,
            lastEventCharacterCount: lastEventUTF16Count,
            plan: plan,
            terminator: terminator,
            eraseCountOverride: eraseCountOverride,
            erasePlan: erasePlan,
            preResolvedText: resolved.text + textSuffix,
            preResolvedCursorOffset: resolved.cursorOffset,
            trailingKeys: resolved.trailingKeys,
            snippetLookup: lookup,
            targetFocus: gateFocus.map { .resolved($0) } ?? .live
        ) { [weak self] outcome in
            if outcome.isConfirmedSuccess {
                DispatchQueue.main.async {
                    self?.onExpansionSucceeded?(snippet)
                }
            }
            self?.endExpansion()
        }
    }

    /// Records refuse and reinjects the swallowed key while `isExpanding` still suppresses rematch.
    ///
    /// The one owner of "a matched expansion was abandoned after the claim": `drop` is required,
    /// so no abort can leave the matched-then-dropped report reading "none" for a trigger that
    /// matched, was swallowed and never expanded. The inject outcome below is the refuse reason;
    /// the drop is the count a reader rules failures out with.
    private func refuseAfterSwallow(
        reason: String,
        drop: MatchDropReason,
        erasePlan: ErasePlan,
        swallowed: SwallowedKey,
        refuseContext: PermissionCoordinator.InjectRefuseProvenance? = nil
    ) {
        recordMatchDrop(
            reason: drop.rawValue,
            trigger: erasePlan.expectedText,
            bundleID: cachedFrontmostBundleID
        )
        // §8.2: the key's own `didSwallow` decides. This was a hard-coded `didSwallow: true`, and
        // the prefix-debounce fire — which swallows nothing — avoided a replay only because its
        // empty payload happened to fail `hasPayload` inside `reinjectSwallowedKey`.
        if swallowed.mustReinjectOnRefuse {
            _ = TextInjectionPipeline.shared.reinjectSwallowedKey(swallowed)
        }
        DispatchQueue.main.async {
            PermissionCoordinator.shared.recordInjectOutcome(
                .refused(reason),
                refuseContext: refuseContext
            )
        }
        endExpansion()
    }

    /// Hop to main for AppKit/AX without nested `main.sync` when already on main.
    private static func runOnMainSync<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }
}
