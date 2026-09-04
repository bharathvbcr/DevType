import AppKit
import ExpanderEngine

/// Localized immutable copy used when a recovery window is created. `DateFormatter` otherwise
/// defaults to the system locale, which made a Japanese/Korean app session embed an English date
/// inside otherwise translated guidance.
struct RecoveredDictationPresentation: Equatable {
    let timestampText: String
    let guidance: String

    init(
        characterCount: Int,
        recordedAt: Date,
        localization: LocalizationManager = .shared
    ) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localization.effectiveLanguageCode())
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        timestampText = formatter.string(from: recordedAt)
        guidance = localization.s(
            "activity.recovery.guidance",
            max(0, characterCount),
            timestampText
        )
    }
}

/// Explicit review surface for a retained, undelivered voice session.
///
/// Activity history stores only an opaque session id and character count. The dictated text is
/// read from its protected session directory only after the user chooses Review, and remains
/// there until they explicitly delete it.
final class RecoveredDictationWindowController: NSWindowController {
    private static var controllers: [String: RecoveredDictationWindowController] = [:]

    static func show(referenceID: String, activityEventID: UUID) {
        if let existing = controllers[referenceID] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let session = VoiceRecoveryService.shared
            .recoverableUndelivered()
            .first(where: { $0.id.description == referenceID }) else {
            _ = ActivityHistoryStore.shared.remove(id: activityEventID)
            DevTypeAlert.info(
                title: LocalizationManager.shared.s("activity.recovery.unavailable.title"),
                message: LocalizationManager.shared.s("activity.recovery.unavailable.message")
            )
            return
        }

        let controller = RecoveredDictationWindowController(
            session: session,
            activityEventID: activityEventID
        )
        controllers[referenceID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let session: RecoverableVoiceSession
    private let activityEventID: UUID
    private let text: String
    private let loc = LocalizationManager.shared

    /// Internal so the AppKit contract can be exercised without scanning or mutating the real
    /// recovery directory. Production construction remains centralized in `show`.
    init(session: RecoverableVoiceSession, activityEventID: UUID) {
        self.session = session
        self.activityEventID = activityEventID
        self.text = VoiceRecoveryService.recoveredText(session)
        let presentation = RecoveredDictationPresentation(
            characterCount: text.count,
            recordedAt: session.snapshot.createdAt,
            localization: LocalizationManager.shared
        )

        let controller = NSViewController()
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DevTypeTheme.windowBackground.cgColor

        let header = DevTypeTheme.makeBrandHeader(
            title: LocalizationManager.shared.s("activity.recovery.title"),
            subtitle: LocalizationManager.shared.s("activity.recovery.subtitle"),
            logoSize: 36
        )
        let guidance = DevTypeTheme.makeLabel(
            presentation.guidance,
            font: DevTypeTheme.font(11),
            color: DevTypeTheme.textSecondary,
            wrapping: true
        )
        guidance.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = DevTypeTheme.font(13)
        textView.textColor = DevTypeTheme.textPrimary
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.setAccessibilityLabel(LocalizationManager.shared.s("activity.recovery.transcript"))

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = textView
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = DevTypeTheme.Radius.control
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = DevTypeTheme.hairline.cgColor

        let copy = CapsuleButton(
            title: LocalizationManager.shared.s("common.copy"),
            symbol: "doc.on.doc",
            style: .primary,
            target: nil,
            action: nil
        )
        let delete = CapsuleButton(
            title: LocalizationManager.shared.s("common.delete"),
            symbol: "trash",
            style: .destructive,
            target: nil,
            action: nil
        )
        let close = CapsuleButton(
            title: LocalizationManager.shared.s("common.close"),
            style: .secondary,
            target: nil,
            action: nil
        )
        let buttons = NSStackView(views: [delete, close, copy])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(guidance)
        root.addSubview(scroll)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 42),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -22),
            guidance.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            guidance.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            guidance.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            scroll.topAnchor.constraint(equalTo: guidance.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        controller.view = root

        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 460))
        window.minSize = NSSize(width: 460, height: 340)
        DevTypeTheme.styleWindow(window, title: LocalizationManager.shared.s("activity.recovery.title"))
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        copy.target = self
        copy.action = #selector(copyTranscript)
        copy.keyEquivalent = "\r"
        delete.target = self
        delete.action = #selector(deleteTranscript)
        close.target = self
        close.action = #selector(closeWindow)
        close.keyEquivalent = "\u{1b}"

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func copyTranscript() {
        if PasteboardBroker.shared.writeUserClipboardString(text) {
            ToastPanel.show(loc.s("activity.recovery.copied"), symbol: "doc.on.doc")
        } else {
            DevTypeAlert.warn(
                title: loc.s("activity.recovery.copyFailed.title"),
                message: loc.s("activity.recovery.copyFailed.message"),
                window: window
            )
        }
    }

    @objc private func deleteTranscript() {
        DevTypeAlert.confirm(
            title: loc.s("activity.recovery.delete.title"),
            message: loc.s("activity.recovery.delete.message"),
            confirmTitle: loc.s("common.delete"),
            cancelTitle: loc.s("common.cancel"),
            destructive: true,
            style: .warning,
            window: window
        ) { [weak self] in
            guard let self else { return }
            guard VoiceRecoveryService.shared.discard(self.session) else {
                DevTypeAlert.warn(
                    title: self.loc.s("activity.recovery.deleteFailed.title"),
                    message: self.loc.s("activity.recovery.deleteFailed.message"),
                    window: self.window
                )
                return
            }
            _ = ActivityHistoryStore.shared.remove(id: self.activityEventID)
            self.close()
        }
    }

    @objc private func closeWindow() { close() }

    @objc private func windowDidClose() {
        Self.controllers.removeValue(forKey: session.id.description)
    }
}
