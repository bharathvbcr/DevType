// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

public enum RunningAppCheck {
    public static func isTextExpander(bundleID: String?, name: String?) -> Bool {
        if let b = bundleID?.lowercased(), b.contains("textexpander") { return true }
        if let n = name?.lowercased(), n.contains("textexpander") { return true }
        return false
    }

    public static func isEspanso(bundleID: String?, name: String?) -> Bool {
        if let b = bundleID?.lowercased(), b.contains("espanso") { return true }
        if let n = name?.lowercased(), n.contains("espanso") { return true }
        return false
    }
}
