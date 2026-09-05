import AppKit
import XCTest
@testable import DevTypeAppCore
@testable import ExpanderEngine

/// Covers the interaction fixes from the performance/UX audit that have a testable seam:
/// toast reading time and queueing, window frame persistence, and the thumbnail cache that
/// makes image snippets legible in a row without a decode on the scroll path.
final class InteractionFixTests: XCTestCase {

    // MARK: - Toast reading time (X6)

    /// Duration used to be constant regardless of message length, so the longest messages got
    /// the least reading time per word.
    func testToastDurationScalesWithMessageLength() {
        let short = ToastPanel.duration(for: "Copied", detail: nil)
        let long = ToastPanel.duration(
            for: "A considerably longer confirmation line that takes real time to read",
            detail: "and a second line underneath it as well"
        )
        XCTAssertGreaterThan(long, short, "a longer message must be readable for longer")
    }

    func testToastDurationStaysWithinItsBounds() {
        let empty = ToastPanel.duration(for: "", detail: nil)
        XCTAssertGreaterThanOrEqual(empty, ToastPanel.minimumDuration)

        let enormous = ToastPanel.duration(
            for: String(repeating: "word ", count: 400),
            detail: String(repeating: "detail ", count: 400)
        )
        XCTAssertLessThanOrEqual(
            enormous, ToastPanel.maximumDuration,
            "a runaway message must not pin the toast on screen"
        )
    }

    func testToastDetailCountsTowardReadingTime() {
        let withoutDetail = ToastPanel.duration(for: "Saved", detail: nil)
        let withDetail = ToastPanel.duration(for: "Saved", detail: "Three snippets updated")
        XCTAssertGreaterThan(withDetail, withoutDetail)
    }

    /// The queue exists so an operation reporting several outcomes does not display only the
    /// last. The hand-over window has to be long enough to read a line but short enough that a
    /// run of toasts still finishes promptly.
    func testToastReplacementWindowIsUsable() {
        XCTAssertGreaterThan(ToastPanel.minimumVisibleBeforeReplacement, 0.5)
        XCTAssertLessThan(ToastPanel.minimumVisibleBeforeReplacement, ToastPanel.minimumDuration)
    }

    // MARK: - Window frame persistence (X3)

    /// No window in DevType remembered its size or position across launches: every one was
    /// created at a fixed size and centred, so a user who works in a wide Snippet Manager
    /// re-established it every morning.
    func testWindowFrameIsSavedAndRestoredUnderItsName() throws {
        let name = "DevTypeTestWindow-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }

        let first = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        first.dtRestoreFrame(named: name)
        guard let screen = NSScreen.main else {
            throw XCTSkip("frame restoration needs a screen to clamp against")
        }
        let moved = NSRect(
            x: screen.visibleFrame.minX + 60,
            y: screen.visibleFrame.minY + 60,
            width: 640,
            height: 480
        )
        first.setFrame(moved, display: false)
        first.saveFrame(usingName: NSWindow.FrameAutosaveName(name))

        let second = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        second.dtRestoreFrame(named: name)

        XCTAssertEqual(second.frame.width, moved.width, accuracy: 1)
        XCTAssertEqual(second.frame.height, moved.height, accuracy: 1)
    }

    /// With nothing saved, the window keeps the size its creator asked for and is centred —
    /// the behaviour every one of these windows had before frames were persisted at all.
    func testFirstRunKeepsTheRequestedSizeAndCentres() throws {
        let name = "DevTypeTestWindow-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
        guard let screen = NSScreen.main else {
            throw XCTSkip("centring needs a screen")
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 410),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.dtRestoreFrame(named: name)

        XCTAssertEqual(window.frame.width, 520, accuracy: 1)
        XCTAssertTrue(
            screen.visibleFrame.intersects(window.frame),
            "an unsaved window must land on screen"
        )
    }

    // MARK: - Image thumbnails (X4)

    /// An image snippet's row used to show a picture glyph and a filename, while every other
    /// snippet type showed its actual content.
    func testThumbnailIsDownscaledOntoTheRowEdge() throws {
        let source = NSImage(size: NSSize(width: 400, height: 200))
        source.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: source.size).fill()
        source.unlockFocus()

        let scaled = try XCTUnwrap(
            SnippetThumbnailCache.scaledForTesting(source, toEdge: SnippetThumbnailCache.thumbnailEdge)
        )
        XCTAssertLessThanOrEqual(scaled.size.width, SnippetThumbnailCache.thumbnailEdge)
        XCTAssertLessThanOrEqual(scaled.size.height, SnippetThumbnailCache.thumbnailEdge)
        // Aspect preserved: a 2:1 source stays 2:1 so rows do not show distorted art.
        XCTAssertEqual(scaled.size.width / scaled.size.height, 2, accuracy: 0.1)
    }

    /// A source already smaller than the row edge is not blown up.
    func testSmallImagesAreNotUpscaled() throws {
        let source = NSImage(size: NSSize(width: 12, height: 8))
        source.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: source.size).fill()
        source.unlockFocus()

        let scaled = try XCTUnwrap(SnippetThumbnailCache.scaledForTesting(source, toEdge: 32))
        XCTAssertEqual(scaled.size.width, 12, accuracy: 0.5)
        XCTAssertEqual(scaled.size.height, 8, accuracy: 0.5)
    }

    func testZeroSizedImageProducesNoThumbnail() {
        let empty = NSImage(size: .zero)
        XCTAssertNil(SnippetThumbnailCache.scaledForTesting(empty, toEdge: 32))
    }

    /// The cache is what keeps a disk read and a full decode off the scroll path.
    func testCachedThumbnailIsReturnedWithoutTouchingDisk() {
        let cache = SnippetThumbnailCache.shared
        cache.removeAll()
        XCTAssertNil(cache.cachedThumbnail(for: "never-decoded.png"))

        let image = NSImage(size: NSSize(width: 10, height: 10))
        cache.storeForTesting(image, path: "row.png", edge: SnippetThumbnailCache.thumbnailEdge)
        XCTAssertNotNil(cache.cachedThumbnail(for: "row.png"))

        cache.invalidate(path: "row.png")
        XCTAssertNil(
            cache.cachedThumbnail(for: "row.png"),
            "a replaced or deleted image must not keep serving its old thumbnail"
        )
    }

    func testEmptyPathIsNeverCached() {
        XCTAssertNil(SnippetThumbnailCache.shared.cachedThumbnail(for: ""))
        XCTAssertNil(SnippetThumbnailCache.shared.thumbnail(for: "") { _ in
            XCTFail("an empty path must not start a decode")
        })
    }
}
