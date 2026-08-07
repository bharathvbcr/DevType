import AppKit
import Carbon
import Carbon.HIToolbox
import ExpanderEngine

// MARK: - §4.2 — a real shortcut model + recorder control
//
// `HotkeyManager` hardcoded `kVK_ANSI_Slash` + `cmdKey` with no picker and no
// defaults key. ⌘/ is Comment Line in Xcode, VS Code, JetBrains, and Sublime, so
// the app's headline shortcut was unusable for the audience it targets. This
// file adds the value type, the persistence, and the `NSView` that records a
// combination; Preferences wires them together.

/// A Carbon-registrable shortcut. Stored as Carbon key code + Carbon modifier
/// mask so it can go straight into `RegisterEventHotKey`.
struct DevTypeShortcut: Equatable, Codable {
    var keyCode: UInt32
    /// Carbon mask: `cmdKey | optionKey | controlKey | shiftKey`.
    var carbonModifiers: UInt32

    static let inlineSearchDefault = DevTypeShortcut(
        keyCode: UInt32(kVK_ANSI_Slash),
        carbonModifiers: UInt32(cmdKey)
    )

    /// Default AI palette: ⌘⌥A (avoids the ⌘/ Comment Line clash).
    static let aiPaletteDefault = DevTypeShortcut(
        keyCode: UInt32(kVK_ANSI_A),
        carbonModifiers: UInt32(cmdKey | optionKey)
    )

    /// A shortcut with no modifier would swallow a plain key system-wide.
    var hasModifier: Bool { carbonModifiers != 0 }

    // MARK: Conversion

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// `⌃⌥⇧⌘` in the canonical macOS order.
    var modifierSymbols: String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out
    }

    /// Human-readable form, e.g. `⌘/` or `⌥Space`.
    var displayString: String {
        modifierSymbols + Self.keyName(for: keyCode)
    }

    /// Layout-independent name for a virtual key code.
    ///
    /// Deliberately keyed on the **virtual key code**, not on
    /// `charactersIgnoringModifiers`: the inline-search jump handler used to
    /// parse characters and broke on layouts where digits need a modifier
    /// (§4.7). Same lesson applies here.
    static func keyName(for keyCode: UInt32) -> String {
        if let named = namedKeys[Int(keyCode)] { return named }
        return String(format: "Key %d", Int(keyCode))
    }

    private static let namedKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "esc",
        kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    /// True for the default ⌘/ so Preferences can warn about the editor clash.
    var isDefaultInlineSearch: Bool { self == Self.inlineSearchDefault }

    var isDefaultAIPalette: Bool { self == Self.aiPaletteDefault }
}

// MARK: - Persistence

/// §4.2 / §4.3: everything hotkey-shaped that used to have no UI and no
/// defaults key of its own.
enum HotkeyPreferences {
    static let inlineSearchKey = "devtype.hotkey.inlineSearch"
    static let aiPaletteKey = "devtype.hotkey.aiPalette"
    static let macrosKey = "devtype.hotkeyMacros"

    static var inlineSearchShortcut: DevTypeShortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: inlineSearchKey),
                  let decoded = try? JSONDecoder().decode(DevTypeShortcut.self, from: data),
                  decoded.hasModifier else {
                return .inlineSearchDefault
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: inlineSearchKey)
        }
    }

    static func resetInlineSearchShortcut() {
        UserDefaults.standard.removeObject(forKey: inlineSearchKey)
    }

    static var aiPaletteShortcut: DevTypeShortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: aiPaletteKey),
                  let decoded = try? JSONDecoder().decode(DevTypeShortcut.self, from: data),
                  decoded.hasModifier else {
                return .aiPaletteDefault
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: aiPaletteKey)
        }
    }

    static func resetAIPaletteShortcut() {
        UserDefaults.standard.removeObject(forKey: aiPaletteKey)
    }

    /// §4.3: the macro list was readable only by hand-crafting JSON into
    /// `devtype.hotkeyMacros`. Writing goes through here so the Preferences UI
    /// and `HotkeyManager.loadMacros()` agree on the wire format.
    static func saveMacros(_ macros: [HotkeyMacroAction]) {
        let encodable = macros.map {
            StoredMacro(
                keyCode: $0.keyCode,
                modifiers: $0.modifiers,
                kind: $0.kind.rawValue,
                argument: $0.argument
            )
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: macrosKey)
    }

    /// Mirrors `HotkeyManager.CodableMacro` (which is private to that type).
    struct StoredMacro: Codable {
        var keyCode: UInt32
        var modifiers: UInt32
        var kind: String
        var argument: String
    }
}

