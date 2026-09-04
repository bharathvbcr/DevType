import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

final class VoiceProviderPreferencesPresentationTests: XCTestCase {
    func testAppleSpeechReadinessNeverClaimsReadyWithoutCurrentOnDeviceEvidence() {
        XCTAssertEqual(
            AppleSpeechReadinessDisplayState.resolve(
                authorization: .authorized,
                providerReadiness: nil
            ),
            .checking
        )
        XCTAssertEqual(
            AppleSpeechReadinessDisplayState.resolve(
                authorization: .authorized,
                providerReadiness: .incompatible(reason: .modelNotFound)
            ),
            .onDeviceUnavailable
        )
        XCTAssertEqual(
            AppleSpeechReadinessDisplayState.resolve(
                authorization: .authorized,
                providerReadiness: .ready(ProviderEvidence(
                    providerID: "apple.speech.legacy",
                    modelVersion: "system",
                    probeTimestamp: Date(),
                    capabilities: ["onDeviceRecognition"]
                ))
            ),
            .ready
        )

        // A once-ready probe may be stale after TCC changes. Current authorization wins.
        XCTAssertEqual(
            AppleSpeechReadinessDisplayState.resolve(
                authorization: .denied,
                providerReadiness: .ready(ProviderEvidence(
                    providerID: "apple.speech.legacy",
                    modelVersion: "system",
                    probeTimestamp: Date(),
                    capabilities: ["onDeviceRecognition"]
                ))
            ),
            .denied
        )
    }

    func testAppleSpeechReadinessRefreshRejectsStaleAsyncCompletion() {
        var lifecycle = AppleSpeechReadinessRefreshLifecycle()
        let first = lifecycle.begin()
        let second = lifecycle.begin()

        XCTAssertFalse(lifecycle.claim(first))
        XCTAssertTrue(lifecycle.claim(second))
        XCTAssertFalse(lifecycle.claim(second), "A probe completion must be single-consumption")
    }

