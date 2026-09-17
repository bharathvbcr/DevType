import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// Streaming preview for an AI transform result.
///
/// Spinner until the first non-nil snapshot (~1.4s prefill), then streamed text.
/// Buttons: Replace / Copy / Retry / Cancel.
///
/// Anything that replaces the request in flight — Cancel, Retry, the tone menu, the kind
/// menu, or another preview opening — discards it, which now both drops its result and
/// cancels the generation, and then queues the replacement behind that unwind. Every
/// callback carries the generation it belongs to, so a superseded request cannot write
/// into the panel or tear down the presentation of the request that replaced it.
enum AIPreviewPanel {
    /// Sized once here so the panel and the labels that must fit inside it can never
    /// disagree. The header (badge, title, delta pills, tone and kind menus) needs 652pt
    /// in every shipped language; this was 560 while the panel silently laid out at 652,
    /// so `positionNearTop` centred a width the panel never had and the error label
    /// declared a wrap width 92pt narrower than the one it got. `loadView` caps the
    /// content view at this size so the number stays true as strings change.
    static let panelSize = NSSize(width: 660, height: 460)

    private static var panel: NSPanel?
    private static var controller: AIPreviewController?
    /// This panel's claim on matching being suspended — see `EventTapEngine.MatchingSuspension`.
    private static var suspension: EventTapEngine.MatchingSuspension?
    private static let dismissWatchers = PanelDismissWatchers()
    /// Bumped on close so late partials / completions ignore a dismissed panel.
    private static var generationToken = UUID()
    /// The generation the previous preview abandoned when it closed. The next preview waits
    /// for it to unwind before asking for the model: without the handover, triggering a
    /// second transform while the first panel was still generating had the closed panel's
    /// own request refuse the new one as `.busy`.
    private static var supersededHandle: AITransformDiscardHandle?
    /// Erased typed trigger to reinject when the panel is cancelled / dismissed.
    private static var pendingRestoreOnCancel: String?
    private static var pendingRestoreSourceApp: NSRunningApplication?

    static var isOpen: Bool { panel?.isVisible == true }

    /// Shared entry used by the hotkey path (after action pick) and the typed engine path.
    /// `restoreOnCancel` re-injects the erased typed trigger when the user dismisses without Replace.
    static func present(
        input: String,
        kind: AITransformKind,
        sourceApp: NSRunningApplication?,
        customInstructions: String? = nil,
        restoreOnCancel: String? = nil,
        loc: LocalizationManager = .shared,
        clipboardWriter: @escaping (String) -> Bool = {
            PasteboardBroker.shared.writeUserClipboardString($0)
        },
        onReplace: @escaping (String, NSRunningApplication?) -> Void
    ) {
        if isOpen { close() }
        open(
            input: input,
            kind: kind,
            sourceApp: sourceApp,
            customInstructions: customInstructions,
            restoreOnCancel: restoreOnCancel,
            loc: loc,
            clipboardWriter: clipboardWriter,
            onReplace: onReplace
        )
    }

    /// Closing always stops generation. There used to be a `discard: false` path for the
    /// Replace button, on the theory that an accepted result had nothing left to cancel —
    /// but the generation behind it kept running and kept the single-flight latch, so the
    /// next transform the user asked for was refused `.busy`. Once the user has taken an
    /// answer, the rest of that generation is dead work in every case.
    static func close(resumeMatching: Bool = true) {
        let token = UUID()
        generationToken = token
        if let abandoned = controller?.teardown() {
            supersededHandle = abandoned
        }
        removeDismissWatchers()
        panel?.close()
        panel = nil
        controller = nil
        if resumeMatching {
            suspension?.release()
            suspension = nil
        }
    }

