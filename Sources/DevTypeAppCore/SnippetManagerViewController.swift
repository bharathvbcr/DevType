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

final class KeyCommandTableView: NSTableView {
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Applies a pending debounced filter before the list can be acted on.
    ///
    /// Search is coalesced on a short timer, so for a moment after the last keystroke the table
    /// still shows the wider list. Taking focus or pressing a key is the earliest point at which
    /// that difference could matter — Select All followed by Delete must operate on what the
    /// user narrowed the list to, not on what happens to be drawn.
    var onWillHandleInput: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        onWillHandleInput?()
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        onWillHandleInput?()
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

final class KeyCommandOutlineView: NSOutlineView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - Snippet Manager (Crimson Glass)

final class SnippetManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    /// Tests point the manager at a temporary library. Production leaves this nil.
    static var libraryOverride: SnippetStore?
    var library: SnippetStore { Self.libraryOverride ?? .shared }
    /// The store the group listener was registered on. `defer` in a test can clear
    /// `libraryOverride` before this controller deinits, and removal has to hit the same store.
    private var listenerStore: SnippetStore?
    /// Reloads that actually applied a new library revision. A second call with the same
    /// revision is the listener echoing a save `finishMutation` already drew.
    var appliedReloadCount = 0

    var groupOutline = KeyCommandOutlineView()
    var groupScroll = NSScrollView()
    var tableView = KeyCommandTableView()
    var scrollView = NSScrollView()
    var filterField = NSSearchField()
    /// Trailing-edge coalescing for `filterChanged`. Short enough to feel immediate, long
    /// enough that a burst of keystrokes runs the pipeline once.
    static let filterDebounceInterval: TimeInterval = 0.12
    var filterDebounce: DispatchWorkItem?
    /// Conflict IDs for the `.conflicts` chip, cached against `SnippetStore.libraryRevision`.
    var cachedConflictIDs: Set<UUID>?
    var cachedConflictRevision: UInt64?
    /// Any write other than the load in `reloadGroups` (an optimistic local edit) drops the
    /// revision, because `groups` no longer is the library that revision names.
    var groups: [SnippetGroup] = [] {
        didSet { groupsRevision = nil }
    }
    /// `SnippetStore.libraryRevision` that `groups` was loaded at.
    var groupsRevision: UInt64?
    var selectedGroupID: UUID?
    var snippets: [SnippetModel] = []
    var statsPill = PillBadgeView(text: "", tint: DevTypeTheme.accent)
    let emptyState = EmptyStateView()
    let loc = LocalizationManager.shared

    // Density & Filter Chips
    var activeFilter: SnippetListFilter = .all
    var isCompactDensity: Bool = false
    let densityControl = NSSegmentedControl()
    private let filterChipsStack = NSStackView()
    private let filterOverflow = NSScrollView()
    var filterChipButtons: [SnippetFilterChip: CapsuleButton] = [:]

