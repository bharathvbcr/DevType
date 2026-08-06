import AppKit
import ExpanderEngine

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

    func configure(with snippet: SnippetModel) {
        enableSwitch.state = snippet.enabled ? .on : .off
        titleLabel.stringValue = snippet.displayTitle
        titleLabel.textColor = snippet.enabled ? DevTypeTheme.textPrimary : DevTypeTheme.textTertiary
        previewLabel.stringValue = snippet.isImageSnippet
            ? "🖼 \(snippet.imagePath)"
            : snippet.replacementText.replacingOccurrences(of: "\n", with: " ↵ ")
        triggerPill.update(
            text: snippet.triggerKeyword.isEmpty ? "·" : snippet.triggerKeyword,
            tint: snippet.enabled ? DevTypeTheme.accent : DevTypeTheme.statusGray
        )
        usageLabel.stringValue = snippet.usageCount > 0 ? "×\(snippet.usageCount)" : ""
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
        let effective = enabled ? tint : DevTypeTheme.textTertiary
        iconChip.layer?.backgroundColor = effective.withAlphaComponent(0.14).cgColor
        iconChip.layer?.borderColor = effective.withAlphaComponent(0.32).cgColor
        iconView.image = DevTypeTheme.tintedSymbol(symbol, size: 11, weight: .semibold, color: effective)
        nameLabel.stringValue = name
        nameLabel.textColor = enabled ? DevTypeTheme.textPrimary : DevTypeTheme.textTertiary
        countLabel.stringValue = count.map { "\($0)" } ?? ""
        alphaValue = enabled ? 1.0 : 0.72
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
    private var groupOutline = NSOutlineView()
    private var groupScroll = NSScrollView()
    private var tableView = NSTableView()
    private var scrollView = NSScrollView()
    private var filterField = NSSearchField()
    private var groups: [SnippetGroup] = []
    private var selectedGroupID: UUID?
    private var snippets: [SnippetModel] = []
    private var statsPill = PillBadgeView(text: "", tint: DevTypeTheme.accent)
    private let emptyState = EmptyStateView()
    private let loc = LocalizationManager.shared

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

        mainView.addSubview(logo)
        mainView.addSubview(titleLabel)
        mainView.addSubview(statsPill)
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
        scrollView.documentView = tableView
        listContent.addSubview(scrollView)

        emptyState.isHidden = true
        listContent.addSubview(emptyState)
        mainView.addSubview(listCard)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: listContent.topAnchor, constant: 6),
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

        let utilityStack = NSStackView(views: [importButton, resetButton])
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
            filterField.widthAnchor.constraint(equalToConstant: 220),

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
        reloadGroups()
    }

    deinit {
        if let token = listenerToken {
            SnippetStore.shared.removeListener(token: token)
        }
    }

    @objc private func filterChanged() {
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

    private func persistGroups() {
        _ = SnippetStore.shared.saveGroups(groups)
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
                if existing != nil {
                    if let (gi, si) = self.groupIndex(for: snippet.id) {
                        self.groups[gi].snippets[si] = snippet
                        if let chosenGroupID,
                           let destGI = self.groups.firstIndex(where: { $0.id == chosenGroupID }),
                           destGI != gi {
                            self.groups[gi].snippets.remove(at: si)
                            self.groups[destGI].snippets.append(snippet)
                        }
                    }
                } else {
                    let targetGI: Int
                    if let id = chosenGroupID ?? self.selectedGroupID,
                       let gi = self.groups.firstIndex(where: { $0.id == id }) {
                        targetGI = gi
                    } else if let gi = self.groups.firstIndex(where: { $0.name == SnippetDocument.defaultGroupName }) {
                        targetGI = gi
                    } else if self.groups.isEmpty {
                        self.groups = [SnippetGroup(name: SnippetDocument.defaultGroupName)]
                        targetGI = 0
                    } else {
                        targetGI = 0
                    }
                    self.groups[targetGI].snippets.append(snippet)
                }
                self.persistGroups()
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
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Invalid Snippet"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc private func deleteSnippet() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < snippets.count else { return }
        let snippet = snippets[selectedRow]
        guard let window = view.window else { return }

        let confirm = NSAlert()
        confirm.messageText = loc.s("manager.delete.confirm.title")
        confirm.informativeText = loc.s("manager.delete.confirm.message", snippet.displayTitle)
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: loc.s("manager.delete"))
        confirm.addButton(withTitle: loc.s("common.cancel"))
        confirm.buttons.first?.hasDestructiveAction = true
        confirm.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if let (gi, si) = self.groupIndex(for: snippet.id) {
                self.groups[gi].snippets.remove(at: si)
                self.persistGroups()
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
        groups[gi].snippets.append(copy)
        persistGroups()
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
        groups[gi].snippets.remove(at: si)
        groups[destGI].snippets.append(snippet)
        persistGroups()
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
                self.groups.append(group)
                self.selectedGroupID = group.id
                self.persistGroups()
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
                guard let self, let draft,
                      let index = self.groups.firstIndex(where: { $0.id == group.id }) else { return }
                self.groups[index].name = draft.name
                self.groups[index].symbol = draft.symbol
                self.groups[index].colorHex = draft.colorHex
                self.groups[index].enabled = draft.enabled
                self.persistGroups()
            }
        )
    }

    @objc private func toggleSelectedGroup() {
        let row = groupOutline.selectedRow
        guard row > 0, row - 1 < groups.count else { return }
        groups[row - 1].enabled.toggle()
        persistGroups()
    }

    @objc private func deleteSelectedGroup() {
        let row = groupOutline.selectedRow
        guard row > 0, row - 1 < groups.count else { return }
        let group = groups[row - 1]

        guard groups.count > 1 else {
            guard let window = view.window else { return }
            let alert = NSAlert()
            alert.messageText = loc.s("manager.group.delete.title")
            alert.informativeText = loc.s("manager.group.delete.last")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window, completionHandler: nil)
            return
        }

        let removeGroup: () -> Void = { [weak self] in
            guard let self, let index = self.groups.firstIndex(where: { $0.id == group.id }) else { return }
            self.groups.remove(at: index)
            if self.selectedGroupID == group.id { self.selectedGroupID = nil }
            self.persistGroups()
        }

        if group.snippets.isEmpty {
            removeGroup()
            return
        }

        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = loc.s("manager.group.delete.title")
        alert.informativeText = loc.s("manager.group.delete.message", group.name, group.snippets.count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: loc.s("manager.group.delete.move"))
        alert.addButton(withTitle: loc.s("manager.group.delete.all"))
        alert.addButton(withTitle: loc.s("common.cancel"))
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                // Move snippets into the next available group, then remove this one.
                guard let index = self.groups.firstIndex(where: { $0.id == group.id }),
                      let destination = self.groups.firstIndex(where: { $0.id != group.id }) else { return }
                let moved = self.groups[index].snippets
                self.groups.remove(at: index)
                let adjusted = destination > index ? destination - 1 : destination
                self.groups[adjusted].snippets.append(contentsOf: moved)
                if self.selectedGroupID == group.id {
                    self.selectedGroupID = self.groups[adjusted].id
                }
                self.persistGroups()
            case .alertSecondButtonReturn:
                removeGroup()
            default:
                break
            }
        }
    }

    // MARK: - Library actions

    @objc private func resetDefaults() {
        guard let window = view.window else { return }
        let confirm = NSAlert()
        confirm.messageText = "Reset to Defaults?"
        confirm.informativeText = "This replaces all snippets with the built-in defaults."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Reset")
        confirm.addButton(withTitle: loc.s("common.cancel"))
        confirm.buttons.first?.hasDestructiveAction = true
        confirm.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let defaults = SnippetStore.shared.defaultSnippets()
            SnippetStore.shared.saveSnippets(defaults)
        }
    }

    /// Unified import: one panel, format auto-detected (TextExpander or Espanso).
    @objc private func importSnippets() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a TextExpander settings folder, or an Espanso config folder, match directory, package, or .yml file"
        if let first = SnippetImporter.detectedSources().first {
            panel.directoryURL = first.kind == .textExpander
                ? first.url.deletingLastPathComponent()
                : first.url
        }
        panel.beginSheetModal(for: view.window ?? NSWindow()) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let result = try SnippetStore.shared.importSnippets(from: url)
                self.reloadGroups()
                let alert = NSAlert()
                alert.messageText = "Import Complete"
                var text = "Imported \(result.snippetCount) snippets in \(result.groupCount) groups from \(result.kind.rawValue)."
                if !result.notes.isEmpty {
                    text += "\n\n" + result.notes.joined(separator: "\n")
                }
                alert.informativeText = text
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                if let window = self.view.window {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            } catch {
                self.presentValidationError(error.localizedDescription)
            }
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

        let edit = NSMenuItem(title: loc.s("manager.group.edit"), action: #selector(editSelectedGroup), keyEquivalent: "")
        edit.target = self
        edit.image = DevTypeTheme.menuIcon("pencil")

        let toggle = NSMenuItem(
            title: group.enabled ? loc.s("manager.group.disable") : loc.s("manager.group.enable"),
            action: #selector(toggleSelectedGroup),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.image = DevTypeTheme.menuIcon(group.enabled ? "pause.circle" : "play.circle")

        let delete = NSMenuItem(title: loc.s("manager.group.delete"), action: #selector(deleteSelectedGroup), keyEquivalent: "")
        delete.target = self
        delete.image = DevTypeTheme.menuIcon("trash")

        menu.items = [edit, toggle, .separator(), delete]
    }

    private func buildSnippetContextMenu(_ menu: NSMenu) {
        let row = tableView.clickedRow
        guard row >= 0, row < snippets.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let snippet = snippets[row]

        let edit = NSMenuItem(title: loc.s("manager.edit"), action: #selector(editSelectedSnippet), keyEquivalent: "")
        edit.target = self
        edit.image = DevTypeTheme.menuIcon("pencil")

        let duplicate = NSMenuItem(title: loc.s("manager.duplicate"), action: #selector(duplicateSelectedSnippet), keyEquivalent: "")
        duplicate.target = self
        duplicate.image = DevTypeTheme.menuIcon("plus.square.on.square")

        let delete = NSMenuItem(title: loc.s("manager.delete"), action: #selector(deleteSnippet), keyEquivalent: "")
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
        let group = groups.remove(at: from)
        var destination = index - 1
        if from < destination { destination -= 1 }
        destination = max(0, min(destination, groups.count))
        groups.insert(group, at: destination)
        selectedGroupID = group.id
        persistGroups()
        return true
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
        cell.configure(with: snippets[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RoundedSelectionRowView()
    }

    @objc private func toggleSnippetEnabled(_ sender: NSSwitch) {
        let row = sender.tag
        guard row >= 0 && row < snippets.count else { return }
        let id = snippets[row].id
        guard let (gi, si) = groupIndex(for: id) else { return }
        groups[gi].snippets[si].enabled = sender.state == .on
        persistGroups()
        applyFilterAndReloadTable()
    }
}
