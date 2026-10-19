import AppKit
import Carbon.HIToolbox
import ExpanderEngine

extension SnippetManagerViewController {
    // MARK: - §4.6 Undo
    //
    // Every mutation is computed against the store's latest snapshot under its RMW lock. Undo is
    // conditional on the exact state this action committed, so a newer import/editor action is
    // never erased by an old undo closure. Resource-changing edits deliberately do not enter this
    // model-only undo stack.

    /// Flips the first snippet through `mutate`, the same path a toolbar toggle uses.
    /// A test that only calls `store.mutateGroups` never reaches `finishMutation`.
    func performLibraryToggleForTesting() -> SnippetStore.GroupMutationResult {
        mutate("test-toggle") { groups in
            guard !groups.isEmpty, !groups[0].snippets.isEmpty else { return }
            groups[0].snippets[0].enabled.toggle()
        }
    }

    @discardableResult
    func mutate(
        _ actionName: String,
        stagedImagePaths: [String] = [],
        onCommit: (() -> Void)? = nil,
        _ body: (inout [SnippetGroup]) -> Void
    ) -> SnippetStore.GroupMutationResult {
        mutateValidated(
            actionName,
            stagedImagePaths: stagedImagePaths,
            onCommit: onCommit
        ) { latest in
            body(&latest)
            return true
        }
    }

    @discardableResult
    func mutateValidated(
        _ actionName: String,
        stagedImagePaths: [String] = [],
        onCommit: (() -> Void)? = nil,
        _ body: (inout [SnippetGroup]) -> Bool
    ) -> SnippetStore.GroupMutationResult {
        let result = library.mutateGroups(body)
        finishMutation(
            result,
            actionName: actionName,
            stagedImagePaths: stagedImagePaths,
            onCommit: onCommit
        )
        return result
    }

    func finishMutation(
        _ result: SnippetStore.GroupMutationResult,
        actionName: String,
        stagedImagePaths: [String] = [],
        onCommit: (() -> Void)? = nil
    ) {
        let completion = SnippetManagerMutationCommitter.finish(
            result,
            stagedImagePaths: stagedImagePaths,
            deleteImage: deleteManagedImage
        )

        switch (result, completion) {
        case let (.saved(before, after), .committed(allowsUndo, cleanupFailures)):
            if allowsUndo {
                registerUndo(restoring: before, expectedCurrent: after, actionName: actionName)
            }
            onCommit?()
            if cleanupFailures > 0 { presentResourceCleanupFailure(count: cleanupFailures) }

        case let (.refused, .refused(_, cleanupFailures)):
            DevTypeLog.app.error("[Manager] save refused — surfacing banner")
            LibraryHealthMonitor.shared.refresh()
            if cleanupFailures > 0 { presentResourceCleanupFailure(count: cleanupFailures) }

        case let (.rejected, .stale(cleanupFailures)):
            DevTypeLog.app.notice("[Manager] stale action refused")
            DevTypeAlert.warn(
                title: loc.s("library.save.title"),
                message: loc.s("manager.action.stale.message"),
                window: view.window
            )
            if cleanupFailures > 0 { presentResourceCleanupFailure(count: cleanupFailures) }

        case let (.unchanged, .unchanged(cleanupFailures)):
            // A staged duplicate becoming a no-op means its target disappeared while the action
            // was in flight. The staged file was compensated; make the stale action visible.
            if !stagedImagePaths.isEmpty {
                DevTypeAlert.warn(
                    title: loc.s("library.save.title"),
                    message: loc.s("manager.action.stale.message"),
                    window: view.window
                )
            }
            if cleanupFailures > 0 { presentResourceCleanupFailure(count: cleanupFailures) }

        default:
            assertionFailure("Mutation result and cleanup projection diverged")
        }

        reloadGroups()
    }

    private func deleteManagedImage(_ path: String) -> Bool {
        let result = library.deleteImageIfUnreferenced(path) { candidate in
            if case .success = SnippetEditResourceAccess.live.deleteImage(candidate) { return true }
            return false
        }
        if result == .removed {
            // A path can be reused by a later import; a stale decode must not outlive its file.
            SnippetThumbnailCache.shared.invalidate(path: path)
        }
        return result == .removed || result == .retainedReferenced
    }

