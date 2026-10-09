import AppKit
import ExpanderEngine


/// Typed UI projection for clearing the always-on, content-free voice outcome history. Keeping
/// the recorder operation injectable makes the button's one-shot behavior testable without
/// touching the user's real Application Support files.
struct VoiceTerminalDiagnosticsDeletionPresentation: Equatable {
    let statusKey: String
    let isWarning: Bool
    let alertTitleKey: String?
    let alertMessageKey: String?
    let failure: VoiceDiagnosticsRecorder.IOFailure?

    static func perform(
        delete: () -> VoiceDiagnosticsRecorder.IOStatus
    ) -> VoiceTerminalDiagnosticsDeletionPresentation {
        switch delete() {
        case .succeeded:
            return VoiceTerminalDiagnosticsDeletionPresentation(
                statusKey: "prefs.voice.terminalDiagnostics.status.deleted",
                isWarning: false,
                alertTitleKey: nil,
                alertMessageKey: nil,
                failure: nil
            )
        case .failed(let failure):
            return VoiceTerminalDiagnosticsDeletionPresentation(
                statusKey: "prefs.voice.terminalDiagnostics.status.deleteFailed",
                isWarning: true,
                alertTitleKey: "prefs.voice.terminalDiagnostics.deleteFailed.title",
                alertMessageKey: "prefs.voice.terminalDiagnostics.deleteFailed.message",
                failure: failure
            )
        case .notAttempted:
            return VoiceTerminalDiagnosticsDeletionPresentation(
                statusKey: "prefs.voice.terminalDiagnostics.status.deleteFailed",
                isWarning: true,
                alertTitleKey: "prefs.voice.terminalDiagnostics.deleteFailed.title",
                alertMessageKey: "prefs.voice.terminalDiagnostics.deleteFailed.message",
                failure: nil
            )
        }
    }
}


// MARK: - Voice tracing and terminal diagnostics

extension VoicePreferencesViewController {

    /// The tracing switch and the reveal / delete row beneath it, last in the options card.
    func makeVoiceDiagnosticsRows() -> (tracingRow: NSView, revealRow: NSView) {
        // Diagnostics. Off by default and last in the card, because switching it on starts
        // recording what the user dictates — it exists to capture a problem, not to run.
        let tracingRow = makeToggleRow(
            title: loc.s("prefs.voice.tracing"),
            toggle: voiceTracingSwitch,
            action: #selector(voiceTracingChanged)
        )
        let revealTraceButton = NSButton(
            title: loc.s("prefs.voice.tracing.reveal"),
            target: self,
            action: #selector(revealVoiceTrace)
        )
        revealTraceButton.bezelStyle = .rounded
        revealTraceButton.controlSize = .small
        revealTraceButton.translatesAutoresizingMaskIntoConstraints = false

        let deleteTraceButton = NSButton(
            title: loc.s("prefs.voice.tracing.delete"),
            target: self,
            action: #selector(deleteVoiceTrace)
        )
        deleteTraceButton.bezelStyle = .rounded
        deleteTraceButton.controlSize = .small
        deleteTraceButton.translatesAutoresizingMaskIntoConstraints = false

        let deleteTerminalDiagnosticsButton = NSButton(
            title: loc.s("prefs.voice.terminalDiagnostics.delete"),
            target: self,
            action: #selector(deleteVoiceTerminalDiagnostics)
        )
        deleteTerminalDiagnosticsButton.bezelStyle = .rounded
        deleteTerminalDiagnosticsButton.controlSize = .small
        deleteTerminalDiagnosticsButton.translatesAutoresizingMaskIntoConstraints = false
        let terminalDiagnosticsHint = loc.s("prefs.voice.terminalDiagnostics.hint")
        deleteTerminalDiagnosticsButton.toolTip = terminalDiagnosticsHint
        deleteTerminalDiagnosticsButton.setAccessibilityHelp(terminalDiagnosticsHint)

        let revealRow = PreferenceRowView()
        revealRow.translatesAutoresizingMaskIntoConstraints = false
        revealRow.addSubview(revealTraceButton)
        revealRow.addSubview(deleteTraceButton)
        revealRow.addSubview(deleteTerminalDiagnosticsButton)
        voiceTraceStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        revealRow.addSubview(voiceTraceStatusLabel)
        NSLayoutConstraint.activate([
            revealTraceButton.leadingAnchor.constraint(equalTo: revealRow.leadingAnchor),
            revealTraceButton.topAnchor.constraint(equalTo: revealRow.topAnchor, constant: 2),
            deleteTraceButton.leadingAnchor.constraint(equalTo: revealTraceButton.trailingAnchor, constant: 8),
            deleteTraceButton.centerYAnchor.constraint(equalTo: revealTraceButton.centerYAnchor),
            deleteTerminalDiagnosticsButton.leadingAnchor.constraint(
                equalTo: deleteTraceButton.trailingAnchor,
                constant: 8
            ),
            deleteTerminalDiagnosticsButton.centerYAnchor.constraint(equalTo: revealTraceButton.centerYAnchor),
            deleteTerminalDiagnosticsButton.trailingAnchor.constraint(lessThanOrEqualTo: revealRow.trailingAnchor),
            voiceTraceStatusLabel.leadingAnchor.constraint(equalTo: revealRow.leadingAnchor),
            voiceTraceStatusLabel.trailingAnchor.constraint(equalTo: revealRow.trailingAnchor),
            voiceTraceStatusLabel.topAnchor.constraint(equalTo: revealTraceButton.bottomAnchor, constant: 6),
            voiceTraceStatusLabel.bottomAnchor.constraint(equalTo: revealRow.bottomAnchor, constant: -2)
        ])
        return (tracingRow, revealRow)
    }

