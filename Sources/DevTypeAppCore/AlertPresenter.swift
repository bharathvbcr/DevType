import AppKit
import ExpanderEngine

// MARK: - §4.8 — one place to build an NSAlert
//
// There were 17 hand-rolled `NSAlert`s across `AppDelegate` (:553, 567, 583, 597,
// 608, 622, 829, 844, 871, 879, 886) and `SnippetManagerViewController` (:656,
// 854, 886), each re-deciding style, button order, sheet-vs-modal, and whether
// its title was localized. `showMutedApps` went further and decoded the user's
// choice by subtracting `alertFirstButtonReturn` from the response — which
// breaks the moment there are more than three muted apps (§4.8, now replaced by
// the real list in Preferences).
//
// `DevTypeAlert` collapses all of that into four call shapes. Everything is
// localized through `LocalizationManager` and every entry point takes an
// optional host window so sheets stay sheets.

enum DevTypeAlert {

    /// Informational alert with a single OK button.
    static func info(
        title: String,
        message: String,
        window: NSWindow? = nil,
        completion: (() -> Void)? = nil
    ) {
        present(
            title: title,
            message: message,
            style: .informational,
            buttons: [LocalizationManager.shared.s("common.ok")],
            window: window
        ) { _ in completion?() }
    }

    /// Warning alert with a single OK button.
    static func warn(
        title: String,
        message: String,
        window: NSWindow? = nil,
        completion: (() -> Void)? = nil
    ) {
        present(
            title: title,
            message: message,
            style: .warning,
            buttons: [LocalizationManager.shared.s("common.ok")],
            window: window
        ) { _ in completion?() }
    }

    /// Two-button confirmation. `confirm` is the first (default) button;
    /// `destructive` marks it red.
    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String? = nil,
        destructive: Bool = false,
        style: NSAlert.Style = .warning,
        window: NSWindow? = nil,
        onConfirm: @escaping () -> Void
    ) {
        let cancel = cancelTitle ?? LocalizationManager.shared.s("common.cancel")
        present(
            title: title,
            message: message,
            style: style,
            buttons: [confirmTitle, cancel],
            destructiveFirstButton: destructive,
            window: window
        ) { index in
            if index == 0 { onConfirm() }
        }
    }

    /// General N-button alert. `handler` receives the **index into `buttons`**,
    /// never a raw `NSApplication.ModalResponse` — the index arithmetic that used
    /// to live at every call site now lives here once.
    ///
    /// Keep `buttons` to four or fewer; anything list-shaped belongs in a real
    /// list UI (see the Muted Apps table in Preferences).
    static func present(
        title: String,
        message: String,
        style: NSAlert.Style = .informational,
        buttons: [String],
        destructiveFirstButton: Bool = false,
        window: NSWindow? = nil,
        handler: ((Int) -> Void)? = nil
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        let titles = buttons.isEmpty ? [LocalizationManager.shared.s("common.ok")] : buttons
        for buttonTitle in titles {
            alert.addButton(withTitle: buttonTitle)
        }
        if destructiveFirstButton {
            alert.buttons.first?.hasDestructiveAction = true
        }

        let resolve: (NSApplication.ModalResponse) -> Int = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < titles.count else { return -1 }
            return index
        }

        if let window {
            alert.beginSheetModal(for: window) { response in
                handler?(resolve(response))
            }
        } else {
            let response = alert.runModal()
            handler?(resolve(response))
        }
    }
}
