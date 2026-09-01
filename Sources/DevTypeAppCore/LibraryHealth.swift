import AppKit
import ExpanderEngine

// MARK: - §0.3 / §1.4 (UI half) — honest library state
//
// `AppDelegate.presentCorruptionAlertIfNeeded` used to say the library "was
// replaced with defaults", because the store really did `writeGroupsToDisk(
// defaults, force: true)` on a failed load. That is no longer true: the store
// refuses to overwrite and latches a blocked state, so the old copy was both a
// lie and a dead end (the user had no way to retry or to accept defaults).
//
// This file replaces it with three surfaces:
//
//   1. `LibraryHealthMonitor` — one place that knows whether the library is
//      unreadable (`isLibraryReadFailed`), whether the last write was refused
//      (`lastSaveFailure`), or whether iCloud has unresolved conflict versions
//      (`unresolvedConflicts()`), and pushes changes to observers.
//   2. `LibraryHealthBannerView` — a non-modal banner the manager window hosts,
//      with the recovery actions inline.
//   3. `LibraryHealthPresenter` — the modal escalations: Reveal Backup, Retry,
//      Overwrite-with-defaults, and the iCloud keep-local / keep-remote choice.

// MARK: - Condition

enum LibraryCondition {
    /// The file could not be read at all. Saving is latched off.
    case readBlocked(reason: String)
    /// The file decoded but a backup was written (legacy `corrupted` issue).
    case corrupted(backupURL: URL)
    /// The file is present but zero bytes.
    case emptyFile(path: String)
    /// A save was refused or failed.
    case saveFailed(SnippetStore.SaveOutcome)
    /// iCloud has unresolved conflict versions.
    case conflicts([SnippetStore.ConflictVersion])

    var bannerText: String {
        let loc = LocalizationManager.shared
        switch self {
        case .readBlocked:
            return loc.s("library.blocked.banner")
        case .corrupted:
            return loc.s("library.corrupted.title")
        case .emptyFile:
            return loc.s("library.empty.title")
        case .saveFailed:
            return loc.s("library.save.banner")
        case .conflicts(let versions):
            return loc.s("library.conflict.banner", versions.count)
        }
    }

    /// Blocking conditions get the accent treatment; advisory ones get orange.
    var isBlocking: Bool {
        switch self {
        case .readBlocked, .saveFailed, .conflicts: return true
        case .corrupted, .emptyFile: return false
        }
    }
}

// MARK: - Monitor

/// Watches the store for the three failure channels and republishes them as one
/// `LibraryCondition?`. Observers are called on the main queue.
final class LibraryHealthMonitor {
    static let shared = LibraryHealthMonitor()

    private let store: SnippetStore
    private var observers: [UUID: (LibraryCondition?) -> Void] = [:]
    private var saveToken: UUID?
    private var conflictToken: UUID?
    private var started = false

    /// Latest condition, or nil when the library is healthy.
    private(set) var condition: LibraryCondition?

    /// Backup URL from the most recent `corrupted` load issue, if any.
    private(set) var lastBackupURL: URL?

    init(store: SnippetStore = .shared) {
        self.store = store
    }

    /// Call once from `applicationDidFinishLaunching`, after the store exists.
    func start() {
        guard !started else { return }
        started = true

        // §0.3: consume whatever the load reported. Unlike the old flow this
        // does *not* imply the file was replaced.
        if let issue = store.consumeLastLoadIssue() {
            switch issue {
            case .corrupted(let backupURL):
                lastBackupURL = backupURL
                condition = .corrupted(backupURL: backupURL)
            case .unreadable(let path, let reason):
                condition = .readBlocked(reason: "\(path)\n\(reason)")
            case .emptyFile(let path):
                condition = .emptyFile(path: path)
            case .conflicted:
                condition = .conflicts(store.unresolvedConflicts())
            }
        }

        // §1.4: blocked saves used to be discarded at every call site, so the UI
        // reported success for writes that never landed.
        saveToken = store.addSaveFailureListener { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                if let outcome, outcome != .saved {
                    self.publish(.saveFailed(outcome))
                } else if self.isShowing(.saveFailedKind) {
                    self.publish(nil)
                }
            }
        }

