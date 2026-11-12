import AppKit
@testable import DevTypeAppCore
import SourceTreeTestSupport
import TestWindowShield
import XCTest

/// A test run must not put windows in front of the person at the keyboard.
///
/// Every test target links `TestWindowShield`, which keeps each window the test process creates
/// fully transparent at the WindowServer while the window's own state — `isVisible`, `alphaValue`,
/// `frame`, key status — reads exactly as it would on screen. These tests read the WindowServer's
/// own record of the window, so they fail if any window the suite orders front can be seen.
final class TestWindowShieldTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["DEVTYPE_TEST_SHOW_WINDOWS"] == "1",
            "DEVTYPE_TEST_SHOW_WINDOWS=1 shows test windows on purpose"
        )
        try XCTSkipUnless(
            CGSessionCopyCurrentDictionary() != nil && !NSScreen.screens.isEmpty,
            "no WindowServer session — there is no screen to keep windows off"
        )
        _ = NSApplication.shared
        XCTAssertTrue(DTTestWindowShieldIsInstalled(), "TestWindowShield did not install in this test bundle")
    }

    /// The WindowServer's alpha and on-screen flag for `window`, which is what the person sees.
    private func serverState(_ window: NSWindow) throws -> (alpha: Double, onScreen: Bool) {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber))
        let entries = try XCTUnwrap(list as? [[String: Any]], "WindowServer returned no window list")
        let entry = try XCTUnwrap(entries.first, "WindowServer has no record of window \(window.windowNumber)")
        let alpha = try XCTUnwrap(entry[kCGWindowAlpha as String] as? Double, "no alpha in \(entry)")
        return (alpha, entry[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }

    /// `nil` while the WindowServer has no record of the window yet.
    private func serverStateIfListed(_ window: NSWindow) -> (alpha: Double, onScreen: Bool)? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber))
        guard let entry = (list as? [[String: Any]])?.first,
              let alpha = entry[kCGWindowAlpha as String] as? Double else { return nil }
        return (alpha, entry[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testOrderedWindowIsTransparentOnScreenButKeepsItsOwnState() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 240, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        spin(0.05)

        XCTAssertTrue(window.isVisible, "the window must still be ordered in for the code under test")
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.0001, "code reads the alpha it would on screen")
        let shown = try serverState(window)
        XCTAssertTrue(shown.onScreen, "the window is ordered in, so the WindowServer lists it on screen")
        XCTAssertEqual(shown.alpha, 0, accuracy: 0.0001, "the person at the keyboard must not see a test window")

        window.alphaValue = 0.5
        spin(0.02)
        XCTAssertEqual(window.alphaValue, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try serverState(window).alpha, 0, accuracy: 0.0001)
    }

    /// Panels in this app fade in through `animator()`. The fade must not leak a single frame.
    func testAnimatedFadeNeverReachesTheScreen() throws {
        let panel = NSPanel(
            contentRect: NSRect(x: 200, y: 200, width: 240, height: 80),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        defer { panel.orderOut(nil) }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }

        let watched = watchPeakAlpha(of: [panel], atLeast: 0.3) { abs(panel.alphaValue - 1) < 0.0001 }
        XCTAssertGreaterThan(watched.samples, 0, "the WindowServer must have listed the panel during its fade")
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.0001, "the fade completes as far as the code can tell")
        XCTAssertEqual(watched.peak, 0, accuracy: 0.0001, "no frame of the fade may be visible")
    }

    /// Hiding the voice HUD runs an AppKit close animation that reads the window's alpha and
    /// drives the WindowServer itself, without `setAlphaValue:`. It must read the hidden value,
    /// or the HUD fades out in full view at the end of every HUD test.
    @MainActor
    func testVoiceHUDCloseAnimationStaysTransparent() throws {
        let hud = VoiceHUDPanel()
        hud.updateState(.success(text: "complete"))
        let shown = watchPeakAlpha(of: [hud], atLeast: 0.3) { hud.isVisible && abs(hud.alphaValue - 1) < 0.0001 }
        XCTAssertTrue(hud.isVisible, "the HUD must be ordered in for the code under test")
        XCTAssertEqual(hud.alphaValue, 1, accuracy: 0.0001)

        hud.hide()
        XCTAssertFalse(hud.isVisible)
        let closing = watchPeakAlpha(of: [hud], atLeast: 0.3) { self.serverStateIfListed(hud) == nil }

        XCTAssertGreaterThan(shown.samples, 0, "the WindowServer must have listed the HUD")
        XCTAssertEqual(shown.peak, 0, accuracy: 0.0001, "the HUD's fade-in must not be visible")
        XCTAssertEqual(closing.peak, 0, accuracy: 0.0001, "the HUD's close animation must not be visible")
    }

    /// Attaching a sheet makes AppKit re-apply both windows' alpha through a private path. Neither
    /// the sheet nor the window it is attached to may become visible.
    func testSheetAndItsHostStayTransparent() throws {
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        defer { host.orderOut(nil) }
        host.makeKeyAndOrderFront(nil)
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.isReleasedWhenClosed = false

        host.beginSheet(sheet)
        let attached = watchPeakAlpha(of: [host, sheet], atLeast: 0.5) { sheet.isSheet && sheet.isVisible }
        XCTAssertTrue(sheet.isSheet && sheet.isVisible, "the sheet must be attached for the code under test")
        XCTAssertEqual(host.alphaValue, 1, accuracy: 0.0001)
        XCTAssertEqual(sheet.alphaValue, 1, accuracy: 0.0001)
        host.endSheet(sheet)
        let detached = watchPeakAlpha(of: [host, sheet], atLeast: 0.3) { self.serverStateIfListed(sheet) == nil }

        XCTAssertGreaterThan(attached.samples, 0, "the WindowServer must have listed both windows")
        XCTAssertEqual(attached.peak, 0, accuracy: 0.0001, "attaching a sheet must not show it or its host")
        XCTAssertEqual(detached.peak, 0, accuracy: 0.0001, "detaching a sheet must not show it or its host")
    }

    /// Samples the WindowServer alpha of `windows` for at least `minimum` seconds and until `settled`
    /// holds, bounded by `timeout` so a loaded machine slows the test rather than failing it.
    /// Returns the highest alpha seen and how many samples found a window listed at all.
    private func watchPeakAlpha(
        of windows: [NSWindow],
        atLeast minimum: TimeInterval,
        timeout: TimeInterval = 5,
        until settled: () -> Bool
    ) -> (peak: Double, samples: Int) {
        var peak = 0.0
        var samples = 0
        let start = Date()
        while Date().timeIntervalSince(start) < timeout,
              Date().timeIntervalSince(start) < minimum || !settled() {
            for window in windows {
                if let state = serverStateIfListed(window) {
                    peak = max(peak, state.alpha)
                    samples += 1
                }
            }
            spin(0.01)
        }
        return (peak, samples)
    }

    /// The shield only covers bundles that link it. A test target added without it would show
    /// its windows again, so every `.testTarget` in the manifest must name it.
    func testEveryTestTargetLinksTheShield() throws {
        let manifest = try String(contentsOf: SourceTree.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let blocks = manifest.components(separatedBy: ".testTarget(").dropFirst()
        XCTAssertFalse(blocks.isEmpty, "Package.swift declares no test targets")
        for block in blocks {
            let body = block.components(separatedBy: "\n        )").first ?? block
            let name = body.components(separatedBy: "name: \"").dropFirst().first?
                .components(separatedBy: "\"").first ?? "<unnamed>"
            XCTAssertTrue(body.contains("\"TestWindowShield\""), "test target \(name) does not depend on TestWindowShield")
        }
    }
}
