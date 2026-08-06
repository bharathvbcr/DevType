// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Carbon.HIToolbox

/// Physical keycode → US/ANSI (QWERTY) Latin character.
public enum USKeyboardLayout {

    public static func character(forKeyCode keyCode: Int, shift: Bool = false) -> Character? {
        if shift, let shifted = shiftedMap[keyCode] { return shifted }
        return baseMap[keyCode]
    }

    private static let baseMap: [Int: Character] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d",
        kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h",
        kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p",
        kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
        kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",

        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",

        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Minus: "-",
        kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",

        kVK_Space: " ",
    ]

    private static let shiftedMap: [Int: Character] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",

        kVK_ANSI_1: "!", kVK_ANSI_2: "@", kVK_ANSI_3: "#", kVK_ANSI_4: "$",
        kVK_ANSI_5: "%", kVK_ANSI_6: "^", kVK_ANSI_7: "&", kVK_ANSI_8: "*",
        kVK_ANSI_9: "(", kVK_ANSI_0: ")",

        kVK_ANSI_Semicolon: ":", kVK_ANSI_Quote: "\"", kVK_ANSI_Comma: "<",
        kVK_ANSI_Period: ">", kVK_ANSI_Slash: "?", kVK_ANSI_Minus: "_",
        kVK_ANSI_Equal: "+", kVK_ANSI_LeftBracket: "{", kVK_ANSI_RightBracket: "}",
        kVK_ANSI_Backslash: "|", kVK_ANSI_Grave: "~",

        kVK_Space: " ",
    ]
}
