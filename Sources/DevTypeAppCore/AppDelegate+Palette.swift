import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

extension AppDelegate {
    /// Hybrid palette commit: AI → `AITransformFlow`, date/clipboard → inject, navigate → windows.
    ///
    /// `selection` is captured at panel-open time by `InlineSearchPanel`. It must not be
    /// re-read here: the panel is key by now, so a live `SelectionReader` read resolves to
    /// our own search field and yields nil.
    func handlePaletteCommand(
        _ command: PaletteCommand,
        insertText: String,
        sourceApp: NSRunningApplication?,
        selection: SelectionReader.Outcome
    ) {
        // Ephemeral rows are built from the query text, so their ids are unique per keystroke
        // and resolve to nothing in the catalogue. Recording them grew the stats file forever.
        if !command.isEphemeral {
            CommandUsageStatsStore.shared.recordUsage(for: command.id)
        }

        switch command.action {
        case .ai(let kind):
            runPaletteAI(
                kind: kind,
                customInstructions: nil,
                sourceApp: sourceApp,
                selection: selection
            )

        case .aiCustom(let instructions):
            runPaletteAI(
                kind: .custom,
                customInstructions: instructions,
                sourceApp: sourceApp,
                selection: selection
            )

        case .date, .clipboard, .generate, .insert:
            guard !insertText.isEmpty else {
                if case .clipboard = command.action {
                    DevTypeAlert.info(
                        title: loc.s("palette.tool.clipboard"),
                        message: loc.s("palette.tool.clipboard.empty")
                    )
                }
                sourceApp?.activate()
                return
            }
            injectPaletteText(insertText, sourceApp: sourceApp)

        case .textOp(let op):
            // Captured at panel-open; a live read here would always miss and silently
            // fall through to the clipboard, transforming the wrong text with no warning.
            let source = selection.result?.text
                ?? NSPasteboard.general.string(forType: .string)
                ?? ""
            guard !SelectionReader.isBlankSelection(source) else {
                DevTypeAlert.info(
                    title: loc.s(command.titleKey),
                    message: selection.failure?.message(loc: loc)
                        ?? loc.s("ai.alert.noSelection.message")
                )
                sourceApp?.activate()
                return
            }
            injectPaletteText(PaletteTextOps.apply(op, to: source), sourceApp: sourceApp)

        case .count:
            sourceApp?.activate()

        case .undoAI:
            guard let original = AIUndoStore.consume() else {
                sourceApp?.activate()
                return
            }
            injectPaletteText(original, sourceApp: sourceApp)

        case .voiceDictation:
            VoiceDictationController.shared.toggleDictation(sourceApp: sourceApp)

        case .navigate(let target):
            switch target {
            case .preferences:
                openPreferences(nil)
            case .manageSnippets:
                openSnippetManager(nil)
            case .permissionRecovery:
                openPermissionRecovery(nil)
            case .voicePreferences:
                openPreferences(nil, tab: .voice)
            case .createSnippet:
                // `selection` was captured when the palette opened. Reading it again now
                // would see this panel's own field and drop the user's text.
                let draft = SnippetManagerViewController.SelectionSnippetDraft
                    .make(fromCapturedText: selection.result?.text)
                presentNewSnippet(draft: draft)
            case .toggleExpansion:
                toggleEngine(NSMenuItem())
            case .importLibrary:
                openSnippetManager(nil)
                SnippetImportFlow.present(from: snippetWindowController?.window)
            case .exportLibrary:
                openSnippetManager(nil)
                LibraryExporter.present(from: snippetWindowController?.window)
            case .testExpansionLab:
                TestExpansionLab.run(from: snippetWindowController?.window)
            case .keyboardShortcuts:
                ShortcutReferenceWindowController.show()
            case .recentActivity:
                ActivityCenterViewController.show()
            }
        }
    }

