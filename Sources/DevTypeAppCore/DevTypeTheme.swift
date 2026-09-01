import AppKit
import DevTypeSafety

// MARK: - Crimson Glass Design System
//
// DevType's visual language: deep crimson accents floating on warm, near-black
// glass. On macOS 26+ surfaces use NSGlassEffectView (Liquid Glass); older
// systems fall back to NSVisualEffectView / solid tinted cards.

/// §5.3: appearance test used by every dynamic colour below.
extension NSAppearance {
    /// True for Dark Aqua and its high-contrast variant.
    var dtIsDark: Bool {
        let darkNames: [NSAppearance.Name] = [
            NSAppearance.Name.darkAqua,
            NSAppearance.Name.accessibilityHighContrastDarkAqua
        ]
        guard let match = bestMatch(from: [
            NSAppearance.Name.aqua,
            NSAppearance.Name.darkAqua,
            NSAppearance.Name.accessibilityHighContrastAqua,
            NSAppearance.Name.accessibilityHighContrastDarkAqua
        ]) else { return false }
        return darkNames.contains(match)
    }
}

enum DevTypeTheme {
    // MARK: Palette — §5.3: dynamic, resolves per appearance
    //
    // These used to be fixed `calibratedRed:` literals, and `styleWindow` /
    // `styleFloatingPanel` forced `NSAppearance(named: .darkAqua)` on every
    // window — so a Light Mode user got a black window and Increase Contrast did
    // nothing. Each colour is now an `NSColor(name:dynamicProvider:)` that picks
    // a light or dark variant from the appearance in force.
    //
    // Caveat worth knowing at call sites: `.cgColor` on a dynamic colour resolves
    // against `NSAppearance.current` at *access* time, so a layer that caches a
    // CGColor freezes at the appearance it was built under. Views that need to
    // track live should draw with NSColor, or rebuild on
    // `viewDidChangeEffectiveAppearance`.

