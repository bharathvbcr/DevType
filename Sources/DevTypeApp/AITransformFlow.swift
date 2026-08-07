import AppKit
import ExpanderEngine

/// Shared entry points for the AI hotkey palette and the typed-path engine handoff.
///
/// Keeps model work off the expansion pipeline: panels own focus, then inject via
/// `erasePlan: .empty` + `secureClipboardPaste: true` (same shape as inline search).
enum AITransformFlow {
    /// Hotkey path: gate on prefs / OS / selection, then show the action picker.
    static func presentFromHotkey(
        loc: LocalizationManager = .shared,
        onInject: @escaping (String, NSRunningApplication?) -> Void
    ) {
        guard AIPreferences.isEnabled else {
            softAlert(
                title: loc.s("ai.alert.disabled.title"),
                message: loc.s("ai.alert.disabled.message"),
                loc: loc
            )
            return
        }

        switch AITextTransformSupport.availability {
        case .available:
            break
        case .unavailable(let reason):
            softAlert(
                title: loc.s("ai.alert.unavailable.title"),
                message: localizedAvailability(reason, loc: loc),
                loc: loc
            )
            return
        }

        // Typed outcome, not `Result?`: the reason decides the message. "Select text first" is
        // actively misleading when the real cause is a revoked AX grant or Secure Input.
        let selection: SelectionReader.Result
        switch SelectionReader.readSelection() {
        case .selection(let resolved):
            selection = resolved
        case .failure(let failure):
            softAlert(
                title: failure.title(loc: loc),
                message: failure.message(loc: loc),
                loc: loc
            )
            return
        }

        AIActionPanel.present(input: selection.text, loc: loc) { kind, sourceApp in
            run(
                input: selection.text,
                kind: kind,
                sourceApp: sourceApp,
                customInstructions: nil,
                forcePreview: false,
                loc: loc,
                onInject: onInject
            )
        }
    }

    /// Typed / engine path: always preview in phase 1 (no headless direct-replace).
    /// `restoreOnCancel` is the erased trigger text — re-injected via `erasePlan: .empty` if
    /// the user dismisses the preview so they are not left with neither trigger nor result.
    static func presentFromEngine(
        input: String,
        kind: AITransformKind,
        sourceApp: NSRunningApplication?,
        customInstructions: String? = nil,
        restoreOnCancel: String? = nil,
        loc: LocalizationManager = .shared,
        onInject: @escaping (String, NSRunningApplication?) -> Void
    ) {
        run(
            input: input,
            kind: kind,
            sourceApp: sourceApp,
            customInstructions: customInstructions,
            forcePreview: true,
            restoreOnCancel: restoreOnCancel,
            loc: loc,
            onInject: onInject
        )
    }

    /// Shared transform entry: resolves output mode, then direct-inject or preview panel.
    static func run(
        input: String,
        kind: AITransformKind,
        sourceApp: NSRunningApplication?,
        customInstructions: String?,
        forcePreview: Bool,
        restoreOnCancel: String? = nil,
        loc: LocalizationManager = .shared,
        onInject: @escaping (String, NSRunningApplication?) -> Void
    ) {
        let mode: AIOutputMode = forcePreview
            ? .preview
            : AIPreferences.outputMode(for: kind)

        switch mode {
        case .preview:
            AIPreviewPanel.present(
                input: input,
                kind: kind,
                sourceApp: sourceApp,
                customInstructions: customInstructions,
                restoreOnCancel: restoreOnCancel,
                loc: loc,
                onReplace: onInject
            )
        case .direct:
            runDirect(
                input: input,
                kind: kind,
                sourceApp: sourceApp,
                customInstructions: customInstructions,
                loc: loc,
                onInject: onInject
            )
        }
    }

    private static func runDirect(
        input: String,
        kind: AITransformKind,
        sourceApp: NSRunningApplication?,
        customInstructions: String?,
        loc: LocalizationManager,
        onInject: @escaping (String, NSRunningApplication?) -> Void
    ) {
        EventTapEngine.shared.suspendMatching()

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            Task { await AITextTransformer.shared.prewarm(kind: kind) }
            _ = AITextTransformer.shared.transform(
                kind: kind,
                input: input,
                customInstructions: customInstructions,
                completionQueue: .main
            ) { result in
                EventTapEngine.shared.resumeMatching()
                switch result {
                case .success(let text):
                    AIUndoStore.stash(input)
                    onInject(text, sourceApp)
                case .failure(let error):
                    if case .discarded = error { return }
                    softAlert(
                        title: loc.s("ai.alert.failed.title"),
                        message: localizedError(error, loc: loc),
                        loc: loc
                    )
                    sourceApp?.activate()
                }
            }
            return
        }
        #endif

        EventTapEngine.shared.resumeMatching()
        softAlert(
            title: loc.s("ai.alert.unavailable.title"),
            message: localizedAvailability(.unsupportedOS, loc: loc),
            loc: loc
        )
    }

    static func localizedError(_ error: AITransformError, loc: LocalizationManager) -> String {
        switch error {
        case .unavailable(let reason):
            return localizedAvailability(reason, loc: loc)
        case .busy:
            return loc.s("ai.error.busy")
        case .emptyInput:
            return loc.s("ai.error.emptyInput")
        case .inputTooLarge(let estimated, let context):
            return loc.s("ai.error.inputTooLarge", estimated, context)
        case .guardrailViolation:
            return loc.s("ai.error.guardrail")
        case .exceededContextWindowSize:
            return loc.s("ai.error.contextWindow")
        case .rateLimited:
            return loc.s("ai.error.rateLimited")
        case .unsupportedLanguageOrLocale:
            return loc.s("ai.error.language")
        case .assetsUnavailable:
            return loc.s("ai.error.assets")
        case .decodingFailure:
            return loc.s("ai.error.decoding")
        case .refusal:
            return loc.s("ai.error.refusal")
        case .concurrentRequests:
            return loc.s("ai.error.busy")
        case .unsupportedGuide:
            return loc.s("ai.error.unsupportedGuide")
        case .discarded:
            return loc.s("ai.error.discarded")
        case .unknown(let message):
            let detail = message.isEmpty ? "—" : message
            return loc.s("ai.error.unknown", detail)
        }
    }

    static func localizedAvailability(
        _ reason: AIModelAvailability.Reason,
        loc: LocalizationManager
    ) -> String {
        switch reason {
        case .unsupportedOS:
            return loc.s("ai.availability.unsupportedOS")
        case .deviceNotEligible:
            return loc.s("ai.availability.deviceNotEligible")
        case .appleIntelligenceNotEnabled:
            return loc.s("ai.availability.notEnabled")
        case .modelNotReady:
            return loc.s("ai.availability.modelNotReady")
        }
    }

    private static func softAlert(title: String, message: String, loc: LocalizationManager) {
        DevTypeAlert.present(
            title: title,
            message: message,
            style: .informational,
            buttons: [loc.s("common.ok")],
            handler: nil
        )
    }
}
