import AppKit
import ExpanderEngine

/// Canonical Advanced-pane projection for deferred Keychain cleanup debt. Reloading the pane must
/// render both branches: otherwise a successful automatic retry leaves an earlier red failure (or
/// unrelated maintenance result) on screen even though the store has returned to a healthy state.
struct SecretCleanupMaintenancePresentation: Equatable {
    let text: String
    let isWarning: Bool

    static func resolve(
        pendingCount: Int,
        localization: LocalizationManager = .shared
    ) -> SecretCleanupMaintenancePresentation {
        let pending = max(0, pendingCount)
        guard pending > 0 else {
            return SecretCleanupMaintenancePresentation(
                text: localization.s("prefs.advanced.secretCleanup.none"),
                isWarning: false
            )
        }
        return SecretCleanupMaintenancePresentation(
            text: localization.s("prefs.advanced.secretCleanup.failed", pending),
            isWarning: true
        )
    }
}

/// Keeps the pasteboard's Boolean result attached to the visible status and semantic tint.
struct AdvancedDiagnosticsCopyPresentation: Equatable {
    enum TintRole: Equatable { case success, failure }

    let statusKey: String
    let tintRole: TintRole

    static func resolve(didWrite: Bool) -> Self {
        didWrite
            ? Self(statusKey: "prefs.advanced.copied", tintRole: .success)
            : Self(statusKey: "prefs.advanced.copyFailed", tintRole: .failure)
    }
}

// MARK: - Advanced (§2.10 / §3.9 / §3.2 / §3.7 readouts)

/// Engine diagnostics and library / Keychain maintenance.
final class AdvancedPreferencesViewController: PreferencesPaneViewController {

    /// Runs after a library reset, whose result the Snippets tab must reflect.
    var onLibraryReset: (() -> Void)?

