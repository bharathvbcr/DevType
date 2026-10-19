import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

extension AppDelegate {
    /// Inject AI result after reactivating the source app. Uses `erasePlan: .empty`
    /// so clipboard paste replaces the live selection (hotkey) or inserts at the
    /// caret (typed path, where the trigger was already erased).
    ///
    /// This is the single delivery seam for every AI-generated result (hotkey direct,
    /// palette, preview Replace, typed-path preview Replace), so it carries the last
    /// line of prompt-leak defense: even if generation-side echo checks ever regress,
    /// a payload quoting unrecognized prompt text is refused here instead of being
    /// typed or pasted into a document. The stashed source selection exempts clauses
    /// the author's own text contains; refusal costs one alert and leaves the field
    /// untouched — never data loss.
    func injectAIReplacement(
        text: String,
        sourceApp: NSRunningApplication?,
        replacing: SelectionReplacement?
    ) {
        let verdict = AIPromptLeakGuard.injectionVerdict(
            payload: text,
            exempting: AIUndoStore.stashedOriginal()
        )
        guard verdict.isClean else {
            DevTypeLog.store.error(
                "[AI] injection refused at boundary — prompt leak guard matched"
            )
            AIDiagnosticsStore.shared.recordFailure(
                kind: "injection-boundary",
                error: "promptEcho",
                detail: "result still contained prompt text after generation checks"
            )
            DevTypeAlert.present(
                title: loc.s("ai.alert.failed.title"),
                message: AITransformFlow.localizedError(.promptEcho, loc: loc),
                style: .informational,
                buttons: [loc.s("common.ok")],
                handler: nil
            )
            sourceApp?.activate()
            return
        }
        SourceAppDelivery.perform(sourceApp: sourceApp, onUnavailable: { [self] cause in
            reportDeliveryTargetUnavailable(cause, path: "aiResultDelivery")
        }) { [self] shouldContinue in
            let snapshot = PermissionCoordinator.shared.cachedSnapshot
            let snippet = SnippetModel(
                title: "AI Transform",
                triggerKeyword: "",
                replacementText: text
            )
            let needsCursor = InjectionPlanner.needsCursorHID(
                cursorOffset: nil,
                totalUTF16Length: text.utf16.count
            )
            let isTerminal = AXContextChecker.shared.isFrontmostAppTerminal()
            let plan = InjectionPlanner().plan(
                snapshot: snapshot,
                isTerminal: isTerminal,
                needsCursorHID: needsCursor,
                isMultiLine: text.contains(where: \.isNewline)
            )
            if case .refuse(let reason) = plan {
                reportDeliveryPlanRefusal(reason: reason, path: "aiResultPlanRefused")
                return
            }

            // Named for this delivery, not copied from the secret path it was cloned from.
            // This string is printed verbatim in the diagnostic report as "held by <reason>",
            // so a suspension stuck during an AI delivery used to send whoever read the report
            // into the secrets subsystem. Matches the `path:` this same function already
            // reports its refusals under.
            let suspension = EventTapEngine.shared.suspendMatching(reason: "aiResultDelivery")
            TextInjectionPipeline.shared.inject(
                snippet: snippet,
                triggerLength: 0,
                swallowed: .notSwallowed,
                plan: plan,
                erasePlan: .empty,
                preResolvedText: text,
                secureClipboardPaste: true,
                shouldContinue: shouldContinue,
                replacingSelection: replacing,
                completion: { _ in
                    suspension.release()
                    self.refreshStatusItemUI()
                }
            )
        }
    }

