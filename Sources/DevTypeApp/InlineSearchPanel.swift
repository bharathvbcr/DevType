import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// Spotlight-style glass palette for snippets, AI tools, and instant commands (⌘/ by default).
enum InlineSearchPanel {
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// Result of committing a palette row.
    enum Pick {
        case snippet(SnippetModel)
        /// `insertText` is non-empty for date/clipboard inserts; empty for AI / navigate.
        case command(PaletteCommand, insertText: String)
    }

    private static var panel: NSPanel?
    private static var controller: InlineSearchController?
    private static var dismissMonitors: [Any] = []
    private static var dismissObservers: [NSObjectProtocol] = []

    static var isOpen: Bool { panel?.isVisible == true }

    static func toggle(
        store: SnippetStore = .shared,
        loc: LocalizationManager = .shared,
        onPick: @escaping (Pick, NSRunningApplication?, SelectionReader.Outcome) -> Void
    ) {
        if isOpen { close() } else { open(store: store, loc: loc, onPick: onPick) }
    }

    static func close() {
        removeDismissWatchers()
        panel?.close()
        panel = nil
        controller = nil
        EventTapEngine.shared.resumeMatching()
    }

    private static func open(
        store: SnippetStore,
        loc: LocalizationManager,
        onPick: @escaping (Pick, NSRunningApplication?, SelectionReader.Outcome) -> Void
    ) {
        let sourceApp = NSWorkspace.shared.frontmostApplication
        // Read the selection HERE, before `NSApp.activate(ignoringOtherApps:)` below makes
        // DevType frontmost. `SelectionReader` resolves the *system-wide* focused element,
        // so once our own panel is key it reads the search field — never the user's text.
        // Any later read from a palette command is therefore guaranteed to return nil.
        //
        // The whole `Outcome` is carried, not just the text: the failure reason is what the
        // command handlers need to tell the user why, and it can only be captured here.
        let sourceSelection = SelectionReader.readSelection()
        EventTapEngine.shared.suspendMatching()

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)
        panel.becomesKeyOnlyIfNeeded = false

        let controller = InlineSearchController(
            store: store,
            loc: loc,
            onPick: { pick in
                close()
                onPick(pick, sourceApp, sourceSelection)
            },
            onCancel: {
                close()
                sourceApp?.activate()
            }
        )
        panel.contentView = controller.view
        positionNearTop(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        controller.focusSearch()
        animateIn(panel)

        self.panel = panel
        self.controller = controller
        installDismissWatchers(for: panel)
    }

    // MARK: - Session-aware dismissal

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

// MARK: - Header cell

private final class PaletteHeaderCellView: NSView {
    private let label = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10, .bold), color: DevTypeTheme.textTertiary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
        dtHideSubviewsFromAccessibility()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(section: PaletteSection, loc: LocalizationManager) {
        label.stringValue = loc.s(section.titleKey).uppercased()
    }
}

// MARK: - Result cell