    private let tapThreadSwitch = NSSwitch()
    private let advancedReadout = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.mono(10.5),
        color: DevTypeTheme.textSecondary,
        wrapping: true
    )
    private let maintenanceStatus = DevTypeTheme.makeLabel(
        "",
        font: DevTypeTheme.font(11),
        color: DevTypeTheme.statusGreen,
        wrapping: true
    )
    private var secretCleanupButton: NSButton?
    private var repairSecretStorageButton: NSButton?

    override func build(into stack: NSStackView) {
        let engineCard = makeCard(title: loc.s("prefs.advanced.engine"), symbol: "bolt.fill")
        let threadRow = makeToggleRow(
            title: loc.s("prefs.advanced.tapThread"),
            toggle: tapThreadSwitch,
            action: #selector(tapThreadChanged)
        )
        let threadHint = DevTypeTheme.makeLabel(
            loc.s("prefs.advanced.tapThread.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        threadHint.translatesAutoresizingMaskIntoConstraints = false
        advancedReadout.translatesAutoresizingMaskIntoConstraints = false
        let copyButton = CapsuleButton(
            title: loc.s("prefs.advanced.copyDiagnostics"),
            symbol: "doc.on.doc",
            style: .secondary,
            target: self,
            action: #selector(copyAdvancedDiagnostics)
        )
        stackInCard(engineCard, views: [threadRow, threadHint, advancedReadout, copyButton])

        let maintenanceCard = makeCard(title: loc.s("prefs.advanced.maintenance"), symbol: "arrow.counterclockwise")
        maintenanceStatus.translatesAutoresizingMaskIntoConstraints = false
        let retrySecretCleanupButton = CapsuleButton(
            title: loc.s("prefs.advanced.secretCleanup.retry"),
            symbol: "key",
            style: .secondary,
            target: self,
            action: #selector(retrySecretCleanup)
        )
        secretCleanupButton = retrySecretCleanupButton
        // The one place a user can ask for the interactive keychain pass. `migrateLegacy` already
        // repairs every account needing authorization, but its only other caller gates on snippet
        // IDs, so an unreadable master key had no reachable repair at all.
        let repairButton = CapsuleButton(
            title: loc.s("prefs.advanced.secretRepair"),
            symbol: "wrench.and.screwdriver",
            style: .secondary,
            target: self,
            action: #selector(repairSecretStorage)
        )
        repairSecretStorageButton = repairButton
        let maintenanceButtons = NSStackView(views: [
            CapsuleButton(
                title: loc.s("prefs.advanced.orphans"),
                symbol: "trash",
                style: .secondary,
                target: self,
                action: #selector(collectOrphans)
            ),
            retrySecretCleanupButton,
            repairButton,
            CapsuleButton(
                title: loc.s("prefs.advanced.reset"),
                symbol: "arrow.counterclockwise",
                style: .destructive,
                target: self,
                action: #selector(resetLibrary)
            )
        ])
        maintenanceButtons.orientation = .horizontal
        maintenanceButtons.spacing = 8
        maintenanceButtons.translatesAutoresizingMaskIntoConstraints = false
        stackInCard(maintenanceCard, views: [maintenanceButtons, maintenanceStatus])

        stack.addArrangedSubview(engineCard)
        stack.addArrangedSubview(maintenanceCard)
        pinWidth(of: [engineCard, maintenanceCard], to: stack)
    }

    override func reload() {
        tapThreadSwitch.state = EventTapEngine.useDedicatedTapThread ? .on : .off
        var lines: [String] = []
        lines.append(EventTapEngine.shared.tapDisableCounters.summaryLine)
        let telemetry = PermissionCoordinator.shared.injectTelemetrySummaryLines()
        lines.append(contentsOf: telemetry)
        lines.append(EventTapEngine.shared.prefixDebounceDiagnostics())
        let overlong = EventTapEngine.shared.overlongTriggerDiagnostics()
        if overlong.isEmpty {
            lines.append(loc.s("prefs.advanced.overlong.none"))
        } else {
            lines.append(contentsOf: overlong)
        }
        advancedReadout.stringValue = lines.joined(separator: "\n")
        let cleanup = SecretCleanupMaintenancePresentation.resolve(
            pendingCount: store.pendingSecretCleanupCount,
            localization: loc
        )
        maintenanceStatus.stringValue = cleanup.text
        maintenanceStatus.textColor = cleanup.isWarning
            ? DevTypeTheme.accentBright
            : DevTypeTheme.statusGreen
    }

    override var refreshesOnSelect: Bool { true }

    @objc private func tapThreadChanged() {
        let enabled = tapThreadSwitch.state == .on
        EventTapEngine.useDedicatedTapThread = enabled
        UserDefaults.standard.set(enabled, forKey: EventTapEngine.useDedicatedTapThreadDefaultsKey)
        reload()
    }

    @objc private func copyAdvancedDiagnostics() {
        let didWrite = DiagnosticReport.copyToPasteboard(advancedReadout.stringValue)
        let presentation = AdvancedDiagnosticsCopyPresentation.resolve(didWrite: didWrite)
        maintenanceStatus.stringValue = loc.s(presentation.statusKey)
        maintenanceStatus.textColor = presentation.tintRole == .success
            ? DevTypeTheme.statusGreen
            : DevTypeTheme.accentBright
    }

    @objc private func collectOrphans() {
        let removed = store.collectOrphanedImages(dryRun: false)
        maintenanceStatus.stringValue = removed.isEmpty
            ? loc.s("prefs.advanced.orphans.none")
            : loc.s("prefs.advanced.orphans.result", removed.count)
        maintenanceStatus.textColor = DevTypeTheme.statusGreen
    }

    /// Offers the one-time system password dialogs, then runs the only interactive keychain pass
    /// in the app. Explained first and never automatic: a keychain prompt the user did not ask for
    /// is exactly what `SecretMenuFlow` refuses to produce.
    @objc private func repairSecretStorage() {
        let pending = SecretStore.shared.accountsNeedingAuthorizationCount()
        guard pending > 0 else {
            maintenanceStatus.stringValue = loc.s("prefs.advanced.secretRepair.none")
            maintenanceStatus.textColor = DevTypeTheme.statusGreen
            return
        }
        DevTypeAlert.present(
            title: loc.s("prefs.advanced.secretRepair.title"),
            message: loc.s("prefs.advanced.secretRepair.message", "\(pending)"),
            buttons: [loc.s("secret.migrate.continue"), loc.s("common.cancel")]
        ) { [weak self] index in
            guard let self, index == 0 else { return }
            self.repairSecretStorageButton?.isEnabled = false
            self.maintenanceStatus.stringValue = self.loc.s("prefs.advanced.secretRepair.running")
            self.maintenanceStatus.textColor = DevTypeTheme.textSecondary
            let summary = SecretStore.shared.migrateLegacy(allowInteraction: true)
            self.repairSecretStorageButton?.isEnabled = true
            let outstanding = summary.needsUser + summary.failed
            if outstanding > 0 {
                self.maintenanceStatus.stringValue = self.loc.s(
                    "prefs.advanced.secretRepair.partial",
                    "\(outstanding)"
                )
                self.maintenanceStatus.textColor = DevTypeTheme.accentBright
            } else {
                self.maintenanceStatus.stringValue = self.loc.s(
                    "prefs.advanced.secretRepair.result",
                    "\(summary.migrated)"
                )
                self.maintenanceStatus.textColor = DevTypeTheme.statusGreen
            }
        }
    }

    @objc private func retrySecretCleanup() {
        secretCleanupButton?.isEnabled = false
        maintenanceStatus.stringValue = loc.s("prefs.advanced.secretCleanup.running")
        maintenanceStatus.textColor = DevTypeTheme.textSecondary
        let store = self.store
        store.requestOrphanSecretCleanupRetry { [weak self] summary in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.secretCleanupButton?.isEnabled = true
                if summary.pending > 0 {
                    self.maintenanceStatus.stringValue = self.loc.s(
                        "prefs.advanced.secretCleanup.failed",
                        summary.pending
                    )
                    self.maintenanceStatus.textColor = DevTypeTheme.accentBright
                } else if summary.removed > 0 {
                    self.maintenanceStatus.stringValue = self.loc.s(
                        "prefs.advanced.secretCleanup.result",
                        summary.removed
                    )
                    self.maintenanceStatus.textColor = DevTypeTheme.statusGreen
                } else {
                    self.maintenanceStatus.stringValue = self.loc.s(
                        "prefs.advanced.secretCleanup.none"
                    )
                    self.maintenanceStatus.textColor = DevTypeTheme.statusGreen
                }
            }
        }
    }

    @objc private func resetLibrary() {
        DevTypeAlert.confirm(
            title: loc.s("alert.reset.title"),
            message: loc.s("alert.reset.message"),
            confirmTitle: loc.s("alert.reset.confirm"),
            destructive: true,
            window: view.window
        ) { [weak self] in
            guard let self else { return }
            let result = self.store.resetToDefaults()
            let completion = SnippetManagerMutationCommitter.finish(
                result,
                deleteImage: { path in
                    let cleanup = self.store.deleteImageIfUnreferenced(path) { candidate in
                        if case .success = SnippetEditResourceAccess.live.deleteImage(candidate) {
                            return true
                        }
                        return false
                    }
                    return cleanup == .removed || cleanup == .retainedReferenced
                }
            )
            switch completion {
            case .committed(_, let cleanupFailures):
                if cleanupFailures == 0 {
                    self.maintenanceStatus.stringValue = self.loc.s("prefs.advanced.reset.done")
                    self.maintenanceStatus.textColor = DevTypeTheme.statusGreen
                } else {
                    self.maintenanceStatus.stringValue = self.loc.s(
                        "manager.resources.cleanupFailed.message",
                        cleanupFailures
                    )
                    self.maintenanceStatus.textColor = DevTypeTheme.accentBright
                }
            case .refused:
                LibraryHealthMonitor.shared.refresh()
                self.maintenanceStatus.stringValue = self.loc.s("library.save.banner")
                self.maintenanceStatus.textColor = DevTypeTheme.accentBright
            case .unchanged:
                self.maintenanceStatus.stringValue = self.loc.s("prefs.advanced.reset.done")
                self.maintenanceStatus.textColor = DevTypeTheme.statusGreen
            case .stale:
                self.maintenanceStatus.stringValue = self.loc.s("manager.action.stale.message")
                self.maintenanceStatus.textColor = DevTypeTheme.accentBright
            }
            self.onLibraryReset?()
        }
    }
}
