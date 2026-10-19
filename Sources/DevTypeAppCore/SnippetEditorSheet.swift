import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

/// Glass sheet for creating / editing a snippet — replaces the old NSAlert accessory form.
///
/// Redesigned around a live "Expansion Stage": a hero strip that simulates the
/// expansion as you type — trigger key-chip with a blinking caret, crimson arrow,
/// and the macro-resolved output — so the editor demonstrates the product instead
/// of merely describing it. Behavior options are capsule toggle chips rather
/// than a settings-style switch grid. Validation renders inline (crimson label).
enum SnippetEditorSheet {

    /// First non-blank line of the body, truncated — the fallback when the user leaves the
    /// title empty. Lives here rather than on the private controller because the
    /// typed-repetition offer builds a draft without ever opening one.
    static func derivedTitle(
        from replacement: String,
        localization loc: LocalizationManager = .shared
    ) -> String {
        let firstLine = replacement
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if firstLine.isEmpty { return loc.s("editor.untitled") }
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
    }
    /// §1 / §3: sized once here so the panel and its glass container can never
    /// disagree. The extra height over the old 500×548 buys the new-snippet
    /// guide strip and a materially taller replacement editor.
    /// Height of the behaviour pill row itself — `ToggleChip.intrinsicContentSize.height` plus a
    /// hair, so a focus ring is not clipped.
    static let chipRowHeight: CGFloat = 26

    /// Strip reserved *below* the pills for the horizontal overlay scroller.
    ///
    /// Overlay scrollers float over their content rather than taking layout space, which is
    /// exactly the problem: while scrolling, the bar was drawn across the bottom of the pills.
    /// Giving it a band of its own is cheaper than hiding it, and hiding it would leave the
    /// overflowing chips with no affordance at all.
    ///
    /// Sized by eye rather than by the scroller's own metrics: `NSScroller.scrollerWidth` reports
    /// the bar alone (~11pt at overlay size), which leaves it touching the pills above and the
    /// error line below. The extra clearance is the difference between "not overlapping" and
    /// "not crowded".
    static let chipScrollerBand: CGFloat = 20

    static let panelWidth: CGFloat = 520
    static let panelHeight: CGFloat = 690

    private static var activePanel: NSPanel?
    private static var activeController: SnippetEditorController?

    static func present(
        from hostWindow: NSWindow?,
        existing: SnippetModel?,
        draft: SnippetModel? = nil,
        groups: [SnippetGroup],
        currentGroupID: UUID?,
        loc: LocalizationManager = .shared,
        completion: @escaping (SnippetModel, UUID?) -> SnippetEditorPersistenceReceipt
    ) {
        // Same single-instance contract as MacroPalettePanel.present: a second
        // presentation while one is up would overwrite the statics, and finishing
        // the first would then nil them out from under the second.
        if (existing ?? draft)?.isSecret == true {
            (NSApp.delegate as? AppDelegate)?.openSecretManager(nil)
            return
        }
        if activePanel != nil { return }
        let panel = EditorKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)

        let snippetGroups = SnippetDocument(groups: groups).groups
        let controller = SnippetEditorController(
            existing: existing,
            draft: draft,
            groups: snippetGroups,
            currentGroupID: snippetGroups.contains(where: { $0.id == currentGroupID }) ? currentGroupID : nil,
            loc: loc,
            persist: completion,
            onDismiss: {
                // §2: a macro palette left open would outlive its host sheet.
                MacroPalettePanel.dismiss()
                if let host = hostWindow, panel.isSheet {
                    host.endSheet(panel)
                }
                panel.close()
                activePanel = nil
                activeController = nil
            }
        )
        panel.contentView = controller.view
        // This panel is a fixed-size, non-resizable sheet, and nothing inside it may change that.
        // A window under Auto Layout holds its size only at priority 500, below every label's
        // default compression resistance, so any label fed by typed text — the trigger rule
        // sentence carrying a conflict message, the live preview, a long group name — widened the
        // editor with each keystroke until the buttons left the screen. The min/max clamp that
        // used to sit here never entered the constraint solve. Required constraints do; see
        // `dtLockContentSize`. The individual labels are also bounded at the source below, so
        // they truncate legibly instead of merely losing the contest.
        panel.dtLockContentSize(NSSize(width: panelWidth, height: panelHeight))
        // ⌘Return → Save, even while the multi-line replacement editor owns Return.
        panel.saveHandler = { [weak controller] in
            controller?.saveFromKeyboard()
        }

