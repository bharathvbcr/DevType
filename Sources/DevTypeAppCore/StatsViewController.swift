import AppKit
import ExpanderEngine

/// §2: Actionable Insights & Statistics Dashboard.
///
/// Features time-period filtering (All Time, Today, 7D, 30D),
/// visual activity sparkline/bar, actionable insight cards (single-use cleanup,
/// trigger conflict resolver, most valuable snippet), and auto-refresh.
final class StatsViewController: NSViewController {
    private static let charactersPerMinute = 200.0

    private enum TimePeriod: Int, CaseIterable {
        case all = 0
        case today = 1
        case sevenDays = 2
        case thirtyDays = 3
    }

    private let store: SnippetStore
    private let loc = LocalizationManager.shared

    private var selectedPeriod: TimePeriod = .all
    private var refreshTimer: Timer?

    private let periodControl = NSSegmentedControl()
    private let expansionsValue = StatsViewController.makeValueLabel()
    private let charactersValue = StatsViewController.makeValueLabel()
    private let timeValue = StatsViewController.makeValueLabel()
    private let keystrokesValue = StatsViewController.makeValueLabel()

    private let sparklineView = StatsSparklineView()
    private let insightsStack = NSStackView()
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

    deinit {
        refreshTimer?.invalidate()
    }

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

        // Time Period Selector
        periodControl.segmentCount = 4
        periodControl.setLabel(loc.s("stats.period.all"), forSegment: 0)
        periodControl.setLabel(loc.s("stats.period.today"), forSegment: 1)
        periodControl.setLabel(loc.s("stats.period.sevenDays"), forSegment: 2)
        periodControl.setLabel(loc.s("stats.period.thirtyDays"), forSegment: 3)
        periodControl.selectedSegment = 0
        periodControl.target = self
        periodControl.action = #selector(periodChanged)
        periodControl.translatesAutoresizingMaskIntoConstraints = false
        periodControl.controlSize = .small

        let refresh = CapsuleButton(
            title: loc.s("stats.refresh"),
            symbol: "arrow.triangle.2.circlepath",
            style: .secondary,
            target: self,
            action: #selector(refreshTapped)
        )

        let topHeaderRow = NSStackView(views: [title, periodControl, refresh])
        topHeaderRow.orientation = .horizontal
        topHeaderRow.alignment = .centerY
        topHeaderRow.spacing = 10
        topHeaderRow.translatesAutoresizingMaskIntoConstraints = false

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

        // Sparkline View
        sparklineView.translatesAutoresizingMaskIntoConstraints = false

        // Actionable Insights Stack
        insightsStack.orientation = .vertical
        insightsStack.alignment = .leading
        insightsStack.spacing = 8
        insightsStack.translatesAutoresizingMaskIntoConstraints = false

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

        root.addSubview(topHeaderRow)
        root.addSubview(subtitle)
        root.addSubview(metrics)
        root.addSubview(sparklineView)
        root.addSubview(insightsStack)
        root.addSubview(lists)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            topHeaderRow.topAnchor.constraint(equalTo: root.topAnchor),
            topHeaderRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topHeaderRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            subtitle.topAnchor.constraint(equalTo: topHeaderRow.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor),

            metrics.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            metrics.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            metrics.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            sparklineView.topAnchor.constraint(equalTo: metrics.bottomAnchor, constant: 10),
            sparklineView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sparklineView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sparklineView.heightAnchor.constraint(equalToConstant: 44),

