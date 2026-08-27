import AppKit
import CoreGraphics
import Foundation

/// Pure geometry for the voice dictation liquid blob HUD.
///
/// The silhouette must stay inside `rect` at every audio level so the panel does
/// not clip organic lobes into a stadium. Expansion sizing accounts for real
/// chrome (header, waveform, padding), not just transcript height.
public enum LiquidBlobGeometry {

    /// Maximum radial scale above the inset base ellipse (audio + harmonics).
    /// Chosen so the path stays inside `rect` after the inset is applied.
    public static let maxRadiusScale: CGFloat = 1.22

    /// Control points around the blob silhouette.
    public static let pointCount: Int = 14

    /// Vertical chrome outside the transcript line: top pad + header + stack
    /// spacings + waveform + bottom pad.
    public static let defaultChromeHeight: CGFloat = 70

    /// Horizontal padding around the transcript (leading/trailing insets).
    public static let horizontalTextPadding: CGFloat = 48

    /// Closed organic spline inscribed in `rect`. Bounding box ⊆ `rect` for any
    /// `audioLevel` in 0…1 and any `phase`.
    public static func path(
        in rect: CGRect,
        phase: Double,
        audioLevel: CGFloat
    ) -> CGPath {
        let width = rect.width
        let height = rect.height
        guard width > 20, height > 20 else {
            let r = Swift.min(width, height) / 2
            let fallback = CGMutablePath()
            fallback.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
            fallback.closeSubpath()
            return fallback
        }

        let level = Swift.min(Swift.max(audioLevel, 0), 1)
        // Inset so maxRadiusScale * base radius never leaves the rect.
        let insetX = (width / 2) * (1 - 1 / maxRadiusScale)
        let insetY = (height / 2) * (1 - 1 / maxRadiusScale)
        let inner = rect.insetBy(dx: insetX, dy: insetY)

        let cx = inner.midX
        let cy = inner.midY
        let rx = Double(inner.width / 2)
        let ry = Double(inner.height / 2)

        // Speech grows deformation inside the inset, not past the window.
        let audioPerturbation = Double(level) * 8.0
        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)

        for i in 0..<pointCount {
            let angle = (Double(i) / Double(pointCount)) * 2.0 * .pi
            let harmonic1 = sin(angle * 2.0 + phase) * 3.0
            let harmonic2 = cos(angle * 3.0 - phase * 0.7) * (2.0 + audioPerturbation)
            let harmonic3 = sin(angle * 5.0 + phase * 1.3) * Double(level) * 2.5
            let radiusScale = 1.0 + ((harmonic1 + harmonic2 + harmonic3) / 100.0)
            // Clamp so floating-point drift cannot push past maxRadiusScale.
            let clampedScale = Swift.min(Swift.max(radiusScale, 0.82), Double(maxRadiusScale))

            let px = cx + CGFloat(cos(angle) * rx * clampedScale)
            let py = cy + CGFloat(sin(angle) * ry * clampedScale)
            points.append(CGPoint(x: px, y: py))
        }

        let path = CGMutablePath()
        guard points.count >= 3 else {
            let r = Swift.min(inner.width, inner.height) / 2
            path.addRoundedRect(in: inner, cornerWidth: r, cornerHeight: r)
            path.closeSubpath()
            return path
        }

        path.move(to: midpoint(points[points.count - 1], points[0]))
        for i in 0..<points.count {
            let p1 = points[i]
            let p2 = points[(i + 1) % points.count]
            path.addQuadCurve(to: midpoint(p1, p2), control: p1)
        }
        path.closeSubpath()
        return path
    }

    /// Sample radial distances from center for variance / audio-response tests.
    public static func sampleRadii(
        in rect: CGRect,
        phase: Double,
        audioLevel: CGFloat
    ) -> [CGFloat] {
        let silhouette = path(in: rect, phase: phase, audioLevel: audioLevel)
        let cx = rect.midX
        let cy = rect.midY
        var radii: [CGFloat] = []
        radii.reserveCapacity(pointCount)
        for i in 0..<pointCount {
            let angle = (Double(i) / Double(pointCount)) * 2.0 * .pi
            var lo: CGFloat = 0
            var hi: CGFloat = Swift.max(rect.width, rect.height)
            for _ in 0..<16 {
                let mid = (lo + hi) / 2
                let pt = CGPoint(
                    x: cx + CGFloat(cos(angle)) * mid,
                    y: cy + CGFloat(sin(angle)) * mid
                )
                if silhouette.contains(pt, using: .winding) {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            radii.append(lo)
        }
        return radii
    }

    /// Radial variance of the silhouette (higher when speech deforms the blob).
    public static func radialVariance(
        in rect: CGRect,
        phase: Double,
        audioLevel: CGFloat
    ) -> CGFloat {
        let radii = sampleRadii(in: rect, phase: phase, audioLevel: audioLevel)
        guard !radii.isEmpty else { return 0 }
        let mean = radii.reduce(0, +) / CGFloat(radii.count)
        let sumSq = radii.reduce(CGFloat(0)) { $0 + ($1 - mean) * ($1 - mean) }
        return sumSq / CGFloat(radii.count)
    }

    /// Whether `text` should keep the HUD at its compact base size.
    public static func isPlaceholderText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return text == "Speak naturally…" || text == "Listening…"
    }

    /// Target HUD size for a transcript string. Empty / placeholder copy stays at `base`.
    public static func hudSize(
        forText text: String,
        font: NSFont,
        chromeHeight: CGFloat = defaultChromeHeight,
        base: CGSize = CGSize(width: 280, height: 72),
        maximum: CGSize = CGSize(width: 520, height: 200)
    ) -> CGSize {
        if isPlaceholderText(text) {
            return base
        }
        let maxTextWidth = maximum.width - horizontalTextPadding
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: maximum.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let width = Swift.min(maximum.width, Swift.max(base.width, bounding.width + horizontalTextPadding))
        let height = Swift.min(maximum.height, Swift.max(base.height, bounding.height + chromeHeight))
        return CGSize(width: ceil(width), height: ceil(height))
    }

    /// Rasterize a blob path into an `NSImage` suitable for `NSVisualEffectView.maskImage`.
    public static func maskImage(path: CGPath, size: CGSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.clear(CGRect(origin: .zero, size: size))
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets()
        image.resizingMode = .stretch
        return image
    }

    private static func midpoint(_ p1: CGPoint, _ p2: CGPoint) -> CGPoint {
        CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
    }
}