    /// Builds a two-variant dynamic colour.
    static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("devtype." + name)) { appearance in
            appearance.dtIsDark ? dark : light
        }
    }

    /// White-on-dark / black-on-light overlay at a given alpha.
    /// Replaces the many hardcoded `NSColor.white.withAlphaComponent(…)` fills
    /// that vanished entirely under a light appearance.
    static func contrastOverlay(_ alpha: CGFloat) -> NSColor {
        dynamic(
            "overlay\(Int(alpha * 1000))",
            light: NSColor(calibratedWhite: 0, alpha: alpha),
            dark: NSColor(calibratedWhite: 1, alpha: alpha)
        )
    }

    static let accent = dynamic(
        "accent",
        light: NSColor(calibratedRed: 0.73, green: 0.11, blue: 0.11, alpha: 1.0), // #BA1C1C — AA on white
        dark: NSColor(calibratedRed: 0.86, green: 0.15, blue: 0.15, alpha: 1.0)   // #DC2626
    )
    static let accentBright = dynamic(
        "accentBright",
        light: NSColor(calibratedRed: 0.80, green: 0.13, blue: 0.11, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.95, green: 0.29, blue: 0.24, alpha: 1.0)   // #F24A3D
    )
    static let accentDeep = dynamic(
        "accentDeep",
        light: NSColor(calibratedRed: 0.40, green: 0.05, blue: 0.05, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.48, green: 0.07, blue: 0.07, alpha: 1.0)   // #7A1212
    )
    static let accentMid = dynamic(
        "accentMid",
        light: NSColor(calibratedRed: 0.58, green: 0.09, blue: 0.09, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.68, green: 0.11, blue: 0.10, alpha: 1.0)   // #AD1C1A
    )

    static let windowBackground = dynamic(
        "windowBackground",
        light: NSColor(calibratedRed: 0.968, green: 0.960, blue: 0.956, alpha: 1.0), // #F7F5F4
        dark: NSColor(calibratedRed: 0.055, green: 0.026, blue: 0.022, alpha: 1.0)   // #0E0706
    )
    static let cardBackground = dynamic(
        "cardBackground",
        light: NSColor(calibratedWhite: 0, alpha: 0.045),
        dark: NSColor(calibratedWhite: 1, alpha: 0.055)
    )
    static let cardBackgroundSolid = dynamic(
        "cardBackgroundSolid",
        light: NSColor(calibratedRed: 1.0, green: 0.995, blue: 0.99, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.125, green: 0.067, blue: 0.055, alpha: 1.0)   // #20110E
    )
    /// §5.2: Increase Contrast strengthens the rule instead of ignoring the setting.
    static var hairline: NSColor {
        DevTypeAccessibility.increaseContrast
            ? contrastOverlay(0.34)
            : contrastOverlay(0.10)
    }

    // §5.3: `textTertiary` was `white @ 0.40` over `#0E0706` ≈ 3:1 — below WCAG AA
    // 4.5:1 at the 10–11pt sizes it is used at (search rows, footer hints, group
    // counts). Raised to ~7:1 in both appearances.
    static let textPrimary = dynamic(
        "textPrimary",
        light: NSColor(calibratedWhite: 0, alpha: 0.92),
        dark: NSColor(calibratedWhite: 1, alpha: 0.96)
    )
    static let textSecondary = dynamic(
        "textSecondary",
        light: NSColor(calibratedWhite: 0, alpha: 0.70),
        dark: NSColor(calibratedWhite: 1, alpha: 0.74)
    )
    static let textTertiary = dynamic(
        "textTertiary",
        light: NSColor(calibratedWhite: 0, alpha: 0.62),
        dark: NSColor(calibratedWhite: 1, alpha: 0.60)
    )

    static let statusGreen = dynamic(
        "statusGreen",
        light: NSColor(calibratedRed: 0.09, green: 0.55, blue: 0.24, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.35, alpha: 1.0)   // #30D159
    )
    static let statusOrange = dynamic(
        "statusOrange",
        light: NSColor(calibratedRed: 0.68, green: 0.40, blue: 0.02, alpha: 1.0),
        dark: NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.10, alpha: 1.0)
    )
    static let statusGray = dynamic(
        "statusGray",
        light: NSColor(calibratedWhite: 0.42, alpha: 1.0),
        dark: NSColor(calibratedWhite: 0.62, alpha: 1.0)
    )
    /// Blue used for the Secure Input state (was inlined in AppDelegate).
    static let statusBlue = dynamic(
        "statusBlue",
        light: NSColor(calibratedRed: 0.06, green: 0.38, blue: 0.80, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 1.0)
    )
    static let statusPurple = dynamic(
        "statusPurple",
        light: NSColor(calibratedRed: 0.55, green: 0.20, blue: 0.85, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.95, alpha: 1.0)
    )

    // MARK: Legacy aliases (kept so older call sites compile)

    static let redPrimary   = accent
    static let redBright    = accentBright
    static let redDark      = accentDeep
    static let redSubtle    = accent.withAlphaComponent(0.16)
    static let redBorder    = accent.withAlphaComponent(0.38)
    static let redGlow      = accent.withAlphaComponent(0.25)
    static let backgroundDark = windowBackground
    static let cardDark     = cardBackgroundSolid
    static let cardBorder   = hairline
    static let textBright   = textPrimary
    static let textMuted    = textSecondary
    static let greenStatus  = statusGreen

    // MARK: Radii

    enum Radius {
        static let panel: CGFloat = 22
        static let card: CGFloat = 14
        static let control: CGFloat = 9
    }

    // MARK: Group tag colors

    /// Preset swatches offered in the group editor (hex strings).
    static let groupColorPalette: [String] = [
        "#DC2626", "#F97316", "#FACC15", "#30D159",
        "#0A84FF", "#BF5AF2", "#FF375F", "#8E8E93"
    ]

    /// Parses "#RRGGBB" (or "RRGGBB") into an NSColor; nil when invalid/empty.
    static func colorFromHex(_ hex: String) -> NSColor? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Hex string for a palette color (round-trips `colorFromHex`).
    static func hex(from color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "" }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }

    /// Sidebar tint for a group: custom tag color, or accent when unset/disabled handled by caller.
    static func tint(forGroupColorHex colorHex: String) -> NSColor {
        colorFromHex(colorHex) ?? accent
    }

    // MARK: Typography

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: SF Symbols

    /// §5.1: every symbol carries a real `accessibilityDescription`.
    ///
    /// This used to pass `accessibilityDescription: nil` for *every* symbol in the
    /// app. Callers may override with `description:`; otherwise
    /// `DevTypeAccessibility.symbolDescription(_:)` supplies a curated localized
    /// label, falling back to a humanized form of the SF Symbol name.
    static func symbol(
        _ name: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .medium,
        color: NSColor? = nil,
        description: String? = nil
    ) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        if let color {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        let label = description ?? DevTypeAccessibility.symbolDescription(name)
        return NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
    }

    /// Template symbol suitable for NSMenuItem images (adopts menu text color).
    /// §5.1: labelled — a menu item image with no description is announced as
    /// an unlabeled image next to the item title.
    static func menuIcon(_ name: String, description: String? = nil) -> NSImage? {
        let label = description ?? DevTypeAccessibility.symbolDescription(name)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// Symbol with the tint **baked into the bitmap** (non-template).
    ///
    /// Palette-configured symbol images can be re-rendered through the
    /// vibrancy/template path when placed in image views inside glass
    /// (`NSVisualEffectView` / `NSGlassEffectView`) surfaces, which flips
    /// their colors — the "inverted icon" bug. Compositing the tint with
    /// `.sourceAtop` produces a final bitmap nothing downstream can reinterpret.
    static func tintedSymbol(
        _ name: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .medium,
        color: NSColor,
        description: String? = nil
    ) -> NSImage? {
        // §5.1: real accessibility description instead of `nil`.
        let label = description ?? DevTypeAccessibility.symbolDescription(name)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return nil }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = label
        return image
    }


    // MARK: Brand imagery

    /// Loads the crisp 3D logo from the Resources bundle.
    static func load3DLogoImage(size: NSSize = NSSize(width: 48, height: 48)) -> NSImage? {
        var foundPath: String?
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "png") {
            foundPath = path
        } else if let path = Bundle.main.path(forResource: "AppIcon", ofType: "jpg") {
            foundPath = path
        } else if let path = Bundle.main.path(forResource: "StatusIcon", ofType: "png") {
            foundPath = path
        } else {
            let directPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Resources/AppIcon.png")
            if FileManager.default.fileExists(atPath: directPath) {
                foundPath = directPath
            }
        }

        if let path = foundPath, let image = NSImage(contentsOfFile: path) {
            image.size = size
            return image
        }
        return nil
    }

    // MARK: Menu-bar mark

    /// Canonical menu-bar icon metrics. The badge is a fixed size and the canvas
    /// grows to the right *only* to make room for it, so the monogram occupies the
    /// same rect either way and the icon never shifts for a mere change of glyph.
    private enum StatusMark {
        static let height: CGFloat = 18
        /// Square the monogram is fitted into; the `D` is 0.9 as wide as it is tall.
        static let markRect = NSRect(x: 0, y: 1.5, width: 15, height: 15)
        static let badgeDiameter: CGFloat = 9
        /// Transparent gap punched between mark and badge so the badge reads as a
        /// badge over any menu-bar backdrop, not just a dark one.
        static let badgeGap: CGFloat = 1.1
        static let badgedWidth: CGFloat = 22
        static var badgeRect: NSRect {
            NSRect(
                x: badgedWidth - badgeDiameter,
                y: 0,
                width: badgeDiameter,
                height: badgeDiameter
            )
        }
        static func canvas(badged: Bool) -> NSSize {
            NSSize(width: badged ? badgedWidth : markRect.width, height: height)
        }
    }

    /// DevType's monogram as vector geometry: a `D` whose counter holds the code
    /// chevron, laid out on a 90×100 grid (y-up) and fitted into `rect`.
    ///
    /// The menu-bar icon used to be `Resources/StatusIcon.png` — a 36px raster of
    /// the glossy 3D app icon — scaled into an 18pt slot. That is exactly enough
    /// pixels for a 2× display and none above it, and the artwork is a near-black
    /// rounded square with bevels and glow, so it read as a smudge on a dark menu
    /// bar, a sticker on a light one, and mush at any size. Vector geometry filled
    /// with a colour resolved from the drawing appearance is crisp at every scale
    /// factor and flips with the menu bar.
    private static func brandMarkPath(in rect: NSRect) -> NSBezierPath {
        let scale = min(rect.width / 90, rect.height / 100)
        var transform = AffineTransform(
            translationByX: rect.midX - 45 * scale,
            byY: rect.midY - 50 * scale
        )
        transform.scale(scale)

        func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

        // Outer contour: flat left stem with softened corners, round right bowl.
        let path = NSBezierPath()
        path.move(to: at(6, 100))
        path.line(to: at(38, 100))
        path.curve(to: at(90, 50), controlPoint1: at(66, 100), controlPoint2: at(90, 78))
        path.curve(to: at(38, 0), controlPoint1: at(90, 22), controlPoint2: at(66, 0))
        path.line(to: at(6, 0))
        path.curve(to: at(0, 6), controlPoint1: at(2.7, 0), controlPoint2: at(0, 2.7))
        path.line(to: at(0, 94))
        path.curve(to: at(6, 100), controlPoint1: at(0, 97.3), controlPoint2: at(2.7, 100))
        path.close()

        // Counter: the same contour inset by the stroke weight, cut out even-odd.
        let weight: CGFloat = 16
        path.move(to: at(weight, 100 - weight))
        path.line(to: at(38, 100 - weight))
        path.curve(
            to: at(90 - weight, 50),
            controlPoint1: at(62, 100 - weight),
            controlPoint2: at(90 - weight, 76)
        )
        path.curve(
            to: at(38, weight),
            controlPoint1: at(90 - weight, 24),
            controlPoint2: at(62, weight)
        )
        path.line(to: at(weight, weight))
        path.close()

        // The chevron inside the counter — the app icon's `</>` reduced to the one
        // stroke that still reads at 18pt. Six points: outer V, then inner V back.
        path.move(to: at(29, 75))
        path.line(to: at(65, 50))
        path.line(to: at(29, 25))
        path.line(to: at(29, 38.4))
        path.line(to: at(45.7, 50))
        path.line(to: at(29, 61.6))
        path.close()

        path.windingRule = .evenOdd
        path.transform(using: transform)
        return path
    }

    /// Draws the engine-state badge: a tinted disc carrying a vector glyph.
    ///
    /// §5.2: colour is not the only channel. The glyph used to be a text
    /// character (`‖`, `◍`, `✕`) set at 8pt inside a 10pt circle, where `◍`
    /// collapsed into a blob and every glyph was drawn in fixed near-black
    /// regardless of the disc behind it. These are drawn as geometry instead, in
    /// whichever of black/white contrasts with the resolved tint, so the state
    /// survives greyscale, colour-blind vision, and Differentiate Without Color.
    private static func drawStatusBadge(_ kind: EngineDisplayStatusKind, tint: NSColor, in rect: NSRect) {
        tint.setFill()
        NSBezierPath(ovalIn: rect).fill()

        let resolved = tint.usingColorSpace(.sRGB)
        let luminance = resolved.map {
            0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent
        } ?? 0.5
        let ink: NSColor = luminance > 0.5 ? .black : .white
        ink.setFill()
        ink.setStroke()

        // Glyphs are specified on a 10-unit grid so they scale with the badge.
        let unit = rect.width / 10
        let cx = rect.midX, cy = rect.midY
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

        switch kind {
        case .active:
            // A bare disc is the "●" of the quiet state — nothing to stamp.
            break
        case .paused:
            let barWidth = 1.4 * unit, barHeight = 4.6 * unit, gap = 1.3 * unit
            NSBezierPath(rect: NSRect(
                x: cx - gap / 2 - barWidth, y: cy - barHeight / 2,
                width: barWidth, height: barHeight
            )).fill()
            NSBezierPath(rect: NSRect(
                x: cx + gap / 2, y: cy - barHeight / 2,
                width: barWidth, height: barHeight
            )).fill()
        case .secure:
            let ring = NSBezierPath(ovalIn: NSRect(
                x: cx - 2.6 * unit, y: cy - 2.6 * unit,
                width: 5.2 * unit, height: 5.2 * unit
            ))
            ring.lineWidth = 1.5 * unit
            ring.stroke()
        case .needsPermissions:
            let barWidth = 1.6 * unit
            NSBezierPath(rect: NSRect(
                x: cx - barWidth / 2, y: cy - 0.4 * unit,
                width: barWidth, height: 3.2 * unit
            )).fill()
            NSBezierPath(ovalIn: NSRect(
                x: cx - barWidth / 2, y: cy - 2.9 * unit,
                width: barWidth, height: barWidth
            )).fill()
        case .tapFailed:
            let arm = 1.9 * unit
            let cross = NSBezierPath()
            cross.move(to: point(cx - arm, cy - arm))
            cross.line(to: point(cx + arm, cy + arm))
            cross.move(to: point(cx - arm, cy + arm))
            cross.line(to: point(cx + arm, cy - arm))
            cross.lineWidth = 1.5 * unit
            cross.lineCapStyle = .round
            cross.stroke()
        }
    }

    /// Menu-bar icon: the monogram with an engine-state badge in the corner.
    ///
    /// The image is not a template — the badge carries colour that templating
    /// would flatten — so the monogram is filled with `NSColor.labelColor`
    /// resolved inside the drawing handler. AppKit re-runs that handler under the
    /// destination's appearance, so the mark tracks a light or dark menu bar the
    /// way a template image would. `cacheMode = .never` keeps a cached rendition
    /// from freezing the icon at the appearance it was first drawn under.
    ///
    /// Appearance is the only thing AppKit resolves for us. A status button does
    /// *not* flip its effective appearance while its menu is open — measured, not
    /// assumed: `effectiveAppearance` stays `NSAppearanceNameAqua` with
    /// `isHighlighted == true`. Only template images get the system's inversion,
    /// which is why the selection fill is dark under a light menu bar. So the
    /// caller tells us when the menu is open and the mark switches to
    /// `selectedMenuItemTextColor` (white in both appearances), the same ink
    /// AppKit draws over a selected menu background. The old raster icon had no
    /// such handling and sank into the selection.
    ///
    /// §5.2: `badge` carries the glyph *and* its tint together — a badge is never
    /// one without the other — and `accessibilityLabel` carries the state for
    /// VoiceOver, so colour is one of three channels rather than the only one.
    ///
    /// A `nil` badge is the bare monogram, which is how the plain working state is
    /// drawn: an indicator that is present whenever nothing is wrong says nothing,
    /// and it competed with the states that do need attention. Absence is still a
    /// channel — every state that is not "plainly working" badges loudly — and the
    /// text title, tooltip and AX value still name the state for anyone who cannot
    /// or does not want to read it off a shape.
    static func statusItemImage(
        badge: (kind: EngineDisplayStatusKind, tint: NSColor)?,
        highlighted: Bool = false,
        accessibilityLabel: String? = nil
    ) -> NSImage {
        let image = NSImage(size: StatusMark.canvas(badged: badge != nil), flipped: false) { rect in
            let ink = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor

            guard let badge else {
                ink.setFill()
                brandMarkPath(in: StatusMark.markRect).fill()
                return true
            }

            let badgeRect = StatusMark.badgeRect

            // Punch the badge's clearance out of the mark rather than laying an
            // opaque ring over it: a ring has to pick a colour, and the old
            // black-at-55% ring was invisible on a dark menu bar.
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: rect.insetBy(dx: -4, dy: -4))
            clip.append(NSBezierPath(
                ovalIn: badgeRect.insetBy(dx: -StatusMark.badgeGap, dy: -StatusMark.badgeGap)
            ))
            clip.windingRule = .evenOdd
            clip.addClip()
            ink.setFill()
            brandMarkPath(in: StatusMark.markRect).fill()
            NSGraphicsContext.restoreGraphicsState()

            drawStatusBadge(badge.kind, tint: badge.tint, in: badgeRect)
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        if let accessibilityLabel { image.accessibilityDescription = accessibilityLabel }
        return image
    }

    // MARK: Window chrome

    /// Unified window chrome: transparent title bar, full-size content, themed
    /// background. Content should reserve ~34pt at the top for the traffic-light
    /// strip.
    ///
    /// §5.3: no longer forces `NSAppearance(named: .darkAqua)`. The window follows
    /// the system appearance and the palette above resolves per appearance, so a
    /// Light Mode user gets a light window instead of a black one.
    static func styleWindow(_ window: NSWindow, title: String) {
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = windowBackground
        window.appearance = nil
        window.isMovableByWindowBackground = true
        window.toolbar = nil
        // §5.1: the window is the AX container for its content; give it a real title
        // even though `titleVisibility` hides the chrome text.
        window.setAccessibilityTitle(title)
    }

    /// Chrome for floating borderless panels (search / fill-in): transparent,
    /// shadowed, rounded by the glass content view.
    /// §5.3: appearance is inherited, not forced to dark.
    static func styleFloatingPanel(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = nil
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
    }

    // MARK: Shared building blocks

    static func makeLabel(
        _ text: String,
        font: NSFont,
        color: NSColor,
        wrapping: Bool = false
    ) -> NSTextField {
        let label = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        return label
    }

    static func makeHairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = hairline.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// Brand lockup: rounded logo with crimson ring + title/subtitle stack.
    static func makeBrandHeader(title: String, subtitle: String, logoSize: CGFloat = 40) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 12
        container.translatesAutoresizingMaskIntoConstraints = false

        let logoImageView = NSImageView()
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.imageScaling = .scaleProportionallyUpOrDown
        if let logo = load3DLogoImage(size: NSSize(width: logoSize, height: logoSize)) {
            logoImageView.image = logo
        }
        logoImageView.wantsLayer = true
        logoImageView.layer?.cornerRadius = logoSize * 0.24
        logoImageView.layer?.masksToBounds = true
        logoImageView.layer?.borderColor = accent.withAlphaComponent(0.40).cgColor
        logoImageView.layer?.borderWidth = 1

        NSLayoutConstraint.activate([
            logoImageView.widthAnchor.constraint(equalToConstant: logoSize),
            logoImageView.heightAnchor.constraint(equalToConstant: logoSize)
        ])

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let titleLabel = makeLabel(title, font: font(16, .bold), color: textPrimary)
        let subtitleLabel = makeLabel(subtitle, font: font(11, .medium), color: accentBright)
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        container.addArrangedSubview(logoImageView)
        container.addArrangedSubview(textStack)
        return container
    }
}

