import AppKit

/// A borderless panel that can still take key focus.
///
/// Six panels each declared a private copy of this two-line subclass. The only axis they
/// ever differed on is main-window status: the macro palette and the template picker
/// refuse it so the window behind them keeps it, everything else takes it.
final class KeyablePanel: NSPanel {
    /// Set immediately after construction, before the panel is ordered front — nothing
    /// consults `canBecomeMain` until then.
    var takesMainWindowStatus = true

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { takesMainWindowStatus }
}

/// Top-left origin, so a stack laid out inside a scroll view reads top-to-bottom.
///
/// Four files declared their own one-line copy of this (`FillInFlippedDocumentView`,
/// `FlippedDocumentView` twice, `PrefsFlippedView`).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The outside-interaction dismissal watchers every floating panel installs.
///
/// Four panels carried a byte-identical copy of the install/remove pair plus the two
/// `dismissMonitors` / `dismissObservers` arrays behind it. The pair is not trivial —
/// it has to cover local clicks, global clicks *and* key loss, and the key-loss observer
/// has to be deferred a runloop turn and then re-checked, because the panel is not yet
/// key at install time and would otherwise dismiss itself the moment it appeared. Owning
/// that once means a fix to it lands everywhere instead of in whichever copy was noticed.
///
/// A reference type, not a value: the deferred key-loss observer is appended from an
/// escaping closure a runloop turn later, which a mutating struct method cannot do.
final class PanelDismissWatchers {
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - isStillCurrent: re-checked on the next runloop turn; the deferred key-loss
    ///     observer is skipped when the caller has already moved on to another panel.
    ///   - dismiss: what an outside interaction means for this panel. Callers guard their
    ///     own "am I still open" state inside it, exactly as the copies did.
    func install(
        for panel: NSPanel,
        isStillCurrent: @escaping () -> Bool,
        dismiss: @escaping () -> Void
    ) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        let local = NSEvent.addLocalMonitorForEvents(matching: clicks) { event in
            if event.window !== panel { dismiss() }
            return event
        }
        if let local { monitors.append(local) }

        let global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { _ in
            dismiss()
        }
        if let global { monitors.append(global) }

        DispatchQueue.main.async {
            guard isStillCurrent() else { return }
            self.observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: panel,
                    queue: .main
                ) { _ in dismiss() }
            )
        }
    }

    func removeAll() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}

/// Presentation shared by the free-floating spotlight-style panels.
enum FloatingPanelChrome {
    /// Fades and settles the panel into its final frame, or lands it immediately when the
    /// user has asked for reduced motion.
    static func animateIn(_ panel: NSPanel) {
        let finalFrame = panel.frame
        guard !DevTypeAccessibility.reduceMotion else {
            panel.alphaValue = 1
            panel.setFrame(finalFrame, display: true)
            return
        }
        let startFrame = finalFrame.insetBy(dx: 12, dy: 8).offsetBy(dx: 0, dy: -10)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    /// Upper third of whichever screen the pointer is on — Spotlight's placement, and the
    /// one place the user is already looking. Falls back to centering when no screen
    /// answers, which is the state during a display reconfiguration.
    static func positionNearTop(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - frame.height / 3 - size.height / 2
        ))
    }
}

// MARK: - Fixed-size panels

extension NSWindow {
    /// Holds a fixed-size panel at exactly `size`, in the one place that actually holds.
    ///
    /// Under Auto Layout a window keeps its current size only at
    /// `NSLayoutConstraint.Priority.windowSizeStayPut` (500). Every label's intrinsic width resists
    /// compression at 750 by default, so a single label fed by user text — a conflict message, a
    /// long trigger, a group name in a popup — wins that contest and *widens the window* instead
    /// of truncating. `contentMinSize` / `contentMaxSize` take no part in the constraint solve;
    /// they bound the user's drag and `setContentSize`, which is why the snippet editor kept
    /// growing as you typed with both of them set.
    ///
    /// Required width and height constraints on the content view do take part, and they outrank
    /// every optional intrinsic size, so overflowing text is compressed and truncated where it
    /// sits and the footer never leaves the panel. Call once the content view is installed.
    func dtLockContentSize(_ size: NSSize) {
        contentMinSize = size
        contentMaxSize = size
        guard let contentView else {
            assertionFailure("dtLockContentSize(_:) must run after the content view is installed")
            return
        }
        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: size.width),
            contentView.heightAnchor.constraint(equalToConstant: size.height)
        ])
    }
}
