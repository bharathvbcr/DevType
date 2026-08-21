import Foundation

/// Process-wide prompt-leak guardrail for the on-device AI transforms.
///
/// The pipeline sends three static surfaces to the model — per-kind system instructions,
/// a per-kind framing line, and the user's selection — and injects the answer back into
/// the user's document. The on-device model sometimes copies prompt text into its reply,
/// and on the direct path that lands in a document with no review. `AIPromptEcho` strips
/// and flags echoes during generation; this type is the *system-wide* layer over it:
///
/// 1. **One corpus.** Every static prompt surface across every transform kind,
///    clause-extracted once, so new kinds are covered without touching call sites.
///    Custom (user-authored) instructions stay excluded — matching them would risk
///    eating legitimate content whenever they overlap the selection, same scope note
///    as `AIPromptEcho`.
/// 2. **Injection verdict.** A last-line check at the delivery seam: an AI result is
///    injected only if it carries no unrecognized prompt clause. Phrases the author's
///    own selection contains never count — the author's text always wins.
/// 3. **Redaction.** Free-form third-party strings (Apple's `GenerationError.Context`
///    prose) are scrubbed of any known prompt surface or selection text before they
///    reach OSLog or the diagnostics store.
///
/// Failure posture is fail-closed and quiet-free: a refused injection leaves the
/// user's field untouched and records why; it never silently rewrites content.
public enum AIPromptLeakGuard {

    /// Normalized clauses from every static prompt surface, longest first.
    ///
    /// Built once from all transform kinds — framings and instruction blocks alike —
    /// so an echoed sentence like "Return only the corrected text — no commentary,
    /// labels, or quotes." is caught exactly like the framing echo it accompanies.
    public static let phrases: [String] = {
        var found = Set<String>()
        for kind in AITransformKind.allCases {
            found.formUnion(AIPromptEcho.phrases(framing: kind.framing))
            found.formUnion(AIPromptEcho.phrases(framing: kind.instructions))
        }
        return found.sorted { $0.count > $1.count }
    }()

    /// Per-kind corpus: that kind's framing clauses plus its instruction clauses.
    /// Used inside generation where the kind is known and stripping should not be
    /// confused by other kinds' wording.
    public static func phrases(for kind: AITransformKind) -> [String] {
        phrasesForKind[kind] ?? []
    }

    private static let phrasesForKind: [AITransformKind: [String]] = {
        var map: [AITransformKind: [String]] = [:]
        for kind in AITransformKind.allCases {
            var found = Set<String>()
            found.formUnion(AIPromptEcho.phrases(framing: kind.framing))
            found.formUnion(AIPromptEcho.phrases(framing: kind.instructions))
            map[kind] = found.sorted { $0.count > $1.count }
        }
        return map
    }()

    // MARK: - Contamination

    /// True when `output` still quotes any prompt clause after stripping, unless the
    /// author's own input contains that clause. Mirrors `AIPromptEcho.contaminated`
    /// over the wider corpus.
    public static func contaminated(output: String, input: String) -> Bool {
        AIPromptEcho.contaminated(output: output, input: input, phrases: phrases)
    }

    public struct Verdict: Equatable, Sendable {
        /// Normalized clause that matched, or `nil` when the payload is clean.
        /// Diagnostic only — normalized form, never enough to reconstruct prose.
        public let matchedPhrase: String?
        public var isClean: Bool { matchedPhrase == nil }

        public static let clean = Verdict(matchedPhrase: nil)
    }

    /// Last-line delivery check for an AI-generated payload about to enter a user
    /// document. `exempting` is the source selection the result replaces: clauses it
    /// contains are treated as authored text and never block delivery, so writing
    /// *about* the feature cannot trap one's own words.
    ///
    /// With no exemption available (`nil`) the raw corpus applies; a false refusal
    /// costs one alert and leaves the field untouched — never data loss.
    public static func injectionVerdict(
        payload: String,
        exempting input: String?
    ) -> Verdict {
        guard !payload.isEmpty else { return .clean }
        let exempt = input.map(AIPromptEcho.normalized) ?? ""
        let outputNormalized = AIPromptEcho.normalized(payload)
        guard !outputNormalized.isEmpty else { return .clean }
        for phrase in phrases where !exempt.contains(phrase) {
            if outputNormalized.contains(phrase) {
                return Verdict(matchedPhrase: phrase)
            }
        }
        return .clean
    }

    // MARK: - Redaction

    /// Where an injection payload came from — declared at the delivery seam so the
    /// compiler forces every caller to state whether the text is model output
    /// (guarded) or the author's own words (exempt by design, mirroring
    /// `AIPromptEcho`'s rule that authored text always wins).
    public enum PayloadOrigin: Sendable {
        /// Model output heading into a document. Subject to `injectionVerdict`;
        /// `sourceSelection` exempts clauses the author selected themselves.
        case aiResult(sourceSelection: String?)
        /// Authored text being re-injected verbatim (an erased trigger restored on
        /// cancel, or an Undo of a previous replace). Never refused.
        case authoredText
    }

    /// Sources shorter than this are skipped: a two- or three-character selection
    /// ("hi", "ok") matches incidentally inside ordinary diagnostic prose and would
    /// shred it without protecting anything meaningful.
    static let minimumRedactableSourceLength = 4

    /// Per-source scan cap. Apple's context prose is short; bounding the needle
    /// bounds the whole operation even for a maximum-size selection.
    static let maximumRedactableSourceLength = 2_000

    /// Replacement marker for scrubbed spans. Deliberately bracketed so a redacted
    /// report reads as redacted rather than as corrupted text.
    public static let redactionMarker = "[redacted]"

    /// Maximum replacements per source before giving up — pathological inputs
    /// (a repeated phrase thousands of times) must not spin the scanner.
    static let maximumReplacementsPerSource = 32

    /// Removes occurrences of known sensitive strings from a free-form detail string
    /// before it is logged or stored. Case-insensitive, diacritic-insensitive; each
    /// source is replaced everywhere it appears until none remain (or the per-source
    /// replacement bound trips).
    ///
    /// Multi-line sources (the prompt surfaces carry their own line breaks) are also
    /// matched against single-space-joined and newline-stripped variants — prose that
    /// quotes a multi-line prompt flattens its whitespace.
    ///
    /// Used for strings we do not author — Apple's `GenerationError` context prose is
    /// documented as describing the violation rather than quoting the input, but it is
    /// still third-party free-form text entering our logs and the diagnostics store,
    /// so the scrub makes leaking through it impossible rather than merely unlikely.
    public static func redact(_ detail: String, sources: [String]) -> String {
        var out = detail
        for source in sources {
            for candidate in sourceVariants(source) {
                var replacements = 0
                while replacements < Self.maximumReplacementsPerSource,
                      let range = out.range(
                        of: candidate,
                        options: [.caseInsensitive, .diacriticInsensitive]
                      ) {
                    out.replaceSubrange(range, with: redactionMarker)
                    replacements += 1
                }
            }
        }
        return out
    }

    private static func sourceVariants(_ source: String) -> [String] {
        let capped = String(source.prefix(maximumRedactableSourceLength))
        guard capped.count >= minimumRedactableSourceLength else { return [] }
        // Deduped so a single-line source is scanned once and the replacement bound
        // applies per source, not once per redundant variant.
        var seen = Set<String>()
        return [capped,
                capped.replacingOccurrences(of: "\n", with: " "),
                capped.replacingOccurrences(of: "\n", with: "")]
            .filter { $0.count >= minimumRedactableSourceLength && seen.insert($0).inserted }
    }
}