    func updateVoiceTraceStatus(_ key: String, warning: Bool) {
        voiceTraceStatusLabel.stringValue = loc.s(key)
        voiceTraceStatusLabel.textColor = warning ? DevTypeTheme.statusOrange : DevTypeTheme.textTertiary
    }

    private func presentVoiceDiagnosticsFailure(
        titleKey: String,
        messageKey: String,
        action: String,
        failure: VoiceDiagnosticsRecorder.IOFailure?
    ) {
        DevTypeLog.voice.error(
            "[VoiceDiagnostics] preferences action=\(action, privacy: .public) failure=\(failure?.rawValue ?? "notAttempted", privacy: .public)"
        )
        DevTypeAlert.warn(
            title: loc.s(titleKey),
            message: loc.s(messageKey),
            window: view.window
        )
    }

    @objc private func deleteVoiceTrace() {
        let recorder = VoiceDiagnosticsRecorder.shared
        switch recorder.deleteTrace() {
        case .succeeded:
            updateVoiceTraceStatus(
                recorder.isEnabled
                    ? "prefs.voice.tracing.status.deletedCapturing"
                    : "prefs.voice.tracing.status.deleted",
                warning: false
            )
        case .failed(let failure):
            updateVoiceTraceStatus("prefs.voice.tracing.status.deleteFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.deleteFailed.title",
                messageKey: "prefs.voice.tracing.deleteFailed.message",
                action: "delete",
                failure: failure
            )
        case .notAttempted:
            updateVoiceTraceStatus("prefs.voice.tracing.status.deleteFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.deleteFailed.title",
                messageKey: "prefs.voice.tracing.deleteFailed.message",
                action: "delete",
                failure: nil
            )
        }
    }

    @objc private func deleteVoiceTerminalDiagnostics() {
        let presentation = VoiceTerminalDiagnosticsDeletionPresentation.perform {
            VoiceDiagnosticsRecorder.shared.deleteTerminalDiagnostics()
        }
        updateVoiceTraceStatus(presentation.statusKey, warning: presentation.isWarning)
        guard let titleKey = presentation.alertTitleKey,
              let messageKey = presentation.alertMessageKey else {
            DevTypeLog.voice.info(
                "[VoiceDiagnostics] preferences action=delete-terminal outcome=succeeded"
            )
            return
        }
        presentVoiceDiagnosticsFailure(
            titleKey: titleKey,
            messageKey: messageKey,
            action: "delete-terminal",
            failure: presentation.failure
        )
    }