        // §1.13: iCloud conflict versions are now surfaced instead of clobbered.
        conflictToken = store.addConflictListener { [weak self] versions in
            DispatchQueue.main.async {
                guard let self else { return }
                if versions.isEmpty {
                    if self.isShowing(.conflictsKind) { self.publish(nil) }
                } else {
                    self.publish(.conflicts(versions))
                }
            }
        }

        refresh()
    }

    /// Re-derives the condition from the store's current state.
    func refresh() {
        if store.isLibraryReadFailed {
            let reason = store.libraryReadFailureReason ?? store.activeLocationURL.path
            publish(.readBlocked(reason: reason))
            return
        }
        let conflicts = store.unresolvedConflicts()
        if !conflicts.isEmpty {
            publish(.conflicts(conflicts))
            return
        }
        if let failure = store.lastSaveFailure, failure != .saved {
            publish(.saveFailed(failure))
            return
        }
        // Corrupted / empty stay sticky until the user dismisses them.
        if isShowing(.corruptedKind) || isShowing(.emptyFileKind) { return }
        publish(nil)
    }

    func dismiss() {
        publish(nil)
    }

    /// Payload-free discriminator, so callers can ask "is the banner currently
    /// showing X?" without pattern-matching an optional with associated values.
    enum Kind {
        case readBlockedKind
        case corruptedKind
        case emptyFileKind
        case saveFailedKind
        case conflictsKind
    }

    private func isShowing(_ kind: Kind) -> Bool {
        guard let condition else { return false }
        switch condition {
        case .readBlocked: return kind == .readBlockedKind
        case .corrupted: return kind == .corruptedKind
        case .emptyFile: return kind == .emptyFileKind
        case .saveFailed: return kind == .saveFailedKind
        case .conflicts: return kind == .conflictsKind
        }
    }

    private func publish(_ newValue: LibraryCondition?) {
        condition = newValue
        for observer in observers.values { observer(newValue) }
    }

    @discardableResult
    func addObserver(_ observer: @escaping (LibraryCondition?) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        observer(condition)
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }
}

// MARK: - Banner

/// Non-modal strip shown above the snippet list while the library is unhealthy.
/// §5.1: the whole strip is one AX element with a spoken label; §5.2: it pairs a
/// warning glyph with the tint so it does not rely on colour alone.
final class LibraryHealthBannerView: NSView {
    private let iconView = NSImageView()
    private let messageLabel = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11.5, .semibold),
        color: DevTypeTheme.textPrimary,
        wrapping: true
    )
    private let actionButton: CapsuleButton
    private let dismissButton: CapsuleButton
    private var onAction: (() -> Void)?
    private var onDismiss: (() -> Void)?
    /// Owned here so a hidden banner collapses to zero height instead of leaving
    /// a 40pt gap above the list (hidden views keep their constraints).
    private var heightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        let loc = LocalizationManager.shared
        actionButton = CapsuleButton(
            title: loc.s("library.banner.details"),
            style: .primary,
            target: nil,
            action: nil
        )
        dismissButton = CapsuleButton(
            title: loc.s("library.banner.dismiss"),
            style: .secondary,
            target: nil,
            action: nil
        )
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = DevTypeTheme.Radius.control
        layer?.borderWidth = 1

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.maximumNumberOfLines = 2

        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        dismissButton.target = self
        dismissButton.action = #selector(dismissTapped)

        addSubview(iconView)
        addSubview(messageLabel)
        addSubview(actionButton)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            messageLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -10),

            actionButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        let height = heightAnchor.constraint(equalToConstant: 0)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height

        dtApplyAccessibility(role: NSAccessibility.Role.group)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Applies a condition, or hides the banner when `condition` is nil.
    func apply(
        _ condition: LibraryCondition?,
        onAction: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        guard let condition else {
            isHidden = true
            heightConstraint?.constant = 0
            setAccessibilityElement(false)
            return
        }
        self.onAction = onAction
        self.onDismiss = onDismiss
        isHidden = false
        heightConstraint?.constant = 40
        setAccessibilityElement(true)

        let tint = condition.isBlocking ? DevTypeTheme.accent : DevTypeTheme.statusOrange
        layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.42).cgColor
        // §5.2: glyph + text, not colour alone.
        iconView.image = DevTypeTheme.tintedSymbol(
            "exclamationmark.triangle.fill",
            size: 13,
            weight: .bold,
            color: tint
        )
        let text = condition.bannerText
        messageLabel.stringValue = text
        messageLabel.textColor = DevTypeTheme.textPrimary
        setAccessibilityLabel(text)
        setAccessibilityRole(NSAccessibility.Role.group)
    }

    @objc private func actionTapped() { onAction?() }
    @objc private func dismissTapped() { onDismiss?() }
}

