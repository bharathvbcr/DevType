import AppKit
import ExpanderEngine

/// In-app inject lab: focuses a controlled NSTextView and runs the real inject pipeline.
/// Proves AX (and optional HID) delivery without requiring Notes/TextEdit.
enum TestExpansionLab {
    /// Presents a sheet (or panel) with a lab field, injects `:test` (or fallback), and reports the outcome.
    static func run(from hostWindow: NSWindow?) {
        // §6.1: this file had zero `loc.s` calls — 308 lines of English shown to
        // a user who may not have got the app working yet.
        let loc = LocalizationManager.shared
        let snippets = SnippetStore.shared.loadSnippets()
        let snippet = snippets.first { $0.triggerKeyword == ":test" }
            ?? SnippetModel(title: "Test", triggerKeyword: ":test", replacementText: "DevType OK")
        let resolved = DynamicTemplateEngine.shared.resolve(snippet.replacementText)
        let snapshot = PermissionProbe().snapshot()
        let shellLike = AXContextChecker.shared.isFrontmostShellLikeContext()
        let plan = InjectionPlanner().plan(
            snapshot: snapshot,
            isTerminal: shellLike,
            needsCursorHID: InjectionPlanner.needsCursorHID(
                cursorOffset: resolved.cursorOffset,
                totalUTF16Length: resolved.text.utf16.count
            ),
            isMultiLine: resolved.text.contains(where: \.isNewline)
        )
        let planLabel: String
        switch plan {
        case .axPlusHID: planLabel = loc.s("lab.plan.axhid")
        case .axOnly: planLabel = loc.s("lab.plan.axonly")
        case .refuse(let reason): planLabel = loc.s("lab.plan.refused", reason)
        }

        if case .refuse(let reason) = plan {
            let yes = loc.s("lab.yes")
            let no = loc.s("lab.no")
            presentResult(
                hostWindow: hostWindow,
                title: loc.s("lab.refused.title"),
                body: loc.s(
                    "lab.refused.body",
                    snippet.triggerKeyword,
                    planLabel,
                    reason,
                    snapshot.canListenTap ? yes : no,
                    snapshot.canUseAX ? yes : no,
                    snapshot.canPostEvents ? yes : no,
                    EventTapEngine.shared.isTapRunning
                        ? loc.s("lab.tap.running")
                        : loc.s("lab.tap.stopped")
                ),
                style: .warning
            )
            DevTypeLog.inject.notice(
                "[Inject] Test Expansion lab refused plan=\(planLabel, privacy: .public)"
            )
            return
        }

        let session = LabSession(
            snippet: snippet,
            expected: resolved.text,
            plan: plan,
            planLabel: planLabel,
            hostWindow: hostWindow
        )
        session.present()
    }

    private static func presentResult(
        hostWindow: NSWindow?,
        title: String,
        body: String,
        style: NSAlert.Style
    ) {
        // §4.8: routed through the shared helper.
        if style == .informational {
            DevTypeAlert.info(title: title, message: body, window: hostWindow)
        } else {
            DevTypeAlert.warn(title: title, message: body, window: hostWindow)
        }
    }
}

/// Retains itself while the lab panel is open.
private final class LabSession: NSObject {
    private let snippet: SnippetModel
    private let expected: String
    private let plan: InjectionPlan
    private let planLabel: String
    private weak var hostWindow: NSWindow?

    private var panel: NSPanel?
    private var textView: NSTextView?
    private var statusLabel: NSTextField?
    /// Self-retain until Close.
    private var retainSelf: LabSession?
    /// Fires `close()` for every dismissal of the panel — including the red
    /// traffic light, which never reaches the Close button. Without it a closed
    /// lab leaked the retained session *and* its `NSPanel` (`isReleasedWhenClosed`
    /// is false) for the rest of the launch.
    private var closeObserver: NSObjectProtocol?

    init(
        snippet: SnippetModel,
        expected: String,
        plan: InjectionPlan,
        planLabel: String,
        hostWindow: NSWindow?
    ) {
        self.snippet = snippet
        self.expected = expected
        self.plan = plan
        self.planLabel = planLabel
        self.hostWindow = hostWindow
        super.init()
    }

    private let loc = LocalizationManager.shared

