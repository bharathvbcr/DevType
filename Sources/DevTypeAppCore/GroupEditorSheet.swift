import AppKit
import ExpanderEngine

private final class GroupEditorKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Values produced by the group editor (create & edit share the same shape).
struct GroupDraft: Equatable {
    var name: String
    var symbol: String
    var colorHex: String
    var enabled: Bool
    /// §4.4 at group level. Applies to every snippet in the group, composed with each
    /// snippet's own scope — see `SnippetStore.expandableSnippets`.
    var scope: SnippetAppScope = .unscoped
}

/// Glass sheet for creating / editing a snippet group: name, SF-symbol icon,
/// color tag, and enable toggle. Validation errors render inline (crimson label).
enum GroupEditorSheet {
    /// Sized once here so the panel, its glass container and the size lock can never disagree.
    static let panelSize = NSSize(width: 400, height: 476)

    private static var activePanel: NSPanel?
    private static var activeController: GroupEditorController?

    static func present(
        from hostWindow: NSWindow?,
        existing: SnippetGroup?,
        loc: LocalizationManager = .shared,
        validate: @escaping (_ name: String) -> String?,
        completion: @escaping (GroupDraft?) -> Void
    ) {
        // Same single-instance contract as MacroPalettePanel.present: a second
        // presentation while one is up would overwrite the statics, and finishing
        // the first would then nil them out from under the second — leaving it
        // unclosable by any path but its own.
        if activePanel != nil { return }
        let panel = GroupEditorKeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)

