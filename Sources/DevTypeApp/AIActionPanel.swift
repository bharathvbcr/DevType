import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// Spotlight-style action picker for on-device AI transforms (hotkey path).
///
/// Modeled on `InlineSearchPanel`: suspend matching on open, resume on close,
/// capture `sourceApp` for reactivation after a pick.
enum AIActionPanel {
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private static var panel: NSPanel?
    private static var controller: AIActionController?
    /// This panel's claim on matching being suspended. Owned, so double-open and double-close are
    /// both harmless — see `EventTapEngine.MatchingSuspension`.
    private static var suspension: EventTapEngine.MatchingSuspension?
    private static var dismissMonitors: [Any] = []
    private static var dismissObservers: [NSObjectProtocol] = []

    static var isOpen: Bool { panel?.isVisible == true }

    static func present(
        input: String,
        source: SelectionReader.Source,
        loc: LocalizationManager = .shared,
        onPick: @escaping (AITransformKind, NSRunningApplication?) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        if isOpen { close() }
        open(input: input, source: source, loc: loc, onPick: onPick, onCancel: onCancel)
    }

    static func close(resumeMatching: Bool = true) {
        removeDismissWatchers()
        panel?.close()
        panel = nil
        controller = nil
        if resumeMatching {
            // Releasing our own token, not decrementing a shared count: a second `close()` (the
            // dismiss watcher racing `onPick`) finds it already released and does nothing, so it
            // cannot resume matching out from under a fill-in panel that suspended it next.
            suspension?.release()
            suspension = nil
        }
    }

