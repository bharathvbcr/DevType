import AppKit
import ExpanderEngine

/// Rebases slow, model-generated tag suggestions onto the current library. Suggestions are tied
/// to the exact title/body/secret state and group context the model saw; unrelated changes such as
/// enabled state may coexist, while moved, edited, deleted, already-tagged, or ambiguous duplicate
/// UUID targets are skipped instead of restoring the minutes-old input snapshot.
struct SnippetTagSuggestionMerge {
    struct Summary: Equatable {
        var applied: Int
        var stale: Int
    }

    private struct Candidate {
        let groupID: UUID
        let groupName: String
        let snippetID: UUID
        let title: String
        let replacementText: String
        let isSecret: Bool
        let priorTags: [String]
        let suggestedTags: [String]
    }

    private let candidates: [Candidate]

    init(baseline: [SnippetGroup], tagged: [SnippetGroup]) {
        // Indexed once. The nested `first(where:)` this replaces rescanned the tagged library
        // for every baseline snippet, so tagging a whole library was quadratic in its size.
        var taggedGroupsByID: [UUID: SnippetGroup] = [:]
        for group in tagged where taggedGroupsByID[group.id] == nil {
            taggedGroupsByID[group.id] = group
        }
        var taggedSnippetsByGroup: [UUID: [UUID: SnippetModel]] = [:]
        for (groupID, group) in taggedGroupsByID {
            var byID: [UUID: SnippetModel] = [:]
            // First occurrence wins, matching `first(where:)`.
            for snippet in group.snippets where byID[snippet.id] == nil {
                byID[snippet.id] = snippet
            }
            taggedSnippetsByGroup[groupID] = byID
        }

        var changes: [Candidate] = []
        for baselineGroup in baseline {
            guard taggedGroupsByID[baselineGroup.id] != nil,
                  let taggedSnippets = taggedSnippetsByGroup[baselineGroup.id] else { continue }
            for baselineSnippet in baselineGroup.snippets {
                guard let taggedSnippet = taggedSnippets[baselineSnippet.id],
                      taggedSnippet.tags != baselineSnippet.tags else { continue }
                changes.append(Candidate(
                    groupID: baselineGroup.id,
                    groupName: baselineGroup.name,
                    snippetID: baselineSnippet.id,
                    title: baselineSnippet.title,
                    replacementText: baselineSnippet.replacementText,
                    isSecret: baselineSnippet.isSecret,
                    priorTags: baselineSnippet.tags,
                    suggestedTags: taggedSnippet.tags
                ))
            }
        }
        candidates = changes
    }

