import AppKit
import ExpanderEngine

private final class PanelCloseWatcher: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Floating glass panel that collects fill-in values before an expansion completes.
enum FillInPanel {
    private static var closeWatcher: PanelCloseWatcher?
    /// Single-instance state. Two stacked forms would each hold a matching
    /// suspension and silently disable expansion app-wide until both were dealt
    /// with — and pixel-identical centered forms make the stack invisible.
    private static var activePanel: NSPanel?
    private static var activeFinish: (([Int: String]?) -> Void)?
    private static let dismissWatchers = PanelDismissWatchers()

    @discardableResult
    static func present(
        title: String,
        fields: [FillField],
        loc: LocalizationManager = .shared,
        completion: @escaping ([Int: String]?) -> Void
    ) -> NSPanel {
        // A second fill-in request cancels the pending form instead of stacking:
        // finishing with nil releases its suspension and re-injects the old trigger.
        activeFinish?(nil)

        let suspension = EventTapEngine.shared.suspendMatching(reason: "FillInPanel")

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)
        panel.becomesKeyOnlyIfNeeded = false

        var finished = false
        let finish: ([Int: String]?) -> Void = { values in
            guard !finished else { return }
            finished = true
            // Clear the retained watcher slot first: `panel.close()` below fires
            // `windowWillClose` synchronously, re-entering through the watcher, and
            // leaving the slot set would pin the last form's whole view hierarchy
            // until the next presentation. Every close path funnels through here —
            // submit, cancel, outside-dismissal, replacement, and the watcher itself.
            closeWatcher = nil
            suspension.release()
            removeDismissWatchers()
            panel.close()
            completion(values)
        }

        let watcher = PanelCloseWatcher { finish(nil) }
        closeWatcher = watcher
        panel.delegate = watcher

        let controller = FillInFormController(
            title: title.isEmpty ? loc.s("fillin.title") : title,
            fields: fields,
            loc: loc,
            onSubmit: { finish($0) },
            onCancel: { finish(nil) }
        )
        panel.contentView = controller.view
        panel.setContentSize(controller.preferredSize)
        panel.center()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        controller.focusFirstField()

        activePanel = panel
        activeFinish = finish
        installDismissWatchers(for: panel)
        return panel
    }

    // MARK: - Dismissal on outside interaction

    /// An abandoned form keeps matching suspended invisibly everywhere — the menu
    /// bar still shows Active and nothing on screen says why. Like the palettes,
    /// any outside interaction finishes the form as a cancellation.
    private static func installDismissWatchers(for panel: NSPanel) {
        dismissWatchers.install(
            for: panel,
            isStillCurrent: { activePanel === panel },
            dismiss: dismissFromOutsideInteraction
        )
    }

    private static func removeDismissWatchers() {
        dismissWatchers.removeAll()
    }

    private static func dismissFromOutsideInteraction() {
        guard activePanel != nil else { return }
        let finish = activeFinish
        activePanel = nil
        activeFinish = nil
        finish?(nil)
    }
}

// MARK: - Form controller

private final class FillInFormController: NSViewController {
    private let formTitle: String
    private let fields: [FillField]
    private let loc: LocalizationManager
    private let onSubmit: ([Int: String]) -> Void
    private let onCancel: () -> Void
    private var values: [Int: String] = [:]
    private var textFields: [Int: NSTextField] = [:]
    private var textViews: [Int: NSTextView] = [:]
    private var popups: [Int: NSPopUpButton] = [:]
    private var toggles: [Int: NSSwitch] = [:]

    var preferredSize: NSSize {
        let fieldHeight = fields.reduce(0) { total, field in
            total + (field.kind == .area ? 112 : 54)
        }
        let spacing = max(0, fields.count - 1) * 12
        return NSSize(width: 460, height: min(540, max(240, 150 + fieldHeight + spacing)))
    }

