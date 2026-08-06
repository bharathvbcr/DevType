import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// Spotlight-style glass palette for searching and expanding snippets (⌘/ by default).
enum InlineSearchPanel {
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private static var panel: NSPanel?
    private static var controller: InlineSearchController?
    private static var dismissMonitors: [Any] = []
    private static var dismissObservers: [NSObjectProtocol] = []

    static var isOpen: Bool { panel?.isVisible == true }

    static func toggle(
        store: SnippetStore = .shared,
        loc: LocalizationManager = .shared,
        onPick: @escaping (SnippetModel, NSRunningApplication?) -> Void
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
        onPick: @escaping (SnippetModel, NSRunningApplication?) -> Void
    ) {
        let sourceApp = NSWorkspace.shared.frontmostApplication
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
            onPick: { snippet in
                close()
                onPick(snippet, sourceApp)
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

    /// The palette is a transient session: anything that takes focus away from it
    /// dismisses it, exactly like esc. That covers a click in another DevType
    /// window, a click in another app or on the desktop, and focus leaving the
    /// panel by any other route (⌘-tab, Mission Control, a menu bar click).
    private static func installDismissWatchers(for panel: NSPanel) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        // Clicks landing in another window of our own app.
        let local = NSEvent.addLocalMonitorForEvents(matching: clicks) { event in
            if event.window !== panel { dismissFromOutsideInteraction() }
            return event
        }
        if let local { dismissMonitors.append(local) }

        // Clicks landing in any other app (or the desktop).
        let global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { _ in
            dismissFromOutsideInteraction()
        }
        if let global { dismissMonitors.append(global) }

        // Backstop for focus changes that never produce a click here. Attached a
        // runloop turn late so the activation that opens the panel can settle
        // without tripping it.
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

    /// Unlike esc, focus has already moved on its own — don't reactivate the
    /// source app on top of wherever the user just clicked.
    private static func dismissFromOutsideInteraction() {
        guard panel != nil else { return }
        close()
    }

    /// Subtle fade + settle presentation, like Spotlight.
    ///
    /// §5.2: this used to run unconditionally. It now honours Reduce Motion —
    /// the panel simply appears at its final frame, fully opaque.
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

// MARK: - Result cell

/// One result row: crimson trigger pill, title + preview, group tag, ⌘n jump hint.
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
            // Fixed-width trigger column: titles always start at the same x,
            // no matter how long the trigger keyword is.
            triggerPill.widthAnchor.constraint(equalToConstant: 92),

            titleLabel.leadingAnchor.constraint(equalTo: triggerPill.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: groupLabel.leadingAnchor, constant: -10),

            previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: groupLabel.leadingAnchor, constant: -10),

            groupLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            groupLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Fixed-width group column keeps the title's trailing edge (and the
            // ⌘n jump cap anchored to it) stable across rows.
            groupLabel.widthAnchor.constraint(equalToConstant: 88)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with hit: SearchHit, jumpNumber: Int?) {
        let loc = LocalizationManager.shared
        let tint = hit.snippet.enabled ? DevTypeTheme.accent : DevTypeTheme.statusGray
        let triggerText = hit.snippet.triggerKeyword.isEmpty ? "·" : hit.snippet.triggerKeyword

        // §4.7: `SearchHit.highlights` carries the matched ranges, so results can
        // show *why* they matched instead of a flat string.
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
            // Content ranges are offsets into `replacementText`, which the macro
            // preview rewrites — so only highlight when the preview is unchanged.
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

        // §5.1: this is the app's PRIMARY keyboard surface and it announced
        // "row 1" with no content — four bare NSTextFields plus a custom
        // PillBadgeView in a plain NSView, none of them AX elements. Collapse the
        // row into one labelled element with a spoken keyboard hint.
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

    /// §4.7: builds an `NSAttributedString` with the matched ranges emphasised.
    /// Returns nil when the hit carries no highlight for `field` (legacy hits and
    /// the empty-query listing), so callers fall back to a plain string.
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
        // `ranges` are grapheme offsets into the original field text; the engine
        // ships the converter because NSAttributedString wants UTF-16.
        let ranges = SnippetSearch.utf16Ranges(highlight.ranges, in: text)
        guard !ranges.isEmpty else { return nil }

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        )
        let full = NSRange(location: 0, length: attributed.length)
        let emphasis = DevTypeTheme.accentBright
        let emphasisFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        // §5.2: weight + background, not colour alone, so the match is visible
        // under Differentiate Without Color and in greyscale.
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
    private let onPick: (SnippetModel) -> Void
    private let onCancel: () -> Void