    func testAppleSpeechReadinessRefreshRejectsCompletionAfterViewTeardown() throws {
        var lifecycle = AppleSpeechReadinessRefreshLifecycle()
        let request = lifecycle.begin()

        lifecycle.invalidate()

        XCTAssertFalse(
            lifecycle.claim(request),
            "A system probe that ignores task cancellation must not repaint a detached view."
        )

        let sourceURL = repositoryRoot()
            .appendingPathComponent("Sources/DevTypeAppCore/PreferencesWindowController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let teardownStart = try XCTUnwrap(source.range(of: "override func viewWillDisappear()"))
        let replacementStart = try XCTUnwrap(
            source.range(
                of: "func prepareForLocalizationReplacement()",
                range: teardownStart.upperBound..<source.endIndex
            )
        )
        let teardown = source[teardownStart.lowerBound..<replacementStart.lowerBound]
        XCTAssertTrue(teardown.contains("appleSpeechReadinessTask?.cancel()"))
        XCTAssertTrue(teardown.contains("appleSpeechReadinessTask = nil"))
        XCTAssertTrue(teardown.contains("appleSpeechReadinessRefresh.invalidate()"))
    }

    func testAppleSpeechAssetInstallLifecycleIsSingleFlightAndRejectsLateCompletion() throws {
        var lifecycle = AppleSpeechAssetInstallLifecycle()
        let first = try XCTUnwrap(lifecycle.begin())

        XCTAssertNil(lifecycle.begin(), "A second click must not start a second system download.")
        XCTAssertTrue(lifecycle.isActive)
        XCTAssertTrue(lifecycle.claimCompletion(first))
        XCTAssertFalse(lifecycle.claimCompletion(first))
        XCTAssertFalse(lifecycle.isActive)

        let detached = try XCTUnwrap(lifecycle.begin())
        lifecycle.invalidate()
        XCTAssertFalse(lifecycle.claimCompletion(detached))
    }

    func testAppleSpeechAssetInstallCancellationDistinguishesTaskRetirementFromDependencyFailure() throws {
        var lifecycle = AppleSpeechAssetInstallLifecycle()

        let dependencyCancellation = try XCTUnwrap(lifecycle.begin())
        XCTAssertEqual(
            lifecycle.claimCancellation(
                dependencyCancellation,
                taskIsCancelled: false
            ),
            .reportFailure,
            "A dependency-originated CancellationError is a failed current request, not teardown."
        )
        XCTAssertFalse(lifecycle.isActive)

        let callerCancellation = try XCTUnwrap(lifecycle.begin())
        XCTAssertEqual(
            lifecycle.claimCancellation(
                callerCancellation,
                taskIsCancelled: true
            ),
            .retireSilently
        )
        XCTAssertFalse(lifecycle.isActive)

        let detached = try XCTUnwrap(lifecycle.begin())
        lifecycle.invalidate()
        XCTAssertEqual(
            lifecycle.claimCancellation(detached, taskIsCancelled: false),
            .ignore,
            "A late CancellationError must not alert or repaint a detached Preferences view."
        )
    }

    func testAppleSpeechAssetDependencyCancellationReleasesControllerOwnershipAndReportsSafely() throws {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("Sources/DevTypeAppCore/PreferencesWindowController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let installStart = try XCTUnwrap(source.range(of: "@objc private func installAppleSpeechAssets()"))
        let finishStart = try XCTUnwrap(
            source.range(
                of: "private func finishAppleSpeechAssetInstall(showFailure:",
                range: installStart.upperBound..<source.endIndex
            )
        )
        let invalidationStart = try XCTUnwrap(
            source.range(
                of: "private func invalidateAppleSpeechAssetInstall()",
                range: finishStart.upperBound..<source.endIndex
            )
        )
        let installBody = source[installStart.lowerBound..<finishStart.lowerBound]
        let finishBody = source[finishStart.lowerBound..<invalidationStart.lowerBound]

        XCTAssertTrue(installBody.contains("claimCancellation("))
        XCTAssertTrue(installBody.contains("case .reportFailure:"))
        XCTAssertTrue(installBody.contains("finishAppleSpeechAssetInstall(showFailure: true)"))
        XCTAssertFalse(
            installBody.contains("catch is CancellationError {\n                return"),
            "An unexpected adapter CancellationError must not strand localization ownership."
        )
        XCTAssertTrue(finishBody.contains("appleSpeechAssetInstallTask = nil"))
        XCTAssertTrue(finishBody.contains("onLocalizationBlockingOperationDidEnd?()"))
        XCTAssertTrue(finishBody.contains("DevTypeAlert.warn("))
        XCTAssertTrue(finishBody.contains("refreshAppleSpeechReadiness()"))
    }

    func testAppleSpeechAssetControlsExposeOnlyAnExplicitSafeInstallAction() {
        let missing = AppleSpeechAssetControlsPresentation.resolve(
            platformSupportsAnalyzer: true,
            analyzerReadiness: .requiresConfiguration(.missingModelDownload),
            isInstalling: false
        )
        XCTAssertFalse(missing.isHidden)
        XCTAssertTrue(missing.isEnabled)
        XCTAssertEqual(missing.titleKey, "prefs.voice.appleAssets.install")

        let installing = AppleSpeechAssetControlsPresentation.resolve(
            platformSupportsAnalyzer: true,
            analyzerReadiness: .downloading(progress: 0.5),
            isInstalling: true
        )
        XCTAssertFalse(installing.isEnabled)
        XCTAssertEqual(installing.titleKey, "prefs.voice.appleAssets.installing")

        let installed = AppleSpeechAssetControlsPresentation.resolve(
            platformSupportsAnalyzer: true,
            analyzerReadiness: .ready(ProviderEvidence(
                providerID: VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer,
                modelVersion: "system"
            )),
            isInstalling: false
        )
        XCTAssertFalse(installed.isEnabled)
        XCTAssertEqual(installed.titleKey, "prefs.voice.appleAssets.installed")

        let olderSystem = AppleSpeechAssetControlsPresentation.resolve(
            platformSupportsAnalyzer: false,
            analyzerReadiness: .unsupported(reason: .modelNotFound),
            isInstalling: false
        )
        XCTAssertTrue(olderSystem.isHidden)
        XCTAssertFalse(olderSystem.isEnabled)
    }

    func testAppleSpeechResolutionNamesTheProviderThatCanActuallyRun() {
        let analyzerReady = ProviderReadiness.ready(ProviderEvidence(
            providerID: VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer,
            modelVersion: "system"
        ))
        let legacyReady = ProviderReadiness.ready(ProviderEvidence(
            providerID: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy,
            modelVersion: "system"
        ))

        XCTAssertEqual(
            AppleSpeechPreferencesResolution.resolve(
                platformSupportsAnalyzer: true,
                analyzerReadiness: analyzerReady,
                legacyReadiness: legacyReady
            ).providerID,
            VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer
        )

        let fallback = AppleSpeechPreferencesResolution.resolve(
            platformSupportsAnalyzer: true,
            analyzerReadiness: .requiresConfiguration(.missingModelDownload),
            legacyReadiness: legacyReady
        )
        XCTAssertEqual(fallback.readiness, legacyReady)
        XCTAssertEqual(
            fallback.providerID,
            VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy
        )

        let unavailable = AppleSpeechPreferencesResolution.resolve(
            platformSupportsAnalyzer: true,
            analyzerReadiness: .requiresConfiguration(.missingModelDownload),
            legacyReadiness: .unsupported(reason: .modelNotFound)
        )
        XCTAssertNil(unavailable.providerID)
        XCTAssertEqual(
            unavailable.readiness,
            .requiresConfiguration(.missingModelDownload)
        )
    }

    func testPreferencesOwnsReachableAnalyzerSetupAndTeardown() throws {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("Sources/DevTypeAppCore/PreferencesWindowController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("AppleSpeechAnalyzerAdapter(locale:"))
        XCTAssertTrue(source.contains("adapter.installAssets("))
        XCTAssertTrue(source.contains("#selector(installAppleSpeechAssets)"))
        XCTAssertTrue(source.contains("appleSpeechAssetButton.setAccessibilityLabel"))
        XCTAssertTrue(source.contains("invalidateAppleSpeechAssetInstall()"))
        XCTAssertFalse(
            source.contains("let adapter = LegacyAppleSpeechAdapter()\n        let endpoint"),
            "Preferences must probe analyzer and legacy readiness separately."
        )
    }

    func testLocalAIReadinessIncludesTheActuallySelectedCorrectionPath() {
        let speechReady = ProviderReadiness.ready(ProviderEvidence(
            providerID: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy,
            modelVersion: "system",
            capabilities: ["onDeviceRecognition"]
        ))

        XCTAssertEqual(
            LocalAIReadinessDisplayState.resolve(
                authorization: .authorized,
                speechReadiness: speechReady,
                selectedCorrectionProviderID: nil
            ),
            .checking
        )
        XCTAssertEqual(
            LocalAIReadinessDisplayState.resolve(
                authorization: .authorized,
                speechReadiness: speechReady,
                selectedCorrectionProviderID: VoiceSessionSnapshotFactory.ProviderID.openAICompatibleCorrector
            ),
            .ready
        )
        XCTAssertEqual(
            LocalAIReadinessDisplayState.resolve(
                authorization: .authorized,
                speechReadiness: speechReady,
                selectedCorrectionProviderID: VoiceSessionSnapshotFactory.ProviderID.deterministicCorrector
            ),
            .basicCleanup
        )
        XCTAssertEqual(
            LocalAIReadinessDisplayState.resolve(
                authorization: .denied,
                speechReadiness: speechReady,
                selectedCorrectionProviderID: VoiceSessionSnapshotFactory.ProviderID.openAICompatibleCorrector
            ),
            .denied,
            "Current speech authorization must override a completed correction probe"
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testGeminiCredentialPresentationDoesNotCollapseUnavailableIntoMissing() {
        XCTAssertEqual(GeminiCredentialDisplayState.resolve(.missing), .missing)
        XCTAssertEqual(GeminiCredentialDisplayState.resolve(.available("")), .missing)
        XCTAssertEqual(GeminiCredentialDisplayState.resolve(.available("AIza-example")), .configured)
        XCTAssertEqual(
            GeminiCredentialDisplayState.resolve(.unavailable(.invalidData)),
            .unavailable
        )
        XCTAssertNotEqual(
            GeminiCredentialDisplayState.missing.tintRole,
            GeminiCredentialDisplayState.unavailable.tintRole
        )
        XCTAssertNotEqual(
            GeminiCredentialDisplayState.missing.statusKey,
            GeminiCredentialDisplayState.unavailable.statusKey
        )
        XCTAssertNotEqual(
            GeminiCredentialDisplayState.missing.placeholderKey,
            GeminiCredentialDisplayState.unavailable.placeholderKey
        )
    }

    func testGeminiValidationResultsMapToLocalizedValueFreeStates() {
        XCTAssertEqual(GeminiValidationDisplayState.resolve(.valid(modelName: "model")), .valid)
        XCTAssertEqual(GeminiValidationDisplayState.resolve(.invalidKey(reason: "private detail")), .invalid)
        XCTAssertEqual(GeminiValidationDisplayState.resolve(.rateLimited), .rateLimited)
        XCTAssertEqual(GeminiValidationDisplayState.resolve(.quotaExhausted), .quotaExhausted)
        XCTAssertEqual(GeminiValidationDisplayState.resolve(.networkError(reason: "private endpoint")), .networkError)

        for state in GeminiValidationDisplayState.allCases {
            XCTAssertTrue(state.localizationKey.hasPrefix("prefs.voice.gemini.validation."))
            XCTAssertFalse(state.localizationKey.contains("private"))
        }
    }

    func testVoiceProviderPreferenceKeysResolveInEveryLanguage() {
        let keys = [
            "prefs.voice.gemini.keyLabel",
            "prefs.voice.gemini.placeholder.saved",
            "prefs.voice.gemini.placeholder.paste",
            "prefs.voice.gemini.placeholder.unavailable",
            "prefs.voice.gemini.keyConfigured",
            "prefs.voice.gemini.noKey",
            "prefs.voice.gemini.saveValidate",
            "prefs.voice.gemini.validating",
            "prefs.voice.gemini.validatingKey",
            "prefs.voice.gemini.delete",
            "prefs.voice.gemini.validation.valid",
            "prefs.voice.gemini.validation.invalid",
            "prefs.voice.gemini.validation.rateLimited",
            "prefs.voice.gemini.validation.quotaExhausted",
            "prefs.voice.gemini.validation.networkError",
            "prefs.voice.localLLM.endpointLabel",
            "prefs.voice.localLLM.endpointStatus",
            "prefs.voice.localLLM.customPlaceholder",
            "prefs.voice.localLLM.customOption",
            "prefs.voice.localLLM.installed",
            "prefs.voice.localLLM.fastRecommended",
            "prefs.voice.localLLM.ultraFast",
            "prefs.voice.localLLM.endpointInvalid.title",
            "prefs.voice.localLLM.endpointInvalid.message",
            "prefs.voice.localLLM.endpointInvalid.pill",
            "prefs.voice.speechModels.status.onDeviceUnavailable",
            "prefs.voice.speechModels.status.basicCleanup",
            "prefs.voice.speechModels.status.readyAnalyzer",
            "prefs.voice.speechModels.status.readyLegacy",
            "prefs.voice.appleAssets.label",
            "prefs.voice.appleAssets.install",
            "prefs.voice.appleAssets.installing",
            "prefs.voice.appleAssets.installed",
            "prefs.voice.appleAssets.unavailable",
            "prefs.voice.appleAssets.failed.title",
            "prefs.voice.appleAssets.failed.message",
            "prefs.voice.engine.gemini",
            "prefs.voice.engine.localAI",
            "prefs.voice.engine.appleSpeech",
            "prefs.voice.engine.whisper",
        ]

        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for key in keys {
                XCTAssertNotNil(table[key], "\(language.rawValue) missing \(key)")
            }
        }
    }

    func testEveryVoiceEngineHasALocalizedPresentationKey() {
        for engine in TranscriptionEngine.allCases {
            for language in AppLanguage.concreteCases {
                let table = LocalizationManager.stringTable(for: language)
                XCTAssertNotNil(
                    table[engine.localizationKey],
                    "\(language.rawValue) missing \(engine.localizationKey)"
                )
            }
        }
    }
}