// MARK: - Modal escalations

enum LibraryHealthPresenter {

    /// Opens the full recovery flow for whatever condition is current.
    static func present(
        _ condition: LibraryCondition,
        window: NSWindow?,
        store: SnippetStore = .shared
    ) {
        switch condition {
        case .readBlocked(let reason):
            presentReadBlocked(reason: reason, window: window, store: store)
        case .corrupted(let backupURL):
            presentCorrupted(backupURL: backupURL, window: window)
        case .emptyFile(let path):
            presentEmptyFile(path: path, window: window, store: store)
        case .saveFailed(let outcome):
            presentSaveFailure(outcome, window: window, store: store)
        case .conflicts(let versions):
            presentConflicts(versions, window: window, store: store)
        }
    }

    // §0.3: unreadable → Reveal Backup / Retry / Overwrite-with-defaults.
    private static func presentReadBlocked(
        reason: String,
        window: NSWindow?,
        store: SnippetStore
    ) {
        let loc = LocalizationManager.shared
        DevTypeAlert.present(
            title: loc.s("library.blocked.title"),
            message: loc.s("library.blocked.body", reason),
            style: .critical,
            buttons: [
                loc.s("library.retryRead"),
                loc.s("library.reveal"),
                loc.s("library.overwrite"),
                loc.s("common.cancel")
            ],
            window: window
        ) { index in
            switch index {
            case 0:
                retryRead(window: window, store: store)
            case 1:
                revealLibrary(store: store)
            case 2:
                confirmOverwrite(window: window, store: store)
            default:
                break
            }
        }
    }

    private static func presentCorrupted(backupURL: URL, window: NSWindow?) {
        let loc = LocalizationManager.shared
        DevTypeAlert.present(
            title: loc.s("library.corrupted.title"),
            message: loc.s("library.corrupted.body", backupURL.path),
            style: .warning,
            buttons: [loc.s("common.ok"), loc.s("common.revealInFinder")],
            window: window
        ) { index in
            if index == 1 {
                NSWorkspace.shared.activateFileViewerSelecting([backupURL])
            }
        }
    }

    private static func presentEmptyFile(
        path: String,
        window: NSWindow?,
        store: SnippetStore
    ) {
        let loc = LocalizationManager.shared
        DevTypeAlert.present(
            title: loc.s("library.empty.title"),
            message: loc.s("library.empty.body", path),
            style: .warning,
            buttons: [
                loc.s("common.ok"),
                loc.s("library.reveal"),
                loc.s("library.overwrite")
            ],
            window: window
        ) { index in
            switch index {
            case 1: revealLibrary(store: store)
            case 2: confirmOverwrite(window: window, store: store)
            default: break
            }
        }
    }

