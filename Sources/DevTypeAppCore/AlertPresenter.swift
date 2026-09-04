import AppKit
import ExpanderEngine

/// A bounded `NSAlert` variant for remote or otherwise unbounded text.
///
/// `NSAlert.informativeText` participates in the alert's intrinsic height. Putting release notes
/// there can push every response button off-screen. This wrapper keeps only the short summary in
/// that region and places the complete long-form body in a fixed-height scroll view. Its explicit
/// top Close button ends both app-modal alerts and document-modal sheets with `.abort`.
@MainActor
final class DevTypeScrollableAlert: NSObject {
    static let accessorySize = NSSize(width: 520, height: 310)

    let alert: NSAlert

    init(
        title: String,
        message: String,
        scrollTitle: String,
        scrollableText: String,
        style: NSAlert.Style,
        buttons: [String]
    ) {
        alert = NSAlert()
        super.init()

        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        let titles = buttons.isEmpty
            ? [LocalizationManager.shared.s("common.ok")]
            : buttons
        for buttonTitle in titles {
            alert.addButton(withTitle: buttonTitle)
        }

        alert.accessoryView = makeAccessory(
            title: scrollTitle,
            text: scrollableText
        )
        alert.layout()
    }

    func present(
        window: NSWindow?,
        handler: ((Int) -> Void)?
    ) {
        let resolve: (NSApplication.ModalResponse) -> Int = { [alert] response in
            let index = response.rawValue
                - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < alert.buttons.count else { return -1 }
            return index
        }

        if let window {
            alert.beginSheetModal(for: window) { [self] response in
                handler?(resolve(response))
                _ = self
            }
        } else {
            let response = alert.runModal()
            alert.window.orderOut(nil)
            handler?(resolve(response))
        }
    }

    private func makeAccessory(title: String, text: String) -> NSView {
        let accessory = NSView(frame: NSRect(origin: .zero, size: Self.accessorySize))
        accessory.setAccessibilityRole(.group)

        let heading = DevTypeTheme.makeLabel(
            title,
            font: DevTypeTheme.font(13, .semibold),
            color: DevTypeTheme.textPrimary
        )
        heading.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = CapsuleButton(
            title: LocalizationManager.shared.s("common.close"),
            symbol: "xmark",
            style: .secondary,
            target: self,
            action: #selector(closeTapped)
        )
        closeButton.identifier = NSUserInterfaceItemIdentifier("updates.available.close")
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.toolTip = closeButton.title

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: Self.accessorySize.width, height: 270)
        )
        scrollView.identifier = NSUserInterfaceItemIdentifier("updates.available.releaseNotes")
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.string = text
        textView.font = DevTypeTheme.font(12.5, .regular)
        textView.textColor = DevTypeTheme.textPrimary
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(title)
        scrollView.documentView = textView

        accessory.addSubview(heading)
        accessory.addSubview(closeButton)
        accessory.addSubview(scrollView)

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: accessory.topAnchor),
            heading.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),
            heading.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            closeButton.topAnchor.constraint(equalTo: accessory.topAnchor),
            closeButton.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])
        accessory.layoutSubtreeIfNeeded()
        return accessory
    }

    @objc private func closeTapped() {
        let response = NSApplication.ModalResponse.abort
        let alertWindow = alert.window
        if let parent = alertWindow.sheetParent {
            parent.endSheet(alertWindow, returnCode: response)
        } else if NSApp.modalWindow === alertWindow {
            NSApp.stopModal(withCode: response)
        } else {
            alertWindow.orderOut(nil)
        }
    }
}

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
// `DevTypeAlert` collapses all of that into five call shapes. Everything is
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
        onCancel: (() -> Void)? = nil,
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
            if index == 0 {
                onConfirm()
            } else {
                onCancel?()
            }
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

    /// Alert with a bounded, scrollable body and an always-visible top Close button.
    @MainActor
    static func presentScrollable(
        title: String,
        message: String,
        scrollTitle: String,
        scrollableText: String,
        style: NSAlert.Style = .informational,
        buttons: [String],
        window: NSWindow? = nil,
        handler: ((Int) -> Void)? = nil
    ) {
        let presentation = DevTypeScrollableAlert(
            title: title,
            message: message,
            scrollTitle: scrollTitle,
            scrollableText: scrollableText,
            style: style,
            buttons: buttons
        )
        presentation.present(window: window, handler: handler)
    }
}

/// Lock-protected admission for user-initiated operations that must not overlap. The caller owns
/// the operation until `finish()`; a second caller can therefore present explicit feedback instead
/// of racing the same library or silently joining a queue.
final class SnippetOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    @discardableResult
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return false }
        active = true
        return true
    }

    func finish() {
        lock.lock()
        active = false
        lock.unlock()
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
}

/// Non-blocking, indeterminate progress presented with the same `NSAlert` vocabulary as the rest
/// of the app. There is deliberately no cancel button: parse, serialized library commit, and an
/// atomic filesystem replacement do not currently have an honest mid-operation cancellation
/// boundary. The source/destination panels and import preview retain their existing cancellation.
final class DevTypeProgressPresentation {
    private let alert: NSAlert
    private let spinner: NSProgressIndicator
    private var dismissed = false

    private init(alert: NSAlert, spinner: NSProgressIndicator) {
        self.alert = alert
        self.spinner = spinner
    }

    static func present(
        title: String,
        message: String,
        window: NSWindow?
    ) -> DevTypeProgressPresentation {
        precondition(Thread.isMainThread, "Progress presentation must be created on the main thread.")

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational

        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .regular
        spinner.setAccessibilityLabel(message)
        alert.accessoryView = spinner

        let presentation = DevTypeProgressPresentation(alert: alert, spinner: spinner)
        spinner.startAnimation(nil)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.window.level = .floating
            alert.window.center()
            alert.window.makeKeyAndOrderFront(nil)
        }
        return presentation
    }

    var isVisible: Bool { alert.window.isVisible }

    func dismiss() {
        precondition(Thread.isMainThread, "Progress presentation must be dismissed on the main thread.")
        guard !dismissed else { return }
        dismissed = true
        spinner.stopAnimation(nil)
        let progressWindow = alert.window
        if let parent = progressWindow.sheetParent {
            parent.endSheet(progressWindow)
        } else {
            progressWindow.orderOut(nil)
        }
    }
}
