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

            textStack.leadingAnchor.constraint(equalTo: enableSwitch.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: centreOffset),
            textStack.trailingAnchor.constraint(equalTo: metricsStack.leadingAnchor, constant: -12),

            metricsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            metricsStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: centreOffset),

            separator.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
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

    /// §4.5: `usageCount` is passed in rather than read from `snippet.usageCount`
    /// — usage now lives in a coalesced sidecar and the model field is legacy.
    func configure(with snippet: SnippetModel, usageCount: Int, isCompact: Bool = false) {
        let loc = LocalizationManager.shared
        enableSwitch.state = snippet.enabled ? .on : .off
        titleLabel.stringValue = snippet.displayTitle
        titleLabel.textColor = snippet.enabled ? DevTypeTheme.textPrimary : DevTypeTheme.textTertiary
        titleLabel.font = isCompact ? DevTypeTheme.font(12, .semibold) : DevTypeTheme.font(13, .semibold)
        // A secret has no `replacementText` to show — by construction, not by redaction here.
        // The mask is so the row does not read as an empty snippet the user should go fix.
        let preview: String
        if snippet.isImageSnippet {
            preview = "🖼 \(snippet.imagePath)"
        } else if snippet.isSecret {
            preview = "🔑 \(snippet.maskedReplacement)"
        } else {
            preview = snippet.replacementText.replacingOccurrences(of: "\n", with: " ↵ ")
        }
        previewLabel.stringValue = preview
        previewLabel.textColor = snippet.enabled ? DevTypeTheme.textSecondary : DevTypeTheme.textTertiary
        previewLabel.isHidden = isCompact
        // Recycled cells inherit whatever the pointer is doing to *this* row now,
        // not what it was doing to the snippet that used to live here.
        previewLabel.isScrolling = isHovered && !isCompact

        // A replacement long enough to truncate is the common case for address,
        // degree, and paragraph snippets — surface the whole thing on hover
        // instead of making the user open the editor to read it.
        toolTip = snippet.isImageSnippet
            ? snippet.imagePath
            : (snippet.isSecret ? snippet.maskedReplacement : snippet.replacementText)

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

        // The vertical chain (badge.top … ctaButton.bottom) gives this view its height.
        // Width comes from the `>=`/`<=` edge pairs below: centering alone leaves the
        // width unconstrained, so the view collapsed to 0pt. Subviews still *drew*
        // (AppKit does not clip to bounds) but `hitTest` rejects points outside the
        // view's own bounds — so clicks on the CTA fell through to the table behind it
        // and the button looked dead.
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor),
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            ctaButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            ctaButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            ctaButton.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            ctaButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
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

enum SnippetFilterChip: Int, CaseIterable {
    case all = 0
    case enabled = 1
    case disabled = 2
    case secrets = 3
    case images = 4
    case macros = 5
    case conflicts = 6
    case unused = 7

