import AppKit
import ExpanderEngine

// MARK: - Gemini API key and cloud-audio consent

extension VoicePreferencesViewController {

    /// Fills `geminiConfigContainer`, which the engine card shows only while Gemini is selected.
    func configureGeminiConfiguration() {
        // Gemini API Configuration Box
        geminiConfigContainer.orientation = .vertical
        geminiConfigContainer.alignment = .leading
        geminiConfigContainer.spacing = 6
        geminiConfigContainer.translatesAutoresizingMaskIntoConstraints = false

        let initialCredential = GeminiCredentialDisplayState.resolve(GeminiAPIKeyStore.readState())
        let geminiLabel = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.gemini.keyLabel"),
            font: DevTypeTheme.font(11.5, .medium),
            color: DevTypeTheme.textPrimary
        )

        geminiAPIKeyField.translatesAutoresizingMaskIntoConstraints = false
        geminiAPIKeyField.font = DevTypeTheme.font(12)
        geminiAPIKeyField.placeholderString = loc.s(initialCredential.placeholderKey)
        geminiAPIKeyField.delegate = self
        geminiAPIKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        geminiAPIKeyField.setAccessibilityLabel(loc.s("prefs.voice.gemini.keyLabel"))
        geminiAPIKeyField.setAccessibilityTitleUIElement(geminiLabel)

        let keyPill = PillBadgeView(
            text: loc.s(initialCredential.statusKey),
            tint: initialCredential.tint,
            showsDot: true
        )
        keyPill.translatesAutoresizingMaskIntoConstraints = false
        geminiKeyStatusPill = keyPill

        let saveBtn = CapsuleButton(
            title: loc.s("prefs.voice.gemini.saveValidate"),
            symbol: "key.fill",
            style: .primary,
            target: self,
            action: #selector(geminiKeySaveClicked)
        )
        geminiKeySaveButton = saveBtn

        let deleteBtn = CapsuleButton(
            title: loc.s("prefs.voice.gemini.delete"),
            symbol: "trash",
            style: .destructive,
            target: self,
            action: #selector(geminiKeyDeleteClicked)
        )
        geminiKeyDeleteButton = deleteBtn

        let geminiActionsRow = NSStackView(views: [geminiAPIKeyField, keyPill, saveBtn, deleteBtn])
        geminiActionsRow.orientation = .horizontal
        geminiActionsRow.spacing = 8
        geminiActionsRow.alignment = .centerY
        geminiActionsRow.translatesAutoresizingMaskIntoConstraints = false