    private func presentResourceCleanupFailure(count: Int) {
        DevTypeLog.app.error(
            "[Manager] attachment cleanup incomplete count=\(count, privacy: .public)"
        )
        DevTypeAlert.warn(
            title: loc.s("manager.resources.cleanupFailed.title"),
            message: loc.s("manager.resources.cleanupFailed.message", count),
            window: view.window
        )
    }

    private func registerUndo(
        restoring snapshot: [SnippetGroup],
        expectedCurrent: [SnippetGroup],
        actionName: String
    ) {
        snippetUndoManager.registerUndo(withTarget: snippetUndoTarget) { target in
            guard let owner = target.owner else { return }
            let result = owner.library.replaceGroups(
                ifCurrent: expectedCurrent,
                with: snapshot
            )
            owner.finishMutation(result, actionName: actionName)
        }
        snippetUndoManager.setActionName(actionName)
    }

    func groupIndex(for snippetID: UUID) -> (Int, Int)? {
        for gi in groups.indices {
            if let si = groups[gi].snippets.firstIndex(where: { $0.id == snippetID }) {
                return (gi, si)
            }
        }
        return nil
    }

    // MARK: - Selection draft

    /// The captured selection is the only input. Callers must not re-read the
    /// selection after a palette or Services panel has become key.
    enum SelectionSnippetDraft {
        /// `.string` is `public.utf8-plain-text`. Services may send only the legacy
        /// `NSStringPboardType`, which is the other type declared in `NSSendTypes`.
        static func serviceText(from pasteboard: NSPasteboard) -> String? {
            if let text = pasteboard.string(forType: .string) { return text }
            return pasteboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType"))
        }

        static func make(fromCapturedText capturedText: String?) -> SnippetModel? {
            guard let capturedText, !SelectionReader.isBlankSelection(capturedText) else { return nil }
            let limit = SnippetImporter.SnippetImportLimits.maxReplacementCharacters
            let body = capturedText.count > limit
                ? String(capturedText.prefix(limit))
                : capturedText
            return SnippetModel(
                title: "",
                triggerKeyword: "",
                replacementText: body,
                isCaseSensitive: true,
                isSecret: false
            )
        }
    }

    // MARK: - Snippet actions

    @objc func addSnippet() {
        presentNewSnippetDraft(nil)
    }

    /// Opens the editor on `draft` without saving. `nil` is the blank new-snippet path.
    func presentNewSnippetDraft(_ draft: SnippetModel?) {
        presentEditor(for: nil, draft: draft)
    }

    @objc func addSnippetFromTemplate() {
        SnippetTemplatePanel.present(from: view.window) { [weak self] template in
            guard let self else { return }
            let draft = template.makeDraft(loc: self.loc)
            self.presentEditor(for: nil, draft: draft)
        }
    }

    @objc func editSelectedSnippet() {
        flushPendingFilter()
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < snippets.count else { return }
        presentEditor(for: snippets[selectedRow], draft: nil)
    }

    private func presentEditor(for existing: SnippetModel?, draft: SnippetModel?) {
        SnippetEditorSheet.present(
            from: view.window,
            existing: existing,
            draft: draft,
            groups: groups,
            currentGroupID: selectedGroupID,
            completion: { [weak self] snippet, chosenGroupID in
                guard let self else {
                    return .refused(.failed("Snippet manager is unavailable"))
                }
                let isEdit = existing != nil
                let actionName = self.loc.s(isEdit ? "manager.undo.edit" : "manager.undo.add")
                return .mutating(
                    store: self.library,
                    mutation: { latest in
                        if let existing {
                            guard latest.flatMap(\.snippets).first(where: { $0.id == existing.id }) == existing else {
                                return false
                            }
                        }
                        guard let after = SnippetLibraryEdit.applying(
                            snippet: snippet,
                            existingID: existing?.id,
                            chosenGroupID: chosenGroupID,
                            fallbackGroupID: self.selectedGroupID,
                            to: latest
                        ) else { return false }
                        latest = after
                        return true
                    },
                    finalize: { [weak self] before, after in
                        guard let self else { return }
                        // Undo is registered only after both the library and resources commit,
                        // and only when the model-only undo stack can restore the full prior state.
                        if SnippetLibraryEdit.supportsModelOnlyUndo(existing: existing, candidate: snippet) {
                            self.registerUndo(
                                restoring: before,
                                expectedCurrent: after,
                                actionName: actionName
                            )
                        }
                        self.groups = after
                        self.reloadGroups()
                    }
                )
            }
        )
    }

