// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Carbon.HIToolbox

/// What a single key does to the expansion buffer.
public enum KeyAction: Equatable {
    /// Backspace — remove the last character from the buffer.
    case deleteLast
    /// Keys that invalidate the buffer: cancel, navigation, forward-delete.
    case clearBuffer
    /// Ordinary keys (including space/punctuation). Return, KeypadEnter, and Tab are
    /// literal in DevType so they may terminate and be swallowed during expansion.
    case literal
}

/// Keycode → buffer action. Single classification point for the engine.
public enum KeyClassifier {

    /// Keys that end a phrase for `TypedRepetitionDetector`.
    ///
    /// Return / Enter / Tab are `.literal` to the matcher — DevType treats them as ordinary
    /// characters that may terminate an expansion — so this is a separate question from
    /// `action(forKeyCode:)`, not a fourth `KeyAction` case.
    public static func endsPhrase(keyCode: Int) -> Bool {
        keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter || keyCode == kVK_Tab
    }

    public static func action(forKeyCode keyCode: Int) -> KeyAction {
        switch keyCode {
        case kVK_Delete:
            return .deleteLast

        case kVK_Escape,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            return .clearBuffer

        default:
            return .literal
        }
    }
}
