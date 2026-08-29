import AppKit
import ExpanderEngine

/// Presentation layer for `UpdateChecker` — turns an outcome into UI.
///
/// The split is deliberate: `UpdateChecker` decides *what is true* and is fully testable without
/// a window server, while this type decides *what the user sees* and touches AppKit only.
///
/// Two entry points, with different noise budgets:
///
/// - `checkManually` — the user clicked "Check for Updates…". Every outcome gets an alert,
///   including "up to date" and every failure, because silence after an explicit request reads
///   as a broken app.
/// - `checkAutomaticallyIfDue` — a background check on launch. It speaks **only** when there is
///   an update to report. Failures are logged, never surfaced: a laptop that opened on a plane
///   must not greet its owner with a network error they did not ask for.
@MainActor
enum UpdateFlow {

    private static var isChecking = false

    private static var loc: LocalizationManager { .shared }

    // MARK: - Manual

    /// Runs a check in response to an explicit user action and reports every outcome.
    static func checkManually(window: NSWindow? = nil) {
        // A second click while the first request is in flight would stack a second alert behind
        // the first; the menu item is disabled during a check, and this backstops that.
        guard !isChecking else { return }
        isChecking = true

        Task {
            defer { isChecking = false }
            // Manual checks ignore the skip list: asking explicitly overrides a past "skip",
            // otherwise the menu item would silently do nothing for a skipped version.
            let outcome = await UpdateChecker.shared.check(honorSkip: false)
            present(outcome, window: window, silentWhenNothingToReport: false)
        }
    }

    // MARK: - Automatic

    /// Runs a check only if the user opted in and the interval has elapsed, and surfaces only a
    /// genuine update.
    static func checkAutomaticallyIfDue() {
        guard UpdatePreferences.automaticCheckEnabled else { return }
        guard !isChecking else { return }
        isChecking = true

        Task {
            defer { isChecking = false }
            guard let outcome = await UpdateChecker.shared.checkIfDue() else { return }
            present(outcome, window: nil, silentWhenNothingToReport: true)
        }
    }

    // MARK: - Presentation

    private static func present(
        _ outcome: UpdateCheckOutcome,
        window: NSWindow?,
        silentWhenNothingToReport: Bool
    ) {
        switch outcome {
        case .updateAvailable(let release):
            presentUpdateAvailable(release, window: window)

        case .skipped(let release):
            // Only reachable from an automatic check (manual passes `honorSkip: false`).
            DevTypeLog.updates.info("update \(release.tagName, privacy: .public) suppressed by skip")

        case .upToDate(let current, let latest):
            guard !silentWhenNothingToReport else { return }
            presentUpToDate(current: current, latest: latest, window: window)

        case .undeterminedLocalVersion(let raw):
            DevTypeLog.updates.error("local version undetermined (raw=\(raw ?? "nil", privacy: .public))")
            guard !silentWhenNothingToReport else { return }
            DevTypeAlert.warn(
                title: loc.s("updates.unknownVersion.title"),
                message: loc.s("updates.unknownVersion.message"),
                window: window
            )

        case .failed(let error):
            DevTypeLog.updates.error("check failed: \(String(describing: error), privacy: .public)")
            guard !silentWhenNothingToReport else { return }
            // Distinct title and copy from `upToDate` — a check that could not run must never
            // look like one that ran and found nothing.
            DevTypeAlert.warn(
                title: loc.s("updates.failed.title"),
                message: loc.s("updates.failed.message", error.userMessage),
                window: window
            )
        }
    }

    private static func presentUpdateAvailable(_ release: ReleaseInfo, window: NSWindow?) {
        let currentDescription = AppVersion.current()?.rawValue ?? "—"
        var message = loc.s("updates.available.message", currentDescription)
        if !release.notes.isEmpty {
            message += "\n\n" + release.notes
        }

        DevTypeAlert.present(
            title: loc.s("updates.available.title", release.version.releaseCore),
            message: message,
            style: .informational,
            buttons: [
                loc.s("updates.button.viewRelease"),
                loc.s("updates.button.skipVersion"),
                loc.s("updates.button.later")
            ],
            window: window
        ) { index in
            switch index {
            case 0:
                // The only "install" step DevType takes: hand the release page to the browser.
                // `releaseURL` was constrained to https://github.com/<owner>/<repo>/… by
                // `UpdateChecker.sanitizedReleaseURL`, so a hostile payload cannot steer this.
                NSWorkspace.shared.open(release.releaseURL)
            case 1:
                UpdatePreferences.skip(release.version)
                DevTypeLog.updates.info("user skipped \(release.tagName, privacy: .public)")
            default:
                break
            }
        }
    }

    private static func presentUpToDate(current: AppVersion, latest: AppVersion, window: NSWindow?) {
        // A build ahead of the newest tag is "up to date" but saying "x.y.z is the latest
        // release" there is simply wrong — the user is running something newer than that.
        let message: String
        if current.isDevelopmentBuild, AppVersion.compare(current, latest) == .orderedDescending {
            message = loc.s("updates.devBuild.message", current.rawValue, latest.releaseCore)
        } else {
            message = loc.s("updates.upToDate.message", latest.releaseCore)
        }
        DevTypeAlert.info(
            title: loc.s("updates.upToDate.title"),
            message: message,
            window: window
        )
    }
}
