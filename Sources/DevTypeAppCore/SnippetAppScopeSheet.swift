import AppKit
import ExpanderEngine

private final class AppScopeKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The two app lists on a snippet, as the editor hands them around.
struct SnippetAppScope: Equatable {
    var includeApps: [String]
    var excludeApps: [String]

    static let unscoped = SnippetAppScope(includeApps: [], excludeApps: [])

    var isScoped: Bool { !includeApps.isEmpty || !excludeApps.isEmpty }
}

/// Editor for `SnippetModel.includeApps` / `excludeApps`.
///
/// The matcher has honoured these lists on every keystroke since §4.4
/// (`AbbreviationMatcher` calls `appliesTo(bundleID:)` at four sites), the exporter writes them
/// as `apps:` / `exclude_apps:`, and `EspansoImporter` reads them back. The one thing missing
/// was any way to create one without hand-editing the library JSON.
///
/// **Both lists are always preserved.** An imported snippet can carry both, and the model gives
/// `excludeApps` precedence rather than treating them as exclusive modes. A UI that presented
/// them as a single either/or choice would silently drop one on save, so the picker switches
/// which list you are *looking at* and never discards the other.
enum SnippetAppScopeSheet {
    private static var activePanel: NSPanel?
    private static var activeController: AppScopeController?

    static func present(
        from hostWindow: NSWindow?,
        scope: SnippetAppScope,
        loc: LocalizationManager = .shared,
        completion: @escaping (SnippetAppScope?) -> Void
    ) {
        // Same single-instance contract as `GroupEditorSheet.present`.
        if activePanel != nil { return }
        let panel = AppScopeKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)

        let controller = AppScopeController(
            scope: scope,
            loc: loc,
            onFinish: { result in
                if let host = hostWindow, panel.isSheet {
                    host.endSheet(panel)
                }
                panel.close()
                activePanel = nil
                activeController = nil
                completion(result)
            }
        )
        panel.contentView = controller.view

        activePanel = panel
        activeController = controller

