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

    /// Resolve what a snippet should put on the clipboard.
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
        /// A plain snippet that renders to nothing — copying "" would silently wipe the clipboard.
        case emptySnippet
    }

    /// Pure policy: which snippets appear in the mouse-only *Copy Secret* submenu, and in what
    /// order? Secrets only, most recently updated first, so the one just added is at the top.
    static func secretMenuEntries(from snippets: [SnippetModel], limit: Int = 20) -> [SnippetModel] {
        SecretMenuEntryPolicy.entries(from: snippets, limit: limit)
    }
}
