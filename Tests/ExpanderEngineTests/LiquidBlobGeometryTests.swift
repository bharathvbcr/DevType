import AppKit
import CoreGraphics
import XCTest
@testable import ExpanderEngine

final class LiquidBlobGeometryTests: XCTestCase {

    private let standardRect = CGRect(x: 0, y: 0, width: 280, height: 72)
    private let expandedRect = CGRect(x: 0, y: 0, width: 440, height: 140)

    // MARK: - Invariant 1: Path is closed

    func testPathIsClosed() {
        let path = LiquidBlobGeometry.path(in: standardRect, phase: 0.0, audioLevel: 0.5)
        XCTAssertFalse(path.isEmpty)

        // Verify path has elements and ends with a close subpath
        var hasClose = false
        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            if element.type == .closeSubpath {
                hasClose = true
            }
        }
        XCTAssertTrue(hasClose, "Organic blob path must be closed")
    }

    // MARK: - Invariant 2: Bounding Box is strictly contained within rect

    func testBoundingBoxContainedInRectAtAudioLevelsAndPhases() {
        let testRects = [
            standardRect,
            expandedRect,
            CGRect(x: 100, y: 200, width: 320, height: 90),
            CGRect(x: 0, y: 0, width: 520, height: 200)
        ]
        let audioLevels: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
        let phases: [Double] = [0.0, .pi / 4, .pi / 2, .pi, 3 * .pi / 2, 2 * .pi, 5.5]

        for rect in testRects {
            for level in audioLevels {
                for phase in phases {
                    let path = LiquidBlobGeometry.path(in: rect, phase: phase, audioLevel: level)
                    let bbox = path.boundingBoxOfPath

                    // Allow a tiny epsilon (0.001) for floating point precision
                    let tolerance: CGFloat = 0.001
                    let paddedRect = rect.insetBy(dx: -tolerance, dy: -tolerance)

                    XCTAssertTrue(
                        paddedRect.contains(bbox),
                        "Blob bounding box \(bbox) must be ⊆ rect \(rect) at audio \(level), phase \(phase)"
                    )
                }
            }
        }
    }

    // MARK: - Invariant 3: Radial variance increases with audio level

    func testHigherAudioIncreasesRadialVariance() {
        // Average variance across several phases to prevent single-phase node nullification
        let phases: [Double] = [0.0, .pi / 3, 2 * .pi / 3, .pi, 4 * .pi / 3]

        var idleVarianceSum: CGFloat = 0
        var loudVarianceSum: CGFloat = 0

        for phase in phases {
            idleVarianceSum += LiquidBlobGeometry.radialVariance(in: standardRect, phase: phase, audioLevel: 0.0)
            loudVarianceSum += LiquidBlobGeometry.radialVariance(in: standardRect, phase: phase, audioLevel: 1.0)
        }

        let avgIdleVariance = idleVarianceSum / CGFloat(phases.count)
        let avgLoudVariance = loudVarianceSum / CGFloat(phases.count)

        XCTAssertGreaterThan(
            avgLoudVariance,
            avgIdleVariance,
            "Loud audio (1.0) variance (\(avgLoudVariance)) must exceed idle audio (0.0) variance (\(avgIdleVariance))"
        )
    }

    // MARK: - Invariant 4: HUD size is monotonic in transcript length

    func testHUDSizeMonotonicInTranscriptLength() {
        let font = NSFont.systemFont(ofSize: 13.5, weight: .medium)

        let shortText = "Hello world"
        let mediumText = "Hello world, this is a longer sentence being spoken into smart dictation."
        let longText = "Hello world, this is a much longer multi-line transcript that continues to wrap across multiple lines in the liquid glass HUD panel as the user dictates text naturally."

        let sizeShort = LiquidBlobGeometry.hudSize(forText: shortText, font: font)
        let sizeMedium = LiquidBlobGeometry.hudSize(forText: mediumText, font: font)
        let sizeLong = LiquidBlobGeometry.hudSize(forText: longText, font: font)

        // Monotonic width & area growth
        XCTAssertGreaterThanOrEqual(sizeMedium.width, sizeShort.width)
        XCTAssertGreaterThanOrEqual(sizeLong.width, sizeMedium.width)
        XCTAssertGreaterThanOrEqual(sizeLong.height, sizeShort.height)
        XCTAssertGreaterThanOrEqual(sizeLong.width * sizeLong.height, sizeShort.width * sizeShort.height)
    }

    // MARK: - Invariant 5: Placeholder / empty text stays at base size

    func testPlaceholderAndEmptyStayAtBaseSize() {
        let font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        let baseSize = CGSize(width: 280, height: 72)

        let emptySize = LiquidBlobGeometry.hudSize(forText: "", font: font, base: baseSize)
        let spacesSize = LiquidBlobGeometry.hudSize(forText: "   \n  ", font: font, base: baseSize)
        let placeholder1 = LiquidBlobGeometry.hudSize(forText: "Speak naturally…", font: font, base: baseSize)
        let placeholder2 = LiquidBlobGeometry.hudSize(forText: "Listening…", font: font, base: baseSize)

        XCTAssertEqual(emptySize, baseSize)
        XCTAssertEqual(spacesSize, baseSize)
        XCTAssertEqual(placeholder1, baseSize)
        XCTAssertEqual(placeholder2, baseSize)
    }

    // MARK: - Mask image generation

    func testMaskImageGeneration() {
        let size = CGSize(width: 280, height: 72)
        let path = LiquidBlobGeometry.path(in: CGRect(origin: .zero, size: size), phase: 0.0, audioLevel: 0.5)
        let image = LiquidBlobGeometry.maskImage(path: path, size: size)

        XCTAssertEqual(image.size, size)
        XCTAssertEqual(image.resizingMode, .stretch)
    }
}
