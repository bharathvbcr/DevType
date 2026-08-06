import AppKit
import Carbon.HIToolbox
import ExpanderEngine

// MARK: - §5.4 — key-command aware table views
//
// The manager built its context menus with `keyEquivalent: ""` on every item and
// had no `keyDown` / `performKeyEquivalent` override anywhere in the file, so
// Edit, Duplicate, Delete, and Move to Group were **right-click only**. Delete
// did not delete and ⌘D did not duplicate.
//
// A `keyDown` hook on the table itself is the reliable route: the table is first
// responder whenever the list has focus, so it sees plain Delete and Return as
// well as ⌘-modified keys, without depending on key-equivalent traversal order.

private final class KeyCommandTableView: NSTableView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

private final class KeyCommandOutlineView: NSOutlineView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - §4.6 — sorting
//
// There was no `sortDescriptor` or `sorted(by` anywhere in `Sources/DevTypeApp/`:
// the list was always in raw storage order with no way to find the snippet you
// use most. `manual` preserves storage order and is the only mode in which
// drag-to-reorder makes sense.
enum SnippetSortMode: Int, CaseIterable {
    case manual
    case title
    case trigger
    case usage
    case recentlyUsed
    case recentlyEdited

    var title: String {
        switch self {
        case .manual: return LocalizationManager.shared.s("manager.sort.manual")
        case .title: return LocalizationManager.shared.s("manager.sort.title")
        case .trigger: return LocalizationManager.shared.s("manager.sort.trigger")
        case .usage: return LocalizationManager.shared.s("manager.sort.usage")
        case .recentlyUsed: return LocalizationManager.shared.s("manager.sort.recent")
        case .recentlyEdited: return LocalizationManager.shared.s("manager.sort.updated")
        }
    }

    /// The equivalent `NSSortDescriptor`, published on the table so anything that
    /// inspects `tableView.sortDescriptors` sees the truth.
    var sortDescriptor: NSSortDescriptor? {
        switch self {
        case .manual: return nil
        case .title: return NSSortDescriptor(key: "title", ascending: true)
        case .trigger: return NSSortDescriptor(key: "triggerKeyword", ascending: true)
        case .usage: return NSSortDescriptor(key: "usageCount", ascending: false)
        case .recentlyUsed: return NSSortDescriptor(key: "lastUsedAt", ascending: false)
        case .recentlyEdited: return NSSortDescriptor(key: "updatedAt", ascending: false)
        }
    }

    static let defaultsKey = "devtype.manager.sortMode"
}

// MARK: - Snippet row cell

/// One snippet row: enable switch, title + preview, trigger pill, usage count.
private final class SnippetRowView: NSView {
    let enableSwitch = NSSwitch()
    private let titleLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(13, .semibold), color: DevTypeTheme.textPrimary)
    private let previewLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11), color: DevTypeTheme.textSecondary)
    private let triggerPill = PillBadgeView(text: "", tint: DevTypeTheme.accent, font: DevTypeTheme.mono(11, .bold))
    private let usageLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10, .medium), color: DevTypeTheme.textTertiary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false
        enableSwitch.controlSize = .small
        titleLabel.lineBreakMode = .byTruncatingTail
        previewLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        usageLabel.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(enableSwitch)
        addSubview(titleLabel)
        addSubview(previewLabel)
        addSubview(triggerPill)
        addSubview(usageLabel)
        addSubview(separator)

        NSLayoutConstraint.activate([
            enableSwitch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            enableSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: enableSwitch.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: triggerPill.leadingAnchor, constant: -10),

            previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: triggerPill.leadingAnchor, constant: -10),

            triggerPill.trailingAnchor.constraint(equalTo: usageLabel.leadingAnchor, constant: -10),
            triggerPill.centerYAnchor.constraint(equalTo: centerYAnchor),

            usageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            usageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            usageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),

            separator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// §4.5: `usageCount` is passed in rather than read from `snippet.usageCount`
    /// — usage now lives in a coalesced sidecar and the model field is legacy.
    func configure(with snippet: SnippetModel, usageCount: Int) {
        let loc = LocalizationManager.shared
        enableSwitch.state = snippet.enabled ? .on : .off
        titleLabel.stringValue = snippet.displayTitle
        titleLabel.textColor = snippet.enabled ? DevTypeTheme.textPrimary : DevTypeTheme.textTertiary
        let preview = snippet.isImageSnippet
            ? "🖼 \(snippet.imagePath)"
            : snippet.replacementText.replacingOccurrences(of: "\n", with: " ↵ ")
        previewLabel.stringValue = preview
        triggerPill.update(
            text: snippet.triggerKeyword.isEmpty ? "·" : snippet.triggerKeyword,
            tint: snippet.enabled ? DevTypeTheme.accent : DevTypeTheme.statusGray
        )
        usageLabel.stringValue = usageCount > 0 ? "×\(usageCount)" : ""

        // §5.1: the NSSwitch had no label at all, so VoiceOver said "switch, on"
        // with no indication of *which* snippet it toggles. The row itself was
        // four unlabeled text fields in a plain NSView.
        let spokenTrigger = snippet.triggerKeyword.isEmpty
            ? loc.s("ax.noTrigger")
            : snippet.triggerKeyword
        enableSwitch.setAccessibilityLabel(loc.s("ax.snippetRow.toggle", snippet.displayTitle))
        enableSwitch.setAccessibilityValue(loc.s(snippet.enabled ? "ax.enabled" : "ax.disabled"))
        for label in [titleLabel, previewLabel, usageLabel] {
            label.setAccessibilityElement(false)
        }
        triggerPill.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(NSAccessibility.Role.row)
        setAccessibilityLabel(loc.s("ax.snippetRow", snippet.displayTitle, spokenTrigger))
        // §5.2: enabled/disabled is spoken, not conveyed by dimming alone.
        setAccessibilityValue(loc.s(snippet.enabled ? "ax.enabled" : "ax.disabled"))
        setAccessibilityHelp(loc.s("ax.snippetRow.help", usageCount))
        // The switch stays an element in its own right so VO can flip it.
        setAccessibilityChildren([enableSwitch])
    }
}

// MARK: - Sidebar row

