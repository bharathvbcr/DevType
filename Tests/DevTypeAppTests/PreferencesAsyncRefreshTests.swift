import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

final class PreferencesAsyncRefreshTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testEndpointRefreshRejectsOutOfOrderCompletionsAndConsumesTheWinnerOnce() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:11434/v1/chat/completions"))
        var lifecycle = EndpointBoundRefreshLifecycle()
        let first = lifecycle.begin(endpoint: endpoint)
        let second = lifecycle.begin(endpoint: endpoint)

        XCTAssertFalse(lifecycle.claim(first, currentEndpoint: endpoint))
        XCTAssertTrue(lifecycle.claim(second, currentEndpoint: endpoint))
        XCTAssertFalse(
            lifecycle.claim(second, currentEndpoint: endpoint),
            "An async completion must be single-consumption."
        )
    }

    func testEndpointRefreshConsumesAMismatchedEndpointAndHonorsInvalidation() throws {
        let firstEndpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:11434/v1/chat/completions"))
        let changedEndpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:1234/v1/chat/completions"))
        var lifecycle = EndpointBoundRefreshLifecycle()

        let mismatch = lifecycle.begin(endpoint: firstEndpoint)
        XCTAssertFalse(lifecycle.claim(mismatch, currentEndpoint: changedEndpoint))
        XCTAssertFalse(
            lifecycle.claim(mismatch, currentEndpoint: firstEndpoint),
            "Reverting the field later must not revive a completion that already arrived stale."
        )

        let closedWindow = lifecycle.begin(endpoint: changedEndpoint)
        lifecycle.invalidate()
        XCTAssertFalse(lifecycle.claim(closedWindow, currentEndpoint: changedEndpoint))
    }

    func testGeminiValidationRejectsDeleteEditAndOutOfOrderCompletions() {
        var lifecycle = GeminiKeyValidationLifecycle()

        let superseded = lifecycle.begin()
        let current = lifecycle.begin()
        XCTAssertTrue(lifecycle.isActive)
        XCTAssertFalse(lifecycle.claim(superseded, draftMatches: true))
        XCTAssertTrue(lifecycle.isActive)
        XCTAssertFalse(
            lifecycle.claim(current, draftMatches: false),
            "A response for a draft the user edited must be consumed without saving it."
        )
        XCTAssertFalse(lifecycle.isActive)
        XCTAssertFalse(
            lifecycle.claim(current, draftMatches: true),
            "Changing the field away and back must not revive an already-rejected response."
        )

        let revokedByDelete = lifecycle.begin()
        lifecycle.invalidate()
        XCTAssertFalse(
            lifecycle.claim(revokedByDelete, draftMatches: true),
            "Explicit deletion must win even if transport cancellation loses."
        )

        let detachedController = lifecycle.begin()
        lifecycle.invalidate()
        XCTAssertFalse(
            lifecycle.claim(detachedController, draftMatches: true),
            "A completion from a torn-down controller must not repaint its UI."
        )
    }

    func testPreferencesLocalizationRefreshDefersOnlyWhileStateOrOperationsOwnTheController() {
        XCTAssertEqual(
            PreferencesLocalizationRefreshDecision.resolve(
                needsRefresh: false,
                hasAttachedSheet: true,
                hasBlockingOperation: true
            ),
            .upToDate
        )
        XCTAssertEqual(
            PreferencesLocalizationRefreshDecision.resolve(
                needsRefresh: true,
                hasAttachedSheet: true,
                hasBlockingOperation: false
            ),
            .deferRefresh
        )
        XCTAssertEqual(
            PreferencesLocalizationRefreshDecision.resolve(
                needsRefresh: true,
                hasAttachedSheet: false,
                hasBlockingOperation: true
            ),
            .deferRefresh
        )
        XCTAssertEqual(
            PreferencesLocalizationRefreshDecision.resolve(
                needsRefresh: true,
                hasAttachedSheet: false,
                hasBlockingOperation: false
            ),
            .rebuild
        )
    }

    func testAdvancedDiagnosticsCopyPresentationReportsThePasteboardResultTruthfully() {
        XCTAssertEqual(
            AdvancedDiagnosticsCopyPresentation.resolve(didWrite: true),
            AdvancedDiagnosticsCopyPresentation(
                statusKey: "prefs.advanced.copied",
                tintRole: .success
            )
        )
        XCTAssertEqual(
            AdvancedDiagnosticsCopyPresentation.resolve(didWrite: false),
            AdvancedDiagnosticsCopyPresentation(
                statusKey: "prefs.advanced.copyFailed",
                tintRole: .failure
            )
        )
    }

    func testLifecycleAndDiagnosticsFeedbackLabelsExistInEveryLanguage() {
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for key in ["common.cancel", "prefs.advanced.copyFailed"] {
                XCTAssertNotNil(table[key], "\(language.rawValue) is missing \(key)")
            }
        }
    }

    func testWhisperActionLifecycleRefusesReentryAndConsumesCompletionOnce() throws {
        var lifecycle = WhisperActionLifecycle()

        let first = try XCTUnwrap(lifecycle.begin(.modelDownload))
        XCTAssertEqual(lifecycle.activeAction, .modelDownload)
        XCTAssertNil(
            lifecycle.begin(.modelDownload),
            "A second click must not replace or cancel the download already in flight."
        )
        XCTAssertNil(
            lifecycle.begin(.serverStart),
            "A conflicting server action must not displace the download already in flight."
        )
        XCTAssertTrue(lifecycle.allowsProgress(first))
        XCTAssertTrue(lifecycle.claimCompletion(first))
        XCTAssertNil(lifecycle.activeAction)

        let current = try XCTUnwrap(lifecycle.begin(.serverStart))

        XCTAssertFalse(
            lifecycle.allowsProgress(first),
            "Queued progress from a completed action must not repaint a later action."
        )
        XCTAssertFalse(
            lifecycle.allowsProgress(current),
            "Only a model download owns progress presentation."
        )
        XCTAssertTrue(lifecycle.claimCompletion(current))
        XCTAssertFalse(
            lifecycle.claimCompletion(current),
            "An action completion must be single-consumption."
        )
    }

    func testWhisperActionLifecycleInvalidationAndTargetedCancellationRejectStaleWork() throws {
        var lifecycle = WhisperActionLifecycle()
        let detachedController = try XCTUnwrap(lifecycle.begin(.modelDownload))

        XCTAssertTrue(lifecycle.allowsProgress(detachedController))
        lifecycle.invalidate()

        XCTAssertFalse(
            lifecycle.allowsProgress(detachedController),
            "Progress queued before teardown must not update detached controls."
        )
        XCTAssertFalse(
            lifecycle.claimCompletion(detachedController),
            "An uncooperative operation completing after teardown must not alert or refresh detached UI."
        )

        let download = try XCTUnwrap(lifecycle.begin(.modelDownload))
        XCTAssertFalse(
            lifecycle.cancel(.serverStart),
            "Stopping a server must not revoke an unrelated model download."
        )
        XCTAssertTrue(lifecycle.allowsProgress(download))
        XCTAssertTrue(lifecycle.claimCompletion(download))

        let start = try XCTUnwrap(lifecycle.begin(.serverStart))
        XCTAssertTrue(lifecycle.cancel(.serverStart))
        XCTAssertNil(lifecycle.activeAction)
        XCTAssertFalse(
            lifecycle.claimCompletion(start),
            "A user-requested stop must retire startup before its backend completion arrives."
        )
    }

    func testWhisperPresentationKeepsModelDownloadBusyAcrossReadinessRefresh() {
        let checkingReadiness = WhisperReadinessPresentation.resolve(
            setupState: nil,
            isManagedByApp: false,
            hasLocalModel: false
        )
        let checking = WhisperControlsPresentation.resolve(
            readiness: checkingReadiness,
            activeAction: .modelDownload
        )
        XCTAssertNil(
            checking.modelButtonTitleKey,
            "A readiness refresh must preserve the current download percentage."
        )
        XCTAssertFalse(checking.isModelButtonHidden)
        XCTAssertFalse(checking.isModelButtonEnabled)
        XCTAssertFalse(checking.isServerButtonEnabled)

        let refreshedReadiness = WhisperReadinessPresentation.resolve(
            setupState: .installedNotRunning(binaryPath: "/opt/homebrew/bin/whisper-server"),
            isManagedByApp: false,
            hasLocalModel: false
        )
        let refreshed = WhisperControlsPresentation.resolve(
            readiness: refreshedReadiness,
            activeAction: .modelDownload
        )
        XCTAssertNil(refreshed.modelButtonTitleKey)
        XCTAssertFalse(refreshed.isModelButtonHidden)
        XCTAssertFalse(refreshed.isModelButtonEnabled)
        XCTAssertFalse(
            refreshed.isServerButtonEnabled,
            "A readiness result must not offer a conflicting action while download is active."
        )
    }

    func testWhisperPresentationKeepsServerStartCancelableAcrossReadinessRefresh() {
        for setupState in [
            WhisperServerSetup.State?.none,
            .some(.installedNotRunning(binaryPath: "/opt/homebrew/bin/whisper-server")),
            .some(.running),
        ] {
            let readiness = WhisperReadinessPresentation.resolve(
                setupState: setupState,
                isManagedByApp: setupState != nil,
                hasLocalModel: false
            )
            let presentation = WhisperControlsPresentation.resolve(
                readiness: readiness,
                activeAction: .serverStart
            )
            XCTAssertEqual(presentation.serverButtonTitleKey, "common.cancel")
            XCTAssertTrue(
                presentation.isServerButtonEnabled,
                "The only control that can cancel a pending server start must stay enabled."
            )
            XCTAssertFalse(presentation.isModelButtonEnabled)
        }
    }

    func testWhisperServerToggleDecisionCancelsStartupAndRejectsCrossActionRaces() {
        XCTAssertEqual(
            WhisperServerToggleDecision.resolve(activeAction: .serverStart, isManagedByApp: false),
            .cancelPendingStart
        )
        XCTAssertEqual(
            WhisperServerToggleDecision.resolve(activeAction: .serverStart, isManagedByApp: true),
            .cancelPendingStart
        )
        XCTAssertEqual(
            WhisperServerToggleDecision.resolve(activeAction: .modelDownload, isManagedByApp: true),
            .ignoreWhileDownloading
        )
        XCTAssertEqual(
            WhisperServerToggleDecision.resolve(activeAction: nil, isManagedByApp: true),
            .stopManagedServer
        )
        XCTAssertEqual(
            WhisperServerToggleDecision.resolve(activeAction: nil, isManagedByApp: false),
            .startServer
        )
    }

    func testWhisperPresentationStartsInCheckingAndMapsUnreachableInstallStates() {
        let checking = WhisperReadinessPresentation.resolve(
            setupState: nil,
            isManagedByApp: false,
            hasLocalModel: false
        )
        XCTAssertEqual(checking.statusKey, "status.checking")
        XCTAssertEqual(checking.tintRole, .checking)
        XCTAssertEqual(checking.serverButtonTitleKey, "status.checking")
        XCTAssertFalse(checking.isServerButtonEnabled)
        XCTAssertTrue(checking.isModelButtonHidden)
        XCTAssertFalse(checking.isModelButtonEnabled)
        XCTAssertNil(checking.detailState)

        let binaryPath = "/opt/homebrew/bin/whisper-server"
        let installed = WhisperReadinessPresentation.resolve(
            setupState: .installedNotRunning(binaryPath: binaryPath),
            isManagedByApp: false,
            hasLocalModel: false
        )
        XCTAssertEqual(installed.statusKey, "prefs.voice.speechModels.status.needsServer")
        XCTAssertEqual(installed.tintRole, .attention)
        XCTAssertEqual(installed.serverButtonTitleKey, "prefs.voice.whisper.start")
        XCTAssertTrue(installed.isServerButtonEnabled)
        XCTAssertFalse(installed.isModelButtonHidden)
        XCTAssertTrue(installed.isModelButtonEnabled)
        XCTAssertEqual(installed.detailState, .installedNotRunning(binaryPath: binaryPath))

        let missing = WhisperReadinessPresentation.resolve(
            setupState: .notInstalled,
            isManagedByApp: false,
            hasLocalModel: false
        )
        XCTAssertEqual(missing.statusKey, "prefs.voice.speechModels.status.needsSetup")
        XCTAssertEqual(missing.tintRole, .attention)
        XCTAssertEqual(missing.serverButtonTitleKey, "prefs.voice.whisper.start")
        XCTAssertTrue(missing.isServerButtonEnabled)
        XCTAssertFalse(missing.isModelButtonHidden)
        XCTAssertTrue(missing.isModelButtonEnabled)
        XCTAssertEqual(missing.detailState, .notInstalled)

        let alreadyDownloaded = WhisperReadinessPresentation.resolve(
            setupState: .notInstalled,
            isManagedByApp: false,
            hasLocalModel: true
        )
        XCTAssertTrue(alreadyDownloaded.isModelButtonHidden)
        XCTAssertFalse(alreadyDownloaded.isModelButtonEnabled)
    }

    func testReachableWhisperEndpointWinsWithoutALocalInstallAndReflectsOwnership() {
        let external = WhisperReadinessPresentation.resolve(
            setupState: .running,
            isManagedByApp: false,
            hasLocalModel: false
        )
        XCTAssertEqual(external.statusKey, "prefs.voice.speechModels.status.ready")
        XCTAssertEqual(external.tintRole, .ready)
        XCTAssertEqual(external.serverButtonTitleKey, "prefs.voice.whisper.external")
        XCTAssertFalse(external.isServerButtonEnabled)
        XCTAssertTrue(external.isModelButtonHidden)
        XCTAssertFalse(external.isModelButtonEnabled)
        XCTAssertNil(external.detailState)

        let managed = WhisperReadinessPresentation.resolve(
            setupState: .running,
            isManagedByApp: true,
            hasLocalModel: false
        )
        XCTAssertEqual(managed.statusKey, "prefs.voice.speechModels.status.ready")
        XCTAssertEqual(managed.serverButtonTitleKey, "prefs.voice.whisper.stop")
        XCTAssertTrue(managed.isServerButtonEnabled)
        XCTAssertTrue(managed.isModelButtonHidden)
        XCTAssertFalse(managed.isModelButtonEnabled)
    }

    func testPreferencesUsesGenerationGatesAtBothAsyncEndpointCallSites() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/DevTypeAppCore/PreferencesWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("localModelScanRefresh.claim("))
        XCTAssertTrue(source.contains("whisperReadinessRefresh.claim("))
        XCTAssertTrue(source.contains("geminiKeyValidationLifecycle.claim("))
        XCTAssertTrue(source.contains("prepareForLocalizationReplacement()"))
        XCTAssertTrue(source.contains("invalidateGeminiKeyValidation(resetPresentation: true)"))
        XCTAssertTrue(source.contains("whisperActionLifecycle.allowsProgress("))
        XCTAssertTrue(source.contains("whisperActionLifecycle.claimCompletion("))
        XCTAssertTrue(source.contains("whisperActionLifecycle.begin(.modelDownload)"))
        XCTAssertTrue(source.contains("whisperActionLifecycle.begin(.serverStart)"))
        XCTAssertTrue(source.contains("WhisperControlsPresentation.resolve("))
        XCTAssertTrue(source.contains("WhisperServerToggleDecision.resolve("))
        XCTAssertTrue(source.contains("whisperModelDownloadTask = Task { @MainActor [weak self] in"))
        XCTAssertTrue(source.contains("whisperServerStartTask = Task { @MainActor [weak self] in"))
        XCTAssertTrue(source.contains("WhisperServerSetup.detect(endpoint: endpoint)"))
        XCTAssertTrue(source.contains("applyWhisperReadinessPresentation()"))
        XCTAssertTrue(
            source.contains("guard !geminiKeyValidationLifecycle.isActive else { return }"),
            "An unrelated Voice reload must not replace the validating pill with Keychain state."
        )
        XCTAssertTrue(
            source.contains("NSWindow.didEndSheetNotification"),
            "A deferred language rebuild needs an explicit retry when the attached sheet closes."
        )
        XCTAssertTrue(
            source.contains("current.blocksLocalizationReplacement"),
            "Controller replacement must wait while its Gemini or Whisper operation owns the UI."
        )
        XCTAssertTrue(
            source.contains("retryDeferredLocalizationRefresh()"),
            "Both sheet dismissal and async-operation retirement must retry deferred localization."
        )
        XCTAssertEqual(
            source.components(separatedBy: "onLocalizationBlockingOperationDidEnd?()").count - 1,
            8,
            "Gemini, Apple asset, and Whisper completion/cancel/invalidation paths must all release the deferred rebuild."
        )

        let toggleStart = try XCTUnwrap(source.range(of: "@objc private func toggleWhisperServer()"))
        let invalidationStart = try XCTUnwrap(
            source.range(
                of: "private func invalidateWhisperActions()",
                range: toggleStart.upperBound..<source.endIndex
            )
        )
        let toggleBody = source[toggleStart.lowerBound..<invalidationStart.lowerBound]
        let cancelPending = try XCTUnwrap(toggleBody.range(of: "cancelPendingWhisperServerStart()"))
        let stop = try XCTUnwrap(toggleBody.range(of: "controller.stop()"))
        XCTAssertLessThan(
            cancelPending.lowerBound,
            stop.lowerBound,
            "Stop must retire the active startup request before terminating its child."
        )
        let startRequest = try XCTUnwrap(toggleBody.range(of: "begin(.serverStart)"))
        let startTask = try XCTUnwrap(toggleBody.range(of: "whisperServerStartTask = Task"))
        let pendingStartPresentation = toggleBody[startRequest.lowerBound..<startTask.lowerBound]
        XCTAssertTrue(
            pendingStartPresentation.contains("applyWhisperReadinessPresentation()"),
            "The initial pending state must use the same cancelable projection as later readiness reloads."
        )
        XCTAssertFalse(
            pendingStartPresentation.contains("whisperServerButton.isEnabled = false"),
            "Starting the server must not disable its only Cancel action."
        )

        let teardownStart = try XCTUnwrap(source.range(of: "override func viewWillDisappear()"))
        let replacementStart = try XCTUnwrap(
            source.range(
                of: "func prepareForLocalizationReplacement()",
                range: teardownStart.upperBound..<source.endIndex
            )
        )
        XCTAssertTrue(
            source[teardownStart.lowerBound..<replacementStart.lowerBound]
                .contains("invalidateWhisperActions()"),
            "Closing Preferences must invalidate progress and completion already queued for its controls."
        )

        let layoutStart = try XCTUnwrap(
            source.range(
                of: "// MARK: Layout",
                range: replacementStart.upperBound..<source.endIndex
            )
        )
        XCTAssertFalse(
            source[replacementStart.lowerBound..<layoutStart.lowerBound]
                .contains("invalidateGeminiKeyValidation("),
            "Localization must not revoke unrelated credential validation."
        )
        XCTAssertFalse(
            source[replacementStart.lowerBound..<layoutStart.lowerBound]
                .contains("invalidateWhisperActions()"),
            "Localization must not revoke a model download or server start."
        )

        let copyStart = try XCTUnwrap(source.range(of: "@objc private func copyAdvancedDiagnostics()"))
        let collectStart = try XCTUnwrap(
            source.range(of: "@objc private func collectOrphans()", range: copyStart.upperBound..<source.endIndex)
        )
        let copyBody = source[copyStart.lowerBound..<collectStart.lowerBound]
        XCTAssertTrue(
            copyBody.contains("let didWrite = DiagnosticReport.copyToPasteboard("),
            "Diagnostics copy must retain the canonical pasteboard writer's result."
        )
        XCTAssertTrue(
            copyBody.contains("AdvancedDiagnosticsCopyPresentation.resolve(didWrite: didWrite)"),
            "The UI must project the actual pasteboard result instead of assuming success."
        )
        XCTAssertTrue(
            source.contains("Self(statusKey: \"prefs.advanced.copyFailed\", tintRole: .failure)"),
            "A refused pasteboard write must surface a localized failure instead of success."
        )
    }
}