    // §1.4: blocked / failed saves get named, not swallowed.
    private static func presentSaveFailure(
        _ outcome: SnippetStore.SaveOutcome,
        window: NSWindow?,
        store: SnippetStore
    ) {
        let loc = LocalizationManager.shared
        let detail: String
        switch outcome {
        case .blockedByRemoteChange:
            detail = loc.s("library.save.blockedRemote")
        case .blockedByNewerSchema:
            detail = loc.s("library.save.blockedSchema")
        case .failed(let reason):
            detail = loc.s("library.save.failed", reason)
        case .saved:
            return
        }
        DevTypeAlert.present(
            title: loc.s("library.save.title"),
            message: detail,
            style: .warning,
            buttons: [loc.s("library.save.reload"), loc.s("common.ok")],
            window: window
        ) { index in
            guard index == 0 else { return }
            store.acknowledgeSaveFailure()
            store.clearLibraryReadFailure()
            _ = store.loadGroups()
            LibraryHealthMonitor.shared.refresh()
        }
    }

    // §1.13: keep-mine / keep-theirs instead of a silent overwrite.
    private static func presentConflicts(
        _ versions: [SnippetStore.ConflictVersion],
        window: NSWindow?,
        store: SnippetStore
    ) {
        let loc = LocalizationManager.shared
        var detail = loc.s("library.conflict.body", versions.count)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        for version in versions {
            let device = version.deviceName ?? "—"
            let date = version.modificationDate.map { formatter.string(from: $0) } ?? "—"
            detail += "\n• \(device) — \(date)"
        }
        DevTypeAlert.present(
            title: loc.s("library.conflict.title"),
            message: detail,
            style: .warning,
            buttons: [
                loc.s("library.conflict.keepLocal"),
                loc.s("library.conflict.keepRemote"),
                loc.s("common.cancel")
            ],
            window: window
        ) { index in
            switch index {
            case 0:
                let outcome = store.resolveConflictsKeepingLocal()
                DevTypeLog.app.notice(
                    "[Library] conflict resolved keeping local saved=\(outcome.didSave, privacy: .public)"
                )
            case 1:
                let ok = store.resolveConflictsKeepingRemote()
                DevTypeLog.app.notice(
                    "[Library] conflict resolved keeping remote ok=\(ok, privacy: .public)"
                )
            default:
                return
            }
            LibraryHealthMonitor.shared.refresh()
        }
    }

    // MARK: Actions

    private static func retryRead(window: NSWindow?, store: SnippetStore) {
        let loc = LocalizationManager.shared
        store.clearLibraryReadFailure()
        _ = store.loadGroups()
        LibraryHealthMonitor.shared.refresh()
        if store.isLibraryReadFailed {
            DevTypeAlert.warn(
                title: loc.s("library.blocked.title"),
                message: loc.s(
                    "library.retry.failed",
                    store.libraryReadFailureReason ?? store.activeLocationURL.path
                ),
                window: window
            )
        } else {
            DevTypeAlert.info(
                title: loc.s("library.blocked.title"),
                message: loc.s("library.retry.ok"),
                window: window
            )
        }
    }

    private static func revealLibrary(store: SnippetStore) {
        let url = LibraryHealthMonitor.shared.lastBackupURL ?? store.activeLocationURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// §0.3: the store no longer force-writes defaults on its own — the user has
    /// to ask for it, and only after an explicit confirmation.
    private static func confirmOverwrite(window: NSWindow?, store: SnippetStore) {
        let loc = LocalizationManager.shared
        DevTypeAlert.confirm(
            title: loc.s("library.overwrite.confirm.title"),
            message: loc.s("library.overwrite.confirm.message"),
            confirmTitle: loc.s("library.overwrite"),
            destructive: true,
            style: .critical,
            window: window
        ) {
            let defaults = [
                SnippetGroup(
                    name: SnippetDocument.defaultGroupName,
                    snippets: store.defaultSnippets()
                )
            ]
            let outcome = store.forceOverwriteLibrary(with: defaults)
            DevTypeLog.app.notice(
                "[Library] user forced overwrite with defaults saved=\(outcome.didSave, privacy: .public)"
            )
            store.clearLibraryReadFailure()
            LibraryHealthMonitor.shared.refresh()
        }
    }
}
