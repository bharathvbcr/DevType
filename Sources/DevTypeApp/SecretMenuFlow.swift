import AppKit
import ExpanderEngine

/// The menu-bar route to a secret: click, copy, paste yourself.
///
/// Everything else DevType does needs the keyboard. Inside a password field macOS withholds
/// keyboard events from every event tap *and* from hotkey registration (TN2150), so a typed
/// trigger is never seen and ⌘/ never fires — there is no version of DevType that can expand into
/// a password field on its own. What still works is a mouse click on the status item and an
/// ordinary pasteboard write, followed by the user's own ⌘V, which is their keystroke going to
/// their app with nothing of ours in the path.
enum SecretMenuFlow {

    /// Resolve a snippet to text, asking for Touch ID first when the snippet is a secret.
    ///
    /// **Every** read of a secret goes through here — the menu, the copy palette, the insert
    /// palette. Putting the gate in the resolver rather than at each call site is what makes it
    /// impossible for the next surface that wants a secret to forget it; `SourceContractTests`
    /// pins that no one calls `SecretStore.secret(for:)` directly.
    ///
    /// Completion is on the main queue, always, so callers can touch AppKit without thinking.
    static func resolve(
        _ snippet: SnippetModel,
        secretStore: SecretStore = .shared,
        gate: BiometricGate = .shared,
        preferenceEnabled: Bool? = nil,
        clipboardText: String? = nil,
        lookup: ((String) -> String?)? = nil,
        loc: LocalizationManager = .shared,
        completion: @escaping (Result<String, ResolveFailure>) -> Void
    ) {
        let availability = gate.availability()
        let enabled = preferenceEnabled
            ?? SecretPreferences.requireBiometry(availability: availability)

        guard BiometricGate.shouldGate(
            isSecret: snippet.isSecret,
            preferenceEnabled: enabled,
            availability: availability
        ) else {
            completion(
                resolveForCopy(
                    snippet,
                    secretStore: secretStore,
                    clipboardText: clipboardText,
                    lookup: lookup
                )
            )
            return
        }

        // The prompt names the snippet, never its value: this string is rendered by macOS in a
        // system dialog and, on a shared screen, is the one part of this flow everyone can read.
        gate.authorize(reason: loc.s("secret.auth.reason", snippet.displayTitle)) { outcome in
            switch outcome {
            case .authorized:
                completion(
                    resolveForCopy(
                        snippet,
                        secretStore: secretStore,
                        clipboardText: clipboardText,
                        lookup: lookup
                    )
                )
            case .cancelled:
                completion(.failure(.authenticationCancelled))
            case .failed(let reason):
                completion(.failure(.authenticationFailed(reason)))
            }
        }
    }

    /// Resolve without asking. Not for direct use by UI: `resolve` is the gated entry point, and
    /// this exists only as the step that runs *after* authorization has been established.
    ///
    /// A secret is fetched from the keychain and used **verbatim** — never run through
    /// `MacroRenderer`. A password containing `{{` or `%` is not a template, and expanding one
    /// would either corrupt it silently or, worse, resolve `{{snippet:…}}` inside it.
    static func resolveForCopy(
        _ snippet: SnippetModel,
        secretStore: SecretStore = .shared,
        clipboardText: String? = nil,
        lookup: ((String) -> String?)? = nil
    ) -> Result<String, ResolveFailure> {
        if snippet.isSecret {
            guard let value = secretStore.secret(for: snippet.id), !value.isEmpty else {
                return .failure(.secretUnavailable)
            }
            return .success(value)
        }
        // An image snippet has no text to render. Reporting it as "empty" was wrong twice: it is
        // not empty, and the advice implied there was something to go and fix.
        if snippet.isImageSnippet {
            return .failure(.imageSnippet(snippet.imagePath))
        }
        let rendered = MacroRenderer.expand(
            content: snippet.replacementText,
            lookup: lookup ?? { _ in nil },
            clipboardText: clipboardText
        )
        guard !rendered.text.isEmpty else { return .failure(.emptySnippet) }
        return .success(rendered.text)
    }

    enum ResolveFailure: Error, Equatable {
        /// Marked secret, but the keychain has nothing (or refused to answer).
        case secretUnavailable
        /// An image snippet: copyable, but as image data rather than as text.
        case imageSnippet(String)
        /// A plain snippet that renders to nothing — copying "" would silently wipe the clipboard.
        case emptySnippet
        /// The user dismissed the Touch ID prompt. Their own decision, already visible to them:
        /// callers must stay silent rather than answer it with a dialog of our own.
        case authenticationCancelled
        /// Authentication could not complete — biometry lockout, no password set. Carries the
        /// system's own wording, which is more accurate than anything we would invent.
        case authenticationFailed(String)

        /// True when the user already knows what happened because they did it.
        var isSilent: Bool { self == .authenticationCancelled }
    }

    /// Pure policy: which snippets appear in the mouse-only *Copy Secret* submenu, and in what
    /// order? Secrets only, most recently updated first, so the one just added is at the top.
    static func secretMenuEntries(from snippets: [SnippetModel], limit: Int = 20) -> [SnippetModel] {
        SecretMenuEntryPolicy.entries(from: snippets, limit: limit)
    }
}