    private static func open(
        input: String,
        kind: AITransformKind,
        sourceApp: NSRunningApplication?,
        customInstructions: String?,
        restoreOnCancel: String?,
        loc: LocalizationManager,
        clipboardWriter: @escaping (String) -> Bool,
        onReplace: @escaping (String, NSRunningApplication?) -> Void
    ) {
        suspension = EventTapEngine.shared.suspendMatching(reason: "AIPreviewPanel")
        let token = UUID()
        generationToken = token
        pendingRestoreOnCancel = restoreOnCancel
        pendingRestoreSourceApp = sourceApp

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            Task { await AITextTransformer.shared.prewarm(kind: kind, customInstructions: customInstructions) }
        }
        #endif
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)
        panel.becomesKeyOnlyIfNeeded = false

        // Consumed once: the request the previous panel abandoned, so this one queues
        // behind its unwind instead of colliding with it.
        let inherited = supersededHandle
        supersededHandle = nil

        let controller = AIPreviewController(
            input: input,
            kind: kind,
            sourceApp: sourceApp,
            customInstructions: customInstructions,
            superseding: inherited,
            loc: loc,
            isCurrent: { token == Self.generationToken && Self.panel != nil },
            clipboardWriter: clipboardWriter,
            onReplace: { text, app in
                // Successful replace — do not reinject the typed trigger.
                pendingRestoreOnCancel = nil
                pendingRestoreSourceApp = nil
                AIUndoStore.stash(input)
                ToastPanel.show(loc.s("ai.preview.undoToast"), symbol: "arrow.uturn.backward.circle")
                close(resumeMatching: true)
                onReplace(text, app)
            },
            onCancel: {
                restoreErasedTriggerAndClose()
            }
        )
        panel.contentView = controller.view
        FloatingPanelChrome.positionNearTop(panel)

        // Publish the session before starting work. Local transforms complete synchronously;
        // `isCurrent` must already recognize this panel when their completion is delivered.
        self.panel = panel
        self.controller = controller
        installDismissWatchers(for: panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        FloatingPanelChrome.animateIn(panel)
        controller.startGeneration()
    }

    /// Cancel / outside-dismiss: reinject the erased typed trigger via `erasePlan: .empty`.
    private static func restoreErasedTriggerAndClose() {
        let trigger = pendingRestoreOnCancel
        let app = pendingRestoreSourceApp
        pendingRestoreOnCancel = nil
        pendingRestoreSourceApp = nil
        close(resumeMatching: true)
        if let trigger, !trigger.isEmpty {
            EventTapEngine.shared.injectAITransformResult(
                text: trigger,
                sourceApp: app,
                origin: .authoredText,
                completion: nil
            )
        } else {
            app?.activate()
        }
    }

    private static func installDismissWatchers(for panel: NSPanel) {
        dismissWatchers.install(
            for: panel,
            isStillCurrent: { self.panel === panel },
            dismiss: dismissFromOutsideInteraction
        )
    }

    private static func removeDismissWatchers() {
        dismissWatchers.removeAll()
    }

    private static func dismissFromOutsideInteraction() {
        guard panel != nil else { return }
        restoreErasedTriggerAndClose()
    }
}

// MARK: - Delta pills

/// The two pills in the preview header, which report how the result differs from the
/// selection. A free function rather than a method on the controller so the rule can be
/// checked without a model in the loop — only a lengthening transform exercises the sign,
/// and every transform that lengthens text needs the model.
enum AIPreviewDelta {
    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// `%d` signs a loss and not a gain, so a result that grew read "8 chars" — which is
    /// how a *total* reads, not a change. The sign is arithmetic rather than a word, so it
    /// is prefixed outside the localized string; every shipped table puts the number first
    /// ("%d words", "%d 단어", "%d 単語").
    static func label(_ delta: Int, key: String, loc: LocalizationManager) -> String {
        let localized = loc.s(key, delta)
        return delta > 0 ? "+" + localized : localized
    }
}

// MARK: - Controller

private final class AIPreviewController: NSViewController {
    private let input: String
    private var kind: AITransformKind
    private let sourceApp: NSRunningApplication?
    /// The user's own instruction, fixed for the life of the panel.
    private let authoredInstructions: String?
    /// The tone menu's preset, if any. Kept apart from `authoredInstructions` so choosing a
    /// tone refines the request instead of replacing it — this used to be one stored property,
    /// and picking a tone silently discarded whatever the user had typed.
    private var toneInstruction: String?
    private var customInstructions: String? {
        AIActionSelection.merged([authoredInstructions, toneInstruction])
    }
    private let loc: LocalizationManager
    private let isCurrent: () -> Bool
    private let clipboardWriter: (String) -> Bool
    private let onReplace: (String, NSRunningApplication?) -> Void
    private let onCancel: () -> Void

