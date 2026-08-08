import AppKit
import ExpanderEngine

/// A confirmation that goes away on its own.
///
/// This replaces the modal alert that used to follow a copy, which was wrong twice over. It made
/// the user dismiss a dialog to get on with a two-second task — and, worse, an alert activates
/// DevType, which takes focus *away from the password field they were about to paste into*. The
/// panel below never becomes key and never activates the app: it is a floating, non-activating
/// label that the user's next action dismisses.
///
/// Dismissed by whichever comes first: the timer, a click anywhere, a keystroke anywhere, an app
/// switch, or the next toast replacing it.
enum ToastPanel {

    /// Longest message the toast will lay out.
    ///
    /// Snippet titles are user text and can be arbitrarily long. A single-line label's *intrinsic*
    /// width counts toward a borderless window's fitting size, so an untruncated title would widen
    /// this panel off the edge of the screen — the same mechanism that was growing the snippet
    /// editor as you typed.
    static let messageLimit = 80

    /// How long a toast stays up when nothing else dismisses it.
    ///
    /// Long enough to read a short line and glance at the timer figure; short enough that it is
    /// gone by the time the user has switched apps and clicked into a field.
    static let defaultDuration: TimeInterval = 4.0

    private final class NonActivatingPanel: NSPanel {
        // Never key, never main: taking focus is the entire failure mode this replaces.
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static var panel: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?
    private static var monitors: [Any] = []
    private static var observers: [NSObjectProtocol] = []

    /// Show `message` (with an optional quieter second line) near the menu bar.
    static func show(
        _ message: String,
        detail: String? = nil,
        symbol: String = "checkmark.circle.fill",
        duration: TimeInterval = defaultDuration
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { show(message, detail: detail, symbol: symbol, duration: duration) }
            return
        }
        dismiss()

        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)
        // Above ordinary windows so it is visible over the app the user is heading back to, but
        // it never takes the click: `ignoresMouseEvents` keeps it out of the way entirely.
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        panel.contentView = makeContent(message: message, detail: detail, symbol: symbol)
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        installDismissWatchers()

        let work = DispatchWorkItem { dismiss() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    static func dismiss() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { dismiss() }
            return
        }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        removeDismissWatchers()

        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.close()
        }
    }

    // MARK: - Content

    private static func makeContent(message: String, detail: String?, symbol: String) -> NSView {
        let root = NSView()
        root.wantsLayer = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = DevTypeTheme.symbol(symbol, size: 18, weight: .semibold, color: DevTypeTheme.accent)
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = DevTypeTheme.makeLabel(
            clamped(message),
            font: DevTypeTheme.font(13, .semibold),
            color: DevTypeTheme.textPrimary
        )
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        // Truncate rather than demand room; see `messageLimit`. `lineBreakMode` alone does not do
        // it — the label still *asks* for its full intrinsic width, and the window grows to give it.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title])
        if let detail, !detail.isEmpty {
            let subtitle = DevTypeTheme.makeLabel(
                detail,
                font: DevTypeTheme.font(11),
                color: DevTypeTheme.textSecondary
            )
            subtitle.translatesAutoresizingMaskIntoConstraints = false
            subtitle.lineBreakMode = .byWordWrapping
            subtitle.maximumNumberOfLines = 2
            subtitle.cell?.wraps = true
            subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            subtitle.preferredMaxLayoutWidth = 380 - 16 - 20 - 12 - 16
            stack.addArrangedSubview(subtitle)
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(icon)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),

            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        return root
    }

    /// Character-counted, so a title ending in an emoji cannot be cut through its cluster.
    private static func clamped(_ text: String) -> String {
        text.count > messageLimit ? String(text.prefix(messageLimit)) + "…" : text
    }

    private static func position(_ panel: NSPanel) {
        // Under the menu bar on the screen with the pointer — the toast follows the click that
        // caused it, which on a multi-display setup is not necessarily the main screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: frame.maxX - size.width - 16,
                y: frame.maxY - size.height - 12
            )
        )
    }

    // MARK: - Dismissal

    private static func installDismissWatchers() {
        // The user doing anything at all is a better dismiss signal than the clock. Global
        // monitors observe without consuming, so the click that dismisses the toast still lands
        // in whatever app it was aimed at.
        let events: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel,
        ]
        // Hopped to the next runloop turn rather than run inline: `dismiss()` removes these
        // very monitors, and tearing down an event monitor from inside its own callback is asking
        // the handler block to be released while it is still executing.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in
            DispatchQueue.main.async { dismiss() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            DispatchQueue.main.async { dismiss() }
            return event
        }) {
            monitors.append(local)
        }
        for name in [
            NSApplication.didResignActiveNotification,
            NSApplication.didBecomeActiveNotification,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    dismiss()
                }
            )
        }
    }

    private static func removeDismissWatchers() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
