import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

// MARK: - Composer pill

/// Toolbar pill for the replacement composer — icon + label + an optional
/// shortcut hint baked into the same capsule. Replaces the 18pt ghost buttons
/// that used to hide in the caption row: bigger target, visible shortcut, and
/// a hover wash, sitting where every chat/post composer has trained users to
/// look for attachments and formatting.
final class ComposerPillButton: NSButton {
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
        replaceTrackingAreaOverBounds()
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