// MARK: - Recorder control

/// A small `NSView` that captures one key-down plus modifier flags.
///
/// Click (or press Space/Return when focused) to arm, then press the
/// combination. `esc` cancels. A key without any modifier is rejected — a bare
/// global hotkey would swallow that key in every app.
final class ShortcutRecorderView: NSView {
    /// Fires with the newly recorded shortcut, or `nil` when cleared.
    var onChange: ((DevTypeShortcut?) -> Void)?

    private(set) var shortcut: DevTypeShortcut? {
        didSet { needsDisplay = true; refreshAccessibility() }
    }

    private var isRecording = false {
        didSet { needsDisplay = true; refreshAccessibility() }
    }

    private let loc = LocalizationManager.shared

    init(shortcut: DevTypeShortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        focusRingType = .default
        layer?.cornerRadius = DevTypeTheme.Radius.control
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            heightAnchor.constraint(equalToConstant: 26)
        ])
        refreshAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setShortcut(_ newValue: DevTypeShortcut?) {
        shortcut = newValue
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    // MARK: Capture

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While armed the control owns every combination, including ones the
        // menu would otherwise claim (⌘Q, ⌘W…). That is the whole point of a
        // recorder — otherwise you could never bind them.
        guard isRecording, window?.firstResponder === self else { return false }
        return capture(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            // Space / Return arms the recorder for keyboard-only users.
            if Int(event.keyCode) == kVK_Space || Int(event.keyCode) == kVK_Return {
                isRecording = true
                return
            }
            super.keyDown(with: event)
            return
        }
        if !capture(event) { super.keyDown(with: event) }
    }

    private func capture(_ event: NSEvent) -> Bool {
        let code = Int(event.keyCode)
        if code == kVK_Escape {
            isRecording = false
            return true
        }
        if code == kVK_Delete || code == kVK_ForwardDelete,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            isRecording = false
            shortcut = nil
            onChange?(nil)
            return true
        }
        let carbon = DevTypeShortcut.carbonModifiers(from: event.modifierFlags)
        guard carbon != 0 else {
            // Reject a bare key and stay armed so the user can add a modifier.
            NSSound.beep()
            return true
        }
        let recorded = DevTypeShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
        isRecording = false
        shortcut = recorded
        onChange?(recorded)
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        DevTypeTheme.contrastOverlay(0.07).setFill()
        path.fill()
        (isRecording ? DevTypeTheme.accent : DevTypeTheme.contrastOverlay(0.22)).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            text = loc.s("shortcut.recording")
            color = DevTypeTheme.accentBright
        } else if let shortcut {
            text = shortcut.displayString
            color = DevTypeTheme.textPrimary
        } else {
            text = loc.s("shortcut.record")
            color = DevTypeTheme.textTertiary
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DevTypeTheme.font(12, .medium),
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    // MARK: §5.1 accessibility

    private func refreshAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(NSAccessibility.Role.button)
        setAccessibilityLabel(loc.s("prefs.hotkeys.macros.shortcut"))
        if isRecording {
            setAccessibilityValue(loc.s("shortcut.recording"))
        } else {
            setAccessibilityValue(shortcut?.displayString ?? loc.s("shortcut.none"))
        }
        setAccessibilityHelp(loc.s("shortcut.help"))
    }
}