        let controller = GroupEditorController(
            existing: existing,
            loc: loc,
            validate: validate,
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
        // Fixed-size sheet: a validation message or a long group name must truncate inside it,
        // never resize it. See `dtLockContentSize`.
        panel.dtLockContentSize(panelSize)

        activePanel = panel
        activeController = controller

        if let hostWindow {
            hostWindow.beginSheet(panel, completionHandler: nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.focusNameField()
    }
}

// MARK: - Icon choice button

/// One selectable SF-symbol cell in the icon picker grid.
///
/// §4: this is a one-of-many picker whose entire state was carried by a border
/// and a tint — image-only, unlabelled, and invisible to VoiceOver. It is now a
/// `.radioButton` with a spoken symbol name and a selected / not-selected value.
private final class IconChoiceButton: NSButton {
    let symbolName: String

    init(symbolName: String, target: AnyObject?, action: Selector?) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        image = DevTypeTheme.tintedSymbol(symbolName, size: 14, weight: .medium, color: DevTypeTheme.textSecondary)

        // `DevTypeAccessibility.symbolDescription` already curates / humanizes
        // every SF Symbol name the app renders — reuse it rather than inventing
        // a second table of icon names.
        let spokenName = DevTypeAccessibility.symbolDescription(symbolName)
        toolTip = spokenName
        setAccessibilityRole(NSAccessibility.Role.radioButton)
        setAccessibilityLabel(spokenName)
        setAccessibilityValue(LocalizationManager.shared.s("ax.notSelected"))

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelected(_ selected: Bool, tint: NSColor) {
        if selected {
            layer?.backgroundColor = tint.withAlphaComponent(0.22).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = tint.withAlphaComponent(0.65).cgColor
            image = DevTypeTheme.tintedSymbol(symbolName, size: 14, weight: .semibold, color: tint)
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
            layer?.borderWidth = 0
            image = DevTypeTheme.tintedSymbol(symbolName, size: 14, weight: .medium, color: DevTypeTheme.textSecondary)
        }
        // §5.2: selection is conveyed by border + tint alone on screen; the AX
        // value gives it a text equivalent.
        setAccessibilityValue(LocalizationManager.shared.s(selected ? "ax.selected" : "ax.notSelected"))
    }

}

// MARK: - Color swatch button

/// Round color swatch; empty hex = "no color" (accent default).
///
/// §4 / §5.2: a swatch whose only content is a fill colour is the textbook case
/// of "state conveyed by colour alone". Each one now carries a spoken colour
/// name and a selected / not-selected value.
private final class ColorSwatchButton: NSButton {
    let colorHex: String

    /// Localization keys for the palette in `DevTypeTheme.groupColorPalette`
    /// order. Keyed by hex so a palette reorder cannot silently mislabel them.
    private static let colorNameKeys: [String: String] = [
        "#DC2626": "ax.color.red",
        "#F97316": "ax.color.orange",
        "#FACC15": "ax.color.yellow",
        "#30D159": "ax.color.green",
        "#0A84FF": "ax.color.blue",
        "#BF5AF2": "ax.color.purple",
        "#FF375F": "ax.color.pink",
        "#8E8E93": "ax.color.gray"
    ]

    static func spokenName(forHex hex: String) -> String {
        let loc = LocalizationManager.shared
        if let key = colorNameKeys[hex.uppercased()] { return loc.s(key) }
        // Unknown / empty hex is the "no colour" swatch.
        return hex.isEmpty ? loc.s("ax.color.none") : hex
    }

    init(colorHex: String, target: AnyObject?, action: Selector?) {
        self.colorHex = colorHex
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 10
        if let color = DevTypeTheme.colorFromHex(colorHex) {
            layer?.backgroundColor = color.cgColor
        } else {
            // "No color" swatch: hollow circle with a diagonal slash.
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 1.5
            layer?.borderColor = DevTypeTheme.textTertiary.cgColor
        }

        let name = Self.spokenName(forHex: colorHex)
        toolTip = name
        setAccessibilityRole(NSAccessibility.Role.radioButton)
        setAccessibilityLabel(name)
        setAccessibilityValue(LocalizationManager.shared.s("ax.notSelected"))

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelected(_ selected: Bool) {
        if selected {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        } else if DevTypeTheme.colorFromHex(colorHex) != nil {
            layer?.borderWidth = 0
        } else {
            layer?.borderWidth = 1.5
            layer?.borderColor = DevTypeTheme.textTertiary.cgColor
        }
        setAccessibilityValue(LocalizationManager.shared.s(selected ? "ax.selected" : "ax.notSelected"))
    }
}

// MARK: - Controller

private final class GroupEditorController: NSViewController {
    private static let iconChoices: [String] = [
        "folder.fill", "tag.fill", "star.fill", "bolt.fill", "envelope.fill",
        "terminal.fill", "curlybraces", "doc.text.fill", "link", "person.fill",
        "briefcase.fill", "bookmark.fill", "heart.fill", "wrench.and.screwdriver.fill"
    ]

    private let existing: SnippetGroup?
    private let loc: LocalizationManager
    private let validate: (String) -> String?
    private let onFinish: (GroupDraft?) -> Void

    private let nameField = GlassTextField()
    private let enabledSwitch = NSSwitch()
    private let errorLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11, .medium), color: DevTypeTheme.accentBright, wrapping: true)

    private var selectedSymbol: String
    private var selectedColorHex: String
    private let symbolField = NSTextField()
    private let colorWell = NSColorWell()
    private var groupScope: SnippetAppScope = .unscoped
    private weak var scopeButton: NSButton?
    private var iconButtons: [IconChoiceButton] = []
    private var swatchButtons: [ColorSwatchButton] = []

    init(
        existing: SnippetGroup?,
        loc: LocalizationManager,
        validate: @escaping (String) -> String?,
        onFinish: @escaping (GroupDraft?) -> Void
    ) {
        self.existing = existing
        self.loc = loc
        self.validate = validate
        self.onFinish = onFinish
        self.selectedSymbol = existing?.symbol ?? Self.iconChoices[0]
        self.selectedColorHex = existing?.colorHex ?? ""
        super.init(nibName: nil, bundle: nil)
        if !Self.iconChoices.contains(selectedSymbol) {
            selectedSymbol = Self.iconChoices[0]
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let glass = GlassContainerView(
            cornerRadius: DevTypeTheme.Radius.panel,
            tint: DevTypeTheme.accent.withAlphaComponent(0.09),
            material: .popover
        )
        glass.frame = NSRect(origin: .zero, size: GroupEditorSheet.panelSize)
        let root = glass.contentView

        // Header
        let isNew = existing == nil
        let badge = IconBadgeView(
            symbol: isNew ? "folder.badge.plus" : "folder.fill",
            tint: DevTypeTheme.accent,
            size: 34,
            pointSize: 15
        )
        let headerLabel = DevTypeTheme.makeLabel(
            loc.s(isNew ? "groupeditor.add" : "groupeditor.edit"),
            font: DevTypeTheme.font(15, .bold),
            color: DevTypeTheme.textPrimary
        )
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(badge)
        root.addSubview(headerLabel)

        // Name
        let nameCaption = caption(loc.s("groupeditor.name"))
        nameField.placeholderAttributedString = NSAttributedString(
            string: SnippetDocument.defaultGroupName,
            attributes: [
                .foregroundColor: DevTypeTheme.textTertiary,
                .font: DevTypeTheme.font(13)
            ]
        )
        nameField.stringValue = existing?.name ?? ""
        // §4: the caption is a separate label, so VoiceOver cannot infer it.
        nameField.setAccessibilityLabel(loc.s("ax.groupeditor.name"))
        root.addSubview(nameCaption)
        root.addSubview(nameField)

        // Icon grid (two rows of seven)
        let iconCaption = caption(loc.s("groupeditor.icon"))
        root.addSubview(iconCaption)
        iconButtons = Self.iconChoices.map { symbol in
            IconChoiceButton(symbolName: symbol, target: self, action: #selector(iconTapped(_:)))
        }
        let iconRowOne = NSStackView(views: Array(iconButtons.prefix(7)))
        let iconRowTwo = NSStackView(views: Array(iconButtons.suffix(from: 7)))
        for row in [iconRowOne, iconRowTwo] {
            row.orientation = .horizontal
            row.spacing = 8
        }
        let iconGrid = NSStackView(views: [iconRowOne, iconRowTwo])
        iconGrid.orientation = .vertical
        iconGrid.alignment = .leading
        iconGrid.spacing = 8
        iconGrid.translatesAutoresizingMaskIntoConstraints = false
        // §4: name the radio group so its 14 members have a spoken container.
        iconGrid.setAccessibilityRole(NSAccessibility.Role.radioGroup)
        iconGrid.setAccessibilityLabel(loc.s("ax.groupeditor.icon"))
        root.addSubview(iconGrid)

        // Any SF Symbol, not just the fourteen above. `SnippetGroup.symbol` has always been a
        // free-form string — the grid was the only thing narrowing it — so this needs no model
        // change and an unrecognised name is refused rather than stored as a blank icon.
        symbolField.translatesAutoresizingMaskIntoConstraints = false
        symbolField.placeholderString = loc.s("groupeditor.symbol.placeholder")
        symbolField.font = DevTypeTheme.font(11)
        symbolField.target = self
        symbolField.action = #selector(customSymbolEntered)
        symbolField.setAccessibilityLabel(loc.s("groupeditor.symbol.placeholder"))
        symbolField.toolTip = loc.s("groupeditor.symbol.help")
        root.addSubview(symbolField)

        // Color swatches ("none" + palette)
        let colorCaption = caption(loc.s("groupeditor.color"))
        root.addSubview(colorCaption)
        swatchButtons = ([""] + DevTypeTheme.groupColorPalette).map { hex in
            ColorSwatchButton(colorHex: hex, target: self, action: #selector(colorTapped(_:)))
        }
        // Same story for the colour: `colorHex` stores any "#RRGGBB", the palette was the only
        // thing limiting it to eight.
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.target = self
        colorWell.action = #selector(customColorPicked)
        colorWell.setAccessibilityLabel(loc.s("groupeditor.color.custom"))
        colorWell.toolTip = loc.s("groupeditor.color.custom")
        colorWell.widthAnchor.constraint(equalToConstant: 28).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 20).isActive = true
        if let current = DevTypeTheme.colorFromHex(existing?.colorHex ?? "") {
            colorWell.color = current
        }

        let swatchRow = NSStackView(views: swatchButtons + [colorWell])
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 10
        swatchRow.translatesAutoresizingMaskIntoConstraints = false
        swatchRow.setAccessibilityRole(NSAccessibility.Role.radioGroup)
        swatchRow.setAccessibilityLabel(loc.s("ax.groupeditor.color"))
        root.addSubview(swatchRow)

        // Enabled toggle
        enabledSwitch.state = (existing?.enabled ?? true) ? .on : .off
        enabledSwitch.controlSize = .small
        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false
        // §4: NSSwitch has no title of its own; the adjacent label is a separate view.
        enabledSwitch.setAccessibilityLabel(loc.s("ax.groupeditor.enabled"))
        let enabledLabel = DevTypeTheme.makeLabel(
            loc.s("groupeditor.enabled"),
            font: DevTypeTheme.font(11.5, .medium),
            color: DevTypeTheme.textPrimary
        )
        enabledLabel.translatesAutoresizingMaskIntoConstraints = false
        groupScope = SnippetAppScope(
            includeApps: existing?.includeApps ?? [],
            excludeApps: existing?.excludeApps ?? []
        )
        let scope = NSButton(
            title: SnippetAppScopeSummary.chipTitle(
                include: groupScope.includeApps, exclude: groupScope.excludeApps, loc: loc
            ),
            target: self,
            action: #selector(editScope)
        )
        scope.bezelStyle = .rounded
        scope.controlSize = .small
        scope.translatesAutoresizingMaskIntoConstraints = false
        scope.toolTip = loc.s("groupeditor.scope.help")
        scope.setAccessibilityLabel(loc.s("groupeditor.scope.label"))
        scopeButton = scope

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let toggleRow = NSStackView(views: [enabledSwitch, enabledLabel, spacer, scope])
        toggleRow.orientation = .horizontal
        toggleRow.alignment = .centerY
        toggleRow.spacing = 7
        toggleRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toggleRow)

        // Inline error
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byWordWrapping
        // A wrapping label measures itself single-line until told its width; the slot is the
        // name field's width. Without this a long conflict message widened the panel.
        errorLabel.preferredMaxLayoutWidth = GroupEditorSheet.panelSize.width - 40
        errorLabel.setAccessibilityRole(NSAccessibility.Role.staticText)
        root.addSubview(errorLabel)

        // Buttons
        let hairline = DevTypeTheme.makeHairline()
        root.addSubview(hairline)

        let cancelButton = CapsuleButton(
            title: loc.s("common.cancel"),
            style: .secondary,
            target: self,
            action: #selector(cancelTapped)
        )
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = CapsuleButton(
            title: loc.s("groupeditor.save"),
            symbol: "checkmark",
            style: .primary,
            target: self,
            action: #selector(saveTapped)
        )
        saveButton.keyEquivalent = "\r"
        root.addSubview(cancelButton)
        root.addSubview(saveButton)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            headerLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            headerLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            nameCaption.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 14),
            nameCaption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            nameField.topAnchor.constraint(equalTo: nameCaption.bottomAnchor, constant: 4),
            nameField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            nameField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            iconCaption.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            iconCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            iconGrid.topAnchor.constraint(equalTo: iconCaption.bottomAnchor, constant: 6),
            iconGrid.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),

            symbolField.topAnchor.constraint(equalTo: iconGrid.bottomAnchor, constant: 8),
            symbolField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            symbolField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            symbolField.heightAnchor.constraint(equalToConstant: 20),

            colorCaption.topAnchor.constraint(equalTo: symbolField.bottomAnchor, constant: 12),
            colorCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            swatchRow.topAnchor.constraint(equalTo: colorCaption.bottomAnchor, constant: 8),
            swatchRow.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),

