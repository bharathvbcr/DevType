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

    /// - Parameters:
    ///   - needsCursorHID: retained for API compatibility and inject-path logging. **Not read**
    ///     — see the discards below. Defaulted so callers are not made to compute it: the
    ///     keystroke path used to render the entire snippet, macros and nested lookups
    ///     included, inside the CGEventTap callback purely to supply this and `isMultiLine`.
    ///   - isMultiLine: same; also not read.
    public func plan(
        snapshot: PermissionSnapshot,
        isTerminal: Bool,
        needsCursorHID: Bool = false,
        isMultiLine: Bool = false
    ) -> InjectionPlan {
        if !snapshot.canUseAX {
            return .refuse(reason: "Accessibility unavailable — refusing expand (fail-closed)")
        }

        if snapshot.canPostEvents {
            // Shell-like contexts take the clipboard path on the inject side (the ⌘V needs Post);
            // multi-line is allowed with Post.
            return .axPlusHID
        }

        // AX without Post: no HID, so no ⌘V — and a terminal has no other usable write path.
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
    ///
    /// §1.6: both lengths here are **UTF-16 code units**, which is the right unit for the
    /// AX caret path (`kAXSelectedTextRange` ranges are UTF-16). It is *not* the unit HID
    /// arrows move in — a posted `kVK_LeftArrow` moves one **grapheme cluster**, so an emoji
    /// or astral CJK character after `{{cursor}}` used to be over-counted. This function only
    /// answers "is there anything to the right of the caret?", which is unit-agnostic; the
    /// UTF-16 → grapheme conversion for the arrow count itself lives in
    /// `HIDKeyPoster.leftArrowCount(text:utf16OffsetFromEnd:)`.
    public static func needsCursorHID(cursorOffset: Int?, totalUTF16Length: Int) -> Bool {
        guard let offset = cursorOffset, offset <= totalUTF16Length else { return false }
        return (totalUTF16Length - offset) > 0
    }

    /// Compatibility overload using Character-count total (converts via UTF-16 when text is available).
    public static func needsCursorHID(cursorOffset: Int?, totalLength: Int) -> Bool {
        needsCursorHID(cursorOffset: cursorOffset, totalUTF16Length: totalLength)
    }
}

// MARK: - Write-route policy (pure; formerly on TextInjectionPipeline)

extension InjectionPlanner {
    /// What to do with a rendered expansion before any erase.
    /// An empty body with no caret marker must not delete the trigger. An empty body that exists
    /// only to place the caret erases the trigger and must not follow that with an empty paste.
    public enum EmptyExpansionDecision: Equatable {
        case refuse
        case eraseOnly
        case insert
    }

    public static func emptyExpansionDecision(text: String, cursorOffset: Int?) -> EmptyExpansionDecision {
        guard text.isEmpty else { return .insert }
        if let cursorOffset, cursorOffset >= 0 { return .eraseOnly }
        return .refuse
    }

    /// How to put `text` into the field once the trigger is gone.
    public enum AfterEraseInsert: Equatable {
        case nothing
        case unicode
        case clipboard
    }

    public static func insertAfterErase(
        bundleID: String?,
        text: String,
        shellLike: Bool = false
    ) -> AfterEraseInsert {
        if text.isEmpty { return .nothing }
        // A terminal accepts ⌘V. A typed newline is not the Return key, so it would not
        // submit a command and may not break the line in the pty.
        if shellLike { return .clipboard }
        let id = bundleID ?? ""
        if AXWriteCapabilityStore.swallowsSyntheticPaste(bundleID: id),
           HIDKeyPoster.unicodeInsertEvents(for: text) != nil {
            return .unicode
        }
        return .clipboard
    }

    /// Whether this inject may touch the field through AX (range replace, then direct set) before
    /// falling back to the clipboard.
    ///
    /// Two exclusions, and they are the same for both AX write sites — which is why this is one
    /// function rather than a repeated `!a && !b` that can drift apart:
    ///
    /// - `shellLike`: a terminal's AX mirror is a rendered screen, not an editable field. A write
    ///   against it either fails or "succeeds" without reaching the pty.
    /// - `preferHID`: this `(bundle, role)` has been condemned as a false-success AX host.
    ///
    /// Terminals reaching the clipboard path is load-bearing beyond AX: the pasteboard payload is
    /// the snippet text byte for byte, because the terminal — not DevType — owns bracketed paste.
    public static func mayWriteViaAX(shellLike: Bool, preferHID: Bool) -> Bool {
        !shellLike && !preferHID
    }
}