    init(
        title: String,
        fields: [FillField],
        loc: LocalizationManager,
        onSubmit: @escaping ([Int: String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.formTitle = title
        self.fields = fields
        self.loc = loc
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let glass = GlassContainerView(
            cornerRadius: DevTypeTheme.Radius.panel,
            tint: DevTypeTheme.accent.withAlphaComponent(0.09),
            material: .popover
        )
        glass.frame = NSRect(x: 0, y: 0, width: 460, height: preferredSize.height)
        let root = glass.contentView

        // Header
        let badge = IconBadgeView(symbol: "text.insert", tint: DevTypeTheme.accent, size: 32, pointSize: 14)
        let titleLabel = DevTypeTheme.makeLabel(formTitle, font: DevTypeTheme.font(14, .bold), color: DevTypeTheme.textPrimary)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        let subtitleLabel = DevTypeTheme.makeLabel(
            loc.s("fillin.subtitle"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary
        )
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerText = NSStackView(views: [titleLabel, subtitleLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 1
        headerText.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(badge)
        root.addSubview(headerText)

        // Field stack. Valid snippets can contain many fill-ins and multiline rows are taller
        // than single-line rows, so the form body scrolls independently while its title and
        // Insert/Cancel actions remain reachable.
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        for field in fields {
            values[field.id] = field.defaultValue
            stack.addArrangedSubview(makeFieldView(field))
        }
        // §4: name the form container; each control inside is labelled below.
        stack.setAccessibilityRole(NSAccessibility.Role.group)
        stack.setAccessibilityLabel(loc.s("ax.fillin.form"))

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let formScroll = NSScrollView()
        formScroll.translatesAutoresizingMaskIntoConstraints = false
        formScroll.hasVerticalScroller = true
        formScroll.autohidesScrollers = true
        formScroll.hasHorizontalScroller = false
        formScroll.borderType = .noBorder
        formScroll.drawsBackground = false
        formScroll.documentView = document
        root.addSubview(formScroll)

        // Buttons
        let hairline = DevTypeTheme.makeHairline()
        root.addSubview(hairline)

        let cancel = CapsuleButton(
            title: loc.s("common.cancel"),
            style: .secondary,
            target: self,
            action: #selector(cancelTapped)
        )
        cancel.keyEquivalent = "\u{1b}"
        let insert = CapsuleButton(
            title: loc.s("fillin.insert"),
            symbol: "checkmark",
            style: .primary,
            target: self,
            action: #selector(submitTapped)
        )
        insert.keyEquivalent = "\r"
        root.addSubview(cancel)
        root.addSubview(insert)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            headerText.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            headerText.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            headerText.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),

            formScroll.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 16),
            formScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            formScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            formScroll.bottomAnchor.constraint(equalTo: hairline.topAnchor, constant: -12),

            document.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            hairline.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hairline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hairline.bottomAnchor.constraint(equalTo: cancel.topAnchor, constant: -12),

            cancel.trailingAnchor.constraint(equalTo: insert.leadingAnchor, constant: -10),
            cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            insert.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            insert.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        view = glass
    }

    func focusFirstField() {
        for field in fields {
            switch field.kind {
            case .text:
                if let field = textFields[field.id] {
                    view.window?.makeFirstResponder(field)
                    return
                }
            case .area:
                if let view = textViews[field.id] {
                    self.view.window?.makeFirstResponder(view)
                    return
                }
            default:
                continue
            }
        }
    }

    @objc private func submitTapped() { onSubmit(collectValues()) }
    @objc private func cancelTapped() { onCancel() }

    private func collectValues() -> [Int: String] {
        var out = values
        for (id, field) in textFields { out[id] = field.stringValue }
        for (id, view) in textViews { out[id] = view.string }
        for (id, popup) in popups { out[id] = popup.titleOfSelectedItem ?? "" }
        for (id, toggle) in toggles { out[id] = toggle.state == .on ? "yes" : "no" }
        return out
    }

    private func makeFieldView(_ field: FillField) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 5
        container.alignment = .leading

        let caption = DevTypeTheme.makeLabel(
            field.name,
            font: DevTypeTheme.font(11, .semibold),
            color: DevTypeTheme.textSecondary
        )
        // §4: the caption is a sibling view of the control, so it is decoration
        // for AX purposes — every control below carries `field.name` itself.
        caption.setAccessibilityElement(false)
        container.addArrangedSubview(caption)

        switch field.kind {
        case .text:
            let input = GlassTextField()
            input.stringValue = field.defaultValue
            input.widthAnchor.constraint(equalToConstant: 400).isActive = true
            input.setAccessibilityLabel(field.name)
            textFields[field.id] = input
            container.addArrangedSubview(input)
        case .area:
            let editorContainer = NSView()
            editorContainer.wantsLayer = true
            editorContainer.translatesAutoresizingMaskIntoConstraints = false
            editorContainer.layer?.cornerRadius = 10
            editorContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
            editorContainer.layer?.borderWidth = 1
            editorContainer.layer?.borderColor = DevTypeTheme.hairline.cgColor

            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = false

            let text = NSTextView()
            text.string = field.defaultValue
            text.isRichText = false
            text.font = DevTypeTheme.font(12.5)
            text.textColor = DevTypeTheme.textPrimary
            text.backgroundColor = .clear
            text.insertionPointColor = DevTypeTheme.accentBright
            text.textContainerInset = NSSize(width: 6, height: 5)
            // §4: an unlabelled NSTextView announces only "text entry area".
            text.setAccessibilityLabel(field.name)
            scroll.documentView = text
            textViews[field.id] = text

            editorContainer.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: editorContainer.topAnchor, constant: 3),
                scroll.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor, constant: 3),
                scroll.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor, constant: -3),
                scroll.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor, constant: -3),
                editorContainer.widthAnchor.constraint(equalToConstant: 400),
                // The 3 pt chrome inset on each edge leaves an 82 pt text viewport. Keep the
                // editable region comfortably above the 80 pt usability floor rather than
                // measuring only the decorative container.
                editorContainer.heightAnchor.constraint(equalToConstant: 88)
            ])
            container.addArrangedSubview(editorContainer)
        case .popup(let options):
            let popup = NSPopUpButton()
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.addItems(withTitles: options)
            if !field.defaultValue.isEmpty, let idx = options.firstIndex(of: field.defaultValue) {
                popup.selectItem(at: idx)
            }
            popup.setAccessibilityLabel(field.name)
            popups[field.id] = popup
            container.addArrangedSubview(popup)
        case .part:
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            let toggle = NSSwitch()
            toggle.translatesAutoresizingMaskIntoConstraints = false
            toggle.controlSize = .small
            toggle.state = (field.defaultValue.lowercased() != "no") ? .on : .off
            let label = DevTypeTheme.makeLabel(
                loc.s("fillin.include", field.name),
                font: DevTypeTheme.font(12, .medium),
                color: DevTypeTheme.textPrimary
            )
            // §4: NSSwitch carries no title of its own; the label beside it is a
            // separate view that AppKit will not associate automatically.
            toggle.setAccessibilityLabel(loc.s("fillin.include", field.name))
            label.setAccessibilityElement(false)
            row.addArrangedSubview(toggle)
            row.addArrangedSubview(label)
            toggles[field.id] = toggle
            container.addArrangedSubview(row)
        }
        return container
    }
}