            toggleRow.topAnchor.constraint(equalTo: swatchRow.bottomAnchor, constant: 14),
            toggleRow.leadingAnchor.constraint(equalTo: nameField.leadingAnchor, constant: 2),

            errorLabel.topAnchor.constraint(equalTo: toggleRow.bottomAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),

            hairline.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hairline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hairline.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        refreshPickers()
        view = glass
    }

    private func caption(_ text: String) -> NSTextField { DevTypeTheme.makeFieldCaption(text) }

    private func refreshPickers() {
        let tint = DevTypeTheme.tint(forGroupColorHex: selectedColorHex)
        for button in iconButtons {
            button.setSelected(button.symbolName == selectedSymbol, tint: tint)
        }
        for swatch in swatchButtons {
            swatch.setSelected(swatch.colorHex == selectedColorHex)
        }
    }

    func focusNameField() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.nameField)
        }
    }

    @objc private func iconTapped(_ sender: IconChoiceButton) {
        selectedSymbol = sender.symbolName
        refreshPickers()
    }

    @objc private func colorTapped(_ sender: ColorSwatchButton) {
        selectedColorHex = sender.colorHex
        refreshPickers()
    }

    /// Reuses the snippet scope editor: the two lists mean the same thing at both levels, and
    /// a second picker would be a second place for the rule to drift.
    @objc private func editScope() {
        SnippetAppScopeSheet.present(
            from: view.window,
            scope: groupScope,
            loc: loc
        ) { [weak self] result in
            guard let self, let result else { return }
            self.groupScope = result
            self.scopeButton?.title = SnippetAppScopeSummary.chipTitle(
                include: result.includeApps, exclude: result.excludeApps, loc: self.loc
            )
        }
    }

    /// Return in the symbol field. Refused unless macOS can actually render the name — a
    /// mistyped symbol would otherwise be stored and draw as nothing in the sidebar, with no
    /// way to tell that from an icon that simply has not loaded.
    @objc private func customSymbolEntered() {
        let name = symbolField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
            showError(loc.s("groupeditor.error.unknownSymbol", name))
            return
        }
        selectedSymbol = name
        symbolField.stringValue = ""
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
        // Deselects every grid button on its own when the symbol is not one of them.
        refreshPickers()
    }

    @objc private func customColorPicked() {
        selectedColorHex = DevTypeTheme.hexFromColor(colorWell.color)
        refreshPickers()
    }

    @objc private func cancelTapped() { onFinish(nil) }

    @objc private func saveTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showError(loc.s("groupeditor.error.emptyName"))
            return
        }
        if let conflict = validate(name) {
            showError(conflict)
            return
        }
        onFinish(GroupDraft(
            name: name,
            symbol: selectedSymbol,
            colorHex: selectedColorHex,
            enabled: enabledSwitch.state == .on,
            scope: groupScope
        ))
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        // §4: a visually-only error is invisible to VoiceOver.
        errorLabel.setAccessibilityValue(message)
        view.layoutSubtreeIfNeeded()
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -6, 5, -3, 2, 0]
        animation.duration = 0.32
        nameField.wantsLayer = true
        nameField.layer?.add(animation, forKey: "devtype.shake")
    }
}