    private static func open(
        input: String,
        source: SelectionReader.Source,
        loc: LocalizationManager,
        onPick: @escaping (AITransformKind, NSRunningApplication?) -> Void,
        onCancel: (() -> Void)?
    ) {
        let sourceApp = NSWorkspace.shared.frontmostApplication
        // Assigning over a live token releases the old one (ARC → `deinit` → `release`), so a
        // second `open()` — reachable because `isOpen` reads `panel?.isVisible`, already false
        // while the panel animates out — cannot leave a suspension stranded.
        suspension = EventTapEngine.shared.suspendMatching(reason: "AIActionPanel")

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            Task { await AITextTransformer.shared.prewarm(kind: .proofread) }
        }
        #endif

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)
        panel.becomesKeyOnlyIfNeeded = false

        let controller = AIActionController(
            input: input,
            source: source,
            loc: loc,
            onPick: { kind in
                close(resumeMatching: true)
                onPick(kind, sourceApp)
            },
            onCancel: {
                close(resumeMatching: true)
                sourceApp?.activate()
                onCancel?()
            }
        )
        panel.contentView = controller.view
        positionNearTop(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        controller.focusTable()
        animateIn(panel)

        self.panel = panel
        self.controller = controller
        installDismissWatchers(for: panel)
    }

    private static func installDismissWatchers(for panel: NSPanel) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        let local = NSEvent.addLocalMonitorForEvents(matching: clicks) { event in
            if event.window !== panel { dismissFromOutsideInteraction() }
            return event
        }
        if let local { dismissMonitors.append(local) }

        let global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { _ in
            dismissFromOutsideInteraction()
        }
        if let global { dismissMonitors.append(global) }

        DispatchQueue.main.async {
            guard self.panel === panel else { return }
            dismissObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: panel,
                    queue: .main
                ) { _ in dismissFromOutsideInteraction() }
            )
        }
    }

    private static func removeDismissWatchers() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
        dismissObservers.forEach(NotificationCenter.default.removeObserver)
        dismissObservers.removeAll()
    }

    private static func dismissFromOutsideInteraction() {
        guard panel != nil else { return }
        close()
    }

    private static func animateIn(_ panel: NSPanel) {
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

    private static func positionNearTop(_ panel: NSPanel) {
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

// MARK: - Controller

private final class AIActionController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let inputPreview: String
    private let source: SelectionReader.Source
    private let loc: LocalizationManager
    private let onPick: (AITransformKind) -> Void
    private let onCancel: () -> Void
    private let actions = AITransformKind.builtInPalette
    private var selection = 0
    private var keyMonitor: Any?

    private let tableView = NSTableView()
    private var scrollView = NSScrollView()

    init(
        input: String,
        source: SelectionReader.Source,
        loc: LocalizationManager,
        onPick: @escaping (AITransformKind) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed
            .replacingOccurrences(of: "\n", with: " ")
        self.inputPreview = preview.count > 120
            ? String(preview.prefix(117)) + "…"
            : preview
        self.source = source
        self.loc = loc
        self.onPick = onPick
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override func loadView() {
        let glass = GlassContainerView(
            cornerRadius: DevTypeTheme.Radius.panel,
            tint: DevTypeTheme.accent.withAlphaComponent(0.10),
            material: .popover
        )
        glass.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
        let root = glass.contentView

        let badge = IconBadgeView(symbol: "sparkles", tint: DevTypeTheme.accent, size: 32, pointSize: 14)
        let titleLabel = DevTypeTheme.makeLabel(
            loc.s("ai.palette.title"),
            font: DevTypeTheme.font(14, .bold),
            color: DevTypeTheme.textPrimary
        )
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let subtitleLabel = DevTypeTheme.makeLabel(
            loc.s(source == .clipboard
                ? "ai.palette.clipboardSubtitle"
                : "ai.palette.subtitle"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary
        )
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerText = NSStackView(views: [titleLabel, subtitleLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 1
        headerText.translatesAutoresizingMaskIntoConstraints = false

        let escCap = KeyCapView("esc")
        root.addSubview(badge)
        root.addSubview(headerText)
        root.addSubview(escCap)

        let previewLabel = DevTypeTheme.makeLabel(
            inputPreview,
            font: DevTypeTheme.font(11),
            color: DevTypeTheme.textSecondary
        )
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.setAccessibilityLabel(loc.s(source == .clipboard
            ? "ai.palette.clipboardPreview"
            : "ai.palette.selectionPreview"))
        root.addSubview(previewLabel)

        let divider = DevTypeTheme.makeHairline()
        root.addSubview(divider)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(confirmSelection)
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        tableView.setAccessibilityLabel(loc.s("ai.palette.title"))
        scrollView.documentView = tableView
        root.addSubview(scrollView)

        let footerDivider = DevTypeTheme.makeHairline()
        root.addSubview(footerDivider)

        let navigateCap = KeyCapView("↑↓")
        let navigateLabel = DevTypeTheme.makeLabel(
            loc.s("search.hint.navigate"),
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.textTertiary
        )
        let pickCap = KeyCapView("↩")
        let pickLabel = DevTypeTheme.makeLabel(
            loc.s("ai.palette.hint.pick"),
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.textTertiary
        )
        let footerStack = NSStackView(views: [navigateCap, navigateLabel, pickCap, pickLabel])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 6
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footerStack)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            headerText.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            headerText.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            headerText.trailingAnchor.constraint(lessThanOrEqualTo: escCap.leadingAnchor, constant: -10),
            escCap.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            escCap.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            previewLabel.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 12),
            previewLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            previewLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            divider.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -4),

            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footerDivider.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -8),

            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])

        view = glass
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        tableView.reloadData()
        if !actions.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        installKeyMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    func focusTable() {
        view.window?.makeFirstResponder(tableView)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch Int(event.keyCode) {
            case kVK_UpArrow:
                self.moveSelection(-1)
                return nil
            case kVK_DownArrow:
                self.moveSelection(1)
                return nil
            case kVK_Escape:
                self.onCancel()
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    self.confirmSelection()
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !actions.isEmpty else { return }
        selection = min(max(0, selection + delta), actions.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        tableView.scrollRowToVisible(selection)
    }

    @objc private func confirmSelection() {
        guard actions.indices.contains(selection) else { return }
        onPick(actions[selection])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard actions.indices.contains(row) else { return nil }
        let kind = actions[row]
        let identifier = NSUserInterfaceItemIdentifier("aiActionCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(13, .medium), color: DevTypeTheme.textPrimary)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = loc.s(kind.localizationKey)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RoundedSelectionRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if tableView.selectedRow >= 0 {
            selection = tableView.selectedRow
        }
    }
}