        if let hostWindow {
            hostWindow.beginSheet(panel, completionHandler: nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Controller

private final class AppScopeController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// Which of the two lists is on screen. Both are kept in memory either way.
    private enum Mode: Int {
        case only
        case never
    }

    private var includeApps: [String]
    private var excludeApps: [String]
    private let loc: LocalizationManager
    private let onFinish: (SnippetAppScope?) -> Void

    private var mode: Mode = .only
    private let modeControl = NSSegmentedControl()
    private let tableView = NSTableView()
    private let bundleField = GlassTextField()
    private let summaryLabel = DevTypeTheme.makeLabel(
        "", font: DevTypeTheme.font(10.5), color: DevTypeTheme.textTertiary, wrapping: true
    )
    private var removeButton: NSButton?

    init(
        scope: SnippetAppScope,
        loc: LocalizationManager,
        onFinish: @escaping (SnippetAppScope?) -> Void
    ) {
        self.includeApps = scope.includeApps
        self.excludeApps = scope.excludeApps
        self.loc = loc
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        // Open on whichever list already has entries, so an imported exclude-only snippet does
        // not look unscoped.
        if scope.includeApps.isEmpty && !scope.excludeApps.isEmpty { mode = .never }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var currentList: [String] {
        get { mode == .only ? includeApps : excludeApps }
        set {
            if mode == .only { includeApps = newValue } else { excludeApps = newValue }
        }
    }

    override func loadView() {
        let glass = GlassContainerView(
            cornerRadius: DevTypeTheme.Radius.panel,
            tint: DevTypeTheme.accent.withAlphaComponent(0.09),
            material: .popover
        )
        glass.frame = NSRect(x: 0, y: 0, width: 420, height: 380)
        let root = glass.contentView

        let badge = IconBadgeView(symbol: "macwindow.on.rectangle", tint: DevTypeTheme.accent, size: 34)
        badge.translatesAutoresizingMaskIntoConstraints = false
        let title = DevTypeTheme.makeLabel(
            loc.s("appscope.title"), font: DevTypeTheme.font(15, .semibold), color: DevTypeTheme.textPrimary
        )
        title.translatesAutoresizingMaskIntoConstraints = false

        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.segmentCount = 2
        modeControl.setLabel(loc.s("appscope.mode.only"), forSegment: 0)
        modeControl.setLabel(loc.s("appscope.mode.never"), forSegment: 1)
        modeControl.segmentStyle = .rounded
        modeControl.trackingMode = .selectOne
        modeControl.selectedSegment = mode.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel(loc.s("appscope.mode.label"))

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.setAccessibilityLabel(loc.s("appscope.list.label"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundleID"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        scroll.documentView = tableView

        bundleField.translatesAutoresizingMaskIntoConstraints = false
        bundleField.placeholderString = loc.s("appscope.bundleID.placeholder")
        bundleField.font = DevTypeTheme.font(12)
        bundleField.target = self
        bundleField.action = #selector(addTyped)
        bundleField.setAccessibilityLabel(loc.s("appscope.bundleID.placeholder"))

        let chooseButton = NSButton(
            title: loc.s("appscope.chooseApp"), target: self, action: #selector(chooseApp)
        )
        chooseButton.translatesAutoresizingMaskIntoConstraints = false
        chooseButton.bezelStyle = .rounded

        let remove = NSButton(title: loc.s("appscope.remove"), target: self, action: #selector(removeSelected))
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.bezelStyle = .rounded
        remove.isEnabled = false
        removeButton = remove

        let cancel = NSButton(title: loc.s("common.cancel"), target: self, action: #selector(cancelTapped))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let done = CapsuleButton(title: loc.s("common.done"), target: self, action: #selector(doneTapped))
        done.translatesAutoresizingMaskIntoConstraints = false
        done.keyEquivalent = "\r"

        for view in [badge, title, modeControl, summaryLabel, scroll, bundleField, chooseButton, remove, cancel, done] {
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),

            modeControl.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 14),
            modeControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            modeControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            summaryLabel.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: modeControl.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: modeControl.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: modeControl.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: modeControl.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 150),

            bundleField.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bundleField.leadingAnchor.constraint(equalTo: modeControl.leadingAnchor),
            bundleField.heightAnchor.constraint(equalToConstant: 24),

            chooseButton.centerYAnchor.constraint(equalTo: bundleField.centerYAnchor),
            chooseButton.leadingAnchor.constraint(equalTo: bundleField.trailingAnchor, constant: 8),
            chooseButton.trailingAnchor.constraint(equalTo: modeControl.trailingAnchor),
            chooseButton.widthAnchor.constraint(equalToConstant: 110),

            remove.topAnchor.constraint(equalTo: bundleField.bottomAnchor, constant: 10),
            remove.leadingAnchor.constraint(equalTo: modeControl.leadingAnchor),

            done.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            cancel.centerYAnchor.constraint(equalTo: done.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
        ])

        view = glass
        refresh()
    }

    // MARK: - Actions

    @objc private func modeChanged() {
        mode = Mode(rawValue: modeControl.selectedSegment) ?? .only
        refresh()
    }

    @objc private func addTyped() {
        add(bundleField.stringValue)
        bundleField.stringValue = ""
    }

    /// Picking the app is friendlier than asking for a reverse-DNS string, and reading the
    /// identifier out of the bundle is what makes it exact — a typo here does not error, it
    /// silently scopes the snippet to an app that does not exist.
    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = loc.s("appscope.chooseApp")
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                if let id = Bundle(url: url)?.bundleIdentifier { self.add(id) }
            }
        }
    }

    private func add(_ raw: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        // Case-insensitive, matching `SnippetModel.appliesTo`, so the list cannot hold two
        // spellings of one app that the matcher would treat as the same.
        guard !currentList.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else {
            NSSound.beep()
            return
        }
        currentList.append(id)
        refresh()
    }

    @objc private func removeSelected() {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { return }
        currentList = currentList.enumerated()
            .filter { !rows.contains($0.offset) }
            .map(\.element)
        refresh()
    }

    @objc private func cancelTapped() { onFinish(nil) }

    @objc private func doneTapped() {
        onFinish(SnippetAppScope(includeApps: includeApps, excludeApps: excludeApps))
    }

    // MARK: - Rendering

    private func refresh() {
        tableView.reloadData()
        removeButton?.isEnabled = !tableView.selectedRowIndexes.isEmpty
        summaryLabel.stringValue = SnippetAppScopeSummary.explanation(
            include: includeApps, exclude: excludeApps, loc: loc
        )
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { currentList.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < currentList.count else { return nil }
        let label = DevTypeTheme.makeLabel(
            currentList[row], font: DevTypeTheme.font(12), color: DevTypeTheme.textPrimary
        )
        label.setAccessibilityLabel(currentList[row])
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton?.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }
}

// MARK: - Summary

/// How a scope reads in one line. Pure, so the wording is testable without any UI.
enum SnippetAppScopeSummary {

    /// Chip title: short enough for the option row.
    static func chipTitle(include: [String], exclude: [String], loc: LocalizationManager) -> String {
        if include.isEmpty && exclude.isEmpty { return loc.s("appscope.chip.all") }
        if !include.isEmpty {
            return loc.p("appscope.chip.only", count: include.count, include.count)
        }
        return loc.p("appscope.chip.except", count: exclude.count, exclude.count)
    }

    /// The sentence in the sheet, which has to say what actually happens when both lists are
    /// populated — `SnippetModel.appliesTo` gives `excludeApps` precedence.
    static func explanation(include: [String], exclude: [String], loc: LocalizationManager) -> String {
        switch (include.isEmpty, exclude.isEmpty) {
        case (true, true):
            return loc.s("appscope.explain.all")
        case (false, true):
            return loc.s("appscope.explain.only")
        case (true, false):
            return loc.s("appscope.explain.except")
        case (false, false):
            return loc.s("appscope.explain.both")
        }
    }
}
