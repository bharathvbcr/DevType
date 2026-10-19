import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

// MARK: - Expansion stage

/// Live simulation strip: [:trigger]▎ → expansion preview. The trigger chip and
/// caret react to the trigger field; the preview renders macros in real time.
final class ExpansionStageView: NSView {
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