        let geminiSubHint = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.gemini.hint"),
            font: DevTypeTheme.font(10),
            color: DevTypeTheme.textTertiary,
            wrapping: true
        )

        let cloudDisclosure = DevTypeTheme.makeLabel(
            loc.s("prefs.voice.cloudDisclosure"),
            font: DevTypeTheme.font(10.5),
            color: DevTypeTheme.statusOrange,
            wrapping: true
        )
        let cloudConsentRow = makeToggleRow(
            title: loc.s("prefs.voice.cloudConsent"),
            toggle: geminiCloudConsentSwitch,
            action: #selector(geminiCloudConsentChanged)
        )

        geminiConfigContainer.addArrangedSubview(geminiLabel)
        geminiConfigContainer.addArrangedSubview(geminiActionsRow)
        geminiConfigContainer.addArrangedSubview(geminiSubHint)
        geminiConfigContainer.addArrangedSubview(cloudDisclosure)
        geminiConfigContainer.addArrangedSubview(cloudConsentRow)
        cloudDisclosure.widthAnchor.constraint(equalTo: geminiConfigContainer.widthAnchor).isActive = true
        cloudConsentRow.widthAnchor.constraint(equalTo: geminiConfigContainer.widthAnchor).isActive = true
    }

    @objc private func geminiCloudConsentChanged() {
        VoicePreferences.hasCloudAudioConsent = geminiCloudConsentSwitch.state == .on
        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        reload()
    }

    @objc private func geminiKeySaveClicked() {
        let key = geminiAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        geminiKeyValidationTask?.cancel()
        let request = geminiKeyValidationLifecycle.begin()
        geminiKeySaveButton?.isEnabled = false
        geminiKeySaveButton?.title = loc.s("prefs.voice.gemini.validating")
        geminiKeyStatusPill?.update(
            text: loc.s("prefs.voice.gemini.validatingKey"),
            tint: DevTypeTheme.accent
        )

        geminiKeyValidationTask = Task { [weak self] in
            let result = await GeminiTranscriptionClient.shared.validateAPIKeyDetailed(key)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.geminiKeyValidationLifecycle.claim(
                          request,
                          draftMatches: self.geminiAPIKeyField.transientValue
                              .trimmingCharacters(in: .whitespacesAndNewlines) == key
                      ) else { return }
                self.geminiKeyValidationTask = nil
                defer { self.onLocalizationBlockingOperationDidEnd?() }

                if result.isValid {
                    do {
                        try GeminiAPIKeyStore.save(key)
                        self.geminiAPIKeyField.stringValue = ""
                        self.geminiAPIKeyField.placeholderString = self.loc.s("prefs.voice.gemini.placeholder.saved")
                        self.reload()
                        let validation = GeminiValidationDisplayState.resolve(result)
                        self.geminiKeyStatusPill?.update(
                            text: self.loc.s(validation.localizationKey),
                            tint: DevTypeTheme.statusGreen
                        )
                    } catch {
                        self.presentGeminiKeychainFailure(action: .save, error: error)
                        self.finishGeminiKeyValidationControls()
                        return
                    }
                } else {
                    let validation = GeminiValidationDisplayState.resolve(result)
                    self.geminiKeyStatusPill?.update(
                        text: self.loc.s(validation.localizationKey),
                        tint: DevTypeTheme.statusOrange
                    )
                }
                self.finishGeminiKeyValidationControls()
            }
        }
    }

    @objc private func geminiKeyDeleteClicked() {
        // Delete is an explicit revocation and therefore wins over every older validation, even
        // when URLSession has already received a response and ignores task cancellation.
        invalidateGeminiKeyValidation(resetPresentation: true)
        do {
            try GeminiAPIKeyStore.delete()
            geminiAPIKeyField.stringValue = ""
            geminiAPIKeyField.placeholderString = loc.s("prefs.voice.gemini.placeholder.paste")
            reload()
        } catch {
            presentGeminiKeychainFailure(action: .delete, error: error)
        }
    }

    private func finishGeminiKeyValidationControls() {
        geminiKeySaveButton?.title = loc.s("prefs.voice.gemini.saveValidate")
        geminiKeySaveButton?.isEnabled = true
    }

    func invalidateGeminiKeyValidation(resetPresentation: Bool) {
        let wasValidating = geminiKeyValidationLifecycle.isActive
        geminiKeyValidationTask?.cancel()
        geminiKeyValidationTask = nil
        geminiKeyValidationLifecycle.invalidate()
        if wasValidating {
            onLocalizationBlockingOperationDidEnd?()
        }
        guard resetPresentation, wasValidating else { return }
        finishGeminiKeyValidationControls()
        refreshGeminiCredentialPresentation()
    }

    func refreshGeminiCredentialPresentation(
        state: GeminiAPIKeyStore.ReadState = GeminiAPIKeyStore.readState()
    ) {
        guard !geminiKeyValidationLifecycle.isActive else { return }
        let credential = GeminiCredentialDisplayState.resolve(state)
        geminiKeyStatusPill?.update(
            text: loc.s(credential.statusKey),
            tint: credential.tint
        )
        if geminiAPIKeyField.stringValue.isEmpty {
            geminiAPIKeyField.placeholderString = loc.s(credential.placeholderKey)
        }
    }

    private enum GeminiKeychainAction { case save, delete }

    private func presentGeminiKeychainFailure(action: GeminiKeychainAction, error: Error) {
        let nsError = error as NSError
        let titleKey: String
        let messageKey: String
        let pillKey: String
        switch action {
        case .save:
            titleKey = "prefs.voice.keychain.saveFailed.title"
            messageKey = "prefs.voice.keychain.saveFailed.message"
            pillKey = "prefs.voice.keychain.saveFailed.pill"
        case .delete:
            titleKey = "prefs.voice.keychain.deleteFailed.title"
            messageKey = "prefs.voice.keychain.deleteFailed.message"
            pillKey = "prefs.voice.keychain.deleteFailed.pill"
        }
        DevTypeLog.voice.error(
            "[Voice] Gemini Keychain operation failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
        )
        geminiKeyStatusPill?.update(text: loc.s(pillKey), tint: DevTypeTheme.statusOrange)
        DevTypeAlert.warn(title: loc.s(titleKey), message: loc.s(messageKey), window: view.window)
    }

}
