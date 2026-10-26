import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import ExpanderEngine

/// Every key the poster emits — backspaces, arrows, unicode, inserts, trailing keys and the ⌘V
/// chord — goes through the one `CommandEventIO`. That is what lets a test drive the destructive
/// half of the pipeline (erase, then paste) against a recorder without a keystroke ever reaching
/// the machine it runs on, and what makes "Post Events revoked" a single switch.
final class HIDKeyPosterEventRouteTests: XCTestCase {
    private final class Recorder {
        var canPost = true
        var events: [CGEvent] = []
        var keyCodes: [Int] {
            events.map { Int($0.getIntegerValueField(.keyboardEventKeycode)) }
        }
    }

    private func poster(_ recorder: Recorder) -> HIDKeyPoster {
        HIDKeyPoster(
            commandEventIO: .init(
                canPost: { recorder.canPost }, post: { recorder.events.append($0) }, pause: {}
            ),
            layout: KeyboardLayoutState(provider: InjectionHarness.NoLayout())
        )
    }

    func testBackspacesArePostedThroughTheInjectedIO() {
        let recorder = Recorder()
        XCTAssertEqual(poster(recorder).sendBackspaces(count: 3), 3)
        XCTAssertEqual(recorder.keyCodes, Array(repeating: kVK_Delete, count: 6), "a down and an up per pair")
    }

    func testArrowsAreSentThroughTheInjectedIO() {
        let recorder = Recorder()
        poster(recorder).sendLeftArrows(count: 2)
        XCTAssertEqual(recorder.keyCodes, Array(repeating: kVK_LeftArrow, count: 4))
    }

    func testAUnicodeKeyEventIsPostedThroughTheInjectedIO() {
        let recorder = Recorder()
        XCTAssertTrue(poster(recorder).postUnicodeKeyEvent(unicode: "x", keyCode: 0, flags: []))
        XCTAssertEqual(recorder.events.count, 2)
    }

    func testAnInsertIsPostedThroughTheInjectedIO() {
        let recorder = Recorder()
        let posted = poster(recorder).postUnicodeInsert([.text("a"), .key(CGKeyCode(kVK_Return))])
        XCTAssertEqual(posted, 2)
        XCTAssertEqual(recorder.keyCodes, [0, 0, kVK_Return, kVK_Return])
    }

    func testTrailingKeysArePostedThroughTheInjectedIO() {
        let recorder = Recorder()
        poster(recorder).postTrailingKeys(["enter", "tab"])
        XCTAssertEqual(recorder.keyCodes, [kVK_Return, kVK_Return, kVK_Tab, kVK_Tab])
    }

    /// With the IO refusing, nothing is posted by any route and each reports it — the poster never
    /// falls back to the live Post Events check or the live event tap.
    func testNothingIsPostedWhenTheIORefuses() {
        let recorder = Recorder()
        recorder.canPost = false
        let hid = poster(recorder)
        XCTAssertEqual(hid.sendBackspaces(count: 3), 0)
        hid.sendLeftArrows(count: 2)
        XCTAssertFalse(hid.postUnicodeKeyEvent(unicode: "x", keyCode: 0, flags: []))
        XCTAssertEqual(hid.postUnicodeInsert([.text("a")]), 0)
        hid.postTrailingKeys(["enter"])
        XCTAssertTrue(recorder.events.isEmpty)
    }

    /// Revoked mid-burst: the pairs already posted stay counted and the rest are not posted.
    func testARevocationMidBurstStopsThePostingAndCountsWhatWentOut() {
        let recorder = Recorder()
        var pairs = 0
        let hid = HIDKeyPoster(
            commandEventIO: .init(
                canPost: { pairs < 2 },
                post: { event in
                    recorder.events.append(event)
                    if event.type == .keyUp { pairs += 1 }
                },
                pause: {}
            ),
            layout: KeyboardLayoutState(provider: InjectionHarness.NoLayout())
        )
        XCTAssertEqual(hid.sendBackspaces(count: 5), 2)
        XCTAssertEqual(recorder.events.count, 4)
    }
}
