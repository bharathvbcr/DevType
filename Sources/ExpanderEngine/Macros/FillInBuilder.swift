// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// Builds TextExpander fill-in macro strings from typed parameters.
public enum FillInBuilder {

    private static func sanitizeToken(_ token: String) -> String {
        token.filter { $0 != ":" && $0 != "%" }
    }

    private static func sanitizeDefault(_ value: String) -> String {
        value.filter { $0 != "%" }
    }

    public static func defaultValueIsRepresentable(_ value: String) -> Bool {
        !value.contains("%")
    }

    public static func nameOrOptionIsRepresentable(_ token: String) -> Bool {
        !token.contains(":") && !token.contains("%")
    }

    public static func fillText(name: String, defaultValue: String) -> String {
        let n = sanitizeToken(name)
        let d = sanitizeDefault(defaultValue)
        return d.isEmpty ? "%filltext:name=\(n)%" : "%filltext:name=\(n):default=\(d)%"
    }

    public static func fillArea(name: String, defaultValue: String) -> String {
        let n = sanitizeToken(name)
        let d = sanitizeDefault(defaultValue)
        return d.isEmpty ? "%fillarea:name=\(n)%" : "%fillarea:name=\(n):default=\(d)%"
    }

    public static func fillPopup(name: String, options: [String], defaultValue: String) -> String {
        let n = sanitizeToken(name)
        let opts = options.map(sanitizeToken).filter { !$0.isEmpty }
        let d = sanitizeDefault(defaultValue)
        var body = "name=\(n)"
        for o in opts { body += ":\(o)" }
        if !d.isEmpty { body += ":default=\(d)" }
        return "%fillpopup:\(body)%"
    }

    public static func fillPart(name: String, includeByDefault: Bool, content: String) -> String {
        let n = sanitizeToken(name)
        let flag = includeByDefault ? "yes" : "no"
        return "%fillpart:name=\(n):default=\(flag)%\(content)%fillpartend%"
    }
}