    func expandFromSearch(_ snippet: SnippetModel, sourceApp: NSRunningApplication?) {
        let sourceApp = sourceApp ?? NSWorkspace.shared.frontmostApplication
        // Inline search: erase 0, no quiescence (palette typing would always abort).
        let clipboard = NSPasteboard.general.string(forType: .string)
        let lookup = nestedSnippetLookup()
        // A secret is fetched at the moment of use and injected verbatim. Never through
        // `MacroRenderer`: a password containing `{{` or `%` is not a template, and expanding
        // one would corrupt it silently — or resolve a nested `{{snippet:…}}` inside it.
        if snippet.isSecret {
            // Same gate as the copy path, and the same reason for it being in the resolver
            // rather than here: a second surface reading secrets is a second place to forget.
            SecretMenuFlow.resolve(snippet, loc: loc) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let value):
                    self.injectSearchExpansion(
                        snippet: snippet,
                        resolved: MacroExpansionResult(
                            text: value,
                            cursorOffset: nil,
                            trailingKeys: [],
                            fillFields: [],
                            needsFillIn: false
                        ),
                        sourceApp: sourceApp
                    )
                case .failure(.migrationRequired(let pendingCount)):
                    self.offerSecretMigration(for: snippet, pendingCount: pendingCount) { [weak self] in
                        self?.expandFromSearch(snippet, sourceApp: sourceApp)
                    }
                case .failure(.keychainLocked):
                    self.offerKeychainUnlock { [weak self] in
                        self?.expandFromSearch(snippet, sourceApp: sourceApp)
                    }
                case .failure(.authenticationCancelled):
                    break
                case .failure(.selectionChanged):
                    self.applyCopyResult(.failure(.selectionChanged), for: snippet)
                case .failure(.authenticationFailed(let reason)):
                    ToastPanel.show(
                        self.loc.s("secret.auth.failed"),
                        detail: reason,
                        symbol: "exclamationmark.lock.fill"
                    )
                case .failure:
                    DevTypeAlert.present(
                        title: self.loc.s("secret.missing.title"),
                        message: self.loc.s("secret.missing.message", snippet.displayTitle),
                        style: .warning,
                        buttons: [self.loc.s("common.ok")],
                        handler: nil
                    )
                }
            }
            return
        }

        let renderContext = MacroRenderContext(clipboardText: clipboard ?? "")
        let resolved = MacroRenderer.expand(
            content: snippet.replacementText,
            lookup: lookup,
            clipboardText: clipboard,
            context: renderContext
        )
        if resolved.needsFillIn {
            FillInPanel.present(title: snippet.displayTitle, fields: resolved.fillFields) { values in
                guard let values else { return }
                let filled = MacroRenderer.expand(
                    content: snippet.replacementText,
                    fillValues: values,
                    lookup: lookup,
                    clipboardText: clipboard,
                    context: renderContext
                )
                self.injectSearchExpansion(snippet: snippet, resolved: filled, sourceApp: sourceApp)
            }
            return
        }
        injectSearchExpansion(snippet: snippet, resolved: resolved, sourceApp: sourceApp)
    }

    private func injectSearchExpansion(
        snippet: SnippetModel,
        resolved: MacroExpansionResult,
        sourceApp: NSRunningApplication?
    ) {
        if let failure = resolved.failure {
            ToastPanel.show(failure.message, symbol: "exclamationmark.triangle.fill", preempt: true)
            return
        }
        SourceAppDelivery.perform(sourceApp: sourceApp, onUnavailable: { [self] cause in
            reportDeliveryTargetUnavailable(cause, path: "searchExpansionDelivery")
        }) { [self] shouldContinue in
            let snapshot = PermissionCoordinator.shared.cachedSnapshot
            let needsCursor = InjectionPlanner.needsCursorHID(
                cursorOffset: resolved.cursorOffset,
                totalUTF16Length: resolved.text.utf16.count
            )
            let isTerminal = AXContextChecker.shared.isFrontmostAppTerminal()
            let plan = InjectionPlanner().plan(
                snapshot: snapshot,
                isTerminal: isTerminal,
                needsCursorHID: needsCursor,
                isMultiLine: resolved.text.contains(where: \.isNewline)
            )
            if case .refuse(let reason) = plan {
                reportDeliveryPlanRefusal(reason: reason, path: "searchExpansionPlanRefused")
                return
            }

            let suspension = EventTapEngine.shared.suspendMatching(reason: "expandFromSearch")
            TextInjectionPipeline.shared.inject(
                snippet: snippet,
                triggerLength: 0,
                swallowed: .notSwallowed,
                plan: plan,
                eraseCountOverride: 0,
                preResolvedText: resolved.text,
                preResolvedCursorOffset: resolved.cursorOffset,
                trailingKeys: resolved.trailingKeys,
                secureClipboardPaste: true,
                shouldContinue: shouldContinue,
                completion: { [weak self] outcome in
                    suspension.release()
                    if outcome.isConfirmedSuccess {
                        SnippetStore.shared.incrementUsage(for: snippet.id)
                        self?.recordRecent(snippet)
                    }
                    self?.refreshStatusItemUI()
                }
            )
        }
    }
}
