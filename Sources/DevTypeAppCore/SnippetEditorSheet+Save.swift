import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

extension SnippetEditorController {
    @objc func saveTapped() {
        let trigger = triggerField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty else {
            showError(loc.s("editor.error.emptyTrigger"))
            return
        }
        // §3: the 64-character ring-buffer cap — over it, the trigger can never
        // fire, so refuse rather than saving a snippet that silently does nothing.
        if trigger.count > AbbreviationMatcher.matchableTriggerLimit {
            showError(loc.s("editor.error.tooLong", AbbreviationMatcher.matchableTriggerLimit))
            return
        }
        let caseSensitive = caseChip.isOn
        if let conflict = SnippetTriggerAuthoringValidator.conflict(
            trigger: trigger,
            caseSensitive: caseSensitive,
            requireWordBoundary: boundaryChip.isOn,
            enabled: enabledChip.isOn,
            excludingID: existing?.id,
            groups: groups
        ) {
            showError(triggerConflictMessage(conflict))
            return
        }

        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementView.string
        // A cleared body used to resurrect the previous text on save — or plant a
        // "Hello World" placeholder into a brand-new snippet — silently undoing what
        // the user just deleted. Refuse the save instead. Attached images carry no body
        // by design, so they stay exempt.
        if !hasImage, replacement.isEmpty {
            showError(loc.s("editor.error.emptyReplacement"))
            return
        }
        // For the Custom AI action the body is not an expansion, it is the prompt — the kind's
        // own instructions say only "follow the additional instructions provided". A blank one
        // is refused here rather than at trigger time, where the user has already committed to
        // an expansion. Trimmed, unlike the check above: a body of one space expands to
        // something, but it instructs the model in nothing.
        if AITransformKind.named(selectedAITransform) == .custom,
           AIActionSelection.normalized(replacement) == nil {
            showError(loc.s("editor.error.customInstructions"))
            return
        }
        var snippet = existing ?? SnippetModel(
            title: "",
            triggerKeyword: trigger,
            replacementText: replacement
        )
        snippet.title = title.isEmpty
            ? Self.derivedTitle(from: replacement, localization: loc)
            : title
        snippet.triggerKeyword = trigger

        // Tags are rebuilt from the chips rather than appended to, so switching one off
        // actually removes it. Suggestions are then normalized against what survived, so an
        // accepted suggestion cannot duplicate a tag the snippet already had.
        snippet.includeApps = appScope.includeApps
        snippet.excludeApps = appScope.excludeApps

        snippet.tags = SnippetTagAssembly.finalTags(
            kept: keptExistingTags,
            accepted: acceptance?.tagsToApply ?? []
        )

        // §4.4: the matcher has honoured these on every keystroke since they were added, and
        // both importers round-trip them — this is the first path that can *write* one.
        snippet.includeApps = appScope.includeApps
        snippet.excludeApps = appScope.excludeApps

        if hasImage {
            // A picked file is copied by `SnippetEditTransaction`; until the host library save
            // lands, the old stored attachment remains intact and this model carries no path.
            snippet.imagePath = pickedImageURL == nil ? attachedImagePath : ""
            snippet.replacementText = ""
        } else {
            snippet.imagePath = ""
            snippet.replacementText = replacement
        }

        snippet.isCaseSensitive = caseSensitive
        snippet.propagateCase = !caseSensitive && propagateCaseChip.isOn
        snippet.requireWordBoundary = boundaryChip.isOn
        snippet.isPlainText = plainChip.isOn
        snippet.enabled = enabledChip.isOn
        snippet.aiTransform = selectedAITransform

        snippet.updatedAt = Date()
        switch resourceTransaction.save(
            snippet: snippet,
            existing: existing,
            pickedImageURL: pickedImageURL,
            secretIntent: .remove,
            groupID: selectedGroupID,
            persist: persist
        ) {
        case .committed:
            onDismiss()
        case .committedWithWarning:
            DevTypeAlert.present(
                title: loc.s("editor.transaction.commitWarning.title"),
                message: loc.s("editor.transaction.commitWarning.message"),
                style: .warning,
                buttons: [loc.s("common.ok")],
                handler: nil
            )
            onDismiss()
        case .failed(let failure):
            showError(transactionMessage(for: failure))
        }
    }

    private func transactionMessage(for failure: SnippetEditTransactionFailure) -> String {
        switch failure {
        case .imageStaging:
            return loc.s("editor.transaction.imageStageFailed")
        case .secretRead:
            return loc.s("editor.transaction.secretReadFailed")
        case .secretWrite:
            return loc.s("editor.transaction.secretWriteFailed")
        case .persistence(let outcome):
            switch outcome {
            case .saved, .savedWithoutBackup:
                return loc.s("editor.transaction.saveFailed")
            case .blockedByNewerSchema:
                return loc.s("editor.transaction.newerSchema")
            case .blockedByRemoteChange:
                return loc.s("editor.transaction.remoteChange")
            case .failed:
                return loc.s("editor.transaction.saveFailed")
            }
        case .commitCleanup:
            return loc.s("editor.transaction.cleanupFailed")
        case .rollback:
            return loc.s("editor.transaction.rollbackFailed")
        }
    }

    func showError(_ message: String) {
        setError(message)
        guard !DevTypeAccessibility.reduceMotion else { return }
        // Brief attention shake on the trigger field.
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -6, 5, -3, 2, 0]
        animation.duration = 0.32
        triggerField.wantsLayer = true
        triggerField.layer?.add(animation, forKey: "devtype.shake")
    }
}
