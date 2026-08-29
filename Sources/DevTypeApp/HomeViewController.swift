import AppKit
import ExpanderEngine

/// §1: First-class Home / Getting Started surface.
///
/// Gives users an immediate landing dashboard after onboarding:
/// engine status & quick controls, new snippet / template affordances,
/// active hotkeys summary, recent & top-used snippets, live test field,
/// and health warnings.
final class HomeViewController: NSViewController {
    private let loc = LocalizationManager.shared
    private let store: SnippetStore
    private weak var hotkeyManager: HotkeyManager?

    // UI Elements
    private let statusPill = PillBadgeView(text: "", tint: DevTypeTheme.statusGreen, showsDot: true)
    private let statusActionBtn = CapsuleButton(title: "", style: .secondary)
    private let scratchField = NSTextField()
    private let topStack = NSStackView()
    private let recentStack = NSStackView()
    private let warningBanner = NSView()
    private let warningLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11.5), color: DevTypeTheme.statusOrange, wrapping: true)

    private var statusObserver: NSObjectProtocol?

    init(store: SnippetStore = .shared, hotkeyManager: HotkeyManager? = nil) {
        self.store = store
        self.hotkeyManager = hotkeyManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    func refreshHotkeyManager(_ manager: HotkeyManager?) {
        self.hotkeyManager = manager
        refresh()
    }

    override func loadView() {
        let scroll = NSScrollView()
        // Preferences embeds this scroll view in a constraint-managed pane host. Keep the
        // outer view in that same layout system instead of generating autoresizing-mask
        // constraints that compete with the host's edge constraints.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 16
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)

        // Header Title
        let headerLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.tab.home"),
            font: DevTypeTheme.font(20, .bold),
            color: DevTypeTheme.textPrimary
        )
        let subtitleLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.tab.home.subtitle"),
            font: DevTypeTheme.font(12),
            color: DevTypeTheme.textSecondary
        )
        let headerStack = NSStackView(views: [headerLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(headerStack)

        // 1. Engine Status Card
        let statusCard = makeStatusCard()
        mainStack.addArrangedSubview(statusCard)

        // Warning banner (hidden by default)
        setupWarningBanner()
        mainStack.addArrangedSubview(warningBanner)

        // 2. Quick Actions Card
        let quickActionsCard = makeQuickActionsCard()
        mainStack.addArrangedSubview(quickActionsCard)

        // 3. Try Typing Scratchpad Card
        let scratchCard = makeScratchpadCard()
        mainStack.addArrangedSubview(scratchCard)

        // 4. Active Shortcuts Card
        let shortcutsCard = makeShortcutsCard()
        mainStack.addArrangedSubview(shortcutsCard)

        // 5. Recent & Top Snippets Dual Columns
        let snippetsDualCard = makeSnippetsDualCard()
        mainStack.addArrangedSubview(snippetsDualCard)

        // Constraints
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

            statusCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            warningBanner.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            quickActionsCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            scratchCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            shortcutsCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            snippetsDualCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        ])

        scroll.documentView = root
        view = scroll

        installObservers()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func installObservers() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .devTypePreferencesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Cards Construction

    private func makeStatusCard() -> NSView {
        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.04))
        card.translatesAutoresizingMaskIntoConstraints = false
        let content = card.contentView

        let title = DevTypeTheme.makeLabel(
            loc.s("home.status.title"),
            font: DevTypeTheme.font(13, .semibold),
            color: DevTypeTheme.textPrimary
        )

        statusActionBtn.target = self
        statusActionBtn.action = #selector(statusActionTapped)

        let topRow = NSStackView(views: [title, statusPill])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let actionRow = NSStackView(views: [topRow, spacer, statusActionBtn])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(actionRow)
        NSLayoutConstraint.activate([
            actionRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            actionRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            actionRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            actionRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])

        return card
    }

    private func setupWarningBanner() {
        warningBanner.wantsLayer = true
        warningBanner.layer?.cornerRadius = 8
        warningBanner.layer?.backgroundColor = DevTypeTheme.statusOrange.withAlphaComponent(0.12).cgColor
        warningBanner.layer?.borderWidth = 1
        warningBanner.layer?.borderColor = DevTypeTheme.statusOrange.withAlphaComponent(0.3).cgColor
        warningBanner.translatesAutoresizingMaskIntoConstraints = false
        warningBanner.isHidden = true

        let icon = NSImageView(image: DevTypeTheme.tintedSymbol("exclamationmark.triangle.fill", size: 14, color: DevTypeTheme.statusOrange) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false

        warningLabel.translatesAutoresizingMaskIntoConstraints = false

        warningBanner.addSubview(icon)
        warningBanner.addSubview(warningLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: warningBanner.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: warningBanner.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            warningLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            warningLabel.trailingAnchor.constraint(equalTo: warningBanner.trailingAnchor, constant: -12),
            warningLabel.topAnchor.constraint(equalTo: warningBanner.topAnchor, constant: 8),
            warningLabel.bottomAnchor.constraint(equalTo: warningBanner.bottomAnchor, constant: -8)
        ])
    }

    private func makeQuickActionsCard() -> NSView {
        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.04))
        card.translatesAutoresizingMaskIntoConstraints = false
        let content = card.contentView

        let title = DevTypeTheme.makeLabel(
            loc.s("home.quickActions.title"),
            font: DevTypeTheme.font(13, .semibold),
            color: DevTypeTheme.textPrimary
        )
        title.translatesAutoresizingMaskIntoConstraints = false

        let newBtn = CapsuleButton(
            title: loc.s("home.quickActions.newSnippet"),
            symbol: "plus",
            style: .primary,
            target: self,
            action: #selector(newSnippetTapped)
        )

        let tplBtn = CapsuleButton(
            title: loc.s("home.quickActions.templates"),
            symbol: "sparkles",
            style: .secondary,
            target: self,
            action: #selector(templatesTapped)
        )

        let impBtn = CapsuleButton(
            title: loc.s("home.quickActions.import"),
            symbol: "square.and.arrow.down",
            style: .secondary,
            target: self,
            action: #selector(importTapped)
        )

        let actStack = NSStackView(views: [newBtn, tplBtn, impBtn])
        actStack.orientation = .horizontal
        actStack.spacing = 8
        actStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(actStack)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),

            actStack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            actStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            actStack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            actStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])

        return card
    }

    private func makeScratchpadCard() -> NSView {
        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.04))
        card.translatesAutoresizingMaskIntoConstraints = false
        let content = card.contentView

        let title = DevTypeTheme.makeLabel(
            loc.s("home.try.title"),
            font: DevTypeTheme.font(13, .semibold),
            color: DevTypeTheme.textPrimary
        )
        title.translatesAutoresizingMaskIntoConstraints = false

        let hint = DevTypeTheme.makeLabel(
            loc.s("home.try.hint"),
            font: DevTypeTheme.font(11),
            color: DevTypeTheme.textSecondary
        )
        hint.translatesAutoresizingMaskIntoConstraints = false

        scratchField.placeholderString = loc.s("home.try.placeholder")
        scratchField.font = DevTypeTheme.mono(13)
        scratchField.translatesAutoresizingMaskIntoConstraints = false
        scratchField.focusRingType = .exterior

        let clearBtn = CapsuleButton(
            title: loc.s("common.clear"),
            symbol: "xmark.circle",
            style: .secondary,
            target: self,
            action: #selector(clearScratchpad)
        )

        let fieldRow = NSStackView(views: [scratchField, clearBtn])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        fieldRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(hint)
        content.addSubview(fieldRow)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),

            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),

            fieldRow.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            fieldRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            fieldRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            fieldRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            clearBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 70)
        ])

        return card
    }

    private func makeShortcutsCard() -> NSView {
        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.04))
        card.translatesAutoresizingMaskIntoConstraints = false
        let content = card.contentView

        let title = DevTypeTheme.makeLabel(
            loc.s("home.hotkeys.title"),
            font: DevTypeTheme.font(13, .semibold),
            color: DevTypeTheme.textPrimary
        )
        title.translatesAutoresizingMaskIntoConstraints = false

        let searchPill = PillBadgeView(text: "⌘ /", tint: DevTypeTheme.accent)
        let searchLabel = DevTypeTheme.makeLabel(loc.s("home.hotkeys.search"), font: DevTypeTheme.font(12), color: DevTypeTheme.textSecondary)
        let searchStack = NSStackView(views: [searchPill, searchLabel])
        searchStack.orientation = .horizontal
        searchStack.spacing = 6

        let aiPill = PillBadgeView(text: "⌥ ⌘ /", tint: DevTypeTheme.accent)
        let aiLabel = DevTypeTheme.makeLabel(loc.s("home.hotkeys.ai"), font: DevTypeTheme.font(12), color: DevTypeTheme.textSecondary)
        let aiStack = NSStackView(views: [aiPill, aiLabel])
        aiStack.orientation = .horizontal
        aiStack.spacing = 6

        let voicePill = PillBadgeView(text: "⌥ Space", tint: DevTypeTheme.accent)
        let voiceLabel = DevTypeTheme.makeLabel(loc.s("home.hotkeys.dictation"), font: DevTypeTheme.font(12), color: DevTypeTheme.textSecondary)
        let voiceStack = NSStackView(views: [voicePill, voiceLabel])
        voiceStack.orientation = .horizontal
        voiceStack.spacing = 6

        let row = NSStackView(views: [searchStack, aiStack, voiceStack])
        row.orientation = .horizontal
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(row)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),

            row.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])

        return card
    }

    private func makeSnippetsDualCard() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let topCard = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.04))
        topCard.translatesAutoresizingMaskIntoConstraints = false
        let topContent = topCard.contentView

        let topTitle = DevTypeTheme.makeLabel(
            loc.s("home.top.title"),
            font: DevTypeTheme.font(13, .semibold),
            color: DevTypeTheme.textPrimary
        )
        topTitle.translatesAutoresizingMaskIntoConstraints = false
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 4
        topStack.translatesAutoresizingMaskIntoConstraints = false

        topContent.addSubview(topTitle)
        topContent.addSubview(topStack)
        NSLayoutConstraint.activate([
            topTitle.topAnchor.constraint(equalTo: topContent.topAnchor, constant: 12),
            topTitle.leadingAnchor.constraint(equalTo: topContent.leadingAnchor, constant: 14),
            topStack.topAnchor.constraint(equalTo: topTitle.bottomAnchor, constant: 8),
            topStack.leadingAnchor.constraint(equalTo: topContent.leadingAnchor, constant: 14),
            topStack.trailingAnchor.constraint(equalTo: topContent.trailingAnchor, constant: -14),
            topStack.bottomAnchor.constraint(equalTo: topContent.bottomAnchor, constant: -12)
        ])

        let recentCard = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.04))
        recentCard.translatesAutoresizingMaskIntoConstraints = false
        let recentContent = recentCard.contentView

        let recentTitle = DevTypeTheme.makeLabel(
            loc.s("home.recent.title"),
            font: DevTypeTheme.font(13, .semibold),
            color: DevTypeTheme.textPrimary
        )
        recentTitle.translatesAutoresizingMaskIntoConstraints = false
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 4
        recentStack.translatesAutoresizingMaskIntoConstraints = false

        recentContent.addSubview(recentTitle)
        recentContent.addSubview(recentStack)
        NSLayoutConstraint.activate([
            recentTitle.topAnchor.constraint(equalTo: recentContent.topAnchor, constant: 12),
            recentTitle.leadingAnchor.constraint(equalTo: recentContent.leadingAnchor, constant: 14),
            recentStack.topAnchor.constraint(equalTo: recentTitle.bottomAnchor, constant: 8),
            recentStack.leadingAnchor.constraint(equalTo: recentContent.leadingAnchor, constant: 14),
            recentStack.trailingAnchor.constraint(equalTo: recentContent.trailingAnchor, constant: -14),
            recentStack.bottomAnchor.constraint(equalTo: recentContent.bottomAnchor, constant: -12)
        ])

        let hStack = NSStackView(views: [topCard, recentCard])
        hStack.orientation = .horizontal
        hStack.distribution = .fillEqually
        hStack.spacing = 12
        hStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hStack)

        NSLayoutConstraint.activate([
            hStack.topAnchor.constraint(equalTo: root.topAnchor),
            hStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hStack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        return root
    }

    // MARK: - Actions

    @objc private func statusActionTapped() {
        let isPaused = UserDefaults.standard.bool(forKey: "devtype.expansionPaused")
        if isPaused {
            UserDefaults.standard.set(false, forKey: "devtype.expansionPaused")
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
            DevTypeAccessibility.announce(loc.s("home.status.active"))
        } else if !PermissionProbe().canListenTap() {
            (NSApp.delegate as? AppDelegate)?.openPermissionRecovery(nil)
        } else {
            UserDefaults.standard.set(true, forKey: "devtype.expansionPaused")
            NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
            DevTypeAccessibility.announce(loc.s("home.status.paused"))
        }
        refresh()
    }

    @objc private func clearScratchpad() {
        scratchField.stringValue = ""
    }

    @objc private func newSnippetTapped() {
        SnippetEditorSheet.present(
            from: view.window,
            existing: nil,
            draft: nil,
            groups: store.loadGroups(),
            currentGroupID: store.loadGroups().first?.id,
            validate: { _, _ in nil },
            completion: { [weak self] result, chosenGroupID in
                guard let self, let snippet = result else { return }
                var groups = self.store.loadGroups()
                let targetGroupID = chosenGroupID ?? groups.first?.id
                if let targetGroupID, let index = groups.firstIndex(where: { $0.id == targetGroupID }) {
                    groups[index].snippets.append(snippet)
                    _ = self.store.saveGroups(groups)
                    self.refresh()
                }
            }
        )
    }

    @objc private func templatesTapped() {
        SnippetTemplatePanel.present(from: view.window) { [weak self] template in
            guard let self else { return }
            let draft = template.makeDraft(loc: self.loc)
            SnippetEditorSheet.present(
                from: self.view.window,
                existing: nil,
                draft: draft,
                groups: self.store.loadGroups(),
                currentGroupID: self.store.loadGroups().first?.id,
                validate: { _, _ in nil },
                completion: { [weak self] result, chosenGroupID in
                    guard let self, let snippet = result else { return }
                    var groups = self.store.loadGroups()
                    let targetGroupID = chosenGroupID ?? groups.first?.id
                    if let targetGroupID, let index = groups.firstIndex(where: { $0.id == targetGroupID }) {
                        groups[index].snippets.append(snippet)
                        _ = self.store.saveGroups(groups)
                        self.refresh()
                    }
                }
            )
        }
    }

    @objc private func importTapped() {
        SnippetImportFlow.present(from: view.window, store: store) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Refresh

    func refresh() {
        let isPaused = UserDefaults.standard.bool(forKey: "devtype.expansionPaused")
        let snapshot = PermissionProbe().snapshot()

        if !snapshot.canListenTap || !snapshot.canUseAX {
            statusPill.update(text: loc.s("home.status.needsPermissions"), tint: DevTypeTheme.accent)
            statusActionBtn.title = loc.s("home.action.fixPermissions")
        } else if isPaused {
            statusPill.update(text: loc.s("home.status.paused"), tint: DevTypeTheme.statusOrange)
            statusActionBtn.title = loc.s("home.action.resume")
        } else if SecureInputMonitor.shared.checkLockStatus().isLocked {
            statusPill.update(text: loc.s("home.status.secureInput"), tint: DevTypeTheme.statusOrange)
            statusActionBtn.title = loc.s("home.action.pause")
        } else {
            statusPill.update(text: loc.s("home.status.active"), tint: DevTypeTheme.statusGreen)
            statusActionBtn.title = loc.s("home.action.pause")
        }

        // Conflicts and health
        let conflicts = store.triggerConflicts()
        if !conflicts.isEmpty {
            warningBanner.isHidden = false
            warningLabel.stringValue = loc.s("stats.insight.conflicts.desc", conflicts.count)
        } else {
            warningBanner.isHidden = true
        }

        // Snippets lists
        populateSnippetsList(topStack, snippets: store.topUsedSnippets(limit: 4))
        populateSnippetsList(recentStack, snippets: store.recentlyUsedSnippets(limit: 4))
    }

    private func populateSnippetsList(_ stack: NSStackView, snippets: [SnippetModel]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if snippets.isEmpty {
            let empty = DevTypeTheme.makeLabel(
                "—",
                font: DevTypeTheme.font(11.5),
                color: DevTypeTheme.textTertiary
            )
            stack.addArrangedSubview(empty)
            return
        }

        for snippet in snippets {
            let pill = PillBadgeView(text: snippet.triggerKeyword, tint: DevTypeTheme.accent, font: DevTypeTheme.mono(10.5, .bold))
            let title = DevTypeTheme.makeLabel(snippet.displayTitle, font: DevTypeTheme.font(11.5, .medium), color: DevTypeTheme.textPrimary)
            title.lineBreakMode = .byTruncatingTail

            let row = NSStackView(views: [pill, title])
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            stack.addArrangedSubview(row)
        }
    }
}
