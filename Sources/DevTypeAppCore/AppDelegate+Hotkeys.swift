import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

extension AppDelegate {
    func bindSnippetStore() {
        SnippetStore.shared.addGroupListener { [weak self] groups in
            let snippets = SnippetStore.expandableSnippets(in: groups)
            EventTapEngine.shared.applySnippetSnapshot(snippets)
            DispatchQueue.main.async {
                guard let self else { return }
                self.recentSnippetIDs = RecentSnippetResolver.reconcile(
                    self.recentSnippetIDs,
                    with: snippets
                )
                self.rebuildSecretsMenu()
                self.rebuildRecentMenu()
            }
        }
    }

    /// Offers to turn a phrase you keep typing into a snippet.
    ///
    /// Presented once, when the phrase crosses the threshold — declining forgets that phrase so
    /// the same offer cannot come back on the next repeat and become nagging.
    func wireRepetitionSuggestions() {
        EventTapEngine.shared.onRepetitionNoticed = { [weak self] candidate in
            guard let self else { return }
            let preview = candidate.text.count > 60
                ? String(candidate.text.prefix(60)) + "…"
                : candidate.text
            // You typed it three times by hand. If a snippet already covers it, what you needed
            // was the trigger — not a second copy of the same body in the library.
            if let existing = RepeatedPhraseLookup.existingSnippet(
                for: candidate.text, in: SnippetStore.shared.loadGroups()
            ) {
                DevTypeAlert.info(
                    title: self.loc.s("repetition.reminder.title"),
                    message: self.loc.s(
                        "repetition.reminder.body", existing.triggerKeyword, preview
                    )
                )
            } else {
                DevTypeAlert.confirm(
                    title: self.loc.s("repetition.offer.title"),
                    message: self.loc.s("repetition.offer.body", candidate.occurrences, preview),
                    confirmTitle: self.loc.s("repetition.offer.confirm"),
                    cancelTitle: self.loc.s("repetition.offer.dismiss"),
                    style: .informational
                ) {
                    self.presentSnippetEditorForRepetition(candidate)
                }
            }
            // Whether or not they take it, this phrase has had its one offer.
            TypedRepetitionDetector.shared.forget(phrase: candidate.text)
        }
    }

    private func presentSnippetEditorForRepetition(_ candidate: TypedRepetitionDetector.Candidate) {
        let draft = SnippetModel(
            title: SnippetEditorSheet.derivedTitle(from: candidate.text),
            triggerKeyword: "",
            replacementText: candidate.text
        )
        let store = SnippetStore.shared
        let groups = store.loadGroups()
        SnippetEditorSheet.present(
            from: nil,
            existing: nil,
            draft: draft,
            groups: groups,
            currentGroupID: groups.first?.id,
            completion: { snippet, chosenGroupID in
                .mutating(
                    store: store,
                    mutation: { latest in
                        guard let after = SnippetLibraryEdit.applying(
                            snippet: snippet,
                            existingID: nil,
                            chosenGroupID: chosenGroupID,
                            fallbackGroupID: latest.first?.id,
                            to: latest
                        ) else { return false }
                        latest = after
                        return true
                    },
                    finalize: { _, _ in }
                )
            }
        )
    }

    func wireExpansionUsage() {
        EventTapEngine.shared.onExpansionSucceeded = { [weak self] snippet in
            SnippetStore.shared.incrementUsage(for: snippet.id)
            self?.recordRecent(snippet)
        }
        EventTapEngine.shared.presentFillIn = { title, fields, completion in
            _ = FillInPanel.present(title: title, fields: fields, completion: completion)
        }
        // Typed AI path handoff — always preview in phase 1.
        EventTapEngine.shared.presentAITransform = { [weak self] input, kind, sourceApp, customInstructions, restoreOnCancel in
            AITransformFlow.presentFromEngine(
                input: input,
                kind: kind,
                sourceApp: sourceApp,
                customInstructions: customInstructions,
                restoreOnCancel: restoreOnCancel
            ) { text, app, replacing in
                self?.injectAIReplacement(text: text, sourceApp: app, replacing: replacing)
            }
        }
        EventTapEngine.shared.presentAITransformHint = { [weak self] titleKey, messageKey in
            guard let self else { return }
            DevTypeAlert.info(
                title: self.loc.s(titleKey),
                message: self.loc.s(messageKey)
            )
        }
    }

