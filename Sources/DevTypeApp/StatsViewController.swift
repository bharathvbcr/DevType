import AppKit
import ExpanderEngine

// MARK: - §4.5 — usage statistics finally have somewhere to go
//
// The store has counted every expansion since day one, and the *only*
// presentation was a `×N` label on the manager row
// (`SnippetManagerViewController.swift:76`). No characters-saved, no time-saved,
// no top-snippets — TextExpander's headline retention feature, collected and
// thrown away.
//
// Counts are read through `SnippetStore.usageCount(for:)` / `topUsedSnippets` /
// `recentlyUsedSnippets` rather than `snippet.usageCount`, because usage now
// lives in a coalesced sidecar. **`incrementUsage` no longer fires store
// listeners**, so this pane pulls on `refresh()` (view appearance, the Refresh
// button, and whenever the host re-shows it) instead of waiting for a push.

final class StatsViewController: NSViewController {

    /// Rough typing speed used to turn characters into minutes.
    private static let charactersPerMinute = 200.0

    private let store: SnippetStore
    private let loc = LocalizationManager.shared

    private let expansionsValue = StatsViewController.makeValueLabel()
    private let charactersValue = StatsViewController.makeValueLabel()
    private let timeValue = StatsViewController.makeValueLabel()
    private let keystrokesValue = StatsViewController.makeValueLabel()

