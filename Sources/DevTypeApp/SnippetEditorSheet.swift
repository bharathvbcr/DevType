import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

private final class EditorKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Glass sheet for creating / editing a snippet — replaces the old NSAlert accessory form.
///
/// Redesigned around a live "Expansion Stage": a hero strip that simulates the
/// expansion as you type — trigger key-chip with a blinking caret, crimson arrow,
/// and the macro-resolved output — so the editor demonstrates the product instead
/// of merely describing it. Behavior options are capsule toggle chips rather
/// than a settings-style switch grid. Validation renders inline (crimson label).
enum SnippetEditorSheet {
    private static var activePanel: NSPanel?
    private static var activeController: SnippetEditorController?

    static func present(
        from hostWindow: NSWindow?,
        existing: SnippetModel?,
        groups: [SnippetGroup],
        currentGroupID: UUID?,
        loc: LocalizationManager = .shared,
        validate: @escaping (_ trigger: String, _ caseSensitive: Bool) -> String?,
        completion: @escaping (SnippetModel?, UUID?) -> Void
    ) {
        let panel = EditorKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 548),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)

        let controller = SnippetEditorController(
            existing: existing,
            groups: groups,
            currentGroupID: currentGroupID,
            loc: loc,
            validate: validate,
            onFinish: { result, groupID in
                if let host = hostWindow, panel.isSheet {
                    host.endSheet(panel)
                }
                panel.close()
                activePanel = nil
                activeController = nil
                completion(result, groupID)
            }
        )
        panel.contentView = controller.view

        activePanel = panel
        activeController = controller

        if let hostWindow {
            hostWindow.beginSheet(panel, completionHandler: nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.focusInitialField()
    }
}

// MARK: - Expansion stage

/// Live simulation strip: [:trigger]▎ → expansion preview. The trigger chip and
/// caret react to the trigger field; the preview renders macros in real time.
private final class ExpansionStageView: NSView {
    private let chip = NSView()
    private let chipLabel: NSTextField
    private let caret = NSView()
    private let arrowView = NSImageView()
    private let previewLabel: NSTextField
    private let fillPill = PillBadgeView(text: "", tint: DevTypeTheme.statusOrange)

    override init(frame frameRect: NSRect) {
        chipLabel = DevTypeTheme.makeLabel(":trigger", font: DevTypeTheme.mono(12, .bold), color: DevTypeTheme.textTertiary)
        previewLabel = DevTypeTheme.makeLabel("—", font: DevTypeTheme.mono(11.5), color: DevTypeTheme.textTertiary)
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = DevTypeTheme.accent.withAlphaComponent(0.22).cgColor

        chip.wantsLayer = true
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.layer?.cornerRadius = 7
        chip.layer?.borderWidth = 1
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chipLabel.lineBreakMode = .byTruncatingTail
        chip.addSubview(chipLabel)

        caret.wantsLayer = true
        caret.translatesAutoresizingMaskIntoConstraints = false
        caret.layer?.cornerRadius = 1
        caret.layer?.backgroundColor = DevTypeTheme.accentBright.cgColor

        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.image = DevTypeTheme.tintedSymbol("arrow.right", size: 11, weight: .bold, color: DevTypeTheme.accent)
        arrowView.imageScaling = .scaleProportionallyUpOrDown

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.lineBreakMode = .byTruncatingTail
        fillPill.isHidden = true

        addSubview(chip)
        addSubview(caret)
        addSubview(arrowView)
        addSubview(previewLabel)
        addSubview(fillPill)

        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),

            chipLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 9),
            chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -9),
            chipLabel.topAnchor.constraint(equalTo: chip.topAnchor, constant: 5),
            chipLabel.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -5),

            caret.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 5),
            caret.centerYAnchor.constraint(equalTo: centerYAnchor),
            caret.widthAnchor.constraint(equalToConstant: 2),
            caret.heightAnchor.constraint(equalToConstant: 16),

            arrowView.leadingAnchor.constraint(equalTo: caret.trailingAnchor, constant: 9),
            arrowView.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrowView.widthAnchor.constraint(equalToConstant: 13),
            arrowView.heightAnchor.constraint(equalToConstant: 13),

            previewLabel.leadingAnchor.constraint(equalTo: arrowView.trailingAnchor, constant: 9),
            previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            fillPill.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            fillPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])

        // Blinking caret — the stage feels alive, like typing.
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.12
        blink.duration = 0.55
        blink.autoreverses = true
        blink.repeatCount = .infinity
        caret.layer?.add(blink, forKey: "devtype.caret")

        updateTrigger("")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateTrigger(_ trigger: String) {
        let trimmed = trigger.trimmingCharacters(in: .whitespaces)
        let empty = trimmed.isEmpty
        chipLabel.stringValue = empty ? ":trigger" : trimmed
        chipLabel.textColor = empty ? DevTypeTheme.textTertiary : DevTypeTheme.accentBright
        chip.layer?.backgroundColor = (
            empty ? NSColor.white.withAlphaComponent(0.05) : DevTypeTheme.accent.withAlphaComponent(0.16)
        ).cgColor
        chip.layer?.borderColor = (
            empty ? DevTypeTheme.hairline : DevTypeTheme.accent.withAlphaComponent(0.45)
        ).cgColor
    }

    func updatePreview(_ rendered: String, fillInsText: String?) {
        if rendered.isEmpty {
            previewLabel.stringValue = "—"
            previewLabel.textColor = DevTypeTheme.textTertiary
        } else {
            previewLabel.stringValue = rendered
            previewLabel.textColor = DevTypeTheme.textSecondary
        }
        if let fillInsText {
            fillPill.update(text: fillInsText, tint: DevTypeTheme.statusOrange)
            fillPill.isHidden = false
        } else {
            fillPill.isHidden = true
        }
    }
}

// MARK: - Toggle chip

/// Capsule toggle used for snippet behavior flags — crimson when on, ghost when off.
private final class ToggleChip: NSButton {
    var isOn: Bool { didSet { needsDisplay = true } }
    private let symbolName: String
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String, isOn: Bool, target: AnyObject?, action: Selector?) {
        self.symbolName = symbol
        self.isOn = isOn
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        font = DevTypeTheme.font(11, .semibold)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let textSize = (title as NSString).size(withAttributes: [
            .font: font ?? DevTypeTheme.font(11, .semibold)
        ])
        return NSSize(width: ceil(textSize.width) + 40, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        if isOn {
            DevTypeTheme.accent.withAlphaComponent(hovering ? 0.27 : 0.20).setFill()
            path.fill()
            DevTypeTheme.accent.withAlphaComponent(hovering ? 0.68 : 0.58).setStroke()
        } else {
            NSColor.white.withAlphaComponent(hovering ? 0.085 : 0.045).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(hovering ? 0.20 : 0.13).setStroke()
        }
        path.lineWidth = 1
        path.stroke()

        let tint: NSColor = isOn ? DevTypeTheme.accentBright : DevTypeTheme.textTertiary
        let textColor: NSColor = isOn ? DevTypeTheme.accentBright : DevTypeTheme.textSecondary
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? DevTypeTheme.font(11, .semibold),
            .foregroundColor: textColor
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let image = DevTypeTheme.tintedSymbol(symbolName, size: 10, weight: .bold, color: tint)
        let imageWidth = image?.size.width ?? 0
        let spacing: CGFloat = image == nil ? 0 : 5
        let combined = imageWidth + spacing + textSize.width
        var x = (bounds.width - combined) / 2
        if let image {
            image.draw(in: NSRect(
                x: x,
                y: (bounds.height - image.size.height) / 2,
                width: image.size.width,
                height: image.size.height
            ))
            x += imageWidth + spacing
        }
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
    }
}

// MARK: - Controller

