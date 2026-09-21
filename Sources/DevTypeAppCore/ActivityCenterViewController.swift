import AppKit
import ExpanderEngine

/// Exact row copy shared by rendering, tooltips, and accessibility. Visual truncation may keep the
/// compact scan-friendly row, but it must never become the only path to the diagnostic detail.
struct ActivityEventRowPresentation: Equatable {
    let title: String
    let details: String
    let timestampText: String

    init(
        event: ActivityHistoryStore.ActivityEvent,
        localization: LocalizationManager = .shared
    ) {
        let localized = event.presentation(localization: localization)
        title = localized.title
        details = localized.details
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localization.effectiveLanguageCode())
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        timestampText = formatter.string(from: event.timestamp)
    }

    var accessibilityLabel: String { title }
    var accessibilityValue: String { details }
}

/// Empty and unavailable history are different states: an unreadable file must not look like the
/// user simply has no recent activity. The failure kind is intentionally not rendered because it
/// may originate in a filesystem path or implementation-specific error.
struct ActivityHistoryEmptyPresentation: Equatable {
    let title: String
    let details: String?

    init(
        persistenceHealth: ActivityHistoryStore.PersistenceHealth,
        localization loc: LocalizationManager = .shared
    ) {
        if persistenceHealth.isHealthy {
            title = loc.s("activity.empty")
            details = nil
        } else {
            title = loc.s("activity.unavailable")
            details = loc.s("activity.unavailable.hint")
        }
    }
}

/// Main-thread single-flight state for Activity's asynchronous diagnostic copy action. Keeping
/// the admission rule separate from the view makes the duplicate-click contract deterministic
/// without coupling report generation to a particular table-row lifetime.
struct ActivityDiagnosticCopyGate {
    private(set) var isInFlight = false

    mutating func begin() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    mutating func finish() {
        isInFlight = false
    }
}

/// Internal so the error-state accessibility contract can be exercised without mutating the
/// process-wide ActivityHistoryStore used by the production controller.
final class ActivityHistoryEmptyStateView: NSTableCellView {
    private let titleLabel: NSTextField
    private let detailsLabel: NSTextField
    private let stack: NSStackView

    init(presentation: ActivityHistoryEmptyPresentation) {
        let title = DevTypeTheme.makeLabel(
            presentation.title,
            font: DevTypeTheme.font(12, .semibold),
            color: presentation.details == nil
                ? DevTypeTheme.textTertiary
                : DevTypeTheme.statusOrange
        )
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel = title

        let hint = NSTextField(wrappingLabelWithString: presentation.details ?? "")
        hint.font = DevTypeTheme.font(10.5)
        hint.textColor = DevTypeTheme.textSecondary
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 420
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.isHidden = presentation.details == nil
        self.detailsLabel = hint

        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.stack = stack

        super.init(frame: .zero)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyPresentation(presentation)
    }

    func update(presentation: ActivityHistoryEmptyPresentation) {
        applyPresentation(presentation)
    }

    private func applyPresentation(_ presentation: ActivityHistoryEmptyPresentation) {
        titleLabel.stringValue = presentation.title
        titleLabel.textColor = presentation.details == nil
            ? DevTypeTheme.textTertiary
            : DevTypeTheme.statusOrange
        if let details = presentation.details {
            detailsLabel.stringValue = details
            detailsLabel.isHidden = false
        } else {
            detailsLabel.stringValue = ""
            detailsLabel.isHidden = true
        }
        setAccessibilityLabel(presentation.title)
        setAccessibilityHelp(presentation.details)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// An accessible, keyboard-responsive table view for recent activity.
///
/// Answers keyboard commands: Return/Enter activates the focused event's action,
/// Delete/Backspace dismisses the selected event from history, and Escape closes the window.
final class ActivityTableView: NSTableView {
    var onReturn: () -> Void = {}
    var onDelete: () -> Void = {}
    var onEscape: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, numpad Enter
            onReturn()
        case 51, 117: // Delete, forward delete
            onDelete()
        case 53: // Escape
            onEscape()
        default:
            super.keyDown(with: event)
        }
    }
}