// MARK: - Glass container (Liquid Glass on macOS 26+, material fallback below)

/// A rounded glass surface. Add content to `contentView`.
final class GlassContainerView: NSView {
    let contentView = NSView()

    init(
        cornerRadius: CGFloat = DevTypeTheme.Radius.panel,
        tint: NSColor = DevTypeTheme.accent.withAlphaComponent(0.10),
        material: NSVisualEffectView.Material = .popover,
        blending: NSVisualEffectView.BlendingMode = .behindWindow,
        showsBorder: Bool = true
    ) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true

        // §5.2: Reduce Transparency fallback. The whole theme is glass
        // (NSGlassEffectView / NSVisualEffectView) with no opaque path — a user
        // who turns the setting on previously got the blur anyway.
        if DevTypeAccessibility.reduceTransparency {
            layer?.backgroundColor = DevTypeTheme.cardBackgroundSolid.cgColor
            contentView.frame = bounds
            contentView.autoresizingMask = [.width, .height]
            addSubview(contentView)
            if showsBorder {
                layer?.borderWidth = 1
                layer?.borderColor = DevTypeTheme.accent.withAlphaComponent(0.45).cgColor
            }
            return
        }

        if #available(macOS 26.0, *), let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassClass.init(frame: bounds)
            // Each write goes through the exception-catching trampoline: the keys are
            // private API with no stability contract, and on a future macOS that
            // renames one, plain KVC raises an undefined-key NSException — which from
            // a Swift frame aborts the process. A rejected key falls back to the
            // material path below instead.
            //
            // All three writes are attempted before anything touches the view
            // hierarchy, so a failure can never leave a half-configured glass
            // surface on screen.
            let configured =
                DTSetValueForKeyCatching(glass, cornerRadius, "cornerRadius")
                && DTSetValueForKeyCatching(glass, tint, "tintColor")
                && DTSetValueForKeyCatching(glass, contentView, "contentView")
            if configured {
                glass.autoresizingMask = [.width, .height]
                addSubview(glass)
                contentView.frame = bounds
                contentView.autoresizingMask = [.width, .height]
                return
            }
        }

        let effect = NSVisualEffectView(frame: bounds)
        effect.material = material
        effect.blendingMode = blending
        effect.state = .active
        effect.wantsLayer = true
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        let tintView = NSView(frame: bounds)
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = tint.cgColor
        tintView.autoresizingMask = [.width, .height]
        addSubview(tintView)

        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)

        if showsBorder {
            layer?.borderWidth = 1
            layer?.borderColor = DevTypeTheme.accent.withAlphaComponent(0.26).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Rounded card used inside windows: dark frosted material + red tint + hairline.
/// Fully constraint-driven so the card stretches correctly in Auto Layout chains.
final class GlassCardView: NSView {
    let contentView = NSView()

    init(
        cornerRadius: CGFloat = DevTypeTheme.Radius.card,
        tint: NSColor = DevTypeTheme.accent.withAlphaComponent(0.07)
    ) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = DevTypeTheme.cardBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = DevTypeTheme.hairline.cgColor

        // §5.2: Reduce Transparency → solid card, no vibrancy layer at all.
        if DevTypeAccessibility.reduceTransparency {
            layer?.backgroundColor = DevTypeTheme.cardBackgroundSolid.cgColor
            contentView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentView.topAnchor.constraint(equalTo: topAnchor),
                contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            return
        }

        let effect = NSVisualEffectView()
        effect.material = .contentBackground
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let tintView = NSView()
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = tint.cgColor
        tintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        for view in [effect, tintView, contentView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Capsule button

/// Fully rounded push button drawn in the Crimson Glass language.
final class CapsuleButton: NSButton {
    enum Style {
        case primary      // crimson gradient, white text
        case secondary    // frosted outline
        case destructive  // crimson tinted outline
    }

    var buttonStyle: Style = .secondary { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var symbolImage: NSImage?

    override var title: String {
        didSet {
            // §5.1: keep the AX label in sync with the drawn title.
            setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    var style: Style {
        get { buttonStyle }
        set { buttonStyle = newValue; needsDisplay = true }
    }

    init(
        title: String,
        symbol: String? = nil,
        style: Style = .secondary,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.buttonStyle = style
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        font = DevTypeTheme.font(13, style == .primary ? .semibold : .medium)
        translatesAutoresizingMaskIntoConstraints = false
        if let symbol {
            symbolImage = DevTypeTheme.tintedSymbol(
                symbol,
                size: 12,
                weight: .semibold,
                color: style == .primary ? .white : (style == .destructive ? DevTypeTheme.accentBright : DevTypeTheme.textPrimary)
            )
        }
        // §5.1: `CapsuleButton` draws its own title, so AppKit has no text to
        // report. Without an explicit label VoiceOver announces "button" only.
        setAccessibilityRole(NSAccessibility.Role.button)
        setAccessibilityLabel(title)

        setContentHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbol(_ name: String?) {
        symbolImage = name.flatMap {
            DevTypeTheme.tintedSymbol(
                $0,
                size: 12,
                weight: .semibold,
                color: buttonStyle == .primary ? .white : (buttonStyle == .destructive ? DevTypeTheme.accentBright : DevTypeTheme.textPrimary)
            )
        }

        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let textSize = (title as NSString).size(withAttributes: [
            .font: font ?? DevTypeTheme.font(13, .medium)
        ])
        var width = textSize.width + 30
        if symbolImage != nil { width += 18 }
        return NSSize(width: max(44, ceil(width)), height: 26)
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
        let highlighted = cell?.isHighlighted == true && isEnabled

        NSGraphicsContext.saveGraphicsState()
        switch buttonStyle {
        case .primary:
            if isEnabled {
                let shadow = NSShadow()
                shadow.shadowColor = DevTypeTheme.accent.withAlphaComponent(0.45)
                shadow.shadowBlurRadius = 7
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
                let gradient = NSGradient(colors: [DevTypeTheme.accentBright, DevTypeTheme.accentDeep])
                gradient?.draw(in: path, angle: 90)
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                DevTypeTheme.accentBright.withAlphaComponent(0.55).setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                DevTypeTheme.accent.withAlphaComponent(0.30).setFill()
                path.fill()
            }
        case .secondary:
            // §5.3: white overlays were invisible under a light appearance.
            DevTypeTheme.contrastOverlay(hovering ? 0.11 : 0.065).setFill()
            path.fill()
            DevTypeTheme.contrastOverlay(hovering ? 0.28 : 0.20).setStroke()
            path.lineWidth = 1
            path.stroke()
        case .destructive:
            DevTypeTheme.accent.withAlphaComponent(hovering ? 0.16 : 0.09).setFill()
            path.fill()
            DevTypeTheme.accent.withAlphaComponent(hovering ? 0.55 : 0.38).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        if highlighted {
            NSColor.black.withAlphaComponent(0.18).setFill()
            path.fill()
        }

        // Keyboard focus ring.
        if window?.firstResponder === self {
            DevTypeTheme.accent.withAlphaComponent(0.65).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: radius - 1, yRadius: radius - 1)
            ring.lineWidth = 2
            ring.stroke()
        }

        // Title + optional symbol, centered as a group.
        let alpha: CGFloat = isEnabled ? 1.0 : 0.45
        let textColor: NSColor
        switch buttonStyle {
        case .primary: textColor = .white
        case .secondary: textColor = DevTypeTheme.textPrimary
        case .destructive: textColor = DevTypeTheme.accentBright
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? DevTypeTheme.font(13, .medium),
            .foregroundColor: textColor.withAlphaComponent(alpha)
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let imageSize = symbolImage?.size ?? .zero
        let spacing: CGFloat = symbolImage == nil ? 0 : 6
        let combined = textSize.width + (symbolImage == nil ? 0 : imageSize.width + spacing)
        var x = (bounds.width - combined) / 2
        let y = (bounds.height - textSize.height) / 2

        if let symbolImage {
            let imageRect = NSRect(
                x: x,
                y: (bounds.height - imageSize.height) / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            // `NSButton.isFlipped` is true, so this draws into a flipped context. The short
            // `draw(in:from:operation:fraction:)` form ignores that and renders the glyph
            // upside down (trash lid at the bottom, import/export arrows reversed) — the
            // `respectFlipped:` overload is the only one that compensates.
            symbolImage.draw(
                in: imageRect,
                from: .zero,
                operation: .sourceOver,
                fraction: alpha,
                respectFlipped: true,
                hints: nil
            )
            x += imageSize.width + spacing
        }
        (title as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }
}

// MARK: - Icon-only capsule

/// Circular, icon-only sibling of `CapsuleButton.secondary`: same frosted fill,
/// hover, highlight, and focus ring, minus the title. For header affordances that
/// have no horizontal room for a label — the glyph plus a tooltip carries them.
final class GlassIconButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private var symbolImage: NSImage?
    private let diameter: CGFloat

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    init(
        symbol: String,
        accessibilityLabel: String,
        diameter: CGFloat = 26,
        target: AnyObject?,
        action: Selector?
    ) {
        self.diameter = diameter
        super.init(frame: .zero)
        title = ""
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        symbolImage = DevTypeTheme.tintedSymbol(
            symbol,
            size: diameter * 0.5,
            weight: .semibold,
            color: DevTypeTheme.textPrimary
        )
        // §5.1: nothing here is a title AppKit can report, so the label is explicit.
        setAccessibilityRole(NSAccessibility.Role.button)
        setAccessibilityLabel(accessibilityLabel)

        setContentHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: diameter, height: diameter)
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

        // §5.3: contrast overlays rather than white ones, so the frosted fill
        // survives a light appearance.
        DevTypeTheme.contrastOverlay(hovering ? 0.11 : 0.065).setFill()
        path.fill()
        DevTypeTheme.contrastOverlay(hovering ? 0.28 : 0.20).setStroke()
        path.lineWidth = 1
        path.stroke()

        if cell?.isHighlighted == true && isEnabled {
            NSColor.black.withAlphaComponent(0.18).setFill()
            path.fill()
        }

        if window?.firstResponder === self {
            DevTypeTheme.accent.withAlphaComponent(0.65).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: radius - 1, yRadius: radius - 1)
            ring.lineWidth = 2
            ring.stroke()
        }

        guard let symbolImage else { return }
        let imageSize = symbolImage.size
        let imageRect = NSRect(
            x: (bounds.width - imageSize.width) / 2,
            y: (bounds.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        // `NSButton.isFlipped` is true — only the `respectFlipped:` overload
        // compensates, otherwise the glyph renders upside down.
        symbolImage.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: isEnabled ? 1.0 : 0.45,
            respectFlipped: true,
            hints: nil
        )
    }
}

// MARK: - Split capsule (primary + disclosure)

/// Primary capsule with a trailing chevron segment. Main click runs `primaryAction`;
/// hovering/clicking the chevron is separate — used for “Add from Template”.
final class SplitCapsuleButton: NSView {
    private enum Zone {
        case none
        case primary
        case disclosure
    }

    private let primaryTitle: String
    private let disclosureTooltip: String
    private let symbolImage: NSImage?
    private weak var target: AnyObject?
    private let primaryAction: Selector
    private let disclosureAction: Selector

    private var hoverZone: Zone = .none {
        didSet {
            needsDisplay = true
            toolTip = hoverZone == .disclosure ? disclosureTooltip : nil
        }
    }
    private var pressZone: Zone = .none { didSet { needsDisplay = true } }

    private let disclosureWidth: CGFloat = 22

    init(
        title: String,
        symbol: String? = "plus",
        disclosureTooltip: String,
        target: AnyObject?,
        primaryAction: Selector,
        disclosureAction: Selector
    ) {
        self.primaryTitle = title
        self.disclosureTooltip = disclosureTooltip
        self.target = target
        self.primaryAction = primaryAction
        self.disclosureAction = disclosureAction
        if let symbol {
            symbolImage = DevTypeTheme.tintedSymbol(symbol, size: 12, weight: .semibold, color: .white)
        } else {
            symbolImage = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        setContentHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(disclosureTooltip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let textSize = (primaryTitle as NSString).size(withAttributes: [
            .font: DevTypeTheme.font(13, .semibold)
        ])
        var width = textSize.width + 30 + disclosureWidth
        if symbolImage != nil { width += 18 }
        return NSSize(width: max(66, ceil(width)), height: 26)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverZone = zone(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hoverZone = zone(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoverZone = .none
        pressZone = .none
    }

    override func mouseDown(with event: NSEvent) {
        pressZone = zone(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let zone = zone(at: convert(event.locationInWindow, from: nil))
        let pressed = pressZone
        pressZone = .none
        guard zone == pressed else { return }
        fire(zone)
    }

    override func accessibilityPerformPress() -> Bool {
        fire(.primary)
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [
            NSAccessibilityCustomAction(name: disclosureTooltip) { [weak self] in
                self?.fire(.disclosure)
                return true
            }
        ]
    }

    private func fire(_ zone: Zone) {
        switch zone {
        case .primary:
            _ = target?.perform(primaryAction)
        case .disclosure:
            _ = target?.perform(disclosureAction)
        case .none:
            break
        }
    }

    private func zone(at point: NSPoint) -> Zone {
        guard bounds.contains(point) else { return .none }
        if point.x >= bounds.maxX - disclosureWidth { return .disclosure }
        return .primary
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = DevTypeTheme.accent.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        let gradient = NSGradient(colors: [DevTypeTheme.accentBright, DevTypeTheme.accentDeep])
        gradient?.draw(in: path, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        DevTypeTheme.accentBright.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let splitX = bounds.maxX - disclosureWidth
        if hoverZone == .primary || pressZone == .primary {
            let overlay = NSBezierPath(
                roundedRect: NSRect(x: rect.minX, y: rect.minY, width: max(0, splitX - rect.minX), height: rect.height),
                xRadius: radius,
                yRadius: radius
            )
            NSColor.black.withAlphaComponent(pressZone == .primary ? 0.18 : 0.08).setFill()
            overlay.fill()
        }
        if hoverZone == .disclosure || pressZone == .disclosure {
            let overlay = NSBezierPath(
                roundedRect: NSRect(x: splitX, y: rect.minY, width: rect.maxX - splitX, height: rect.height),
                xRadius: radius,
                yRadius: radius
            )
            NSColor.black.withAlphaComponent(pressZone == .disclosure ? 0.18 : 0.08).setFill()
            overlay.fill()
        }

        DevTypeTheme.accentDeep.withAlphaComponent(0.35).setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: splitX, y: rect.minY + 5))
        divider.line(to: NSPoint(x: splitX, y: rect.maxY - 5))
        divider.lineWidth = 1
        divider.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: DevTypeTheme.font(13, .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (primaryTitle as NSString).size(withAttributes: attributes)
        let imageSize = symbolImage?.size ?? .zero
        let spacing: CGFloat = symbolImage == nil ? 0 : 6
        let combined = textSize.width + (symbolImage == nil ? 0 : imageSize.width + spacing)
        let primaryWidth = bounds.width - disclosureWidth
        var x = (primaryWidth - combined) / 2
        let y = (bounds.height - textSize.height) / 2

        if let symbolImage {
            let imageRect = NSRect(
                x: x,
                y: (bounds.height - imageSize.height) / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            symbolImage.draw(
                in: imageRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            x += imageSize.width + spacing
        }
        (primaryTitle as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)

        if let chevron = DevTypeTheme.tintedSymbol("chevron.down", size: 9, weight: .bold, color: .white) {
            let cx = bounds.maxX - disclosureWidth / 2 - chevron.size.width / 2
            let cy = (bounds.height - chevron.size.height) / 2
            chevron.draw(
                in: NSRect(x: cx, y: cy, width: chevron.size.width, height: chevron.size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
    }
}

// MARK: - Pill badge

/// Small rounded badge: tinted fill + optional status dot + label.
final class PillBadgeView: NSView {
    private let label: NSTextField
    private let dot = NSView()
    private var tint: NSColor
    private let showsDot: Bool

    /// Upper bound on the pill's width. A long trigger keyword truncates inside
    /// the badge instead of shoving the row's title and preview off-screen.
    var maximumWidth: CGFloat? {
        didSet {
            maxWidthConstraint?.isActive = false
            maxWidthConstraint = nil
            guard let maximumWidth else { return }
            // Truncation has to be on, otherwise the capped label just clips.
            label.lineBreakMode = .byTruncatingTail
            let constraint = widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth)
            constraint.isActive = true
            maxWidthConstraint = constraint
        }
    }

    private var maxWidthConstraint: NSLayoutConstraint?

    init(text: String, tint: NSColor, showsDot: Bool = false, font: NSFont? = nil, truncates: Bool = false) {
        self.tint = tint
        self.showsDot = showsDot
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        label.font = font ?? DevTypeTheme.font(10.5, .semibold)
        if truncates { label.lineBreakMode = .byTruncatingTail }
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = tint
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = tint.cgColor
        dot.isHidden = !showsDot
        addSubview(dot)
        addSubview(label)

        // A pill sits next to flexible text in most of its callers. Without these
        // priorities Auto Layout is free to satisfy a `<=` gap by squeezing the
        // badge — the label inside collapses and the pill renders as a bare
        // circle. Resisting compression above the default makes the *neighbour*
        // truncate instead, which is the intended behaviour everywhere.
        label.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh + 1, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        setContentHuggingPriority(.defaultHigh + 1, for: .horizontal)

        if showsDot {
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
                label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5)
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
            ])
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2.5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2.5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
        applyTint()
    }

    /// `NSView` has no intrinsic content size, so the old
    /// `cornerRadius = intrinsicContentSize.height / 2` evaluated to `-0.5`,
    /// which Core Animation clamps to 0 — a square badge. `layout()` corrected it
    /// afterwards, but only when a layout pass actually ran, so a re-`configure`d
    /// table cell whose geometry had not changed kept the squared-off radius.
    /// That is why some trigger pills rendered as pills and others as rectangles.
    private func updateCornerRadius() {
        let height = bounds.height > 0 ? bounds.height : fittingSize.height
        layer?.cornerRadius = max(0, height / 2)
    }

    private func applyTint() {
        updateCornerRadius()
        layer?.backgroundColor = tint.withAlphaComponent(0.15).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = tint.withAlphaComponent(0.40).cgColor
        label.textColor = tint
        dot.layer?.backgroundColor = tint.cgColor
    }

    func update(text: String, tint newTint: NSColor) {
        // Runs AutoLayout via `invalidateIntrinsicContentSize()` / `applyTint()`; off-main
        // this aborts the process inside CoreAutoLayout. Fail here instead, in debug.
        assertMainThread()
        label.stringValue = text
        tint = newTint
        applyTint()
        // §5.1: the badge is a status affordance; expose its text as an AX value.
        setAccessibilityValue(text)
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    /// §4.7: attributed variant so search highlighting can reach the trigger pill.
    /// `applyTint()` writes `label.textColor`, which would rebuild a plain string,
    /// so the attributed value is assigned last.
    func update(attributed: NSAttributedString, tint newTint: NSColor) {
        tint = newTint
        applyTint()
        label.attributedStringValue = attributed
        setAccessibilityValue(attributed.string)
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateCornerRadius()
    }
}

// MARK: - Marquee label

/// Single-line label that scrolls its text right-to-left when the text is wider
/// than the width it was handed, so a long replacement can be read in full
/// without opening the editor.
///
/// Scrolling is opt-in per instance via `isScrolling` rather than automatic: the
/// snippet list turns it on only for the row under the pointer. Fifty rows of
/// simultaneously moving text would be unreadable, and animating every visible
/// cell keeps the compositor busy for no benefit.
///
/// The seamless wrap comes from drawing the string twice — the second copy sits
/// one `gap` past the end of the first, and the track slides by exactly
/// `textWidth + gap` per cycle, which lands the copy precisely where the
/// original started.
final class MarqueeLabel: NSView {
    /// Points travelled per second once the text starts moving.
    private static let speed: CGFloat = 40
    /// Blank run between the end of the text and the start of the repeat.
    private static let gap: CGFloat = 56
    /// Beat at the head of each pass, so the start of the text is readable
    /// before it slides away.
    private static let hold: CFTimeInterval = 0.9
    private static let animationKey = "marquee"

    private let track = NSView()
    private let primary = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private let lineHeight: CGFloat
    /// Distance the currently-installed animation was built for, so `layout()`
    /// can run as often as it likes without restarting (and visibly jumping) it.
    private var animatedDistance: CGFloat = -1

    /// Whether this label *wants* to scroll. It still only moves when the text
    /// actually overflows and the user has not asked for reduced motion.
    var isScrolling = false {
        didSet {
            guard isScrolling != oldValue else { return }
            needsLayout = true
        }
    }

    var stringValue: String {
        get { primary.stringValue }
        set {
            guard newValue != primary.stringValue else { return }
            primary.stringValue = newValue
            secondary.stringValue = newValue
            invalidateIntrinsicContentSize()
            animatedDistance = -1
            needsLayout = true
        }
    }

    var textColor: NSColor? {
        get { primary.textColor }
        set {
            primary.textColor = newValue
            secondary.textColor = newValue
        }
    }

    init(font: NSFont, color: NSColor) {
        lineHeight = ceil(("Xg" as NSString).size(withAttributes: [.font: font]).height)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // Without this the second copy and the overflowing text spill across the
        // trigger pill — AppKit does not clip to bounds on its own.
        layer?.masksToBounds = true

        track.wantsLayer = true
        for field in [primary, secondary] {
            field.font = font
            field.textColor = color
            field.lineBreakMode = .byTruncatingTail
            field.isSelectable = false
            track.addSubview(field)
        }
        secondary.isHidden = true
        addSubview(track)

        // In a row this is the element that gives way: it clips rather than
        // pushing the trigger pill or the title around.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Honour the system Reduce Motion setting — the text still truncates and the
    /// full string is available from the tooltip, so nothing is lost by holding
    /// it still.
    private static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var textWidth: CGFloat {
        guard let font = primary.font else { return 0 }
        return (primary.stringValue as NSString).size(withAttributes: [.font: font]).width
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(textWidth), height: lineHeight)
    }

    override func layout() {
        super.layout()
        let full = ceil(textWidth)
        let height = bounds.height
        let overflows = full > bounds.width + 0.5
        let moving = isScrolling && overflows && !Self.prefersReducedMotion

        // A truncating tail would put an ellipsis in the middle of the scroll.
        primary.lineBreakMode = moving ? .byClipping : .byTruncatingTail
        track.frame = NSRect(
            x: 0,
            y: 0,
            width: moving ? full * 2 + Self.gap : bounds.width,
            height: height
        )
        primary.frame = NSRect(x: 0, y: 0, width: moving ? full : bounds.width, height: height)
        secondary.frame = NSRect(x: full + Self.gap, y: 0, width: full, height: height)
        secondary.isHidden = !moving

        syncAnimation(moving: moving, distance: full + Self.gap)
    }

    /// `transform.translation.x` rather than `position.x`: translation is
    /// relative, so re-running `layout()` (which rewrites `track.frame`, and with
    /// it the layer's position) cannot leave the animation's endpoints stale.
    private func syncAnimation(moving: Bool, distance: CGFloat) {
        guard moving, distance > 0 else {
            track.layer?.removeAnimation(forKey: Self.animationKey)
            animatedDistance = -1
            return
        }
        let installed = track.layer?.animation(forKey: Self.animationKey) != nil
        guard !installed || animatedDistance != distance else { return }
        animatedDistance = distance

        let travel = CFTimeInterval(distance / Self.speed)
        let total = travel + Self.hold
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -distance]
        animation.keyTimes = [0, NSNumber(value: Self.hold / total), 1]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .linear)
        ]
        animation.duration = total
        animation.repeatCount = .infinity
        track.layer?.add(animation, forKey: Self.animationKey)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A recycled cell that has left the hierarchy should not keep a repeating
        // animation alive on its layer.
        if window == nil {
            isScrolling = false
            track.layer?.removeAnimation(forKey: Self.animationKey)
            animatedDistance = -1
        }
    }
}

// MARK: - Key cap

/// Tiny keyboard-key chip used for shortcut hints (↩, esc, ⌘1…).
final class KeyCapView: NSView {
    private let label: NSTextField

    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        label.font = DevTypeTheme.font(10, .semibold)
        label.textColor = DevTypeTheme.textSecondary
        label.translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 5
        // §5.3: dynamic overlays — the white fills disappeared in Light Mode.
        layer?.backgroundColor = DevTypeTheme.contrastOverlay(0.07).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = DevTypeTheme.contrastOverlay(0.20).cgColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.5)
        ])
        // §5.1: key caps are decorative hints — the enclosing row speaks for them.
        dtApplyAccessibility(isElement: false)
        label.setAccessibilityElement(false)
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    func update(text: String) {
        label.stringValue = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Icon badge

/// SF symbol centered in a tinted, rounded square — card headers, status rows.
final class IconBadgeView: NSView {
    private let imageView = NSImageView()
    private var symbolName: String
    private var tint: NSColor
    private let pointSize: CGFloat

    init(symbol: String, tint: NSColor = DevTypeTheme.accent, size: CGFloat = 30, pointSize: CGFloat = 13) {
        self.symbolName = symbol
        self.tint = tint
        self.pointSize = pointSize
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = size * 0.28
        applyTint()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        setSymbol(symbol, tint: tint)
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: size * 0.62),
            imageView.heightAnchor.constraint(equalToConstant: size * 0.62)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyTint() {
        layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = tint.withAlphaComponent(0.34).cgColor
    }

    func setSymbol(_ name: String, tint newTint: NSColor) {
        symbolName = name
        tint = newTint
        imageView.image = DevTypeTheme.tintedSymbol(symbolName, size: pointSize, weight: .semibold, color: tint)
        // §5.1: an icon chip is decoration next to a labelled title in every
        // current call site — keep it out of the AX tree rather than announcing
        // an unlabeled image.
        imageView.setAccessibilityElement(false)
        dtApplyAccessibility(isElement: false)
        applyTint()
    }

}

// MARK: - Rounded table selection

/// Row view that paints DevType's rounded crimson selection.
final class RoundedSelectionRowView: NSTableRowView {
    var selectionRadius: CGFloat = 9
    var selectionInset = NSEdgeInsets(top: 2.5, left: 6, bottom: 2.5, right: 6)

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = NSRect(
            x: bounds.origin.x + selectionInset.left,
            y: bounds.origin.y + selectionInset.top,
            width: bounds.width - selectionInset.left - selectionInset.right,
            height: bounds.height - selectionInset.top - selectionInset.bottom
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: selectionRadius, yRadius: selectionRadius)
        if isEmphasized {
            DevTypeTheme.accent.withAlphaComponent(0.32).setFill()
            path.fill()
            DevTypeTheme.accent.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            // §5.3: dynamic so unemphasized selection stays visible in Light Mode.
            DevTypeTheme.contrastOverlay(0.12).setFill()
            path.fill()
        }
    }

    override var isEmphasized: Bool {
        get { super.isEmphasized }
        set { super.isEmphasized = newValue }
    }
}

// MARK: - Styled text input

/// Rounded, crimson-focus text field matching the glass theme.
final class GlassTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = true
        bezelStyle = .roundedBezel
        font = DevTypeTheme.font(13)
        textColor = DevTypeTheme.textPrimary
        translatesAutoresizingMaskIntoConstraints = false
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }
}
