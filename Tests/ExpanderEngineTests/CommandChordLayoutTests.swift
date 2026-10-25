import Carbon
import CoreGraphics
import XCTest
@testable import ExpanderEngine

/// The paste chord is posted as ⌘ + a key code, so the key code that matters is the one the
/// *layout* maps to "v" while Command is down — not the one that types a "v".
///
/// They are the same key on almost every layout, which is why this went unnoticed. They differ on
/// the "Command-QWERTY" layouts macOS ships (Dvorak - QWERTY ⌘, Arabic - QWERTY ⌘, …): typing is
/// Dvorak, but every ⌘ shortcut keeps its QWERTY position. The scan translated with no modifier,
/// so on Dvorak - QWERTY ⌘ it found the physical period key (47) and posted ⌘+period — "Cancel" in
/// most apps, not paste — for every expansion.
///
/// These read the layouts that ship with macOS. Reading a non-selected input source does not
/// switch the user's layout, so the test never changes machine state.
final class CommandChordLayoutTests: XCTestCase {
    private struct NoLayout: KeyboardLayoutProviding {
        func currentSourceID() -> String? { nil }
        func keyCode(for character: Character) -> CGKeyCode? { nil }
    }

    private func installedLayout(_ id: String) throws -> TISInputSource {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        return try XCTUnwrap(list?.first, "\(id) is not installed on this machine")
    }

    private func chordKey(_ character: Character, layout id: String) throws -> CGKeyCode? {
        LiveKeyboardLayoutProvider.keyCode(
            for: character, in: try installedLayout(id), modifiers: LiveKeyboardLayoutProvider.chordModifiers
        )
    }

    /// Characterization (passes before and after the layout fix): the chord is built from a private
    /// event source and carries exactly Command on every event but the Command release, so a
    /// Shift or Option the user is physically holding when the trigger fires is not in the flags
    /// of the paste. Whether the HID tap merges the *hardware* modifier state on top of that is
    /// not observable without a live app.
    func testPasteChordFlagsAreExactlyCommandWhateverTheUserIsHolding() {
        var events: [CGEvent] = []
        let hid = HIDKeyPoster(
            commandEventIO: .init(canPost: { true }, post: { events.append($0) }, pause: {}),
            layout: KeyboardLayoutState(provider: NoLayout())
        )
        let done = expectation(description: "chord posted")
        hid.postCmdVKeyEventsAsync { _ in done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(events.map { $0.flags.intersection([.maskShift, .maskAlternate, .maskControl, .maskCommand]) },
                       [.maskCommand, .maskCommand, .maskCommand, []])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       [Int64(kVK_Command), Int64(kVK_ANSI_V), Int64(kVK_ANSI_V), Int64(kVK_Command)],
                       "no layout is known, so the chord falls back to the ANSI key")
    }

    func testCommandQWERTYLayoutPastesFromTheQWERTYVKey() throws {
        XCTAssertEqual(try chordKey("v", layout: "com.apple.keylayout.DVORAK-QWERTYCMD"), CGKeyCode(kVK_ANSI_V))
        XCTAssertEqual(try chordKey("c", layout: "com.apple.keylayout.DVORAK-QWERTYCMD"), CGKeyCode(kVK_ANSI_C))
    }

    /// The fix must not move any layout whose ⌘ shortcuts follow its typing — that is what Dvorak
    /// proper is, and the existing Dvorak behaviour (⌘V on the physical period key) is correct.
    func testLayoutsWhoseShortcutsFollowTypingKeepTheirOwnKey() throws {
        XCTAssertEqual(try chordKey("v", layout: "com.apple.keylayout.US"), CGKeyCode(kVK_ANSI_V))
        XCTAssertEqual(try chordKey("v", layout: "com.apple.keylayout.Dvorak"), CGKeyCode(kVK_ANSI_Period))
        XCTAssertEqual(try chordKey("c", layout: "com.apple.keylayout.Dvorak"), CGKeyCode(kVK_ANSI_I))
        XCTAssertEqual(try chordKey("v", layout: "com.apple.keylayout.French"), CGKeyCode(kVK_ANSI_V))
    }

    /// A non-Latin layout types no "v" at all, but ⌘V still pastes from the QWERTY position; the
    /// scan must find it rather than hand the caller `nil` and a hard-coded guess.
    func testNonLatinLayoutStillResolvesTheChordKey() throws {
        XCTAssertEqual(try chordKey("v", layout: "com.apple.keylayout.Russian"), CGKeyCode(kVK_ANSI_V))
    }
}
