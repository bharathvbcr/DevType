import AppKit
import ExpanderEngine

enum StatsTimePeriod: Int, CaseIterable, Hashable {
    case all = 0
    case today = 1
    case sevenDays = 2
    case thirtyDays = 3

    var usagePeriod: UsageStatsStore.Period {
        switch self {
        case .all: return .all
        case .today: return .today
        case .sevenDays: return .sevenDays
        case .thirtyDays: return .thirtyDays
        }
    }
}

/// Pure projection consumed by the Statistics view. Period metrics, lists, and the sparkline come
/// from one immutable period snapshot; the unused insight comes from an immutable lifetime
/// snapshot so changing the visible period cannot redefine "unused."
struct StatsPresentationSnapshot {
    struct SnippetUsage: Equatable {
        let snippet: SnippetModel
        let usageCount: Int
        let lastUsedAt: Date?
    }

    let generatedAt: Date
    let totalUses: Int
    let charactersProduced: Int
    let keystrokesSaved: Int
    let unusedCount: Int
    let mostValuableSnippet: SnippetModel?
    let mostValuableKeystrokesSaved: Int
    let top: [SnippetUsage]
    let recent: [SnippetUsage]
    let sparklineCounts: [Int]
    /// Exact lifetime usage whose timestamps were intentionally evicted from the bounded sidecar.
    /// Cards remain exact; only the timeline is partial when this is non-zero.
    let unbucketedUsageCount: Int

    static func make(
        snippets: [SnippetModel],
        usage: UsageStatsStore.PeriodSnapshot,
        lifetimeUsage: UsageStatsStore.PeriodSnapshot,
        listLimit: Int = 8
    ) -> StatsPresentationSnapshot {
        var snippetsByID: [UUID: SnippetModel] = [:]
        var orderedSnippets: [SnippetModel] = []
        for snippet in snippets where snippetsByID[snippet.id] == nil {
            snippetsByID[snippet.id] = snippet
            orderedSnippets.append(snippet)
        }

        var totalUses = 0
        var charactersProduced = 0
        var keystrokesSaved = 0
        var unusedCount = 0
        var mostValuableSnippet: SnippetModel?
        var mostValuableKeystrokesSaved = 0

        for snippet in orderedSnippets {
            let lifetimeCount = max(snippet.usageCount, lifetimeUsage.usageCount(for: snippet.id))
            if lifetimeCount == 0 { unusedCount += 1 }
            let count = usage.usageCount(for: snippet.id)
            guard count > 0 else { continue }
            totalUses = addingClamped(totalUses, count)

            let producedPerUse = snippet.isImageSnippet ? 0 : snippet.replacementText.count
            let savedPerUse = max(0, producedPerUse - snippet.triggerKeyword.count)
            charactersProduced = addingClamped(
                charactersProduced,
                multiplyingClamped(count, producedPerUse)
            )
            let saved = multiplyingClamped(count, savedPerUse)
            keystrokesSaved = addingClamped(keystrokesSaved, saved)
            if saved > mostValuableKeystrokesSaved {
                mostValuableSnippet = snippet
                mostValuableKeystrokesSaved = saved
            }
        }

        let safeLimit = max(0, listLimit)
        let top = usage.topSnippetIDs(limit: safeLimit).compactMap { id -> SnippetUsage? in
            guard let snippet = snippetsByID[id], let stat = usage.entries[id] else { return nil }
            return SnippetUsage(
                snippet: snippet,
                usageCount: stat.usageCount,
                lastUsedAt: stat.lastUsedAt
            )
        }
        let recent = usage.recentSnippetIDs(limit: safeLimit).compactMap { id -> SnippetUsage? in
            guard let snippet = snippetsByID[id], let stat = usage.entries[id] else { return nil }
            return SnippetUsage(
                snippet: snippet,
                usageCount: stat.usageCount,
                lastUsedAt: stat.lastUsedAt
            )
        }

        return StatsPresentationSnapshot(
            generatedAt: usage.generatedAt,
            totalUses: totalUses,
            charactersProduced: charactersProduced,
            keystrokesSaved: keystrokesSaved,
            unusedCount: unusedCount,
            mostValuableSnippet: mostValuableSnippet,
            mostValuableKeystrokesSaved: mostValuableKeystrokesSaved,
            top: top,
            recent: recent,
            sparklineCounts: usage.timeline.map(\.usageCount),
            unbucketedUsageCount: max(0, usage.unbucketedUsageCount)
        )
    }

    private static func addingClamped(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func multiplyingClamped(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : product
    }
}

/// Locale-explicit formatting for every value projected by the Statistics screen. The formatter
/// resolves the effective app language on each call so changing the in-app language takes effect
/// without relying on, or mutating, the process locale.
struct StatsLocalizedFormatter {
    static let maximumAccessibilitySummaryLength = 160

    let localization: LocalizationManager

    private var locale: Locale {
        Locale(identifier: localization.effectiveLanguageCode())
    }