    private func runPaletteAI(
        kind: AITransformKind,
        customInstructions: String?,
        sourceApp: NSRunningApplication?,
        selection: SelectionReader.Outcome
    ) {
        // Supersedes any earlier palette AI action still waiting on focus or on its selection read.
        paletteAIGeneration &+= 1
        guard AIPreferences.isEnabled else {
            DevTypeAlert.info(
                title: loc.s("ai.alert.disabled.title"),
                message: loc.s("ai.alert.disabled.message")
            )
            return
        }
        // A local kind needs no model, so the availability gate does not apply to it.
        // The master AI switch above still does: this action lives on the AI surface, and
        // a user who turned that surface off should not find one of its rows still firing.
        if kind.requiresModel {
            switch AITextTransformSupport.availability {
            case .available:
                break
            case .unavailable(let reason):
                DevTypeAlert.info(
                    title: loc.s("ai.alert.unavailable.title"),
                    message: AITransformFlow.localizedAvailability(reason, loc: loc)
                )
                return
            }
        }

        switch selection {
        case .selection(let resolved):
            startPaletteAITransform(
                resolved,
                kind: kind,
                customInstructions: customInstructions,
                sourceApp: sourceApp
            )

        case .failure(.noFocusedElement):
            // The command palette captured before stealing focus, but some custom editors
            // (including Codex) publish no focused AX element. Do not synthesize ⌘C merely
            // because the general palette opened: wait until the user explicitly chooses an AI
            // action, return focus to the source, then use the same brokered fallback as the
            // dedicated AI hotkey. Polling the actual frontmost pid is load-bearing — posting
            // before activation completes would copy from DevType's own search field.
            guard let sourceApp else {
                presentPaletteSelectionFailure(.noFocusedElement, sourceApp: nil)
                return
            }
            sourceApp.activate()
            retryPaletteAISelectionAfterFocus(
                kind: kind,
                customInstructions: customInstructions,
                sourceApp: sourceApp
            )

        case .failure(let failure):
            presentPaletteSelectionFailure(failure, sourceApp: sourceApp)
        }
    }