    var localizationKey: String {
        switch self {
        case .all: return "manager.filter.all"
        case .enabled: return "manager.filter.enabled"
        case .disabled: return "manager.filter.disabled"
        case .secrets: return "manager.filter.secrets"
        case .images: return "manager.filter.images"
        case .macros: return "manager.filter.macros"
        case .conflicts: return "manager.filter.conflicts"
        case .unused: return "manager.filter.unused"
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

    // Density & Filter Chips
    private var activeFilterChip: SnippetFilterChip = .all
    private var isCompactDensity: Bool = false
    private let densityControl = NSSegmentedControl()
    private let filterChipsStack = NSStackView()
    private var filterChipButtons: [SnippetFilterChip: CapsuleButton] = [:]

    // Bulk Operations Bar
    private let bulkBar = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.12))
    private let selectedCountLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(12, .bold), color: DevTypeTheme.textPrimary)
    private var primaryActionBar: NSStackView?
    private var utilityActionBar: NSStackView?

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

        // Density control
        densityControl.segmentCount = 2
        densityControl.setLabel(loc.s("manager.density.comfortable"), forSegment: 0)
        densityControl.setLabel(loc.s("manager.density.compact"), forSegment: 1)
        densityControl.selectedSegment = 0
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
            "GROUPS",
            font: DevTypeTheme.font(10, .bold),
            color: DevTypeTheme.textTertiary
        )
        groupsCaption.translatesAutoresizingMaskIntoConstraints = false
        sidebarContent.addSubview(groupsCaption)

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
        groupOutline.onKeyDown = { [weak self] event in
            self?.handleGroupKeyDown(event) ?? false
        }
        let groupCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("group"))
        groupCol.title = "Groups"
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

        // Filter Chips Bar
        filterChipsStack.orientation = .horizontal
        filterChipsStack.spacing = 6
        filterChipsStack.translatesAutoresizingMaskIntoConstraints = false
        for chip in SnippetFilterChip.allCases {
            let btn = CapsuleButton(
                title: loc.s(chip.localizationKey),
                style: chip == activeFilterChip ? .primary : .secondary,
                target: self,
                action: #selector(filterChipTapped(_:))
            )
            btn.tag = chip.rawValue
            btn.controlSize = .small
            filterChipButtons[chip] = btn
            filterChipsStack.addArrangedSubview(btn)
        }
        listContent.addSubview(filterChipsStack)

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
            filterChipsStack.topAnchor.constraint(equalTo: listContent.topAnchor, constant: 8),
            filterChipsStack.leadingAnchor.constraint(equalTo: listContent.leadingAnchor, constant: 10),
            filterChipsStack.trailingAnchor.constraint(lessThanOrEqualTo: listContent.trailingAnchor, constant: -10),

            healthBanner.topAnchor.constraint(equalTo: filterChipsStack.bottomAnchor, constant: 4),
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
        let importButton = CapsuleButton(
            title: loc.s("manager.import"),
            symbol: "square.and.arrow.down",
            style: .secondary,
            target: self,
            action: #selector(importSnippets)
        )
        let exportButton = CapsuleButton(
            title: loc.s("manager.export"),
            symbol: "square.and.arrow.up",
            style: .secondary,
            target: self,
            action: #selector(exportSnippets)
        )
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
        primaryStack.setContentHuggingPriority(.required, for: .vertical)
        primaryActionBar = primaryStack

        let utilityStack = NSStackView(views: [statsButton, importButton, exportButton, resetButton])
        utilityStack.orientation = .horizontal
        utilityStack.spacing = 10
        utilityStack.translatesAutoresizingMaskIntoConstraints = false
        utilityStack.setContentHuggingPriority(.required, for: .vertical)
        utilityActionBar = utilityStack

        // MARK: Bulk Actions Bar
        bulkBar.translatesAutoresizingMaskIntoConstraints = false
        bulkBar.isHidden = true
        let bulkContent = bulkBar.contentView

        let bulkEnableBtn = CapsuleButton(title: loc.s("manager.bulk.enable"), style: .secondary, target: self, action: #selector(bulkEnableSelected))
        let bulkDisableBtn = CapsuleButton(title: loc.s("manager.bulk.disable"), style: .secondary, target: self, action: #selector(bulkDisableSelected))
        let bulkMoveBtn = CapsuleButton(title: loc.s("manager.bulk.moveToGroup"), style: .secondary, target: self, action: #selector(bulkMoveSelected(_:)))
        let bulkDuplicateBtn = CapsuleButton(title: loc.s("manager.bulk.duplicate"), style: .secondary, target: self, action: #selector(bulkDuplicateSelected))
        let bulkPrefixSuffixBtn = CapsuleButton(title: loc.s("manager.bulk.prefixSuffix"), style: .secondary, target: self, action: #selector(bulkPrefixSuffixSelected))
        let bulkDeleteBtn = CapsuleButton(title: loc.s("manager.bulk.delete"), style: .destructive, target: self, action: #selector(bulkDeleteSelected))
        let bulkSelectAllBtn = CapsuleButton(title: loc.s("manager.bulk.selectAll"), style: .secondary, target: self, action: #selector(selectAllSnippets))

        let bulkLeftStack = NSStackView(views: [selectedCountLabel, bulkEnableBtn, bulkDisableBtn, bulkMoveBtn, bulkDuplicateBtn, bulkPrefixSuffixBtn])
        bulkLeftStack.orientation = .horizontal
        bulkLeftStack.spacing = 8
        bulkLeftStack.alignment = .centerY
        bulkLeftStack.translatesAutoresizingMaskIntoConstraints = false

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

            utilityStack.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -20),
            utilityStack.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -16),

            bulkBar.leadingAnchor.constraint(equalTo: mainView.leadingAnchor, constant: 16),
            bulkBar.trailingAnchor.constraint(equalTo: mainView.trailingAnchor, constant: -16),
            bulkBar.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -12),
            bulkBar.heightAnchor.constraint(equalToConstant: 44)
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

    @objc private func densityChanged() {
        isCompactDensity = densityControl.selectedSegment == 1
        tableView.rowHeight = isCompactDensity ? 38 : 52
        tableView.reloadData()
    }

    @objc private func filterChipTapped(_ sender: NSButton) {
        guard let chip = SnippetFilterChip(rawValue: sender.tag) else { return }
        activeFilterChip = chip
        for (c, btn) in filterChipButtons {
            btn.style = (c == chip ? .primary : .secondary)
        }
        applyFilterAndReloadTable()
    }

    @objc private func filterChanged() {
        applyFilterAndReloadTable()
    }

    @objc private func clearFilter() {
        filterField.stringValue = ""
        applyFilterAndReloadTable()
    }

    @objc private func resetFilterChip() {
        activeFilterChip = .all
        for (c, btn) in filterChipButtons {
            btn.style = (c == .all ? .primary : .secondary)
        }
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

        var filtered = pool
        switch activeFilterChip {
        case .all:
            break
        case .enabled:
            filtered = filtered.filter(\.enabled)
        case .disabled:
            filtered = filtered.filter { !$0.enabled }
        case .secrets:
            filtered = filtered.filter(\.isSecret)
        case .images:
            filtered = filtered.filter(\.isImageSnippet)
        case .macros:
            filtered = filtered.filter { $0.replacementText.contains("%") || $0.replacementText.contains("{{") }
        case .conflicts:
            let conflictIDs = Set(SnippetStore.shared.triggerConflicts().flatMap(\.snippetIDs))
            filtered = filtered.filter { conflictIDs.contains($0.id) }
        case .unused:
            filtered = filtered.filter { SnippetStore.shared.usageCount(for: $0) == 0 }
        }

        if !filter.isEmpty {
            filtered = filtered.filter {
                $0.triggerKeyword.lowercased().contains(filter)
                    || $0.displayTitle.lowercased().contains(filter)
                    || $0.replacementText.lowercased().contains(filter)
            }
        }
        snippets = sorted(filtered)
        tableView.sortDescriptors = sortMode.sortDescriptor.map { [$0] } ?? []
        let all = groups.flatMap(\.snippets)
        let active = all.filter(\.enabled).count
        statsPill.update(text: loc.s("manager.stats", active, all.count), tint: DevTypeTheme.accent)

        emptyState.isHidden = !snippets.isEmpty
        if snippets.isEmpty {
            let title: String
            let subtitle: String
            let cta: String?
            let action: Selector?

            if !filter.isEmpty {
                title = loc.s("snippets.empty.noMatch", filterField.stringValue)
                subtitle = ""
                cta = loc.s("common.clear")
                action = #selector(clearFilter)
            } else if activeFilterChip != .all {
                title = loc.s(activeFilterChip.localizationKey)
                subtitle = loc.s("snippets.empty.noMatch", "")
                cta = loc.s("manager.filter.all")
                action = #selector(resetFilterChip)
            } else {
                title = loc.s("manager.empty.title")
                subtitle = loc.s("manager.empty.subtitle")
                cta = loc.s("manager.add")
                action = #selector(addSnippet)
            }

            emptyState.configure(
                title: title,
                subtitle: subtitle,
                ctaTitle: cta,
                target: self,
                action: action
            )
        }
        tableView.reloadData()
        updateBulkBar()
    }

    private func updateBulkBar() {
        let count = tableView.selectedRowIndexes.count
        if count > 1 {
            bulkBar.isHidden = false
            primaryActionBar?.isHidden = true
            utilityActionBar?.isHidden = true
            selectedCountLabel.stringValue = loc.s("manager.bulk.selected", count)
        } else {
            bulkBar.isHidden = true
            primaryActionBar?.isHidden = false
            utilityActionBar?.isHidden = false
        }
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

    @objc func addSnippet() {
        presentEditor(for: nil, draft: nil)
    }

    @objc private func addSnippetFromTemplate() {
        SnippetTemplatePanel.present(from: view.window) { [weak self] template in
            guard let self else { return }
            let draft = template.makeDraft(loc: self.loc)
            self.presentEditor(for: nil, draft: draft)
        }
    }

    @objc private func editSelectedSnippet() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < snippets.count else { return }
        presentEditor(for: snippets[selectedRow], draft: nil)
    }

    private func presentEditor(for existing: SnippetModel?, draft: SnippetModel?) {
        SnippetEditorSheet.present(
            from: view.window,
            existing: existing,
            draft: draft,
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
        // User preference: conflict warnings off means the editor validates nothing here —
        // the save proceeds and the matcher's normal collision rules apply.
        guard SnippetStore.isConflictDetectionEnabled else { return nil }
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

    @objc private func deleteSnippet() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < snippets.count else { return }
        let snippet = snippets[selectedRow]

        // A secret's deletion is not undoable in the way the rest of this manager is: the
        // keychain purge follows the save, and the value is not in the undo snapshot to restore
        // (that is the point of the feature). Say so before it happens rather than after.
        let message = snippet.isSecret
            ? loc.s("manager.delete.confirm.secret", snippet.displayTitle)
            : loc.s("manager.delete.confirm.message", snippet.displayTitle)

        DevTypeAlert.confirm(
            title: loc.s("manager.delete.confirm.title"),
            message: message,
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
        // A duplicate gets a new UUID, so it cannot inherit the original's keychain entry — and
        // copying the value across would be a second, unasked-for place the secret lives. The
        // copy is deliberately a plain, empty snippet the user can fill in.
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

    /// Header gear — opens Preferences ▸ General without a trip to the menu bar.
    @objc private func openSettings() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.openPreferences(nil, tab: .general)
        } else {
            PreferencesWindowController.shared.show(tab: .general, hotkeyManager: nil)
        }
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

        if modifiers == .command, code == kVK_ANSI_A {
            selectAllSnippets()
            return true
        }
        if modifiers == .command, code == kVK_ANSI_D {
            guard hasSelection else { return true }
            if tableView.selectedRowIndexes.count > 1 {
                bulkDuplicateSelected()
            } else {
                duplicateSelectedSnippet()
            }
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch code {
        case kVK_Delete, kVK_ForwardDelete:
            guard hasSelection else { return true }
            if tableView.selectedRowIndexes.count > 1 {
                bulkDeleteSelected()
            } else {
                deleteSnippet()
            }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard hasSelection else { return true }
            editSelectedSnippet()
            return true
        case kVK_Space:
            guard hasSelection else { return true }
            if tableView.selectedRowIndexes.count > 1 {
                let anyDisabled = tableView.selectedRowIndexes.contains { $0 < snippets.count && !snippets[$0].enabled }
                if anyDisabled { bulkEnableSelected() } else { bulkDisableSelected() }
            } else {
                toggleSelectedSnippetEnabled()
            }
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
            usageCount: SnippetStore.shared.usageCount(for: snippets[row]),
            isCompact: isCompactDensity
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RoundedSelectionRowView()
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

    // MARK: - Bulk Operations

    @objc private func selectAllSnippets() {
        tableView.selectAll(nil)
    }

    @objc private func bulkEnableSelected() {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })
        mutate(loc.s("manager.bulk.enable")) { groups in
            for gi in groups.indices {
                for si in groups[gi].snippets.indices {
                    if selectedIDs.contains(groups[gi].snippets[si].id) {
                        groups[gi].snippets[si].enabled = true
                    }
                }
            }
        }
    }

    @objc private func bulkDisableSelected() {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })
        mutate(loc.s("manager.bulk.disable")) { groups in
            for gi in groups.indices {
                for si in groups[gi].snippets.indices {
                    if selectedIDs.contains(groups[gi].snippets[si].id) {
                        groups[gi].snippets[si].enabled = false
                    }
                }
            }
        }
    }

    @objc private func bulkMoveSelected(_ sender: NSButton) {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })

        let menu = NSMenu()
        for group in groups {
            let item = NSMenuItem(title: group.name, action: #selector(confirmBulkMove(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = group.id
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func confirmBulkMove(_ sender: NSMenuItem) {
        guard let destID = sender.representedObject as? UUID else { return }
        let selectedRows = tableView.selectedRowIndexes
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })

        mutate(loc.s("manager.bulk.moveToGroup")) { groups in
            guard let destGI = groups.firstIndex(where: { $0.id == destID }) else { return }
            var movedSnippets: [SnippetModel] = []
            for gi in groups.indices {
                if groups[gi].id == destID { continue }
                movedSnippets.append(contentsOf: groups[gi].snippets.filter { selectedIDs.contains($0.id) })
                groups[gi].snippets.removeAll(where: { selectedIDs.contains($0.id) })
            }
            groups[destGI].snippets.append(contentsOf: movedSnippets)
        }
    }

    @objc private func bulkDuplicateSelected() {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })

        mutate(loc.s("manager.bulk.duplicate")) { groups in
            for gi in groups.indices {
                var duplicates: [SnippetModel] = []
                for snippet in groups[gi].snippets where selectedIDs.contains(snippet.id) {
                    let dup = SnippetModel(
                        id: UUID(),
                        title: snippet.displayTitle + " (Copy)",
                        triggerKeyword: snippet.triggerKeyword + "copy",
                        replacementText: snippet.replacementText,
                        isCaseSensitive: snippet.isCaseSensitive,
                        requireWordBoundary: snippet.requireWordBoundary,
                        enabled: snippet.enabled,
                        imagePath: snippet.imagePath,
                        isSecret: snippet.isSecret
                    )
                    duplicates.append(dup)
                }
                groups[gi].snippets.append(contentsOf: duplicates)
            }
        }
    }

    @objc private func bulkDeleteSelected() {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = loc.s("manager.delete")
        alert.informativeText = loc.s("manager.bulk.selected", selectedIDs.count)
        alert.addButton(withTitle: loc.s("common.delete"))
        alert.addButton(withTitle: loc.s("common.cancel"))

        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                self.mutate(self.loc.s("manager.bulk.delete")) { groups in
                    for gi in groups.indices {
                        groups[gi].snippets.removeAll(where: { selectedIDs.contains($0.id) })
                    }
                }
            }
        }
    }

    @objc private func bulkExportSelected() {
        LibraryExporter.present(from: view.window)
    }

    @objc private func bulkPrefixSuffixSelected() {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let selectedIDs = Set(selectedRows.compactMap { $0 < snippets.count ? snippets[$0].id : nil })

        let alert = NSAlert()
        alert.messageText = loc.s("manager.bulk.prefixSuffix.title")
        alert.addButton(withTitle: loc.s("manager.bulk.prefixSuffix.apply", selectedIDs.count))
        alert.addButton(withTitle: loc.s("common.cancel"))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 60)

        let prefixField = NSTextField()
        prefixField.placeholderString = loc.s("manager.bulk.prefixSuffix.prefix")
        let suffixField = NSTextField()
        suffixField.placeholderString = loc.s("manager.bulk.prefixSuffix.suffix")

        stack.addArrangedSubview(prefixField)
        stack.addArrangedSubview(suffixField)
        alert.accessoryView = stack

        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                let prefix = prefixField.stringValue
                let suffix = suffixField.stringValue
                guard !prefix.isEmpty || !suffix.isEmpty else { return }

                self.mutate(self.loc.s("manager.bulk.prefixSuffix")) { groups in
                    for gi in groups.indices {
                        for si in groups[gi].snippets.indices {
                            if selectedIDs.contains(groups[gi].snippets[si].id) {
                                groups[gi].snippets[si].triggerKeyword = prefix + groups[gi].snippets[si].triggerKeyword + suffix
                            }
                        }
                    }
                }
            }
        }
    }
}
