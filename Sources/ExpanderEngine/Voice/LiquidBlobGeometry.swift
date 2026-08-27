import AppKit
import CoreGraphics
import Foundation

/// Pure geometry for the voice dictation liquid blob HUD.
///
/// Base shape is an inset horizontal stadium / capsule with straight top and bottom
/// spans so that content in the top-left and top-right is NEVER pinched or clipped.
/// Harmonics deform the perimeter organically in response to live speech.
public enum LiquidBlobGeometry {

    /// Maximum harmonic ripple perturbation ratio relative to radius.
    public static let maxDeformationRatio: CGFloat = 0.075

    /// Control points around the blob silhouette.
    public static let pointCount: Int = 32

    /// Vertical chrome outside the transcript: top pad + compact status row +
    /// stack spacing + bottom pad.
    public static let defaultChromeHeight: CGFloat = 46

    /// Horizontal padding around the transcript (leading/trailing insets).
    public static let horizontalTextPadding: CGFloat = 36

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
        let r = height / 2.0
        let maxDeform = Swift.min(3.0, r * maxDeformationRatio) * level

        // Inset base capsule by maxDeform + margin so ripples NEVER exceed rect
        let insetX = maxDeform + 1.0
        let insetY = maxDeform + 1.0
        let inner = rect.insetBy(dx: insetX, dy: insetY)

        // The voice HUD is intentionally horizontal. Keep the public geometry
        // contract safe for a narrow or transient zero-layout rect anyway: the
        // horizontal-cap construction below assumes width >= height and would
        // otherwise project both caps beyond the supplied bounds.
        guard inner.width >= inner.height else {
            let radius = Swift.min(inner.width, inner.height) / 2
            let fallback = CGMutablePath()
            fallback.addRoundedRect(in: inner, cornerWidth: radius, cornerHeight: radius)
            fallback.closeSubpath()
            return fallback
        }

        let capR = inner.height / 2.0
        let leftCenterX = inner.minX + capR
        let rightCenterX = Swift.max(leftCenterX, inner.maxX - capR)
        let straightWidth = rightCenterX - leftCenterX

        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)

        let pointsPerSegment = pointCount / 4

        // 1. Top flat edge (left to right)
        for i in 0..<pointsPerSegment {
            let t = Double(i) / Double(pointsPerSegment)
            let x = leftCenterX + CGFloat(t) * straightWidth
            let wave = (
                sin(t * 2.0 * .pi + phase) * 0.58
                + sin(t * .pi + phase * 0.37) * 0.18
            ) * Double(maxDeform)
            let y = inner.maxY + CGFloat(wave)
            points.append(CGPoint(x: x, y: y))
        }

        // 2. Right semicircular cap (angle +pi/2 -> -pi/2)
        for i in 0..<pointsPerSegment {
            let t = Double(i) / Double(pointsPerSegment)
            let angle = (.pi / 2.0) - t * .pi
            let wave = (
                cos(angle * 2.0 - phase * 0.72) * 0.52
                + sin(angle + phase * 0.31) * 0.16
            ) * Double(maxDeform)
            let radius = capR + CGFloat(wave)
            let x = rightCenterX + CGFloat(cos(angle)) * radius
            let y = inner.midY + CGFloat(sin(angle)) * radius
            points.append(CGPoint(x: x, y: y))
        }

        // 3. Bottom flat edge (right to left)
        for i in 0..<pointsPerSegment {
            let t = Double(i) / Double(pointsPerSegment)
            let x = rightCenterX - CGFloat(t) * straightWidth
            let wave = -(
                sin(t * 2.0 * .pi + phase + 1.15) * 0.56
                + sin(t * .pi - phase * 0.29) * 0.16
            ) * Double(maxDeform)
            let y = inner.minY + CGFloat(wave)
            points.append(CGPoint(x: x, y: y))
        }

        // 4. Left semicircular cap (angle 3pi/2 -> pi/2)
        for i in 0..<pointsPerSegment {
            let t = Double(i) / Double(pointsPerSegment)
            let angle = (3.0 * .pi / 2.0) - t * .pi
            let wave = (
                cos(angle * 2.0 + phase * 0.68) * 0.50
                + sin(angle - phase * 0.27) * 0.16
            ) * Double(maxDeform)
            let radius = capR + CGFloat(wave)
            let x = leftCenterX + CGFloat(cos(angle)) * radius
            let y = inner.midY + CGFloat(sin(angle)) * radius
            points.append(CGPoint(x: x, y: y))
        }

        guard points.count >= 3 else {
            let fallback = CGMutablePath()
            fallback.addRoundedRect(in: inner, cornerWidth: capR, cornerHeight: capR)
            fallback.closeSubpath()
            return fallback
        }

        let path = CGMutablePath()
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
        let probeCount = 16
        radii.reserveCapacity(probeCount)
        for i in 0..<probeCount {
            let angle = (Double(i) / Double(probeCount)) * 2.0 * .pi
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

    /// Radial deformation variance of the silhouette relative to resting state (0 at idle, > 0 during speech).
    public static func radialVariance(
        in rect: CGRect,
        phase: Double,
        audioLevel: CGFloat
    ) -> CGFloat {
        let baseRadii = sampleRadii(in: rect, phase: 0.0, audioLevel: 0.0)
        let activeRadii = sampleRadii(in: rect, phase: phase, audioLevel: audioLevel)
        guard baseRadii.count == activeRadii.count, !baseRadii.isEmpty else { return 0 }
        var sumDiffSq: CGFloat = 0
        for i in 0..<baseRadii.count {
            let diff = activeRadii[i] - baseRadii[i]
            sumDiffSq += diff * diff
        }
        return sumDiffSq / CGFloat(baseRadii.count)
    }

    /// Whether `text` should keep the HUD at its compact base size.
    public static func isPlaceholderText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return text == "Speak naturally…" || text == "Listening…" || text == "Listening" || text == "자연스럽게 말씀하세요…" || text == "自然に話してください…"
    }

    /// Target HUD size for a transcript string. Empty / placeholder copy stays at `base`.
    public static func hudSize(
        forText text: String,
        font: NSFont,
        chromeHeight: CGFloat = defaultChromeHeight,
        base: CGSize = CGSize(width: 304, height: 68),
        maximum: CGSize = CGSize(width: 500, height: 188)
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
