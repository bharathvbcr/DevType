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
        let resolved = MacroRenderer.expand(content: snippet.replacementText,
                                            lookup: NestedSnippetResolver(snippets: snippets, excludingSecrets: true).lookup)
        if let failure = resolved.failure {
            presentResult(hostWindow: hostWindow, title: loc.s("lab.refused.title"), body: failure.message, style: .warning)
            return
        }
        guard !resolved.needsFillIn else {
            presentResult(hostWindow: hostWindow, title: loc.s("lab.refused.title"),
                          body: "Fill in this snippet before using the expansion lab.", style: .warning)
            return
        }
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
            prepared: resolved,
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
    private let prepared: MacroExpansionResult
    private var expected: String { prepared.text }
    private let plan: InjectionPlan
    private let planLabel: String
    private weak var hostWindow: NSWindow?

    private var panel: NSPanel?
    private var textView: NSTextView?
    private var statusLabel: NSTextField?
    private weak var auditOutcomeRow: NSView?
    private weak var auditOutcomeTitleLabel: NSTextField?
    private weak var auditOutcomePill: PillBadgeView?
    /// Self-retain until Close.
    private var retainSelf: LabSession?
    /// Fires `close()` for every dismissal of the panel — including the red
    /// traffic light, which never reaches the Close button. Without it a closed
    /// lab leaked the retained session *and* its `NSPanel` (`isReleasedWhenClosed`
    /// is false) for the rest of the launch.
    private var closeObserver: NSObjectProtocol?

    init(
        snippet: SnippetModel,
        prepared: MacroExpansionResult,
        plan: InjectionPlan,
        planLabel: String,
        hostWindow: NSWindow?
    ) {
        self.snippet = snippet
        self.prepared = prepared
        self.plan = plan
        self.planLabel = planLabel
        self.hostWindow = hostWindow
        super.init()
    }

    private let loc = LocalizationManager.shared

    func present() {
        retainSelf = self

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 490),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        DevTypeTheme.styleWindow(panel, title: loc.s("window.lab"))
        self.panel = panel

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 490))
        container.wantsLayer = true
        container.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        let badge = IconBadgeView(symbol: "bolt.fill", tint: DevTypeTheme.accent, size: 30, pointSize: 13)
        badge.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(wrappingLabelWithString: loc.s("lab.caption", planLabel))
        caption.font = DevTypeTheme.font(11)
        caption.textColor = DevTypeTheme.textSecondary
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.preferredMaxLayoutWidth = 460

        let editorBlock = NSView()
        editorBlock.wantsLayer = true
        editorBlock.translatesAutoresizingMaskIntoConstraints = false
        editorBlock.layer?.cornerRadius = 8
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

        // MARK: - Audit Checklist Card
        let auditCard = makeAuditCard(editable: textView.isEditable)
        auditCard.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: loc.s("lab.focusing"))
        statusLabel.font = DevTypeTheme.font(11, .medium)
        statusLabel.textColor = DevTypeTheme.accentBright
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        self.statusLabel = statusLabel

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
        container.addSubview(auditCard)
        container.addSubview(statusLabel)
        container.addSubview(closeButton)
        panel.contentView = container
        // Titled but not resizable, and the caption quotes the snippet's plan label — hold it.
        panel.dtLockContentSize(container.frame.size)

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            badge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),

            caption.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            caption.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            caption.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            editorBlock.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 12),
            editorBlock.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            editorBlock.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            editorBlock.heightAnchor.constraint(equalToConstant: 95),

            auditCard.topAnchor.constraint(equalTo: editorBlock.bottomAnchor, constant: 12),
            auditCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            auditCard.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            statusLabel.topAnchor.constraint(equalTo: auditCard.bottomAnchor, constant: 12),
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
                    preResolvedText: self.prepared.text,
                    preResolvedCursorOffset: self.prepared.cursorOffset,
                    trailingKeys: self.prepared.trailingKeys,
                    completion: { [weak self] outcome in
                        DispatchQueue.main.async {
                            self?.evaluateResult(outcome: outcome)
                        }
                    }
                )
            }
        }
    }

    private func makeAuditCard(editable: Bool) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = DevTypeTheme.cardBackground.cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor

        let headerLabel = DevTypeTheme.makeLabel(
            loc.s("lab.audit.title"),
            font: DevTypeTheme.font(12, .semibold),
            color: DevTypeTheme.textPrimary
        )
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let snapshot = PermissionProbe().snapshot()
        let isSecure = SecureInputMonitor.shared.checkLockStatus().isLocked
        let lastOutcome = PermissionCoordinator.shared.lastRecordedInjectOutcome

        let row1 = makeAuditRow(
            title: loc.s("lab.audit.range"),
            status: snapshot.canUseAX ? loc.s("lab.yes") : loc.s("lab.no"),
            tint: snapshot.canUseAX ? DevTypeTheme.statusGreen : DevTypeTheme.accent
        )
        let row2 = makeAuditRow(
            title: loc.s("lab.audit.secure"),
            status: isSecure ? loc.s("home.status.secureInput") : loc.s("lab.secure.inactive"),
            tint: isSecure ? DevTypeTheme.statusOrange : DevTypeTheme.statusGreen
        )
        let row3 = makeAuditRow(
            title: loc.s("lab.audit.event"),
            status: snapshot.canPostEvents ? loc.s("lab.yes") : loc.s("lab.no"),
            tint: snapshot.canPostEvents ? DevTypeTheme.statusGreen : DevTypeTheme.accent
        )
        let row4 = makeAuditRow(
            title: loc.s("lab.audit.editable"),
            status: editable ? loc.s("lab.status.editable") : loc.s("lab.no"),
            tint: editable ? DevTypeTheme.statusGreen : DevTypeTheme.accent
        )
        let row5 = makeAuditRow(
            title: String(format: loc.s("lab.audit.path"), planLabel),
            status: loc.s("lab.status.selected"),
            tint: DevTypeTheme.statusBlue
        )
        let row6 = makeAuditRow(
            title: String(format: loc.s("lab.audit.lastOutcome"), outcomeString(lastOutcome)),
            status: outcomeString(lastOutcome),
            tint: lastOutcome?.isConfirmedSuccess == true
                ? DevTypeTheme.statusGreen
                : DevTypeTheme.statusOrange,
            capture: { [weak self] row, label, pill in
                self?.auditOutcomeRow = row
                self?.auditOutcomeTitleLabel = label
                self?.auditOutcomePill = pill
            }
        )

        let grid = NSStackView(views: [row1, row2, row3, row4, row5, row6])
        grid.orientation = .vertical
        grid.spacing = 6
        grid.alignment = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(headerLabel)
        card.addSubview(grid)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            headerLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),

            grid.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        return card
    }

    private func makeAuditRow(
        title: String,
        status: String,
        tint: NSColor,
        capture: ((NSView, NSTextField, PillBadgeView) -> Void)? = nil
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let lbl = DevTypeTheme.makeLabel(title, font: DevTypeTheme.font(11), color: DevTypeTheme.textSecondary)
        lbl.translatesAutoresizingMaskIntoConstraints = false

        let pill = PillBadgeView(text: status, tint: tint)
        pill.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(lbl)
        row.addSubview(pill)

        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            pill.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            pill.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: lbl.trailingAnchor, constant: 8),

            row.heightAnchor.constraint(equalToConstant: 20)
        ])

        row.dtHideSubviewsFromAccessibility()
        row.dtApplyAccessibility(role: NSAccessibility.Role.row, label: title, value: status)
        capture?(row, lbl, pill)

        return row
    }

    private func outcomeString(_ outcome: PermissionCoordinator.InjectOutcome?) -> String {
        switch outcome {
        case .succeeded: return loc.s("lab.outcome.succeeded")
        case .postedUnverified: return loc.s("lab.outcome.posted")
        case .degradedAXOnly: return loc.s("lab.outcome.degraded")
        case .failedSilent: return loc.s("lab.outcome.failed")
        case .refused(let reason): return loc.s("lab.outcome.refused", reason)
        case .none: return loc.s("lab.outcome.unknown")
        }
    }

    private func evaluateResult(outcome: PermissionCoordinator.InjectOutcome) {
        guard let textView, let statusLabel else { return }
        let actual = textView.string
        let outcomeLabel = outcomeString(outcome)
        refreshAuditOutcome(outcome)

        // The lab controls the whole field, so accepting a suffix or substring could report a
        // false positive after a partial or duplicated delivery. Require both exact text and a
        // confirmed terminal outcome; posted-but-unverified is evidence, not proof.
        let matched = actual == expected && outcome.isConfirmedSuccess

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

    private func refreshAuditOutcome(_ outcome: PermissionCoordinator.InjectOutcome) {
        let label = outcomeString(outcome)
        auditOutcomeTitleLabel?.stringValue = loc.s("lab.audit.lastOutcome", label)
        auditOutcomePill?.update(
            text: label,
            tint: outcome.isConfirmedSuccess ? DevTypeTheme.statusGreen : DevTypeTheme.statusOrange
        )
        auditOutcomeRow?.setAccessibilityLabel(loc.s("lab.audit.lastOutcome", label))
        auditOutcomeRow?.setAccessibilityValue(label)
    }

    @objc func close() {
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
