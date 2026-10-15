import AppKit
import ExpanderEngine

// MARK: - Microphone and speech-recognition permission card

extension VoicePreferencesViewController {

    func makeVoicePermissionCard() -> GlassCardView {
        // 0. Permission Card
        let permCard = makeCard(title: loc.s("prefs.voice.permission.card"), symbol: "mic.fill")
        let permHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.permission.hint"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )
        permHint.translatesAutoresizingMaskIntoConstraints = false

        let micPill = PillBadgeView(text: loc.s("status.checking"), tint: DevTypeTheme.statusGray, showsDot: true)
        voiceMicPermissionPill = micPill

        let micActions = NSStackView(views: [
            micPill,
            CapsuleButton(
                title: loc.s("prefs.voice.requestMic"),
                symbol: "mic.fill",
                style: .primary,
                target: self,
                action: #selector(requestMicrophoneAccessClicked)
            ),
            CapsuleButton(
                title: loc.s("prefs.voice.openSettings"),
                symbol: "gearshape",
                style: .secondary,
                target: self,
                action: #selector(openMicrophoneSettingsClicked)
            )
        ])
        micActions.orientation = .horizontal
        micActions.spacing = 10
        micActions.alignment = .centerY
        let micRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.permission.microphone"),
            control: micActions,
            font: DevTypeTheme.font(11.5, .medium)
        )

        let speechPill = PillBadgeView(
            text: loc.s("status.checking"),
            tint: DevTypeTheme.statusGray,
            showsDot: true
        )
        voiceSpeechPermissionPill = speechPill
        let speechActions = NSStackView(views: [
            speechPill,
            CapsuleButton(
                title: loc.s("prefs.voice.requestSpeech"),
                symbol: "waveform",
                style: .primary,
                target: self,
                action: #selector(requestSpeechRecognitionAccessClicked)
            ),
            CapsuleButton(
                title: loc.s("prefs.voice.openSpeechSettings"),
                symbol: "gearshape",
                style: .secondary,
                target: self,
                action: #selector(openSpeechRecognitionSettingsClicked)
            )
        ])
        speechActions.orientation = .horizontal
        speechActions.spacing = 10
        speechActions.alignment = .centerY
        let speechRow = makeLabeledControlRow(
            title: loc.s("prefs.voice.permission.speechRecognition"),
            control: speechActions,
            font: DevTypeTheme.font(11.5, .medium)
        )

        stackInCard(permCard, views: [permHint, micRow, speechRow])
        return permCard
    }

    @objc private func requestMicrophoneAccessClicked() {
        DurableVoiceCapture.requestMicrophonePermission { [weak self] _ in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
    }

    @objc private func openMicrophoneSettingsClicked() {
        SettingsDeepLinker.shared.open(for: .microphone)
    }

    @objc private func requestSpeechRecognitionAccessClicked() {
        Task { [weak self] in
            _ = await SpeechAuthorization.request()
            await MainActor.run { self?.reload() }
        }
    }

    @objc private func openSpeechRecognitionSettingsClicked() {
        SettingsDeepLinker.shared.open(for: .speechRecognition)
    }

    func voicePermissionPresentation(
        for status: DurableVoiceCapture.MicrophonePermissionStatus
    ) -> (text: String, color: NSColor) {
        voicePermissionPresentation(for: status.rawValue)
    }

    func voicePermissionPresentation(
        for status: SpeechAuthorization.Status
    ) -> (text: String, color: NSColor) {
        voicePermissionPresentation(for: status.diagnosticLabel)
    }

    /// Microphone and speech authorization use the same four labels. Denied and restricted
    /// share a color and keep distinct copy.
    private func voicePermissionPresentation(for statusKey: String) -> (text: String, color: NSColor) {
        switch statusKey {
        case DurableVoiceCapture.MicrophonePermissionStatus.authorized.rawValue:
            return (loc.s("status.authorized"), DevTypeTheme.statusGreen)
        case DurableVoiceCapture.MicrophonePermissionStatus.denied.rawValue:
            return (loc.s("status.denied"), DevTypeTheme.statusOrange)
        case DurableVoiceCapture.MicrophonePermissionStatus.restricted.rawValue:
            return (loc.s("status.restricted"), DevTypeTheme.statusOrange)
        default:
            return (loc.s("status.notRequested"), DevTypeTheme.statusOrange)
        }
    }

}