/// Source-list style group row: tinted icon chip (custom symbol + group color),
/// name, and snippet count. Disabled groups render dimmed.
private final class GroupRowView: NSView {
    private let iconChip = NSView()
    private let iconView = NSImageView()
    private let nameLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(12.5, .medium), color: DevTypeTheme.textPrimary)
    private let countLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10.5, .semibold), color: DevTypeTheme.textTertiary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconChip.wantsLayer = true
        iconChip.translatesAutoresizingMaskIntoConstraints = false
        iconChip.layer?.cornerRadius = 6
        iconChip.layer?.borderWidth = 1

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        iconChip.addSubview(iconView)
        addSubview(iconChip)
        addSubview(nameLabel)
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            iconChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconChip.widthAnchor.constraint(equalToConstant: 22),
            iconChip.heightAnchor.constraint(equalToConstant: 22),

            iconView.centerXAnchor.constraint(equalTo: iconChip.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconChip.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),

            nameLabel.leadingAnchor.constraint(equalTo: iconChip.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),

            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String, name: String, count: Int?, tint: NSColor, enabled: Bool) {
        let loc = LocalizationManager.shared
        let effective = enabled ? tint : DevTypeTheme.textTertiary
        iconChip.layer?.backgroundColor = effective.withAlphaComponent(0.14).cgColor
        iconChip.layer?.borderColor = effective.withAlphaComponent(0.32).cgColor
        iconView.image = DevTypeTheme.tintedSymbol(symbol, size: 11, weight: .semibold, color: effective)
        nameLabel.stringValue = name
        nameLabel.textColor = enabled ? DevTypeTheme.textPrimary : DevTypeTheme.textTertiary
        countLabel.stringValue = count.map { "\($0)" } ?? ""
        // §5.2: dimming to 0.72 alpha plus a colour shift was the *only* signal
        // that a group was disabled. Keep the visual, add a strikethrough so the
        // difference survives greyscale, and speak it over AX below.
        alphaValue = enabled ? 1.0 : 0.72
        if enabled {
            nameLabel.stringValue = name
        } else {
            nameLabel.attributedStringValue = NSAttributedString(
                string: name,
                attributes: [
                    .font: nameLabel.font ?? DevTypeTheme.font(12.5, .medium),
                    .foregroundColor: DevTypeTheme.textTertiary,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: DevTypeTheme.textTertiary
                ]
            )
        }

        // §5.1: one labelled element instead of two anonymous text fields.
        iconChip.setAccessibilityElement(false)
        iconView.setAccessibilityElement(false)
        nameLabel.setAccessibilityElement(false)
        countLabel.setAccessibilityElement(false)
        var value = loc.s(enabled ? "ax.enabled" : "ax.disabled")
        if let count { value += ", " + loc.s("ax.groupRow.count", count) }
        dtApplyAccessibility(
            role: NSAccessibility.Role.row,
            label: loc.s("ax.groupRow", name),
            value: value,
            help: loc.s("ax.groupRow.help")
        )
    }
}

// MARK: - Empty state

/// Centered placeholder for an empty snippet list: icon badge, title, subtitle,
/// and an optional call-to-action capsule.
private final class EmptyStateView: NSView {
    private let badge = IconBadgeView(symbol: "text.badge.plus", tint: DevTypeTheme.accent, size: 46, pointSize: 20)
    private let titleLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(13, .semibold), color: DevTypeTheme.textSecondary)
    private let subtitleLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11), color: DevTypeTheme.textTertiary, wrapping: true)
    private let ctaButton = CapsuleButton(title: "", symbol: "plus", style: .primary, target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2

        addSubview(badge)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(ctaButton)

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor),
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),

            titleLabel.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),

            ctaButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            ctaButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            ctaButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, subtitle: String, ctaTitle: String?, target: AnyObject?, action: Selector?) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        if let ctaTitle {
            ctaButton.title = ctaTitle
            ctaButton.target = target
            ctaButton.action = action
            ctaButton.isHidden = false
        } else {
            ctaButton.isHidden = true
        }
    }
}

// MARK: - Snippet Manager (Crimson Glass)

