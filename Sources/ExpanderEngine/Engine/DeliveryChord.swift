import AppKit
import CoreGraphics

/// The key and modifiers that accepted an AI result (Return, or ⌥Return, in the preview panel).
///
/// Holding the chord past its first press autorepeats it into the frontmost app while the result is
/// being delivered. Those repeats are the same press, not new input — but they would otherwise move
/// the input revision like any real key and abort the replace confirm as `.focusMoved`. Only a
/// chord noted as the one that started *this* delivery is recognised, and only the four modifiers
/// that make a chord different from another one take part in the comparison.
public struct DeliveryChord: Equatable {
    public let keyCode: Int64
    private let modifiers: UInt8

    private static let command: UInt8 = 1, option: UInt8 = 2, control: UInt8 = 4, shift: UInt8 = 8

    /// From a tap event.
    public init(keyCode: Int64, flags: CGEventFlags) {
        self.keyCode = keyCode
        var bits: UInt8 = 0
        if flags.contains(.maskCommand) { bits |= Self.command }
        if flags.contains(.maskAlternate) { bits |= Self.option }
        if flags.contains(.maskControl) { bits |= Self.control }
        if flags.contains(.maskShift) { bits |= Self.shift }
        modifiers = bits
    }

    /// From an AppKit key event.
    public init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = Int64(keyCode)
        var bits: UInt8 = 0
        if modifierFlags.contains(.command) { bits |= Self.command }
        if modifierFlags.contains(.option) { bits |= Self.option }
        if modifierFlags.contains(.control) { bits |= Self.control }
        if modifierFlags.contains(.shift) { bits |= Self.shift }
        modifiers = bits
    }
}
