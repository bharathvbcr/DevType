import Foundation

/// How an AI transform result is delivered to the user.
///
/// - `direct`: inject as soon as generation finishes (safe on the hotkey path).
/// - `preview`: stream into a panel for Replace / Copy / Retry / Cancel.
public enum AIOutputMode: String, Sendable, Equatable, CaseIterable {
    case direct
    case preview
}

/// Built-in on-device text transforms.
///
/// Each case carries prompt instructions, sampling temperature, a default output mode,
/// a token-budget multiplier (expected output size relative to input), and whether the
/// transform is safe to split across chunks when the input exceeds the model context.
///
/// Chunk safety: proofreading (and similar local edits) can run per paragraph without
/// changing meaning. Condense / expand refuse oversized input instead of silently
/// mangling global structure — callers consult `isChunkSafe` before splitting.
public enum AITransformKind: String, Sendable, Equatable, CaseIterable {
    case proofread
    case rewrite
    case paraphrase
    case expand
    case condense
    case formal
    case friendly
    case bulletize
    case promptEnhance = "promptenhance"
    /// Telugu / Hindi (usually typed in English letters) → English.
    case translate
    /// Grammar and spelling correction that stays in Telugu / Hindi.
    case refine
    case custom

    /// Case-insensitive lookup used by snippet `aiTransform` and the action palette.
    public static func named(_ raw: String) -> AITransformKind? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AITransformKind(rawValue: key)
    }

    /// Palette actions (excludes `custom`, which needs caller-supplied instructions).
    public static var builtInPalette: [AITransformKind] {
        allCases.filter { $0 != .custom }
    }

    /// Localization key for the human title (`ai.kind.proofread`, …).
    public var localizationKey: String {
        "ai.kind.\(rawValue)"
    }

    /// System instructions for `LanguageModelSession`. For `custom`, returns a thin
    /// wrapper; pass the real prompt via `customInstructions` on the transformer.
    public var instructions: String {
        switch self {
        case .proofread:
            return """
            You correct spelling, grammar, and punctuation in text the user supplies.
            Change nothing else: preserve the author's wording, tone, register, and line breaks.
            Do not rephrase, summarize, shorten, or answer the text. Only fix errors.
            """
        case .rewrite:
            return """
            You rewrite the user's text for clarity and flow while preserving meaning,
            facts, and roughly the same length. Keep the original language and line-break
            structure where it matters. Do not add a preamble or labels.
            """
        case .paraphrase:
            return """
            You paraphrase the user's text using different wording while preserving the
            full meaning and tone. Keep roughly the same length. Do not add commentary.
            """
        case .expand:
            return """
            You expand the user's text with relevant detail and smoother phrasing while
            staying faithful to the original intent. Do not invent facts the source does
            not support. Do not add a preamble or labels.
            """
        case .condense:
            return """
            You condense the user's text to be shorter and tighter while preserving the
            essential meaning. Drop filler, not substance. Do not add a preamble or labels.
            """
        case .formal:
            return """
            You rewrite the user's text in a clear, professional, formal register.
            Preserve meaning and structure. Do not add a preamble or labels.
            """
        case .friendly:
            return """
            You rewrite the user's text in a warm, approachable, friendly register.
            Preserve meaning and structure. Do not add a preamble or labels.
            """
        case .bulletize:
            return """
            You convert the user's text into a concise bullet list. Each bullet is one
            clear point. Preserve meaning; do not invent content. Use "- " markers.
            Do not add a preamble or labels.
            """
        case .promptEnhance:
            return """
            You rewrite the user's draft into a clearer, more effective LLM prompt.
            Improve structure, specificity, constraints, and output format while
            preserving the author's intent. Return ONLY the enhanced prompt — no
            commentary, labels, or preamble.
            """
        case .translate:
            return """
            You translate the user's text into English.

            The input is usually Telugu or Hindi typed in English letters (romanized) —
            for example "nenu intiki veltunnanu" is Telugu for "I am going home",
            "meeru ela unnaru" is Telugu for "how are you", and "main ghar ja raha hoon"
            is Hindi for "I am going home". Read such text phonetically as Telugu or
            Hindi, not as English words. Telugu and Devanagari script are also accepted.

            Preserve tone, register, and line-break structure. Leave names, numbers,
            URLs, code, and @handles exactly as written. Text that is already English
            stays as it is.

            Return ONLY the English translation — no transliteration, romanization,
            commentary, labels, or notes.
            """
        case .refine:
            return """
            You correct grammar, spelling, and word choice in the user's text and
            return it in THE SAME LANGUAGE it was written in.

            The input is usually Telugu or Hindi typed in English letters (romanized) —
            for example "nenu ninna intiki vellanu" (Telugu) or "main kal ghar gaya tha"
            (Hindi). Fix inconsistent romanized spelling, wrong verb forms, wrong gender
            or number agreement, and awkward phrasing. Telugu and Devanagari script are
            also accepted, and stay in their own script.

            Never translate. Romanized Telugu comes back as romanized Telugu; romanized
            Hindi comes back as romanized Hindi. Do not switch the text to English and do
            not convert romanized text into Telugu or Devanagari script.

            Preserve meaning, tone, register, and line-break structure. Leave names,
            numbers, URLs, code, and @handles exactly as written.

            Return ONLY the corrected text — no translation, commentary, labels, or notes.
            """
        case .custom:
            return """
            You transform the user's text according to the additional instructions
            provided with the request. Return only the transformed text.
            """
        }
    }

    public var temperature: Double {
        switch self {
        case .proofread: return 0.2
        case .rewrite: return 0.5
        case .paraphrase: return 0.6
        case .expand: return 0.7
        case .condense: return 0.3
        case .formal: return 0.4
        case .friendly: return 0.5
        case .bulletize: return 0.3
        case .promptEnhance: return 0.35
        // Translating and correcting should be reproducible, not creative.
        case .translate: return 0.2
        case .refine: return 0.2
        case .custom: return 0.5
        }
    }

    public var defaultOutputMode: AIOutputMode {
        switch self {
        case .proofread:
            return .direct
        case .rewrite, .paraphrase, .expand, .condense, .formal, .friendly, .bulletize,
             .promptEnhance, .translate, .refine, .custom:
            // Translate and refine both replace the text wholesale off a *guessed*
            // source language, and the failure mode is silent (refine quietly
            // translating to English). Preview by default; Preferences → AI can
            // switch either to direct.
            return .preview
        }
    }

    /// Expected output size relative to input tokens (used for `maximumResponseTokens`
    /// and context-window budgeting).
    public var tokenBudgetMultiplier: Double {
        switch self {
        case .proofread: return 1.15
        case .rewrite: return 1.25
        case .paraphrase: return 1.25
        case .expand: return 2.0
        case .condense: return 0.6
        case .formal: return 1.2
        case .friendly: return 1.2
        case .bulletize: return 1.1
        case .promptEnhance: return 1.4
        // Romanized Telugu / Hindi is token-hostile (it splits into many sub-word
        // pieces), so the output can be longer in tokens than the input even when
        // it is shorter in characters.
        case .translate: return 1.6
        case .refine: return 1.5
        case .custom: return 1.5
        }
    }

    /// When `true`, oversized input may be split (e.g. per paragraph) and transformed
    /// piece-wise. When `false`, the transformer must refuse rather than chunk.
    public var isChunkSafe: Bool {
        switch self {
        // Both are local edits: a paragraph translated or corrected on its own says
        // the same thing as one handled in context.
        case .proofread, .formal, .friendly, .bulletize, .translate, .refine:
            return true
        case .rewrite, .paraphrase, .expand, .condense, .promptEnhance, .custom:
            return false
        }
    }
}
