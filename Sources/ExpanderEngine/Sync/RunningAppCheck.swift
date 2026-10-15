// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// One other expander we recognise by a substring of its bundle id or process name.
public struct CompetitorApp: Sendable, Equatable {
    public let needle: String
    public let alertTitleKey: String
    public let alertMessageKey: String

    public func matches(bundleID: String?, name: String?) -> Bool {
        if let bundleID, bundleID.lowercased().contains(needle) { return true }
        if let name, name.lowercased().contains(needle) { return true }
        return false
    }
}

public enum RunningAppCheck {
    public static let textExpander = CompetitorApp(
        needle: "textexpander",
        alertTitleKey: "alert.textExpander.title",
        alertMessageKey: "menu.textExpanderWarning"
    )
    public static let espanso = CompetitorApp(
        needle: "espanso",
        alertTitleKey: "alert.espanso.title",
        alertMessageKey: "menu.espansoWarning"
    )

    /// The expanders `AppDelegate` warns about at launch. Add a row here rather than
    /// another `isX` / `warnIfX` pair.
    public static let warnedAtLaunch: [CompetitorApp] = [textExpander, espanso]

    public static func isTextExpander(bundleID: String?, name: String?) -> Bool {
        textExpander.matches(bundleID: bundleID, name: name)
    }

    public static func isEspanso(bundleID: String?, name: String?) -> Bool {
        espanso.matches(bundleID: bundleID, name: name)
    }
}
