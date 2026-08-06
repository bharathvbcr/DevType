import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

private final class EditorKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Wired by the controller so ⌘Return saves even while the multi-line
    /// replacement editor holds focus.
    var saveHandler: (() -> Void)?

    /// Return/Enter routing, resolved at the panel so view order doesn't matter:
    /// a focused multi-line text view gets the newline *before* the Save button's
    /// "\r" key equivalent can swallow it, ⌘Return saves from anywhere, and
    /// single-line fields (field editors) keep their Return → Save path.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 {
            let significant = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if significant == .command, let saveHandler {
                saveHandler()
                return true
            }
            if significant.isEmpty,
               let textView = firstResponder as? NSTextView,
               !textView.isFieldEditor,
               textView.isEditable,
               !textView.hasMarkedText() {
                textView.insertNewline(nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Glass sheet for creating / editing a snippet — replaces the old NSAlert accessory form.
///
/// Redesigned around a live "Expansion Stage": a hero strip that simulates the
/// expansion as you type — trigger key-chip with a blinking caret, crimson arrow,
/// and the macro-resolved output — so the editor demonstrates the product instead
/// of merely describing it. Behavior options are capsule toggle chips rather
/// than a settings-style switch grid. Validation renders inline (crimson label).
enum SnippetEditorSheet {
    /// §1 / §3: sized once here so the panel and its glass container can never
    /// disagree. The extra height over the old 500×548 buys the new-snippet
    /// guide strip and a materially taller replacement editor.
    static let panelWidth: CGFloat = 520
    static let panelHeight: CGFloat = 672

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
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
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
                // §2: a macro palette left open would outlive its host sheet.
                MacroPalettePanel.dismiss()
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
        // ⌘Return → Save, even while the multi-line replacement editor owns Return.
        panel.saveHandler = { [weak controller] in
            controller?.saveFromKeyboard()
        }

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

    // §4: the stage conveys everything through position, tint and a blinking
    // caret. These three keep a text equivalent so the strip has an AX value.
    private var currentTrigger = ""
    private var currentPreview = ""
    private var currentFillIns: String?
    private var currentlyInvalid = false

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
        currentTrigger = trimmed
        refreshAccessibility()
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
        currentPreview = rendered
        currentFillIns = fillInsText
        refreshAccessibility()
    }

    /// Conflict state: the chip goes crimson so an invalid trigger is visible in
    /// the hero strip even before the eye reaches the inline error label.
    func setInvalid(_ invalid: Bool) {
        currentlyInvalid = invalid
        guard invalid else {
            updateTrigger(chipLabel.stringValue == ":trigger" ? "" : chipLabel.stringValue)
            return
        }
        chipLabel.textColor = DevTypeTheme.accentBright
        chip.layer?.backgroundColor = DevTypeTheme.accent.withAlphaComponent(0.26).cgColor
        chip.layer?.borderColor = DevTypeTheme.accentBright.withAlphaComponent(0.75).cgColor
        refreshAccessibility()
    }

    /// §4: the whole strip speaks as one static-text element. Before this it was
    /// five unlabelled subviews inside a plain NSView, so VoiceOver announced
    /// nothing at all for the editor's most informative surface. The invalid
    /// state is spoken too — it was previously carried by chip tint alone (§5.2).
    private func refreshAccessibility() {
        let loc = LocalizationManager.shared
        dtHideSubviewsFromAccessibility()
        var value: String
        if currentTrigger.isEmpty {
            value = loc.s("ax.editor.stage.empty")
        } else {
            value = loc.s(
                "ax.editor.stage.value",
                currentTrigger,
                currentPreview.isEmpty ? "—" : currentPreview
            )
        }
        if let currentFillIns {
            value += ". " + currentFillIns
        }
        if currentlyInvalid {
            value += ". " + loc.s("editor.error.duplicateLive")
        }
        dtApplyAccessibility(
            role: NSAccessibility.Role.staticText,
            label: loc.s("ax.editor.stage"),
            value: value
        )
    }
}

// MARK: - Toggle chip

/// Capsule toggle used for snippet behavior flags — crimson when on, ghost when off.
///
/// §3 / §4: the four chips previously carried no explanation anywhere in the UI
/// and no accessibility at all. Each now has a tooltip, an AX help string, the
/// `.checkBox` role, and an AX value reflecting on/off — so state is not carried
/// by fill colour alone.
private final class ToggleChip: NSButton {
    var isOn: Bool {
        didSet {
            needsDisplay = true
            refreshAccessibilityValue()
        }
    }
    private let symbolName: String
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String, isOn: Bool, help: String, target: AnyObject?, action: Selector?) {
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

        toolTip = help
        setAccessibilityRole(NSAccessibility.Role.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityHelp(help)
        refreshAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Property observers do not fire during `init`, so this is also called once
    /// explicitly above.
    private func refreshAccessibilityValue() {
        let loc = LocalizationManager.shared
        setAccessibilityValue(isOn ? loc.s("ax.enabled") : loc.s("ax.disabled"))
    }

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
            // `ToggleChip` is an NSButton, whose context is flipped — see the note in
            // `CapsuleButton.draw`. Without `respectFlipped:` the glyph renders upside down.
            image.draw(
                in: NSRect(
                    x: x,
                    y: (bounds.height - image.size.height) / 2,
                    width: image.size.width,
                    height: image.size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: nil
            )
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
    private var saveButton: CapsuleButton?
    /// Inline live-validation readout next to the Trigger caption (✓ / conflict).
    private let triggerStatusLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10, .medium), color: DevTypeTheme.statusGreen)
    /// §1: full-width sentence under the trigger field describing exactly what
    /// will happen with the trigger the user has typed.
    private let triggerRuleLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10, .medium), color: DevTypeTheme.textTertiary)
    /// Last computed trigger validity so Save enablement stays in sync.
    private var isTriggerValid = false

    // §1: dismissible new-snippet guide.
    private var guideView: SnippetEditorGuideView?
    private var guideHeightConstraint: NSLayoutConstraint?
    private var editorHeightConstraint: NSLayoutConstraint?
    private var helpButton: NSButton?
    private var guideVisible: Bool

    /// Editor height with the guide showing; it grows by exactly the guide's
    /// height when the guide is collapsed (or absent, i.e. when editing an
    /// existing snippet), so the panel is one fixed size in every state.
    /// Editing an existing snippet therefore gets 248pt of body — well over the
    /// 110pt the editor used to be fixed at.
    private static let editorHeightWithGuide: CGFloat = 132

    // §2: smart-insertion bookkeeping. Placeholder spans arrive as *data* on the
    // macro descriptor and are stored here as absolute ranges, then shifted by
    // the observed length delta on each edit — never recovered by re-parsing.
    private var placeholderRanges: [NSRange] = []
    private var placeholderCursor = 0
    private var lastTextLength = 0

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
        // §1: never shown when editing an existing snippet, and the dismissal is
        // remembered across launches.
        self.guideVisible = (existing == nil) && !SnippetEditorGuideView.isDismissed
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
        glass.frame = NSRect(
            x: 0,
            y: 0,
            width: SnippetEditorSheet.panelWidth,
            height: SnippetEditorSheet.panelHeight
        )
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

        // §1: the "?" affordance — dismissing the guide is never permanent.
        if isNew {
            let button = SnippetEditorGuideView.makeGhostButton(
                title: loc.s("guide.show"),
                symbol: "questionmark",
                target: self,
                action: #selector(toggleGuide)
            )
            helpButton = button
            root.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
                button.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
            ])
        }

        // Expansion stage (live simulation hero)
        root.addSubview(stage)

        // §1: new-snippet guide — trigger rule, live, plus one-click starters.
        let guide: SnippetEditorGuideView?
        if isNew {
            let built = SnippetEditorGuideView(
                loc: loc,
                onStarter: { [weak self] starter in self?.applyStarter(starter) },
                onDismiss: { [weak self] in self?.dismissGuide() }
            )
            guide = built
            guideView = built
            root.addSubview(built)
        } else {
            guide = nil
        }

        // Title
        let nameCaption = caption(loc.s("editor.name"))
        titleField.placeholderAttributedString = placeholder(loc.s("editor.name"))
        titleField.stringValue = existing?.title ?? ""
        // §4: the caption is a separate view, so VoiceOver cannot infer it.
        titleField.setAccessibilityLabel(loc.s("editor.name"))
        root.addSubview(nameCaption)
        root.addSubview(titleField)

        // Trigger (left) + Group (right), side by side
        let triggerCaption = caption(loc.s("editor.trigger"))
        triggerField.placeholderAttributedString = placeholder("e.g. :eml")
        triggerField.font = DevTypeTheme.mono(13, .medium)
        triggerField.stringValue = existing?.triggerKeyword ?? ""
        triggerField.delegate = self
        triggerField.setAccessibilityLabel(loc.s("editor.trigger"))
        triggerField.setAccessibilityHelp(loc.s("editor.trigger.hint"))
        triggerStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        triggerStatusLabel.lineBreakMode = .byTruncatingTail
        triggerRuleLabel.translatesAutoresizingMaskIntoConstraints = false
        triggerRuleLabel.lineBreakMode = .byTruncatingTail
        triggerRuleLabel.setAccessibilityLabel(loc.s("ax.editor.triggerStatus"))
        root.addSubview(triggerCaption)
        root.addSubview(triggerStatusLabel)
        root.addSubview(triggerField)
        root.addSubview(triggerRuleLabel)

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
            isOn: existing?.enabled ?? true,
            help: loc.s("editor.enabled.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        caseChip = ToggleChip(
            title: loc.s("editor.caseSensitive"), symbol: "textformat",
            isOn: existing?.isCaseSensitive ?? false,
            help: loc.s("editor.caseSensitive.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        boundaryChip = ToggleChip(
            title: loc.s("editor.wordBoundary"), symbol: "paragraphsign",
            isOn: existing?.requireWordBoundary ?? true,
            // §1: this is the toggle that changes the trigger rule the guide
            // explains, so its help text spells that rule out in full.
            help: loc.s("editor.wordBoundary.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        plainChip = ToggleChip(
            title: loc.s("editor.plainText"), symbol: "doc.plaintext",
            isOn: existing?.isPlainText ?? true,
            help: loc.s("editor.plainText.help"),
            target: self, action: #selector(chipTapped(_:))
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
        // ⌘Return — see EditorKeyablePanel.performKeyEquivalent for the Return routing.
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        self.saveButton = saveButton
        root.addSubview(cancelButton)
        root.addSubview(saveButton)

        // Visible shortcut hints — a shortcut you can't discover may as well not exist.
        let escHint = KeyCapView("esc")
        let escLabel = DevTypeTheme.makeLabel(
            loc.s("common.cancel"),
            font: DevTypeTheme.font(9.5, .medium),
            color: DevTypeTheme.textTertiary
        )
        escLabel.translatesAutoresizingMaskIntoConstraints = false
        let saveHint = KeyCapView("⌘↩")
        let saveHintLabel = DevTypeTheme.makeLabel(
            loc.s("editor.save"),
            font: DevTypeTheme.font(9.5, .medium),
            color: DevTypeTheme.textTertiary
        )
        saveHintLabel.translatesAutoresizingMaskIntoConstraints = false
        let hintStack = NSStackView(views: [escHint, escLabel, saveHint, saveHintLabel])
        hintStack.orientation = .horizontal
        hintStack.alignment = .centerY
        hintStack.spacing = 4
        hintStack.setCustomSpacing(12, after: escLabel)
        hintStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hintStack)

        let columnGap: CGFloat = 12

        // §1 / §3: the guide and the replacement editor share one pool of
        // vertical space — collapsing the guide grows the editor by exactly the
        // same amount, so the panel is a fixed size in every state.
        let guideHeight = guide?.heightAnchor.constraint(
            equalToConstant: guideVisible ? SnippetEditorGuideView.preferredHeight : 0
        )
        guideHeightConstraint = guideHeight
        let editorHeight = editorContainer.heightAnchor.constraint(
            equalToConstant: guideVisible
                ? Self.editorHeightWithGuide
                : Self.editorHeightWithGuide + SnippetEditorGuideView.preferredHeight
        )
        editorHeightConstraint = editorHeight

        var extraConstraints: [NSLayoutConstraint] = []
        if let guide, let guideHeight {
            extraConstraints = [
                guide.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 10),
                guide.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                guide.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                guideHeight
            ]
        }

        // When the guide strip exists (new snippets) the form hangs off its
        // bottom edge; otherwise it hugs the stage. Anchoring the caption to the
        // stage in both cases would put the guide on top of the Title field.
        let nameTopConstraint = nameCaption.topAnchor.constraint(
            equalTo: guide?.bottomAnchor ?? stage.bottomAnchor,
            constant: 12
        )

        NSLayoutConstraint.activate(extraConstraints)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            headerLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            headerLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            stage.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 14),
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stage.heightAnchor.constraint(equalToConstant: 60),

            nameTopConstraint,
            nameCaption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            titleField.topAnchor.constraint(equalTo: nameCaption.bottomAnchor, constant: 4),
            titleField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            titleField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            triggerCaption.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 10),
            triggerCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            triggerStatusLabel.centerYAnchor.constraint(equalTo: triggerCaption.centerYAnchor),
            triggerStatusLabel.leadingAnchor.constraint(equalTo: triggerCaption.trailingAnchor, constant: 8),
            triggerStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: triggerField.trailingAnchor),
            triggerField.topAnchor.constraint(equalTo: triggerCaption.bottomAnchor, constant: 4),
            triggerField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            triggerField.trailingAnchor.constraint(equalTo: root.centerXAnchor, constant: -columnGap / 2),

            triggerRuleLabel.topAnchor.constraint(equalTo: triggerField.bottomAnchor, constant: 4),
            triggerRuleLabel.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            triggerRuleLabel.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            groupCaption.topAnchor.constraint(equalTo: triggerCaption.topAnchor),
            groupCaption.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: columnGap / 2 + 2),
            groupPopup.topAnchor.constraint(equalTo: groupCaption.bottomAnchor, constant: 4),
            groupPopup.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: columnGap / 2),
            groupPopup.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            replacementCaption.topAnchor.constraint(equalTo: triggerRuleLabel.bottomAnchor, constant: 8),
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
            editorHeight,
            imageBar.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            imageBar.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            imageBar.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            imageBar.heightAnchor.constraint(equalTo: editorContainer.heightAnchor),

            behaviorCaption.topAnchor.constraint(equalTo: editorContainer.bottomAnchor, constant: 12),
            behaviorCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            chipsRow.topAnchor.constraint(equalTo: behaviorCaption.bottomAnchor, constant: 7),
            chipsRow.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),

            // §3: anchored UP from the divider rather than DOWN from the chips.
            // Top-anchored, a two-line error grew straight through the hairline
            // and the buttons; from here it grows into the gap above itself.
            errorLabel.bottomAnchor.constraint(equalTo: hairline.topAnchor, constant: -8),
            errorLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            hairline.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hairline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hairline.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),

            hintStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hintStack.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        // §3: an explicit key-view loop. Left implicit, AppKit walks the views in
        // subview order, which stopped matching reading order once the guide and
        // the trigger readout were inserted above the form.
        titleField.nextKeyView = triggerField
        triggerField.nextKeyView = groupPopup
        groupPopup.nextKeyView = replacementView
        replacementView.nextKeyView = enabledChip
        enabledChip.nextKeyView = caseChip
        caseChip.nextKeyView = boundaryChip
        boundaryChip.nextKeyView = plainChip
        plainChip.nextKeyView = cancelButton
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = titleField

        lastTextLength = (replacementView.string as NSString).length
        stage.updateTrigger(triggerField.stringValue)
        applyGuideVisibility()
        updateImageUI()
        view = glass
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        triggerDidChange()
    }

    /// ⌘Return path from EditorKeyablePanel — mirrors the Save button.
    func saveFromKeyboard() { saveTapped() }

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
        // §3: ⌘/ is the documented "show me the macros" shortcut.
        button.keyEquivalent = "/"
        button.keyEquivalentModifierMask = [.command]
        button.toolTip = loc.s("editor.hint.macros")
        button.setAccessibilityRole(NSAccessibility.Role.button)
        button.setAccessibilityLabel(loc.s("editor.macros"))
        button.setAccessibilityHelp(loc.s("editor.hint.macros"))
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
        button.setAccessibilityRole(NSAccessibility.Role.button)
        button.setAccessibilityLabel(loc.s("editor.image.attach"))
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
        // §4: labelled in `updateImageUI()` once the file name is known.
        imagePreviewView.setAccessibilityRole(NSAccessibility.Role.image)

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
        // §4: an unlabelled NSTextView is announced only as "text entry area".
        replacementView.setAccessibilityLabel(loc.s("ax.editor.replacement"))
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
        // §2: keep the pending placeholder ranges aligned with the edit that just
        // happened, so typing over one placeholder does not desynchronise the
        // rest of the just-inserted token.
        let newLength = (replacementView.string as NSString).length
        let delta = newLength - lastTextLength
        lastTextLength = newLength
        if delta != 0, !placeholderRanges.isEmpty {
            let caret = replacementView.selectedRange().location
            // An insertion of `delta` characters ended at the caret; a deletion
            // leaves the caret at the edit point.
            let editStart = caret - max(delta, 0)
            for index in placeholderRanges.indices where index >= placeholderCursor {
                if placeholderRanges[index].location >= editStart {
                    placeholderRanges[index].location = max(0, placeholderRanges[index].location + delta)
                }
            }
        }
        refreshPreview()
    }

    /// §2: Tab hops to the next editable span of the macro that was just
    /// inserted. With no pending span we return `false`, so AppKit's default
    /// (inserting a literal tab, which snippet bodies legitimately need) is
    /// unchanged.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === replacementView else { return false }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            return advanceToNextPlaceholder()
        }
        return false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === triggerField else { return }
        triggerDidChange()
    }

    /// §1 / §3: one entry point for everything that reacts to the trigger — the
    /// hero chip, the guide's live rule sentence, and validation.
    private func triggerDidChange() {
        let raw = triggerField.stringValue
        stage.updateTrigger(raw)
        guideView?.update(trigger: raw, requireWordBoundary: boundaryChip?.isOn ?? true)
        validateTriggerLive()
    }

    /// Live trigger check: a green ✓ when the trigger is usable, the conflict
    /// inline when it is not, and Save disabled until it is — no more
    /// type-everything-then-fail-on-Save.
    ///
    /// §3: also catches the silent failure mode. `AbbreviationMatcher`'s ring
    /// buffer caps at `matchableTriggerLimit` characters, so a longer trigger
    /// saves happily and then never fires; nothing used to say so.
    private func validateTriggerLive() {
        let trigger = triggerField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty else {
            isTriggerValid = false
            saveButton?.isEnabled = false
            triggerStatusLabel.stringValue = ""
            stage.setInvalid(false)
            errorLabel.isHidden = true
            setTriggerRule(loc.s("editor.trigger.hint"), isError: false)
            return
        }
        if trigger.count > AbbreviationMatcher.matchableTriggerLimit {
            isTriggerValid = false
            saveButton?.isEnabled = false
            triggerStatusLabel.stringValue = ""
            errorLabel.stringValue = loc.s("editor.error.tooLong", AbbreviationMatcher.matchableTriggerLimit)
            errorLabel.isHidden = false
            errorLabel.setAccessibilityValue(errorLabel.stringValue)
            stage.setInvalid(true)
            setTriggerRule(errorLabel.stringValue, isError: true)
            return
        }
        // Duplicate detection comes from the host's `validate` closure because it
        // can exclude the snippet being edited. `SnippetStore.triggerConflicts()`
        // reads the saved library only, so it would report this draft as
        // colliding with its own stored copy.
        if let conflict = validate(trigger, caseChip?.isOn ?? false) {
            isTriggerValid = false
            saveButton?.isEnabled = false
            triggerStatusLabel.stringValue = ""
            errorLabel.stringValue = conflict
            errorLabel.isHidden = false
            errorLabel.setAccessibilityValue(conflict)
            stage.setInvalid(true)
            setTriggerRule(loc.s("editor.error.duplicateLive"), isError: true)
        } else {
            isTriggerValid = true
            saveButton?.isEnabled = true
            triggerStatusLabel.stringValue = "✓ " + loc.s("editor.trigger.available")
            triggerStatusLabel.textColor = DevTypeTheme.statusGreen
            triggerStatusLabel.setAccessibilityValue(loc.s("editor.trigger.available"))
            stage.setInvalid(false)
            errorLabel.isHidden = true
            // §1: the rule that only README ever stated, rendered against the
            // trigger the user actually typed.
            setTriggerRule(
                TriggerRuleDescription.text(
                    for: trigger,
                    requireWordBoundary: boundaryChip?.isOn ?? true,
                    loc: loc
                ),
                isError: false
            )
        }
    }

    private func setTriggerRule(_ text: String, isError: Bool) {
        triggerRuleLabel.stringValue = text
        triggerRuleLabel.textColor = isError ? DevTypeTheme.accentBright : DevTypeTheme.textTertiary
        triggerRuleLabel.toolTip = text
        // §5.2: colour never carries this alone — the sentence is the signal, and
        // the AX value repeats it verbatim.
        triggerRuleLabel.setAccessibilityValue(text)
    }

    // MARK: §1 — new-snippet guide

    private func applyGuideVisibility() {
        guideHeightConstraint?.constant = guideVisible ? SnippetEditorGuideView.preferredHeight : 0
        editorHeightConstraint?.constant = guideVisible
            ? Self.editorHeightWithGuide
            : Self.editorHeightWithGuide + SnippetEditorGuideView.preferredHeight
        guideView?.isHidden = !guideVisible
        let key = guideVisible ? "guide.hide" : "guide.show"
        helpButton?.toolTip = loc.s(key)
        helpButton?.setAccessibilityLabel(loc.s(key))
        // Guarded: this runs once from inside `loadView`, where touching `view`
        // before it is assigned would re-enter `loadView` forever.
        if isViewLoaded { view.layoutSubtreeIfNeeded() }
    }

    @objc private func toggleGuide() {
        guard guideView != nil else { return }
        guideVisible.toggle()
        SnippetEditorGuideView.isDismissed = !guideVisible
        applyGuideVisibility()
        if guideVisible { triggerDidChange() }
    }

    private func dismissGuide() {
        guideVisible = false
        SnippetEditorGuideView.isDismissed = true
        applyGuideVisibility()
    }

    /// §1: one click fills trigger *and* body, so the first thing a new user sees
    /// is a snippet that actually works.
    private func applyStarter(_ starter: SnippetStarterTemplate) {
        triggerField.stringValue = starter.trigger
        if titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            titleField.stringValue = loc.s(starter.titleKey)
        }
        replacementView.string = starter.replacement
        lastTextLength = (replacementView.string as NSString).length
        placeholderRanges = []
        placeholderCursor = 0
        // A starter is text; an attached image would hide it entirely.
        pickedImageURL = nil
        attachedImagePath = ""
        updateImageUI()
        triggerDidChange()
        view.window?.makeFirstResponder(replacementView)
        replacementView.setSelectedRange(NSRange(location: lastTextLength, length: 0))
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

    /// §2: opens the searchable palette. This used to pop a flat `NSMenu` with a
    /// Date submenu plus nine hardcoded `(title, rawToken)` tuples — no search,
    /// no descriptions, no examples, and no exposure at all for the macros the
    /// engine gained since it was written (date arithmetic, case transforms,
    /// `%uuid%`, `%random:…%`, `%counter:…%`, the whole mustache syntax).
    @objc private func showMacroMenu(_ sender: NSButton) {
        guard !hasImage else { return }
        let presented = MacroPalettePanel.present(
            from: view.window,
            loc: loc,
            onInsert: { [weak self] descriptor in
                self?.insert(descriptor: descriptor)
            }
        )
        // Lightweight fallback so the affordance is never dead.
        if !presented { showFallbackMacroMenu(from: sender) }
    }

    /// Fallback menu, built from the *same* catalogue as the palette so the two
    /// can never drift apart the way the old hardcoded menu drifted from the
    /// engine.
    private func showFallbackMacroMenu(from sender: NSButton) {
        let menu = NSMenu()
        for category in MacroCategory.allCases {
            let descriptors = MacroCatalog.descriptors(in: category)
            guard !descriptors.isEmpty else { continue }
            let parent = NSMenuItem(title: loc.s(category.titleKey), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for descriptor in descriptors {
                let name = descriptor.name(using: loc)
                let example = descriptor.example
                let item = NSMenuItem(
                    title: example.isEmpty ? name : "\(name) — \(example)",
                    action: #selector(insertMacroFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = descriptor.id
                item.toolTip = descriptor.detail(using: loc)
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func insertMacroFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let descriptor = MacroCatalog.all.first(where: { $0.id == id }) else { return }
        insert(descriptor: descriptor)
    }

    /// §2: smart insertion — the biggest win over the old menu. The token goes
    /// in, then its first editable span is *selected* so the user types straight
    /// over it instead of hand-editing raw macro syntax. Tab walks the rest.
    private func insert(descriptor: MacroDescriptor) {
        // Cleared first so the `didChangeText()` below has nothing stale to
        // shift; that notification also refreshes `lastTextLength` for us.
        placeholderRanges = []
        placeholderCursor = 0

        let selected = replacementView.selectedRange()
        let origin = selected.location
        replacementView.insertText(descriptor.token, replacementRange: selected)
        replacementView.didChangeText()
        view.window?.makeFirstResponder(replacementView)

        placeholderRanges = descriptor.placeholders.map {
            NSRange(location: origin + $0.offset, length: $0.length)
        }
        placeholderCursor = 0
        if !advanceToNextPlaceholder() {
            // No editable span: park the caret just after the token. That is the
            // right place for `%|`, `{{cursor}}` and the bare key macros.
            let length = (replacementView.string as NSString).length
            let end = min(origin + (descriptor.token as NSString).length, length)
            replacementView.setSelectedRange(NSRange(location: max(0, end), length: 0))
        }
        refreshPreview()
    }

    @discardableResult
    private func advanceToNextPlaceholder() -> Bool {
        let length = (replacementView.string as NSString).length
        while placeholderCursor < placeholderRanges.count {
            let range = placeholderRanges[placeholderCursor]
            placeholderCursor += 1
            guard range.location >= 0, range.location <= length else { continue }
            let safe = NSRange(
                location: range.location,
                length: min(range.length, length - range.location)
            )
            replacementView.setSelectedRange(safe)
            replacementView.scrollRangeToVisible(safe)
            return true
        }
        placeholderRanges = []
        placeholderCursor = 0
        return false
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
    // MARK: Actions

    @objc private func chipTapped(_ sender: ToggleChip) {
        sender.isOn.toggle()
        // Case sensitivity changes what counts as a conflict, and Word Boundary
        // changes the firing rule the guide explains — both re-run live.
        if sender === caseChip || sender === boundaryChip { triggerDidChange() }
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
        // §3: the 64-character ring-buffer cap — over it, the trigger can never
        // fire, so refuse rather than saving a snippet that silently does nothing.
        if trigger.count > AbbreviationMatcher.matchableTriggerLimit {
            showError(loc.s("editor.error.tooLong", AbbreviationMatcher.matchableTriggerLimit))
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
        snippet.title = title.isEmpty ? Self.derivedTitle(from: replacement) : title
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
        // §4: an error that only appears visually is invisible to VoiceOver.
        errorLabel.setAccessibilityRole(NSAccessibility.Role.staticText)
        errorLabel.setAccessibilityValue(message)
        view.layoutSubtreeIfNeeded()
        guard !DevTypeAccessibility.reduceMotion else { return }
        // Brief attention shake on the trigger field.
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -6, 5, -3, 2, 0]
        animation.duration = 0.32
        triggerField.wantsLayer = true
        triggerField.layer?.add(animation, forKey: "devtype.shake")
    }

    /// A blank Title used to save as "Untitled". Deriving the first line of the
    /// replacement (or the trigger) makes the manager list self-explanatory.
    static func derivedTitle(from replacement: String) -> String {
        let firstLine = replacement
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if firstLine.isEmpty { return "Untitled" }
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
    }
}
