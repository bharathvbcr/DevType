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
