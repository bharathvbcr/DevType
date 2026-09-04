import AppKit
import ExpanderEngine

/// Interactive trigger-conflict resolver.
///
/// The table renders an immutable `ConflictResolverSnapshot`; destructive actions resolve their
/// UUID against the store's latest state so a sheet left open cannot write its stale projection
/// back over a newer library.
final class SnippetConflictResolverSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public static func present(
        from window: NSWindow?,
        store: SnippetStore = .shared,
        completion: (() -> Void)? = nil
    ) {
        let controller = SnippetConflictResolverSheet(store: store, completion: completion)
        let sheetWindow = NSWindow(contentViewController: controller)
        let title = LocalizationManager.shared.s("conflict.resolver.title")
        sheetWindow.title = title
        sheetWindow.styleMask = [.titled, .closable, .resizable]
        sheetWindow.setContentSize(NSSize(width: 680, height: 520))
        sheetWindow.minSize = NSSize(width: 540, height: 360)
        DevTypeTheme.styleWindow(sheetWindow, title: title)

        if let window {
            window.beginSheet(sheetWindow)
        } else {
            sheetWindow.center()
            sheetWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private let store: SnippetStore
    private let completion: (() -> Void)?
    private let loc = LocalizationManager.shared
    private let tableView = NSTableView()
    private let summaryLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5, .medium),
        color: DevTypeTheme.textSecondary,
        wrapping: true
    )
    private var snapshot = ConflictResolverSnapshot(groups: [], detectionEnabled: true)

    init(store: SnippetStore = .shared, completion: (() -> Void)? = nil) {
        self.store = store
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        let header = DevTypeTheme.makeLabel(
            loc.s("conflict.resolver.title"),
            font: DevTypeTheme.font(16, .bold),
            color: DevTypeTheme.textPrimary
        )
        header.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.maximumNumberOfLines = 2

        let closeButton = CapsuleButton(
            title: loc.s("common.done"),
            style: .primary,
            target: self,
            action: #selector(closeTapped)
        )
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 8)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityRole(NSAccessibility.Role.table)
        tableView.setAccessibilityLabel(loc.s("conflict.resolver.ax.table"))
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conflictCol")))
        scrollView.documentView = tableView

        root.addSubview(header)
        root.addSubview(summaryLabel)
        root.addSubview(closeButton)
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),

            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            summaryLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            summaryLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: closeButton.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        view = root
        reloadConflicts()
    }

    private func reloadConflicts() {
        // Exactly one store read: detector output, item details, group names, and counts cannot
        // straddle watcher updates or a concurrent editor save.
        snapshot = ConflictResolverSnapshot(
            groups: store.loadGroups(),
            detectionEnabled: SnippetStore.isConflictDetectionEnabled
        )
        if snapshot.rows.isEmpty {
            summaryLabel.stringValue = ""
        } else {
            summaryLabel.stringValue = loc.p(
                "conflict.resolver.summary",
                count: snapshot.conflictCount,
                snapshot.conflictCount,
                snapshot.affectedSnippetCount
            )
        }
        tableView.reloadData()
    }

    @objc private func closeTapped() {
        if let window = view.window, let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            view.window?.close()
        }
        completion?()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        snapshot.rows.isEmpty ? 1 : snapshot.rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard snapshot.rows.indices.contains(row) else {
            return ConflictResolverLayout.emptyRowHeight
        }
        return ConflictResolverLayout.rowHeight(
            snippetCount: snapshot.rows[row].affectedSnippetCount
        )
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard snapshot.rows.indices.contains(row) else { return makeEmptyState() }
        return ConflictRowView(
            row: snapshot.rows[row],
            onDisable: { [weak self] target in self?.resolve(target: target, action: .disable) },
            onDelete: { [weak self] item in self?.confirmDelete(item) }
        )
    }

    private func makeEmptyState() -> NSView {
        let empty = NSTableCellView()
        let text: String
        switch snapshot.emptyState {
        case .detectionDisabled:
            text = loc.s("conflict.resolver.disabled")
        case .noConflicts, .none:
            text = loc.s("library.health.conflictsNone")
        }
        let label = DevTypeTheme.makeLabel(
            text,
            font: DevTypeTheme.font(13),
            color: DevTypeTheme.textSecondary,
            wrapping: true
        )
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        empty.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: empty.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: empty.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: empty.trailingAnchor, constant: -24),
        ])
        return empty
    }

    private func confirmDelete(_ item: ConflictResolverSnapshot.Item) {
        DevTypeAlert.confirm(
            title: loc.s("manager.delete.confirm.title"),
            message: loc.s("manager.delete.confirm.message", displayTitle(for: item.snippet)),
            confirmTitle: loc.s("common.delete"),
            destructive: true,
            window: view.window
        ) { [weak self] in
            self?.resolve(target: item.target, action: .delete)
        }
    }

    private func resolve(
        target: SnippetStore.TriggerConflictTarget,
        action: SnippetStore.TriggerConflictResolutionAction
    ) {
        switch store.resolveTriggerConflict(target: target, action: action) {
        case .persisted:
            reloadConflicts()
        case .targetUnavailable:
            reloadConflicts()
            DevTypeAlert.warn(
                title: loc.s("conflict.resolver.stale.title"),
                message: loc.s("conflict.resolver.stale.message"),
                window: view.window
            )
        case .refused(let outcome):
            // `saveGroupsSerialized` leaves the cache untouched on refusal. Re-render that
            // unchanged state, refresh the persistent health banner, and explain why it remains.
            reloadConflicts()
            LibraryHealthMonitor.shared.refresh()
            DevTypeAlert.warn(
                title: loc.s("library.save.title"),
                message: saveFailureMessage(for: outcome),
                window: view.window
            )
        }
    }

    private func saveFailureMessage(for outcome: SnippetStore.SaveOutcome) -> String {
        switch outcome {
        case .saved:
            return loc.s("library.save.banner")
        case .blockedByNewerSchema:
            return loc.s("library.save.blockedSchema")
        case .blockedByRemoteChange:
            return loc.s("library.save.blockedRemote")
        case .failed(let reason):
            return loc.s("library.save.failed", reason)
        }
    }

    private func displayTitle(for snippet: SnippetModel) -> String {
        let title = snippet.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? loc.s("conflict.resolver.untitled") : title
    }
}