    func registerHotkeys() {
        hotkeyManager.onInlineSearch = { [weak self] in
            self?.toggleInlineSearch(nil)
        }
        hotkeyManager.onAIPalette = { [weak self] in
            self?.presentAIPalette()
        }
        hotkeyManager.onVoiceDictation = {
            VoiceDictationController.shared.toggleDictation()
        }
        hotkeyManager.onInsertText = { text in
            TextInjectionPipeline.shared.inject(
                snippet: SnippetModel(title: "Hotkey", triggerKeyword: "", replacementText: text),
                triggerLength: 0,
                swallowed: .notSwallowed,
                eraseCountOverride: 0,
                preResolvedText: text,
                secureClipboardPaste: true,
                completion: nil
            )
        }
        hotkeyManager.onOpenURL = { urlString in
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
        // §4.2: `RegisterEventHotKey` failure used to be a log line and nothing
        // else, so a shortcut another app had claimed just never worked.
        hotkeyManager.onRegistrationFailed = { [weak self] label, status in
            guard let self else { return }
            DispatchQueue.main.async {
                ActivityHistoryStore.publish(
                    .hotkeyRegistrationFailed(status: Int32(status))
                )
                // Preferences reports its own failure inline; don't double-alert.
                if PreferencesWindowController.shared.window?.isVisible == true { return }
                DevTypeAlert.present(
                    title: self.loc.s("prefs.hotkeys.failed.title"),
                    message: self.loc.s("prefs.hotkeys.failed.message", label, Int(status)),
                    style: .warning,
                    buttons: [self.loc.s("menu.preferences"), self.loc.s("common.ok")]
                ) { index in
                    if index == 0 { self.openPreferences(nil, tab: .hotkeys) }
                }
            }
        }
        hotkeyManager.registerAll()
        VoiceDictationController.shared.performLaunchRecovery()
    }

    @objc func startSmartDictation(_ sender: Any?) {
        VoiceDictationController.shared.toggleDictation()
    }

    /// Records the reason for an otherwise-silent `SIGABRT`.
    ///
    /// The two palette crashes that motivated §8.7 shipped `.ips` reports whose only
    /// application-specific information was `abort() called` — no exception name, no
    /// reason, because the raiser (`-[NSRemoteView containingWindowWillOrderOnScreen:]`)
    /// catches and rethrows, which loses AppKit's default logging. Diagnosing them cost a
    /// debugger session. This puts the name, a content-free reason fingerprint, and a bounded
    /// frame count into the unified log first, so the next one is correlatable without exporting
    /// filesystem paths embedded in symbolicated frames.
    ///
    /// This does not prevent the abort — nothing can, once an exception is uncaught. It
    /// only makes the crash diagnosable. Preventing a specific crash is the job of an
    /// ObjC `@catch` at the boundary that raises, as in
    /// `DTMakeKeyAndOrderFrontCatchingException`.
    func installLastResortExceptionLogger() {
        NSSetUncaughtExceptionHandler { exception in
            DevTypeLog.app.fault(
                """
                [Crash] uncaught \(DevTypeLog.boundedPublicIdentifier(exception.name.rawValue, label: "exceptionName"), privacy: .public): \
                \(DevTypeLog.publicTextMetadata(exception.reason), privacy: .public)
                stackFrames=\(exception.callStackReturnAddresses.count, privacy: .public)
                """
            )
        }
    }

    @objc func toggleInlineSearch(_ sender: Any?) {
        InlineSearchPanel.toggle { [weak self] pick, sourceApp, selection in
            guard let self else { return }
            switch pick {
            case .snippet(let snippet):
                self.expandFromSearch(snippet, sourceApp: sourceApp)
            case .command(let command, let insertText):
                self.handlePaletteCommand(
                    command,
                    insertText: insertText,
                    sourceApp: sourceApp,
                    selection: selection
                )
            }
        }
    }
}