            insightsStack.topAnchor.constraint(equalTo: sparklineView.bottomAnchor, constant: 10),
            insightsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            insightsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            emptyLabel.topAnchor.constraint(equalTo: insightsStack.bottomAnchor, constant: 10),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            lists.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 8),
            lists.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            lists.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            lists.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func periodChanged() {
        selectedPeriod = TimePeriod(rawValue: periodControl.selectedSegment) ?? .all
        refresh()
    }

    @objc private func refreshTapped() {
        refresh()
    }

    // MARK: Data & Calculations

    func refresh() {
        let groups = store.loadGroups()
        let snippets = groups.flatMap(\.snippets)

        var totalUses = 0
        var charactersTyped = 0
        var keystrokesSaved = 0
        var singleUseCount = 0
        var mostValuableSnippet: SnippetModel?
        var maxKeystrokesForSnippet = 0

        let calendar = Calendar.current
        let now = Date()

        for snippet in snippets {
            let uses = store.usageCount(for: snippet)
            guard uses > 0 else { continue }

            if uses == 1 { singleUseCount += 1 }

            if let lastDate = store.lastUsedAt(forSnippetID: snippet.id) {
                switch selectedPeriod {
                case .all:
                    break
                case .today:
                    if !calendar.isDateInToday(lastDate) { continue }
                case .sevenDays:
                    if let d = calendar.date(byAdding: .day, value: -7, to: now), lastDate < d { continue }
                case .thirtyDays:
                    if let d = calendar.date(byAdding: .day, value: -30, to: now), lastDate < d { continue }
                }
            }

            totalUses += uses
            let produced = snippet.isImageSnippet ? 0 : snippet.replacementText.count
            let typed = snippet.triggerKeyword.count
            let savedPerUse = max(0, produced - typed)
            let snippetSaved = uses * savedPerUse

            charactersTyped += uses * produced
            keystrokesSaved += snippetSaved

            if snippetSaved > maxKeystrokesForSnippet {
                maxKeystrokesForSnippet = snippetSaved
                mostValuableSnippet = snippet
            }
        }

        expansionsValue.stringValue = format(totalUses)
        charactersValue.stringValue = format(charactersTyped)
        keystrokesValue.stringValue = format(keystrokesSaved)
        timeValue.stringValue = formatDuration(
            minutes: Double(keystrokesSaved) / Self.charactersPerMinute
        )

        // Sparkline sample points
        let top = store.topUsedSnippets(limit: 8)
        let sparkCounts = top.map { store.usageCount(for: $0) }
        sparklineView.setPoints(sparkCounts)

        // Populate Actionable Insights
        populateInsights(singleUseCount: singleUseCount, mostValuable: mostValuableSnippet, maxSaved: maxKeystrokesForSnippet)

        let recent = store.recentlyUsedSnippets(limit: 8)
        fill(topStack, with: top, showsRelativeDate: false)
        fill(recentStack, with: recent, showsRelativeDate: true)

        let hasData = totalUses > 0
        emptyLabel.stringValue = hasData ? "" : loc.s("stats.empty")
        emptyLabel.isHidden = hasData
    }

    private func populateInsights(singleUseCount: Int, mostValuable: SnippetModel?, maxSaved: Int) {
        insightsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let conflicts = store.triggerConflicts()
        if !conflicts.isEmpty {
            let conflictCard = makeInsightCard(
                title: loc.s("stats.insight.conflicts.title"),
                desc: loc.s("stats.insight.conflicts.desc", conflicts.count),
                actionTitle: loc.s("stats.insight.conflicts.action"),
                tint: DevTypeTheme.statusOrange,
                action: #selector(resolveConflictsTapped)
            )
            insightsStack.addArrangedSubview(conflictCard)
            conflictCard.widthAnchor.constraint(equalTo: insightsStack.widthAnchor).isActive = true
        }

        if let mostValuable {
            let timeSavedStr = formatDuration(minutes: Double(maxSaved) / Self.charactersPerMinute)
            let valCard = makeInsightCard(
                title: loc.s("stats.insight.valuable.title"),
                desc: loc.s("stats.insight.valuable.desc", mostValuable.triggerKeyword, timeSavedStr),
                actionTitle: nil,
                tint: DevTypeTheme.statusGreen,
                action: nil
            )
            insightsStack.addArrangedSubview(valCard)
            valCard.widthAnchor.constraint(equalTo: insightsStack.widthAnchor).isActive = true
        }

        if singleUseCount > 2 {
            let singleCard = makeInsightCard(
                title: loc.s("stats.insight.singleUse.title"),
                desc: loc.s("stats.insight.singleUse.desc", singleUseCount),
                actionTitle: loc.s("stats.insight.singleUse.action"),
                tint: DevTypeTheme.accent,
                action: #selector(reviewUnusedTapped)
            )
            insightsStack.addArrangedSubview(singleCard)
            singleCard.widthAnchor.constraint(equalTo: insightsStack.widthAnchor).isActive = true
        }
    }

    private func makeInsightCard(title: String, desc: String, actionTitle: String?, tint: NSColor, action: Selector?) -> NSView {
        let card = GlassCardView(tint: tint.withAlphaComponent(0.06))
        card.translatesAutoresizingMaskIntoConstraints = false
        let content = card.contentView

        let titleLabel = DevTypeTheme.makeLabel(title, font: DevTypeTheme.font(11.5, .bold), color: DevTypeTheme.textPrimary)
        let descLabel = DevTypeTheme.makeLabel(desc, font: DevTypeTheme.font(11), color: DevTypeTheme.textSecondary)

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(textStack)
        var trailingAnchorRef = content.trailingAnchor

        if let actionTitle, let action {
            let btn = CapsuleButton(title: actionTitle, style: .secondary, target: self, action: action)
            btn.controlSize = .small
            btn.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(btn)

            NSLayoutConstraint.activate([
                btn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                btn.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
            trailingAnchorRef = btn.leadingAnchor
        }

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            textStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            textStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchorRef, constant: -8)
        ])

        return card
    }

    @objc private func resolveConflictsTapped() {
        SnippetConflictResolverSheet.present(from: view.window, store: store) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func reviewUnusedTapped() {
        (NSApp.delegate as? AppDelegate)?.openSnippetManager(nil)
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
        row.dtApplyAccessibility(
            role: NSAccessibility.Role.staticText,
            label: "\(snippet.displayTitle), \(detail)"
        )
        trigger.setAccessibilityElement(false)
        detailLabel.setAccessibilityElement(false)
        return row
    }

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

/// Custom lightweight activity sparkline visualizer.
private final class StatsSparklineView: NSView {
    private var points: [Int] = []

    func setPoints(_ points: [Int]) {
        self.points = points
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard points.count > 1 else { return }

        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.04))
        card.frame = bounds

        let maxVal = CGFloat(points.max() ?? 1)
        guard maxVal > 0 else { return }

        let path = NSBezierPath()
        let stepX = bounds.width / CGFloat(points.count - 1)
        let padding: CGFloat = 8

        for (i, p) in points.enumerated() {
            let x = CGFloat(i) * stepX
            let normalized = CGFloat(p) / maxVal
            let y = padding + normalized * (bounds.height - (padding * 2))
            if i == 0 {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }

        DevTypeTheme.accent.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 2.0
        path.stroke()
    }
}
