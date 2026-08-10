import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// Streaming preview for an AI transform result.
///
/// Spinner until the first non-nil snapshot (~1.4s prefill), then streamed text.
/// Buttons: Replace / Copy / Retry / Cancel. Cancel discards the pending result
/// (generation may continue) and closes — late completions must not inject.
enum AIPreviewPanel {
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private static var panel: NSPanel?
    private static var controller: AIPreviewController?
    /// This panel's claim on matching being suspended — see `EventTapEngine.MatchingSuspension`.
    private static var suspension: EventTapEngine.MatchingSuspension?
    private static var dismissMonitors: [Any] = []
    private static var dismissObservers: [NSObjectProtocol] = []
    /// Bumped on close so late partials / completions ignore a dismissed panel.
    private static var generationToken = UUID()
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
        onReplace: @escaping (String, NSRunningApplication?) -> Void
    ) {
        if isOpen { close(discard: true) }
        open(
            input: input,
            kind: kind,
            sourceApp: sourceApp,
            customInstructions: customInstructions,
            restoreOnCancel: restoreOnCancel,
            loc: loc,
            onReplace: onReplace
        )
    }

    static func close(discard: Bool = true, resumeMatching: Bool = true) {
        let token = UUID()
        generationToken = token
        controller?.teardown(discard: discard)
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        DevTypeTheme.styleFloatingPanel(panel)
        panel.becomesKeyOnlyIfNeeded = false

        let controller = AIPreviewController(
            input: input,
            kind: kind,
            sourceApp: sourceApp,
            customInstructions: customInstructions,
            loc: loc,
            isCurrent: { token == Self.generationToken && Self.panel != nil },
            onReplace: { text, app in
                // Successful replace — do not reinject the typed trigger.
                pendingRestoreOnCancel = nil
                pendingRestoreSourceApp = nil
                AIUndoStore.stash(input)
                close(discard: false, resumeMatching: true)
                onReplace(text, app)
            },
            onCancel: {
                restoreErasedTriggerAndClose()
            }
        )
        panel.contentView = controller.view
        positionNearTop(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        animateIn(panel)

        self.panel = panel
        self.controller = controller
        installDismissWatchers(for: panel)
        controller.startGeneration()
    }

    /// Cancel / outside-dismiss: reinject the erased typed trigger via `erasePlan: .empty`.
    private static func restoreErasedTriggerAndClose() {
        let restore = pendingRestoreOnCancel
        let app = pendingRestoreSourceApp
        pendingRestoreOnCancel = nil
        pendingRestoreSourceApp = nil
        close(discard: true, resumeMatching: true)
        if let restore, !restore.isEmpty {
            EventTapEngine.shared.injectAITransformResult(
                text: restore,
                sourceApp: app,
                completion: nil
            )
        } else {
            app?.activate()
        }
    }

    private static func installDismissWatchers(for panel: NSPanel) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        let local = NSEvent.addLocalMonitorForEvents(matching: clicks) { event in
            if event.window !== panel { dismissFromOutsideInteraction() }
            return event
        }
        if let local { dismissMonitors.append(local) }

        let global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { _ in
            dismissFromOutsideInteraction()
        }
        if let global { dismissMonitors.append(global) }

        DispatchQueue.main.async {
            guard self.panel === panel else { return }
            dismissObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: panel,
                    queue: .main
                ) { _ in dismissFromOutsideInteraction() }
            )
        }
    }

    private static func removeDismissWatchers() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
        dismissObservers.forEach(NotificationCenter.default.removeObserver)
        dismissObservers.removeAll()
    }

    private static func dismissFromOutsideInteraction() {
        guard panel != nil else { return }
        restoreErasedTriggerAndClose()
    }

    private static func animateIn(_ panel: NSPanel) {
        let finalFrame = panel.frame
        guard !DevTypeAccessibility.reduceMotion else {
            panel.alphaValue = 1
            panel.setFrame(finalFrame, display: true)
            return
        }
        let startFrame = finalFrame.insetBy(dx: 12, dy: 8).offsetBy(dx: 0, dy: -10)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    private static func positionNearTop(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - frame.height / 3 - size.height / 2
        ))
    }
}

// MARK: - Controller

private final class AIPreviewController: NSViewController {
    private let input: String
    private var kind: AITransformKind
    private let sourceApp: NSRunningApplication?
    private var customInstructions: String?
    private let loc: LocalizationManager
    private let isCurrent: () -> Bool
    private let onReplace: (String, NSRunningApplication?) -> Void
    private let onCancel: () -> Void

    private var discardHandle: AITransformDiscardHandle?
    private var resultText = ""
    private var keyMonitor: Any?
    private var showingDiff = false

