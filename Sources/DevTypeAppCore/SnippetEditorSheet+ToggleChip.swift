import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

// MARK: - Toggle chip

/// Capsule toggle used for snippet behavior flags — crimson when on, ghost when off.
///
/// §3 / §4: the four chips previously carried no explanation anywhere in the UI
/// and no accessibility at all. Each now has a tooltip, an AX help string, the
/// `.checkBox` role, and an AX value reflecting on/off — so state is not carried
/// by fill colour alone.
final class ToggleChip: NSButton {
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
        replaceTrackingAreaOverBounds()
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