    @objc func deleteSnippet() {
        flushPendingFilter()
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < snippets.count else { return }
        let snippet = snippets[selectedRow]

        // The secret variant of this warning lives in `SecretManagerViewController`, which owns
        // the only rows that can be secrets.
        DevTypeAlert.confirm(
            title: loc.s("manager.delete.confirm.title"),
            message: loc.s("manager.delete.confirm.message", snippet.displayTitle),
            confirmTitle: loc.s("manager.delete"),
            destructive: true,
            window: view.window
        ) { [weak self] in
            guard let self else { return }
            // §4.6: delete used to be a modal confirm and then gone forever.
            self.mutateValidated(self.loc.s("manager.undo.delete")) { groups in
                for gi in groups.indices {
                    if let si = groups[gi].snippets.firstIndex(where: { $0.id == snippet.id }) {
                        guard groups[gi].snippets[si] == snippet else { return false }
                        groups[gi].snippets.remove(at: si)
                        return true
                    }
                }
                return false
            }
        }
    }

    @objc func duplicateSelectedSnippet() {
        let row = tableView.selectedRow
        guard row >= 0, row < snippets.count else { return }
        let renderedSource = snippets[row]
        var stagedImagePaths: [String] = []
        var duplicationError: Error?
        let result = library.mutateGroups { latest in
            guard let target = SnippetDuplicationPlanner.validatedTargets(
                for: [renderedSource],
                in: latest
            )?.first else { return false }
            var planner = SnippetDuplicationPlanner(existing: latest.flatMap(\.snippets))
            do {
                let copy = try planner.duplicate(target.snippet) { path in
                    let copied = try self.duplicateImageAttachment(path)
                    stagedImagePaths.append(copied)
                    return copied
                }
                latest[target.groupIndex].snippets.append(copy)
                return true
            } catch {
                duplicationError = error
                return false
            }
        }
        if let duplicationError {
            finishFailedDuplication(duplicationError, stagedImagePaths: stagedImagePaths)
            return
        }
        finishMutation(
            result,
            actionName: loc.s("manager.undo.duplicate"),
            stagedImagePaths: stagedImagePaths
        )
    }

    func duplicateImageAttachment(_ path: String) throws -> String {
        guard let sourceURL = ImageAttachmentStore.shared.resolvedURL(forImagePath: path) else {
            throw ImageAttachmentStore.StoreError.unreadableImage(path)
        }
        return try ImageAttachmentStore.shared.importImage(from: sourceURL)
    }

    private func presentDuplicationFailure(_ error: Error) {
        DevTypeAlert.warn(
            title: loc.s("manager.duplicate"),
            message: error.localizedDescription,
            window: view.window
        )
    }

    func finishFailedDuplication(_ error: Error, stagedImagePaths: [String]) {
        let cleanupFailures = stagedImagePaths.reduce(into: 0) { failures, path in
            if !deleteManagedImage(path) { failures += 1 }
        }
        presentDuplicationFailure(error)
        if cleanupFailures > 0 { presentResourceCleanupFailure(count: cleanupFailures) }
        reloadGroups()
    }

    @objc func moveSelectedSnippetToGroup(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let destID = UUID(uuidString: raw),
              groups.contains(where: { $0.id == destID }) else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < snippets.count else { return }
        let snippetID = snippets[row].id
        mutate(loc.s("manager.undo.move")) { groups in
            guard let sourceGroup = groups.firstIndex(where: {
                $0.snippets.contains(where: { $0.id == snippetID })
            }),
            let sourceSnippet = groups[sourceGroup].snippets.firstIndex(where: { $0.id == snippetID }),
            let destinationGroup = groups.firstIndex(where: { $0.id == destID }),
            sourceGroup != destinationGroup else { return }
            let snippet = groups[sourceGroup].snippets.remove(at: sourceSnippet)
            groups[destinationGroup].snippets.append(snippet)
        }
    }
}