    private let spinner = NSProgressIndicator()
    private let waitingLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(12), color: DevTypeTheme.textTertiary)
    private let textView = NSTextView()
    private var scrollView = NSScrollView()
    private var replaceButton: CapsuleButton!
    private var copyButton: CapsuleButton!
    private var retryButton: CapsuleButton!
    private var diffButton: CapsuleButton!
    private var kindPopup: NSPopUpButton!
    private var titleLabel: NSTextField!
    private var errorLabel = DevTypeTheme.makeLabel("", font: DevTypeTheme.font(11), color: DevTypeTheme.statusOrange)

    init(
        input: String,
        kind: AITransformKind,
        sourceApp: NSRunningApplication?,
        customInstructions: String?,
        loc: LocalizationManager,
        isCurrent: @escaping () -> Bool,
        onReplace: @escaping (String, NSRunningApplication?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.input = input
        self.kind = kind
        self.sourceApp = sourceApp
        self.customInstructions = customInstructions
        self.loc = loc
        self.isCurrent = isCurrent
        self.onReplace = onReplace
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func teardown(discard: Bool) {
        if discard {
            discardHandle?.discard()
        }
        discardHandle = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    override func loadView() {
        let glass = GlassContainerView(
            cornerRadius: DevTypeTheme.Radius.panel,
            tint: DevTypeTheme.accent.withAlphaComponent(0.10),
            material: .popover
        )
        glass.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        let root = glass.contentView

        let badge = IconBadgeView(symbol: "sparkles", tint: DevTypeTheme.accent, size: 32, pointSize: 14)
        titleLabel = DevTypeTheme.makeLabel(
            loc.s(kind.localizationKey),
            font: DevTypeTheme.font(14, .bold),
            color: DevTypeTheme.textPrimary
        )
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let subtitleLabel = DevTypeTheme.makeLabel(
            loc.s("ai.preview.subtitle"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary
        )
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

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

        let headerText = NSStackView(views: [titleLabel, subtitleLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 1
        headerText.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(badge)
        root.addSubview(headerText)
        root.addSubview(kindPopup)

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
        textView.setAccessibilityLabel(loc.s("ai.preview.result"))
        scrollView.documentView = textView
        root.addSubview(scrollView)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 3
        root.addSubview(errorLabel)

        let hairline = DevTypeTheme.makeHairline()
        root.addSubview(hairline)

        let cancel = CapsuleButton(
            title: loc.s("common.cancel"),
            style: .secondary,
            target: self,
            action: #selector(cancelTapped)
        )
        cancel.keyEquivalent = "\u{1b}"

        retryButton = CapsuleButton(
            title: loc.s("common.retry"),
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
            title: loc.s("ai.preview.copy"),
            style: .secondary,
            target: self,
            action: #selector(copyTapped)
        )
        copyButton.isEnabled = false

        replaceButton = CapsuleButton(
            title: loc.s("ai.preview.replace"),
            symbol: "checkmark",
            style: .primary,
            target: self,
            action: #selector(replaceTapped)
        )
        replaceButton.keyEquivalent = "\r"
        replaceButton.isEnabled = false

        root.addSubview(cancel)
        root.addSubview(diffButton)
        root.addSubview(retryButton)
        root.addSubview(copyButton)
        root.addSubview(replaceButton)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            headerText.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            headerText.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            kindPopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            kindPopup.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            kindPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            headerText.trailingAnchor.constraint(lessThanOrEqualTo: kindPopup.leadingAnchor, constant: -8),

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
            hairline.bottomAnchor.constraint(equalTo: cancel.topAnchor, constant: -12),

            cancel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            replaceButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            replaceButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            copyButton.trailingAnchor.constraint(equalTo: replaceButton.leadingAnchor, constant: -8),
            copyButton.bottomAnchor.constraint(equalTo: replaceButton.bottomAnchor),
            retryButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            retryButton.bottomAnchor.constraint(equalTo: replaceButton.bottomAnchor),
            diffButton.trailingAnchor.constraint(equalTo: retryButton.leadingAnchor, constant: -8),
            diffButton.bottomAnchor.constraint(equalTo: replaceButton.bottomAnchor)
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
        discardHandle?.discard()
        discardHandle = nil
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
        replaceButton.isEnabled = false
        copyButton.isEnabled = false
        retryButton.isEnabled = false
        diffButton.isEnabled = false
        diffButton.isHidden = kind != .proofread
        diffButton.title = loc.s("ai.preview.diff")
        titleLabel.stringValue = loc.s(kind.localizationKey)

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            discardHandle = AITextTransformer.shared.transformStreaming(
                kind: kind,
                input: input,
                customInstructions: customInstructions,
                onPartial: { [weak self] partial in
                    Task { @MainActor in
                        self?.applyPartial(partial)
                    }
                },
                completionQueue: .main
            ) { [weak self] result in
                Task { @MainActor in
                    self?.applyCompletion(result)
                }
            }
            return
        }
        #endif
        applyCompletion(.failure(.unavailable(.unsupportedOS)))
    }

    private func applyPartial(_ partial: String?) {
        guard isCurrent() else { return }
        guard let partial else { return }
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
        // Replace / Copy stay disabled until the stream finishes: Return is bound to
        // Replace, and a fast Return over a half-streamed snapshot injects truncated
        // text. The failure path below re-enables them for a partial worth keeping.
    }

    private func applyCompletion(_ result: Result<String, AITransformError>) {
        guard isCurrent() else { return }
        discardHandle = nil
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        waitingLabel.isHidden = true
        retryButton.isEnabled = true

        switch result {
        case .success(let text):
            resultText = text
            scrollView.isHidden = false
            textView.string = text
            replaceButton.isEnabled = !text.isEmpty
            copyButton.isEnabled = !text.isEmpty
            diffButton.isEnabled = kind == .proofread && text != input && !text.isEmpty
            errorLabel.isHidden = true
        case .failure(let error):
            if case .discarded = error { return }
            errorLabel.stringValue = AITransformFlow.localizedError(error, loc: loc)
            errorLabel.isHidden = false
            if resultText.isEmpty {
                scrollView.isHidden = true
            }
            replaceButton.isEnabled = !resultText.isEmpty
            copyButton.isEnabled = !resultText.isEmpty
            diffButton.isEnabled = kind == .proofread && !resultText.isEmpty && resultText != input
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.cancelTapped()
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if self.replaceButton.isEnabled,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
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
        customInstructions = nil
        beginTransform()
    }

    @objc private func replaceTapped() {
        guard !resultText.isEmpty else { return }
        onReplace(resultText, sourceApp)
    }

    @objc private func copyTapped() {
        guard !resultText.isEmpty else { return }
        PasteboardBroker.shared.writeUserClipboardString(resultText)
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

