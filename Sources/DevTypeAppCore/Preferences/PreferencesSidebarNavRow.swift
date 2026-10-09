import AppKit
import ExpanderEngine

// MARK: - Sidebar nav row

/// System Settings–style sidebar row: icon + label, rounded selection, hover
/// wash, and a ⌘1…⌘N key equivalent so the window is keyboard-navigable.
final class SidebarNavRow: NSButton {
    let tab: PreferencesTab
    private let symbolName: String
    var isSelectedRow = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(tab: PreferencesTab, index: Int, target: AnyObject?, action: Selector?) {
        self.tab = tab
        self.symbolName = tab.symbol
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = tab.title
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        keyEquivalent = String(index + 1)
        keyEquivalentModifierMask = [.command]
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityRole(NSAccessibility.Role.button)
        setAccessibilityLabel(tab.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        replaceTrackingAreaOverBounds()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        if isSelectedRow {
            DevTypeTheme.accent.withAlphaComponent(hovering ? 0.30 : 0.24).setFill()
            path.fill()
            DevTypeTheme.accent.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            DevTypeTheme.contrastOverlay(0.07).setFill()
            path.fill()
        }

        let tint: NSColor = isSelectedRow ? DevTypeTheme.accentBright : DevTypeTheme.textSecondary
        let icon = DevTypeTheme.tintedSymbol(symbolName, size: 12, weight: .semibold, color: tint)
        let iconY = (bounds.height - (icon?.size.height ?? 0)) / 2
        icon?.draw(
            in: NSRect(x: 10, y: iconY, width: icon?.size.width ?? 0, height: icon?.size.height ?? 0),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )

        let attributes: [NSAttributedString.Key: Any] = [
            .font: DevTypeTheme.font(12.5, isSelectedRow ? .semibold : .medium),
            .foregroundColor: isSelectedRow ? DevTypeTheme.textPrimary : DevTypeTheme.textSecondary
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: 34, y: (bounds.height - textSize.height) / 2),
            withAttributes: attributes
        )
    }
}