        activePanel = panel
        activeController = controller

        if let hostWindow {
            hostWindow.beginSheet(panel, completionHandler: nil)
        } else {
            panel.center()
            WindowOrdering.makeKeyAndOrderFront(panel, context: "SnippetEditor")
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.focusInitialField()
    }
}

// MARK: - Controller

final class SnippetEditorController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    let existing: SnippetModel?
    /// Prefill for a new snippet (e.g. Add from Template). Never treated as an edit.
    private let draft: SnippetModel?
    let groups: [SnippetGroup]
    let loc: LocalizationManager
    let persist: (SnippetModel, UUID?) -> SnippetEditorPersistenceReceipt
    let onDismiss: () -> Void
    let resourceTransaction = SnippetEditTransaction()

    /// Values shown in the form: edit target, or template draft, or blank.
    var seed: SnippetModel? { existing ?? draft }

    let titleField = GlassTextField()
    let triggerField = GlassTextField()
    let groupPopup = NSPopUpButton()
    let aiTransformPopup = NSPopUpButton()
    let replacementView = NSTextView()
    let stage = ExpansionStageView()
    var enabledChip: ToggleChip!
    var caseChip: ToggleChip!
    var boundaryChip: ToggleChip!
    /// Enhancement plan 1.4. Shown only while Case Sensitive is off: a case-sensitive trigger
    /// matches one spelling, so how it was typed carries no request for the output.
    var propagateCaseChip: ToggleChip!
    var plainChip: ToggleChip!
    /// The replacement text view's scroller, hidden while the secure field has the slot.
    weak var replacementScroll: NSScrollView?
    let errorLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11, .medium), color: DevTypeTheme.accentBright, wrapping: true)
    let charCountLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10, .medium), color: DevTypeTheme.textTertiary)
    var editorContainer: NSView!
    /// The option-chip row, held so suggestion chips can be appended to and removed from it.
    weak var chipsRow: NSStackView?
    var macroButton: NSButton!
    /// The attach-image button, disabled while Secret is on: a snippet cannot be both.
    weak var imageButton: NSButton?
    var imagePreviewBar: NSView!
    let imagePreviewView = NSImageView()
    let imageNameLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11, .medium), color: DevTypeTheme.textSecondary)
    var saveButton: CapsuleButton?
    /// Inline live-validation readout next to the Trigger caption (✓ / conflict).
    let triggerStatusLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10, .medium), color: DevTypeTheme.statusGreen)
    /// §1: full-width sentence under the trigger field describing exactly what
    /// will happen with the trigger the user has typed.
    let triggerRuleLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(10, .medium), color: DevTypeTheme.textTertiary)
    /// Last computed trigger validity so Save enablement stays in sync.
    var isTriggerValid = false

    // §1: dismissible new-snippet guide.
    var guideView: SnippetEditorGuideView?
    var guideHeightConstraint: NSLayoutConstraint?
    /// Collapses the inline error to zero height while there is nothing to say.
    var errorHeightConstraint: NSLayoutConstraint?
    var helpButton: NSButton?
    var guideVisible: Bool

    // §2: smart-insertion bookkeeping. Placeholder spans arrive as *data* on the
    // macro descriptor and are stored here as absolute ranges, then shifted by
    // the observed length delta on each edit — never recovered by re-parsing.
    var placeholderRanges: [NSRange] = []
    var placeholderCursor = 0
    var lastTextLength = 0

    /// Stored file name of the snippet's existing image ("" = none).
    var attachedImagePath = ""
    /// Newly picked image file — copied into the store on save.
    var pickedImageURL: URL?
    /// Ordinary replacement text survives Secret on/off cycles for this sheet only. It is never
    /// persisted while Secret is enabled and never copied into the secure field.

    // MARK: - On-device tag suggestion (`SnippetTagSuggester`)

    /// What the model offered and what the user has accepted of it. `nil` until a suggestion
    /// arrives. Nothing here reaches the snippet without a chip being switched on.
    var acceptance: TagSuggestionAcceptance?
    /// In-flight suggestion. Cancelled on every keystroke and when the sheet closes, so a
    /// result for a body the user has since rewritten can never land.
    var suggestionTask: Task<Void, Never>?
    /// The chips currently offering the suggestion, so a new suggestion can replace them
    /// without disturbing the permanent option chips they sit beside.
    var suggestionChips: [ToggleChip] = []
    /// One chip per tag the snippet already carries, each switched on. Switching one off
    /// removes that tag at save — until now a tag could be written (by an Espanso import, or
    /// by a suggestion) but never seen or taken back.
    var existingTagChips: [ToggleChip] = []
    /// The chip offering the suggested group, if one was offered.
    weak var groupSuggestionChip: ToggleChip?
    /// Per-app scope, edited in `SnippetAppScopeSheet` and written at save. Seeded from the
    /// snippet so an imported scope survives an edit that never opens the sheet.
    var appScope: SnippetAppScope = .unscoped
    weak var appScopeChip: ToggleChip?

    /// Free-form tag entry. Lives at the end of the chip row, so it costs no vertical space in
    /// a panel whose height is fixed — the row already scrolls horizontally when it overflows.
    let newTagField = NSTextField()
    /// The group selected before the group chip was switched on, restored if it is switched
    /// back off — accepting a suggestion and then changing your mind must not strand you on it.
    var groupSelectionBeforeSuggestion: UUID?

    var hasImage: Bool { pickedImageURL != nil || !attachedImagePath.isEmpty }

    init(
        existing: SnippetModel?,
        draft: SnippetModel? = nil,
        groups: [SnippetGroup],
        currentGroupID: UUID?,
        loc: LocalizationManager,
        persist: @escaping (SnippetModel, UUID?) -> SnippetEditorPersistenceReceipt,
        onDismiss: @escaping () -> Void
    ) {
        self.existing = existing
        self.draft = draft
        self.groups = groups
        self.loc = loc
        self.persist = persist
        self.onDismiss = onDismiss
        self.initialGroupID = currentGroupID ?? groups.first?.id
        self.attachedImagePath = (existing ?? draft)?.imagePath ?? ""
        // §1: never shown when editing an existing snippet, and the dismissal is
        // remembered across launches.
        self.guideVisible = (existing == nil) && !SnippetEditorGuideView.isDismissed
        super.init(nibName: nil, bundle: nil)
    }

    let initialGroupID: UUID?

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        // The task captures `self` weakly, so this is not a leak fix — it stops a model
        // request whose answer nothing will read from holding the adapter warm.
        suggestionTask?.cancel()
        // Normally Cancel drains this before dismissal. This final best-effort pass covers app
        // teardown after a failed compensation without ever staging anything new.
        _ = resourceTransaction.cancel()
    }

    override func loadView() {
        let glass = GlassContainerView(
            cornerRadius: DevTypeTheme.Radius.panel,
            tint: DevTypeTheme.accent.withAlphaComponent(0.09),
            material: .popover
        )
        glass.frame = NSRect(
            x: 0,
            y: 0,
            width: SnippetEditorSheet.panelWidth,
            height: SnippetEditorSheet.panelHeight
        )
        let root = glass.contentView

        // Header
        let isNew = existing == nil
        let badge = IconBadgeView(
            symbol: isNew ? "sparkles" : "square.and.pencil",
            tint: DevTypeTheme.accent,
            size: 34,
            pointSize: 15
        )
        let headerLabel = DevTypeTheme.makeLabel(
            loc.s(isNew ? "editor.add" : "editor.edit"),
            font: DevTypeTheme.font(15, .bold),
            color: DevTypeTheme.textPrimary
        )
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(badge)
        root.addSubview(headerLabel)

        // §1: the "?" affordance — dismissing the guide is never permanent.
        if isNew {
            let button = SnippetEditorGuideView.makeGhostButton(
                title: loc.s("guide.show"),
                symbol: "questionmark",
                target: self,
                action: #selector(toggleGuide)
            )
            helpButton = button
            root.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
                button.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
            ])
        }

        // Expansion stage (live simulation hero)
        root.addSubview(stage)

        // §1: new-snippet guide — trigger rule, live, plus one-click starters.
        let guide: SnippetEditorGuideView?
        if isNew {
            let built = SnippetEditorGuideView(
                loc: loc,
                onStarter: { [weak self] starter in self?.applyStarter(starter) },
                onDismiss: { [weak self] in self?.dismissGuide() }
            )
            guide = built
            guideView = built
            root.addSubview(built)
        } else {
            guide = nil
        }

        // Title
        let nameCaption = caption(loc.s("editor.name"))
        titleField.placeholderAttributedString = placeholder(loc.s("editor.name"))
        titleField.stringValue = seed?.title ?? ""
        // §4: the caption is a separate view, so VoiceOver cannot infer it.
        titleField.setAccessibilityLabel(loc.s("editor.name"))
        root.addSubview(nameCaption)
        root.addSubview(titleField)

        // Trigger (left) + Group (right), side by side
        let triggerCaption = caption(loc.s("editor.trigger"))
        triggerField.placeholderAttributedString = placeholder(loc.s("editor.trigger.placeholder"))
        triggerField.font = DevTypeTheme.mono(13, .medium)
        triggerField.stringValue = seed?.triggerKeyword ?? ""
        triggerField.delegate = self
        triggerField.setAccessibilityLabel(loc.s("editor.trigger"))
        triggerField.setAccessibilityHelp(loc.s("editor.trigger.hint"))
        triggerStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        triggerStatusLabel.lineBreakMode = .byTruncatingTail
        triggerRuleLabel.translatesAutoresizingMaskIntoConstraints = false
        triggerRuleLabel.lineBreakMode = .byTruncatingTail
        // Both carry text the user controls — the rule sentence embeds the typed trigger and, on
        // a conflict, the full message naming every shadowed trigger. At the default resistance
        // (750) their intrinsic width beat the window's 500 and pushed the panel wider; at low
        // resistance they truncate in place. The rule label's tooltip and the inline error carry
        // the full text.
        triggerStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        triggerRuleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        triggerRuleLabel.setAccessibilityLabel(loc.s("ax.editor.triggerStatus"))
        root.addSubview(triggerCaption)
        root.addSubview(triggerStatusLabel)
        root.addSubview(triggerField)
        root.addSubview(triggerRuleLabel)

        let groupCaption = caption(loc.s("editor.group"))
        configureGroupPopup()
        root.addSubview(groupCaption)
        root.addSubview(groupPopup)

        // Replacement — the macro palette and image picker live in the
        // composer's own toolbar, so the caption line stays quiet apart from the
        // AI Transform control, which is a property *of* the replacement and now
        // rides on its header row instead of stacking under Group.
        let replacementCaption = caption(loc.s("editor.replacement"))
        let editorContainer = makeEditorContainer()
        self.editorContainer = editorContainer
        let imageBar = makeImagePreviewBar()
        self.imagePreviewBar = imageBar
        root.addSubview(replacementCaption)
        root.addSubview(editorContainer)
        root.addSubview(imageBar)

        let aiTransformRaw = seed?.aiTransform.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let aiCaption = caption(loc.s("editor.aiTransform"))
        aiCaption.setContentCompressionResistancePriority(.required, for: .horizontal)
        configureAITransformPopup(selectedRaw: aiTransformRaw)
        root.addSubview(aiCaption)
        root.addSubview(aiTransformPopup)

        // Behavior toggle chips
        let behaviorCaption = caption(loc.s("editor.behavior"))
        root.addSubview(behaviorCaption)

        enabledChip = ToggleChip(
            title: loc.s("editor.enabled"), symbol: "power",
            isOn: seed?.enabled ?? true,
            help: loc.s("editor.enabled.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        caseChip = ToggleChip(
            title: loc.s("editor.caseSensitive"), symbol: "textformat",
            // §5: default ON for new snippets — ":Hi" silently swallowing ":hi"
            // was the most confusing matching behaviour a new user could hit.
            isOn: seed?.isCaseSensitive ?? true,
            help: loc.s("editor.caseSensitive.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        propagateCaseChip = ToggleChip(
            title: loc.s("editor.propagateCase"), symbol: "textformat.size",
            isOn: seed?.propagateCase ?? false,
            help: loc.s("editor.propagateCase.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        propagateCaseChip.isHidden = caseChip.isOn
        boundaryChip = ToggleChip(
            title: loc.s("editor.wordBoundary"), symbol: "paragraphsign",
            isOn: seed?.requireWordBoundary ?? true,
            // §1: this is the toggle that changes the trigger rule the guide
            // explains, so its help text spells that rule out in full.
            help: loc.s("editor.wordBoundary.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        plainChip = ToggleChip(
            title: loc.s("editor.plainText"), symbol: "doc.plaintext",
            isOn: seed?.isPlainText ?? true,
            help: loc.s("editor.plainText.help"),
            target: self, action: #selector(chipTapped(_:))
        )
        let chipsRow = NSStackView(views: [enabledChip, caseChip, propagateCaseChip, boundaryChip, plainChip])
        // Suggestion chips are appended to this same row rather than given a row of their own:
        // the panel is a fixed 690pt and this one already scrolls horizontally when it overflows.
        self.chipsRow = chipsRow
        for tag in seed?.tags ?? [] {
            existingTagChips.append(makeExistingTagChip(tag))
        }
        for chip in existingTagChips { chipsRow.addArrangedSubview(chip) }
        appScope = SnippetAppScope(
            includeApps: seed?.includeApps ?? [],
            excludeApps: seed?.excludeApps ?? []
        )
        let scopeChip = ToggleChip(
            title: SnippetAppScopeSummary.chipTitle(
                include: appScope.includeApps, exclude: appScope.excludeApps, loc: loc
            ),
            symbol: "macwindow.on.rectangle",
            isOn: appScope.isScoped,
            help: loc.s("appscope.chip.help"),
            target: self,
            action: #selector(appScopeChipTapped)
        )
        appScopeChip = scopeChip
        chipsRow.addArrangedSubview(scopeChip)
        configureNewTagField()
        chipsRow.addArrangedSubview(newTagField)
        chipsRow.orientation = .horizontal
        chipsRow.alignment = .centerY
        chipsRow.spacing = 8
        chipsRow.translatesAutoresizingMaskIntoConstraints = false

        // The row is wider than the panel. `ToggleChip.intrinsicContentSize` says as much in its
        // own comment — "any wider and the four chips stop fitting on one row inside the 480pt
        // content width" — and Secret is the fifth. The row had only a leading constraint, so the
        // overflow simply ran off the edge with no way to reach it.
        //
        // Scrolled rather than wrapped: a second line would have to come out of the composer's
        // height, which is the part of this panel worth the space, and every chip stays on the
        // baseline the caption labels.
        let chipsScroll = NSScrollView()
        chipsScroll.translatesAutoresizingMaskIntoConstraints = false
        chipsScroll.hasHorizontalScroller = true
        chipsScroll.hasVerticalScroller = false
        chipsScroll.autohidesScrollers = true
        chipsScroll.scrollerStyle = .overlay
        chipsScroll.borderType = .noBorder
        chipsScroll.drawsBackground = false
        chipsScroll.horizontalScrollElasticity = .allowed
        chipsScroll.verticalScrollElasticity = .none
        // An overlay scroller draws *on top of* the content it scrolls, so mid-scroll it sat
        // across the bottom of the pills. Reserve a band for it instead: the content inset keeps
        // the document out of the strip the scroller appears in, so the two never share pixels.
        chipsScroll.automaticallyAdjustsContentInsets = false
        chipsScroll.contentInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: SnippetEditorSheet.chipScrollerBand,
            right: 0
        )
        chipsScroll.documentView = chipsRow
        root.addSubview(chipsScroll)

        NSLayoutConstraint.activate([
            // Pin the row inside the clip view so the stack keeps its intrinsic width (that is
            // what there is to scroll) while its height matches the visible strip.
            chipsRow.leadingAnchor.constraint(equalTo: chipsScroll.contentView.leadingAnchor),
            chipsRow.topAnchor.constraint(equalTo: chipsScroll.contentView.topAnchor),
            // Height, not a bottom pin: pinned to the bottom the stack would stretch across the
            // scroller's band and put the pills back under it.
            chipsRow.heightAnchor.constraint(equalToConstant: SnippetEditorSheet.chipRowHeight),
        ])

        // Inline error
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        errorLabel.maximumNumberOfLines = 2
        // Setting `maximumNumberOfLines` resets the wrapping label's break mode,
        // which left long conflict messages clipped mid-word at the panel edge.
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.cell?.wraps = true
        errorLabel.cell?.isScrollable = false
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
            title: loc.s("editor.save"),
            symbol: "checkmark",
            style: .primary,
            target: self,
            action: #selector(saveTapped)
        )
        // ⌘Return — see EditorKeyablePanel.performKeyEquivalent for the Return routing.
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        self.saveButton = saveButton
        root.addSubview(cancelButton)
        root.addSubview(saveButton)

        // Visible shortcut hints — a shortcut you can't discover may as well not exist.
        let escHint = KeyCapView("esc")
        let escLabel = DevTypeTheme.makeLabel(
            loc.s("common.cancel"),
            font: DevTypeTheme.font(9.5, .medium),
            color: DevTypeTheme.textTertiary
        )
        escLabel.translatesAutoresizingMaskIntoConstraints = false
        let saveHint = KeyCapView("⌘↩")
        let saveHintLabel = DevTypeTheme.makeLabel(
            loc.s("editor.save"),
            font: DevTypeTheme.font(9.5, .medium),
            color: DevTypeTheme.textTertiary
        )
        saveHintLabel.translatesAutoresizingMaskIntoConstraints = false
        let hintStack = NSStackView(views: [escHint, escLabel, saveHint, saveHintLabel])
        hintStack.orientation = .horizontal
        hintStack.alignment = .centerY
        hintStack.spacing = 4
        hintStack.setCustomSpacing(12, after: escLabel)
        hintStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hintStack)

        let columnGap: CGFloat = 12

        // §1 / §3: everything above the composer hangs off the top edge and
        // everything below it hangs off the bottom edge, leaving the replacement
        // editor as the single flexible row. Collapsing the guide — or hiding
        // the inline error — therefore hands its space straight to the editor
        // with no per-state height arithmetic to keep in sync, and no element
        // can ever grow through the footer.
        let guideHeight = guide?.heightAnchor.constraint(
            equalToConstant: guideVisible ? SnippetEditorGuideView.preferredHeight : 0
        )
        guideHeightConstraint = guideHeight

        // The error takes no space until there is something to say.
        errorLabel.preferredMaxLayoutWidth = SnippetEditorSheet.panelWidth - 40
        let errorHeight = errorLabel.heightAnchor.constraint(equalToConstant: 0)
        errorHeightConstraint = errorHeight

        // Floor for the flexible row, below required so a pathological state
        // (very long error, very tall guide) degrades instead of logging a
        // constraint conflict.
        let editorMinHeight = editorContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 88)
        editorMinHeight.priority = NSLayoutConstraint.Priority(999)

        // The rule sentence spans the full width, so it has to clear BOTH
        // columns. The required `>=` pair does that; this low-priority spring
        // pulls it snug against whichever column ends lower (the popup, today)
        // so the position stays unambiguous.
        let ruleTopSpring = triggerRuleLabel.topAnchor.constraint(
            equalTo: groupPopup.bottomAnchor,
            constant: 6
        )
        ruleTopSpring.priority = .defaultLow

        var extraConstraints: [NSLayoutConstraint] = []
        if let guide, let guideHeight {
            extraConstraints = [
                guide.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 10),
                guide.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                guide.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                guideHeight
            ]
        }

        // When the guide strip exists (new snippets) the form hangs off its
        // bottom edge; otherwise it hugs the stage. Anchoring the caption to the
        // stage in both cases would put the guide on top of the Title field.
        let nameTopConstraint = nameCaption.topAnchor.constraint(
            equalTo: guide?.bottomAnchor ?? stage.bottomAnchor,
            constant: 12
        )

        NSLayoutConstraint.activate(extraConstraints)
        NSLayoutConstraint.activate([
            editorMinHeight,
            errorHeight,
            ruleTopSpring,
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            headerLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            headerLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            stage.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 14),
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stage.heightAnchor.constraint(equalToConstant: 60),

            nameTopConstraint,
            nameCaption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            titleField.topAnchor.constraint(equalTo: nameCaption.bottomAnchor, constant: 4),
            titleField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            titleField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            triggerCaption.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 10),
            triggerCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            triggerStatusLabel.centerYAnchor.constraint(equalTo: triggerCaption.centerYAnchor),
            triggerStatusLabel.leadingAnchor.constraint(equalTo: triggerCaption.trailingAnchor, constant: 8),
            triggerStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: triggerField.trailingAnchor),
            triggerField.topAnchor.constraint(equalTo: triggerCaption.bottomAnchor, constant: 4),
            triggerField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            triggerField.trailingAnchor.constraint(equalTo: root.centerXAnchor, constant: -columnGap / 2),

            // Sits below BOTH columns — as a half-width neighbour of the popup
            // it used to be drawn straight through the AI Transform caption.
            triggerRuleLabel.topAnchor.constraint(greaterThanOrEqualTo: triggerField.bottomAnchor, constant: 6),
            triggerRuleLabel.topAnchor.constraint(greaterThanOrEqualTo: groupPopup.bottomAnchor, constant: 6),
            triggerRuleLabel.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            triggerRuleLabel.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            groupCaption.topAnchor.constraint(equalTo: triggerCaption.topAnchor),
            groupCaption.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: columnGap / 2 + 2),
            groupPopup.topAnchor.constraint(equalTo: groupCaption.bottomAnchor, constant: 4),
            groupPopup.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: columnGap / 2),
            groupPopup.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            // Composer header: caption on the left, AI Transform on the right.
            aiTransformPopup.topAnchor.constraint(equalTo: triggerRuleLabel.bottomAnchor, constant: 12),
            aiTransformPopup.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            aiTransformPopup.widthAnchor.constraint(equalToConstant: 136),
            aiCaption.trailingAnchor.constraint(equalTo: aiTransformPopup.leadingAnchor, constant: -8),
            aiCaption.centerYAnchor.constraint(equalTo: aiTransformPopup.centerYAnchor),

            replacementCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            replacementCaption.centerYAnchor.constraint(equalTo: aiTransformPopup.centerYAnchor),
            replacementCaption.trailingAnchor.constraint(lessThanOrEqualTo: aiCaption.leadingAnchor, constant: -10),

            editorContainer.topAnchor.constraint(equalTo: aiTransformPopup.bottomAnchor, constant: 6),
            editorContainer.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            imageBar.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            imageBar.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            imageBar.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            imageBar.heightAnchor.constraint(equalTo: editorContainer.heightAnchor),

            // Bottom half, anchored UP from the footer: the composer's bottom
            // edge is whatever is left over.
            editorContainer.bottomAnchor.constraint(equalTo: behaviorCaption.topAnchor, constant: -12),
            behaviorCaption.leadingAnchor.constraint(equalTo: nameCaption.leadingAnchor),
            behaviorCaption.bottomAnchor.constraint(equalTo: chipsScroll.topAnchor, constant: -9),
            chipsScroll.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            // The trailing edge is the whole point: without it the row had nothing telling it
            // where the panel ends, so it overflowed instead of scrolling.
            chipsScroll.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            chipsScroll.heightAnchor.constraint(
                equalToConstant: SnippetEditorSheet.chipRowHeight + SnippetEditorSheet.chipScrollerBand
            ),
            chipsScroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -10),

            // §3: anchored UP from the divider rather than DOWN from the chips.
            // Top-anchored, a two-line error grew straight through the hairline
            // and the buttons; from here it grows into the gap above itself.
            errorLabel.bottomAnchor.constraint(equalTo: hairline.topAnchor, constant: -8),
            errorLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            hairline.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hairline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hairline.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),

            hintStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hintStack.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        // §3: an explicit key-view loop. Left implicit, AppKit walks the views in
        // subview order, which stopped matching reading order once the guide and
        // the trigger readout were inserted above the form.
        titleField.nextKeyView = triggerField
        triggerField.nextKeyView = groupPopup
        groupPopup.nextKeyView = aiTransformPopup
        aiTransformPopup.nextKeyView = replacementView
        replacementView.nextKeyView = enabledChip
        enabledChip.nextKeyView = caseChip
        caseChip.nextKeyView = propagateCaseChip
        propagateCaseChip.nextKeyView = boundaryChip
        boundaryChip.nextKeyView = plainChip
        plainChip.nextKeyView = cancelButton
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = titleField

        lastTextLength = (replacementView.string as NSString).length
        stage.updateTrigger(triggerField.stringValue)
        applyGuideVisibility()
        updateImageUI()
        view = glass
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        triggerDidChange()
    }

    /// ⌘Return path from EditorKeyablePanel — mirrors the Save button.
    func saveFromKeyboard() { saveTapped() }

    // MARK: Live preview

    func textDidChange(_ notification: Notification) {
        // §2: keep the pending placeholder ranges aligned with the edit that just
        // happened, so typing over one placeholder does not desynchronise the
        // rest of the just-inserted token.
        let newLength = (replacementView.string as NSString).length
        let delta = newLength - lastTextLength
        lastTextLength = newLength
        if delta != 0, !placeholderRanges.isEmpty {
            let caret = replacementView.selectedRange().location
            // An insertion of `delta` characters ended at the caret; a deletion
            // leaves the caret at the edit point.
            let editStart = caret - max(delta, 0)
            for index in placeholderRanges.indices where index >= placeholderCursor {
                if placeholderRanges[index].location >= editStart {
                    placeholderRanges[index].location = max(0, placeholderRanges[index].location + delta)
                }
            }
        }
        refreshPreview()
        scheduleTagSuggestion()
    }


    /// §2: Tab hops to the next editable span of the macro that was just
    /// inserted. With no pending span we return `false`, so AppKit's default
    /// (inserting a literal tab, which snippet bodies legitimately need) is
    /// unchanged.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === replacementView else { return false }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            return advanceToNextPlaceholder()
        }
        return false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === triggerField else { return }
        triggerDidChange()
    }
    // MARK: Actions

    @objc private func chipTapped(_ sender: ToggleChip) {
        sender.isOn.toggle()
        if sender === caseChip { propagateCaseChip.isHidden = caseChip.isOn }
        // Case sensitivity changes what counts as a conflict, and Word Boundary
        // changes the firing rule the guide explains — both re-run live.
        if sender === caseChip || sender === boundaryChip || sender === enabledChip {
            triggerDidChange()
        }
    }

    func focusInitialField() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let target = self.existing == nil ? self.titleField : self.triggerField
            self.view.window?.makeFirstResponder(target)
        }
    }

    @objc private func cancelTapped() {
        switch resourceTransaction.cancel() {
        case .clean:
            onDismiss()
        case .rollbackFailed:
            showError(loc.s("editor.transaction.rollbackFailed"))
        }
    }

    /// Derive a visible name from the first non-blank body line; content-free secret/image
    /// snippets use the localized untitled fallback.
    static func derivedTitle(
        from replacement: String,
        localization loc: LocalizationManager = .shared
    ) -> String {
        SnippetEditorSheet.derivedTitle(from: replacement, localization: loc)
    }
}
