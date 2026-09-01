import AppKit
import ExpanderEngine

// MARK: - §4.8 / §1.10 (UI half) — one import flow instead of two
//
// The open panel, the format hint, the "Import Complete" alert, and the failure
// alert were duplicated between `AppDelegate.importSnippets(_:)` (:534-574) and
// `SnippetManagerViewController.importSnippets()` (:868-903), with different
// strings and different sheet behaviour. Both were also hardcoded English.
//
// This also moves the app onto the store's `ImportMode` API: `.merge` never
// removes a local snippet, where the old `importGroups` replaced same-named
// groups wholesale (§1.10) — so importing an Espanso `base.yml` no longer
// obliterates the user's `General` group. The returned `ImportSummary` gives the
// user a real added/updated/unchanged diff instead of a bare count.

enum SnippetImportFlow {

    /// Serializes imports. Two overlapping flows (menu bar + Preferences sheet)
    /// would race the store's read-modify-write merge and double-alert; the second
    /// caller is told one is already running instead of queueing silently.
    private static let stateLock = NSLock()
    private static var isImporting = false

    /// Presents the open panel, imports with `.merge`, and reports the result.
    /// `window` makes both the panel and the result alert sheets.
    static func present(
        from window: NSWindow?,
        store: SnippetStore = .shared,
        completion: (() -> Void)? = nil
    ) {
        let loc = LocalizationManager.shared
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = loc.s("alert.import.prompt")
        panel.message = loc.s("alert.import.message")

        if let first = SnippetImporter.detectedSources().first {
            panel.directoryURL = first.kind == .textExpander
                ? first.url.deletingLastPathComponent()
                : first.url
        }

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            perform(url: url, store: store, window: window, completion: completion)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.begin(completionHandler: finish)
        }
    }

    private static func perform(
        url: URL,
        store: SnippetStore,
        window: NSWindow?,
        completion: (() -> Void)?
    ) {
        let loc = LocalizationManager.shared
        stateLock.lock()
        if isImporting {
            stateLock.unlock()
            DevTypeAlert.info(
                title: loc.s("alert.import.inprogress.title"),
                message: loc.s("alert.import.inprogress.message"),
                window: window
            )
            return
        }
        isImporting = true
        stateLock.unlock()

        // Parse + preview + merge + save
        DispatchQueue.global(qos: .userInitiated).async { [store] in
            do {
                let parsed = try SnippetImporter.importFrom(url)
                DispatchQueue.main.async {
                    SnippetImportPreviewSheet.present(
                        from: window,
                        incomingGroups: parsed.groups,
                        existingGroups: store.loadGroups()
                    ) { mode, _ in
                        DispatchQueue.global(qos: .userInitiated).async {
                            let outcome: Result<
                                (result: SnippetImporter.ImportResult, summary: SnippetStore.ImportSummary),
                                Error
                            >
                            do {
                                outcome = .success(try store.importSnippets(from: url, mode: mode))
                            } catch {
                                outcome = .failure(error)
                            }
                            DispatchQueue.main.async {
                                stateLock.lock()
                                isImporting = false
                                stateLock.unlock()
                                report(outcome, window: window, loc: loc, completion: completion)
                            }
                        }
                    } onCancel: {
                        resetImportState()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    stateLock.lock()
                    isImporting = false
                    stateLock.unlock()
                    report(.failure(error), window: window, loc: loc, completion: completion)
                }
            }
        }
    }

    /// Runs `SnippetLibraryTagger` over the library and writes the result back.
    ///
    /// Reloads the groups inside the task rather than capturing them: the batch takes a model
    /// call per snippet, and writing back a snapshot taken minutes earlier would revert
    /// anything the user changed meanwhile.
    private static func tagImportedLibrary(window: NSWindow?, loc: LocalizationManager) {
        guard #available(macOS 26.0, *) else { return }
        #if canImport(FoundationModels)
        Task { @MainActor in
            let groups = SnippetStore.shared.loadGroups()
            let (updated, summary) = await SnippetLibraryTagger.tagLibrary(
                groups,
                engine: SnippetTagSuggester.foundationModelsEngine()
            )
            let outcome = SnippetStore.shared.saveGroups(updated)

            var message = loc.s(
                "alert.import.tagResult",
                summary.tagged,
                summary.noSuggestion,
                summary.skipped
            )
            // Never present a capped or cancelled run as full coverage.
            if !summary.isComplete {
                message += "\n" + loc.p(
                    "alert.import.tagResult.partial",
                    count: summary.notAttempted,
                    summary.notAttempted
                )
            }
            if !outcome.didSave {
                LibraryHealthMonitor.shared.refresh()
                message += "\n\n" + loc.s("library.save.banner")
            }
            DevTypeLog.app.info(
                "[Import] tagged=\(summary.tagged, privacy: .public) none=\(summary.noSuggestion, privacy: .public) skipped=\(summary.skipped, privacy: .public) notAttempted=\(summary.notAttempted, privacy: .public) saved=\(outcome.didSave, privacy: .public)"
            )
            DevTypeAlert.info(
                title: loc.s("alert.import.tagResult.title"),
                message: message,
                window: window
            )
        }
        #endif
    }

    private static func resetImportState() {
        stateLock.lock()
        isImporting = false
        stateLock.unlock()
    }

    private typealias ImportOutcome = Result<
        (result: SnippetImporter.ImportResult, summary: SnippetStore.ImportSummary),
        Error
    >

    private static func report(
        _ outcome: ImportOutcome,
        window: NSWindow?,
        loc: LocalizationManager,
        completion: (() -> Void)?
    ) {
        switch outcome {
        case .success(let (result, summary)):
            completion?()

            var body = loc.s(
                "alert.import.body",
                result.snippetCount,
                result.groupCount,
                result.kind.rawValue
            )
            body += "\n" + loc.s(
                "alert.import.summary",
                summary.snippetsAdded,
                summary.snippetsUpdated,
                summary.snippetsUnchanged
            )
            body += "\n" + result.sourcePath
            if !result.notes.isEmpty {
                body += "\n\n" + result.notes.joined(separator: "\n")
            }
            // §1.4: an import that could not be written must not read as success.
            if !summary.outcome.didSave {
                LibraryHealthMonitor.shared.refresh()
                body += "\n\n" + loc.s("library.save.banner")
            }

            DevTypeLog.app.info(
                "[Import] kind=\(result.kind.rawValue, privacy: .public) added=\(summary.snippetsAdded, privacy: .public) updated=\(summary.snippetsUpdated, privacy: .public) saved=\(summary.outcome.didSave, privacy: .public)"
            )
            // An import is the one moment a whole library arrives untagged: unless the source
            // carried `search_terms`, none of it is findable by tag or visible to the Tagged
            // filter. Offered rather than done — it spends real model time per snippet.
            let eligible = SnippetStore.shared.loadGroups()
                .flatMap(\.snippets)
                .filter(SnippetLibraryTagger.isEligible)
                .count
            if SnippetTagSuggester.isActive, eligible > 0 {
                DevTypeAlert.confirm(
                    title: loc.s("alert.import.title"),
                    message: body + "\n\n" + loc.p("alert.import.tagOffer", count: eligible, eligible),
                    confirmTitle: loc.s("alert.import.tagOffer.confirm"),
                    cancelTitle: loc.s("common.notNow"),
                    style: .informational,
                    window: window
                ) {
                    tagImportedLibrary(window: window, loc: loc)
                }
            } else {
                DevTypeAlert.info(
                    title: loc.s("alert.import.title"),
                    message: body,
                    window: window
                )
            }
        case .failure(let error):
            DevTypeLog.app.error(
                "[Import] failed: \(error.localizedDescription, privacy: .public)"
            )
            DevTypeAlert.warn(
                title: loc.s("alert.import.failed.title"),
                message: error.localizedDescription,
                window: window
            )
        }
    }
}