/// Exact action identity retained by each row. `NSButton.tag` is an `Int`; narrowing a UUID to
/// `hashValue` permits collisions and randomized values. Keeping the rendered occurrence target
/// makes the action lossless and independently retained from the button's weak target reference.
final class ConflictSnippetActionTarget: NSObject {
    let conflictTarget: SnippetStore.TriggerConflictTarget
    private let handler: (SnippetStore.TriggerConflictTarget) -> Void

    init(
        target: SnippetStore.TriggerConflictTarget,
        handler: @escaping (SnippetStore.TriggerConflictTarget) -> Void
    ) {
        self.conflictTarget = target
        self.handler = handler
    }

    @objc func invoke(_ sender: NSButton) {
        handler(conflictTarget)
    }
}

private final class ConflictRowView: NSView {
    private let row: ConflictResolverSnapshot.Row
    private let onDisable: (SnippetStore.TriggerConflictTarget) -> Void
    private let onDelete: (ConflictResolverSnapshot.Item) -> Void
    private let loc = LocalizationManager.shared
    private var actionTargets: [ConflictSnippetActionTarget] = []

    init(
        row: ConflictResolverSnapshot.Row,
        onDisable: @escaping (SnippetStore.TriggerConflictTarget) -> Void,
        onDelete: @escaping (ConflictResolverSnapshot.Item) -> Void
    ) {
        self.row = row
        self.onDisable = onDisable
        self.onDelete = onDelete
        super.init(frame: .zero)

        let card = GlassCardView(tint: DevTypeTheme.statusOrange.withAlphaComponent(0.06))
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        let content = card.contentView

        let explanationText: String
        switch row.conflict.kind {
        case .emptyTrigger:
            explanationText = loc.s("conflict.issue.empty")
        case .duplicateTrigger:
            explanationText = loc.s("conflict.winner.exact")
        case .caseShadow:
            explanationText = loc.s("conflict.winner.case")
        case .prefixShadow:
            explanationText = loc.s("conflict.winner.shorter")
        }

        let winnerBadge = PillBadgeView(
            text: explanationText,
            tint: DevTypeTheme.statusOrange,
            showsDot: row.conflict.kind != .emptyTrigger
        )
        winnerBadge.translatesAutoresizingMaskIntoConstraints = false
        winnerBadge.heightAnchor.constraint(
            equalToConstant: ConflictResolverLayout.headerRowHeight
        ).isActive = true

        let countBadge = PillBadgeView(
            text: loc.p(
                "conflict.resolver.affected",
                count: row.affectedSnippetCount,
                row.affectedSnippetCount
            ),
            tint: DevTypeTheme.textTertiary,
            showsDot: false
        )
        countBadge.translatesAutoresizingMaskIntoConstraints = false

        let snippetsStack = NSStackView()
        snippetsStack.orientation = .vertical
        snippetsStack.alignment = .width
        snippetsStack.spacing = ConflictResolverLayout.snippetSpacing
        snippetsStack.translatesAutoresizingMaskIntoConstraints = false
        for item in row.items {
            let summary = makeSnippetSummary(item)
            summary.heightAnchor.constraint(equalToConstant: ConflictResolverLayout.snippetRowHeight).isActive = true
            snippetsStack.addArrangedSubview(summary)
        }

        content.addSubview(winnerBadge)
        content.addSubview(countBadge)
        content.addSubview(snippetsStack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            winnerBadge.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            winnerBadge.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            winnerBadge.trailingAnchor.constraint(lessThanOrEqualTo: countBadge.leadingAnchor, constant: -8),

            countBadge.centerYAnchor.constraint(equalTo: winnerBadge.centerYAnchor),
            countBadge.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            snippetsStack.topAnchor.constraint(equalTo: winnerBadge.bottomAnchor, constant: 8),
            snippetsStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            snippetsStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            snippetsStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeSnippetSummary(_ item: ConflictResolverSnapshot.Item) -> NSView {
        let snippet = item.snippet
        let title = displayTitle(for: snippet)
        let trigger = snippet.triggerKeyword.isEmpty
            ? loc.s("conflict.resolver.noTrigger")
            : snippet.triggerKeyword

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = (
            item.isWinner
                ? DevTypeTheme.accent.withAlphaComponent(0.4)
                : NSColor.white.withAlphaComponent(0.08)
        ).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(NSAccessibility.Role.group)
        container.setAccessibilityLabel(loc.s("conflict.resolver.ax.item", title, trigger, item.groupName))

        let titleLabel = DevTypeTheme.makeLabel(
            title,
            font: DevTypeTheme.font(12, .semibold),
            color: DevTypeTheme.textPrimary
        )
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = title

        let groupText = loc.s("conflict.resolver.group", item.groupName)
        let groupLabel = DevTypeTheme.makeLabel(
            groupText,
            font: DevTypeTheme.font(10, .medium),
            color: DevTypeTheme.textTertiary
        )
        groupLabel.lineBreakMode = .byTruncatingMiddle
        groupLabel.toolTip = groupText

        let triggerLabel = DevTypeTheme.makeLabel(
            trigger,
            font: DevTypeTheme.mono(11, .bold),
            color: DevTypeTheme.accent
        )
        triggerLabel.lineBreakMode = .byTruncatingMiddle
        triggerLabel.toolTip = trigger

        let previewText = snippet.isImageSnippet
            ? loc.s("editor.image.attached")
            : snippet.replacementText.replacingOccurrences(of: "\n", with: " ")
        let previewLabel = DevTypeTheme.makeLabel(
            previewText,
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textSecondary
        )
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.toolTip = previewText

        let infoStack = NSStackView(views: [titleLabel, groupLabel, triggerLabel, previewLabel])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 2
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        let disableTarget = ConflictSnippetActionTarget(target: item.target, handler: onDisable)
        actionTargets.append(disableTarget)
        let disableButton = CapsuleButton(
            title: loc.s("conflict.action.disable"),
            style: .secondary,
            target: disableTarget,
            action: #selector(ConflictSnippetActionTarget.invoke(_:))
        )
        disableButton.controlSize = .small
        disableButton.setAccessibilityLabel(loc.s("conflict.resolver.ax.disable", title))

        let deleteTarget = ConflictSnippetActionTarget(target: item.target) { [onDelete, item] _ in
            onDelete(item)
        }
        actionTargets.append(deleteTarget)
        let deleteButton = CapsuleButton(
            title: loc.s("conflict.action.delete"),
            style: .destructive,
            target: deleteTarget,
            action: #selector(ConflictSnippetActionTarget.invoke(_:))
        )
        deleteButton.controlSize = .small
        deleteButton.setAccessibilityLabel(loc.s("conflict.resolver.ax.delete", title))

        let buttonRow = NSStackView(views: [disableButton, deleteButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(infoStack)
        container.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            infoStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            infoStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            infoStack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 6),
            infoStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -6),
            infoStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonRow.leadingAnchor, constant: -10),

            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            buttonRow.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }

    private func displayTitle(for snippet: SnippetModel) -> String {
        let title = snippet.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? loc.s("conflict.resolver.untitled") : title
    }
}
