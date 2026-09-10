import Carbon
import CoreGraphics
import XCTest
@testable import ExpanderEngine

final class HIDCopyBoundaryRegressionTests: XCTestCase {
    func testCopyStopsIfPostPermissionIsRevokedDuringModifierGap() {
        var permitted = true
        var keys: [Int64] = []
        let poster = HIDKeyPoster(commandEventIO: .init(
            canPost: { permitted },
            post: { keys.append($0.getIntegerValueField(.keyboardEventKeycode)) },
            pause: { permitted = false }))
        XCTAssertFalse(poster.postCmdCKeyEvents())
        XCTAssertEqual(keys, [Int64(kVK_Command), Int64(kVK_Command)],
                       "Permission loss must release Command without posting C")
    }

    func testCopyRefusalNeverPostsAKey() {
        let poster = HIDKeyPoster(commandEventIO: .init(
            canPost: { false }, post: { _ in XCTFail("Input was not authorized") },
            pause: { XCTFail("Refused input cannot wait") }))
        XCTAssertFalse(poster.postCmdCKeyEvents())
    }

    func testCopyFocusLossReleasesOnlyThePressedModifier() {
        var current = true
        var keys: [Int64] = []
        let poster = HIDKeyPoster(commandEventIO: .init(
            canPost: { true }, post: { keys.append($0.getIntegerValueField(.keyboardEventKeycode)) },
            pause: { current = false }))
        XCTAssertFalse(poster.postCmdCKeyEvents(shouldContinue: { current }))
        XCTAssertEqual(keys, [Int64(kVK_Command), Int64(kVK_Command)])
    }

    func testCopyTagsAllEventsAndReleasesCommand() {
        var events: [CGEvent] = []
        let poster = HIDKeyPoster(commandEventIO: .init(
            canPost: { true }, post: { events.append($0) }, pause: {}))
        XCTAssertTrue(poster.postCmdCKeyEvents())
        XCTAssertEqual(events.count, 4)
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), SyntheticEventMarker.magicUserData)
        }
        XCTAssertEqual(events.last?.flags, [])
        // CoreGraphics represents modifier releases as flagsChanged events.
        XCTAssertEqual(events.last?.type, .flagsChanged)
    }

    func testUnresolvableCharacterNeverTurnsIntoThePasteKey() {
        XCTAssertNil(HIDKeyPoster.resolveVirtualKeyCodeForChar("🐢"),
                     "The caller must choose its own fallback; 9 means V, even for a copy request")
    }
}