private final class SnippetEditorController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    private let existing: SnippetModel?
    private let groups: [SnippetGroup]
    private let loc: LocalizationManager
    private let validate: (String, Bool) -> String?
    private let onFinish: (SnippetModel?, UUID?) -> Void

    private let titleField = GlassTextField()
    private let triggerField = GlassTextField()
    private let groupPopup = NSPopUpButton()
    private let replacementView = NSTextView()
    private let stage = ExpansionStageView()
    private var enabledChip: ToggleChip!
    private var caseChip: ToggleChip!
    private var boundaryChip: ToggleChip!
    private var plainChip: ToggleChip!
    private let errorLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11, .medium), color: DevTypeTheme.accentBright, wrapping: true)
    private let charCountLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10, .medium), color: DevTypeTheme.textTertiary)
    private var editorContainer: NSView!
    private var macroButton: NSButton!
    private var imagePreviewBar: NSView!
    private let imagePreviewView = NSImageView()
    private let imageNameLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11, .medium), color: DevTypeTheme.textSecondary)

    /// Stored file name of the snippet's existing image ("" = none).
    private var attachedImagePath = ""
    /// Newly picked image file — copied into the store on save.
    private var pickedImageURL: URL?

    private var hasImage: Bool { pickedImageURL != nil || !attachedImagePath.isEmpty }

    init(
        existing: SnippetModel?,
        groups: [SnippetGroup],
        currentGroupID: UUID?,
        loc: LocalizationManager,
        validate: @escaping (String, Bool) -> String?,
        onFinish: @escaping (SnippetModel?, UUID?) -> Void
    ) {
        self.existing = existing
        self.groups = groups
        self.loc = loc
        self.validate = validate
        self.onFinish = onFinish
        self.initialGroupID = currentGroupID ?? groups.first?.id
        self.attachedImagePath = existing?.imagePath ?? ""
        super.init(nibName: nil, bundle: nil)
    }

    private let initialGroupID: UUID?

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let glass = GlassContainerView(
            cornerRadius: DevTypeTheme.Radius.panel,
            tint: DevTypeTheme.accent.withAlphaComponent(0.09),
            material: .popover
        )
        glass.frame = NSRect(x: 0, y: 0, width: 500, height: 548)
        let root = glass.contentView

        // Header
        let isNew = existing == nil
        let badge = IconBadgeView(
            symbol: isNew ? "sparkles" : "square.and.pencil",
            tint: DevTypeTheme.accent,
            size: 34,
            pointSize: 15
        )
        let headerLabel = DevTypeTheme.makeLabel(
            loc.s(isNew ? "editor.add" : "editor.edit"),
            font: DevTypeTheme.font(15, .bold),
            color: DevTypeTheme.textPrimary
        )
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(badge)
        root.addSubview(headerLabel)

        // Expansion stage (live simulation hero)
        root.addSubview(stage)

        // Title
        let nameCaption = caption(loc.s("editor.name"))
        titleField.placeholderAttributedString = placeholder(loc.s("editor.name"))
        titleField.stringValue = existing?.title ?? ""
        root.addSubview(nameCaption)
        root.addSubview(titleField)

        // Trigger (left) + Group (right), side by side
        let triggerCaption = caption(loc.s("editor.trigger"))
        triggerField.placeholderAttributedString = placeholder("e.g. :eml")
        triggerField.font = DevTypeTheme.mono(13, .medium)
        triggerField.stringValue = existing?.triggerKeyword ?? ""
        triggerField.delegate = self
        root.addSubview(triggerCaption)
        root.addSubview(triggerField)

        let groupCaption = caption(loc.s("editor.group"))
        configureGroupPopup()
        root.addSubview(groupCaption)
        root.addSubview(groupPopup)

        // Replacement + macro menu + image + char count
        let replacementCaption = caption(loc.s("editor.replacement"))
        charCountLabel.translatesAutoresizingMaskIntoConstraints = false
        let macroButton = makeMacroButton()
        self.macroButton = macroButton
        let imageButton = makeImageButton()
        let editorContainer = makeEditorContainer()
        self.editorContainer = editorContainer
        let imageBar = makeImagePreviewBar()
        self.imagePreviewBar = imageBar
        root.addSubview(replacementCaption)
        root.addSubview(charCountLabel)
        root.addSubview(macroButton)
        root.addSubview(imageButton)
        root.addSubview(editorContainer)
        root.addSubview(imageBar)

        // Behavior toggle chips
        let behaviorCaption = caption(loc.s("editor.behavior"))
        root.addSubview(behaviorCaption)

        enabledChip = ToggleChip(
            title: loc.s("editor.enabled"), symbol: "power",
            isOn: existing?.enabled ?? true, target: self, action: #selector(chipTapped(_:))
        )
        caseChip = ToggleChip(
            title: loc.s("editor.caseSensitive"), symbol: "textformat",
            isOn: existing?.isCaseSensitive ?? false, target: self, action: #selector(chipTapped(_:))
        )
        boundaryChip = ToggleChip(
            title: loc.s("editor.wordBoundary"), symbol: "paragraphsign",
            isOn: existing?.requireWordBoundary ?? true, target: self, action: #selector(chipTapped(_:))
        )
        plainChip = ToggleChip(
            title: loc.s("editor.plainText"), symbol: "doc.plaintext",
            isOn: existing?.isPlainText ?? true, target: self, action: #selector(chipTapped(_:))
        )
        let chipsRow = NSStackView(views: [enabledChip, caseChip, boundaryChip, plainChip])
        chipsRow.orientation = .horizontal
        chipsRow.alignment = .centerY
        chipsRow.spacing = 8
        chipsRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chipsRow)

        // Inline error
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        errorLabel.maximumNumberOfLines = 2
        root.addSubview(errorLabel)

        // Buttons
        let hairline = DevTypeTheme.makeHairline()
        root.addSubview(hairline)

        let cancelButton = CapsuleButton(
            title: loc.s("common.cancel"),
            style: .secondary,
            target: self,
            action: #selector(cancelTapped)
        )
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = CapsuleButton(
            title: loc.s("editor.save"),
            symbol: "checkmark",
            style: .primary,
            target: self,
            action: #selector(saveTapped)
        )
        saveButton.keyEquivalent = "\r"
        root.addSubview(cancelButton)
        root.addSubview(saveButton)

        let columnGap: CGFloat = 12

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            headerLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            headerLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            stage.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 14),
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stage.heightAnchor.constraint(equalToConstant: 60),

            nameCaption.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 12),
            nameCaption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            titleField.topAnchor.constraint(equalTo: nameCaption.bottomAnchor, constant: 4),
            titleField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            titleField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            triggerCaption.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 10),
            triggerCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            triggerField.topAnchor.constraint(equalTo: triggerCaption.bottomAnchor, constant: 4),
            triggerField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            triggerField.trailingAnchor.constraint(equalTo: root.centerXAnchor, constant: -columnGap / 2),

            groupCaption.topAnchor.constraint(equalTo: triggerCaption.topAnchor),
            groupCaption.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: columnGap / 2 + 2),
            groupPopup.topAnchor.constraint(equalTo: groupCaption.bottomAnchor, constant: 4),
            groupPopup.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: columnGap / 2),
            groupPopup.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            replacementCaption.topAnchor.constraint(equalTo: triggerField.bottomAnchor, constant: 10),
            replacementCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            charCountLabel.centerYAnchor.constraint(equalTo: replacementCaption.centerYAnchor),
            charCountLabel.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            imageButton.centerYAnchor.constraint(equalTo: replacementCaption.centerYAnchor),
            imageButton.trailingAnchor.constraint(equalTo: charCountLabel.leadingAnchor, constant: -8),
            macroButton.centerYAnchor.constraint(equalTo: replacementCaption.centerYAnchor),
            macroButton.trailingAnchor.constraint(equalTo: imageButton.leadingAnchor, constant: -8),
            editorContainer.topAnchor.constraint(equalTo: replacementCaption.bottomAnchor, constant: 4),
            editorContainer.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            editorContainer.heightAnchor.constraint(equalToConstant: 110),
            imageBar.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            imageBar.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            imageBar.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            imageBar.heightAnchor.constraint(equalTo: editorContainer.heightAnchor),

            behaviorCaption.topAnchor.constraint(equalTo: editorContainer.bottomAnchor, constant: 12),
            behaviorCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            chipsRow.topAnchor.constraint(equalTo: behaviorCaption.bottomAnchor, constant: 7),
            chipsRow.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),

            errorLabel.topAnchor.constraint(equalTo: chipsRow.bottomAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            hairline.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hairline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hairline.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        stage.updateTrigger(triggerField.stringValue)
        updateImageUI()
        view = glass
    }

    // MARK: Building blocks

    private func caption(_ text: String) -> NSTextField {
        let label = DevTypeTheme.makeLabel(text, font: DevTypeTheme.font(11, .semibold), color: DevTypeTheme.textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func placeholder(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: DevTypeTheme.textTertiary,
            .font: DevTypeTheme.font(13)
        ])
    }

    private func configureGroupPopup() {
        groupPopup.translatesAutoresizingMaskIntoConstraints = false
        groupPopup.pullsDown = false
        groupPopup.font = DevTypeTheme.font(12, .medium)
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
    }

    private var selectedGroupID: UUID? {
        guard let raw = groupPopup.selectedItem?.representedObject as? String else { return groups.first?.id }
        return UUID(uuidString: raw) ?? groups.first?.id
    }

    /// Borderless "+" button that pops the macro insertion menu.
    private func makeMacroButton() -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = DevTypeTheme.accent.withAlphaComponent(0.14).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = DevTypeTheme.accent.withAlphaComponent(0.35).cgColor
        button.image = DevTypeTheme.tintedSymbol("plus", size: 9, weight: .bold, color: DevTypeTheme.accentBright)
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(
            string: loc.s("editor.macros"),
            attributes: [
                .font: DevTypeTheme.font(10, .semibold),
                .foregroundColor: DevTypeTheme.accentBright
            ]
        )
        button.target = self
        button.action = #selector(showMacroMenu(_:))
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 18),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
        return button
    }

    /// Small capsule next to the macro button that opens an image picker.
    private func makeImageButton() -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = DevTypeTheme.accent.withAlphaComponent(0.14).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = DevTypeTheme.accent.withAlphaComponent(0.35).cgColor
        button.image = DevTypeTheme.tintedSymbol("photo", size: 9, weight: .bold, color: DevTypeTheme.accentBright)
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(
            string: loc.s("editor.image.attach"),
            attributes: [
                .font: DevTypeTheme.font(10, .semibold),
                .foregroundColor: DevTypeTheme.accentBright
            ]
        )
        button.target = self
        button.action = #selector(chooseImage(_:))
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 18),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
        return button
    }

    /// Preview strip that replaces the text editor while an image is attached.
    private func makeImagePreviewBar() -> NSView {
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

        imageNameLabel.translatesAutoresizingMaskIntoConstraints = false
        imageNameLabel.lineBreakMode = .byTruncatingMiddle

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

    private func makeEditorContainer() -> NSView {
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
        replacementView.string = existing?.replacementText ?? ""
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
        scroll.documentView = replacementView

        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        return container
    }

    // MARK: Live preview

    func textDidChange(_ notification: Notification) {
        refreshPreview()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === triggerField else { return }
        stage.updateTrigger(triggerField.stringValue)
    }

    private func refreshPreview() {
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

    // MARK: Macro insertion

    @objc private func showMacroMenu(_ sender: NSButton) {
        let menu = NSMenu()

        // Date presets submenu — named formats with live examples (US, Full, ISO, …).
        let dateItem = NSMenuItem(title: loc.s("editor.macro.date"), action: nil, keyEquivalent: "")
        let dateMenu = NSMenu()
        for preset in DateFormatLibrary.presets {
            let example = DateFormatLibrary.example(for: preset)
            let item = NSMenuItem(
                title: "\(preset.title) — \(example)",
                action: #selector(insertMacro(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = "%date:\(preset.id)%"
            dateMenu.addItem(item)
        }
        dateItem.submenu = dateMenu
        menu.addItem(dateItem)

        let entries: [(String, String)] = [
            (loc.s("editor.macro.cursor"), "%|"),
            (loc.s("editor.macro.clipboard"), "%clipboard"),
            (loc.s("editor.macro.filltext"), "%filltext:name=Field%"),
            (loc.s("editor.macro.fillarea"), "%fillarea:name=Details%"),
            (loc.s("editor.macro.fillpopup"), "%fillpopup:name=Choice:Option A:Option B:default=Option A%"),
            (loc.s("editor.macro.fillpart"), "%fillpart:name=Section:default=yes%\n\n%fillpartend%"),
            (loc.s("editor.macro.nested"), "%snippet:TRIGGER%"),
            (loc.s("editor.macro.keyEnter"), "%key:enter%"),
            (loc.s("editor.macro.keyTab"), "%key:tab%")
        ]
        for entry in entries {
            let item = NSMenuItem(title: entry.0, action: #selector(insertMacro(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.1
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func insertMacro(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        replacementView.insertText(token, replacementRange: replacementView.selectedRange())
        replacementView.didChangeText()
        view.window?.makeFirstResponder(replacementView)
        refreshPreview()
    }

    // MARK: Image attachment

    @objc private func chooseImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.pickedImageURL = url
            self.attachedImagePath = ""
            self.updateImageUI()
        }
    }

    @objc private func removeImage(_ sender: Any?) {
        pickedImageURL = nil
        attachedImagePath = ""
        updateImageUI()
    }

    private func updateImageUI() {
        let has = hasImage
        editorContainer?.isHidden = has
        macroButton?.isHidden = has
        imagePreviewBar?.isHidden = !has
        if has {
            let image = pickedImageURL.flatMap { NSImage(contentsOf: $0) }
                ?? ImageAttachmentStore.shared.loadImage(path: attachedImagePath)
            imagePreviewView.image = image
            imageNameLabel.stringValue = pickedImageURL?.lastPathComponent ?? attachedImagePath
        }
        refreshPreview()
    }
    // MARK: Actions

    @objc private func chipTapped(_ sender: ToggleChip) {
        sender.isOn.toggle()
    }

    func focusInitialField() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let target = self.existing == nil ? self.titleField : self.triggerField
            self.view.window?.makeFirstResponder(target)
        }
    }

    @objc private func cancelTapped() { onFinish(nil, nil) }

    @objc private func saveTapped() {
        let trigger = triggerField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty else {
            showError(loc.s("editor.error.emptyTrigger"))
            return
        }
        let caseSensitive = caseChip.isOn
        if let conflict = validate(trigger, caseSensitive) {
            showError(conflict)
            return
        }

        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementView.string
        var snippet = existing ?? SnippetModel(
            title: "",
            triggerKeyword: trigger,
            replacementText: replacement.isEmpty ? "Hello World" : replacement
        )
        snippet.title = title.isEmpty ? "Untitled" : title
        snippet.triggerKeyword = trigger

        if hasImage {
            if let picked = pickedImageURL {
                // Copy the picked file into the attachment store.
                do {
                    let stored = try ImageAttachmentStore.shared.importImage(from: picked)
                    if let old = existing?.imagePath, !old.isEmpty, old != stored {
                        ImageAttachmentStore.shared.deleteImage(path: old)
                    }
                    snippet.imagePath = stored
                } catch {
                    showError(error.localizedDescription)
                    return
                }
            } else {
                snippet.imagePath = attachedImagePath
            }
            snippet.replacementText = ""
        } else {
            // Image removed (or never attached): drop any stored attachment.
            if let old = existing?.imagePath, !old.isEmpty {
                ImageAttachmentStore.shared.deleteImage(path: old)
            }
            snippet.imagePath = ""
            snippet.replacementText = replacement.isEmpty ? (existing?.replacementText ?? "Hello World") : replacement
        }

        snippet.isCaseSensitive = caseSensitive
        snippet.requireWordBoundary = boundaryChip.isOn
        snippet.isPlainText = plainChip.isOn
        snippet.enabled = enabledChip.isOn
        snippet.updatedAt = Date()
        onFinish(snippet, selectedGroupID)
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        view.layoutSubtreeIfNeeded()
        // Brief attention shake on the trigger field.
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -6, 5, -3, 2, 0]
        animation.duration = 0.32
        triggerField.wantsLayer = true
        triggerField.layer?.add(animation, forKey: "devtype.shake")
    }
}