    /// Wait for AppKit to finish activating the source before a fallback that may post ⌘C.
    /// Transition policy and bounds live in `SelectionReader`; this method only schedules.
    private func retryPaletteAISelectionAfterFocus(
        kind: AITransformKind,
        customInstructions: String?,
        sourceApp: NSRunningApplication,
        remainingPolls: Int = SelectionReader.sourceFocusMaxPolls
    ) {
        // Neither the focus wait nor the off-main read blocks main, so the user can start another
        // palette AI action in the meantime. Only the latest may read — the read can post ⌘C — and
        // only the latest may act on what it read.
        let generation = paletteAIGeneration
        switch SelectionReader.sourceFocusRetryDecision(
            sourcePID: sourceApp.processIdentifier,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            sourceTerminated: sourceApp.isTerminated,
            remainingPolls: remainingPolls
        ) {
        case .wait(let nextRemainingPolls):
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SelectionReader.sourceFocusPollInterval
            ) { [weak self] in
                guard let self, self.paletteAIGeneration == generation else { return }
                self.retryPaletteAISelectionAfterFocus(
                    kind: kind,
                    customInstructions: customInstructions,
                    sourceApp: sourceApp,
                    remainingPolls: nextRemainingPolls
                )
            }

        case .read:
            SelectionReader.readSelectionForExplicitAIAction { [weak self] outcome in
                guard let self, self.paletteAIGeneration == generation else { return }
                switch outcome {
                case .selection(let resolved):
                    self.startPaletteAITransform(
                        resolved,
                        kind: kind,
                        customInstructions: customInstructions,
                        sourceApp: sourceApp
                    )
                case .failure(let failure):
                    self.presentPaletteSelectionFailure(failure, sourceApp: sourceApp)
                }
            }

        case .fail:
            presentPaletteSelectionFailure(.noFocusedElement, sourceApp: sourceApp)
        }
    }

    private func startPaletteAITransform(
        _ resolved: SelectionReader.Result,
        kind: AITransformKind,
        customInstructions: String?,
        sourceApp: NSRunningApplication?
    ) {
        let picked = AIActionSelection(kind: kind, customInstructions: customInstructions)
        AITransformFlow.run(
            input: resolved.text,
            kind: picked.kind,
            sourceApp: sourceApp,
            customInstructions: picked.customInstructions,
            forcePreview: picked.requiresPreview,
            replacing: resolved.replacement,
            loc: loc
        ) { [weak self] text, app, replacing in
            self?.injectAIReplacement(text: text, sourceApp: app, replacing: replacing)
        }
    }

    private func presentPaletteSelectionFailure(
        _ failure: SelectionReader.Failure,
        sourceApp: NSRunningApplication?
    ) {
        DevTypeAlert.info(
            title: failure.title(loc: loc),
            message: failure.message(loc: loc)
        )
        sourceApp?.activate()
    }

    /// Shared `onUnavailable` for every panel-driven delivery.
    ///
    /// By this point the payload is already resolved — a finished AI transform, a rendered
    /// macro, a palette value — so giving up here destroys work the user watched happen. All
    /// three call sites used to show a toast and record nothing, which is why a diagnostic
    /// report could show a transform that succeeded with no inject attempt anywhere beside it.
    func reportDeliveryTargetUnavailable(
        _ cause: SelectionReader.SourceUnavailability,
        path: String
    ) {
        PermissionCoordinator.shared.recordInjectOutcome(
            .refused(cause.reason),
            refuseContext: nil,
            path: path
        )
        // `.ownProcess` is the one cause with advice attached: the command ran with our own
        // window in front, so there is no other app to insert into. "Target changed" is wrong
        // there — nothing changed, and the app the toast implies the user should return to is
        // the one they are already looking at.
        let message = cause == .ownProcess
            ? loc.s("delivery.fail.ownProcess")
            : loc.s("voice.error.targetChanged")
        ToastPanel.show(message, symbol: "exclamationmark.triangle.fill")
    }

    /// Shared refusal for a delivery whose `InjectionPlanner` plan is `.refuse`.
    ///
    /// The planner only refuses on a missing capability (Accessibility revoked, or Post Events
    /// missing in a terminal), so the reason is actionable and belongs in front of the user —
    /// these call sites used to drop it with a bare `return`.
    ///
    /// Shown through `sanitizedRefusalReason` rather than raw: the planner's own strings are
    /// internal prose ("refusing expand (fail-closed)"), and that sanitizer is already the
    /// vocabulary the status UI and the diagnostic report speak.
    func reportDeliveryPlanRefusal(reason: String, path: String) {
        PermissionCoordinator.shared.recordInjectOutcome(
            .refused(reason),
            refuseContext: nil,
            path: path
        )
        ToastPanel.show(
            PermissionCoordinator.sanitizedRefusalReason(reason, path: path),
            symbol: "exclamationmark.triangle.fill",
            preempt: true
        )
    }

    /// Insert resolved palette text (date tools / clipboard) with eraseCount 0, like hotkey insertText.
    private func injectPaletteText(_ text: String, sourceApp: NSRunningApplication?) {
        SourceAppDelivery.perform(sourceApp: sourceApp, onUnavailable: { [self] cause in
            reportDeliveryTargetUnavailable(cause, path: "paletteTextDelivery")
        }) { [self] shouldContinue in
            TextInjectionPipeline.shared.inject(
                snippet: SnippetModel(title: "Palette", triggerKeyword: "", replacementText: text),
                triggerLength: 0,
                swallowed: .notSwallowed,
                eraseCountOverride: 0,
                preResolvedText: text,
                secureClipboardPaste: true,
                shouldContinue: shouldContinue,
                completion: { [weak self] _ in
                    self?.refreshStatusItemUI()
                }
            )
        }
    }

    func presentAIPalette() {
        AITransformFlow.presentFromHotkey { [weak self] text, sourceApp, replacing in
            self?.injectAIReplacement(text: text, sourceApp: sourceApp, replacing: replacing)
        }
    }
}