    func apply(to groups: inout [SnippetGroup]) -> Summary {
        var summary = Summary(applied: 0, stale: 0)
        // Every occurrence of each snippet ID, found in one pass rather than one full scan of
        // the library per candidate. A duplicate UUID still yields more than one location and
        // is still refused below — this changes the cost, not the rule.
        var locationsByID: [UUID: [(group: Int, snippet: Int)]] = [:]
        for groupIndex in groups.indices {
            for snippetIndex in groups[groupIndex].snippets.indices {
                let id = groups[groupIndex].snippets[snippetIndex].id
                locationsByID[id, default: []].append((groupIndex, snippetIndex))
            }
        }

        for candidate in candidates {
            let locations = locationsByID[candidate.snippetID] ?? []
            guard locations.count == 1, let location = locations.first else {
                summary.stale += 1
                continue
            }
            let group = groups[location.group]
            let snippet = group.snippets[location.snippet]
            guard group.id == candidate.groupID,
                  group.name == candidate.groupName,
                  snippet.title == candidate.title,
                  snippet.replacementText == candidate.replacementText,
                  snippet.isSecret == candidate.isSecret,
                  snippet.tags == candidate.priorTags else {
                summary.stale += 1
                continue
            }

            groups[location.group].snippets[location.snippet].tags = candidate.suggestedTags
            summary.applied += 1
        }
        return summary
    }
}

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

    /// Serializes parse, preview, and commit as one user-visible operation. In particular, the
    /// immutable prepared plan remains owned until the preview is cancelled or that exact plan is
    /// committed; a second entry point can never race it with a second read-modify-write.
    private static let operationGate = SnippetOperationGate()

    /// Presents the open panel, imports with `.merge`, and reports the result.
    /// `window` makes both the panel and the result alert sheets.
    static func present(
        from window: NSWindow?,
        store: SnippetStore = .shared,
        completion: (() -> Void)? = nil
    ) {
        let loc = LocalizationManager.shared
        guard operationGate.begin() else {
            DevTypeAlert.info(
                title: loc.s("alert.import.inprogress.title"),
                message: loc.s("alert.import.inprogress.message"),
                window: window
            )
            return
        }

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
            guard response == .OK, let url = panel.url else {
                resetImportState()
                return
            }
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
        let parsingProgress = DevTypeProgressPresentation.present(
            title: loc.s("alert.import.progress.parsing.title"),
            message: loc.s("alert.import.progress.parsing.message"),
            window: window
        )

        // Parse once, preview that value, then commit the chosen mode.
        DispatchQueue.global(qos: .userInitiated).async { [store] in
            do {
                let plan = try SnippetImporter.prepareImport(from: url)
                let preview = store.previewImport(plan)
                DispatchQueue.main.async {
                    parsingProgress.dismiss()
                    SnippetImportPreviewSheet.present(
                        from: window,
                        preview: preview
                    ) { mode in
                        let committingProgress = DevTypeProgressPresentation.present(
                            title: loc.s("alert.import.progress.committing.title"),
                            message: loc.s("alert.import.progress.committing.message"),
                            window: window
                        )
                        DispatchQueue.global(qos: .userInitiated).async {
                            let outcome: Result<
                                (result: SnippetImporter.ImportResult, summary: SnippetStore.ImportSummary),
                                Error
                            >
                            outcome = .success(store.commitImport(preview.plan, mode: mode))
                            DispatchQueue.main.async {
                                committingProgress.dismiss()
                                operationGate.finish()
                                report(outcome, window: window, loc: loc, completion: completion)
                            }
                        }
                    } onCancel: {
                        resetImportState()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    parsingProgress.dismiss()
                    operationGate.finish()
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
            let merge = SnippetTagSuggestionMerge(baseline: groups, tagged: updated)
            var commitSummary = SnippetTagSuggestionMerge.Summary(applied: 0, stale: 0)
            let mutation = SnippetStore.shared.mutateGroups { latest in
                commitSummary = merge.apply(to: &latest)
                return true
            }
            let outcome = mutation.saveOutcome ?? .blockedByRemoteChange
            var reportedSummary = summary
            reportedSummary.tagged = outcome.didSave ? commitSummary.applied : 0
            reportedSummary.skipped += commitSummary.stale

            var message = loc.s(
                "alert.import.tagResult",
                reportedSummary.tagged,
                reportedSummary.noSuggestion,
                reportedSummary.skipped
            )
            // Never present a capped or cancelled run as full coverage.
            if !reportedSummary.isComplete {
                message += "\n" + loc.p(
                    "alert.import.tagResult.partial",
                    count: reportedSummary.notAttempted,
                    reportedSummary.notAttempted
                )
            }
            if !outcome.didSave {
                LibraryHealthMonitor.shared.refresh()
                message += "\n\n" + loc.s("library.save.banner")
            }
            DevTypeLog.app.info(
                "[Import] tagged=\(reportedSummary.tagged, privacy: .public) none=\(reportedSummary.noSuggestion, privacy: .public) skipped=\(reportedSummary.skipped, privacy: .public) stale=\(commitSummary.stale, privacy: .public) notAttempted=\(reportedSummary.notAttempted, privacy: .public) saved=\(outcome.didSave, privacy: .public)"
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
        operationGate.finish()
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
            guard summary.outcome.didSave else {
                ActivityHistoryStore.publish(.importFailed)
                LibraryHealthMonitor.shared.refresh()
                DevTypeLog.app.error(
                    "[Import] commit refused outcome=\(summary.outcome.diagnosticLabel, privacy: .public)"
                )
                DevTypeAlert.warn(
                    title: loc.s("alert.import.saveFailed.title"),
                    message: saveFailureMessage(for: summary.outcome, loc: loc),
                    window: window
                )
                return
            }
            ActivityHistoryStore.publish(
                .importCompleted(
                    added: summary.snippetsAdded,
                    updated: summary.snippetsUpdated,
                    unchanged: summary.snippetsUnchanged,
                    saved: true
                )
            )
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
            if !result.notes.isEmpty {
                body += "\n\n" + result.notes
                    .map { localizedNote($0, loc: loc) }
                    .joined(separator: "\n")
            }

            DevTypeLog.app.info(
                "[Import] kind=\(result.kind.rawValue, privacy: .public) added=\(summary.snippetsAdded, privacy: .public) updated=\(summary.snippetsUpdated, privacy: .public) saved=true"
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
            ActivityHistoryStore.publish(.importFailed)
            DevTypeLog.app.error(
                "[Import] failed \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            DevTypeAlert.warn(
                title: loc.s("alert.import.failed.title"),
                message: failureMessage(for: error, loc: loc),
                window: window
            )
        }
    }

    /// Maps typed importer/framework failures to a finite localized vocabulary. Associated path
    /// and parser-detail strings are deliberately ignored: they may include account names,
    /// private directory structure, or source content.
    static func failureMessage(for error: Error, loc: LocalizationManager) -> String {
        if let importError = error as? SnippetImporter.ImportError {
            switch importError {
            case .pathNotFound: return loc.s("alert.import.failed.unavailable")
            case .unrecognizedSource: return loc.s("alert.import.failed.unsupported")
            case .noImportableSnippets: return loc.s("alert.import.failed.empty")
            case .resourceLimitExceeded(.fileCount):
                return loc.s("alert.import.failed.limit.files")
            case .resourceLimitExceeded(.aggregateBytes):
                return loc.s("alert.import.failed.limit.bytes")
            case .resourceLimitExceeded(.snippetCount):
                return loc.s("alert.import.failed.limit.snippets")
            case .attachmentCommitFailed:
                return loc.s("alert.import.saveFailed.generic")
            case .libraryCommitFailed:
                return loc.s("alert.import.saveFailed.generic")
            }
        }
        if let textExpanderError = error as? TEImporter.ImportError {
            switch textExpanderError {
            case .folderNotFound: return loc.s("alert.import.failed.unavailable")
            case .noGroupFiles: return loc.s("alert.import.failed.empty")
            }
        }
        if let espansoError = error as? EspansoImporter.ImportError {
            switch espansoError {
            case .pathNotFound: return loc.s("alert.import.failed.unavailable")
            case .noMatchFiles: return loc.s("alert.import.failed.empty")
            case .parseFailed: return loc.s("alert.import.failed.malformed")
            }
        }

        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: cocoaError.code) {
            case .fileNoSuchFile:
                return loc.s("alert.import.failed.unavailable")
            case .fileReadNoPermission:
                return loc.s("alert.import.failed.access")
            case .fileReadCorruptFile, .fileReadInapplicableStringEncoding:
                return loc.s("alert.import.failed.malformed")
            default:
                break
            }
        }
        return loc.s("alert.import.failed.generic")
    }

    static func localizedNote(
        _ note: SnippetImporter.ImportNote,
        loc: LocalizationManager
    ) -> String {
        switch note {
        case .richTextDowngraded(let count):
            return loc.p("alert.import.note.richText", count: count, count)
        case .scriptImportedLiterally(let count):
            return loc.p("alert.import.note.script", count: count, count)
        case .missingAbbreviationSkipped(let count):
            return loc.p("alert.import.note.missingAbbreviation", count: count, count)
        case .disabledGroupPreserved(let count):
            return loc.p("alert.import.note.disabledGroup", count: count, count)
        case .wordBoundaryPreserved(let count):
            return loc.p("alert.import.note.wordBoundary", count: count, count)
        case .oversizedItemSkipped(let count):
            return loc.p("alert.import.note.oversized", count: count, count)
        case .imageMatchImported(let count):
            return loc.p("alert.import.note.imageImported", count: count, count)
        case .imageMatchSkipped(let count):
            return loc.p("alert.import.note.imageSkipped", count: count, count)
        case .markdownImportedLiterally(let count):
            return loc.p("alert.import.note.markdown", count: count, count)
        case .appScopePreserved(let count):
            return loc.p("alert.import.note.appScope", count: count, count)
        case .propagateCaseNotAdapted(let count):
            return loc.p("alert.import.note.propagateCase", count: count, count)
        case .unsupportedMatchSkipped(let count):
            return loc.p("alert.import.note.unsupported", count: count, count)
        }
    }

    /// A prepared plan is not an imported library until its serialized store commit reaches disk.
    /// The free-form `.failed` detail is intentionally never interpolated into UI.
    static func saveFailureMessage(
        for outcome: SnippetStore.SaveOutcome,
        loc: LocalizationManager
    ) -> String {
        switch outcome {
        case .blockedByRemoteChange:
            return loc.s("alert.import.saveFailed.remote")
        case .blockedByNewerSchema:
            return loc.s("alert.import.saveFailed.schema")
        case .failed, .saved:
            return loc.s("alert.import.saveFailed.generic")
        }
    }
}
