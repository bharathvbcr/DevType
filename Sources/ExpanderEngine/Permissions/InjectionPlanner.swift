import Foundation

/// Chooses AX-only / AX+HID / refuse based on capability snapshot + inject context.
public enum InjectionPlan: Equatable {
    /// Refuse expand entirely (fail-closed). Caller must not swallow the trigger key.
    case refuse(reason: String)
    /// AX range/direct replace only — no HID backspace, paste, or arrows.
    case axOnly
    /// Full path: AX preferred, HID backspace/paste/cursor allowed.
    case axPlusHID
}

public struct InjectionPlanner: Sendable {
    public init() {}

    public func plan(
        snapshot: PermissionSnapshot,
        isTerminal: Bool,
        needsCursorHID: Bool,
        isMultiLine: Bool = false
    ) -> InjectionPlan {
        if !snapshot.canUseAX {
            return .refuse(reason: "Accessibility unavailable — refusing expand (fail-closed)")
        }

        if snapshot.canPostEvents {
            // Shell-like contexts get bracket-paste on the inject path; multi-line is allowed with Post.
            return .axPlusHID
        }

        // AX without Post: no HID. Terminal / bracket-paste needs Post.
        if isTerminal {
            return .refuse(reason: "Post Events missing — terminal / shell-like paste unsupported")
        }

        // Non-shell: multi-line via AX selected-text replace; caret via AX selected-text range.
        // `needsCursorHID` / `isMultiLine` are retained for API compat and inject-path logging;
        // they are not refuse gates when AX caret + range replace are available.
        _ = needsCursorHID
        _ = isMultiLine
        return .axOnly
    }

    /// Pure helper: whether a snippet resolution wants caret placement after inject
    /// (AX caret first; HID arrows only when Post is available).
    /// Lengths are UTF-16 code units (AX / HID arrow counts).
    public static func needsCursorHID(cursorOffset: Int?, totalUTF16Length: Int) -> Bool {
        guard let offset = cursorOffset, offset <= totalUTF16Length else { return false }
        return (totalUTF16Length - offset) > 0
    }

    /// Compatibility overload using Character-count total (converts via UTF-16 when text is available).
    public static func needsCursorHID(cursorOffset: Int?, totalLength: Int) -> Bool {
        needsCursorHID(cursorOffset: cursorOffset, totalUTF16Length: totalLength)
    }
}
