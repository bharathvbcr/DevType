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

    /// First non-blank line of the body, truncated — the fallback when the user leaves the
    /// title empty. Lives here rather than on the private controller because the
    /// typed-repetition offer builds a draft without ever opening one.
    static func derivedTitle(from replacement: String) -> String {
        let firstLine = replacement
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if firstLine.isEmpty { return "Untitled" }
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
    }
    /// §1 / §3: sized once here so the panel and its glass container can never
    /// disagree. The extra height over the old 500×548 buys the new-snippet
    /// guide strip and a materially taller replacement editor.
    /// Height of the behaviour pill row itself — `ToggleChip.intrinsicContentSize.height` plus a
    /// hair, so a focus ring is not clipped.
    static let chipRowHeight: CGFloat = 26

    /// Strip reserved *below* the pills for the horizontal overlay scroller.
    ///
    /// Overlay scrollers float over their content rather than taking layout space, which is
    /// exactly the problem: while scrolling, the bar was drawn across the bottom of the pills.
    /// Giving it a band of its own is cheaper than hiding it, and hiding it would leave the
    /// overflowing chips with no affordance at all.
    ///
    /// Sized by eye rather than by the scroller's own metrics: `NSScroller.scrollerWidth` reports
    /// the bar alone (~11pt at overlay size), which leaves it touching the pills above and the
    /// error line below. The extra clearance is the difference between "not overlapping" and
    /// "not crowded".
    static let chipScrollerBand: CGFloat = 20

    static let panelWidth: CGFloat = 520
    static let panelHeight: CGFloat = 690

    private static var activePanel: NSPanel?
    private static var activeController: SnippetEditorController?

    static func present(
        from hostWindow: NSWindow?,
        existing: SnippetModel?,
        draft: SnippetModel? = nil,
        groups: [SnippetGroup],
        currentGroupID: UUID?,
        loc: LocalizationManager = .shared,
        validate: @escaping (_ trigger: String, _ caseSensitive: Bool) -> String?,
        completion: @escaping (SnippetModel?, UUID?) -> Void
    ) {
        // Same single-instance contract as MacroPalettePanel.present: a second
        // presentation while one is up would overwrite the statics, and finishing
        // the first would then nil them out from under the second.
        if activePanel != nil { return }
        let panel = EditorKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)
        // This panel is a fixed-size, non-resizable sheet, and nothing inside it should be able to
        // change that. Without the clamp, AppKit sizes a borderless window from its content view's
        // *fitting* size, which counts every label's intrinsic width — so one label fed by
        // user-typed text (the live preview) was enough to make the editor grow as you typed.
        // The individual causes are fixed at the source; this makes the next one impossible.
        let fixedSize = NSSize(width: panelWidth, height: panelHeight)
        panel.contentMinSize = fixedSize
        panel.contentMaxSize = fixedSize

        let controller = SnippetEditorController(
            existing: existing,
            draft: draft,
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
        chipLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        // A label's intrinsic width counts toward the content view's fitting size, and a
        // borderless panel is sized from that — so a label that wants to be 900pt wide *widens
        // the window*. That is the "editor grows as I type" bug: this strip previews the
        // replacement text, so every character typed pushed the panel out. Let it be compressed
        // and truncated instead; `lineBreakMode` above is what makes that read correctly.
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
            previewLabel.stringValue = MacroPreview.clampedForStage(rendered)
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

// MARK: - Composer pill

/// Toolbar pill for the replacement composer — icon + label + an optional
/// shortcut hint baked into the same capsule. Replaces the 18pt ghost buttons
/// that used to hide in the caption row: bigger target, visible shortcut, and
/// a hover wash, sitting where every chat/post composer has trained users to
/// look for attachments and formatting.
private final class ComposerPillButton: NSButton {
    private let symbolName: String
    private let shortcutHint: String?
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String, shortcut: String?, target: AnyObject?, action: Selector?) {
        self.symbolName = symbol
        self.shortcutHint = shortcut
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(NSAccessibility.Role.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var titleFont: NSFont { DevTypeTheme.font(11, .semibold) }
    private var hintFont: NSFont { DevTypeTheme.mono(9.5, .medium) }

    override var intrinsicContentSize: NSSize {
        var width: CGFloat = 12 + 11 + 5 // leading pad + icon + gap
        width += (title as NSString).size(withAttributes: [.font: titleFont]).width
        if let shortcutHint {
            width += 8 + (shortcutHint as NSString).size(withAttributes: [.font: hintFont]).width
        }
        width += 12 // trailing pad
        return NSSize(width: ceil(width), height: 24)
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
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        DevTypeTheme.accent.withAlphaComponent(hovering ? 0.24 : 0.13).setFill()
        path.fill()
        DevTypeTheme.accent.withAlphaComponent(hovering ? 0.58 : 0.32).setStroke()
        path.lineWidth = 1
        path.stroke()

        var x: CGFloat = 12
        if let icon = DevTypeTheme.tintedSymbol(symbolName, size: 10, weight: .bold, color: DevTypeTheme.accentBright) {
            icon.draw(
                in: NSRect(x: x, y: (bounds.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: nil
            )
        }
        x += 11 + 5

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: DevTypeTheme.accentBright
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        (title as NSString).draw(
            at: NSPoint(x: x, y: (bounds.height - titleSize.height) / 2),
            withAttributes: titleAttributes
        )
        x += titleSize.width

        if let shortcutHint {
            let hintAttributes: [NSAttributedString.Key: Any] = [
                .font: hintFont,
                .foregroundColor: hovering ? DevTypeTheme.textSecondary : DevTypeTheme.textTertiary
            ]
            let hintSize = (shortcutHint as NSString).size(withAttributes: hintAttributes)
            (shortcutHint as NSString).draw(
                at: NSPoint(x: x + 8, y: (bounds.height - hintSize.height) / 2),
                withAttributes: hintAttributes
            )
        }
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
    private var helpText: String = ""

    /// Non-nil when this toggle has no effect for the current trigger.
    ///
    /// A control that looks live but changes nothing is worse than no control: it is what
    /// makes `requireWordBoundary` read as "already on" for a `` ` ``-prefixed trigger, when
    /// `AbbreviationMatcher` rule (1) never consults it. The stored value is preserved (so
    /// saving does not silently rewrite the model, and the flag becomes meaningful again if
    /// the trigger is renamed) — the chip just stops accepting clicks and says why.
    var inertReason: String? {
        didSet {
            isEnabled = inertReason == nil
            alphaValue = isEnabled ? 1.0 : 0.4
            toolTip = inertReason ?? helpText
            setAccessibilityHelp(inertReason ?? helpText)
            refreshAccessibilityValue()
            needsDisplay = true
        }
    }

    init(title: String, symbol: String, isOn: Bool, help: String, target: AnyObject?, action: Selector?) {
        self.symbolName = symbol
        self.isOn = isOn
        self.helpText = help
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
        // VoiceOver must not read an inert toggle as a live "on" — that is the same lie the
        // dimmed appearance exists to stop telling sighted users.
        if inertReason != nil {
            setAccessibilityValue(loc.s("ax.notApplicable"))
            return
        }
        setAccessibilityValue(isOn ? loc.s("ax.enabled") : loc.s("ax.disabled"))
    }

    override var intrinsicContentSize: NSSize {
        let textSize = (title as NSString).size(withAttributes: [
            .font: font ?? DevTypeTheme.font(11, .semibold)
        ])
        // Padding covers the 10pt glyph + 5pt gap and still leaves ~10pt of
        // breathing room per side. Any wider and the four chips stop fitting on
        // one row inside the 480pt content width.
        return NSSize(width: ceil(textSize.width) + 36, height: 24)
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
    /// Prefill for a new snippet (e.g. Add from Template). Never treated as an edit.
    private let draft: SnippetModel?
    private let groups: [SnippetGroup]
    private let loc: LocalizationManager
    private let validate: (String, Bool) -> String?
    private let onFinish: (SnippetModel?, UUID?) -> Void

    /// Values shown in the form: edit target, or template draft, or blank.
    private var seed: SnippetModel? { existing ?? draft }

    private let titleField = GlassTextField()
    private let triggerField = GlassTextField()
    private let groupPopup = NSPopUpButton()
    private let aiTransformPopup = NSPopUpButton()
    private let replacementView = NSTextView()
    private let stage = ExpansionStageView()
    private var enabledChip: ToggleChip!
    private var caseChip: ToggleChip!
    private var boundaryChip: ToggleChip!
    private var plainChip: ToggleChip!
    private var secretChip: ToggleChip!
    /// Secure entry shown in place of the replacement text view while `secretChip` is on.
    private let secretField = NSSecureTextField()
    /// The replacement text view's scroller, hidden while the secure field has the slot.
    private weak var replacementScroll: NSScrollView?
    private let errorLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11, .medium), color: DevTypeTheme.accentBright, wrapping: true)
    private let charCountLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10, .medium), color: DevTypeTheme.textTertiary)
    private var editorContainer: NSView!
    /// The option-chip row, held so suggestion chips can be appended to and removed from it.
    private weak var chipsRow: NSStackView?
    private var macroButton: NSButton!
    /// The attach-image button, disabled while Secret is on: a snippet cannot be both.
    private weak var imageButton: NSButton?
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
    /// Collapses the inline error to zero height while there is nothing to say.
    private var errorHeightConstraint: NSLayoutConstraint?
    private var helpButton: NSButton?
    private var guideVisible: Bool

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

    // MARK: - On-device tag suggestion (`SnippetTagSuggester`)

    /// What the model offered and what the user has accepted of it. `nil` until a suggestion
    /// arrives. Nothing here reaches the snippet without a chip being switched on.
    private var acceptance: TagSuggestionAcceptance?
    /// In-flight suggestion. Cancelled on every keystroke and when the sheet closes, so a
    /// result for a body the user has since rewritten can never land.
    private var suggestionTask: Task<Void, Never>?
    /// The chips currently offering the suggestion, so a new suggestion can replace them
    /// without disturbing the permanent option chips they sit beside.
    private var suggestionChips: [ToggleChip] = []
    /// One chip per tag the snippet already carries, each switched on. Switching one off
    /// removes that tag at save — until now a tag could be written (by an Espanso import, or
    /// by a suggestion) but never seen or taken back.
    private var existingTagChips: [ToggleChip] = []
    /// The chip offering the suggested group, if one was offered.
    private weak var groupSuggestionChip: ToggleChip?
    /// Per-app scope, edited in `SnippetAppScopeSheet` and written at save. Seeded from the
    /// snippet so an imported scope survives an edit that never opens the sheet.
    private var appScope: SnippetAppScope = .unscoped
    private weak var appScopeChip: ToggleChip?

    /// Free-form tag entry. Lives at the end of the chip row, so it costs no vertical space in
    /// a panel whose height is fixed — the row already scrolls horizontally when it overflows.
    private let newTagField = NSTextField()
    /// The group selected before the group chip was switched on, restored if it is switched
    /// back off — accepting a suggestion and then changing your mind must not strand you on it.
    private var groupSelectionBeforeSuggestion: UUID?

    private var hasImage: Bool { pickedImageURL != nil || !attachedImagePath.isEmpty }

    init(
        existing: SnippetModel?,
        draft: SnippetModel? = nil,
        groups: [SnippetGroup],
        currentGroupID: UUID?,
        loc: LocalizationManager,
        validate: @escaping (String, Bool) -> String?,
        onFinish: @escaping (SnippetModel?, UUID?) -> Void
    ) {
        self.existing = existing
        self.draft = draft
        self.groups = groups
        self.loc = loc
        self.validate = validate
        self.onFinish = onFinish
        self.initialGroupID = currentGroupID ?? groups.first?.id
        self.attachedImagePath = (existing ?? draft)?.imagePath ?? ""
        // §1: never shown when editing an existing snippet, and the dismissal is
        // remembered across launches.
        self.guideVisible = (existing == nil) && !SnippetEditorGuideView.isDismissed
        super.init(nibName: nil, bundle: nil)
    }

    private let initialGroupID: UUID?

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        // The task captures `self` weakly, so this is not a leak fix — it stops a model
        // request whose answer nothing will read from holding the adapter warm.
        suggestionTask?.cancel()
    }

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
        titleField.stringValue = seed?.title ?? ""
        // §4: the caption is a separate view, so VoiceOver cannot infer it.
        titleField.setAccessibilityLabel(loc.s("editor.name"))
        root.addSubview(nameCaption)
        root.addSubview(titleField)

        // Trigger (left) + Group (right), side by side
        let triggerCaption = caption(loc.s("editor.trigger"))
        triggerField.placeholderAttributedString = placeholder("e.g. :eml")
        triggerField.font = DevTypeTheme.mono(13, .medium)
        triggerField.stringValue = seed?.triggerKeyword ?? ""
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

        // Replacement — the macro palette and image picker live in the
        // composer's own toolbar, so the caption line stays quiet apart from the
        // AI Transform control, which is a property *of* the replacement and now
        // rides on its header row instead of stacking under Group.
        let replacementCaption = caption(loc.s("editor.replacement"))
        let editorContainer = makeEditorContainer()
        self.editorContainer = editorContainer
        let imageBar = makeImagePreviewBar()
        self.imagePreviewBar = imageBar
        root.addSubview(replacementCaption)
        root.addSubview(editorContainer)
        root.addSubview(imageBar)

        let aiTransformRaw = seed?.aiTransform.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let aiCaption = caption(loc.s("editor.aiTransform"))
        aiCaption.setContentCompressionResistancePriority(.required, for: .horizontal)
        configureAITransformPopup(selectedRaw: aiTransformRaw)
        root.addSubview(aiCaption)
        root.addSubview(aiTransformPopup)

        // Behavior toggle chips
        let behaviorCaption = caption(loc.s("editor.behavior"))
        root.addSubview(behaviorCaption)

        enabledChip = ToggleChip(
            title: loc.s("editor.enabled"), symbol: "power",
            isOn: seed?.enabled ?? true,
            help: loc.s("editor.enabled.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        caseChip = ToggleChip(
            title: loc.s("editor.caseSensitive"), symbol: "textformat",
            // §5: default ON for new snippets — ":Hi" silently swallowing ":hi"
            // was the most confusing matching behaviour a new user could hit.
            isOn: seed?.isCaseSensitive ?? true,
            help: loc.s("editor.caseSensitive.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        boundaryChip = ToggleChip(
            title: loc.s("editor.wordBoundary"), symbol: "paragraphsign",
            isOn: seed?.requireWordBoundary ?? true,
            // §1: this is the toggle that changes the trigger rule the guide
            // explains, so its help text spells that rule out in full.
            help: loc.s("editor.wordBoundary.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        plainChip = ToggleChip(
            title: loc.s("editor.plainText"), symbol: "doc.plaintext",
            isOn: seed?.isPlainText ?? true,
            help: loc.s("editor.plainText.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        secretChip = ToggleChip(
            title: loc.s("editor.secret.toggle"), symbol: "key.fill",
            isOn: seed?.isSecret ?? false,
            help: loc.s("editor.secret.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        // Editing an existing secret shows an empty field with a "stored" placeholder: the value
        // is in the keychain and is deliberately never fetched to populate this view. Leaving the
        // field untouched keeps what is stored; typing replaces it.
        secretField.placeholderString = loc.s(
            (seed?.isSecret ?? false) ? "editor.secret.unchanged" : "editor.secret.placeholder"
        )
        secretField.translatesAutoresizingMaskIntoConstraints = false
        secretField.font = DevTypeTheme.font(13, .regular)
        secretField.isHidden = !(seed?.isSecret ?? false)

        let chipsRow = NSStackView(views: [enabledChip, caseChip, boundaryChip, plainChip, secretChip])
        // Suggestion chips are appended to this same row rather than given a row of their own:
        // the panel is a fixed 690pt and this one already scrolls horizontally when it overflows.
        self.chipsRow = chipsRow
        for tag in seed?.tags ?? [] {
            existingTagChips.append(makeExistingTagChip(tag))
        }
        for chip in existingTagChips { chipsRow.addArrangedSubview(chip) }
        appScope = SnippetAppScope(
            includeApps: seed?.includeApps ?? [],
            excludeApps: seed?.excludeApps ?? []
        )
        let scopeChip = ToggleChip(
            title: SnippetAppScopeSummary.chipTitle(
                include: appScope.includeApps, exclude: appScope.excludeApps, loc: loc
            ),
            symbol: "macwindow.on.rectangle",
            isOn: appScope.isScoped,
            help: loc.s("appscope.chip.help"),
            target: self,
            action: #selector(appScopeChipTapped)
        )
        appScopeChip = scopeChip
        chipsRow.addArrangedSubview(scopeChip)
        configureNewTagField()
        chipsRow.addArrangedSubview(newTagField)
        chipsRow.orientation = .horizontal
        chipsRow.alignment = .centerY
        chipsRow.spacing = 8
        chipsRow.translatesAutoresizingMaskIntoConstraints = false

        // The row is wider than the panel. `ToggleChip.intrinsicContentSize` says as much in its
        // own comment — "any wider and the four chips stop fitting on one row inside the 480pt
        // content width" — and Secret is the fifth. The row had only a leading constraint, so the
        // overflow simply ran off the edge with no way to reach it.
        //
        // Scrolled rather than wrapped: a second line would have to come out of the composer's
        // height, which is the part of this panel worth the space, and every chip stays on the
        // baseline the caption labels.
        let chipsScroll = NSScrollView()
        chipsScroll.translatesAutoresizingMaskIntoConstraints = false
        chipsScroll.hasHorizontalScroller = true
        chipsScroll.hasVerticalScroller = false
        chipsScroll.autohidesScrollers = true
        chipsScroll.scrollerStyle = .overlay
        chipsScroll.borderType = .noBorder
        chipsScroll.drawsBackground = false
        chipsScroll.horizontalScrollElasticity = .allowed
        chipsScroll.verticalScrollElasticity = .none
        // An overlay scroller draws *on top of* the content it scrolls, so mid-scroll it sat
        // across the bottom of the pills. Reserve a band for it instead: the content inset keeps
        // the document out of the strip the scroller appears in, so the two never share pixels.
        chipsScroll.automaticallyAdjustsContentInsets = false
        chipsScroll.contentInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: SnippetEditorSheet.chipScrollerBand,
            right: 0
        )
        chipsScroll.documentView = chipsRow
        root.addSubview(chipsScroll)

        NSLayoutConstraint.activate([
            // Pin the row inside the clip view so the stack keeps its intrinsic width (that is
            // what there is to scroll) while its height matches the visible strip.
            chipsRow.leadingAnchor.constraint(equalTo: chipsScroll.contentView.leadingAnchor),
            chipsRow.topAnchor.constraint(equalTo: chipsScroll.contentView.topAnchor),
            // Height, not a bottom pin: pinned to the bottom the stack would stretch across the
            // scroller's band and put the pills back under it.
            chipsRow.heightAnchor.constraint(equalToConstant: SnippetEditorSheet.chipRowHeight),
        ])

        // Inline error
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        errorLabel.maximumNumberOfLines = 2
        // Setting `maximumNumberOfLines` resets the wrapping label's break mode,
        // which left long conflict messages clipped mid-word at the panel edge.
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.cell?.wraps = true
        errorLabel.cell?.isScrollable = false
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

        // §1 / §3: everything above the composer hangs off the top edge and
        // everything below it hangs off the bottom edge, leaving the replacement
        // editor as the single flexible row. Collapsing the guide — or hiding
        // the inline error — therefore hands its space straight to the editor
        // with no per-state height arithmetic to keep in sync, and no element
        // can ever grow through the footer.
        let guideHeight = guide?.heightAnchor.constraint(
            equalToConstant: guideVisible ? SnippetEditorGuideView.preferredHeight : 0
        )
        guideHeightConstraint = guideHeight

        // The error takes no space until there is something to say.
        errorLabel.preferredMaxLayoutWidth = SnippetEditorSheet.panelWidth - 40
        let errorHeight = errorLabel.heightAnchor.constraint(equalToConstant: 0)
        errorHeightConstraint = errorHeight

        // Floor for the flexible row, below required so a pathological state
        // (very long error, very tall guide) degrades instead of logging a
        // constraint conflict.
        let editorMinHeight = editorContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 88)
        editorMinHeight.priority = NSLayoutConstraint.Priority(999)

        // The rule sentence spans the full width, so it has to clear BOTH
        // columns. The required `>=` pair does that; this low-priority spring
        // pulls it snug against whichever column ends lower (the popup, today)
        // so the position stays unambiguous.
        let ruleTopSpring = triggerRuleLabel.topAnchor.constraint(
            equalTo: groupPopup.bottomAnchor,
            constant: 6
        )
        ruleTopSpring.priority = .defaultLow

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
            editorMinHeight,
            errorHeight,
            ruleTopSpring,
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

            // Sits below BOTH columns — as a half-width neighbour of the popup
            // it used to be drawn straight through the AI Transform caption.
            triggerRuleLabel.topAnchor.constraint(greaterThanOrEqualTo: triggerField.bottomAnchor, constant: 6),
            triggerRuleLabel.topAnchor.constraint(greaterThanOrEqualTo: groupPopup.bottomAnchor, constant: 6),
            triggerRuleLabel.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            triggerRuleLabel.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            groupCaption.topAnchor.constraint(equalTo: triggerCaption.topAnchor),
            groupCaption.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: columnGap / 2 + 2),
            groupPopup.topAnchor.constraint(equalTo: groupCaption.bottomAnchor, constant: 4),
            groupPopup.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: columnGap / 2),
            groupPopup.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            // Composer header: caption on the left, AI Transform on the right.
            aiTransformPopup.topAnchor.constraint(equalTo: triggerRuleLabel.bottomAnchor, constant: 12),
            aiTransformPopup.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            aiTransformPopup.widthAnchor.constraint(equalToConstant: 136),
            aiCaption.trailingAnchor.constraint(equalTo: aiTransformPopup.leadingAnchor, constant: -8),
            aiCaption.centerYAnchor.constraint(equalTo: aiTransformPopup.centerYAnchor),

            replacementCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            replacementCaption.centerYAnchor.constraint(equalTo: aiTransformPopup.centerYAnchor),
            replacementCaption.trailingAnchor.constraint(lessThanOrEqualTo: aiCaption.leadingAnchor, constant: -10),

            editorContainer.topAnchor.constraint(equalTo: aiTransformPopup.bottomAnchor, constant: 6),
            editorContainer.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            imageBar.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            imageBar.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            imageBar.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            imageBar.heightAnchor.constraint(equalTo: editorContainer.heightAnchor),

            // Bottom half, anchored UP from the footer: the composer's bottom
            // edge is whatever is left over.
            editorContainer.bottomAnchor.constraint(equalTo: behaviorCaption.topAnchor, constant: -12),
            behaviorCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            behaviorCaption.bottomAnchor.constraint(equalTo: chipsScroll.topAnchor, constant: -9),
            chipsScroll.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            // The trailing edge is the whole point: without it the row had nothing telling it
            // where the panel ends, so it overflowed instead of scrolling.
            chipsScroll.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            chipsScroll.heightAnchor.constraint(
                equalToConstant: SnippetEditorSheet.chipRowHeight + SnippetEditorSheet.chipScrollerBand
            ),
            chipsScroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -10),

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
        groupPopup.nextKeyView = aiTransformPopup
        aiTransformPopup.nextKeyView = replacementView
        replacementView.nextKeyView = enabledChip
        enabledChip.nextKeyView = caseChip
        caseChip.nextKeyView = boundaryChip
        boundaryChip.nextKeyView = plainChip
        plainChip.nextKeyView = secretChip
        secretChip.nextKeyView = cancelButton
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = titleField

        lastTextLength = (replacementView.string as NSString).length
        stage.updateTrigger(triggerField.stringValue)
        applyGuideVisibility()
        updateImageUI()
        view = glass
    }

    override func viewDidLoad() {
        defer { applySecretVisibility() }
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

    private func configureAITransformPopup(selectedRaw: String) {
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

    private var selectedAITransform: String {
        (aiTransformPopup.selectedItem?.representedObject as? String) ?? ""
    }

    private var selectedGroupID: UUID? {
        guard let raw = groupPopup.selectedItem?.representedObject as? String else { return groups.first?.id }
        return UUID(uuidString: raw) ?? groups.first?.id
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

    /// Composer: text editor on top, toolbar (macro palette · image · character
    /// count) along the bottom — the layout every chat/post composer trained
    /// users to expect. The macro palette gets a real pill with its ⌘/ hint
    /// baked in instead of an 18pt ghost button hidden in the caption row.
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

        container.addSubview(scroll)
        // The secret field occupies the replacement text view's own slot rather than a row of its
        // own: it *is* the replacement, and the outer layout pins `chipsRow` directly to the error
        // label with nothing between them to insert into.
        container.addSubview(secretField)
        container.addSubview(toolbarRule)
        container.addSubview(macro)
        container.addSubview(image)
        container.addSubview(charCountLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: toolbarRule.topAnchor, constant: -2),

            secretField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            secretField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            secretField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            secretField.heightAnchor.constraint(equalToConstant: 24),

            toolbarRule.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            toolbarRule.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            toolbarRule.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -35),

            macro.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            macro.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),

            image.leadingAnchor.constraint(equalTo: macro.trailingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: macro.centerYAnchor),

            charCountLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            charCountLabel.centerYAnchor.constraint(equalTo: macro.centerYAnchor)
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
        scheduleTagSuggestion()
    }

    // MARK: Tag suggestion

    /// Debounce before asking the model. Long enough that it does not fire mid-sentence;
    /// short enough to have an answer by the time the user reaches for Save.
    private static let tagSuggestionDebounce = Duration.milliseconds(900)

    /// Asks `SnippetTagSuggester` for tags once typing settles.
    ///
    /// New snippets only. Re-tagging an existing one would silently rewrite metadata the user
    /// may have curated by hand, and the sheet gives them no way to see that it happened.
    private func scheduleTagSuggestion() {
        suggestionTask?.cancel()
        suggestionTask = nil
        guard existing == nil, SnippetTagSuggester.isActive else { return }
        // A secret's body is the secret. It never reaches the model — the suggester refuses it
        // too, but the caller that has the plaintext is the right place to stop.
        let isSecret = secretChip?.isOn ?? false
        let body = replacementView.string
        guard SnippetTagSuggester.shouldSuggest(body: body, isSecret: isSecret) else {
            clearSuggestionChips()
            acceptance = nil
            return
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        let title = titleField.stringValue
        let names = groups.map(\.name)
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: Self.tagSuggestionDebounce)
            guard !Task.isCancelled else { return }
            let suggestion = await SnippetTagSuggester.suggest(
                title: title,
                body: body,
                isSecret: isSecret,
                groupNames: names
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.applyTagSuggestion(suggestion) }
        }
        #endif
    }

    /// Offers the suggestion. Applies none of it.
    ///
    /// Every chip starts off. A suggestion that the user never looks at therefore changes
    /// nothing about the snippet they save, which is the point: the model's read of a
    /// half-written body is a guess, and a guess should not be able to write to the library
    /// just because the user was typing quickly.
    private func applyTagSuggestion(_ suggestion: SnippetTagSuggester.Suggestion) {
        clearSuggestionChips()
        let acceptance = TagSuggestionAcceptance(suggestion: suggestion)
        guard acceptance.hasAnythingToOffer else {
            self.acceptance = nil
            return
        }
        self.acceptance = acceptance

        guard let chipsRow else { return }
        for tag in suggestion.tags {
            let chip = ToggleChip(
                title: tag,
                symbol: "tag",
                isOn: false,
                help: loc.s("editor.tags.suggested.help"),
                target: self,
                action: #selector(suggestedTagChipTapped(_:))
            )
            suggestionChips.append(chip)
            insertChipBeforeTagField(chip, in: chipsRow)
        }
        if let name = suggestion.groupName {
            let chip = ToggleChip(
                title: name,
                symbol: "folder",
                isOn: false,
                help: loc.s("editor.group.suggested.help"),
                target: self,
                action: #selector(suggestedGroupChipTapped(_:))
            )
            groupSuggestionChip = chip
            suggestionChips.append(chip)
            insertChipBeforeTagField(chip, in: chipsRow)
        }

    }

    private func insertChipBeforeTagField(_ chip: ToggleChip, in row: NSStackView) {
        if let index = row.arrangedSubviews.firstIndex(of: newTagField) {
            row.insertArrangedSubview(chip, at: index)
        } else {
            row.addArrangedSubview(chip)
        }
    }

    private func clearSuggestionChips() {
        for chip in suggestionChips {
            chipsRow?.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        suggestionChips.removeAll()
        groupSuggestionChip = nil
        // A chip-driven group selection does not outlive the chip that caused it.
        if acceptance?.isGroupAccepted == true, let previous = groupSelectionBeforeSuggestion {
            selectGroup(id: previous)
        }
        groupSelectionBeforeSuggestion = nil
    }

    @objc private func existingTagChipTapped(_ sender: ToggleChip) {
        sender.isOn.toggle()
    }

    /// Opens the scope editor. Unlike the other chips this one does not toggle: "all apps" is
    /// not the opposite of a specific list, and silently clearing one on a click would throw
    /// away exactly the thing the chip is advertising.
    @objc private func appScopeChipTapped() {
        SnippetAppScopeSheet.present(
            from: view.window,
            scope: appScope,
            loc: loc
        ) { [weak self] result in
            guard let self, let result else { return }
            self.appScope = result
            self.appScopeChip?.isOn = result.isScoped
            self.appScopeChip?.title = SnippetAppScopeSummary.chipTitle(
                include: result.includeApps, exclude: result.excludeApps, loc: self.loc
            )
            self.appScopeChip?.needsDisplay = true
        }
    }

    private func makeExistingTagChip(_ tag: String) -> ToggleChip {
        ToggleChip(
            title: tag,
            symbol: "tag.fill",
            isOn: true,
            help: loc.s("editor.tags.existing.help"),
            target: self,
            action: #selector(existingTagChipTapped(_:))
        )
    }

    private func configureNewTagField() {
        newTagField.translatesAutoresizingMaskIntoConstraints = false
        newTagField.placeholderString = loc.s("editor.tags.add.placeholder")
        newTagField.font = DevTypeTheme.font(11, .medium)
        newTagField.isBordered = false
        newTagField.drawsBackground = false
        newTagField.focusRingType = .none
        newTagField.target = self
        newTagField.action = #selector(newTagEntered)
        newTagField.setAccessibilityLabel(loc.s("editor.tags.add.placeholder"))
        newTagField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        newTagField.widthAnchor.constraint(equalToConstant: 120).isActive = true
    }

    /// Return in the tag field. The typed text goes through the same normalizer the model's
    /// suggestions do, so a hand-typed tag cannot carry a delimiter the exporter would read back
    /// as structure, and cannot duplicate one the snippet already has.
    @objc private func newTagEntered() {
        let raw = newTagField.stringValue
        let accepted = SnippetTagSuggester.normalizedTags([raw], existing: keptExistingTags)
        guard let tag = accepted.first else {
            // Rejected: empty, a duplicate, too long, or delimiter-bearing. Leave the text in
            // place rather than silently discarding what the user typed.
            NSSound.beep()
            return
        }
        let chip = makeExistingTagChip(tag)
        existingTagChips.append(chip)
        // Always before the entry field, so the field stays the last thing in the row.
        if let row = chipsRow, let index = row.arrangedSubviews.firstIndex(of: newTagField) {
            row.insertArrangedSubview(chip, at: index)
        } else {
            chipsRow?.addArrangedSubview(chip)
        }
        newTagField.stringValue = ""
    }

    /// Tags the user left switched on, in their stored order.
    private var keptExistingTags: [String] {
        existingTagChips.filter(\.isOn).map(\.title)
    }

    @objc private func suggestedTagChipTapped(_ sender: ToggleChip) {
        sender.isOn.toggle()
        acceptance?.setTag(sender.title, accepted: sender.isOn)
    }

    /// The one suggestion chip with an immediate effect — the group popup has to show the
    /// change for the user to judge it. Switching it back off restores what was selected before.
    @objc private func suggestedGroupChipTapped(_ sender: ToggleChip) {
        sender.isOn.toggle()
        acceptance?.setGroupAccepted(sender.isOn)
        if sender.isOn {
            groupSelectionBeforeSuggestion = selectedGroupID
            if let name = acceptance?.suggestion.groupName,
               let group = groups.first(where: { $0.name == name }) {
                selectGroup(id: group.id)
            }
        } else if let previous = groupSelectionBeforeSuggestion {
            selectGroup(id: previous)
            groupSelectionBeforeSuggestion = nil
        }
    }

    private func selectGroup(id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groupPopup.selectItem(at: index)
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
        // Rule (1): a punctuation-started trigger fires the moment it is typed and never
        // consults `requireWordBoundary`, so the chip must not present itself as live.
        let firstChar = raw.trimmingCharacters(in: .whitespacesAndNewlines).first
        let firesInstantly = firstChar.map { !AbbreviationMatcher.isWordCharacter($0) } ?? false
        boundaryChip?.inertReason = firesInstantly
            ? loc.s("editor.wordBoundary.inert", String(firstChar ?? " "))
            : nil
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
            setError(nil)
            setTriggerRule(loc.s("editor.trigger.hint"), isError: false)
            return
        }
        if trigger.count > AbbreviationMatcher.matchableTriggerLimit {
            isTriggerValid = false
            saveButton?.isEnabled = false
            triggerStatusLabel.stringValue = ""
            let message = loc.s("editor.error.tooLong", AbbreviationMatcher.matchableTriggerLimit)
            setError(message)
            stage.setInvalid(true)
            setTriggerRule(message, isError: true)
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
            setError(conflict)
            stage.setInvalid(true)
            setTriggerRule(loc.s("editor.error.duplicateLive"), isError: true)
        } else {
            isTriggerValid = true
            saveButton?.isEnabled = true
            triggerStatusLabel.stringValue = "✓ " + loc.s("editor.trigger.available")
            triggerStatusLabel.textColor = DevTypeTheme.statusGreen
            triggerStatusLabel.setAccessibilityValue(loc.s("editor.trigger.available"))
            stage.setInvalid(false)
            setError(nil)
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

    /// Single entry point for the inline error slot. `nil` collapses it to zero
    /// height so the space goes back to the composer; a message sizes the slot
    /// to the wrapped text (up to two lines) instead of letting it grow into the
    /// footer.
    private func setError(_ message: String?) {
        guard let message, !message.isEmpty else {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
            errorHeightConstraint?.constant = 0
            if isViewLoaded { view.layoutSubtreeIfNeeded() }
            return
        }
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        // §4: an error that only appears visually is invisible to VoiceOver.
        errorLabel.setAccessibilityRole(NSAccessibility.Role.staticText)
        errorLabel.setAccessibilityValue(message)
        // Measured from the string, not `fittingSize` — the collapsing height
        // constraint below is part of the label's own layout, so asking the view
        // would just hand back whatever the constraint currently says.
        let font = errorLabel.font ?? DevTypeTheme.font(11, .medium)
        let bounds = (message as NSString).boundingRect(
            with: NSSize(width: errorLabel.preferredMaxLayoutWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        // Two lines max, matching `maximumNumberOfLines`. The slack matters: the
        // cell drops a line it cannot fit *entirely* rather than clipping it, so
        // a slot measured exactly to `boundingRect` silently loses line two.
        let lineCap = 2 * ceil(font.boundingRectForFont.height) + 6
        errorHeightConstraint?.constant = min(lineCap, ceil(bounds.height) + 6)
        if isViewLoaded { view.layoutSubtreeIfNeeded() }
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
        if sender === secretChip { applySecretVisibility() }
    }

    func focusInitialField() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let target = self.existing == nil ? self.titleField : self.triggerField
            self.view.window?.makeFirstResponder(target)
        }
    }

    @objc private func cancelTapped() { onFinish(nil, nil) }

    /// A secret's value is typed into a secure field, never into the plain text view.
    ///
    /// The text view is left in place but emptied and disabled: a value already typed there
    /// before the toggle was flipped must not survive into the library, and the visible
    /// transition is what tells the user where the value is now going.
    private func applySecretVisibility() {
        let secret = secretChip?.isOn ?? false
        // A secret and an image are mutually exclusive: `isImageSnippet` and the keychain lookup
        // would each claim the snippet, and every consumer would pick a different winner. Turning
        // Secret on drops the attachment, and the attach button is unavailable while it is on.
        if secret, hasImage {
            pickedImageURL = nil
            attachedImagePath = ""
            updateImageUI()
        }
        imageButton?.isEnabled = !secret
        imageButton?.alphaValue = secret ? 0.4 : 1.0
        secretField.isHidden = !secret
        // Hidden rather than dimmed: two text areas in one slot, one of them live, is exactly the
        // ambiguity that gets a password typed into the wrong one.
        replacementScroll?.isHidden = secret
        replacementView.isEditable = !secret
        if secret {
            replacementView.string = ""
            view.window?.makeFirstResponder(secretField)
        }
        refreshPreview()
    }

    @objc private func saveTapped() {
        let trigger = triggerField.stringValue.trimmingCharacters(in: .whitespaces)
        // A secret is reachable only by an explicit gesture — the menu, or the copy palette — so
        // its trigger can never fire and demanding one made the user invent a keyword for
        // something that does nothing with it.
        let requiresTrigger = !(secretChip?.isOn ?? false)
        guard !trigger.isEmpty || !requiresTrigger else {
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
        if requiresTrigger, let conflict = validate(trigger, caseSensitive) {
            showError(conflict)
            return
        }

        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementView.string
        // A cleared body used to resurrect the previous text on save — or plant a
        // "Hello World" placeholder into a brand-new snippet — silently undoing what
        // the user just deleted. Refuse the save instead. Secrets and attached images
        // carry no body by design, so they stay exempt.
        if !hasImage && !(secretChip?.isOn ?? false), replacement.isEmpty {
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
        snippet.title = title.isEmpty ? Self.derivedTitle(from: replacement) : title
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
            // Unreachable with an empty body: the guard above refused it (or a secret
            // is on, and `applySecret` overwrites this below).
            snippet.replacementText = replacement
        }

        snippet.isCaseSensitive = caseSensitive
        snippet.requireWordBoundary = boundaryChip.isOn
        snippet.isPlainText = plainChip.isOn
        snippet.enabled = enabledChip.isOn
        snippet.aiTransform = selectedAITransform

        if !applySecret(to: &snippet) { return }

        snippet.updatedAt = Date()
        onFinish(snippet, selectedGroupID)
    }

    /// Route the value to the keychain (or back out of it), returning false to abort the save.
    ///
    /// Ordering matters and is the whole point: the keychain write happens *before* the snippet is
    /// handed on, so a refused write (locked keychain, denied prompt) stops the save instead of
    /// producing a snippet that claims to hold a secret it never stored. The reverse direction —
    /// un-ticking Secret — deletes the stored value rather than orphaning it.
    private func applySecret(to snippet: inout SnippetModel) -> Bool {
        let wantsSecret = secretChip?.isOn ?? false
        let typed = secretField.stringValue

        guard wantsSecret else {
            if existing?.isSecret == true { SecretStore.shared.remove(for: snippet.id) }
            snippet.isSecret = false
            return true
        }

        snippet.isSecret = true
        // The value never round-trips through the model, so a secret snippet's
        // `replacementText` is empty from here on — including in the copy handed to listeners.
        snippet.replacementText = ""

        if typed.isEmpty {
            // Untouched field on an existing secret: keep what is stored. On a *new* secret it
            // means there is nothing to store, which is a snippet that would paste nothing.
            if existing?.isSecret == true, SecretStore.shared.hasSecret(for: snippet.id) {
                return true
            }
            showError(loc.s("editor.secret.placeholder"))
            view.window?.makeFirstResponder(secretField)
            return false
        }

        switch SecretStore.shared.store(typed, for: snippet.id) {
        case .success:
            // Clear the field so the value does not sit in a live NSSecureTextField after save.
            secretField.stringValue = ""
            return true
        case .failure(let failure):
            let detail = failure.status.map(String.init) ?? "—"
            DevTypeAlert.present(
                title: loc.s("secret.saveFailed.title"),
                message: loc.s("secret.saveFailed.message", detail),
                style: .warning,
                buttons: [loc.s("common.ok")],
                handler: nil
            )
            return false
        }
    }

    private func showError(_ message: String) {
        setError(message)
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
        SnippetEditorSheet.derivedTitle(from: replacement)
    }
}