    private let topStack = NSStackView()
    private let recentStack = NSStackView()
    private let emptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary,
        wrapping: true
    )

    init(store: SnippetStore = .shared) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = DevTypeTheme.makeLabel(
            loc.s("stats.title"),
            font: DevTypeTheme.font(15, .bold),
            color: DevTypeTheme.textPrimary
        )
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = DevTypeTheme.makeLabel(
            loc.s("stats.subtitle"),
            font: DevTypeTheme.font(11.5),
            color: DevTypeTheme.textSecondary
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let refresh = CapsuleButton(
            title: loc.s("stats.refresh"),
            symbol: "arrow.triangle.2.circlepath",
            style: .secondary,
            target: self,
            action: #selector(refreshTapped)
        )

        let metrics = NSStackView(views: [
            makeMetricCard(loc.s("stats.totalExpansions"), value: expansionsValue, symbol: "bolt.fill"),
            makeMetricCard(loc.s("stats.charactersSaved"), value: charactersValue, symbol: "text.insert"),
            makeMetricCard(loc.s("stats.keystrokesSaved"), value: keystrokesValue, symbol: "keyboard"),
            makeMetricCard(loc.s("stats.timeSaved"), value: timeValue, symbol: "clock.arrow.circlepath")
        ])
        metrics.orientation = .horizontal
        metrics.distribution = .fillEqually
        metrics.spacing = 10
        metrics.translatesAutoresizingMaskIntoConstraints = false

        let timeHint = DevTypeTheme.makeLabel(
            loc.s("stats.timeSaved.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary
        )
        timeHint.translatesAutoresizingMaskIntoConstraints = false

        configureListStack(topStack)
        configureListStack(recentStack)

        let topSection = makeListSection(loc.s("stats.top"), stack: topStack)
        let recentSection = makeListSection(loc.s("stats.recent"), stack: recentStack)
        let lists = NSStackView(views: [topSection, recentSection])
        lists.orientation = .horizontal
        lists.distribution = .fillEqually
        lists.alignment = .top
        lists.spacing = 12
        lists.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        root.addSubview(title)
        root.addSubview(subtitle)
        root.addSubview(refresh)
        root.addSubview(metrics)
        root.addSubview(timeHint)
        root.addSubview(lists)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor),

            refresh.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            refresh.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            metrics.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            metrics.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            metrics.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            timeHint.topAnchor.constraint(equalTo: metrics.bottomAnchor, constant: 6),
            timeHint.leadingAnchor.constraint(equalTo: root.leadingAnchor),

            emptyLabel.topAnchor.constraint(equalTo: timeHint.bottomAnchor, constant: 14),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            lists.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 10),
            lists.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            lists.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // `equalTo` (not `lessThanOrEqualTo`) so the controller's view has a
            // determinate height when it is an arranged subview of a stack.
            lists.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    // MARK: Data

    @objc private func refreshTapped() { refresh() }

    /// Re-reads every number from the store. Safe to call as often as you like.
    func refresh() {
        let groups = store.loadGroups()
        let snippets = groups.flatMap(\.snippets)

        var totalUses = 0
        var charactersTyped = 0
        var keystrokesSaved = 0
        for snippet in snippets {
            // §4.5: read through the store, not `snippet.usageCount` — the model
            // field is legacy and no longer authoritative.
            let uses = store.usageCount(for: snippet)
            guard uses > 0 else { continue }
            totalUses += uses
            let produced = snippet.isImageSnippet ? 0 : snippet.replacementText.count
            let typed = snippet.triggerKeyword.count
            charactersTyped += uses * produced
            keystrokesSaved += uses * max(0, produced - typed)
        }

        expansionsValue.stringValue = format(totalUses)
        charactersValue.stringValue = format(charactersTyped)
        keystrokesValue.stringValue = format(keystrokesSaved)
        timeValue.stringValue = formatDuration(
            minutes: Double(keystrokesSaved) / Self.charactersPerMinute
        )

        let top = store.topUsedSnippets(limit: 8)
        let recent = store.recentlyUsedSnippets(limit: 8)
        fill(topStack, with: top, showsRelativeDate: false)
        fill(recentStack, with: recent, showsRelativeDate: true)

        let hasData = totalUses > 0
        emptyLabel.stringValue = hasData ? "" : loc.s("stats.empty")
        emptyLabel.isHidden = hasData
    }

    private func fill(_ stack: NSStackView, with snippets: [SnippetModel], showsRelativeDate: Bool) {
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        for snippet in snippets {
            stack.addArrangedSubview(makeSnippetRow(snippet, showsRelativeDate: showsRelativeDate))
        }
    }

    private func makeSnippetRow(_ snippet: SnippetModel, showsRelativeDate: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let trigger = DevTypeTheme.makeLabel(
            snippet.triggerKeyword.isEmpty ? snippet.displayTitle : snippet.triggerKeyword,
            font: DevTypeTheme.mono(11, .semibold),
            color: DevTypeTheme.accentBright
        )
        trigger.translatesAutoresizingMaskIntoConstraints = false
        trigger.lineBreakMode = .byTruncatingTail

        let uses = store.usageCount(for: snippet)
        let detail: String
        if showsRelativeDate {
            if let date = store.lastUsedAt(forSnippetID: snippet.id) {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                detail = formatter.localizedString(for: date, relativeTo: Date())
            } else {
                detail = loc.s("stats.never")
            }
        } else {
            detail = loc.p("stats.uses", count: uses, uses)
        }
        let detailLabel = DevTypeTheme.makeLabel(
            detail,
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.textTertiary
        )
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(trigger)
        row.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            trigger.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            trigger.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            trigger.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
            trigger.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -8),
            detailLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            detailLabel.centerYAnchor.constraint(equalTo: trigger.centerYAnchor)
        ])
        // §5.1: one utterance per row instead of two orphaned static texts.
        row.dtApplyAccessibility(
            role: NSAccessibility.Role.staticText,
            label: "\(snippet.displayTitle), \(detail)"
        )
        trigger.setAccessibilityElement(false)
        detailLabel.setAccessibilityElement(false)
        return row
    }

    // MARK: Building blocks

    private static func makeValueLabel() -> NSTextField {
        let label = DevTypeTheme.makeLabel(
            "0",
            font: DevTypeTheme.font(20, .bold),
            color: DevTypeTheme.textPrimary
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeMetricCard(_ caption: String, value: NSTextField, symbol: String) -> NSView {
        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.06))
        card.translatesAutoresizingMaskIntoConstraints = false
        let content = card.contentView

        let captionLabel = DevTypeTheme.makeLabel(
            caption,
            font: DevTypeTheme.font(10.5, .medium),
            color: DevTypeTheme.textSecondary,
            wrapping: true
        )
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.maximumNumberOfLines = 2

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = DevTypeTheme.tintedSymbol(symbol, size: 11, weight: .semibold, color: DevTypeTheme.accent)
        icon.setAccessibilityElement(false)

        content.addSubview(icon)
        content.addSubview(value)
        content.addSubview(captionLabel)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),

            value.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
            value.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            value.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),

            captionLabel.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 2),
            captionLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            captionLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 12)
        ])
        return card
    }

    private func configureListStack(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeListSection(_ title: String, stack: NSStackView) -> NSView {
        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.04))
        card.translatesAutoresizingMaskIntoConstraints = false
        let content = card.contentView

        let header = DevTypeTheme.makeLabel(
            title,
            font: DevTypeTheme.font(11, .bold),
            color: DevTypeTheme.textSecondary
        )
        header.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 90)
        ])
        return card
    }

    // MARK: Formatting

    private func format(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func formatDuration(minutes: Double) -> String {
        let seconds = max(0, minutes * 60)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "0"
    }
}
