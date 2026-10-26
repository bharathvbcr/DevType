import Foundation

/// Fixed identities the harness checks against. Nothing here is discovered at run time: a harness
/// that accepted "whatever DevType is running" could type into the wrong app.
public enum HarnessConstants {
    public static let devTypeBundleID = "com.devtype.app"
    public static let installedAppPath = "/Applications/DevType.app"
    public static let safariBundleID = "com.apple.Safari"
    /// DevType's preferences domain. Read with CFPreferences, never `UserDefaults.standard`, which
    /// would be this tool's own domain.
    public static let devTypeDefaultsDomain = "com.devtype.app"
    public static let defaultTrigger = ";dtharness"
    public static let defaultExpansion = "[[DT-HARNESS-OK-7Q4X]]"
    public static let pageTitle = "DevType Live Harness"
    public static let domPrefix = "dth-"
    public static let fixtureRelativePath = "Tests/Fixtures/SafariHarness/safari-harness.html"
    public static let logSubsystem = "com.devtype.app"

    // DevType's own defaults keys (DevTypeAppCore/ShortcutRecorder.swift, AIPreferences).
    public static let storeLocationKey = "devtype.storeFileURL"
    public static let aiPaletteHotkeyKey = "devtype.hotkey.aiPalette"
    public static let hotkeysDisabledKey = "devtype.hotkeys.disabled"
    public static let aiEnabledKey = "devtype.ai.enabled"
    public static let prefixDebounceKey = "DevTypePrefixDebounceMs"
}

/// Every control on the fixture page. The raw value is the DOM id, which is also its aria-label.
public enum PageField: String, CaseIterable, Sendable {
    case plain = "dth-plain"
    case area = "dth-area"
    case editable = "dth-editable"
    case rerender = "dth-rerender"
    case spaImmediateA = "dth-spa-immediate-a"
    case spaImmediateB = "dth-spa-immediate-b"
    case spaDelayedA = "dth-spa-delayed-a"
    case spaDelayedB = "dth-spa-delayed-b"
    case password = "dth-password"
    case ai = "dth-ai"
    case reset = "dth-reset"

    public var domID: String { rawValue }

    /// Fields a case may type into. The reset button is a press target, never a typing target.
    public var acceptsTyping: Bool { self != .reset }
}

public enum Modifier: String, Sendable, CaseIterable {
    case shift, option, control, command

    public var keyCode: UInt16 {
        switch self {
        case .command: return 55
        case .shift: return 56
        case .option: return 58
        case .control: return 59
        }
    }

    public var mask: ModifierMask {
        switch self {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        }
    }
}

/// Same bit values as `CGEventFlags`, kept here so this target's logic stays free of CoreGraphics.
public struct ModifierMask: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let shift = ModifierMask(rawValue: 0x0002_0000)
    public static let control = ModifierMask(rawValue: 0x0004_0000)
    public static let option = ModifierMask(rawValue: 0x0008_0000)
    public static let command = ModifierMask(rawValue: 0x0010_0000)

    public var names: [String] {
        var out: [String] = []
        if contains(.control) { out.append("control") }
        if contains(.option) { out.append("option") }
        if contains(.shift) { out.append("shift") }
        if contains(.command) { out.append("command") }
        return out
    }
}