    func present() {
        retainSelf = self

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        DevTypeTheme.styleWindow(panel, title: loc.s("window.lab"))
        self.panel = panel

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        container.wantsLayer = true
        container.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        let badge = IconBadgeView(symbol: "bolt.fill", tint: DevTypeTheme.accent, size: 30, pointSize: 13)
        badge.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(wrappingLabelWithString: loc.s("lab.caption", planLabel))
        caption.font = DevTypeTheme.font(11)
        caption.textColor = DevTypeTheme.textSecondary
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.preferredMaxLayoutWidth = 400

        let editorBlock = NSView()
        editorBlock.wantsLayer = true
        editorBlock.translatesAutoresizingMaskIntoConstraints = false
        editorBlock.layer?.cornerRadius = 10
        editorBlock.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        editorBlock.layer?.borderWidth = 1
        editorBlock.layer?.borderColor = DevTypeTheme.hairline.cgColor

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = DevTypeTheme.mono(13)
        textView.textColor = DevTypeTheme.textPrimary
        textView.backgroundColor = .clear
        textView.insertionPointColor = DevTypeTheme.accentBright
        textView.string = ""
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        self.textView = textView

        editorBlock.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: editorBlock.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: editorBlock.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: editorBlock.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: editorBlock.bottomAnchor, constant: -4)
        ])

        let statusLabel = NSTextField(labelWithString: loc.s("lab.focusing"))
        statusLabel.font = DevTypeTheme.font(11, .medium)
        statusLabel.textColor = DevTypeTheme.accentBright
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        self.statusLabel = statusLabel

        // §5.1: the lab's text view is the whole point of the panel — name it.
        textView.setAccessibilityLabel(loc.s("lab.caption", planLabel))
        statusLabel.setAccessibilityLabel(loc.s("window.lab"))

        let closeButton = CapsuleButton(
            title: loc.s("common.close"),
            style: .secondary,
            target: self,
            action: #selector(close)
        )
        closeButton.keyEquivalent = "\u{1b}"

        container.addSubview(badge)
        container.addSubview(caption)
        container.addSubview(editorBlock)
        container.addSubview(statusLabel)
        container.addSubview(closeButton)
        panel.contentView = container

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            badge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),

            caption.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            caption.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            caption.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            editorBlock.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 14),
            editorBlock.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            editorBlock.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            editorBlock.heightAnchor.constraint(equalToConstant: 150),

            statusLabel.topAnchor.constraint(equalTo: editorBlock.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),

            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            closeButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            closeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])

        if let hostWindow {
            hostWindow.beginSheet(panel, completionHandler: nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Mirror the AppDelegate Setup-window pattern: one block-based observer,
        // replaced (here: removed) on close, so the window closing by any route
        // funnels into the same teardown as the Close button. Double-close is
        // idempotent — the observer is removed before `panel.close()` re-enters.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in self?.close() }

        // Focus lab field, then inject with eraseCount=0 (empty field).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(textView)
            textView.window?.makeFirstResponder(textView)
            statusLabel.stringValue = self.loc.s("lab.injecting")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                TextInjectionPipeline.shared.inject(
                    snippet: self.snippet,
                    triggerLength: 0,
                    clipboardOverride: nil,
                    swallowedFinalKey: false,
                    lastEventCharacterCount: 0,
                    plan: self.plan,
                    completion: { [weak self] in
                        DispatchQueue.main.async {
                            self?.evaluateResult()
                        }
                    }
                )
            }
        }
    }

    private func evaluateResult() {
        guard let textView, let statusLabel else { return }
        let actual = textView.string
        let outcome = PermissionCoordinator.shared.lastRecordedInjectOutcome
        let outcomeLabel: String
        switch outcome {
        case .succeeded: outcomeLabel = loc.s("lab.outcome.succeeded")
        case .postedUnverified: outcomeLabel = loc.s("lab.outcome.posted")
        case .degradedAXOnly: outcomeLabel = loc.s("lab.outcome.degraded")
        case .failedSilent: outcomeLabel = loc.s("lab.outcome.failed")
        case .refused(let reason): outcomeLabel = loc.s("lab.outcome.refused", reason)
        case .none: outcomeLabel = loc.s("lab.outcome.unknown")
        }

        let matched = actual == expected
            || actual.hasSuffix(expected)
            || (!expected.isEmpty && actual.contains(expected))

        if matched {
            statusLabel.stringValue = loc.s("lab.ok", outcomeLabel)
            statusLabel.textColor = DevTypeTheme.greenStatus
            DevTypeLog.inject.info(
                "[Inject] Test Expansion lab OK plan=\(self.planLabel, privacy: .public) outcome=\(outcomeLabel, privacy: .public)"
            )
        } else {
            statusLabel.stringValue = loc.s("lab.mismatch", outcomeLabel)
            statusLabel.textColor = DevTypeTheme.redBright
            DevTypeLog.inject.error(
                "[Inject] Test Expansion lab MISMATCH plan=\(self.planLabel, privacy: .public) outcome=\(outcomeLabel, privacy: .public) actualLen=\(actual.count, privacy: .public)"
            )
        }
    }

    @objc func close() {
        // Remove first: `panel.close()` below fires willClose synchronously and the
        // observer would re-enter this method mid-teardown.
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        if let host = hostWindow, let panel, panel.isSheet {
            host.endSheet(panel)
        }
        panel?.close()
        panel = nil
        textView = nil
        statusLabel = nil
        retainSelf = nil
    }
}
