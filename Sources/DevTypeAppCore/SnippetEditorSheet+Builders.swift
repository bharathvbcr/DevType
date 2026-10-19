import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

extension SnippetEditorController {
    // MARK: Building blocks

    func caption(_ text: String) -> NSTextField { DevTypeTheme.makeFieldCaption(text) }

    func placeholder(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: DevTypeTheme.textTertiary,
            .font: DevTypeTheme.font(13)
        ])
    }

    func configureGroupPopup() {
        groupPopup.translatesAutoresizingMaskIntoConstraints = false
        groupPopup.pullsDown = false
        groupPopup.font = DevTypeTheme.font(12, .medium)
        // A popup's intrinsic width is its *widest* item, and group names are user-typed: one
        // long name widened the whole panel before anything was typed into it. It is pinned to
        // its column by constraints; let it truncate there.
        groupPopup.lineBreakMode = .byTruncatingTail
        groupPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // §4: the caption above it is a separate view.
        groupPopup.setAccessibilityLabel(loc.s("editor.group"))
        let menu = NSMenu()
        for group in groups {
            let item = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            item.representedObject = group.id.uuidString
            item.image = DevTypeTheme.tintedSymbol(
                group.symbol,
                size: 12,
                weight: .medium,
                color: group.enabled ? DevTypeTheme.tint(forGroupColorHex: group.colorHex) : DevTypeTheme.textTertiary
            )
            menu.addItem(item)
        }
        groupPopup.menu = menu
        if let id = initialGroupID,
           let index = groups.firstIndex(where: { $0.id == id }) {
            groupPopup.selectItem(at: index)
        }
        // Records the user's intent, nothing else — see `groupSelectionChangedManually`.
        groupPopup.target = self
        groupPopup.action = #selector(groupPopupChanged)
    }

    @objc private func groupPopupChanged() {
        // A choice made in the popup itself supersedes the suggested one — the chip must stop
        // presenting itself as the reason for the current selection.
        acceptance?.groupSelectionChangedManually()
        groupSuggestionChip?.isOn = false
        groupSelectionBeforeSuggestion = nil
    }

    func configureAITransformPopup(selectedRaw: String) {
        aiTransformPopup.translatesAutoresizingMaskIntoConstraints = false
        aiTransformPopup.pullsDown = false
        aiTransformPopup.font = DevTypeTheme.font(12, .medium)
        aiTransformPopup.setAccessibilityLabel(loc.s("editor.aiTransform"))

        let menu = NSMenu()
        let none = NSMenuItem(title: loc.s("editor.aiTransform.none"), action: nil, keyEquivalent: "")
        none.representedObject = ""
        menu.addItem(none)
        for kind in AITransformKind.allCases {
            let item = NSMenuItem(title: loc.s(kind.localizationKey), action: nil, keyEquivalent: "")
            item.representedObject = kind.rawValue
            menu.addItem(item)
        }
        aiTransformPopup.menu = menu

        let key = selectedRaw.lowercased()
        if key.isEmpty {
            aiTransformPopup.selectItem(at: 0)
        } else if let kind = AITransformKind.named(key),
                  let idx = AITransformKind.allCases.firstIndex(of: kind) {
            aiTransformPopup.selectItem(at: idx + 1)
        } else {
            aiTransformPopup.selectItem(at: 0)
        }
    }

    var selectedAITransform: String {
        (aiTransformPopup.selectedItem?.representedObject as? String) ?? ""
    }

    var selectedGroupID: UUID? {
        guard let raw = groupPopup.selectedItem?.representedObject as? String else { return groups.first?.id }
        return UUID(uuidString: raw) ?? groups.first?.id
    }

    /// Preview strip that replaces the text editor while an image is attached.
    func makeImagePreviewBar() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = DevTypeTheme.hairline.cgColor

        imagePreviewView.translatesAutoresizingMaskIntoConstraints = false
        imagePreviewView.imageScaling = .scaleProportionallyUpOrDown
        imagePreviewView.wantsLayer = true
        imagePreviewView.layer?.cornerRadius = 8
        imagePreviewView.layer?.masksToBounds = true
        imagePreviewView.layer?.borderWidth = 1
        imagePreviewView.layer?.borderColor = DevTypeTheme.hairline.cgColor
        // §4: labelled in `updateImageUI()` once the file name is known.
        imagePreviewView.setAccessibilityRole(NSAccessibility.Role.image)

        imageNameLabel.translatesAutoresizingMaskIntoConstraints = false
        imageNameLabel.lineBreakMode = .byTruncatingMiddle
        // A file name is user data too; it sits between the thumbnail and the Remove button.
        imageNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let hintLabel = DevTypeTheme.makeLabel(
            loc.s("editor.image.attached"),
            font: DevTypeTheme.font(10),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.maximumNumberOfLines = 2

        let removeButton = NSButton()
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.isBordered = false
        removeButton.wantsLayer = true
        removeButton.layer?.cornerRadius = 6
        removeButton.layer?.backgroundColor = DevTypeTheme.accent.withAlphaComponent(0.16).cgColor
        removeButton.attributedTitle = NSAttributedString(
            string: loc.s("editor.image.remove"),
            attributes: [
                .font: DevTypeTheme.font(10, .semibold),
                .foregroundColor: DevTypeTheme.accentBright
            ]
        )
        removeButton.target = self
        removeButton.action = #selector(removeImage(_:))
        removeButton.setAccessibilityRole(NSAccessibility.Role.button)
        removeButton.setAccessibilityLabel(loc.s("editor.image.remove"))

        container.addSubview(imagePreviewView)
        container.addSubview(imageNameLabel)
        container.addSubview(hintLabel)
        container.addSubview(removeButton)

        NSLayoutConstraint.activate([
            imagePreviewView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            imagePreviewView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imagePreviewView.widthAnchor.constraint(equalToConstant: 86),
            imagePreviewView.heightAnchor.constraint(equalToConstant: 86),

            imageNameLabel.leadingAnchor.constraint(equalTo: imagePreviewView.trailingAnchor, constant: 12),
            imageNameLabel.topAnchor.constraint(equalTo: imagePreviewView.topAnchor, constant: 8),
            imageNameLabel.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -10),

            hintLabel.leadingAnchor.constraint(equalTo: imageNameLabel.leadingAnchor),
            hintLabel.topAnchor.constraint(equalTo: imageNameLabel.bottomAnchor, constant: 3),
            hintLabel.trailingAnchor.constraint(equalTo: imageNameLabel.trailingAnchor),

            removeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            removeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            removeButton.heightAnchor.constraint(equalToConstant: 22),
            removeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
        return container
    }

    /// Composer: text editor on top, toolbar (macro palette · image · character
    /// count) along the bottom — the layout every chat/post composer trained
    /// users to expect. The macro palette gets a real pill with its ⌘/ hint
    /// baked in instead of an 18pt ghost button hidden in the caption row.
    func makeEditorContainer() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = DevTypeTheme.hairline.cgColor

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        replacementView.isRichText = false
        replacementView.font = DevTypeTheme.mono(12.5)
        replacementView.textColor = DevTypeTheme.textPrimary
        replacementView.backgroundColor = .clear
        replacementView.insertionPointColor = DevTypeTheme.accentBright
        replacementView.string = seed?.replacementText ?? ""
        replacementView.delegate = self
        replacementView.textContainerInset = NSSize(width: 6, height: 6)
        replacementView.minSize = NSSize(width: 0, height: 0)
        replacementView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        replacementView.isVerticallyResizable = true
        replacementView.isHorizontallyResizable = false
        replacementView.autoresizingMask = [.width]
        replacementView.textContainer?.containerSize = NSSize(
            width: 400,
            height: CGFloat.greatestFiniteMagnitude
        )
        replacementView.textContainer?.widthTracksTextView = true
        // §4: an unlabelled NSTextView is announced only as "text entry area".
        replacementView.setAccessibilityLabel(loc.s("ax.editor.replacement"))
        scroll.documentView = replacementView
        replacementScroll = scroll

        let toolbarRule = DevTypeTheme.makeHairline()

        let macro = ComposerPillButton(
            title: loc.s("editor.macros"),
            symbol: "curlybraces",
            shortcut: "⌘⇧/",
            target: self,
            action: #selector(showMacroMenu(_:))
        )
        // ⌘/ is the global Command Palette chord — a Carbon hotkey consumes it
        // system-wide before key-equivalent traversal ever reaches this sheet, so
        // pressing the previously advertised ⌘/ here sprang the search palette
        // over the editor instead. ⇧⌘/ is unclaimed: the accessory app installs
        // no Help menu that could bind ⌘?.
        macro.keyEquivalent = "/"
        macro.keyEquivalentModifierMask = [.command, .shift]
        macro.toolTip = loc.s("editor.hint.macros")
        macro.setAccessibilityHelp(loc.s("editor.hint.macros"))
        macroButton = macro

        let image = ComposerPillButton(
            title: loc.s("editor.image.attach"),
            symbol: "photo",
            shortcut: nil,
            target: self,
            action: #selector(chooseImage(_:))
        )

        imageButton = image
        charCountLabel.translatesAutoresizingMaskIntoConstraints = false
        charCountLabel.lineBreakMode = .byTruncatingTail
        charCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addSubview(scroll)
        container.addSubview(toolbarRule)
        container.addSubview(macro)
        container.addSubview(image)
        container.addSubview(charCountLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: toolbarRule.topAnchor, constant: -2),

            toolbarRule.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            toolbarRule.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            toolbarRule.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -35),

            macro.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            macro.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),

            image.leadingAnchor.constraint(equalTo: macro.trailingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: macro.centerYAnchor),

            charCountLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            charCountLabel.centerYAnchor.constraint(equalTo: macro.centerYAnchor),
            // The count had no relation to the pills beside it; a long localized count in a
            // narrow slot would have been drawn straight through the Image button.
            charCountLabel.leadingAnchor.constraint(greaterThanOrEqualTo: image.trailingAnchor, constant: 8)
        ])
        return container
    }
}
