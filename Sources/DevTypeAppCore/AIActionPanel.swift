import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// User-facing action metadata shared by palette rendering and filtering.
///
/// Keeping this mapping outside the controller prevents the row label and the search corpus from
/// drifting apart. Descriptions are keys derived from the action's canonical title key; behavior
/// remains an explicit semantic classification because it also drives the badge tint.
enum AIActionBehavior: CaseIterable, Equatable {
    case preserves
    case shortens
    case expands
    case rewrites

    var localizationKey: String {
        switch self {
        case .preserves: return "ai.badge.preserves"
        case .shortens: return "ai.badge.shortens"
        case .expands: return "ai.badge.expands"
        case .rewrites: return "ai.badge.rewrites"
        }
    }
}

struct AIActionPresentation: Equatable {
    let kind: AITransformKind

    var descriptionKey: String { "\(kind.localizationKey).description" }

    var behavior: AIActionBehavior {
        switch kind {
        case .proofread, .translate, .translateTelugu, .translateHindi:
            return .preserves
        case .condense, .mergeRewrite, .gitCommitMessage, .removeMarkdown:
            return .shortens
        case .expand, .generateDocstring, .generateUnitTests, .explainCode, .explainRegex:
            return .expands
        case .rewrite, .paraphrase, .formal, .friendly, .bulletize, .promptEnhance,
             .toJson, .sqlQuery, .fixCode, .custom, .toMarkdown:
            return .rewrites
        }
    }
}

/// Immutable filter result so zero matches is a first-class presentation state rather than an
/// accidental empty table. `localize` is injected to make every searchable field testable.
struct AIActionPaletteProjection: Equatable {
    let actions: [AITransformKind]

    init(
        actions candidates: [AITransformKind],
        query: String,
        localize: (String) -> String
    ) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            actions = candidates
            return
        }
        actions = candidates.filter { kind in
            let presentation = AIActionPresentation(kind: kind)
            return TokenizedFilter.matches(query: needle, fields: [
                localize(kind.localizationKey),
                localize(presentation.descriptionKey),
                localize(presentation.behavior.localizationKey)
            ])
        }
    }

    var showsEmptyState: Bool { actions.isEmpty }
    var initialSelection: Int? { actions.isEmpty ? nil : 0 }
}

/// Spotlight-style action picker for on-device AI transforms (hotkey path).
///
/// Modeled on `InlineSearchPanel`: suspend matching on open, resume on close,
/// capture `sourceApp` for reactivation after a pick.
enum AIActionPanel {
    private static var panel: NSPanel?
    private static var controller: AIActionController?
    /// This panel's claim on matching being suspended. Owned, so double-open and double-close are
    /// both harmless — see `EventTapEngine.MatchingSuspension`.
    private static var suspension: EventTapEngine.MatchingSuspension?
    private static let dismissWatchers = PanelDismissWatchers()

    static var isOpen: Bool { panel?.isVisible == true }

