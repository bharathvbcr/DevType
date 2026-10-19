import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// One snippet row: enable switch, title + preview, trigger pill, usage count.
private final class SnippetRowView: NSView {
    /// Longest trigger the pill may show before it truncates. Past this the row's
    /// title and preview would be starved of space.
    private static let maxPillWidth: CGFloat = 150

    let enableSwitch = NSSwitch()
    private let titleLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(13, .semibold), color: DevTypeTheme.textPrimary)
    private let previewLabel = MarqueeLabel(font: DevTypeTheme.font(11), color: DevTypeTheme.textSecondary)
    private let triggerPill = PillBadgeView(text: "", tint: DevTypeTheme.accent, font: DevTypeTheme.mono(11, .bold), truncates: true)
    private let usageLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.mono(10, .medium), color: DevTypeTheme.textTertiary)
    private let textStack = NSStackView()
    private let metricsStack = NSStackView()
    /// Thumbnail for image snippets. Zero-width for every other kind, so text rows are laid out
    /// exactly as before.
    private let thumbnail = NSImageView()
    private var thumbnailWidth: NSLayoutConstraint?
    /// Image path this cell is currently showing, so an async decode landing after the cell has
    /// been recycled for a different snippet is discarded instead of drawn on the wrong row.
    private var thumbnailPath: String = ""

    /// Kept on the row rather than read from the label, so a `configure` that
    /// recycles the cell under a stationary pointer resumes the scroll instead of
    /// waiting for the next mouse move.
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false
        enableSwitch.controlSize = .small
        titleLabel.lineBreakMode = .byTruncatingTail
        usageLabel.alignment = .right
        triggerPill.maximumWidth = Self.maxPillWidth

        // The title and preview are the only elastic things in the row: they give
        // way first when a long replacement needs more room than there is.
        // (`MarqueeLabel` sets its own compression resistance in `init`.)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(previewLabel)

        // Trailing metrics live in a stack so the usage counter can be *removed*
        // from layout when it is zero. The old fixed 24pt reservation meant the
        // trigger pills of counted and uncounted rows never lined up.
        metricsStack.orientation = .horizontal
        metricsStack.alignment = .centerY
        metricsStack.spacing = 8
        metricsStack.translatesAutoresizingMaskIntoConstraints = false
        metricsStack.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        metricsStack.setContentHuggingPriority(.defaultHigh + 1, for: .horizontal)
        // Now that the text column claims the rest of the row, the metrics have
        // to stay welded to their own content width. `setContentHuggingPriority`
        // is not enough — a stack view arranges by its *own* hugging priority,
        // and under the default `.gravityAreas` it happily stretched across the
        // row and flung the usage count away from its pill.
        metricsStack.distribution = .fill
        metricsStack.setHuggingPriority(.required, for: .horizontal)
        usageLabel.setContentHuggingPriority(.required, for: .horizontal)
        usageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        metricsStack.addArrangedSubview(triggerPill)
        metricsStack.addArrangedSubview(usageLabel)

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.imageScaling = .scaleProportionallyDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 4
        thumbnail.layer?.masksToBounds = true
        thumbnail.setAccessibilityElement(false)
        addSubview(thumbnail)
        addSubview(enableSwitch)
        addSubview(textStack)
        addSubview(metricsStack)
        addSubview(separator)

        // The 1pt separator sits on the bottom edge, so everything centres against
        // a half-point-shifted axis to stay optically centred inside the row.
        let centreOffset: CGFloat = -0.5
        NSLayoutConstraint.activate([
            enableSwitch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            enableSwitch.centerYAnchor.constraint(equalTo: centerYAnchor, constant: centreOffset),

            // Both labels span the whole text column, and the column spans the
            // whole row. As a `<=`, the stack settled at whatever its widest
            // label measured — so a preview one point past its own measured
            // width truncated ("El Paso" → "El P…") with hundreds of points of
            // empty row to its right, and a recycled cell inherited the previous
            // occupant's narrower width. The trigger pill still takes the space
            // it needs: it outranks the text on hugging and compression alike.
            titleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),

            thumbnail.leadingAnchor.constraint(equalTo: enableSwitch.trailingAnchor, constant: 12),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor, constant: centreOffset),
            thumbnail.heightAnchor.constraint(lessThanOrEqualToConstant: SnippetThumbnailCache.thumbnailEdge),

            textStack.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 0),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: centreOffset),
            textStack.trailingAnchor.constraint(equalTo: metricsStack.leadingAnchor, constant: -12),

            metricsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            metricsStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: centreOffset),

            separator.leadingAnchor.constraint(equalTo: enableSwitch.trailingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])

        // Collapsed by default; `configure` widens it only for image snippets.
        let width = thumbnail.widthAnchor.constraint(equalToConstant: 0)
        width.isActive = true
        thumbnailWidth = width
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Hover
    //
    // A truncated replacement scrolls only while the pointer is on its row, so
    // the list stays still until you actually go looking at one.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        // `.inVisibleRect` keeps the area correct as the table scrolls and as the
        // cell is recycled at a different size, without recomputing the rect.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        previewLabel.isScrolling = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        previewLabel.isScrolling = false
    }

    /// Shows a cached thumbnail for image snippets and collapses to nothing for every other
    /// kind, so text rows keep their previous layout exactly.
    ///
    /// Decoding happens off the main thread. The completion checks `thumbnailPath` before
    /// drawing: a recycled cell that has moved on to a different snippet must not have the
    /// previous row's image land on it.
    private func configureThumbnail(for snippet: SnippetModel, isCompact: Bool) {
        guard snippet.isImageSnippet, !isCompact else {
            thumbnailPath = ""
            thumbnail.image = nil
            thumbnail.isHidden = true
            thumbnailWidth?.constant = 0
            return
        }
        let edge = SnippetThumbnailCache.thumbnailEdge
        thumbnailPath = snippet.imagePath
        thumbnail.isHidden = false
        // Reserve the space before the image arrives so the row does not reflow under the user.
        thumbnailWidth?.constant = edge + 10

        let path = snippet.imagePath
        if let cached = SnippetThumbnailCache.shared.thumbnail(for: path, edge: edge, completion: {
            [weak self] image in
            guard let self, self.thumbnailPath == path else { return }
            self.thumbnail.image = image
        }) {
            thumbnail.image = cached
        } else {
            // Placeholder until the decode lands — and the permanent state for an image whose
            // file has gone missing, which reads as "this is an image snippet, and it is broken".
            thumbnail.image = DevTypeTheme.symbol(
                "photo",
                size: 16,
                weight: .regular,
                color: DevTypeTheme.textTertiary
            )
        }
    }

    /// §4.5: `usageCount` is passed in rather than read from `snippet.usageCount`
    /// — usage now lives in a coalesced sidecar and the model field is legacy.
    ///
    /// No row here is ever a secret: the manager's `groups` come from
    /// `SnippetStore.loadSnippetGroups()`, which lifts every secret out into the independent
    /// `secrets` collection the Secrets manager owns. There is nothing to mask.
    func configure(with snippet: SnippetModel, usageCount: Int, isCompact: Bool = false) {
        let loc = LocalizationManager.shared
        enableSwitch.state = snippet.enabled ? .on : .off
        titleLabel.stringValue = snippet.displayTitle
        titleLabel.textColor = snippet.enabled ? DevTypeTheme.textPrimary : DevTypeTheme.textTertiary
        titleLabel.font = isCompact ? DevTypeTheme.font(12, .semibold) : DevTypeTheme.font(13, .semibold)
        configureThumbnail(for: snippet, isCompact: isCompact)

        // The filename is the least informative thing about an image, and the thumbnail beside
        // it now carries the identity. Say what the row *is*, and leave the path to the tooltip
        // and the editor.
        previewLabel.stringValue = snippet.isImageSnippet
            ? loc.s("manager.preview.image")
            : SnippetOneLinePreview.text(snippet.replacementText)
        previewLabel.textColor = snippet.enabled ? DevTypeTheme.textSecondary : DevTypeTheme.textTertiary
        previewLabel.isHidden = isCompact
        // Recycled cells inherit whatever the pointer is doing to *this* row now,
        // not what it was doing to the snippet that used to live here.
        previewLabel.isScrolling = isHovered && !isCompact

        // A replacement long enough to truncate is the common case for address,
        // degree, and paragraph snippets — surface the whole thing on hover
        // instead of making the user open the editor to read it.
        toolTip = snippet.isImageSnippet ? snippet.imagePath : snippet.replacementText

        // An empty trigger used to render as "·", which the pill drew as a lone
        // dot in a circle and read as a rendering glitch. An em dash in the muted
        // tint reads as "nothing set here", which is what it means.
        let hasTrigger = !snippet.triggerKeyword.isEmpty
        triggerPill.update(
            text: hasTrigger ? snippet.triggerKeyword : "—",
            tint: hasTrigger && snippet.enabled ? DevTypeTheme.accent : DevTypeTheme.statusGray
        )
        triggerPill.toolTip = hasTrigger ? snippet.triggerKeyword : loc.s("ax.noTrigger")

        usageLabel.stringValue = usageCount > 0 ? "×\(usageCount)" : ""
        usageLabel.isHidden = usageCount == 0
        usageLabel.toolTip = usageCount > 0 ? loc.s("ax.snippetRow.help", usageCount) : nil

        // §5.1: the NSSwitch had no label at all, so VoiceOver said "switch, on"
        // with no indication of *which* snippet it toggles. The row itself was
        // four unlabeled text fields in a plain NSView.
        let spokenTrigger = snippet.triggerKeyword.isEmpty
            ? loc.s("ax.noTrigger")
            : snippet.triggerKeyword
        enableSwitch.setAccessibilityLabel(loc.s("ax.snippetRow.toggle", snippet.displayTitle))
        enableSwitch.setAccessibilityValue(loc.s(snippet.enabled ? "ax.enabled" : "ax.disabled"))
        for label in [titleLabel, usageLabel] {
            label.setAccessibilityElement(false)
        }
        previewLabel.setAccessibilityElement(false)
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
extension SnippetManagerViewController {
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
                // Summed rather than flattened: this runs per outline row render, and the
                // flattened array was allocated and discarded to produce one integer.
                count: groups.reduce(0) { $0 + $1.snippets.count },
                tint: DevTypeTheme.accent,
                enabled: true
            )
        }
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = RoundedSelectionRowView.dequeue(from: outlineView, owner: self)
        rowView.selectionRadius = 7
        rowView.selectionInset = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
        return rowView
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = groupOutline.selectedRow
        guard row >= 0 else { return }
        hasResolvedInitialGroupSelection = true
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
        // §4.6: undoable reorder.
        mutate(
            loc.s("manager.undo.reorderGroups"),
            onCommit: { self.selectedGroupID = id }
        ) { groups in
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
        SnippetReorderEligibility.isAllowed(
            sortMode: sortMode,
            hasConcreteGroup: selectedGroupID != nil,
            filterText: filterField.stringValue,
            filter: activeFilter
        )
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
            usageCount: library.usageCount(for: snippets[row]),
            isCompact: isCompactDensity
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RoundedSelectionRowView.dequeue(from: tableView, owner: self)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateBulkBar()
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