    @objc private func voiceTracingChanged() {
        let recorder = VoiceDiagnosticsRecorder.shared
        if voiceTracingSwitch.state == .on {
            // Keep acceptance off until the previous trace is definitely gone. Otherwise a failed
            // delete silently mixes old dictated text into what the UI calls a fresh capture.
            recorder.isEnabled = false
            switch recorder.deleteTrace() {
            case .succeeded:
                recorder.isEnabled = true
                updateVoiceTraceStatus("prefs.voice.tracing.status.on", warning: false)
            case .failed(let failure):
                recorder.isEnabled = false
                voiceTracingSwitch.state = .off
                updateVoiceTraceStatus("prefs.voice.tracing.status.startFailed", warning: true)
                presentVoiceDiagnosticsFailure(
                    titleKey: "prefs.voice.tracing.startFailed.title",
                    messageKey: "prefs.voice.tracing.startFailed.message",
                    action: "enable",
                    failure: failure
                )
            case .notAttempted:
                recorder.isEnabled = false
                voiceTracingSwitch.state = .off
                updateVoiceTraceStatus("prefs.voice.tracing.status.startFailed", warning: true)
                presentVoiceDiagnosticsFailure(
                    titleKey: "prefs.voice.tracing.startFailed.title",
                    messageKey: "prefs.voice.tracing.startFailed.message",
                    action: "enable",
                    failure: nil
                )
            }
            return
        }

        // This operation first blocks new submissions, drains accepted writes, and then deletes.
        // A failed delete still leaves tracing off; the warning is about retained local data only.
        switch recorder.disableAndDelete() {
        case .succeeded:
            updateVoiceTraceStatus("prefs.voice.tracing.status.off", warning: false)
        case .failed(let failure):
            voiceTracingSwitch.state = .off
            updateVoiceTraceStatus("prefs.voice.tracing.status.deleteFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.disableDeleteFailed.title",
                messageKey: "prefs.voice.tracing.disableDeleteFailed.message",
                action: "disable",
                failure: failure
            )
        case .notAttempted:
            voiceTracingSwitch.state = .off
            updateVoiceTraceStatus("prefs.voice.tracing.status.deleteFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.disableDeleteFailed.title",
                messageKey: "prefs.voice.tracing.disableDeleteFailed.message",
                action: "disable",
                failure: nil
            )
        }
    }

    @objc private func revealVoiceTrace() {
        let recorder = VoiceDiagnosticsRecorder.shared
        // read() is a queue barrier: it waits for every accepted append before the file is opened.
        let trace = recorder.read()
        let health = recorder.ioHealth
        switch health.read {
        case .failed(let failure):
            updateVoiceTraceStatus("prefs.voice.tracing.status.readFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.readFailed.title",
                messageKey: "prefs.voice.tracing.readFailed.message",
                action: "reveal",
                failure: failure
            )
            return
        case .notAttempted:
            updateVoiceTraceStatus("prefs.voice.tracing.status.readFailed", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.readFailed.title",
                messageKey: "prefs.voice.tracing.readFailed.message",
                action: "reveal",
                failure: nil
            )
            return
        case .succeeded:
            break
        }

        guard let trace, !trace.isEmpty else {
            updateVoiceTraceStatus("prefs.voice.tracing.status.empty", warning: false)
            DevTypeAlert.info(
                title: loc.s("prefs.voice.tracing.empty.title"),
                message: loc.s("prefs.voice.tracing.empty.message"),
                window: view.window
            )
            return
        }

        if case .failed(let failure) = health.write {
            updateVoiceTraceStatus("prefs.voice.tracing.status.incomplete", warning: true)
            presentVoiceDiagnosticsFailure(
                titleKey: "prefs.voice.tracing.incomplete.title",
                messageKey: "prefs.voice.tracing.incomplete.message",
                action: "reveal-incomplete",
                failure: failure
            )
        }
        let url = VoiceDiagnosticsRecorder.traceURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

}