    private var discardHandle: AITransformDiscardHandle?
    /// Identifies which request a partial or completion belongs to.
    ///
    /// `isCurrent()` only answers "is this panel still the open one" — it cannot tell one
    /// of this panel's own requests from another. So when the user changed the kind, the
    /// tone, or pressed Retry, the *replaced* stream kept writing its partials into the
    /// text view under the new title, and its `.discarded` notice tore down the
    /// replacement's spinner and dropped the replacement's handle on its way to an early
    /// return. Every callback now names its generation and stale ones stop at the door.
    private var generation: UInt64 = 0
    /// The request a still-unwinding predecessor left behind, consumed by the next start.
    private var supersededHandle: AITransformDiscardHandle?
    private var resultText = ""
    private var keyMonitor: Any?
    private var showingDiff = false

    private let spinner = NSProgressIndicator()
    private let waitingLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(12), color: DevTypeTheme.textTertiary)
    private let textView = NSTextView()
    private var scrollView = NSScrollView()
    private let wordsDeltaPill = PillBadgeView(text: "", tint: DevTypeTheme.statusBlue)
    private let charsDeltaPill = PillBadgeView(text: "", tint: DevTypeTheme.textTertiary)

    private var replaceButton: CapsuleButton!
    private var replaceAndCopyButton: CapsuleButton!
    private var copyButton: CapsuleButton!
    private var retryButton: CapsuleButton!
    private var diffButton: CapsuleButton!
    private var kindPopup: NSPopUpButton!
    private var tonePopup: NSPopUpButton!
    private var titleLabel: NSTextField!
    private var errorLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11), color: DevTypeTheme.statusOrange)

    init(
        input: String,
        kind: AITransformKind,
        sourceApp: NSRunningApplication?,
        customInstructions: String?,
        superseding: AITransformDiscardHandle?,
        loc: LocalizationManager,
        isCurrent: @escaping () -> Bool,
        clipboardWriter: @escaping (String) -> Bool,
        onReplace: @escaping (String, NSRunningApplication?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.input = input
        self.kind = kind
        self.sourceApp = sourceApp
        self.authoredInstructions = customInstructions
        self.supersededHandle = superseding
        self.loc = loc
        self.isCurrent = isCurrent
        self.clipboardWriter = clipboardWriter
        self.onReplace = onReplace
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// Stops generation and returns the request that was abandoned, so the next preview can
    /// wait for it to unwind rather than be refused `.busy` by a panel that no longer exists.
    func teardown() -> AITransformDiscardHandle? {
        generation &+= 1
        let abandoned = discardHandle ?? supersededHandle
        discardHandle = nil
        supersededHandle = nil
        abandoned?.discard()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        return abandoned
    }

    override func loadView() {
        let glass = GlassContainerView(
            cornerRadius: DevTypeTheme.Radius.panel,
            tint: DevTypeTheme.accent.withAlphaComponent(0.10),
            material: .popover
        )
        glass.frame = NSRect(origin: .zero, size: AIPreviewPanel.panelSize)
        let root = glass.contentView

        let badge = IconBadgeView(symbol: "sparkles", tint: DevTypeTheme.accent, size: 32, pointSize: 14)
        titleLabel = DevTypeTheme.makeLabel(
            loc.s(kind.localizationKey),
            font: DevTypeTheme.font(14, .bold),
            color: DevTypeTheme.textPrimary
        )
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // The header is the widest row, and every label in it resists compression at 750,
        // which beats the window's own `windowSizeStayPut` (500) — so a longer transform
        // title or a longer translation moves the panel instead of truncating. Both
        // free-form labels yield first; the delta pills and the two menus are short.
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        wordsDeltaPill.translatesAutoresizingMaskIntoConstraints = false
        wordsDeltaPill.isHidden = true
        charsDeltaPill.translatesAutoresizingMaskIntoConstraints = false
        charsDeltaPill.isHidden = true

        let titleRow = NSStackView(views: [titleLabel, wordsDeltaPill, charsDeltaPill])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = DevTypeTheme.makeLabel(
            loc.s("ai.preview.subtitle"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary
        )
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerText = NSStackView(views: [titleRow, subtitleLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 1
        headerText.translatesAutoresizingMaskIntoConstraints = false

        // Tone popup
        tonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        tonePopup.translatesAutoresizingMaskIntoConstraints = false
        tonePopup.font = DevTypeTheme.font(11, .medium)
        tonePopup.addItem(withTitle: loc.s("ai.preview.tone.default"))
        tonePopup.addItem(withTitle: loc.s("ai.preview.tone.professional"))
        tonePopup.addItem(withTitle: loc.s("ai.preview.tone.casual"))
        tonePopup.addItem(withTitle: loc.s("ai.preview.tone.concise"))
        tonePopup.target = self
        tonePopup.action = #selector(toneChanged)
        tonePopup.setAccessibilityLabel(loc.s("ai.preview.tone.label"))

        kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        kindPopup.translatesAutoresizingMaskIntoConstraints = false
        kindPopup.font = DevTypeTheme.font(11, .medium)
        kindPopup.setAccessibilityLabel(loc.s("ai.preview.kind"))
        for k in AITransformKind.builtInPalette {
            let item = NSMenuItem(title: loc.s(k.localizationKey), action: nil, keyEquivalent: "")
            item.representedObject = k.rawValue
            kindPopup.menu?.addItem(item)
        }
        if let idx = AITransformKind.builtInPalette.firstIndex(of: kind) {
            kindPopup.selectItem(at: idx)
        }
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)

        let popupsStack = NSStackView(views: [tonePopup, kindPopup])
        popupsStack.orientation = .horizontal
        popupsStack.spacing = 6
        popupsStack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(badge)
        root.addSubview(headerText)
        root.addSubview(popupsStack)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isDisplayedWhenStopped = false
        waitingLabel.translatesAutoresizingMaskIntoConstraints = false
        waitingLabel.stringValue = loc.s("ai.preview.waiting")
        root.addSubview(spinner)
        root.addSubview(waitingLabel)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.isHidden = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = DevTypeTheme.font(13)
        textView.textColor = DevTypeTheme.textPrimary
        textView.textContainerInset = NSSize(width: 4, height: 4)
        // A scroll view does not size its document view — the document view has to be told
        // to follow the viewport. `NSTextView()` starts at a zero frame, and without this
        // the width AppKit happens to give it when the scroll view is first tiled is the
        // width it keeps forever. On the shipped 1.2.0 build that width is zero: the
        // panel's accessibility tree reads `AXScrollArea [632x277]` wrapping
        // `AXTextArea [0x277]` holding the whole result, so the answer was present,
        // announced to VoiceOver and insertable by Replace — with nowhere to draw.
        // This is the same setup every other text view in the app already uses.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: AIPreviewPanel.panelSize.width - 28,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(loc.s("ai.preview.result"))
        scrollView.documentView = textView
        root.addSubview(scrollView)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 3
        // This panel animates its frame in, so it cannot take the fixed-size lock the sheets use;
        // the one label fed by a free-form error message bounds itself instead. Without a
        // preferred width a wrapping label measures single-line, and at the default resistance
        // that width beat the window's and stretched the panel to fit the message.
        errorLabel.preferredMaxLayoutWidth = AIPreviewPanel.panelSize.width - 36
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addSubview(errorLabel)

        let hairline = DevTypeTheme.makeHairline()
        root.addSubview(hairline)

        let cancel = CapsuleButton(
            title: loc.s("common.cancel") + "  ⎋",
            style: .secondary,
            target: self,
            action: #selector(cancelTapped)
        )
        cancel.keyEquivalent = "\u{1b}"

        retryButton = CapsuleButton(
            title: loc.s("common.retry") + "  ⌘R",
            style: .secondary,
            target: self,
            action: #selector(retryTapped)
        )
        retryButton.isEnabled = false

        diffButton = CapsuleButton(
            title: loc.s("ai.preview.diff"),
            style: .secondary,
            target: self,
            action: #selector(diffTapped)
        )
        diffButton.isEnabled = false
        diffButton.isHidden = kind != .proofread

        copyButton = CapsuleButton(
            title: loc.s("ai.preview.copy") + "  ⌘C",
            style: .secondary,
            target: self,
            action: #selector(copyTapped)
        )
        copyButton.isEnabled = false

        replaceAndCopyButton = CapsuleButton(
            title: loc.s("ai.preview.replaceAndCopy") + "  ⌥↩",
            style: .secondary,
            target: self,
            action: #selector(replaceAndCopyTapped)
        )
        replaceAndCopyButton.isEnabled = false

        replaceButton = CapsuleButton(
            title: loc.s("ai.preview.replace") + "  ↩",
            symbol: "checkmark",
            style: .primary,
            target: self,
            action: #selector(replaceTapped)
        )
        replaceButton.keyEquivalent = "\r"
        replaceButton.isEnabled = false

        // The fixed 560pt panel cannot contain all six localized actions on one
        // baseline. Keep every action visible at full intrinsic width by placing
        // secondary review commands on a row above the commit/cancel row.
        let secondaryActions = NSStackView(views: [diffButton, retryButton, copyButton])
        secondaryActions.orientation = .horizontal
        secondaryActions.alignment = .centerY
        secondaryActions.spacing = 8
        secondaryActions.translatesAutoresizingMaskIntoConstraints = false

        let primaryActions = NSStackView(views: [replaceAndCopyButton, replaceButton])
        primaryActions.orientation = .horizontal
        primaryActions.alignment = .centerY
        primaryActions.spacing = 8
        primaryActions.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(cancel)
        root.addSubview(secondaryActions)
        root.addSubview(primaryActions)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            headerText.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            headerText.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            popupsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            popupsStack.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            headerText.trailingAnchor.constraint(lessThanOrEqualTo: popupsStack.leadingAnchor, constant: -8),

            spinner.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 28),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            waitingLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 10),
            waitingLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            scrollView.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scrollView.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -8),

            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            errorLabel.bottomAnchor.constraint(equalTo: hairline.topAnchor, constant: -10),

            hairline.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            hairline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            hairline.bottomAnchor.constraint(equalTo: secondaryActions.topAnchor, constant: -12),

            cancel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(lessThanOrEqualTo: primaryActions.leadingAnchor, constant: -12),

            primaryActions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            primaryActions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancel.centerYAnchor.constraint(equalTo: primaryActions.centerYAnchor),

            secondaryActions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            secondaryActions.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 18),
            secondaryActions.bottomAnchor.constraint(equalTo: primaryActions.topAnchor, constant: -8),

            // The declared size, made true. `dtLockContentSize` pins a *required equal*
            // size, which this panel cannot take: `FloatingPanelChrome.animateIn` settles
            // it in from a frame inset by 12×8 and a required equality would fight that
            // every time. An upper bound does the job the lock does — it outranks the 750
            // intrinsic widths that were pushing the panel out to 652pt against a declared
            // 560 — while still letting the animation come in smaller.
            glass.widthAnchor.constraint(lessThanOrEqualToConstant: AIPreviewPanel.panelSize.width),
            glass.heightAnchor.constraint(lessThanOrEqualToConstant: AIPreviewPanel.panelSize.height)
        ])

        view = glass
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    func startGeneration() {
        beginTransform()
    }

    private func beginTransform() {
        generation &+= 1
        let generation = self.generation

        // Stop the request being replaced *before* asking for another. `discard()` now
        // cancels it as well as dropping its result, and handing it to `after:` queues this
        // request behind its unwind — the two halves of what "replace this request" means.
        // Skipping either is what made Retry, the kind menu and the tone menu answer
        // "Another AI transform is already running" and leave the panel blank.
        let superseded = discardHandle ?? supersededHandle
        discardHandle = nil
        supersededHandle = nil
        superseded?.discard()

        resultText = ""
        showingDiff = false
        textView.string = ""
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        scrollView.isHidden = true
        spinner.isHidden = false
        waitingLabel.isHidden = false
        spinner.startAnimation(nil)
        errorLabel.isHidden = true
        errorLabel.stringValue = ""
        wordsDeltaPill.isHidden = true
        charsDeltaPill.isHidden = true
        replaceButton.isEnabled = false
        replaceAndCopyButton.isEnabled = false
        copyButton.isEnabled = false
        retryButton.isEnabled = false
        diffButton.isEnabled = false
        diffButton.isHidden = kind != .proofread
        diffButton.title = loc.s("ai.preview.diff")
        titleLabel.stringValue = loc.s(kind.localizationKey)

        if let local = AILocalTransform.run(kind: kind, input: input) {
            applyCompletion(local, generation: generation)
            return
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            discardHandle = AITextTransformer.shared.transformStreaming(
                kind: kind,
                input: input,
                customInstructions: customInstructions,
                after: superseded,
                onPartial: { [weak self] partial in
                    Task { @MainActor in
                        self?.applyPartial(partial, generation: generation)
                    }
                },
                completionQueue: .main
            ) { [weak self] result in
                Task { @MainActor in
                    self?.applyCompletion(result, generation: generation)
                }
            }
            return
        }
        #endif
        applyCompletion(.failure(.unavailable(.unsupportedOS)), generation: generation)
    }

    /// Whether a callback still speaks for what the panel is showing. Both halves matter:
    /// the panel must still be the open one, *and* the callback must belong to the request
    /// the panel is currently running.
    private func isLive(_ generation: UInt64) -> Bool {
        generation == self.generation && isCurrent()
    }

    private func applyPartial(_ partial: String?, generation: UInt64) {
        guard isLive(generation), let partial else { return }
        if scrollView.isHidden {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            waitingLabel.isHidden = true
            scrollView.isHidden = false
        }
        resultText = partial
        showingDiff = false
        textView.string = partial
        textView.scrollToEndOfDocument(nil)
        updateDeltas(for: partial)
    }

    private func applyCompletion(_ result: Result<String, AITransformError>, generation: UInt64) {
        // Before a single pixel changes. This guard used to sit below `discardHandle = nil`
        // and the spinner teardown, so a superseded request's `.discarded` notice reached in
        // and silenced the spinner of the request that had replaced it — leaving a panel
        // with no text, no spinner and nothing on the way.
        guard isLive(generation) else { return }
        stopPresentingWork()

        // `.discarded` for the *live* request is unreachable from this panel — every discard
        // bumps the generation first, so such a notice is stale by construction and was
        // refused above. If one ever does arrive, the spinner is already down and Retry is
        // live; there is no result and no failure to report.
        if case .failure(.discarded) = result { return }

        switch Self.normalized(result) {
        case .success(let text):
            resultText = text
            scrollView.isHidden = false
            textView.string = text
            replaceButton.isEnabled = true
            replaceAndCopyButton.isEnabled = true
            copyButton.isEnabled = true
            diffButton.isEnabled = kind == .proofread && text != input
            errorLabel.isHidden = true
            updateDeltas(for: text)
        case .failure(let error):
            errorLabel.stringValue = AITransformFlow.localizedError(error, loc: loc)
            errorLabel.isHidden = false
            if resultText.isEmpty {
                scrollView.isHidden = true
            }
            replaceButton.isEnabled = !resultText.isEmpty
            replaceAndCopyButton.isEnabled = !resultText.isEmpty
            copyButton.isEnabled = !resultText.isEmpty
            diffButton.isEnabled = kind == .proofread && !resultText.isEmpty && resultText != input
        }
    }

    /// The presentation of "a request is running", taken down. Retry becomes available in
    /// success and in failure alike — it is the one control that is always correct once a
    /// generation has ended, which is why the tests read it as the finished signal.
    private func stopPresentingWork() {
        discardHandle = nil
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        waitingLabel.isHidden = true
        retryButton.isEnabled = true
    }

    /// A blank answer is a failed generation, not a result.
    ///
    /// `AITransformFlow.runDirect` already refuses to inject one, and `generateRaw` rejects
    /// it for every model transform — but the preview calls `AILocalTransform` itself, ahead
    /// of that check, so a whitespace-only selection reached the panel as a `.success` with
    /// Replace enabled and offered to overwrite the selection with nothing.
    private static func normalized(
        _ result: Result<String, AITransformError>
    ) -> Result<String, AITransformError> {
        guard case .success(let text) = result else { return result }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
        return .failure(.decodingFailure)
    }

    private func updateDeltas(for text: String) {
        let wordDelta = AIPreviewDelta.words(in: text) - AIPreviewDelta.words(in: input)
        let charDelta = text.count - input.count

        wordsDeltaPill.isHidden = false
        wordsDeltaPill.update(
            text: AIPreviewDelta.label(wordDelta, key: "ai.preview.delta.words", loc: loc),
            tint: wordDelta >= 0 ? DevTypeTheme.statusBlue : DevTypeTheme.statusOrange
        )

        charsDeltaPill.isHidden = false
        charsDeltaPill.update(
            text: AIPreviewDelta.label(charDelta, key: "ai.preview.delta.chars", loc: loc),
            tint: DevTypeTheme.textTertiary
        )
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // ⌘R -> Retry
            if flags == .command && event.charactersIgnoringModifiers == "r" {
                if self.retryButton.isEnabled {
                    self.retryTapped()
                    return nil
                }
            }

            // ⌘C -> Copy
            if flags == .command && event.charactersIgnoringModifiers == "c" {
                if self.copyButton.isEnabled {
                    self.copyTapped()
                    return nil
                }
            }

            // ⌥↩ -> Replace & Copy
            if flags.contains(.option) && (event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)) {
                if self.replaceAndCopyButton.isEnabled {
                    self.replaceAndCopyTapped()
                    return nil
                }
            }

            switch Int(event.keyCode) {
            case kVK_Escape:
                self.cancelTapped()
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if self.replaceButton.isEnabled, flags.isEmpty {
                    self.replaceTapped()
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    @objc private func kindChanged() {
        guard let raw = kindPopup.selectedItem?.representedObject as? String,
              let next = AITransformKind.named(raw),
              next != kind else { return }
        kind = next
        beginTransform()
    }

    @objc private func toneChanged() {
        switch tonePopup.indexOfSelectedItem {
        case 1: toneInstruction = "Maintain a formal, authoritative, and professional tone."
        case 2: toneInstruction = "Maintain a friendly, conversational, and casual tone."
        case 3: toneInstruction = "Be highly concise, punchy, and to the point."
        default: toneInstruction = nil
        }
        beginTransform()
    }

    @objc private func replaceTapped() {
        guard !resultText.isEmpty else { return }
        onReplace(resultText, sourceApp)
    }

    @objc private func replaceAndCopyTapped() {
        guard !resultText.isEmpty else { return }
        let didWrite = clipboardWriter(resultText)
        onReplace(resultText, sourceApp)
        if !didWrite {
            ToastPanel.show(loc.s("clipboard.write.failed"), symbol: "xmark.circle.fill", preempt: true)
        }
    }

    @objc private func copyTapped() {
        guard !resultText.isEmpty else { return }
        if clipboardWriter(resultText) {
            ToastPanel.show(loc.s("ai.preview.copy"), symbol: "doc.on.doc.fill")
        } else {
            ToastPanel.show(loc.s("clipboard.write.failed"), symbol: "xmark.circle.fill", preempt: true)
        }
    }

    @objc private func retryTapped() {
        beginTransform()
    }

    @objc private func diffTapped() {
        guard !resultText.isEmpty else { return }
        showingDiff.toggle()
        if showingDiff {
            diffButton.title = loc.s("ai.preview.result")
            textView.textStorage?.setAttributedString(Self.diffAttributed(from: input, to: resultText))
        } else {
            diffButton.title = loc.s("ai.preview.diff")
            textView.string = resultText
        }
    }

    @objc private func cancelTapped() {
        onCancel()
    }

    /// Line-oriented red/green diff for proofread review.
    private static func diffAttributed(from original: String, to updated: String) -> NSAttributedString {
        let oldLines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = updated.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let out = NSMutableAttributedString()
        let base = [NSAttributedString.Key.font: DevTypeTheme.font(12)]
        let del: [NSAttributedString.Key: Any] = [
            .font: DevTypeTheme.font(12),
            .foregroundColor: NSColor.systemRed,
            .backgroundColor: NSColor.systemRed.withAlphaComponent(0.12)
        ]
        let add: [NSAttributedString.Key: Any] = [
            .font: DevTypeTheme.font(12),
            .foregroundColor: NSColor.systemGreen,
            .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.12)
        ]
        let diff = newLines.difference(from: oldLines)
        for change in diff {
            switch change {
            case .remove(_, let element, _):
                out.append(NSAttributedString(string: "− \(element)\n", attributes: del))
            case .insert(_, let element, _):
                out.append(NSAttributedString(string: "+ \(element)\n", attributes: add))
            }
        }
        if out.length == 0 {
            out.append(NSAttributedString(string: updated, attributes: base))
        }
        return out
    }
}