/// §8: Notification & Recent Activity Center.
///
/// Surfaces non-transient event history (failed expansions, secure input changes,
/// sync issues, AI/dictation errors, hotkey conflicts) with actionable resolution paths.
final class ActivityCenterViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private static var windowController: NSWindowController?
    private var diagnosticCopyGate = ActivityDiagnosticCopyGate()

    /// Active window reference, accessible for tests and window coordination.
    static var activeWindow: NSWindow? {
        windowController?.window
    }

    public static func show() {
        if let existing = windowController?.window,
           let vc = existing.contentViewController as? ActivityCenterViewController {
            vc.attachObserversIfNeeded()
            vc.refreshLocalization()
            vc.reload()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vc = ActivityCenterViewController()
        let window = NSWindow(contentViewController: vc)
        window.title = LocalizationManager.shared.s("activity.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 540, height: 420))
        window.minSize = NSSize(width: 440, height: 320)
        DevTypeTheme.styleWindow(window, title: LocalizationManager.shared.s("activity.title"))
        window.dtRestoreFrame(named: "DevTypeActivityCenterWindow")
        window.isReleasedWhenClosed = false
        window.delegate = vc

        let wc = NSWindowController(window: window)
        windowController = wc
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let loc = LocalizationManager.shared
    private let tableView = ActivityTableView()
    private let headerLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(16, .bold),
        color: DevTypeTheme.textPrimary
    )
    private var clearButton: CapsuleButton?
    private var events: [ActivityHistoryStore.ActivityEvent] = []
    private var updateObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private lazy var emptyStateView = ActivityHistoryEmptyStateView(
        presentation: ActivityHistoryEmptyPresentation(
            persistenceHealth: ActivityHistoryStore.shared.persistenceHealth,
            localization: loc
        )
    )

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        headerLabel.stringValue = loc.s("activity.title")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let clearBtn = CapsuleButton(
            title: loc.s("activity.clear"),
            symbol: "trash",
            style: .secondary,
            target: self,
            action: #selector(clearTapped)
        )
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        clearButton = clearBtn

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("eventCol"))
        col.resizingMask = .autoresizingMask
        col.width = 480
        tableView.addTableColumn(col)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableRowDoubleClicked)
        tableView.setAccessibilityLabel(loc.s("activity.title"))

        tableView.onReturn = { [weak self] in
            self?.performSelectedAction()
        }
        tableView.onDelete = { [weak self] in
            self?.deleteSelectedRow()
        }
        tableView.onEscape = { [weak self] in
            self?.view.window?.performClose(nil)
        }

        scroll.documentView = tableView

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true

        root.addSubview(headerLabel)
        root.addSubview(clearBtn)
        root.addSubview(scroll)
        root.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearBtn.leadingAnchor, constant: -8),

            clearBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            clearBtn.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),

            emptyStateView.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 20),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -20)
        ])

        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLocalization()
        attachObserversIfNeeded()
        reload()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        detachObservers()
    }

    deinit {
        detachObservers()
    }

    func attachObserversIfNeeded() {
        if updateObserver == nil {
            updateObserver = NotificationCenter.default.addObserver(
                forName: ActivityHistoryStore.didUpdateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reload()
            }
        }
        if languageObserver == nil {
            languageObserver = NotificationCenter.default.addObserver(
                forName: .devTypeLanguageChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshLocalization()
            }
        }
    }

    func detachObservers() {
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        updateObserver = nil
        languageObserver = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        detachObservers()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        attachObserversIfNeeded()
        reload()
    }

    func refreshLocalization() {
        headerLabel.stringValue = loc.s("activity.title")
        clearButton?.title = loc.s("activity.clear")
        tableView.setAccessibilityLabel(loc.s("activity.title"))
        if let window = view.window {
            DevTypeTheme.styleWindow(window, title: loc.s("activity.title"))
        }
        reload()
    }

    func reload() {
        events = ActivityHistoryStore.shared.recentEvents()
        let health = ActivityHistoryStore.shared.persistenceHealth
        emptyStateView.update(
            presentation: ActivityHistoryEmptyPresentation(
                persistenceHealth: health,
                localization: loc
            )
        )
        emptyStateView.isHidden = !events.isEmpty
        clearButton?.isEnabled = !events.isEmpty || !health.isHealthy
        tableView.reloadData()
    }

    @objc private func clearTapped() {
        guard !events.isEmpty || !ActivityHistoryStore.shared.persistenceHealth.isHealthy else {
            return
        }

        let doClear = { [weak self] in
            guard let self else { return }
            switch ActivityHistoryStore.shared.clear() {
            case .persisted:
                self.reload()
            case .persistenceFailed:
                let hostWindow = self.view.window?.isVisible == true ? self.view.window : nil
                DevTypeAlert.warn(
                    title: self.loc.s("activity.clear.failed.title"),
                    message: self.loc.s("activity.clear.failed.message"),
                    window: hostWindow
                )
            }
        }

        if !events.isEmpty {
            let hostWindow = view.window?.isVisible == true ? view.window : nil
            DevTypeAlert.confirm(
                title: loc.s("activity.clear"),
                message: loc.s("activity.clear.confirm.message"),
                confirmTitle: loc.s("activity.clear"),
                cancelTitle: loc.s("common.cancel"),
                destructive: true,
                window: hostWindow,
                onConfirm: doClear
            )
        } else {
            doClear()
        }
    }

    @objc private func tableRowDoubleClicked() {
        performSelectedAction()
    }

    private func performSelectedAction() {
        let row = tableView.selectedRow
        guard row >= 0 && row < events.count else { return }
        let event = events[row]
        if event.action != .none {
            handleAction(event)
        }
    }

    private func deleteSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0 && row < events.count else { return }
        let event = events[row]
        _ = ActivityHistoryStore.shared.remove(id: event.id)
        reload()
        if !events.isEmpty {
            let nextRow = min(row, events.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        }
    }

    // MARK: - Table View

    func numberOfRows(in tableView: NSTableView) -> Int {
        events.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < events.count else { return nil }
        let event = events[row]
        let cell = ActivityEventRowView(event: event, localization: loc) { [weak self] selectedEvent in
            self?.handleAction(selectedEvent)
        }
        return cell
    }

    private func handleAction(_ event: ActivityHistoryStore.ActivityEvent) {
        switch event.action {
        case .none:
            break
        case .openPermissionRecovery:
            (NSApp.delegate as? AppDelegate)?.openPermissionRecovery(nil)
        case .openSnippetManager:
            (NSApp.delegate as? AppDelegate)?.openSnippetManager(nil)
        case .openPreferences:
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.openPreferences(nil, tab: .general)
            } else {
                PreferencesWindowController.shared.show(tab: .general, hotkeyManager: nil)
            }
        case .openAIPreferences:
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.openPreferences(nil, tab: .ai)
            } else {
                PreferencesWindowController.shared.show(tab: .ai, hotkeyManager: nil)
            }
        case .openVoicePreferences:
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.openPreferences(nil, tab: .voice)
            } else {
                PreferencesWindowController.shared.show(tab: .voice, hotkeyManager: nil)
            }
        case .openHotkeyPreferences:
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.openPreferences(nil, tab: .hotkeys)
            } else {
                PreferencesWindowController.shared.show(tab: .hotkeys, hotkeyManager: nil)
            }
        case .openLab:
            TestExpansionLab.run(from: view.window)
        case .copyDiagnostics:
            guard diagnosticCopyGate.begin() else {
                ToastPanel.show(loc.s("diagnostics.logs.building"), symbol: "hourglass")
                return
            }
            DiagnosticReport.buildAsync { [weak self] report in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.diagnosticCopyGate.finish()
                    if DiagnosticReport.copyToPasteboard(report) {
                        ToastPanel.show(self.loc.s("diagnostics.copied"), symbol: "doc.on.doc")
                    } else {
                        let hostWindow = self.view.window?.isVisible == true ? self.view.window : nil
                        DevTypeAlert.warn(
                            title: self.loc.s("diagnostics.copy.failed.title"),
                            message: self.loc.s("diagnostics.copy.failed.message"),
                            window: hostWindow
                        )
                    }
                }
            }
        case .reviewRecoveredVoice:
            guard let referenceID = event.referenceID else {
                _ = ActivityHistoryStore.shared.remove(id: event.id)
                reload()
                return
            }
            RecoveredDictationWindowController.show(
                referenceID: referenceID,
                activityEventID: event.id
            )
        }
    }
}

