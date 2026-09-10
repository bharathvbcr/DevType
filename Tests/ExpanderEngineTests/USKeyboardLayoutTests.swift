import Carbon.HIToolbox
import XCTest
@testable import ExpanderEngine

final class USKeyboardLayoutTests: XCTestCase {
    func testCharacterMapsKnownQwertyKeycodes() {
        let mappings: [(keyCode: Int, expected: Character)] = [
            (kVK_ANSI_A, "a"),
            (kVK_ANSI_Z, "z"),
            (kVK_ANSI_1, "1"),
            (kVK_ANSI_Semicolon, ";"),
            (kVK_ANSI_Equal, "="),
            (kVK_Space, " "),
        ]
        for mapping in mappings {
            XCTAssertEqual(
                USKeyboardLayout.character(forKeyCode: mapping.keyCode),
                mapping.expected,
                "non-shifted keycode \(mapping.keyCode) should map to \(mapping.expected)"
            )
        }
    }

    func testCharacterAppliesShiftedMapWhenRequested() {
        let shiftedMappings: [(keyCode: Int, expected: Character)] = [
            (kVK_ANSI_A, "A"),
            (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_1, "!"),
            (kVK_ANSI_Semicolon, ":"),
            (kVK_Space, " "),
            (kVK_ANSI_Equal, "+"),
        ]
        for mapping in shiftedMappings {
            XCTAssertEqual(
                USKeyboardLayout.character(forKeyCode: mapping.keyCode, shift: true),
                mapping.expected,
                "shifted keycode \(mapping.keyCode) should map to \(mapping.expected)"
            )
        }
    }

    func testUnknownKeycodeReturnsNil() {
        XCTAssertNil(USKeyboardLayout.character(forKeyCode: -1))
        XCTAssertNil(USKeyboardLayout.character(forKeyCode: 9999))
    }
}
