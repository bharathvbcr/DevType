import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

extension SnippetEditorController {
    // MARK: Image attachment

    @objc func chooseImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = loc.s("common.choose")
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.pickedImageURL = url
            self.attachedImagePath = ""
            self.updateImageUI()
        }
    }

    @objc func removeImage(_ sender: Any?) {
        guard hasImage else { return }
        confirmImageRemoval(
            titleKey: "editor.image.removeConfirm.title",
            messageKey: "editor.image.removeConfirm.message",
            confirmKey: "editor.image.removeConfirm.confirm"
        ) { [weak self] in
            guard let self else { return }
            self.clearImageDraft()
            self.view.window?.makeFirstResponder(self.replacementView)
        }
    }

    func clearImageDraft() {
        pickedImageURL = nil
        attachedImagePath = ""
        updateImageUI()
    }

    func confirmImageRemoval(
        titleKey: String,
        messageKey: String,
        confirmKey: String,
        onCancel: (() -> Void)? = nil,
        onConfirm: @escaping () -> Void
    ) {
        DevTypeAlert.confirm(
            title: loc.s(titleKey),
            message: loc.s(messageKey),
            confirmTitle: loc.s(confirmKey),
            destructive: true,
            window: view.window,
            onCancel: onCancel,
            onConfirm: onConfirm
        )
    }

    func updateImageUI() {
        let has = hasImage
        editorContainer?.isHidden = has
        macroButton?.isHidden = has
        imagePreviewBar?.isHidden = !has
        if has {
            let image = pickedImageURL.flatMap { NSImage(contentsOf: $0) }
                ?? ImageAttachmentStore.shared.loadImage(path: attachedImagePath)
            let name = pickedImageURL?.lastPathComponent ?? attachedImagePath
            imagePreviewView.image = image
            imageNameLabel.stringValue = name
            // §4: an image well with no label is announced as an unlabeled image.
            imagePreviewView.setAccessibilityLabel(loc.s("ax.editor.imagePreview", name))
            imagePreviewView.setAccessibilityValue(name)
            imageNameLabel.setAccessibilityLabel(loc.s("ax.editor.imagePreview", name))
        }
        refreshPreview()
    }
}