final class SnippetManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private var groupOutline = KeyCommandOutlineView()
    private var groupScroll = NSScrollView()
    private var tableView = KeyCommandTableView()
    private var scrollView = NSScrollView()
    private var filterField = NSSearchField()
    private var groups: [SnippetGroup] = []
    private var selectedGroupID: UUID?
    private var snippets: [SnippetModel] = []
    private var statsPill = PillBadgeView(text: "", tint: DevTypeTheme.accent)
    private let emptyState = EmptyStateView()
    private let loc = LocalizationManager.shared

    // §4.6: sorting + undo.
    private var sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sortMode: SnippetSortMode = {
        let raw = UserDefaults.standard.integer(forKey: SnippetSortMode.defaultsKey)
        return SnippetSortMode(rawValue: raw) ?? .manual
    }()

    /// §4.6: there was no `UndoManager` / `registerUndo` anywhere in `Sources/`.
    /// Delete was a modal confirm and then gone forever, and the Edit menu's ⌘Z
    /// only ever reached `NSTextView`'s field editor.
    ///
    /// Undo here is snapshot-based: each mutation records the whole `groups`
    /// array before the change. That is a few kilobytes per step for a realistic
    /// library and it means every operation — add, edit, delete, duplicate, move,
    /// reorder, toggle, group edits, even Reset Defaults — is undoable without
    /// hand-writing an inverse for each one.
    private let snippetUndoManager = UndoManager()

    /// §0.3: non-modal banner for an unreadable / unwritable / conflicted library.
    private let healthBanner = LibraryHealthBannerView()
    private var healthToken: UUID?

    /// Returning our manager from the responder chain is what makes the standard
    /// Edit ▸ Undo item (and ⌘Z) reach snippet edits when the table has focus,
    /// while a focused text field still gets its own field-editor undo.
    override var undoManager: UndoManager? { snippetUndoManager }

    private lazy var groupContextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    private lazy var snippetContextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    override func loadView() {
        let mainView = NSView()
        mainView.wantsLayer = true
        mainView.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        // MARK: Header (below the 34pt traffic-light strip)
        let logo = NSImageView()
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.image = DevTypeTheme.load3DLogoImage(size: NSSize(width: 28, height: 28))
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.wantsLayer = true
        logo.layer?.cornerRadius = 7
        logo.layer?.masksToBounds = true
        logo.layer?.borderColor = DevTypeTheme.accent.withAlphaComponent(0.4).cgColor
        logo.layer?.borderWidth = 1

        let titleLabel = DevTypeTheme.makeLabel(
            loc.s("manager.title"),
            font: DevTypeTheme.font(18, .bold),
            color: DevTypeTheme.textPrimary
        )
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statsPill.translatesAutoresizingMaskIntoConstraints = false

        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.placeholderString = loc.s("manager.filter")
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.controlSize = .regular
        filterField.setAccessibilityLabel(loc.s("manager.filter"))

        // §4.6: sort control. The list column is view-based with no header, so
        // the descriptor is driven from here and mirrored onto
        // `tableView.sortDescriptors`.
        sortPopup.translatesAutoresizingMaskIntoConstraints = false
        sortPopup.removeAllItems()
        for mode in SnippetSortMode.allCases {
            sortPopup.addItem(withTitle: mode.title)
            sortPopup.lastItem?.tag = mode.rawValue
        }
        sortPopup.selectItem(withTag: sortMode.rawValue)
        sortPopup.target = self
        sortPopup.action = #selector(sortModeChanged)
        sortPopup.controlSize = .small
        sortPopup.toolTip = loc.s("manager.sort.hint")
        sortPopup.setAccessibilityLabel(loc.s("manager.sort"))

        mainView.addSubview(logo)
        mainView.addSubview(titleLabel)
        mainView.addSubview(statsPill)
        mainView.addSubview(sortPopup)
        mainView.addSubview(filterField)

        // MARK: Sidebar (groups) — glass card
        let sidebarCard = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.05))
        sidebarCard.translatesAutoresizingMaskIntoConstraints = false
        mainView.addSubview(sidebarCard)
        let sidebarContent = sidebarCard.contentView

        let groupsCaption = DevTypeTheme.makeLabel(
            "GROUPS",
            font: DevTypeTheme.font(10, .bold),
            color: DevTypeTheme.textTertiary
        )
        groupsCaption.translatesAutoresizingMaskIntoConstraints = false
        sidebarContent.addSubview(groupsCaption)

        // Quick "add group" affordance next to the caption.
        let addGroupCaptionButton = NSButton()
        addGroupCaptionButton.isBordered = false
        addGroupCaptionButton.wantsLayer = true
        addGroupCaptionButton.layer?.cornerRadius = 4
        addGroupCaptionButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        addGroupCaptionButton.image = DevTypeTheme.tintedSymbol("plus", size: 9, weight: .bold, color: DevTypeTheme.textSecondary)
        addGroupCaptionButton.imageScaling = .scaleProportionallyUpOrDown
        addGroupCaptionButton.toolTip = loc.s("manager.group.add")
        addGroupCaptionButton.target = self
        addGroupCaptionButton.action = #selector(addGroup)
        addGroupCaptionButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarContent.addSubview(addGroupCaptionButton)

        groupScroll.translatesAutoresizingMaskIntoConstraints = false
        groupScroll.hasVerticalScroller = true
        groupScroll.autohidesScrollers = true
        groupScroll.borderType = .noBorder
        groupScroll.drawsBackground = false

        groupOutline.headerView = nil
        groupOutline.dataSource = self
        groupOutline.delegate = self
        groupOutline.rowSizeStyle = .default
        groupOutline.rowHeight = 30
        groupOutline.intercellSpacing = NSSize(width: 0, height: 2)
        groupOutline.backgroundColor = .clear
        groupOutline.selectionHighlightStyle = .regular
        groupOutline.indentationPerLevel = 0
        groupOutline.registerForDraggedTypes([.string])
        groupOutline.menu = groupContextMenu
        groupOutline.setAccessibilityLabel(loc.s("ax.groupsTable"))
        // §5.4: Return edits the group, Delete removes it.
        groupOutline.onKeyDown = { [weak self] event in
            self?.handleGroupKeyDown(event) ?? false
        }
        let groupCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("group"))
        groupCol.title = "Groups"
        groupOutline.addTableColumn(groupCol)
        groupOutline.outlineTableColumn = groupCol
        groupScroll.documentView = groupOutline
        sidebarContent.addSubview(groupScroll)

        // Bottom "New Group" bar — the always-visible way to organise groups.
        let newGroupBar = NSView()
        newGroupBar.translatesAutoresizingMaskIntoConstraints = false
        let barHairline = DevTypeTheme.makeHairline()
        let newGroupButton = CapsuleButton(
            title: loc.s("manager.group.add"),
            symbol: "folder.badge.plus",
            style: .secondary,
            target: self,
            action: #selector(addGroup)
        )
        newGroupBar.addSubview(barHairline)
        newGroupBar.addSubview(newGroupButton)
        sidebarContent.addSubview(newGroupBar)

        NSLayoutConstraint.activate([
            groupsCaption.topAnchor.constraint(equalTo: sidebarContent.topAnchor, constant: 12),
            groupsCaption.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor, constant: 16),

            addGroupCaptionButton.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor, constant: -10),
            addGroupCaptionButton.centerYAnchor.constraint(equalTo: groupsCaption.centerYAnchor),
            addGroupCaptionButton.widthAnchor.constraint(equalToConstant: 18),
            addGroupCaptionButton.heightAnchor.constraint(equalToConstant: 18),

            groupScroll.topAnchor.constraint(equalTo: groupsCaption.bottomAnchor, constant: 6),
            groupScroll.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor),
            groupScroll.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor),
            groupScroll.bottomAnchor.constraint(equalTo: newGroupBar.topAnchor, constant: -4),

            newGroupBar.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor),
            newGroupBar.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor),
            newGroupBar.bottomAnchor.constraint(equalTo: sidebarContent.bottomAnchor),
            newGroupBar.heightAnchor.constraint(equalToConstant: 42),

            barHairline.topAnchor.constraint(equalTo: newGroupBar.topAnchor),
            barHairline.leadingAnchor.constraint(equalTo: newGroupBar.leadingAnchor, constant: 10),
            barHairline.trailingAnchor.constraint(equalTo: newGroupBar.trailingAnchor, constant: -10),

            newGroupButton.centerXAnchor.constraint(equalTo: newGroupBar.centerXAnchor),
            newGroupButton.centerYAnchor.constraint(equalTo: newGroupBar.centerYAnchor, constant: 2)
        ])

        // MARK: Snippet list — glass card
        let listCard = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.05))
        listCard.translatesAutoresizingMaskIntoConstraints = false
        let listContent = listCard.contentView

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(editSelectedSnippet)
        tableView.target = self
        tableView.menu = snippetContextMenu
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(loc.s("ax.snippetsTable"))
        // §4.6: drag-to-reorder inside the selected group (manual sort only).
        tableView.registerForDraggedTypes([.string])
        tableView.draggingDestinationFeedbackStyle = .gap
        // §5.4: Delete deletes, Return edits, ⌘D duplicates.
        tableView.onKeyDown = { [weak self] event in
            self?.handleSnippetKeyDown(event) ?? false
        }
        scrollView.documentView = tableView
        listContent.addSubview(scrollView)

        // §0.3: banner sits above the list, pushing it down only when unhealthy.
        healthBanner.isHidden = true
        listContent.addSubview(healthBanner)

        emptyState.isHidden = true
        listContent.addSubview(emptyState)
        mainView.addSubview(listCard)

        NSLayoutConstraint.activate([
            healthBanner.topAnchor.constraint(equalTo: listContent.topAnchor, constant: 6),
            healthBanner.leadingAnchor.constraint(equalTo: listContent.leadingAnchor, constant: 8),
            healthBanner.trailingAnchor.constraint(equalTo: listContent.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: healthBanner.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: listContent.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContent.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContent.bottomAnchor, constant: -6),

            emptyState.centerXAnchor.constraint(equalTo: listContent.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: listContent.centerYAnchor, constant: -8),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: listContent.leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: listContent.trailingAnchor, constant: -24)
        ])

        // MARK: Action bar
        let addButton = CapsuleButton(
            title: loc.s("manager.add"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(addSnippet)
        )
        let editButton = CapsuleButton(
            title: loc.s("manager.edit"),
            symbol: "pencil",
            style: .secondary,
            target: self,
            action: #selector(editSelectedSnippet)
        )
        let deleteButton = CapsuleButton(
            title: loc.s("manager.delete"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(deleteSnippet)
        )
        let importButton = CapsuleButton(
            title: loc.s("manager.import"),
            symbol: "square.and.arrow.down",
            style: .secondary,
            target: self,
            action: #selector(importSnippets)
        )
        // §0.4: export sits next to import.
        let exportButton = CapsuleButton(
            title: loc.s("manager.export"),
            symbol: "square.and.arrow.up",
            style: .secondary,
            target: self,
            action: #selector(exportSnippets)
        )
        // §4.5: the only presentation of usage was a `×N` label on each row.
        let statsButton = CapsuleButton(
            title: loc.s("manager.stats.button"),
            symbol: "chart.bar",
            style: .secondary,
            target: self,
            action: #selector(openStatistics)
        )
        let resetButton = CapsuleButton(
            title: loc.s("manager.reset"),
            symbol: "arrow.counterclockwise",
            style: .secondary,
            target: self,
            action: #selector(resetDefaults)
        )

        let primaryStack = NSStackView(views: [addButton, editButton, deleteButton])
        primaryStack.orientation = .horizontal
        primaryStack.spacing = 10
        primaryStack.translatesAutoresizingMaskIntoConstraints = false
        // Keep the stack at button height — the glass cards absorb the window's
        // extra vertical space (equal hugging would stretch the stack instead).
        primaryStack.setContentHuggingPriority(.required, for: .vertical)

        let utilityStack = NSStackView(views: [statsButton, importButton, exportButton, resetButton])
        utilityStack.orientation = .horizontal
        utilityStack.spacing = 10
        utilityStack.translatesAutoresizingMaskIntoConstraints = false
        utilityStack.setContentHuggingPriority(.required, for: .vertical)

        mainView.addSubview(primaryStack)
        mainView.addSubview(utilityStack)

        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 20),
            logo.topAnchor.constraint(equalTo: mainView.topAnchor, constant: 40),
            logo.widthAnchor.constraint(equalToConstant: 28),
            logo.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: logo.centerYAnchor),

            statsPill.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            statsPill.centerYAnchor.constraint(equalTo: logo.centerYAnchor),

            filterField.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -20),
            filterField.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            filterField.widthAnchor.constraint(equalToConstant: 200),

            sortPopup.trailingAnchor.constraint(equalTo: filterField.leadingAnchor, constant: -10),
            sortPopup.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            sortPopup.leadingAnchor.constraint(greaterThanOrEqualTo: statsPill.trailingAnchor, constant: 10),

            sidebarCard.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 14),
            sidebarCard.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 16),
            sidebarCard.bottomAnchor.constraint(equalTo: primaryStack.topAnchor, constant: -14),
            sidebarCard.widthAnchor.constraint(equalToConstant: 224),

            listCard.topAnchor.constraint(equalTo: sidebarCard.topAnchor),
            listCard.leadingAnchor.constraint(equalTo: sidebarCard.trailingAnchor, constant: 12),
            listCard.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -16),
            listCard.bottomAnchor.constraint(equalTo: sidebarCard.bottomAnchor),

            primaryStack.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 20),
            primaryStack.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -16),

            utilityStack.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -20),
            utilityStack.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -16)
        ])

        self.view = mainView
    }

    private var listenerToken: UUID?

    override func viewDidLoad() {
        super.viewDidLoad()
        if listenerToken == nil {
            listenerToken = SnippetStore.shared.addGroupListener { [weak self] _ in
                DispatchQueue.main.async { self?.reloadGroups() }
            }
        }
        // §0.3: subscribe to library health so the banner reflects a blocked
        // save or an iCloud conflict without a modal.
        if healthToken == nil {
            LibraryHealthMonitor.shared.start()
            healthToken = LibraryHealthMonitor.shared.addObserver { [weak self] condition in
                self?.applyHealth(condition)
            }
        }
        reloadGroups()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // §4.5: `incrementUsage` no longer fires store listeners, so the `×N`
        // column is refreshed on appearance rather than waiting for a push.
        applyFilterAndReloadTable()
    }

    deinit {
        if let token = listenerToken {
            SnippetStore.shared.removeListener(token: token)
        }
        if let healthToken {
            LibraryHealthMonitor.shared.removeObserver(healthToken)
        }
    }

    private func applyHealth(_ condition: LibraryCondition?) {
        healthBanner.apply(
            condition,
            onAction: { [weak self] in
                guard let self, let condition = LibraryHealthMonitor.shared.condition else { return }
                LibraryHealthPresenter.present(condition, window: self.view.window)
            },
            onDismiss: {
                LibraryHealthMonitor.shared.dismiss()
            }
        )
    }

    @objc private func filterChanged() {
        applyFilterAndReloadTable()
    }

    @objc private func sortModeChanged() {
        sortMode = SnippetSortMode(rawValue: sortPopup.selectedTag()) ?? .manual
        UserDefaults.standard.set(sortMode.rawValue, forKey: SnippetSortMode.defaultsKey)
        applyFilterAndReloadTable()
    }

    private func reloadGroups() {
        groups = SnippetStore.shared.loadGroups()
        if selectedGroupID == nil, let first = groups.first {
            selectedGroupID = first.id
        }
        groupOutline.reloadData()
        if let id = selectedGroupID,
           let index = groups.firstIndex(where: { $0.id == id }) {
            groupOutline.selectRowIndexes(IndexSet(integer: index + 1), byExtendingSelection: false)
        } else {
            groupOutline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        applyFilterAndReloadTable()
    }

    private func applyFilterAndReloadTable() {
        let filter = filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool: [SnippetModel]
        if let id = selectedGroupID, let group = groups.first(where: { $0.id == id }) {
            pool = group.snippets
        } else {
            pool = groups.flatMap(\.snippets)
        }
        if filter.isEmpty {
            snippets = pool
        } else {
            snippets = pool.filter {
                $0.triggerKeyword.lowercased().contains(filter)
                    || $0.displayTitle.lowercased().contains(filter)
                    || $0.replacementText.lowercased().contains(filter)
            }
        }
        snippets = sorted(snippets)
        tableView.sortDescriptors = sortMode.sortDescriptor.map { [$0] } ?? []
        let all = groups.flatMap(\.snippets)
        let active = all.filter(\.enabled).count
        statsPill.update(text: loc.s("manager.stats", active, all.count), tint: DevTypeTheme.accent)

        emptyState.isHidden = !snippets.isEmpty
        if snippets.isEmpty {
            emptyState.configure(
                title: filter.isEmpty
                    ? loc.s("manager.empty.title")
                    : loc.s("snippets.empty.noMatch", filterField.stringValue),
                subtitle: filter.isEmpty ? loc.s("manager.empty.subtitle") : "",
                ctaTitle: filter.isEmpty ? loc.s("manager.add") : nil,
                target: self,
                action: #selector(addSnippet)
            )
        }
        tableView.reloadData()
    }

    /// §4.6: applies the active sort. `manual` preserves storage order, which is
    /// also the only mode where drag-to-reorder is meaningful.
    private func sorted(_ input: [SnippetModel]) -> [SnippetModel] {
        let store = SnippetStore.shared
        switch sortMode {
        case .manual:
            return input
        case .title:
            return input.sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
        case .trigger:
            return input.sorted {
                $0.triggerKeyword.localizedStandardCompare($1.triggerKeyword) == .orderedAscending
            }
        case .usage:
            // §4.5: usage lives in the sidecar, not on the model.
            return input.sorted { store.usageCount(for: $0) > store.usageCount(for: $1) }
        case .recentlyUsed:
            return input.sorted {
                let left = store.lastUsedAt(forSnippetID: $0.id) ?? Date.distantPast
                let right = store.lastUsedAt(forSnippetID: $1.id) ?? Date.distantPast
                return left > right
            }
        case .recentlyEdited:
            return input.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// §1.4: `saveGroups` returns a `SaveOutcome` that every caller used to
    /// discard (`_ = SnippetStore.shared.saveGroups(groups)`), so the UI reported
    /// success for writes that never landed. Blocked outcomes now reach the
    /// health monitor, which raises the banner.
    private func persistGroups() {
        let outcome = SnippetStore.shared.saveGroups(groups)
        if !outcome.didSave {
            DevTypeLog.app.error("[Manager] save refused — surfacing banner")
            LibraryHealthMonitor.shared.refresh()
        }
    }

    // MARK: - §4.6 Undo
    //
    // Every mutation funnels through here so undo/redo comes for free.
    // `registerUndo` inside an undo *is* how redo gets registered — the manager
    // is in its undoing state at that point and routes the new registration onto
    // the redo stack.

    private func mutate(_ actionName: String, _ body: (inout [SnippetGroup]) -> Void) {
        let before = groups
        body(&groups)
        guard groups != before else { return }
        registerUndo(restoring: before, actionName: actionName)
        persistGroups()
        reloadGroups()
    }

    private func registerUndo(restoring snapshot: [SnippetGroup], actionName: String) {
        snippetUndoManager.registerUndo(withTarget: self) { target in
            let redoSnapshot = target.groups
            target.groups = snapshot
            target.registerUndo(restoring: redoSnapshot, actionName: actionName)
            target.persistGroups()
            target.reloadGroups()
        }
        snippetUndoManager.setActionName(actionName)
    }

    private func groupIndex(for snippetID: UUID) -> (Int, Int)? {
        for gi in groups.indices {
            if let si = groups[gi].snippets.firstIndex(where: { $0.id == snippetID }) {
                return (gi, si)
            }
        }
        return nil
    }

    // MARK: - Snippet actions

    @objc private func addSnippet() {
        presentEditor(for: nil)
    }

    @objc private func editSelectedSnippet() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < snippets.count else { return }
        presentEditor(for: snippets[selectedRow])
    }

    private func presentEditor(for existing: SnippetModel?) {
        SnippetEditorSheet.present(
            from: view.window,
            existing: existing,
            groups: groups,
            currentGroupID: selectedGroupID,
            validate: { [weak self] trigger, caseSensitive in
                self?.duplicateTriggerConflict(
                    trigger: trigger,
                    caseSensitive: caseSensitive,
                    excludingID: existing?.id
                )
            },
            completion: { [weak self] result, chosenGroupID in
                guard let self, let snippet = result else { return }
                let isEdit = existing != nil
                // §4.6: undoable.
                self.mutate(self.loc.s(isEdit ? "manager.undo.edit" : "manager.undo.add")) { groups in
                    if isEdit {
                        for gi in groups.indices {
                            guard let si = groups[gi].snippets.firstIndex(where: { $0.id == snippet.id })
                            else { continue }
                            groups[gi].snippets[si] = snippet
                            if let chosenGroupID,
                               let destGI = groups.firstIndex(where: { $0.id == chosenGroupID }),
                               destGI != gi {
                                groups[gi].snippets.remove(at: si)
                                groups[destGI].snippets.append(snippet)
                            }
                            break
                        }
                    } else {
                        let targetGI: Int
                        if let id = chosenGroupID ?? self.selectedGroupID,
                           let gi = groups.firstIndex(where: { $0.id == id }) {
                            targetGI = gi
                        } else if let gi = groups.firstIndex(where: { $0.name == SnippetDocument.defaultGroupName }) {
                            targetGI = gi
                        } else if groups.isEmpty {
                            groups = [SnippetGroup(name: SnippetDocument.defaultGroupName)]
                            targetGI = 0
                        } else {
                            targetGI = 0
                        }
                        groups[targetGI].snippets.append(snippet)
                    }
                }
            }
        )
    }

    private func duplicateTriggerConflict(trigger: String, caseSensitive: Bool, excludingID: UUID?) -> String? {
        for other in groups.flatMap(\.snippets) {
            if let excludingID, other.id == excludingID { continue }
            let collide: Bool
            if caseSensitive && other.isCaseSensitive {
                collide = other.triggerKeyword == trigger
            } else {
                collide = other.triggerKeyword.lowercased() == trigger.lowercased()
            }
            if collide {
                return loc.s("editor.error.conflict", trigger, other.triggerKeyword)
            }
        }
        return nil
    }

    private func presentValidationError(_ message: String) {
        DevTypeAlert.warn(
            title: loc.s("alert.invalidSnippet.title"),
            message: message,
            window: view.window
        )
    }

    @objc private func deleteSnippet() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < snippets.count else { return }
        let snippet = snippets[selectedRow]

        DevTypeAlert.confirm(
            title: loc.s("manager.delete.confirm.title"),
            message: loc.s("manager.delete.confirm.message", snippet.displayTitle),
            confirmTitle: loc.s("manager.delete"),
            destructive: true,
            window: view.window
        ) { [weak self] in
            guard let self else { return }
            // §4.6: delete used to be a modal confirm and then gone forever.
            self.mutate(self.loc.s("manager.undo.delete")) { groups in
                for gi in groups.indices {
                    if let si = groups[gi].snippets.firstIndex(where: { $0.id == snippet.id }) {
                        groups[gi].snippets.remove(at: si)
                        break
                    }
                }
            }
        }
    }

    @objc private func duplicateSelectedSnippet() {
        let row = tableView.selectedRow
        guard row >= 0, row < snippets.count else { return }
        let source = snippets[row]
        guard let (gi, _) = groupIndex(for: source.id) else { return }
        let copy = SnippetModel(
            title: source.title,
            label: source.label.isEmpty ? "" : source.label + " copy",
            triggerKeyword: uniqueTrigger(basedOn: source.triggerKeyword),
            replacementText: source.replacementText,
            isCaseSensitive: source.isCaseSensitive,
            requireWordBoundary: source.requireWordBoundary,
            isPlainText: source.isPlainText,
            enabled: source.enabled,
            usageCount: 0
        )
        mutate(loc.s("manager.undo.duplicate")) { groups in
            guard groups.indices.contains(gi) else { return }
            groups[gi].snippets.append(copy)
        }
    }

    private func uniqueTrigger(basedOn base: String) -> String {
        let existing = Set(groups.flatMap(\.snippets).map { $0.triggerKeyword.lowercased() })
        var candidate = base + "-copy"
        var suffix = 2
        while existing.contains(candidate.lowercased()) {
            candidate = "\(base)-copy\(suffix)"
            suffix += 1
        }
        return candidate
    }

    @objc private func moveSelectedSnippetToGroup(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let destID = UUID(uuidString: raw),
              let destGI = groups.firstIndex(where: { $0.id == destID }) else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < snippets.count else { return }
        let snippet = snippets[row]
        guard let (gi, si) = groupIndex(for: snippet.id), gi != destGI else { return }
        mutate(loc.s("manager.undo.move")) { groups in
            guard groups.indices.contains(gi),
                  groups[gi].snippets.indices.contains(si),
                  groups.indices.contains(destGI) else { return }
            groups[gi].snippets.remove(at: si)
            groups[destGI].snippets.append(snippet)
        }
    }

    // MARK: - Group actions

    @objc private func addGroup() {
        GroupEditorSheet.present(
            from: view.window,
            existing: nil,
            validate: { [weak self] name in
                guard let self else { return nil }
                let clash = self.groups.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                return clash ? self.loc.s("groupeditor.error.duplicate", name) : nil
            },
            completion: { [weak self] draft in
                guard let self, let draft else { return }
                let group = SnippetGroup(
                    name: draft.name,
                    enabled: draft.enabled,
                    symbol: draft.symbol,
                    colorHex: draft.colorHex,
                    snippets: []
                )
                self.selectedGroupID = group.id
                self.mutate(self.loc.s("manager.undo.addGroup")) { groups in
                    groups.append(group)
                }
            }
        )
    }

    @objc private func editSelectedGroup() {
        let row = groupOutline.selectedRow
        guard row > 0, row - 1 < groups.count else { return }
        let group = groups[row - 1]
        GroupEditorSheet.present(
            from: view.window,
            existing: group,
            validate: { [weak self] name in
                guard let self else { return nil }
                let clash = self.groups.contains {
                    $0.id != group.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
                }
                return clash ? self.loc.s("groupeditor.error.duplicate", name) : nil
            },
            completion: { [weak self] draft in
                guard let self, let draft else { return }
                self.mutate(self.loc.s("manager.undo.editGroup")) { groups in
                    guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
                    groups[index].name = draft.name
                    groups[index].symbol = draft.symbol
                    groups[index].colorHex = draft.colorHex
                    groups[index].enabled = draft.enabled
                }
            }
        )
    }

    @objc private func toggleSelectedGroup() {
        let row = groupOutline.selectedRow
        guard row > 0, row - 1 < groups.count else { return }
        let groupID = groups[row - 1].id
        mutate(loc.s("manager.undo.toggleGroup")) { groups in
            guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[index].enabled.toggle()
        }
    }

    @objc private func deleteSelectedGroup() {
        let row = groupOutline.selectedRow
        guard row > 0, row - 1 < groups.count else { return }
        let group = groups[row - 1]

        guard groups.count > 1 else {
            DevTypeAlert.warn(
                title: loc.s("manager.group.delete.title"),
                message: loc.s("manager.group.delete.last"),
                window: view.window
            )
            return
        }

        let removeGroup: () -> Void = { [weak self] in
            guard let self else { return }
            if self.selectedGroupID == group.id { self.selectedGroupID = nil }
            self.mutate(self.loc.s("manager.undo.deleteGroup")) { groups in
                guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
                groups.remove(at: index)
            }
        }

        if group.snippets.isEmpty {
            removeGroup()
            return
        }

        // §6.2: was `"%@" contains %d snippet(s)` — a literal "(s)". Now a real
        // plural lookup that collapses to one form in Korean and Japanese.
        DevTypeAlert.present(
            title: loc.s("manager.group.delete.title"),
            message: loc.p(
                "manager.group.delete.message",
                count: group.snippets.count,
                group.name,
                group.snippets.count
            ),
            style: .warning,
            buttons: [
                loc.s("manager.group.delete.move"),
                loc.s("manager.group.delete.all"),
                loc.s("common.cancel")
            ],
            window: view.window
        ) { [weak self] index in
            guard let self else { return }
            switch index {
            case 0:
                // Move snippets into the next available group, then remove this one.
                self.mutate(self.loc.s("manager.undo.deleteGroup")) { groups in
                    guard let source = groups.firstIndex(where: { $0.id == group.id }),
                          let destination = groups.firstIndex(where: { $0.id != group.id })
                    else { return }
                    let moved = groups[source].snippets
                    groups.remove(at: source)
                    let adjusted = destination > source ? destination - 1 : destination
                    guard groups.indices.contains(adjusted) else { return }
                    groups[adjusted].snippets.append(contentsOf: moved)
                    if self.selectedGroupID == group.id {
                        self.selectedGroupID = groups[adjusted].id
                    }
                }
            case 1:
                removeGroup()
            default:
                break
            }
        }
    }

    // MARK: - Library actions

    /// §4.6: "Reset Defaults" destroyed the whole library behind one alert with
    /// no undo. It is still a confirm, but the copy now says what it costs and
    /// the change goes through the undo stack.
    @objc private func resetDefaults() {
        DevTypeAlert.confirm(
            title: loc.s("alert.reset.title"),
            message: loc.s("alert.reset.message"),
            confirmTitle: loc.s("alert.reset.confirm"),
            destructive: true,
            window: view.window
        ) { [weak self] in
            guard let self else { return }
            let defaults = SnippetStore.shared.defaultSnippets()
            self.mutate(self.loc.s("manager.undo.reset")) { groups in
                groups = [
                    SnippetGroup(name: SnippetDocument.defaultGroupName, snippets: defaults)
                ]
            }
        }
    }

    /// §4.8: delegates to the shared flow instead of duplicating the panel,
    /// the hint text, and the result alert from `AppDelegate`.
    @objc private func importSnippets() {
        SnippetImportFlow.present(from: view.window) { [weak self] in
            self?.reloadGroups()
        }
    }

    /// §0.4: JSON / Espanso YAML / CSV export.
    @objc private func exportSnippets() {
        LibraryExporter.present(from: view.window)
    }

    /// §4.5: opens the statistics pane (Preferences ▸ Snippets).
    @objc private func openStatistics() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.openPreferences(nil, tab: .snippets)
        } else {
            PreferencesWindowController.shared.show(tab: .snippets, hotkeyManager: nil)
        }
    }

    // MARK: - Context menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === groupContextMenu {
            buildGroupContextMenu(menu)
        } else if menu === snippetContextMenu {
            buildSnippetContextMenu(menu)
        }
    }

    private func buildGroupContextMenu(_ menu: NSMenu) {
        let row = groupOutline.clickedRow
        guard row > 0, row - 1 < groups.count else { return }
        groupOutline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let group = groups[row - 1]

        // §5.4: every item used to carry `keyEquivalent: ""`, so these were
        // right-click only. The equivalents shown here double as discoverability
        // for the `keyDown` handlers below.
        let edit = NSMenuItem(title: loc.s("manager.group.edit"), action: #selector(editSelectedGroup), keyEquivalent: "\r")
        edit.keyEquivalentModifierMask = []
        edit.target = self
        edit.image = DevTypeTheme.menuIcon("pencil")

        let toggle = NSMenuItem(
            title: group.enabled ? loc.s("manager.group.disable") : loc.s("manager.group.enable"),
            action: #selector(toggleSelectedGroup),
            keyEquivalent: " "
        )
        toggle.keyEquivalentModifierMask = []
        toggle.target = self
        toggle.image = DevTypeTheme.menuIcon(group.enabled ? "pause.circle" : "play.circle")

        let delete = NSMenuItem(
            title: loc.s("manager.group.delete"),
            action: #selector(deleteSelectedGroup),
            keyEquivalent: "\u{8}"
        )
        delete.keyEquivalentModifierMask = []
        delete.target = self
        delete.image = DevTypeTheme.menuIcon("trash")

        menu.items = [edit, toggle, .separator(), delete]
    }

    // MARK: - §5.4 Keyboard handling

    /// Delete removes, Return edits, ⌘D duplicates, Space toggles enabled.
    /// Returns true when the event was consumed.
    private func handleSnippetKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = Int(event.keyCode)
        let hasSelection = tableView.selectedRow >= 0 && tableView.selectedRow < snippets.count

        if modifiers == .command, code == kVK_ANSI_D {
            guard hasSelection else { return true }
            duplicateSelectedSnippet()
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch code {
        case kVK_Delete, kVK_ForwardDelete:
            guard hasSelection else { return true }
            deleteSnippet()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard hasSelection else { return true }
            editSelectedSnippet()
            return true
        case kVK_Space:
            guard hasSelection else { return true }
            toggleSelectedSnippetEnabled()
            return true
        default:
            return false
        }
    }

    /// Return edits the group, Delete removes it, Space toggles it.
    private func handleGroupKeyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
        let row = groupOutline.selectedRow
        // Row 0 is the synthetic "All Snippets" entry — it has no group actions.
        guard row > 0, row - 1 < groups.count else { return false }
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            deleteSelectedGroup()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            editSelectedGroup()
            return true
        case kVK_Space:
            toggleSelectedGroup()
            return true
        default:
            return false
        }
    }

    /// Keyboard equivalent of clicking the row's enable switch.
    @objc private func toggleSelectedSnippetEnabled() {
        let row = tableView.selectedRow
        guard row >= 0, row < snippets.count else { return }
        let id = snippets[row].id
        mutate(loc.s("manager.undo.toggle")) { groups in
            for gi in groups.indices {
                if let si = groups[gi].snippets.firstIndex(where: { $0.id == id }) {
                    groups[gi].snippets[si].enabled.toggle()
                    break
                }
            }
        }
    }

    private func buildSnippetContextMenu(_ menu: NSMenu) {
        let row = tableView.clickedRow
        guard row >= 0, row < snippets.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let snippet = snippets[row]

        // §5.4: real key equivalents. Delete deletes, Return edits, ⌘D duplicates
        // — all also handled directly in `handleSnippetKeyDown`.
        let edit = NSMenuItem(title: loc.s("manager.edit"), action: #selector(editSelectedSnippet), keyEquivalent: "\r")
        edit.keyEquivalentModifierMask = []
        edit.target = self
        edit.image = DevTypeTheme.menuIcon("pencil")

        let duplicate = NSMenuItem(
            title: loc.s("manager.duplicate"),
            action: #selector(duplicateSelectedSnippet),
            keyEquivalent: "d"
        )
        duplicate.keyEquivalentModifierMask = [.command]
        duplicate.target = self
        duplicate.image = DevTypeTheme.menuIcon("plus.square.on.square")

        let delete = NSMenuItem(
            title: loc.s("manager.delete"),
            action: #selector(deleteSnippet),
            keyEquivalent: "\u{8}"
        )
        delete.keyEquivalentModifierMask = []
        delete.target = self
        delete.image = DevTypeTheme.menuIcon("trash")

        var items: [NSMenuItem] = [edit, duplicate]

        // "Move to Group" submenu listing every other group.
        let currentGI = groupIndex(for: snippet.id)?.0
        let destinations = groups.indices.filter { $0 != currentGI }
        if !destinations.isEmpty {
            let move = NSMenuItem(title: loc.s("manager.moveToGroup"), action: nil, keyEquivalent: "")
            move.image = DevTypeTheme.menuIcon("folder")
            let submenu = NSMenu()
            for gi in destinations {
                let group = groups[gi]
                let item = NSMenuItem(title: group.name, action: #selector(moveSelectedSnippetToGroup(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = group.id.uuidString
                item.image = DevTypeTheme.menuIcon(group.symbol)
                submenu.addItem(item)
            }
            move.submenu = submenu
            items.append(move)
        }

        items.append(.separator())
        items.append(delete)
        menu.items = items
    }

    // MARK: - Outline (groups)

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? groups.count + 1 : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if index == 0 { return "all" as NSString }
        return groups[index - 1]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("groupRow")
        let row: GroupRowView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? GroupRowView {
            row = reused
        } else {
            row = GroupRowView()
            row.identifier = identifier
        }
        if let group = item as? SnippetGroup {
            row.configure(
                symbol: group.symbol,
                name: group.name,
                count: group.snippets.count,
                tint: DevTypeTheme.tint(forGroupColorHex: group.colorHex),
                enabled: group.enabled
            )
        } else {
            row.configure(
                symbol: "square.stack.3d.up.fill",
                name: loc.s("manager.group.all"),
                count: groups.flatMap(\.snippets).count,
                tint: DevTypeTheme.accent,
                enabled: true
            )
        }
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = RoundedSelectionRowView()
        rowView.selectionRadius = 7
        rowView.selectionInset = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
        return rowView
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = groupOutline.selectedRow
        guard row >= 0 else { return }
        if row == 0 {
            selectedGroupID = nil
        } else if row - 1 < groups.count {
            selectedGroupID = groups[row - 1].id
        }
        applyFilterAndReloadTable()
    }

    // MARK: Group drag-to-reorder

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let group = item as? SnippetGroup else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(group.id.uuidString, forType: .string)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard item == nil,
              index >= 1,
              info.draggingPasteboard.types?.contains(.string) == true else { return [] }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard item == nil,
              let raw = info.draggingPasteboard.string(forType: .string),
              let id = UUID(uuidString: raw),
              let from = groups.firstIndex(where: { $0.id == id }) else { return false }
        selectedGroupID = id
        // §4.6: undoable reorder.
        mutate(loc.s("manager.undo.reorderGroups")) { groups in
            guard let source = groups.firstIndex(where: { $0.id == id }) else { return }
            let group = groups.remove(at: source)
            var destination = index - 1
            if source < destination { destination -= 1 }
            destination = max(0, min(destination, groups.count))
            groups.insert(group, at: destination)
        }
        _ = from
        return true
    }

    // MARK: - §4.6 Snippet drag-to-reorder (manual sort, single group, no filter)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard canReorderSnippets, snippets.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(snippets[row].id.uuidString, forType: .string)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard canReorderSnippets,
              dropOperation == .above,
              info.draggingPasteboard.types?.contains(.string) == true else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard canReorderSnippets,
              let raw = info.draggingPasteboard.string(forType: .string),
              let id = UUID(uuidString: raw),
              let groupID = selectedGroupID else { return false }
        mutate(loc.s("manager.undo.reorder")) { groups in
            guard let gi = groups.firstIndex(where: { $0.id == groupID }),
                  let source = groups[gi].snippets.firstIndex(where: { $0.id == id }) else { return }
            let snippet = groups[gi].snippets.remove(at: source)
            var destination = row
            if source < destination { destination -= 1 }
            destination = max(0, min(destination, groups[gi].snippets.count))
            groups[gi].snippets.insert(snippet, at: destination)
        }
        return true
    }

    /// Reordering only makes sense when the visible list *is* the stored order:
    /// one concrete group, no filter, manual sort.
    private var canReorderSnippets: Bool {
        sortMode == .manual
            && selectedGroupID != nil
            && filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { snippets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < snippets.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("snippetRow")
        let cell: SnippetRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? SnippetRowView {
            cell = reused
        } else {
            cell = SnippetRowView()
            cell.identifier = identifier
            cell.enableSwitch.target = self
            cell.enableSwitch.action = #selector(toggleSnippetEnabled(_:))
        }
        cell.enableSwitch.tag = row
        // §4.5: usage read from the store, not the legacy model field.
        cell.configure(
            with: snippets[row],
            usageCount: SnippetStore.shared.usageCount(for: snippets[row])
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RoundedSelectionRowView()
    }

    @objc private func toggleSnippetEnabled(_ sender: NSSwitch) {
        let row = sender.tag
        guard row >= 0 && row < snippets.count else { return }
        let id = snippets[row].id
        let isOn = sender.state == .on
        mutate(loc.s("manager.undo.toggle")) { groups in
            for gi in groups.indices {
                if let si = groups[gi].snippets.firstIndex(where: { $0.id == id }) {
                    groups[gi].snippets[si].enabled = isOn
                    break
                }
            }
        }
    }
}
