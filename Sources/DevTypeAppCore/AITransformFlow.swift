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

        // The model being unavailable does not make every action unavailable. Open the
        // panel with the ones that run locally and let it say why the list is short —
        // Apple Intelligence needs macOS 26 and DevType supports macOS 14, so refusing
        // outright turns most users away from transforms that would have worked.
        //
        // Refuse only when nothing at all would be offered; an empty picker is worse than
        // the alert it replaced.
        let modelUnavailable: AIModelAvailability.Reason?
        switch AITextTransformSupport.availability {
        case .available:
            modelUnavailable = nil
        case .unavailable(let reason):
            guard !AITransformKind.palette(modelAvailable: false).isEmpty else {
                softAlert(
                    title: loc.s("ai.alert.unavailable.title"),
                    message: localizedAvailability(reason, loc: loc),
                    loc: loc
                )
                return
            }
            modelUnavailable = reason
        }

        // Before the selection read, and long before the model: `AIActionPanel` captures whatever
        // is frontmost now as the source app, and `SourceAppDelivery` refuses to deliver into our
        // own process. Invoked with a DevType window in front, every one of those steps runs — the
        // read, the picker, the generation — and the finished result is then thrown away at the
        // delivery guard. Asking the delivery's own entry gate up front turns a transform the user
        // watched happen and lost into an instant, accurate refusal.
        //
        // `.noSourceSelection` already says the right thing ("DevType is in front, so there is no
        // selected text behind it to read — switch to your text") in every shipped language.
        if SourceAppDelivery.entryUnavailability(sourceApp: NSWorkspace.shared.frontmostApplication)
            == .ownProcess {
            softAlert(
                title: SelectionReader.Failure.noSourceSelection.title(loc: loc),
                message: SelectionReader.Failure.noSourceSelection.message(loc: loc),
                loc: loc
            )
            return
        }

        // Typed outcome, not `Result?`: the reason decides the message. "Select text first" is
        // actively misleading when the real cause is a revoked AX grant or Secure Input.
        //
        // Clipboard fallback on: this is the one explicit-gesture path where a brokered ⌘C as a
        // last resort is right — the captured text is shown in the action panel before anything
        // is written back, so a bad capture is visible and cancellable.
        let selection: SelectionReader.Result
        switch SelectionReader.readSelectionForExplicitAIAction() {
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

        AIActionPanel.present(
            input: selection.text,
            source: selection.source,
            loc: loc,
            modelUnavailable: modelUnavailable
        ) { picked, sourceApp in
            // `picked.customInstructions` is the whole contract of a `.custom` pick — the kind's
            // own prompt is a wrapper with no direction in it. Dropping it here (this argument
            // was hard-coded `nil`) ran the model on nothing.
            run(
                input: selection.text,
                kind: picked.kind,
                sourceApp: sourceApp,
                customInstructions: picked.customInstructions,
                forcePreview: picked.requiresPreview,
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
        // Held for the lifetime of the transform. The completion below is guaranteed to run
        // exactly once (`AITransformOnceCompletion`, including on discard), and even if that
        // guarantee were ever broken, dropping the last reference to this token releases it.
        let suspension = EventTapEngine.shared.suspendMatching(reason: "AITransformFlow")

        // Local kinds work on every OS DevType supports, so they are answered before the
        // availability branch below — which would otherwise refuse them on any Mac without
        // Apple Intelligence, for a transform that never wanted it.
        if let local = AILocalTransform.run(kind: kind, input: input) {
            suspension.release()
            switch local {
            case .success(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    softAlert(
                        title: loc.s("ai.alert.failed.title"),
                        message: localizedError(.decodingFailure, loc: loc),
                        loc: loc
                    )
                    sourceApp?.activate()
                    return
                }
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
            return
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            Task { await AITextTransformer.shared.prewarm(kind: kind) }
            _ = AITextTransformer.shared.transform(
                kind: kind,
                input: input,
                customInstructions: customInstructions,
                completionQueue: .main
            ) { result in
                suspension.release()
                switch result {
                case .success(let text):
                    // Never let a blank result erase the selection on the direct path.
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        softAlert(
                            title: loc.s("ai.alert.failed.title"),
                            message: localizedError(.decodingFailure, loc: loc),
                            loc: loc
                        )
                        sourceApp?.activate()
                        return
                    }
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

        suspension.release()
        softAlert(
            title: loc.s("ai.alert.unavailable.title"),
            message: localizedAvailability(.unsupportedOS, loc: loc),
            loc: loc
        )
    }

    /// `AITransformError.localizationKey` owns which string each case shows; this only supplies
    /// the format arguments. It used to restate the whole mapping, so a new case had to be
    /// added in two places that nothing kept in step.
    static func localizedError(_ error: AITransformError, loc: LocalizationManager) -> String {
        switch error {
        case .inputTooLarge(let estimated, let context):
            return loc.s(error.localizationKey, estimated, context)
        case .unknown(let message):
            let detail = message.isEmpty ? "—" : message
            return loc.s(error.localizationKey, detail)
        default:
            return loc.s(error.localizationKey)
        }
    }

    static func localizedAvailability(
        _ reason: AIModelAvailability.Reason,
        loc: LocalizationManager
    ) -> String {
        loc.s(reason.localizationKey)
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
