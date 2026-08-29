import AppKit
import ExpanderEngine

/// §8: Notification & Recent Activity Center.
///
/// Surfaces non-transient event history (failed expansions, secure input changes,
/// sync issues, AI/dictation errors, hotkey conflicts) with actionable resolution paths.
final class ActivityCenterViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static var windowController: NSWindowController?

    public static func show() {
        if let existing = windowController?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vc = ActivityCenterViewController()
        let window = NSWindow(contentViewController: vc)
        window.title = LocalizationManager.shared.s("activity.title")
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 540, height: 420))
        window.minSize = NSSize(width: 440, height: 320)
        DevTypeTheme.styleWindow(window, title: LocalizationManager.shared.s("activity.title"))
        window.center()
        window.isReleasedWhenClosed = false

        let wc = NSWindowController(window: window)
        windowController = wc
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let loc = LocalizationManager.shared
    private let tableView = NSTableView()
    private var events: [ActivityHistoryStore.ActivityEvent] = []
    private var updateObserver: NSObjectProtocol?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        let header = DevTypeTheme.makeLabel(
            loc.s("activity.title"),
            font: DevTypeTheme.font(16, .bold),
            color: DevTypeTheme.textPrimary
        )
        header.translatesAutoresizingMaskIntoConstraints = false

        let clearBtn = CapsuleButton(
            title: loc.s("activity.clear"),
            symbol: "trash",
            style: .secondary,
            target: self,
            action: #selector(clearTapped)
        )
        clearBtn.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("eventCol")))
        scroll.documentView = tableView

        root.addSubview(header)
        root.addSubview(clearBtn)
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            clearBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            clearBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])

        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        updateObserver = NotificationCenter.default.addObserver(
            forName: ActivityHistoryStore.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
    }

    private func reload() {
        events = ActivityHistoryStore.shared.recentEvents()
        tableView.reloadData()
    }

    @objc private func clearTapped() {
        ActivityHistoryStore.shared.clear()
        reload()
    }

    // MARK: - Table View

    func numberOfRows(in tableView: NSTableView) -> Int {
        events.isEmpty ? 1 : events.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if events.isEmpty {
            let emptyView = NSTableCellView()
            let label = DevTypeTheme.makeLabel(
                loc.s("activity.empty"),
                font: DevTypeTheme.font(12),
                color: DevTypeTheme.textTertiary
            )
            label.translatesAutoresizingMaskIntoConstraints = false
            emptyView.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor)
            ])
            return emptyView
        }

        let event = events[row]
        let cell = ActivityEventRowView(event: event) { [weak self] action in
            self?.handleAction(action)
        }
        return cell
    }

    private func handleAction(_ action: ActivityHistoryStore.EventAction) {
        switch action {
        case .none:
            break
        case .openPermissionRecovery:
            (NSApp.delegate as? AppDelegate)?.openPermissionRecovery(nil)
        case .openSnippetManager:
            (NSApp.delegate as? AppDelegate)?.openSnippetManager(nil)
        case .openPreferences:
            PreferencesWindowController.shared.show(tab: .general, hotkeyManager: nil)
        case .openLab:
            TestExpansionLab.run(from: view.window)
        case .copyDiagnostics:
            DiagnosticReport.buildAsync { report in
                _ = DiagnosticReport.copyToPasteboard(report)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    ToastPanel.show(self.loc.s("diagnostics.copied"), symbol: "doc.on.doc")
                }
            }
        }
    }
}

private final class ActivityEventRowView: NSTableCellView {
    private let event: ActivityHistoryStore.ActivityEvent
    private let onAction: (ActivityHistoryStore.EventAction) -> Void

    init(event: ActivityHistoryStore.ActivityEvent, onAction: @escaping (ActivityHistoryStore.EventAction) -> Void) {
        self.event = event
        self.onAction = onAction
        super.init(frame: .zero)

        let card = GlassCardView(tint: tint(for: event.category).withAlphaComponent(0.06))
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let content = card.contentView

        let icon = IconBadgeView(symbol: symbol(for: event.category), tint: tint(for: event.category), size: 28, pointSize: 12)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = DevTypeTheme.makeLabel(event.title, font: DevTypeTheme.font(12, .semibold), color: DevTypeTheme.textPrimary)
        titleLabel.lineBreakMode = .byTruncatingTail
        let detailsLabel = DevTypeTheme.makeLabel(event.details, font: DevTypeTheme.font(10.5), color: DevTypeTheme.textSecondary)
        detailsLabel.lineBreakMode = .byTruncatingTail

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let timeLabel = DevTypeTheme.makeLabel(formatter.string(from: event.timestamp), font: DevTypeTheme.mono(10), color: DevTypeTheme.textTertiary)

        let textStack = NSStackView(views: [titleLabel, detailsLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(icon)
        content.addSubview(textStack)
        content.addSubview(timeLabel)

        var trailingAnchorRef = timeLabel.leadingAnchor

        if event.action != .none {
            let actionBtn = CapsuleButton(title: actionTitle(for: event.action), style: .secondary, target: self, action: #selector(actionTapped))
            actionBtn.controlSize = .small
            actionBtn.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(actionBtn)

            NSLayoutConstraint.activate([
                actionBtn.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -8),
                actionBtn.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
            trailingAnchorRef = actionBtn.leadingAnchor
        }

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchorRef, constant: -8),

            timeLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func actionTapped() {
        onAction(event.action)
    }

    private func symbol(for category: ActivityHistoryStore.EventCategory) -> String {
        switch category {
        case .expansion: return "bolt.fill"
        case .secureInput: return "lock.shield.fill"
        case .library: return "square.stack.3d.up.fill"
        case .importExport: return "square.and.arrow.down.fill"
        case .ai: return "sparkles"
        case .voice: return "mic.fill"
        case .hotkey: return "keyboard"
        case .general: return "bell.fill"
        }
    }

    private func tint(for category: ActivityHistoryStore.EventCategory) -> NSColor {
        switch category {
        case .expansion, .library, .importExport: return DevTypeTheme.accent
        case .secureInput: return DevTypeTheme.statusOrange
        case .ai, .voice: return DevTypeTheme.statusBlue
        case .hotkey: return DevTypeTheme.statusPurple
        case .general: return DevTypeTheme.textSecondary
        }
    }

    private func actionTitle(for action: ActivityHistoryStore.EventAction) -> String {
        switch action {
        case .none: return ""
        case .openPermissionRecovery: return "Permissions"
        case .openSnippetManager: return "Manager"
        case .openPreferences: return "Settings"
        case .openLab: return "Test Lab"
        case .copyDiagnostics: return "Copy Info"
        }
    }
}