/// One result row: crimson trigger/badge pill, title + preview, section/group tag, ⌘n jump hint.
private final class SearchHitCellView: NSView {
    private let triggerPill = PillBadgeView(text: "", tint: DevTypeTheme.accent, font: DevTypeTheme.mono(11.5, .bold), truncates: true)
    private let titleLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(13, .semibold), color: DevTypeTheme.textPrimary)
    private let previewLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11), color: DevTypeTheme.textSecondary)
    private let groupLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10, .medium), color: DevTypeTheme.textTertiary)
    private var jumpCap: KeyCapView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.lineBreakMode = .byTruncatingTail
        previewLabel.lineBreakMode = .byTruncatingTail
        groupLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        groupLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(triggerPill)
        addSubview(titleLabel)
        addSubview(previewLabel)
        addSubview(groupLabel)

        NSLayoutConstraint.activate([
            triggerPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            triggerPill.centerYAnchor.constraint(equalTo: centerYAnchor),
            triggerPill.widthAnchor.constraint(equalToConstant: 92),

            titleLabel.leadingAnchor.constraint(equalTo: triggerPill.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: groupLabel.leadingAnchor, constant: -10),

            previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: groupLabel.leadingAnchor, constant: -10),

            groupLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            groupLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            groupLabel.widthAnchor.constraint(equalToConstant: 88)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configureCommand(_ hit: PaletteCommandHit, jumpNumber: Int?, loc: LocalizationManager) {
        let tint: NSColor
        switch hit.command.section {
        case .ai: tint = DevTypeTheme.accentBright
        case .commands: tint = DevTypeTheme.accent
        case .snippets: tint = DevTypeTheme.accent
        }
        let triggerText = hit.command.trigger.isEmpty ? "·" : hit.command.trigger
        triggerPill.update(text: triggerText, tint: hit.isEnabled ? tint : DevTypeTheme.textTertiary)
        triggerPill.toolTip = hit.command.trigger

        titleLabel.textColor = hit.isEnabled ? DevTypeTheme.textPrimary : DevTypeTheme.textTertiary
        titleLabel.stringValue = loc.s(hit.command.titleKey)

        previewLabel.textColor = DevTypeTheme.textSecondary
        if let reason = hit.disabledReason, !reason.isEmpty {
            previewLabel.stringValue = reason
        } else {
            previewLabel.stringValue = hit.preview
        }

        groupLabel.textColor = DevTypeTheme.textTertiary
        groupLabel.stringValue = loc.s(hit.command.section.titleKey)
        groupLabel.toolTip = groupLabel.stringValue

        installJumpCap(hit.isEnabled ? jumpNumber : nil)

        dtHideSubviewsFromAccessibility()
        dtApplyAccessibility(
            role: NSAccessibility.Role.row,
            label: loc.s("ax.paletteRow.command", triggerText, loc.s(hit.command.titleKey), loc.s(hit.command.section.titleKey)),
            value: hit.preview,
            help: jumpNumber.map { loc.s("ax.searchRow.help", $0) }
                ?? loc.s("ax.searchRow.helpNoJump")
        )
    }

    func configureSnippet(with hit: SearchHit, jumpNumber: Int?) {
        let loc = LocalizationManager.shared
        let tint = hit.snippet.enabled ? DevTypeTheme.accent : DevTypeTheme.statusGray
        let triggerText = hit.snippet.triggerKeyword.isEmpty ? "·" : hit.snippet.triggerKeyword

        if let attributed = Self.highlighted(
            triggerText,
            field: .trigger,
            in: hit,
            font: DevTypeTheme.mono(11.5, .bold),
            color: tint
        ) {
            triggerPill.update(attributed: attributed, tint: tint)
        } else {
            triggerPill.update(text: triggerText, tint: tint)
        }
        triggerPill.toolTip = hit.snippet.triggerKeyword.isEmpty ? nil : hit.snippet.triggerKeyword

        let titleColor = hit.snippet.enabled ? DevTypeTheme.textPrimary : DevTypeTheme.textTertiary
        titleLabel.textColor = titleColor
        if let attributed = Self.highlighted(
            hit.snippet.displayTitle,
            field: .title,
            in: hit,
            font: DevTypeTheme.font(13, .semibold),
            color: titleColor
        ) {
            titleLabel.attributedStringValue = attributed
        } else {
            titleLabel.stringValue = hit.snippet.displayTitle
        }

        let previewText: String
        if hit.snippet.isImageSnippet {
            previewText = "🖼 \(hit.snippet.imagePath)"
            previewLabel.stringValue = previewText
        } else {
            previewText = MacroPreview.render(hit.snippet.replacementText)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if previewText == hit.snippet.replacementText,
               let attributed = Self.highlighted(
                   previewText,
                   field: .content,
                   in: hit,
                   font: DevTypeTheme.font(11),
                   color: DevTypeTheme.textSecondary
               ) {
                previewLabel.attributedStringValue = attributed
            } else {
                previewLabel.textColor = DevTypeTheme.textSecondary
                previewLabel.stringValue = previewText
            }
        }

        if let attributed = Self.highlighted(
            hit.groupName,
            field: .group,
            in: hit,
            font: DevTypeTheme.font(10, .medium),
            color: DevTypeTheme.textTertiary
        ) {
            groupLabel.attributedStringValue = attributed
        } else {
            groupLabel.textColor = DevTypeTheme.textTertiary
            groupLabel.stringValue = hit.groupName
        }
        groupLabel.toolTip = hit.groupName

        installJumpCap(jumpNumber)

        dtHideSubviewsFromAccessibility()
        let spokenTrigger = hit.snippet.triggerKeyword.isEmpty
            ? loc.s("ax.noTrigger")
            : hit.snippet.triggerKeyword
        let spokenDetail = hit.snippet.isImageSnippet ? loc.s("ax.searchRow.image") : previewText
        let labelKey = hit.snippet.enabled ? "ax.searchRow" : "ax.searchRow.disabled"
        dtApplyAccessibility(
            role: NSAccessibility.Role.row,
            label: loc.s(labelKey, spokenTrigger, hit.snippet.displayTitle, hit.groupName),
            value: spokenDetail,
            help: jumpNumber.map { loc.s("ax.searchRow.help", $0) }
                ?? loc.s("ax.searchRow.helpNoJump")
        )
    }

    private func installJumpCap(_ jumpNumber: Int?) {
        jumpCap?.removeFromSuperview()
        jumpCap = nil
        if let jumpNumber {
            let cap = KeyCapView("⌘\(jumpNumber)")
            jumpCap = cap
            addSubview(cap)
            NSLayoutConstraint.activate([
                cap.trailingAnchor.constraint(equalTo: groupLabel.leadingAnchor, constant: -6),
                cap.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }

    private static func highlighted(
        _ text: String,
        field: SearchField,
        in hit: SearchHit,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString? {
        guard !text.isEmpty,
              let highlight = hit.highlights.first(where: { $0.field == field }),
              !highlight.ranges.isEmpty else { return nil }
        let ranges = SnippetSearch.utf16Ranges(highlight.ranges, in: text)
        guard !ranges.isEmpty else { return nil }

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        )
        let full = NSRange(location: 0, length: attributed.length)
        let emphasis = DevTypeTheme.accentBright
        let emphasisFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: emphasis,
            .backgroundColor: emphasis.withAlphaComponent(0.18),
            .font: emphasisFont
        ]
        for range in ranges {
            let clamped = NSIntersectionRange(range, full)
            guard clamped.length > 0 else { continue }
            attributed.addAttributes(attributes, range: clamped)
        }
        return attributed
    }
}

// MARK: - Controller

private final class InlineSearchController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let store: SnippetStore
    private let loc: LocalizationManager
    private let onPick: (InlineSearchPanel.Pick) -> Void
    private let onCancel: () -> Void

    private var groups: [SnippetGroup] = []
    private var rows: [PaletteListRow] = []
    private var selection = 0
    private var keyMonitor: Any?
    private var listenerToken: UUID?
    /// Clipboard text + changeCount — refreshed on open / when changeCount moves (not every keystroke).
    private var cachedClipboard: String?
    private var cachedClipboardChangeCount: Int = -1
    private var semanticBoostIDs: [String] = []
    private var semanticWorkItem: DispatchWorkItem?
    private var aiDisabledReason: String?

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let countLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10.5, .medium), color: DevTypeTheme.textTertiary)
    private let emptyState = NSView()
    private var scrollView = NSScrollView()

    init(
        store: SnippetStore,
        loc: LocalizationManager,
        onPick: @escaping (InlineSearchPanel.Pick) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.store = store
        self.loc = loc
        self.onPick = onPick
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let listenerToken { store.removeListener(token: listenerToken) }
    }

    override func loadView() {
        let glass = GlassContainerView(
            cornerRadius: DevTypeTheme.Radius.panel,
            tint: DevTypeTheme.accent.withAlphaComponent(0.10),
            material: .popover
        )
        glass.frame = NSRect(x: 0, y: 0, width: 640, height: 460)
        let root = glass.contentView

        let magnifier = NSImageView()
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        magnifier.image = DevTypeTheme.symbol("magnifyingglass", size: 17, weight: .medium, color: DevTypeTheme.accent)
        magnifier.imageScaling = .scaleProportionallyUpOrDown

        searchField.placeholderAttributedString = NSAttributedString(
            string: loc.s("search.placeholder"),
            attributes: [
                .foregroundColor: DevTypeTheme.textTertiary,
                .font: DevTypeTheme.font(20, .light)
            ]
        )
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = DevTypeTheme.font(20, .light)
        searchField.textColor = DevTypeTheme.textPrimary
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none

        let escCap = KeyCapView("esc")
        root.addSubview(magnifier)
        root.addSubview(searchField)
        root.addSubview(escCap)

        let divider = DevTypeTheme.makeHairline()
        root.addSubview(divider)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(expandSelected)
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        tableView.setAccessibilityLabel(loc.s("ax.searchResults"))
        searchField.setAccessibilityLabel(loc.s("search.placeholder"))
        magnifier.setAccessibilityElement(false)
        scrollView.documentView = tableView
        root.addSubview(scrollView)

        setupEmptyState(in: root)

        let footerDivider = DevTypeTheme.makeHairline()
        root.addSubview(footerDivider)

        let navigateCap = KeyCapView("↑↓")
        let navigateLabel = DevTypeTheme.makeLabel(loc.s("search.hint.navigate"), font: DevTypeTheme.font(10.5, .medium), color: DevTypeTheme.textTertiary)
        let expandCap = KeyCapView("↩")
        let expandLabel = DevTypeTheme.makeLabel(loc.s("search.hint.expand"), font: DevTypeTheme.font(10.5, .medium), color: DevTypeTheme.textTertiary)
        let jumpCap = KeyCapView("⌘1–9")
        let jumpLabel = DevTypeTheme.makeLabel(loc.s("search.hint.jump"), font: DevTypeTheme.font(10.5, .medium), color: DevTypeTheme.textTertiary)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let footerStack = NSStackView(views: [
            navigateCap, navigateLabel, expandCap, expandLabel, jumpCap, jumpLabel
        ])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 6
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footerStack)
        root.addSubview(countLabel)

        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            magnifier.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: 20),
            magnifier.heightAnchor.constraint(equalToConstant: 20),

            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: escCap.leadingAnchor, constant: -10),
            searchField.heightAnchor.constraint(equalToConstant: 30),

            escCap.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            escCap.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
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
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            countLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: footerStack.centerYAnchor)
        ])

        view = glass
    }

    private func setupEmptyState(in root: NSView) {
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = DevTypeTheme.symbol("text.magnifyingglass", size: 28, weight: .light, color: DevTypeTheme.accent.withAlphaComponent(0.7))
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = DevTypeTheme.makeLabel(
            loc.s("search.empty.title"),
            font: DevTypeTheme.font(13, .semibold),
            color: DevTypeTheme.textSecondary
        )
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = DevTypeTheme.makeLabel(
            loc.s("search.empty.subtitle"),
            font: DevTypeTheme.font(11),
            color: DevTypeTheme.textTertiary
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addSubview(stack)
        root.addSubview(emptyState)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        groups = store.loadGroups()
        refreshClipboardCache(force: true)
        aiDisabledReason = AILocaleSupport.disabledReason(loc: loc)
        listenerToken = store.addGroupListener { [weak self] updated in
            DispatchQueue.main.async {
                self?.groups = updated
                self?.refreshHits()
            }
        }
        refreshHits()
        installKeyMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        semanticWorkItem?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) {
        selection = 0
        refreshHits()
        scheduleSemanticBoost()
    }

    private func refreshClipboardCache(force: Bool = false) {
        let count = NSPasteboard.general.changeCount
        guard force || count != cachedClipboardChangeCount else { return }
        cachedClipboardChangeCount = count
        cachedClipboard = NSPasteboard.general.string(forType: .string)
    }

    private func scheduleSemanticBoost() {
        semanticWorkItem?.cancel()
        let query = searchField.stringValue
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = CommandPaletteCatalog.semanticBoostIDs(for: query)
            DispatchQueue.main.async {
                guard self.searchField.stringValue == query else { return }
                self.semanticBoostIDs = ids
                self.refreshHits()
            }
        }
        semanticWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(PaletteToolRouter.debounceMilliseconds),
            execute: work
        )
    }

    private func refreshHits() {
        refreshClipboardCache()
        let query = searchField.stringValue
        let previous = rows
        rows = CommandPaletteCatalog.buildRows(
            query: query,
            groups: groups,
            loc: loc,
            usageBoost: { [weak store] snippetID in
                store?.usageCount(forSnippetID: snippetID) ?? 0
            },
            clipboardPreview: cachedClipboard,
            semanticBoostIDs: semanticBoostIDs,
            commandUsageBoost: { CommandUsageStatsStore.shared.rankBoost(for: $0) },
            aiDisabledReason: aiDisabledReason,
            commandLimit: 20,
            snippetLimit: 40
        )

        if selection < 0 || !rows.indices.contains(selection) || !rows[selection].isSelectable {
            selection = firstSelectableIndex(from: 0, step: 1) ?? -1
        }

        reloadTableDiff(from: previous, to: rows)
        if selection >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
            tableView.scrollRowToVisible(selection)
        } else {
            tableView.deselectAll(nil)
        }

        let selectableCount = rows.filter(\.isSelectable).count
        emptyState.isHidden = selectableCount > 0
        let totalSnippets = groups.flatMap(\.snippets).count
        countLabel.stringValue = loc.s("search.count", selectableCount, totalSnippets)
    }

    /// Prefer range reloads over full `reloadData` once the catalogue is large (D3).
    private func reloadTableDiff(from old: [PaletteListRow], to new: [PaletteListRow]) {
        if old.isEmpty || old.count != new.count {
            tableView.reloadData()
            return
        }
        var changed = IndexSet()
        for i in new.indices where !Self.rowsEqual(old[i], new[i]) {
            changed.insert(i)
        }
        if changed.count > new.count / 2 {
            tableView.reloadData()
        } else if !changed.isEmpty {
            tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        }
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
                self.cancel()
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    self.expandSelected()
                    return nil
                }
                return event
            default:
                if event.modifierFlags.contains(.command),
                   let digit = Self.digitKeyCodes[Int(event.keyCode)] {
                    if let pick = self.pickAtJumpIndex(digit - 1) {
                        self.onPick(pick)
                        return nil
                    }
                }
                return event
            }
        }
    }

    private static let digitKeyCodes: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
        kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3,
        kVK_ANSI_Keypad4: 4, kVK_ANSI_Keypad5: 5, kVK_ANSI_Keypad6: 6,
        kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9
    ]

    /// Jump index among selectable rows only (headers skipped).
    private func pickAtJumpIndex(_ index: Int) -> InlineSearchPanel.Pick? {
        let selectable = rows.compactMap { row -> InlineSearchPanel.Pick? in
            switch row {
            case .command(let hit):
                guard hit.isEnabled else { return nil }
                return .command(hit.command, insertText: hit.insertText)
            case .snippet(let hit):
                return .snippet(hit.snippet)
            case .header:
                return nil
            }
        }
        guard selectable.indices.contains(index) else { return nil }
        return selectable[index]
    }

    private static func rowsEqual(_ a: PaletteListRow, _ b: PaletteListRow) -> Bool {
        a == b
    }

    private func firstSelectableIndex(from start: Int, step: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        var index = start
        while index >= 0 && index < rows.count {
            if rows[index].isSelectable { return index }
            index += step
        }
        return nil
    }

    private func applySelection(scroll: Bool) {
        guard rows.indices.contains(selection) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        if scroll { tableView.scrollRowToVisible(selection) }
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let start = selection < 0 ? (delta > 0 ? 0 : rows.count - 1) : selection + delta
        guard let next = firstSelectableIndex(from: start, step: delta > 0 ? 1 : -1) else { return }
        selection = next
        applySelection(scroll: true)
    }

    private func selectedPick() -> InlineSearchPanel.Pick? {
        guard rows.indices.contains(selection) else { return nil }
        switch rows[selection] {
        case .command(let hit):
            return .command(hit.command, insertText: hit.insertText)
        case .snippet(let hit):
            return .snippet(hit.snippet)
        case .header:
            return nil
        }
    }

    @objc private func expandSelected() {
        guard let pick = selectedPick() else { return }
        onPick(pick)
    }

    @objc private func cancel() { onCancel() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 48 }
        switch rows[row] {
        case .header: return 22
        case .command, .snippet: return 48
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let section):
            let identifier = NSUserInterfaceItemIdentifier("paletteHeader")
            let cell: PaletteHeaderCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? PaletteHeaderCellView {
                cell = reused
            } else {
                cell = PaletteHeaderCellView()
                cell.identifier = identifier
            }
            cell.configure(section: section, loc: loc)
            return cell

        case .command(let hit):
            let identifier = NSUserInterfaceItemIdentifier("hitCell")
            let cell: SearchHitCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? SearchHitCellView {
                cell = reused
            } else {
                cell = SearchHitCellView()
                cell.identifier = identifier
            }
            let jump = jumpNumber(forSelectableRow: row)
            cell.configureCommand(hit, jumpNumber: jump, loc: loc)
            return cell

        case .snippet(let hit):
            let identifier = NSUserInterfaceItemIdentifier("hitCell")
            let cell: SearchHitCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? SearchHitCellView {
                cell = reused
            } else {
                cell = SearchHitCellView()
                cell.identifier = identifier
            }
            let jump = jumpNumber(forSelectableRow: row)
            cell.configureSnippet(with: hit, jumpNumber: jump)
            return cell
        }
    }

    private func jumpNumber(forSelectableRow row: Int) -> Int? {
        var index = 0
        for i in 0..<rows.count {
            guard rows[i].isSelectable else { continue }
            if i == row {
                return index < 9 ? index + 1 : nil
            }
            index += 1
        }
        return nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RoundedSelectionRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0, rows.indices.contains(row), rows[row].isSelectable {
            selection = row
        }
    }
}
