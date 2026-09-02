import Foundation

/// The transforms DevType performs itself, with no model in the loop.
///
/// `AITransformKind` is the app's whole vocabulary of "do this to my selection" — it feeds
/// the AI palette, the ⌘/ command palette, the Preferences output-mode list, snippet
/// `aiTransform`, and voice triggers. A transform that belongs in that vocabulary but does
/// not need a language model should still live there, and should not have to pretend.
///
/// `removeMarkdown` is the first such transform. `AIMarkdownStripper` already answers it
/// exactly, so routing it through a session would only add latency, non-determinism, a
/// refusal path, and a hard dependency on macOS 26 — while producing a worse answer.
///
/// Every entry point checks here first (`AITextTransformer.transform`, the direct and
/// preview flows in the app), so there is one implementation rather than one per caller,
/// and a kind added to this file becomes available everywhere at once.
public enum AILocalTransform {

    /// Whether this kind is answered here rather than by the model.
    public static func handles(_ kind: AITransformKind) -> Bool {
        !kind.requiresModel
    }

    /// Runs `kind` locally, or returns `nil` when it needs the model.
    ///
    /// `nil` rather than a thrown error so callers read as "local first, model otherwise"
    /// — a caller that forgets the check still behaves correctly, just without the
    /// short-circuit.
    public static func run(kind: AITransformKind, input: String) -> Result<String, AITransformError>? {
        switch kind {
        case .removeMarkdown:
            return .success(removingMarkdown(from: input))

        case .proofread, .rewrite, .paraphrase, .expand, .condense, .mergeRewrite,
             .formal, .friendly, .bulletize, .promptEnhance, .explainCode,
             .generateDocstring, .fixCode, .toJson, .generateUnitTests,
             .gitCommitMessage, .explainRegex, .sqlQuery,
             .translate, .translateTelugu, .translateHindi, .custom, .toMarkdown:
            return nil
        }
    }

    // MARK: - removeMarkdown

    /// Two things this does differently from the automatic pass that runs on every AI
    /// answer, and both follow from it being something the user asked for by name:
    ///
    /// 1. **No ownership rule.** The automatic pass never removes a construct the source
    ///    text already used — proofreading a README has to give the README back. Here the
    ///    source text *is* the Markdown, and preserving it would remove the entire point
    ///    of the action. So `original` is empty: everything goes.
    /// 2. **No preference check.** `AIPreferences.removesMarkdown` governs whether DevType
    ///    tidies up after a model on its own. Choosing "Remove Markdown" from a palette is
    ///    not DevType deciding anything; declining to obey it because of a background
    ///    setting would be a bug report.
    ///
    /// The selection's own leading and trailing whitespace is put back, so replacing a
    /// mid-sentence selection does not weld words together.
    static func removingMarkdown(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return input }

        let stripped = AIMarkdownStripper.strip(
            trimmed,
            policy: AITransformKind.removeMarkdown.markdownPolicy,
            original: ""
        )
        return AITransformText.restoringAffixes(of: input, to: stripped)
    }
}