    // Bulk Operations Bar
    let bulkBar = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.12))
    let selectedCountLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(12, .bold), color: DevTypeTheme.textPrimary)
    var primaryActionBar: NSStackView?
    var utilityActionBar: NSStackView?
    weak var bulkOverflowButton: NSPopUpButton?

    // §4.6: sorting + undo.
    var sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var sortMode: SnippetSortMode = {
        let raw = UserDefaults.standard.integer(forKey: SnippetSortMode.defaultsKey)
        return SnippetSortMode(rawValue: raw) ?? .manual
    }()
    let restorationState: SnippetManagerLocalizationState?
    var pendingRestoredSnippetIDs: Set<UUID> = []
    var hasResolvedInitialGroupSelection: Bool

    /// §4.6: there was no `UndoManager` / `registerUndo` anywhere in `Sources/`.
    /// Delete was a modal confirm and then gone forever, and the Edit menu's ⌘Z
    /// only ever reached `NSTextView`'s field editor.
    ///
    /// Undo here is snapshot-based for model-only mutations whose UUID-to-resource
    /// projection is unchanged. Resource-changing operations still commit safely, but are
    /// deliberately withheld from the undo stack so undo cannot recreate a secret without its
    /// Keychain value or an image snippet after its attachment was deleted.
    let snippetUndoManager: UndoManager
    let snippetUndoTarget: SnippetManagerUndoTarget

    /// §0.3: non-modal banner for an unreadable / unwritable / conflicted library.
    let healthBanner = LibraryHealthBannerView()
    private var healthToken: UUID?

    /// Returning our manager from the responder chain is what makes the standard
    /// Edit ▸ Undo item (and ⌘Z) reach snippet edits when the table has focus,
    /// while a focused text field still gets its own field-editor undo.
    override var undoManager: UndoManager? { snippetUndoManager }

    init(
        restorationState: SnippetManagerLocalizationState? = nil,
        snippetUndoManager: UndoManager = UndoManager(),
        snippetUndoTarget: SnippetManagerUndoTarget = SnippetManagerUndoTarget()
    ) {
        self.restorationState = restorationState
        self.snippetUndoManager = snippetUndoManager
        self.snippetUndoTarget = snippetUndoTarget
        self.hasResolvedInitialGroupSelection = restorationState != nil
        super.init(nibName: nil, bundle: nil)
        snippetUndoTarget.owner = self

        guard let restorationState else { return }
        selectedGroupID = restorationState.selectedGroupID
        pendingRestoredSnippetIDs = restorationState.selectedSnippetIDs
        activeFilter = restorationState.filter
        isCompactDensity = restorationState.isCompactDensity
        sortMode = restorationState.sortMode
        filterField.stringValue = restorationState.filterText
    }

    required init?(coder: NSCoder) {
        restorationState = nil
        snippetUndoManager = UndoManager()
        snippetUndoTarget = SnippetManagerUndoTarget()
        hasResolvedInitialGroupSelection = false
        super.init(coder: coder)
        snippetUndoTarget.owner = self
    }

    lazy var groupContextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    lazy var snippetContextMenu: NSMenu = {
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
        filterField.toolTip = loc.s("search.syntax.hint")
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.controlSize = .regular
        filterField.setAccessibilityLabel(loc.s("manager.filter"))

        // Density control
        densityControl.segmentCount = 2
        densityControl.setLabel(loc.s("manager.density.comfortable"), forSegment: 0)
        densityControl.setLabel(loc.s("manager.density.compact"), forSegment: 1)
        densityControl.selectedSegment = isCompactDensity ? 1 : 0
        densityControl.target = self
        densityControl.action = #selector(densityChanged)
        densityControl.controlSize = .small
        densityControl.translatesAutoresizingMaskIntoConstraints = false

        // §4.6: sort control.
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

        let settingsButton = GlassIconButton(
            symbol: "gearshape",
            accessibilityLabel: loc.s("manager.settings"),
            target: self,
            action: #selector(openSettings)
        )
        settingsButton.toolTip = loc.s("manager.settings")

        mainView.addSubview(logo)
        mainView.addSubview(titleLabel)
        mainView.addSubview(statsPill)
        mainView.addSubview(densityControl)
        mainView.addSubview(sortPopup)
        mainView.addSubview(filterField)
        mainView.addSubview(settingsButton)

        // MARK: Sidebar (groups) — glass card
        let sidebarCard = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.05))
        sidebarCard.translatesAutoresizingMaskIntoConstraints = false
        mainView.addSubview(sidebarCard)
        let sidebarContent = sidebarCard.contentView

        let groupsCaption = DevTypeTheme.makeLabel(
            loc.s("manager.groups.caption"),
            font: DevTypeTheme.font(10, .bold),
            color: DevTypeTheme.textTertiary
        )
        groupsCaption.translatesAutoresizingMaskIntoConstraints = false
        sidebarContent.addSubview(groupsCaption)

        let addGroupCaptionButton = NSButton()
        addGroupCaptionButton.isBordered = false
        addGroupCaptionButton.title = ""
        addGroupCaptionButton.wantsLayer = true
        addGroupCaptionButton.layer?.cornerRadius = 4
        addGroupCaptionButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        addGroupCaptionButton.image = DevTypeTheme.tintedSymbol("plus", size: 9, weight: .bold, color: DevTypeTheme.textSecondary)
        addGroupCaptionButton.imageScaling = .scaleProportionallyUpOrDown
        addGroupCaptionButton.imagePosition = .imageOnly
        addGroupCaptionButton.toolTip = loc.s("manager.group.add")
        addGroupCaptionButton.setAccessibilityElement(true)
        addGroupCaptionButton.setAccessibilityRole(.button)
        addGroupCaptionButton.setAccessibilityLabel(loc.s("manager.group.add"))
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
        groupOutline.onKeyDown = { [weak self] event in
            self?.handleGroupKeyDown(event) ?? false
        }
        let groupCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("group"))
        groupCol.title = loc.s("manager.groups.caption")
        groupOutline.addTableColumn(groupCol)
        groupOutline.outlineTableColumn = groupCol
        groupScroll.documentView = groupOutline
        sidebarContent.addSubview(groupScroll)

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

        // Filter Chips Bar. Nine localized labels cannot fit the list column at the
        // window's supported 700pt minimum. Keep the direct, glanceable chips, but put
        // them in an explicit horizontal overflow strip rather than letting Auto Layout
        // push the last controls through the card edge.
        filterChipsStack.orientation = .horizontal
        filterChipsStack.alignment = .centerY
        filterChipsStack.spacing = 6
        filterChipsStack.translatesAutoresizingMaskIntoConstraints = false
        for chip in SnippetFilterChip.allCases {
            let btn = CapsuleButton(
                title: loc.s(chip.localizationKey),
                style: chip == activeFilter.chip ? .primary : .secondary,
                target: self,
                action: #selector(filterChipTapped(_:))
            )
            btn.tag = chip.rawValue
            btn.controlSize = .small
            filterChipButtons[chip] = btn
            filterChipsStack.addArrangedSubview(btn)
        }
        filterOverflow.identifier = NSUserInterfaceItemIdentifier("manager.filterOverflow")
        filterOverflow.translatesAutoresizingMaskIntoConstraints = false
        filterOverflow.hasHorizontalScroller = true
        filterOverflow.hasVerticalScroller = false
        filterOverflow.autohidesScrollers = true
        filterOverflow.scrollerStyle = .overlay
        filterOverflow.borderType = .noBorder
        filterOverflow.drawsBackground = false
        filterOverflow.horizontalScrollElasticity = .allowed
        filterOverflow.verticalScrollElasticity = .none
        filterOverflow.automaticallyAdjustsContentInsets = false
        filterOverflow.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 14, right: 0)
        filterOverflow.setAccessibilityLabel(loc.s("manager.filter"))
        filterOverflow.documentView = filterChipsStack
        listContent.addSubview(filterOverflow)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.headerView = nil
        tableView.rowHeight = isCompactDensity ? 38 : 52
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.doubleAction = #selector(editSelectedSnippet)
        tableView.target = self
        tableView.menu = snippetContextMenu
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(loc.s("ax.snippetsTable"))
        tableView.registerForDraggedTypes([.string])
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.onWillHandleInput = { [weak self] in self?.flushPendingFilter() }
        tableView.onKeyDown = { [weak self] event in
            self?.handleSnippetKeyDown(event) ?? false
        }
        scrollView.documentView = tableView
        listContent.addSubview(scrollView)

        healthBanner.isHidden = true
        listContent.addSubview(healthBanner)

        emptyState.isHidden = true
        listContent.addSubview(emptyState)
        mainView.addSubview(listCard)

        NSLayoutConstraint.activate([
            filterOverflow.topAnchor.constraint(equalTo: listContent.topAnchor, constant: 8),
            filterOverflow.leadingAnchor.constraint(equalTo: listContent.leadingAnchor, constant: 10),
            filterOverflow.trailingAnchor.constraint(equalTo: listContent.trailingAnchor, constant: -10),
            filterOverflow.heightAnchor.constraint(equalToConstant: 42),

            // Preserve the stack's intrinsic width: that width is the scrollable document.
            // A trailing pin would instead compress every required-width capsule.
            filterChipsStack.leadingAnchor.constraint(equalTo: filterOverflow.contentView.leadingAnchor),
            filterChipsStack.topAnchor.constraint(equalTo: filterOverflow.contentView.topAnchor),
            filterChipsStack.heightAnchor.constraint(equalToConstant: 28),

            healthBanner.topAnchor.constraint(equalTo: filterOverflow.bottomAnchor, constant: 4),
            healthBanner.leadingAnchor.constraint(equalTo: listContent.leadingAnchor, constant: 8),
            healthBanner.trailingAnchor.constraint(equalTo: listContent.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: healthBanner.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: listContent.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContent.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContent.bottomAnchor, constant: -6),

            emptyState.centerXAnchor.constraint(equalTo: listContent.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: listContent.centerYAnchor, constant: -8),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: listContent.leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: listContent.trailingAnchor, constant: -24)
        ])

        // MARK: Standard Action Bar
        let addButton = SplitCapsuleButton(
            title: loc.s("manager.add"),
            symbol: "plus",
            disclosureTooltip: loc.s("manager.add.template.tooltip"),
            target: self,
            primaryAction: #selector(addSnippet),
            disclosureAction: #selector(addSnippetFromTemplate)
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
        let statsButton = CapsuleButton(
            title: loc.s("manager.stats.button"),
            symbol: "chart.bar",
            style: .secondary,
            target: self,
            action: #selector(openStatistics)
        )
        let utilityOverflow = makeActionOverflow(
            identifier: "manager.utilityOverflow",
            title: loc.s("manager.moreActions"),
            symbol: "ellipsis.circle",
            actions: [
                (loc.s("manager.import"), #selector(importSnippets)),
                (loc.s("manager.export"), #selector(exportSnippets)),
                (loc.s("manager.reset"), #selector(resetDefaults))
            ]
        )

        let primaryStack = NSStackView(views: [addButton, editButton, deleteButton])
        primaryStack.orientation = .horizontal
        primaryStack.spacing = 10
        primaryStack.translatesAutoresizingMaskIntoConstraints = false
        primaryStack.setContentHuggingPriority(.required, for: .vertical)
        primaryActionBar = primaryStack

        let utilityStack = NSStackView(views: [statsButton, utilityOverflow])
        utilityStack.orientation = .horizontal
        utilityStack.spacing = 10
        utilityStack.translatesAutoresizingMaskIntoConstraints = false
        utilityStack.setContentHuggingPriority(.required, for: .vertical)
        utilityActionBar = utilityStack

        // MARK: Bulk Actions Bar
        bulkBar.translatesAutoresizingMaskIntoConstraints = false
        bulkBar.isHidden = true
        let bulkContent = bulkBar.contentView

        let bulkDeleteBtn = CapsuleButton(title: loc.s("manager.bulk.delete"), style: .destructive, target: self, action: #selector(bulkDeleteSelected))
        let bulkSelectAllBtn = CapsuleButton(title: loc.s("manager.bulk.selectAll"), style: .secondary, target: self, action: #selector(selectAllSnippets))
        let bulkOverflow = makeActionOverflow(
            identifier: "manager.bulkOverflow",
            title: loc.s("manager.bulk.actions"),
            symbol: "ellipsis.circle",
            actions: [
                (loc.s("manager.bulk.enable"), #selector(bulkEnableSelected)),
                (loc.s("manager.bulk.disable"), #selector(bulkDisableSelected)),
                (loc.s("manager.bulk.moveToGroup"), #selector(bulkMoveFromOverflow(_:))),
                (loc.s("manager.bulk.duplicate"), #selector(bulkDuplicateSelected)),
                (loc.s("manager.bulk.prefixSuffix"), #selector(bulkPrefixSuffixSelected)),
                (loc.s("manager.bulk.export"), #selector(bulkExportSelected))
            ]
        )
        bulkOverflowButton = bulkOverflow

        let bulkLeftStack = NSStackView(views: [selectedCountLabel, bulkOverflow])
        bulkLeftStack.orientation = .horizontal
        bulkLeftStack.spacing = 8
        bulkLeftStack.alignment = .centerY
        bulkLeftStack.translatesAutoresizingMaskIntoConstraints = false
        selectedCountLabel.lineBreakMode = .byTruncatingTail
        selectedCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bulkRightStack = NSStackView(views: [bulkSelectAllBtn, bulkDeleteBtn])
        bulkRightStack.orientation = .horizontal
        bulkRightStack.spacing = 8
        bulkRightStack.alignment = .centerY
        bulkRightStack.translatesAutoresizingMaskIntoConstraints = false

        bulkContent.addSubview(bulkLeftStack)
        bulkContent.addSubview(bulkRightStack)

        NSLayoutConstraint.activate([
            bulkLeftStack.leadingAnchor.constraint(equalTo: bulkContent.leadingAnchor, constant: 12),
            bulkLeftStack.centerYAnchor.constraint(equalTo: bulkContent.centerYAnchor),
            bulkLeftStack.trailingAnchor.constraint(lessThanOrEqualTo: bulkRightStack.leadingAnchor, constant: -8),

            bulkRightStack.trailingAnchor.constraint(equalTo: bulkContent.trailingAnchor, constant: -12),
            bulkRightStack.centerYAnchor.constraint(equalTo: bulkContent.centerYAnchor)
        ])

        mainView.addSubview(primaryStack)
        mainView.addSubview(utilityStack)
        mainView.addSubview(bulkBar)

        let preferredFilterWidth = filterField.widthAnchor.constraint(equalToConstant: 200)
        preferredFilterWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 20),
            logo.topAnchor.constraint(equalTo: mainView.topAnchor, constant: 40),
            logo.widthAnchor.constraint(equalToConstant: 28),
            logo.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: logo.centerYAnchor),

            statsPill.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            statsPill.centerYAnchor.constraint(equalTo: logo.centerYAnchor),

            settingsButton.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -20),
            settingsButton.centerYAnchor.constraint(equalTo: logo.centerYAnchor),

            filterField.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -10),
            filterField.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            filterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            preferredFilterWidth,

            sortPopup.trailingAnchor.constraint(equalTo: filterField.leadingAnchor, constant: -8),
            sortPopup.centerYAnchor.constraint(equalTo: logo.centerYAnchor),

            densityControl.trailingAnchor.constraint(equalTo: sortPopup.leadingAnchor, constant: -8),
            densityControl.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            densityControl.leadingAnchor.constraint(greaterThanOrEqualTo: statsPill.trailingAnchor, constant: 10),

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
            primaryStack.trailingAnchor.constraint(lessThanOrEqualTo: utilityStack.leadingAnchor, constant: -10),

            utilityStack.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -20),
            utilityStack.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -16),

            bulkBar.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 16),
            bulkBar.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -16),
            bulkBar.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -12),
            bulkBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        self.view = mainView
    }

    /// A compact pull-down preserves every secondary action without forcing translated
    /// button labels to compete for one horizontal row. The first item is a disabled
    /// title; the remaining items retain their direct controller selectors.
    private func makeActionOverflow(
        identifier: String,
        title: String,
        symbol: String,
        actions: [(title: String, action: Selector)]
    ) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.identifier = NSUserInterfaceItemIdentifier(identifier)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .small
        popup.bezelStyle = .rounded
        popup.font = DevTypeTheme.font(11, .semibold)
        popup.addItem(withTitle: title)
        popup.item(at: 0)?.image = DevTypeTheme.tintedSymbol(
            symbol,
            size: 11,
            weight: .semibold,
            color: DevTypeTheme.textSecondary
        )
        popup.item(at: 0)?.isEnabled = false
        for item in actions {
            popup.addItem(withTitle: item.title)
            popup.lastItem?.target = self
            popup.lastItem?.action = item.action
        }
        popup.setAccessibilityLabel(title)
        popup.toolTip = title
        return popup
    }

    private var listenerToken: UUID?

    override func viewDidLoad() {
        super.viewDidLoad()
        if listenerToken == nil {
            listenerStore = library
            listenerToken = library.addGroupListener { [weak self] _ in
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
        restoreLocalizationStateWhenLaidOut()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // §4.5: `incrementUsage` no longer fires store listeners, so the `×N`
        // column is refreshed on appearance rather than waiting for a push.
        applyFilterAndReloadTable()
    }

    deinit {
        filterDebounce?.cancel()
        if let token = listenerToken {
            listenerStore?.removeListener(token: token)
        }
        if let healthToken {
            LibraryHealthMonitor.shared.removeObserver(healthToken)
        }
        if snippetUndoTarget.owner === self {
            snippetUndoTarget.owner = nil
        }
    }
}