/// Internal so accessibility regressions can exercise the rendered AppKit row rather than only
/// its presentation model. The activity center remains the sole production owner.
final class ActivityEventRowView: NSTableCellView {
    private let event: ActivityHistoryStore.ActivityEvent
    private let onAction: (ActivityHistoryStore.ActivityEvent) -> Void

    init(
        event: ActivityHistoryStore.ActivityEvent,
        localization: LocalizationManager,
        onAction: @escaping (ActivityHistoryStore.ActivityEvent) -> Void
    ) {
        self.event = event
        self.onAction = onAction
        super.init(frame: .zero)

        let presentation = ActivityEventRowPresentation(
            event: event,
            localization: localization
        )

        let card = GlassCardView(tint: tint(for: event.category).withAlphaComponent(0.06))
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let content = card.contentView

        let icon = IconBadgeView(symbol: symbol(for: event.category), tint: tint(for: event.category), size: 28, pointSize: 12)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = DevTypeTheme.makeLabel(presentation.title, font: DevTypeTheme.font(12, .semibold), color: DevTypeTheme.textPrimary)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = presentation.title
        titleLabel.setAccessibilityLabel(presentation.accessibilityLabel)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detailsLabel = DevTypeTheme.makeLabel(presentation.details, font: DevTypeTheme.font(10.5), color: DevTypeTheme.textSecondary)
        detailsLabel.lineBreakMode = .byTruncatingTail
        detailsLabel.toolTip = presentation.details
        detailsLabel.setAccessibilityLabel(presentation.details)
        detailsLabel.setAccessibilityValue(presentation.accessibilityValue)
        detailsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let timeLabel = DevTypeTheme.makeLabel(
            presentation.timestampText,
            font: DevTypeTheme.mono(10),
            color: DevTypeTheme.textTertiary
        )
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, detailsLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        content.addSubview(icon)
        content.addSubview(textStack)
        content.addSubview(timeLabel)

        var trailingAnchorRef = timeLabel.leadingAnchor

        if event.action != .none {
            let actionBtn = CapsuleButton(
                title: actionTitle(for: event.action, localization: localization),
                style: .secondary,
                target: self,
                action: #selector(actionTapped)
            )
            actionBtn.controlSize = .small
            actionBtn.translatesAutoresizingMaskIntoConstraints = false
            actionBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            actionBtn.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
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

        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel("\(presentation.title), \(presentation.details), \(presentation.timestampText)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func actionTapped() {
        onAction(event)
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

    private func actionTitle(
        for action: ActivityHistoryStore.EventAction,
        localization loc: LocalizationManager
    ) -> String {
        switch action {
        case .none: return ""
        case .openPermissionRecovery: return loc.s("activity.action.permissions")
        case .openSnippetManager: return loc.s("activity.action.manager")
        case .openPreferences: return loc.s("activity.action.settings")
        case .openAIPreferences: return loc.s("activity.action.aiSettings")
        case .openVoicePreferences: return loc.s("activity.action.voiceSettings")
        case .openHotkeyPreferences: return loc.s("activity.action.hotkeySettings")
        case .openLab: return loc.s("activity.action.testLab")
        case .copyDiagnostics: return loc.s("activity.action.copyInfo")
        case .reviewRecoveredVoice: return loc.s("activity.action.review")
        }
    }
}