    /// - Parameter modelUnavailable: why the on-device model cannot be used, when it
    ///   cannot. The panel then lists only the actions that do not need it and says so,
    ///   instead of offering twenty rows that would all fail.
    static func present(
        input: String,
        source: SelectionReader.Source,
        loc: LocalizationManager = .shared,
        modelUnavailable: AIModelAvailability.Reason? = nil,
        onPick: @escaping (AIActionSelection, NSRunningApplication?) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        if isOpen { close() }
        open(
            input: input,
            source: source,
            loc: loc,
            modelUnavailable: modelUnavailable,
            onPick: onPick,
            onCancel: onCancel
        )
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
        modelUnavailable: AIModelAvailability.Reason?,
        onPick: @escaping (AIActionSelection, NSRunningApplication?) -> Void,
        onCancel: (() -> Void)?
    ) {
        let sourceApp = NSWorkspace.shared.frontmostApplication
        // Assigning over a live token releases the old one (ARC → `deinit` → `release`), so a
        // second `open()` — reachable because `isOpen` reads `panel?.isVisible`, already false
        // while the panel animates out — cannot leave a suspension stranded.
        suspension = EventTapEngine.shared.suspendMatching(reason: "AIActionPanel")

        #if canImport(FoundationModels)
        // No point warming a session for a panel that is about to offer only local work.
        if #available(macOS 26.0, *), modelUnavailable == nil {
            Task { await AITextTransformer.shared.prewarm(kind: .proofread) }
        }
        #endif

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
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
            modelUnavailable: modelUnavailable,
            onPick: { selection in
                close(resumeMatching: true)
                onPick(selection, sourceApp)
            },
            onCancel: {
                close(resumeMatching: true)
                sourceApp?.activate()
                onCancel?()
            }
        )
        panel.contentView = controller.view
        FloatingPanelChrome.positionNearTop(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        controller.focusSearch()
        FloatingPanelChrome.animateIn(panel)

        self.panel = panel
        self.controller = controller
        installDismissWatchers(for: panel)
    }

    private static func installDismissWatchers(for panel: NSPanel) {
        dismissWatchers.install(
            for: panel,
            isStillCurrent: { self.panel === panel },
            dismiss: dismissFromOutsideInteraction
        )
    }

    private static func removeDismissWatchers() {
        dismissWatchers.removeAll()
    }

    private static func dismissFromOutsideInteraction() {
        guard panel != nil else { return }
        close()
    }
}

// MARK: - Controller

private final class AIActionController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextFieldDelegate {
    private let inputPreview: String
    private let rawInput: String
    private let source: SelectionReader.Source
    private let loc: LocalizationManager
    private let onPick: (AIActionSelection) -> Void
    private let onCancel: () -> Void
    private let modelUnavailable: AIModelAvailability.Reason?
    private let allActions: [AITransformKind]
    private var filteredActions: [AITransformKind] = []
    private var selection = 0
    private var keyMonitor: Any?

    private let searchField = NSSearchField()
    private let customField = NSTextField()
    private let tableView = NSTableView()
    private var scrollView = NSScrollView()
    private let emptyState = NSView()