    private var groups: [SnippetGroup] = []
    private var hits: [SearchHit] = []
    private var selection = 0
    private var keyMonitor: Any?
    private var listenerToken: UUID?

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let countLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10.5, .medium), color: DevTypeTheme.textTertiary)
    private let emptyState = NSView()
    private var scrollView = NSScrollView()

    init(store: SnippetStore, loc: LocalizationManager, onPick: @escaping (SnippetModel) -> Void, onCancel: @escaping () -> Void) {
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

        // MARK: Search row
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

        // MARK: Results table
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
        // §5.1: the results table and the query field are the two things a
        // VoiceOver user needs named on this surface.
        tableView.setAccessibilityLabel(loc.s("ax.searchResults"))
        searchField.setAccessibilityLabel(loc.s("search.placeholder"))
        magnifier.setAccessibilityElement(false)
        scrollView.documentView = tableView
        root.addSubview(scrollView)

        // MARK: Empty state
        setupEmptyState(in: root)

        // MARK: Footer — key-cap hints
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
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) {
        selection = 0
        refreshHits()
    }

    private func refreshHits() {
        let query = searchField.stringValue
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            hits = groups
                .filter(\.enabled)
                .flatMap { group in
                    group.snippets
                        .filter { $0.enabled && !$0.triggerKeyword.isEmpty }
                        .map { SearchHit(snippet: $0, groupID: group.id, groupName: group.name, score: 0) }
                }
                .sorted { $0.snippet.updatedAt > $1.snippet.updatedAt }
                .prefix(50)
                .map { $0 }
        } else {
            // §4.7: rank by usage as well as match quality. The store paid the
            // full cost of maintaining usage counts and `SnippetSearch` ignored
            // them entirely — a `boost` closure fixes that without making the
            // search module depend on the store.
            hits = SnippetSearch.run(
                query: query,
                in: groups,
                includeDisabled: false,
                limit: 50,
                boost: { [weak store] snippetID in
                    store?.usageCount(forSnippetID: snippetID) ?? 0
                }
            )
        }
        selection = min(selection, max(0, hits.count - 1))
        tableView.reloadData()
        if !hits.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
            tableView.scrollRowToVisible(selection)
        }
        emptyState.isHidden = !hits.isEmpty
        let total = groups.flatMap(\.snippets).count
        countLabel.stringValue = loc.s("search.count", hits.count, total)
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
                // §4.7: this used to be `Int(event.charactersIgnoringModifiers ?? "")`,
                // which fails on AZERTY (digits need ⇧), on Dvorak-like layouts,
                // and on any layout where the top row is not 1–9. Key codes are
                // layout-independent, which is the whole point of ⌘1–9.
                if event.modifierFlags.contains(.command),
                   let digit = Self.digitKeyCodes[Int(event.keyCode)],
                   hits.indices.contains(digit - 1) {
                    self.onPick(self.hits[digit - 1].snippet)
                    return nil
                }
                return event
            }
        }
    }

    /// §4.7: virtual key code → jump index, main row and numeric keypad.
    /// Note the hardware ordering quirk: `kVK_ANSI_6` sits *below* `kVK_ANSI_5`
    /// but `kVK_ANSI_7` is above it, which is exactly why a literal table beats
    /// arithmetic here.
    private static let digitKeyCodes: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
        kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3,
        kVK_ANSI_Keypad4: 4, kVK_ANSI_Keypad5: 5, kVK_ANSI_Keypad6: 6,
        kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9
    ]

    private func moveSelection(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selection = min(max(0, selection + delta), hits.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        tableView.scrollRowToVisible(selection)
    }

    @objc private func expandSelected() {
        guard hits.indices.contains(selection) else { return }
        onPick(hits[selection].snippet)
    }

    @objc private func cancel() { onCancel() }

    // MARK: Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard hits.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("hitCell")
        let cell: SearchHitCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? SearchHitCellView {
            cell = reused
        } else {
            cell = SearchHitCellView()
            cell.identifier = identifier
        }
        cell.configure(with: hits[row], jumpNumber: row < 9 ? row + 1 : nil)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RoundedSelectionRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selection = tableView.selectedRow
    }
}
