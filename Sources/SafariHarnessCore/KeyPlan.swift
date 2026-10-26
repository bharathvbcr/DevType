import Foundation

/// One keyboard event the harness will post at the HID tap. `flags` is what the event carries, not
/// what is physically held: the harness sets it explicitly on every event.
public struct KeyEvent: Equatable, Sendable {
    public let keyCode: UInt16
    public let down: Bool
    public let flags: ModifierMask

    public init(keyCode: UInt16, down: Bool, flags: ModifierMask = []) {
        self.keyCode = keyCode
        self.down = down
        self.flags = flags
    }
}

public enum KeyPlanError: Error, Equatable, CustomStringConvertible {
    case unmappableCharacter(Character)

    public var description: String {
        switch self {
        case .unmappableCharacter(let c):
            return "cannot type \(String(reflecting: String(c))): not on the US keyboard layout the harness drives"
        }
    }
}

/// Character to virtual key code on the US (ANSI) layout.
///
/// DevType's tap derives the typed character from the key code through its own US table first and
/// only falls back to the event's unicode string (`EventTapEngine+TapCallback.swift`, the
/// `USKeyboardLayout.character(forKeyCode:shift:)` call), so a key code plus an explicit shift flag
/// is exactly what a real keyboard produces. Setting a unicode string on a dummy key code would
/// hand DevType the wrong character. Safari renders by the active layout, which is why
/// `LayoutPolicy` refuses anything but a US layout.
public enum KeyPlan {
    public static let returnKey: UInt16 = 36
    public static let escapeKey: UInt16 = 53
    public static let spaceKey: UInt16 = 49

    private static let unshifted: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50
    ]

    /// Shifted symbol to the unshifted character on the same key.
    private static let shiftedBase: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
        ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
        ">": ".", "?": "/", "~": "`"
    ]

    public static func keyCode(for character: Character) -> (code: UInt16, shift: Bool)? {
        if let code = unshifted[character] { return (code, false) }
        if let base = shiftedBase[character], let code = unshifted[base] { return (code, true) }
        if character.isUppercase, character.isASCII,
           let code = unshifted[Character(character.lowercased())] { return (code, true) }
        return nil
    }

    public static func canType(_ text: String) -> Bool {
        text.allSatisfy { keyCode(for: $0) != nil }
    }

    /// The events for one character: a real keyboard presses Shift first and releases it last.
    public static func events(for character: Character) throws -> [KeyEvent] {
        guard let (code, shift) = keyCode(for: character) else {
            throw KeyPlanError.unmappableCharacter(character)
        }
        guard shift else {
            return [KeyEvent(keyCode: code, down: true), KeyEvent(keyCode: code, down: false)]
        }
        return [
            KeyEvent(keyCode: Modifier.shift.keyCode, down: true, flags: .shift),
            KeyEvent(keyCode: code, down: true, flags: .shift),
            KeyEvent(keyCode: code, down: false, flags: .shift),
            KeyEvent(keyCode: Modifier.shift.keyCode, down: false)
        ]
    }

    /// A chord: modifiers down in order, the key, then modifiers up in reverse. Each event carries
    /// the modifiers held at that moment.
    public static func chord(keyCode: UInt16, modifiers: [Modifier]) -> [KeyEvent] {
        var held: ModifierMask = []
        var out: [KeyEvent] = []
        for modifier in modifiers {
            held.insert(modifier.mask)
            out.append(KeyEvent(keyCode: modifier.keyCode, down: true, flags: held))
        }
        out.append(KeyEvent(keyCode: keyCode, down: true, flags: held))
        out.append(KeyEvent(keyCode: keyCode, down: false, flags: held))
        for modifier in modifiers.reversed() {
            held.remove(modifier.mask)
            out.append(KeyEvent(keyCode: modifier.keyCode, down: false, flags: held))
        }
        return out
    }
}

/// US layouts only. A different layout would make the posted key codes type different characters.
public enum LayoutPolicy {
    public static let acceptedSourceIDs: Set<String> = [
        "com.apple.keylayout.US", "com.apple.keylayout.ABC", "com.apple.keylayout.USExtended"
    ]

    public static func isSupported(sourceID: String?) -> Bool {
        guard let sourceID else { return false }
        return acceptedSourceIDs.contains(sourceID)
    }
}

/// Seeded so a run can be repeated: the seed is printed in the report.
public struct JitterRNG: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func nextUInt64() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func next(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextUInt64() % span)
    }
}

/// Key hold and inter-key gap, in milliseconds.
public struct Pace: Equatable, Sendable {
    public let holdMs: ClosedRange<Int>
    public let gapMs: ClosedRange<Int>
    public let name: String

    /// An unhurried typist: about 8 to 14 characters a second.
    public static let human = Pace(holdMs: 35...70, gapMs: 70...140, name: "human")
    /// A fast burst, the kind that runs ahead of an expansion in flight.
    public static let fast = Pace(holdMs: 5...9, gapMs: 10...16, name: "fast")

    public func sampleHold(_ rng: inout JitterRNG) -> Int { rng.next(in: holdMs) }
    public func sampleGap(_ rng: inout JitterRNG) -> Int { rng.next(in: gapMs) }
}

/// The AI palette shortcut as DevType stores it: `{keyCode, carbonModifiers}` JSON under
/// `devtype.hotkey.aiPalette`. Absent or unreadable means the default, command-option-A.
public struct AIHotkey: Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: [Modifier]
    public let isDefault: Bool

    // Carbon modifier masks.
    static let carbonCommand: UInt32 = 256
    static let carbonShift: UInt32 = 512
    static let carbonOption: UInt32 = 2048
    static let carbonControl: UInt32 = 4096
    static let defaultKeyCode: UInt16 = 0 // kVK_ANSI_A

    public static let `default` = AIHotkey(keyCode: defaultKeyCode, modifiers: [.option, .command], isDefault: true)

    private struct Stored: Decodable {
        let keyCode: UInt32
        let carbonModifiers: UInt32
    }

    public static func decode(_ data: Data?) -> AIHotkey {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.carbonModifiers != 0, stored.keyCode <= UInt32(UInt16.max) else {
            return .default
        }
        var mods: [Modifier] = []
        if stored.carbonModifiers & carbonControl != 0 { mods.append(.control) }
        if stored.carbonModifiers & carbonOption != 0 { mods.append(.option) }
        if stored.carbonModifiers & carbonShift != 0 { mods.append(.shift) }
        if stored.carbonModifiers & carbonCommand != 0 { mods.append(.command) }
        return AIHotkey(keyCode: UInt16(stored.keyCode), modifiers: mods, isDefault: false)
    }

    public var events: [KeyEvent] { KeyPlan.chord(keyCode: keyCode, modifiers: modifiers) }
    public var label: String { (modifiers.map(\.rawValue) + ["keyCode \(keyCode)"]).joined(separator: "+") }
}