    func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    func relativeDate(_ date: Date, relativeTo referenceDate: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    func duration(minutes: Double) -> String {
        let safeMinutes = minutes.isFinite ? max(0, minutes) : 0
        let seconds = safeMinutes * 60
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: seconds) ?? number(0)
    }

    func sparklineAccessibilitySummary(
        points: [Int],
        unbucketedUsageCount: Int = 0
    ) -> String {
        let base: String
        if points.isEmpty {
            base = localization.s("stats.chart.accessibility.empty")
        } else {
            var total = 0
            var peak = 0
            for point in points {
                let safePoint = max(0, point)
                peak = max(peak, safePoint)
                let (next, overflow) = total.addingReportingOverflow(safePoint)
                total = overflow ? Int.max : next
            }
            if total > 0 {
                base = localization.s(
                    "stats.chart.accessibility.summary",
                    number(points.count),
                    number(total),
                    number(peak)
                )
            } else {
                base = localization.s("stats.chart.accessibility.empty")
            }
        }

        let omitted = max(0, unbucketedUsageCount)
        guard omitted > 0 else { return bounded(base) }
        return bounded(
            base + " " + localization.s(
                "stats.chart.accessibility.partial",
                number(omitted)
            )
        )
    }

    private func bounded(_ value: String) -> String {
        guard value.count > Self.maximumAccessibilitySummaryLength else { return value }
        return String(value.prefix(Self.maximumAccessibilitySummaryLength - 1)) + "…"
    }
}

/// §2: Actionable Insights & Statistics Dashboard.
///
/// Features time-period filtering (All Time, Today, 7D, 30D),
/// visual activity sparkline/bar, actionable insight cards (unused-snippet cleanup,
/// trigger conflict resolver, most valuable snippet), and auto-refresh.
final class StatsViewController: NSViewController {
    private static let charactersPerMinute = 200.0

    private let store: SnippetStore
    private let loc: LocalizationManager
    private let formatter: StatsLocalizedFormatter

    private var selectedPeriod: StatsTimePeriod = .all
    private var refreshTimer: Timer?

    private let periodControl = NSSegmentedControl()
    private let expansionsValue = StatsViewController.makeValueLabel()
    private let charactersValue = StatsViewController.makeValueLabel()
    private let timeValue = StatsViewController.makeValueLabel()
    private let keystrokesValue = StatsViewController.makeValueLabel()

