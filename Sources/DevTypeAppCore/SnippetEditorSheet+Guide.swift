import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

extension SnippetEditorController {
    // MARK: §1 — new-snippet guide

    func applyGuideVisibility() {
        // The composer is pinned top and bottom, so it absorbs the guide's
        // height automatically — there is no second constant to keep in step.
        guideHeightConstraint?.constant = guideVisible ? SnippetEditorGuideView.preferredHeight : 0
        guideView?.isHidden = !guideVisible
        let key = guideVisible ? "guide.hide" : "guide.show"
        helpButton?.toolTip = loc.s(key)
        helpButton?.setAccessibilityLabel(loc.s(key))
        // Guarded: this runs once from inside `loadView`, where touching `view`
        // before it is assigned would re-enter `loadView` forever.
        if isViewLoaded { view.layoutSubtreeIfNeeded() }
    }

    @objc func toggleGuide() {
        guard guideView != nil else { return }
        guideVisible.toggle()
        SnippetEditorGuideView.isDismissed = !guideVisible
        applyGuideVisibility()
        if guideVisible { triggerDidChange() }
    }

    func dismissGuide() {
        guideVisible = false
        SnippetEditorGuideView.isDismissed = true
        applyGuideVisibility()
    }

    /// §1: one click fills trigger *and* body, so the first thing a new user sees
    /// is a snippet that actually works.
    func applyStarter(_ starter: SnippetStarterTemplate) {
        guard !hasImage else {
            confirmImageRemoval(
                titleKey: "editor.image.removeConfirm.title",
                messageKey: "editor.image.removeConfirm.message",
                confirmKey: "editor.image.removeConfirm.confirm"
            ) { [weak self] in
                guard let self else { return }
                self.clearImageDraft()
                self.applyStarter(starter)
            }
            return
        }
        triggerField.stringValue = starter.trigger
        if titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            titleField.stringValue = loc.s(starter.titleKey)
        }
        replacementView.string = starter.replacement
        lastTextLength = (replacementView.string as NSString).length
        placeholderRanges = []
        placeholderCursor = 0
        updateImageUI()
        triggerDidChange()
        view.window?.makeFirstResponder(replacementView)
        replacementView.setSelectedRange(NSRange(location: lastTextLength, length: 0))
    }

    func refreshPreview() {
        if hasImage {
            charCountLabel.stringValue = ""
            let name = pickedImageURL?.lastPathComponent ?? attachedImagePath
            stage.updatePreview("🖼 \(name)", fillInsText: nil)
            return
        }
        let source = replacementView.string
        charCountLabel.stringValue = loc.s("editor.chars", source.count)

        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            stage.updatePreview("", fillInsText: nil)
            return
        }
        let resolved = MacroParser.resolveNested(source) { abbreviation in
            SnippetStore.shared.allSnippets.first(where: { $0.triggerKeyword == abbreviation })?.replacementText
        }
        let fillCount = MacroParser.fillFields(in: MacroParser.parse(resolved)).count
        stage.updatePreview(
            MacroPreview.render(resolved),
            fillInsText: fillCount > 0 ? loc.s("editor.fillins", fillCount) : nil
        )
    }
}
