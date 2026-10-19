import AppKit
import Carbon
import ExpanderEngine
import ServiceManagement

extension AppDelegate {
    /// Opens the snippet editor on `draft` and saves nothing. `nil` is a blank snippet.
    func presentNewSnippet(draft: SnippetModel?) {
        openSnippetManager(nil)
        (snippetWindowController?.contentViewController as? SnippetManagerViewController)?
            .presentNewSnippetDraft(draft)
    }

    /// Services menu: "New DevType Snippet from Selection". The pasteboard is the
    /// selection the sending app already captured. Do not read Accessibility again.
    ///
    /// `userData` and `error` are optional because Services omits `NSUserData` and may
    /// pass a NULL error pointer. A non-optional `String` traps on that NULL.
    @objc func newSnippetFromSelection(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        _ = userData
        let text = SnippetManagerViewController.SelectionSnippetDraft.serviceText(from: pboard)
        guard let draft = SnippetManagerViewController.SelectionSnippetDraft.make(fromCapturedText: text) else {
            // Not the AI-palette alert. This menu item is not the AI palette.
            error?.pointee = loc.s("ai.refuse.noSelection") as NSString
            return
        }
        presentNewSnippet(draft: draft)
    }

    /// `devtype://` entry point. Registered via `CFBundleURLTypes` only — there is
    /// no `kAEGetURL` handler, which would run this a second time.
    public func application(_ application: NSApplication, open urls: [URL]) {
        let origin = urlOriginBundleIdentifier()
        var refused = false
        for url in urls where !performDevTypeURL(url, origin: origin) {
            refused = true
        }
        guard refused else { return }
        DevTypeAlert.warn(
            title: loc.s("url.refuse.unknown"),
            message: loc.s("url.refuse.unknown")
        )
    }

    /// Bundle id of the process that sent the current Apple Event, when macOS provides one.
    /// The id is bounded before it is logged. Query values are not part of this string.
    private func urlOriginBundleIdentifier() -> String? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pidValue = event.attributeDescriptor(forKeyword: keySenderPIDAttr) else {
            return nil
        }
        let pid = pid_t(pidValue.int32Value)
        guard pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Performs one URL. Returns false when the URL is not an allowlisted command.
    /// Copy of a secret returns true: it was understood, and it was refused. The
    /// refusal does not read `SecretStore` and does not call `copyToClipboard`.
    private func performDevTypeURL(_ url: URL, origin: String?) -> Bool {
        switch DevTypeURLParser.parse(url.absoluteString) {
        case .failure(let failure):
            let result: String
            switch failure {
            case .foreignHost: result = "foreign-host"
            case .unknownAction: result = "unknown-action"
            case .malformed: result = "malformed"
            case .oversized: result = "oversized"
            }
            DevTypeLog.app.info(
                "\(DevTypeURLAudit.line(action: "url", result: result, originBundleIdentifier: origin), privacy: .public)"
            )
            return false
        case .command(let command):
            switch command {
            case .newSnippet(let title, let trigger, let text):
                DevTypeLog.app.info(
                    "\(DevTypeURLAudit.line(action: "new", result: "editor", originBundleIdentifier: origin), privacy: .public)"
                )
                presentNewSnippet(draft: DevTypeURLCommand.editorDraft(
                    title: title, trigger: trigger, text: text
                ))
            case .palette:
                DevTypeLog.app.info(
                    "\(DevTypeURLAudit.line(action: "palette", result: "opened", originBundleIdentifier: origin), privacy: .public)"
                )
                toggleInlineSearch(nil)
            case .preferences(let tab):
                DevTypeLog.app.info(
                    "\(DevTypeURLAudit.line(action: "preferences", result: "opened", originBundleIdentifier: origin), privacy: .public)"
                )
                openPreferences(nil, tab: preferencesTab(for: tab))
            case .toggleDictation:
                DevTypeLog.app.info(
                    "\(DevTypeURLAudit.line(action: "dictation", result: "needs-confirm", originBundleIdentifier: origin), privacy: .public)"
                )
                DevTypeAlert.confirm(
                    title: loc.s("url.confirm.dictation.title"),
                    message: loc.s("url.confirm.dictation.message"),
                    confirmTitle: loc.s("common.ok")
                ) {
                    VoiceDictationController.shared.toggleDictation(sourceApp: nil)
                }
            case .copy(let trigger):
                performCopyURL(trigger: trigger, origin: origin)
            }
            return true
        }
    }

    private func preferencesTab(for tab: DevTypePreferencesTab?) -> PreferencesTab? {
        switch tab {
        case .home: return .home
        case .general: return .general
        case .snippets: return .snippets
        case .hotkeys: return .hotkeys
        case .voice: return .voice
        case .ai: return .ai
        case .advanced: return .advanced
        case nil: return nil
        }
    }

    /// Confirms, then uses the existing non-secret copy path. A secret never reaches
    /// `copyToClipboard`: the decision returns before the value is read.
    private func performCopyURL(trigger: String, origin: String?) {
        let decision = DevTypeURLCopy.decide(trigger: trigger, in: SnippetStore.shared.allSnippets)
        let audit: DevTypeURLCopyAudit.Result
        switch decision {
        case .confirm(let snippet):
            audit = .needsConfirm
            DevTypeLog.app.info(
                "\(DevTypeURLCopyAudit.line(result: audit, originBundleIdentifier: origin), privacy: .public)"
            )
            DevTypeAlert.confirm(
                title: loc.s("url.confirm.copy.title"),
                message: loc.s("url.confirm.copy.message"),
                confirmTitle: loc.s("common.copy")
            ) { [weak self] in
                self?.copyToClipboard(snippet)
            }
        case .refusedSecret:
            audit = .refusedSecret
            DevTypeLog.app.info(
                "\(DevTypeURLCopyAudit.line(result: audit, originBundleIdentifier: origin), privacy: .public)"
            )
            DevTypeAlert.warn(
                title: loc.s("url.refuse.secret"),
                message: loc.s("url.refuse.secret")
            )
        case .notFound:
            audit = .notFound
            DevTypeLog.app.info(
                "\(DevTypeURLCopyAudit.line(result: audit, originBundleIdentifier: origin), privacy: .public)"
            )
            DevTypeAlert.warn(
                title: loc.s("url.refuse.missing"),
                message: loc.s("url.refuse.missing")
            )
        case .ambiguous:
            audit = .ambiguous
            DevTypeLog.app.info(
                "\(DevTypeURLCopyAudit.line(result: audit, originBundleIdentifier: origin), privacy: .public)"
            )
            DevTypeAlert.warn(
                title: loc.s("url.refuse.ambiguous"),
                message: loc.s("url.refuse.ambiguous")
            )
        }
    }
}