    init(
        input: String,
        source: SelectionReader.Source,
        loc: LocalizationManager,
        modelUnavailable: AIModelAvailability.Reason?,
        onPick: @escaping (AIActionSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.modelUnavailable = modelUnavailable
        self.allActions = AITransformKind.palette(modelAvailable: modelUnavailable == nil)
        self.rawInput = input
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
        self.filteredActions = allActions
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
        glass.frame = NSRect(x: 0, y: 0, width: 460, height: 520)
        let root = glass.contentView

        let badge = IconBadgeView(symbol: "sparkles", tint: DevTypeTheme.accent, size: 32, pointSize: 14)
        let titleLabel = DevTypeTheme.makeLabel(
            loc.s("ai.palette.title"),
            font: DevTypeTheme.font(14, .bold),
            color: DevTypeTheme.textPrimary
        )
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // A short list needs a reason, or it reads as actions having gone missing. The
        // subtitle already sits under the title and says what the panel is for; when the
        // model is out, saying why is more useful than saying that again.
        let subtitleText = modelUnavailable == nil
            ? loc.s(source == .clipboard ? "ai.palette.clipboardSubtitle" : "ai.palette.subtitle")
            : loc.s("ai.palette.localOnly")
        let subtitleLabel = DevTypeTheme.makeLabel(
            subtitleText,
            font: DevTypeTheme.font(10.5),
            color: modelUnavailable == nil ? DevTypeTheme.textTertiary : DevTypeTheme.statusOrange
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

        // Preview box
        let previewBox = NSView()
        previewBox.wantsLayer = true
        previewBox.layer?.backgroundColor = DevTypeTheme.cardBackground.cgColor
        previewBox.layer?.cornerRadius = 6
        previewBox.layer?.borderWidth = 1
        previewBox.layer?.borderColor = NSColor.separatorColor.cgColor
        previewBox.translatesAutoresizingMaskIntoConstraints = false

        let previewText: String
        if inputPreview.isEmpty {
            previewText = loc.s(source == .clipboard ? "ai.palette.clipboardPreview" : "ai.palette.selectionPreview")
        } else if source == .clipboard {
            previewText = "\(loc.s("ai.palette.clipboardPreview")): \(inputPreview)"
        } else {
            previewText = inputPreview
        }
        let previewLabel = DevTypeTheme.makeLabel(
            previewText,
            font: DevTypeTheme.font(11),
            color: DevTypeTheme.textSecondary
        )
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.lineBreakMode = .byTruncatingTail
        previewBox.addSubview(previewLabel)
        root.addSubview(previewBox)

        // Search Field
        searchField.placeholderString = loc.s("ai.panel.searchPlaceholder")
        searchField.font = DevTypeTheme.font(12)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchField)

        let divider = DevTypeTheme.makeHairline()
        root.addSubview(divider)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.headerView = nil
        tableView.rowHeight = 44
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
        setupEmptyState(in: root)

        // Custom Instruction Field
        customField.placeholderString = modelUnavailable == nil
            ? loc.s("ai.palette.hint.pick") + " / " + loc.s("ai.panel.customPrompt")
            : loc.s("ai.palette.customUnavailable")
        customField.isEnabled = modelUnavailable == nil
        customField.font = DevTypeTheme.font(12)
        customField.focusRingType = .none
        customField.delegate = self
        customField.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(customField)

        let footerDivider = DevTypeTheme.makeHairline()
        root.addSubview(footerDivider)

        let quickCap = KeyCapView("1-9")
        let quickLabel = DevTypeTheme.makeLabel(
            loc.s("ai.palette.quick"),
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.textTertiary
        )
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
        let footerStack = NSStackView(views: [quickCap, quickLabel, navigateCap, navigateLabel, pickCap, pickLabel])
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

            previewBox.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 10),
            previewBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            previewBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            previewBox.heightAnchor.constraint(equalToConstant: 28),

            previewLabel.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 8),
            previewLabel.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -8),
            previewLabel.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),

            searchField.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: customField.topAnchor, constant: -6),

            customField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            customField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            customField.heightAnchor.constraint(equalToConstant: 24),
            customField.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -6),

            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footerDivider.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -8),

            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])

        view = glass
    }

    private func setupEmptyState(in root: NSView) {
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = DevTypeTheme.symbol(
            "text.magnifyingglass",
            size: 26,
            weight: .light,
            color: DevTypeTheme.accent.withAlphaComponent(0.7)
        )
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)

        let title = DevTypeTheme.makeLabel(
            loc.s("ai.palette.empty"),
            font: DevTypeTheme.font(13, .semibold),
            color: DevTypeTheme.textSecondary
        )
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = DevTypeTheme.makeLabel(
            loc.s("ai.palette.emptyHint"),
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
        emptyState.setAccessibilityElement(true)
        emptyState.setAccessibilityRole(.group)
        emptyState.setAccessibilityLabel(loc.s("ai.palette.empty"))
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
        applyProjection(AIActionPaletteProjection(
            actions: allActions,
            query: searchField.stringValue,
            localize: { loc.s($0) }
        ))
        installKeyMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    func focusTable() {
        view.window?.makeFirstResponder(tableView)
    }

    /// Whether the instruction field is taking keystrokes.
    ///
    /// A focused `NSTextField` is *not* the window's first responder — its field editor
    /// (an `NSTextView`) is, so identity-comparing the responder against the control never
    /// matched. That silent mismatch is why ⏎ in this field ran the highlighted row instead
    /// of the instruction typed into it. `currentEditor()` answers the question the
    /// responder comparison was trying to ask.
    private var isEditingInstructionField: Bool {
        customField.currentEditor() != nil
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Quick pick 1..9. This monitor runs before the field editor sees the event, so
            // the guard decides whether a digit is a shortcut or a character. In the filter
            // it stays a shortcut (that is the footer's "1-9 Quick", and no action name has
            // a digit in it); in the instruction field it is part of a sentence the user is
            // composing — "summarize in 3 bullets" must not fire action 3 and throw the rest
            // away. ⌘ asks for the shortcut from either field.
            let chars = event.charactersIgnoringModifiers ?? ""
            if let num = Int(chars), num >= 1 && num <= 9,
               !self.isEditingInstructionField || event.modifierFlags.contains(.command) {
                let idx = num - 1
                if idx < self.filteredActions.count {
                    self.onPick(AIActionSelection(kind: self.filteredActions[idx]))
                    return nil
                }
            }

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
                    self.confirmReturn()
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === searchField {
            applyProjection(AIActionPaletteProjection(
                actions: allActions,
                query: searchField.stringValue,
                localize: { loc.s($0) }
            ))
        }
    }

    private func applyProjection(_ projection: AIActionPaletteProjection) {
        filteredActions = projection.actions
        selection = projection.initialSelection ?? -1
        tableView.reloadData()
        emptyState.isHidden = !projection.showsEmptyState
        if let selected = projection.initialSelection {
            tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !filteredActions.isEmpty else { return }
        selection = min(max(0, selection + delta), filteredActions.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        tableView.scrollRowToVisible(selection)
    }

    /// ⏎: the instruction field wins while it is being edited, otherwise the highlighted row.
    /// `AIActionSelection` owns that decision so the typed text and `.custom` travel together —
    /// `.custom` on its own is a wrapper prompt with no direction in it.
    private func confirmReturn() {
        guard let selection = AIActionSelection.confirmingReturn(
            instructionFieldText: customField.stringValue,
            // `.custom` is a model transform, so with no model there is no custom pick to
            // make. The field is disabled in that state too; this does not lean on a
            // disabled NSTextField refusing to open a field editor.
            isEditingInstructionField: isEditingInstructionField && modelUnavailable == nil,
            highlightedAction: highlightedAction
        ) else { return }
        onPick(selection)
    }

    /// Double-click: always the row under the cursor, never the instruction field.
    @objc private func confirmSelection() {
        guard let kind = highlightedAction else { return }
        onPick(AIActionSelection(kind: kind))
    }

    private var highlightedAction: AITransformKind? {
        filteredActions.indices.contains(selection) ? filteredActions[selection] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredActions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredActions.indices.contains(row) else { return nil }
        let kind = filteredActions[row]
        let identifier = NSUserInterfaceItemIdentifier("aiActionCell")
        let cell: AIActionRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? AIActionRowView {
            cell = reused
        } else {
            cell = AIActionRowView()
            cell.identifier = identifier
        }

        let numStr = row < 9 ? "\(row + 1)" : nil
        let presentation = AIActionPresentation(kind: kind)
        cell.configure(
            shortcut: numStr,
            title: loc.s(kind.localizationKey),
            detail: loc.s(presentation.descriptionKey),
            tag: loc.s(presentation.behavior.localizationKey),
            tagTint: behaviorTint(for: presentation.behavior)
        )
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

    private func behaviorTint(for behavior: AIActionBehavior) -> NSColor {
        switch behavior {
        case .preserves:
            return DevTypeTheme.statusGreen
        case .shortens:
            return DevTypeTheme.statusOrange
        case .expands:
            return DevTypeTheme.statusBlue
        case .rewrites:
            return DevTypeTheme.accent
        }
    }
}

// MARK: - Row View

private final class AIActionRowView: NSTableCellView {
    private let shortcutCap = KeyCapView("1")
    private let titleLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(13, .semibold), color: DevTypeTheme.textPrimary)
    private let detailLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10.5), color: DevTypeTheme.textSecondary)
    private let tagPill = PillBadgeView(text: "", tint: DevTypeTheme.accent)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        shortcutCap.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        tagPill.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(shortcutCap)
        addSubview(textStack)
        addSubview(tagPill)

        NSLayoutConstraint.activate([
            shortcutCap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            shortcutCap.centerYAnchor.constraint(equalTo: centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: shortcutCap.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: tagPill.leadingAnchor, constant: -8),

            tagPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            tagPill.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(shortcut: String?, title: String, detail: String, tag: String, tagTint: NSColor) {
        if let shortcut {
            shortcutCap.isHidden = false
            shortcutCap.text = shortcut
        } else {
            shortcutCap.isHidden = true
        }
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        tagPill.update(text: tag, tint: tagTint)
    }
}