    private let chartTitleLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(10.5, .semibold),
        color: DevTypeTheme.textSecondary
    )
    private let sparklineView: StatsSparklineView
    private let insightsStack = NSStackView()
    private let topStack = NSStackView()
    private let recentStack = NSStackView()
    private let emptyLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5),
        color: DevTypeTheme.textTertiary,
        wrapping: true
    )

    init(
        store: SnippetStore = .shared,
        localization: LocalizationManager = .shared
    ) {
        self.store = store
        self.loc = localization
        self.formatter = StatsLocalizedFormatter(localization: localization)
        self.sparklineView = StatsSparklineView(localization: localization)
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
        periodControl.trackingMode = .selectOne
        periodControl.selectedSegment = 0
        updatePeriodControlLocalization()
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
        chartTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        chartTitleLabel.stringValue = loc.s("stats.chart.title")
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
        root.addSubview(chartTitleLabel)
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

            chartTitleLabel.topAnchor.constraint(equalTo: metrics.bottomAnchor, constant: 10),
            chartTitleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chartTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),

            sparklineView.topAnchor.constraint(equalTo: chartTitleLabel.bottomAnchor, constant: 4),
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
        selectedPeriod = StatsTimePeriod(rawValue: periodControl.selectedSegment) ?? .all
        updatePeriodControlAccessibilityValue()
        refresh()
    }

    @objc private func refreshTapped() {
        refresh()
    }

    // MARK: Data & Calculations

    func refresh() {
        updatePeriodControlLocalization()
        let groups = store.loadGroups()
        let snippets = groups.flatMap(\.snippets)
        let snippetIDs = Set(snippets.map(\.id))
        let now = Date()
        let usage = store.usageStatsStore.snapshot(
            period: selectedPeriod.usagePeriod,
            snippetIDs: snippetIDs,
            now: now,
            calendar: .current
        )
        let lifetimeUsage = selectedPeriod == .all ? usage : store.usageStatsStore.snapshot(
            period: .all,
            snippetIDs: snippetIDs,
            now: now,
            calendar: .current
        )
        let presentation = StatsPresentationSnapshot.make(
            snippets: snippets,
            usage: usage,
            lifetimeUsage: lifetimeUsage
        )

        expansionsValue.stringValue = formatter.number(presentation.totalUses)
        charactersValue.stringValue = formatter.number(presentation.charactersProduced)
        keystrokesValue.stringValue = formatter.number(presentation.keystrokesSaved)
        timeValue.stringValue = formatter.duration(
            minutes: Double(presentation.keystrokesSaved) / Self.charactersPerMinute
        )

        let timelineIsPartial = presentation.unbucketedUsageCount > 0
        chartTitleLabel.stringValue = loc.s(
            timelineIsPartial ? "stats.chart.title.partial" : "stats.chart.title"
        )
        sparklineView.setPoints(
            presentation.sparklineCounts,
            unbucketedUsageCount: presentation.unbucketedUsageCount
        )

        // Populate Actionable Insights
        populateInsights(
            unusedCount: presentation.unusedCount,
            mostValuable: presentation.mostValuableSnippet,
            maxSaved: presentation.mostValuableKeystrokesSaved
        )

        fill(
            topStack,
            with: presentation.top,
            showsRelativeDate: false,
            relativeTo: presentation.generatedAt
        )
        fill(
            recentStack,
            with: presentation.recent,
            showsRelativeDate: true,
            relativeTo: presentation.generatedAt
        )

        let hasData = presentation.totalUses > 0
        emptyLabel.stringValue = hasData ? "" : loc.s("stats.empty")
        emptyLabel.isHidden = hasData
    }

    private func populateInsights(unusedCount: Int, mostValuable: SnippetModel?, maxSaved: Int) {
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
            let timeSavedStr = formatter.duration(
                minutes: Double(maxSaved) / Self.charactersPerMinute
            )
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

        if unusedCount > 2 {
            let unusedCard = makeInsightCard(
                title: loc.s("stats.insight.unused.title"),
                desc: loc.s("stats.insight.unused.desc", unusedCount),
                actionTitle: loc.s("stats.insight.unused.action"),
                tint: DevTypeTheme.accent,
                action: #selector(reviewUnusedTapped)
            )
            insightsStack.addArrangedSubview(unusedCard)
            unusedCard.widthAnchor.constraint(equalTo: insightsStack.widthAnchor).isActive = true
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
        (NSApp.delegate as? AppDelegate)?.openSnippetManager(filteringBy: .unused)
    }

    private func fill(
        _ stack: NSStackView,
        with snippets: [StatsPresentationSnapshot.SnippetUsage],
        showsRelativeDate: Bool,
        relativeTo referenceDate: Date
    ) {
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        for snippet in snippets {
            stack.addArrangedSubview(makeSnippetRow(
                snippet,
                showsRelativeDate: showsRelativeDate,
                relativeTo: referenceDate
            ))
        }
    }

    private func makeSnippetRow(
        _ item: StatsPresentationSnapshot.SnippetUsage,
        showsRelativeDate: Bool,
        relativeTo referenceDate: Date
    ) -> NSView {
        let snippet = item.snippet
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let trigger = DevTypeTheme.makeLabel(
            snippet.triggerKeyword.isEmpty ? snippet.displayTitle : snippet.triggerKeyword,
            font: DevTypeTheme.mono(11, .semibold),
            color: DevTypeTheme.accentBright
        )
        trigger.translatesAutoresizingMaskIntoConstraints = false
        trigger.lineBreakMode = .byTruncatingTail

        let detail: String
        if showsRelativeDate {
            if let date = item.lastUsedAt {
                detail = formatter.relativeDate(date, relativeTo: referenceDate)
            } else {
                detail = loc.s("stats.never")
            }
        } else {
            detail = loc.p("stats.uses", count: item.usageCount, item.usageCount)
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

    private func updatePeriodControlLocalization() {
        periodControl.setLabel(loc.s("stats.period.all"), forSegment: StatsTimePeriod.all.rawValue)
        periodControl.setLabel(
            loc.s("stats.period.today"),
            forSegment: StatsTimePeriod.today.rawValue
        )
        periodControl.setLabel(
            loc.s("stats.period.sevenDays"),
            forSegment: StatsTimePeriod.sevenDays.rawValue
        )
        periodControl.setLabel(
            loc.s("stats.period.thirtyDays"),
            forSegment: StatsTimePeriod.thirtyDays.rawValue
        )
        periodControl.setAccessibilityLabel(loc.s("stats.period.accessibility.label"))
        updatePeriodControlAccessibilityValue()
    }

    private func updatePeriodControlAccessibilityValue() {
        let selectedLabel = periodControl.label(forSegment: selectedPeriod.rawValue)
        periodControl.setAccessibilityValue(selectedLabel)
    }
}

/// Custom lightweight activity sparkline visualizer.
final class StatsSparklineView: NSView {
    private var points: [Int] = []
    private var unbucketedUsageCount = 0
    private let formatter: StatsLocalizedFormatter

    init(localization: LocalizationManager = .shared) {
        self.formatter = StatsLocalizedFormatter(localization: localization)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPoints(_ points: [Int], unbucketedUsageCount: Int = 0) {
        self.points = points.map { max(0, $0) }
        self.unbucketedUsageCount = max(0, unbucketedUsageCount)
        updateAccessibility()
        needsDisplay = true
    }

    private func updateAccessibility() {
        setAccessibilityLabel(formatter.localization.s("stats.chart.accessibility.label"))
        setAccessibilityValue(formatter.sparklineAccessibilitySummary(
            points: points,
            unbucketedUsageCount: unbucketedUsageCount
        ))
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
