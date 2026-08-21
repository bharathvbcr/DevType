import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Availability / errors (no FoundationModels dependency)

/// On-device model readiness, mapped for UI localization later.
public enum AIModelAvailability: Equatable, Sendable {
    case available
    case unavailable(Reason)

    public enum Reason: Equatable, Sendable {
        /// Process is running below macOS 26, or FoundationModels is not linked.
        case unsupportedOS
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
    }
}

/// Failures from an AI transform. Cases are localization-key friendly; the UI maps them.
public enum AITransformError: Error, Equatable, Sendable {
    case unavailable(AIModelAvailability.Reason)
    /// Another transform is already in flight (single-flight guard).
    case busy
    case emptyInput
    case inputTooLarge(estimatedTokens: Int, contextSize: Int)
    case guardrailViolation
    case exceededContextWindowSize
    case rateLimited
    case unsupportedLanguageOrLocale
    case assetsUnavailable
    case decodingFailure
    case refusal
    case concurrentRequests
    /// Guided-generation schema / guide was rejected by the model.
    case unsupportedGuide
    /// The model answered in a writing system the transform forbids (e.g. English
    /// proofread coming back in Devanagari). Nothing is injected.
    case languageDrift
    /// The model rewrote or answered the text instead of correcting it. Nothing is
    /// injected — a proofread that doubles in length is not a proofread.
    case unexpectedRewrite
    /// The model copied part of the prompt (the framing line / instructions) into its
    /// answer. Nothing is injected — "Proofread the text below…" must never appear in
    /// the user's document.
    case promptEcho
    /// Caller discarded the result (Cancel). Generation may still finish; do not inject.
    case discarded
    case unknown(String)
}

/// Handle returned from a GCD-style transform. Call `discard()` to cancel delivery —
/// the model may keep running, but the completion will not succeed afterward.
public final class AITransformDiscardHandle: @unchecked Sendable {
    private let once: AITransformOnceCompletion

    fileprivate init(once: AITransformOnceCompletion) {
        self.once = once
    }

    /// Completes exactly once with `.discarded` if still pending. Late successes are dropped.
    public func discard() {
        once.complete(.failure(.discarded))
    }
}

/// Ensures a transform completion handler runs at most once, on a chosen queue.
fileprivate final class AITransformOnceCompletion: @unchecked Sendable {
    private let lock = UnfairLock()
    private let queue: DispatchQueue
    private var handler: (@Sendable (Result<String, AITransformError>) -> Void)?

    init(
        queue: DispatchQueue,
        handler: @escaping @Sendable (Result<String, AITransformError>) -> Void
    ) {
        self.queue = queue
        self.handler = handler
    }

    func complete(_ result: Result<String, AITransformError>) {
        let pending: (@Sendable (Result<String, AITransformError>) -> Void)? = lock.withLock {
            let h = handler
            handler = nil
            return h
        }
        guard let pending else { return }
        queue.async { pending(result) }
    }
}

// MARK: - Token budget (no FoundationModels dependency)

/// Pure context-window budgeting (no live model). Used by `AITextTransformer` and unit tests.
public enum AITokenBudget {
    /// Tokens reserved for guided-generation schema + prompt framing overhead.
    public static let schemaReserveTokens = 160
    public static let minimumResponseTokens = 32

    /// Heuristic used when `tokenCount(for:)` is unavailable.
    public static func estimateTokensHeuristic(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }

    /// Returns the clamped `maximumResponseTokens` for generation, or throws `.inputTooLarge`.
    public static func evaluate(
        inputTokens: Int,
        instructionTokens: Int,
        framingTokens: Int,
        contextSize: Int,
        tokenBudgetMultiplier: Double
    ) throws -> Int {
        let rawMax = Int((Double(inputTokens) * tokenBudgetMultiplier).rounded(.up))
        let maxResponse = max(minimumResponseTokens, rawMax)

        let estimated =
            instructionTokens
            + inputTokens
            + framingTokens
            + schemaReserveTokens
            + maxResponse

        if estimated > contextSize {
            throw AITransformError.inputTooLarge(
                estimatedTokens: estimated,
                contextSize: contextSize
            )
        }

        let fixed =
            instructionTokens + inputTokens + framingTokens + schemaReserveTokens
        let room = max(minimumResponseTokens, contextSize - fixed)
        return min(maxResponse, room)
    }
}

// MARK: - Pure text plumbing (no FoundationModels dependency)

/// Input/output shaping shared by `AITextTransformer` and unit tests.
public enum AITransformText {

    /// One paragraph (or line) plus the whitespace that separated it from the next.
    /// Chunked transforms rejoin with the *original* separators — a fixed "\n\n"
    /// silently rewrites the author's spacing, which proofread promises not to do.
    public struct Segment: Equatable, Sendable {
        public let body: String
        public let separator: String

        public init(body: String, separator: String) {
            self.body = body
            self.separator = separator
        }
    }

    public enum Granularity: Sendable {
        /// Paragraphs, falling back to lines when the text is one paragraph.
        case automatic
        /// Every line break starts a new segment.
        case line
    }

    /// Paragraph split; falls back to a line split when the text is one paragraph,
    /// so a long unbroken block still has somewhere to break rather than refusing.
    public static func segments(
        _ text: String,
        granularity: Granularity = .automatic
    ) -> [Segment] {
        if granularity == .line { return split(text, minimumNewlines: 1) }
        let paragraphs = split(text, minimumNewlines: 2)
        if paragraphs.count > 1 { return paragraphs }
        let lines = split(text, minimumNewlines: 1)
        return lines.count > 1 ? lines : paragraphs
    }

    /// Whether a result kept the input's exact line shape — same number of lines and
    /// the same breaks between them. The on-device model reliably flattens multi-line
    /// input, or quietly eats blank lines, however firmly the prompt asks it not to,
    /// so proofread verifies the shape instead of trusting it.
    public static func preservesLineStructure(input: String, output: String) -> Bool {
        segments(input, granularity: .line).map(\.separator)
            == segments(output, granularity: .line).map(\.separator)
    }

    public static func joined(_ segments: [Segment], bodies: [String]) -> String {
        var out = ""
        for (index, segment) in segments.enumerated() {
            out += (index < bodies.count ? bodies[index] : segment.body)
            out += segment.separator
        }
        return out
    }

    private static func split(_ text: String, minimumNewlines: Int) -> [Segment] {
        var result: [Segment] = []
        var body = ""
        var pending = ""
        var newlines = 0

        func closeSegment(with separator: String) {
            if !body.isEmpty {
                result.append(Segment(body: body, separator: separator))
                body = ""
            } else if let last = result.popLast() {
                result.append(Segment(body: last.body, separator: last.separator + separator))
            }
        }

        for character in text {
            if character.isWhitespace {
                pending.append(character)
                if character.isNewline { newlines += 1 }
                continue
            }
            if newlines >= minimumNewlines {
                closeSegment(with: pending)
            } else {
                body += pending
            }
            pending = ""
            newlines = 0
            body.append(character)
        }
        closeSegment(with: pending)
        return result
    }

    /// Re-attaches the selection's own leading / trailing whitespace to a result.
    /// The model is handed trimmed input, so without this a selection like
    /// `" hello "` is replaced by `"hello"` and words weld together in the field.
    public static func restoringAffixes(of original: String, to result: String) -> String {
        let core = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return result }
        return leadingWhitespace(original) + core + trailingWhitespace(original)
    }

    public static func leadingWhitespace(_ text: String) -> String {
        String(text.prefix(while: { $0.isWhitespace }))
    }

    public static func trailingWhitespace(_ text: String) -> String {
        String(text.reversed().prefix(while: { $0.isWhitespace }).reversed())
    }

    /// Strips wrappers the model adds on its own — a code fence or a pair of quotes
    /// the input never had. Anything the input already carried is left alone.
    public static func sanitize(_ text: String, input: String) -> String {
        var out = text

        if !input.contains("```") {
            let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.count >= 2,
               lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
               lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" {
                out = lines.dropFirst().dropLast().joined(separator: "\n")
            }
        }

        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputTrimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'")]
        for (open, close) in pairs {
            guard trimmed.count >= 2, trimmed.first == open, trimmed.last == close else { continue }
            let inner = String(trimmed.dropFirst().dropLast())
            // An interior quote means the pair is probably the author's, not a wrapper.
            guard !inner.contains(open), !inner.contains(close) else { continue }
            guard !(inputTrimmed.first == open && inputTrimmed.last == close) else { continue }
            out = inner
            break
        }
        return out
    }
}

/// How far a result may drift in size from the text it came from.
///
/// A correction stays about as long as the original. When the model answers the text
/// instead of correcting it — it does this with questions and instructions — the reply
/// balloons, and on the direct path that lands in the user's field with no review.
public enum AILengthPolicy: Sendable, Equatable {
    /// Roughly the same size, with slack for short inputs where one fix moves the
    /// ratio a lot ("hi" → "Hi, there.").
    case correction
    case unconstrained

    /// Characters of slack before the ratio applies at all.
    static let floorCharacters = 40
    static let maximumGrowth = 2.0

    public func exceeded(input: String, output: String) -> Bool {
        guard self == .correction else { return false }
        let limit = max(
            Self.floorCharacters,
            Int(Double(input.count) * Self.maximumGrowth)
        )
        return output.count > limit
    }
}

/// Writing systems a transform is allowed to answer in.
///
/// The prompt asks; this enforces. A small on-device model answering English input
/// in Devanagari — the bug this shipped to fix — is invisible to every other check,
/// and on the direct path it lands in the user's field unreviewed.
public enum AIScriptPolicy: Sendable, Equatable {
    /// The reply may only use scripts the input already used (proofread).
    case sameAsInput
    /// The reply must be Latin letters (romanized Telugu / Hindi, or English).
    case latinOnly
    case unconstrained

    /// `nil` when the output is acceptable, else the offending script's name.
    public func violation(input: String, output: String) -> String? {
        switch self {
        case .unconstrained:
            return nil
        case .latinOnly:
            return AIScriptFamily.families(in: output)
                .subtracting([.latin])
                .first?
                .rawValue
        case .sameAsInput:
            return AIScriptFamily.families(in: output)
                .subtracting(AIScriptFamily.families(in: input))
                .first?
                .rawValue
        }
    }
}

/// Coarse writing-system buckets. Only letters are classified — punctuation, digits,
/// and emoji carry no language and would otherwise fire false violations.
public enum AIScriptFamily: String, Sendable, Hashable {
    case latin, devanagari, telugu, otherIndic, cjk, hangul, cyrillic, greek, arabic, hebrew, other

    public static func families(in text: String) -> Set<AIScriptFamily> {
        var found: Set<AIScriptFamily> = []
        for character in text where character.isLetter {
            for scalar in character.unicodeScalars {
                if let family = family(of: scalar) { found.insert(family) }
            }
        }
        return found
    }

    static func family(of scalar: Unicode.Scalar) -> AIScriptFamily? {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
            return .latin
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        case 0x0400...0x04FF, 0x0500...0x052F:
            return .cyrillic
        case 0x0590...0x05FF:
            return .hebrew
        case 0x0600...0x06FF, 0x0750...0x077F:
            return .arabic
        case 0x0900...0x097F:
            return .devanagari
        case 0x0C00...0x0C7F:
            return .telugu
        case 0x0980...0x09FF, 0x0A00...0x0BFF, 0x0C80...0x0D7F:
            return .otherIndic
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return .cjk
        case 0x1100...0x11FF, 0xAC00...0xD7AF:
            return .hangul
        default:
            return .other
        }
    }
}

/// Detects and removes prompt echoes from a model answer.
///
/// The on-device model is handed its instructions twice — once as system instructions
/// and once as the framing line immediately before the selection. Small models
/// sometimes copy that framing into the reply ("Proofread the text below.
/// Return it corrected…"), and on the direct path that text lands in the user's
/// document with no review. Guided generation, the script policy, and the length
/// policy all let an echo through: it is the right script and roughly the input's
/// size. This is the check that actually catches it.
///
/// Scope note: only the per-request *framing* is matched (it is static per kind and
/// is what leaks in practice). Custom instructions are user-authored prose; matching
/// them would risk eating legitimate content whenever they overlap the selection.
public enum AIPromptEcho: Sendable {

    /// Minimum normalized length of a phrase before stripping/flagging. Below this,
    /// generic words ("transform", "text") could match innocent output.
    static let minimumPhraseLength = 12

    /// Characters an echo may carry between itself and the real content
    /// ("…own language:\n\nHello" → the colon and newlines are the echo's, not ours).
    ///
    /// Sentence punctuation is deliberately absent. A period between an echo and the
    /// content is ambiguous — it may be the echo's sentence end or the content's — so
    /// it is handled by the explicit terminal-period rule in `stripLeadingPhrase`
    /// instead of blanket consumption, and content punctuation always survives.
    private static let boundarySeparators: Set<Character> = [
        " ", "\t", "\n", "\r", ":", "\"", "'", "\u{201C}", "\u{201D}", "-", "\u{2014}",
    ]

    /// The prompt phrases a reply might echo, longest first. Derived from the framing
    /// so every transform kind is covered without per-kind code. Each framing line is
    /// broken into its sentences/clauses — the model frequently echoes just
    /// "Proofread the text below." rather than the whole line.
    public static func phrases(framing: String) -> [String] {
        var found: Set<String> = []
        for line in framing.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Sentence terminators delimit echoable clauses; they are formatting, so
            // they never join two words of one phrase.
            for clause in trimmed.split(whereSeparator: { $0 == "." || $0 == ":" }) {
                let phrase = normalized(String(clause))
                guard phrase.count >= minimumPhraseLength else { continue }
                found.insert(phrase)
            }
        }
        return found.sorted { $0.count > $1.count }
    }

    /// Comparison form: case-insensitive, whitespace-collapsed, punctuation-skipped.
    ///
    /// Punctuation is dropped because echoing models drop it too ("corrected, in" →
    /// "corrected in"), and a comma-for-comma comparison would miss exactly the sloppiest
    /// echoes. The strip walk mirrors this form character-by-character on the original
    /// string, so the cut still lands at the right offset despite the lossy comparison.
    ///
    /// Skipped punctuation must behave identically in both forms: like the strip walk,
    /// only a *consumed* character clears the run-of-whitespace flag. Clearing it on
    /// punctuation instead produced "prompt — no" → "prompt  no" here while the strip
    /// walk built "prompt no" — phrases containing spaced punctuation (em dashes in the
    /// instruction sentences) were then unfindable and never stripped.
    public static func normalized(_ text: String) -> String {
        var out = ""
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace {
                if !lastWasSpace && !out.isEmpty { out.append(" ") }
                lastWasSpace = true
                continue
            }
            guard character.isLetter || character.isNumber else { continue }
            lastWasSpace = false
            out.append(contentsOf: character.lowercased())
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Removes leading / trailing echoes of the framing from a model answer.
    ///
    /// Never strips when the author's own input contains the same phrase — a user who
    /// selected text that literally begins with "Proofread the text below" keeps it.
    public static func stripped(_ output: String, input: String, framing: String) -> String {
        stripped(output, input: input, phrases: phrases(framing: framing))
    }

    /// Precomputed-phrase variant. Callers that check many outputs against one prompt
    /// surface (the transformer, `AIPromptLeakGuard`) extract once and reuse.
    public static func stripped(_ output: String, input: String, phrases: [String]) -> String {
        let inputNormalized = normalized(input)
        var out = output
        // Framing has at most a handful of clauses; a small fixed bound terminates
        // even if a pathological answer repeats them.
        for _ in 0..<8 {
            var strippedSomething = false
            for phrase in phrases where !inputNormalized.contains(phrase) {
                if let head = stripLeadingPhrase(out, phrase: phrase) {
                    out = head
                    strippedSomething = true
                }
                if let tail = stripTrailingPhrase(out, phrase: phrase) {
                    out = tail
                    strippedSomething = true
                }
            }
            if !strippedSomething { break }
        }
        return out
    }

    /// True when the answer still quotes prompt text after stripping — the signal to
    /// re-roll rather than inject. Phrases the input itself contains never count,
    /// so an author writing *about* the framing is never blocked.
    public static func contaminated(
        output: String,
        input: String,
        framing: String
    ) -> Bool {
        contaminated(output: output, input: input, phrases: phrases(framing: framing))
    }

    /// Precomputed-phrase variant — see `stripped(_:input:phrases:)`.
    public static func contaminated(
        output: String,
        input: String,
        phrases: [String]
    ) -> Bool {
        let inputNormalized = normalized(input)
        let outputNormalized = normalized(output)
        return phrases.contains { phrase in
            !inputNormalized.contains(phrase) && outputNormalized.contains(phrase)
        }
    }

    /// Cuts `phrase` off the start of `text`, or nil when it does not start with it.
    ///
    /// Matching walks the original string and builds the same lossy comparison form as
    /// `normalized` (punctuation skipped, whitespace collapsed), so the cut lands after
    /// the real characters even when the echo's punctuation differs from the framing's.
    ///
    /// After a full match, only true boundary separators are consumed — plus one period
    /// that reads as terminal (". Content"). A period followed directly by more content
    /// stays: "below.Fix this" is ambiguous, and ambiguity resolves in favour of the
    /// author's text.
    static func stripLeadingPhrase(_ text: String, phrase: String) -> String? {
        guard !phrase.isEmpty else { return nil }
        var accumulated = ""
        var lastAppendedWasSpace = false
        for (index, character) in zip(text.indices, text) {
            if character.isWhitespace {
                if !lastAppendedWasSpace && !accumulated.isEmpty {
                    accumulated.append(" ")
                    lastAppendedWasSpace = true
                }
            } else if character.isLetter || character.isNumber {
                accumulated.append(contentsOf: character.lowercased())
                lastAppendedWasSpace = false
            } else {
                // Punctuation: skipped in the comparison, but it still occupies the
                // original string — the cut below accounts for it via `index`.
                continue
            }
            if accumulated.count >= phrase.count {
                guard accumulated == phrase else { return nil }
                var remainder = text[text.index(after: index)...]
                // The echo's own sentence period: consume only when terminal.
                if remainder.first == "." {
                    let next = remainder.index(after: remainder.startIndex)
                    if next == remainder.endIndex || remainder[next].isWhitespace || remainder[next] == ":" {
                        remainder.removeFirst()
                    }
                }
                while let first = remainder.first, boundarySeparators.contains(first) {
                    remainder.removeFirst()
                }
                return String(remainder)
            }
            guard phrase.hasPrefix(accumulated) else { return nil }
        }
        return nil
    }

    /// Mirror of `stripLeadingPhrase` for an echo at the end of the answer.
    ///
    /// In reversed orientation a post-match period would belong to the *content*
    /// ("Fixed. Proofread…" — the period ends the author's sentence), which is why the
    /// terminal-period consumption must not run here; only true separators go.
    static func stripTrailingPhrase(_ text: String, phrase: String) -> String? {
        guard let cut = stripLeadingPhrase(
            String(text.reversed()),
            phrase: String(phrase.reversed())
        ) else { return nil }
        var restored = String(cut.reversed())
        // The whitespace that separated content from echo leaves with the echo.
        while let last = restored.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
            restored.removeLast()
        }
        return restored
    }
}


/// Counts consecutive identical requests so a Retry can re-roll sampling.
public struct AIRepeatTracker: Sendable {
    private var lastSignature: String?
    private var attempts = 0

    public init() {}

    /// Returns 0 for a new request, then 1, 2, … while the same request repeats.
    public mutating func attempt(for signature: String) -> Int {
        if lastSignature == signature {
            attempts += 1
        } else {
            lastSignature = signature
            attempts = 0
        }
        return attempts
    }
}

// MARK: - Locale probe (no actor hop)

/// Cached locale support for greying out AI palette rows (B′3).
public enum AILocaleSupport {
    public static func disabledReason(
        locale: Locale = .current,
        loc: LocalizationManager = .shared
    ) -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AITextTransformer.localeDisabledReason(locale: locale, loc: loc)
        }
        #endif
        return nil
    }
}

// MARK: - Transformer

#if canImport(FoundationModels)

/// Guided-generation payload. Forces clean text (no JSON wrapper / commentary).
@available(macOS 26.0, *)
@Generable
public struct TransformedText {
    @Guide(description: "The transformed text only. No commentary, quotes, or labels.")
    public var text: String
}

/// Serial on-device text transformer.
///
/// Single-flight is mandatory: concurrent `respond` on one `LanguageModelSession`
/// throws `.concurrentRequests` (mapped below). This actor refuses overlapping
/// requests and uses a fresh session per call so transcripts never accumulate
/// across transforms. `session.isResponding` is consulted for diagnostics only.
@available(macOS 26.0, *)
public actor AITextTransformer {
    public static let shared = AITextTransformer()

    private let model: SystemLanguageModel
    private var inFlight = false
    /// Session kept only for `prewarm()`; request work always builds a fresh session.
    private var warmSession: LanguageModelSession?
    /// Static token counts keyed by kind (+ framing). Input remains dynamic.
    private var staticTokenCache: [String: (instruction: Int, framing: Int)] = [:]
    /// Monotonic seed for reproducible retries when sampling is random.
    private var retrySeed: UInt64 = 1
    /// Detects a repeated request (the Retry button) so deterministic kinds re-roll.
    private var repeats = AIRepeatTracker()

    public init() {
        model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
    }

    /// Unit-test hook: claim the single-flight latch without calling the model.
    public func testingAcquireFlight() -> Bool {
        if inFlight { return false }
        inFlight = true
        return true
    }

    /// Unit-test hook: release a latch taken via `testingAcquireFlight()`.
    public func testingReleaseFlight() {
        inFlight = false
    }

    public var availability: AIModelAvailability {
        Self.mapAvailability(model.availability)
    }

    public var isAvailable: Bool {
        model.isAvailable
    }

    public var contextSize: Int {
        model.contextSize
    }

    /// Whether the warm or last session is mid-response (diagnostics).
    public var isSessionResponding: Bool {
        warmSession?.isResponding ?? false
    }

    /// Sync readiness check that does not hop through the actor.
    public nonisolated static func probeAvailability() -> AIModelAvailability {
        let probe = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        return mapAvailability(probe.availability)
    }

    /// Locale gate for palette greying (B′3).
    public nonisolated static func localeDisabledReason(
        locale: Locale,
        loc: LocalizationManager
    ) -> String? {
        let probe = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        if probe.supportsLocale(locale) { return nil }
        return loc.s("ai.error.language")
    }

    /// Load model assets early (panel open). Prefill latency dominates; this is the
    /// main perceived-latency win. Safe to call repeatedly.
    ///
    /// Uses the real per-kind instructions and prompt framing so the system prefix cache
    /// matches what `runTransform` will request. Transform calls still build a fresh
    /// session (no transcript bleed) — only the warm path needs to match.
    public func prewarm(
        kind: AITransformKind = .proofread,
        customInstructions: String? = nil
    ) {
        // Callers fire prewarm and the transform back to back; the actor is reentrant,
        // so without this the warm session can be built *while* a transform is running
        // and compete with it for the same model.
        guard !inFlight else { return }
        let instructions = Self.resolvedInstructions(
            kind: kind,
            customInstructions: customInstructions
        )
        let session = LanguageModelSession(model: model, instructions: instructions)
        warmSession = session
        session.prewarm(promptPrefix: Prompt(Self.promptFraming(for: kind)))
    }

    /// Default prompt framing. `runTransform` and `prewarm` resolve it through
    /// `promptFraming(for:)` so the warm prefix matches what the request will send.
    /// The strings themselves live on `AITransformKind` (single canonical owner).
    nonisolated static let promptFramingPrefix = AITransformKind.genericFraming

    /// Per-kind framing. "Transform this text" is an instruction to change the text,
    /// which is the wrong verb for proofreading — the framing line is the last thing
    /// the model reads before the input, so it carries real weight.
    nonisolated static func promptFraming(for kind: AITransformKind) -> String {
        kind.framing
    }

    /// GCD entry point. Completion fires exactly once on `completionQueue`.
    /// Discard via the returned handle so a late result cannot inject.
    public nonisolated func transform(
        kind: AITransformKind,
        input: String,
        customInstructions: String? = nil,
        completionQueue: DispatchQueue = .main,
        completion: @escaping @Sendable (Result<String, AITransformError>) -> Void
    ) -> AITransformDiscardHandle {
        transformStreaming(
            kind: kind,
            input: input,
            customInstructions: customInstructions,
            onPartial: nil,
            completionQueue: completionQueue,
            completion: completion
        )
    }

    /// Streaming entry point. `onPartial` receives `PartiallyGenerated.text` (Optional)
    /// on `completionQueue` as snapshots arrive; may be `nil` before the first token.
    /// Discard via the returned handle — Cancel must not claim generation stopped.
    public nonisolated func transformStreaming(
        kind: AITransformKind,
        input: String,
        customInstructions: String? = nil,
        onPartial: (@Sendable (String?) -> Void)?,
        completionQueue: DispatchQueue = .main,
        completion: @escaping @Sendable (Result<String, AITransformError>) -> Void
    ) -> AITransformDiscardHandle {
        let once = AITransformOnceCompletion(queue: completionQueue, handler: completion)
        let handle = AITransformDiscardHandle(once: once)
        let partialQueue = completionQueue
        Task {
            await self.runTransform(
                kind: kind,
                input: input,
                customInstructions: customInstructions,
                streamPartials: onPartial != nil,
                onPartial: { text in
                    guard let onPartial else { return }
                    partialQueue.async { onPartial(text) }
                },
                once: once
            )
        }
        return handle
    }

    /// Async convenience used by tests and future callers.
    public func transform(
        kind: AITransformKind,
        input: String,
        customInstructions: String? = nil
    ) async -> Result<String, AITransformError> {
        await withCheckedContinuation { continuation in
            let once = AITransformOnceCompletion(queue: .global(qos: .userInitiated)) { result in
                continuation.resume(returning: result)
            }
            Task {
                await self.runTransform(
                    kind: kind,
                    input: input,
                    customInstructions: customInstructions,
                    streamPartials: false,
                    onPartial: { _ in },
                    once: once
                )
            }
        }
    }

    // MARK: - Internals

    private func runTransform(
        kind: AITransformKind,
        input: String,
        customInstructions: String?,
        streamPartials: Bool,
        onPartial: @escaping @Sendable (String?) -> Void,
        once: AITransformOnceCompletion
    ) async {
        guard !inFlight else {
            once.complete(.failure(.busy))
            return
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            once.complete(.failure(.emptyInput))
            return
        }

        if case .unavailable(let reason) = availability {
            once.complete(.failure(.unavailable(reason)))
            return
        }

        inFlight = true
        defer { inFlight = false }

        let instructions = Self.resolvedInstructions(
            kind: kind,
            customInstructions: customInstructions
        )
        // Same kind + instructions + input as last time means the user pressed Retry.
        let attempt = repeats.attempt(
            for: kind.rawValue + "\u{1f}" + instructions + "\u{1f}" + trimmed
        )

        // Granularity for the chunked pass below: paragraphs when the input did not
        // fit, lines when a single-shot result came back with its line breaks eaten.
        var chunkGranularity: AITransformText.Granularity = .automatic

        // Try single-shot first; on `.inputTooLarge` for chunk-safe kinds, fall through.
        do {
            let budget = try await evaluateBudget(
                kind: kind,
                instructions: instructions,
                input: trimmed
            )
            let text = try await generateOnce(
                kind: kind,
                instructions: instructions,
                input: trimmed,
                maxResponseTokens: budget.maxResponseTokens,
                attempt: attempt,
                streamPartials: streamPartials,
                onPartial: onPartial
            )
            if kind.preservesLineStructure,
               kind.isChunkSafe,
               AITransformText.segments(trimmed, granularity: .line).count > 1,
               !AITransformText.preservesLineStructure(input: trimmed, output: text) {
                // The model collapsed the layout. Redo it a line at a time and rejoin
                // on the author's own breaks; no prompt wording prevents this.
                DevTypeLog.store.debug(
                    "[AI] line structure lost kind=\(kind.rawValue, privacy: .public) — repairing per line"
                )
                chunkGranularity = .line
            } else {
                AIDiagnosticsStore.shared.recordSuccess(kind: kind.rawValue)
                once.complete(.success(AITransformText.restoringAffixes(of: input, to: text)))
                return
            }
        } catch let error as AITransformError {
            if case .inputTooLarge = error, kind.isChunkSafe {
                // Fall through to chunking.
            } else {
                once.complete(.failure(error))
                return
            }
        } catch {
            once.complete(.failure(Self.mapGenerationError(error, kind: kind, input: trimmed)))
            return
        }

        // B′4: paragraph chunking for chunk-safe kinds, serialized on this actor latch.
        do {
            let chunks = AITransformText.segments(trimmed, granularity: chunkGranularity)
            guard chunks.count > 1 else {
                // Still too large as one paragraph — refuse.
                let budgetErr: AITransformError
                do {
                    _ = try await evaluateBudget(
                        kind: kind,
                        instructions: instructions,
                        input: trimmed
                    )
                    budgetErr = .inputTooLarge(estimatedTokens: trimmed.count, contextSize: model.contextSize)
                } catch let e as AITransformError {
                    budgetErr = e
                } catch {
                    budgetErr = .unknown(error.localizedDescription)
                }
                once.complete(.failure(budgetErr))
                return
            }

            var pieces: [String] = []
            pieces.reserveCapacity(chunks.count)
            var assembled = ""
            for (index, chunk) in chunks.enumerated() {
                let budget = try await evaluateBudget(
                    kind: kind,
                    instructions: instructions,
                    input: chunk.body
                )
                let piece = try await generateOnce(
                    kind: kind,
                    instructions: instructions,
                    input: chunk.body,
                    maxResponseTokens: budget.maxResponseTokens,
                    attempt: attempt,
                    streamPartials: false,
                    onPartial: { _ in }
                )
                pieces.append(piece)
                // Rejoin on the author's own separators, not a canned "\n\n".
                assembled = AITransformText.joined(Array(chunks.prefix(pieces.count)), bodies: pieces)
                if streamPartials {
                    let progress = assembled + (index + 1 < chunks.count ? "…" : "")
                    onPartial(progress)
                }
            }
            // Each piece was checked against the echo corpus with only its own chunk
            // visible; re-check the assembly as a whole so no per-chunk miss can slip
            // through the seams where pieces were rejoined.
            if AIPromptEcho.contaminated(
                output: assembled,
                input: trimmed,
                phrases: AIPromptLeakGuard.phrases(for: kind)
            ) {
                record(
                    violation: "promptEcho",
                    detail: "assembled chunks still contain prompt framing",
                    kind: kind,
                    attempt: attempt
                )
                once.complete(.failure(.promptEcho))
                return
            }
            AIDiagnosticsStore.shared.recordSuccess(kind: kind.rawValue)
            once.complete(.success(AITransformText.restoringAffixes(of: input, to: assembled)))
        } catch let error as AITransformError {
            once.complete(.failure(error))
        } catch {
            once.complete(.failure(Self.mapGenerationError(error, kind: kind, input: trimmed)))
        }
    }

    /// Generates, then enforces the kind's script and length policies. A violation is
    /// re-rolled once (greedy would just repeat it); a second violation fails the
    /// transform rather than injecting text the user did not ask for.
    private func generateOnce(
        kind: AITransformKind,
        instructions: String,
        input: String,
        maxResponseTokens: Int,
        attempt: Int,
        streamPartials: Bool,
        onPartial: @escaping @Sendable (String?) -> Void
    ) async throws -> String {
        var lastFailure = AITransformError.languageDrift
        for extraAttempt in 0...1 {
            let text = try await generateRaw(
                kind: kind,
                instructions: instructions,
                input: input,
                maxResponseTokens: maxResponseTokens,
                attempt: attempt + extraAttempt,
                streamPartials: streamPartials,
                onPartial: onPartial
            )

            if let script = kind.scriptPolicy.violation(input: input, output: text) {
                lastFailure = .languageDrift
                record(violation: "languageDrift", detail: "answered in \(script)", kind: kind, attempt: extraAttempt)
                continue
            }
            // The framing echo is stripped in `generateRaw`; anything left means the
            // model copied the prompt into the body of its answer. Re-roll once, then
            // fail rather than inject "Proofread the text below…" into a document.
            // The corpus covers both the framing line *and* this kind's instruction
            // sentences ("Return ONLY the enhanced prompt…") — an echoed instruction
            // has the right script and roughly the right size, so every other policy
            // waves it through.
            if AIPromptEcho.contaminated(
                output: text,
                input: input,
                phrases: AIPromptLeakGuard.phrases(for: kind)
            ) {
                lastFailure = .promptEcho
                record(
                    violation: "promptEcho",
                    detail: "answer still contains prompt framing",
                    kind: kind,
                    attempt: extraAttempt
                )
                continue
            }
            if kind.lengthPolicy.exceeded(input: input, output: text) {
                lastFailure = .unexpectedRewrite
                record(
                    violation: "unexpectedRewrite",
                    detail: "\(input.count) chars in, \(text.count) out",
                    kind: kind,
                    attempt: extraAttempt
                )
                continue
            }
            return text
        }
        throw lastFailure
    }

    /// Contract violations are logged without the text itself — the detail describes
    /// the shape of the failure, never the user's selection or the model's answer.
    private func record(
        violation: String,
        detail: String,
        kind: AITransformKind,
        attempt: Int
    ) {
        DevTypeLog.store.error(
            "[AI] \(violation, privacy: .public) kind=\(kind.rawValue, privacy: .public) \(detail, privacy: .public) attempt=\(attempt, privacy: .public)"
        )
        AIDiagnosticsStore.shared.recordFailure(
            kind: kind.rawValue,
            error: violation,
            detail: detail
        )
    }

    private func generateRaw(
        kind: AITransformKind,
        instructions: String,
        input: String,
        maxResponseTokens: Int,
        attempt: Int,
        streamPartials: Bool,
        onPartial: @escaping @Sendable (String?) -> Void
    ) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        if session.isResponding {
            DevTypeLog.store.debug("[AI] session.isResponding was unexpectedly true before respond")
        }
        let prompt = "\(Self.promptFraming(for: kind))\(input)"
        let options = Self.generationOptions(
            kind: kind,
            maxResponseTokens: maxResponseTokens,
            seed: nextSeed(),
            attempt: attempt
        )

        let raw: String
        if streamPartials {
            let stream = session.streamResponse(
                to: prompt,
                generating: TransformedText.self,
                options: options
            )
            var lastText = ""
            for try await snapshot in stream {
                let partial = snapshot.content.text
                onPartial(partial)
                if let partial {
                    lastText = partial
                }
            }
            raw = lastText
        } else {
            let response = try await session.respond(
                to: prompt,
                generating: TransformedText.self,
                options: options
            )
            raw = response.content.text
        }

        let cleaned = AITransformText.sanitize(
            AIPromptEcho.stripped(
                raw,
                input: input,
                phrases: AIPromptLeakGuard.phrases(for: kind)
            ),
            input: input
        )
        // An empty response is a failed generation, not a result. Letting it through
        // means the direct path replaces the user's selection with nothing.
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DevTypeLog.store.error(
                "[AI] empty generation kind=\(kind.rawValue, privacy: .public)"
            )
            AIDiagnosticsStore.shared.recordFailure(
                kind: kind.rawValue,
                error: "emptyOutput",
                detail: "model returned no text"
            )
            throw AITransformError.decodingFailure
        }
        return cleaned
    }

    private func nextSeed() -> UInt64 {
        let seed = retrySeed
        retrySeed &+= 1
        return seed
    }

    /// Greedy for deterministic kinds so the same selection corrects the same way —
    /// except on a repeat of the identical request, where greedy would hand back a
    /// byte-identical result and make Retry look broken. Temperature is meaningless
    /// under greedy sampling, so it is only passed with random sampling.
    nonisolated static func generationOptions(
        kind: AITransformKind,
        maxResponseTokens: Int,
        seed: UInt64,
        attempt: Int
    ) -> GenerationOptions {
        if kind.isDeterministic && attempt == 0 {
            return GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: maxResponseTokens
            )
        }
        // A deterministic kind's own temperature (0.2) re-rolls to the same string on
        // a short edit, which is what Retry looked like before. Warm it enough to
        // move without turning a correction into a rewrite.
        let temperature = kind.isDeterministic && attempt > 0
            ? min(1.0, kind.temperature + 0.3)
            : kind.temperature
        return GenerationOptions(
            sampling: .random(top: 50, seed: seed),
            temperature: temperature,
            maximumResponseTokens: maxResponseTokens
        )
    }

    private static func resolvedInstructions(
        kind: AITransformKind,
        customInstructions: String?
    ) -> String {
        let extra = customInstructions?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if extra.isEmpty {
            return kind.instructions
        }
        return kind.instructions + "\n\nAdditional instructions:\n" + extra
    }

    private func evaluateBudget(
        kind: AITransformKind,
        instructions: String,
        input: String
    ) async throws -> (maxResponseTokens: Int, contextSize: Int) {
        let context = model.contextSize
        let cacheKey = kind.rawValue + "\u{1f}" + instructions
        let instructionTokens: Int
        let framingTokens: Int
        if let cached = staticTokenCache[cacheKey] {
            instructionTokens = cached.instruction
            framingTokens = cached.framing
        } else {
            let i = await estimateTokenCount(instructions)
            let f = await estimateTokenCount(Self.promptFraming(for: kind))
            staticTokenCache[cacheKey] = (i, f)
            instructionTokens = i
            framingTokens = f
        }
        let inputTokens = await estimateTokenCount(input)
        let maxResponse = try AITokenBudget.evaluate(
            inputTokens: inputTokens,
            instructionTokens: instructionTokens,
            framingTokens: framingTokens,
            contextSize: context,
            tokenBudgetMultiplier: kind.tokenBudgetMultiplier
        )
        return (maxResponse, context)
    }

    private func estimateTokenCount(_ text: String) async -> Int {
        if #available(macOS 26.4, *) {
            do {
                return try await model.tokenCount(for: text)
            } catch {
                // Fall through to heuristic.
            }
        }
        return AITokenBudget.estimateTokensHeuristic(text)
    }

    private static func mapAvailability(
        _ availability: SystemLanguageModel.Availability
    ) -> AIModelAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady:
                return .unavailable(.modelNotReady)
            @unknown default:
                return .unavailable(.modelNotReady)
            }
        @unknown default:
            return .unavailable(.modelNotReady)
        }
    }

    /// Apple attaches a `GenerationError.Context` to every case, and its `debugDescription`
    /// is the only explanation the framework offers — in particular it is the sole way to
    /// tell *why* a guardrail fired. `AITransformError` is a flat, `Equatable` enum used for
    /// UI mapping, so the detail cannot ride along on the case; log it here instead, or the
    /// information is gone by the time anyone reads a diagnostic report.
    ///
    /// The transformed text and the user's selection are deliberately never logged. Apple's
    /// context prose is documented as describing the violation rather than quoting the
    /// input — but it is still third-party free-form text entering our logs and the
    /// diagnostics store, so `AIPromptLeakGuard.redact` scrubs any occurrence of the
    /// selection or a prompt surface out of it before either sink sees it.
    private static func logGenerationFailure(
        _ generation: LanguageModelSession.GenerationError,
        kind: AITransformKind,
        input: String
    ) {
        let detail: String
        switch generation {
        case .guardrailViolation(let context),
             .exceededContextWindowSize(let context),
             .rateLimited(let context),
             .unsupportedLanguageOrLocale(let context),
             .assetsUnavailable(let context),
             .decodingFailure(let context),
             .concurrentRequests(let context),
             .unsupportedGuide(let context):
            detail = AIPromptLeakGuard.redact(
                context.debugDescription,
                sources: [input, kind.framing, kind.instructions]
            )
        case .refusal(_, let context):
            detail = AIPromptLeakGuard.redact(
                context.debugDescription,
                sources: [input, kind.framing, kind.instructions]
            )
        @unknown default:
            detail = generation.localizedDescription
        }
        DevTypeLog.store.error(
            "[AI] transform failed kind=\(kind.rawValue, privacy: .public) detail=\(detail, privacy: .public)"
        )
        // OSLog only survives the report's 30-minute lookback; retain it for DiagnosticReport.
        AIDiagnosticsStore.shared.recordFailure(
            kind: kind.rawValue,
            error: Self.caseLabel(generation),
            detail: detail
        )
    }

    /// Short, stable case label for diagnostics (`localizedDescription` is prose).
    private static func caseLabel(_ generation: LanguageModelSession.GenerationError) -> String {
        switch generation {
        case .guardrailViolation: return "guardrailViolation"
        case .exceededContextWindowSize: return "exceededContextWindowSize"
        case .rateLimited: return "rateLimited"
        case .unsupportedLanguageOrLocale: return "unsupportedLanguageOrLocale"
        case .assetsUnavailable: return "assetsUnavailable"
        case .decodingFailure: return "decodingFailure"
        case .refusal: return "refusal"
        case .concurrentRequests: return "concurrentRequests"
        case .unsupportedGuide: return "unsupportedGuide"
        @unknown default: return "unknown"
        }
    }

    private static func mapGenerationError(
        _ error: Error,
        kind: AITransformKind,
        input: String
    ) -> AITransformError {
        guard let generation = error as? LanguageModelSession.GenerationError else {
            DevTypeLog.store.error(
                "[AI] transform failed kind=\(kind.rawValue, privacy: .public) non-GenerationError=\(AIPromptLeakGuard.redact(error.localizedDescription, sources: [input, kind.framing, kind.instructions]), privacy: .public)"
            )
            return .unknown(error.localizedDescription)
        }
        logGenerationFailure(generation, kind: kind, input: input)
        switch generation {
        case .guardrailViolation:
            return .guardrailViolation
        case .exceededContextWindowSize:
            return .exceededContextWindowSize
        case .rateLimited:
            return .rateLimited
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguageOrLocale
        case .assetsUnavailable:
            return .assetsUnavailable
        case .decodingFailure:
            return .decodingFailure
        case .refusal:
            return .refusal
        case .concurrentRequests:
            return .concurrentRequests
        case .unsupportedGuide:
            return .unsupportedGuide
        @unknown default:
            return .unknown(generation.localizedDescription)
        }
    }
}

#else

/// Stub when FoundationModels is unavailable at compile time.
public enum AITextTransformerUnavailable {
    public static var availability: AIModelAvailability {
        .unavailable(.unsupportedOS)
    }
}

#endif

/// Process-wide availability that compiles on every deployment target.
public enum AITextTransformSupport {
    public static var availability: AIModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AITextTransformer.probeAvailability()
        }
        return .unavailable(.unsupportedOS)
        #else
        return .unavailable(.unsupportedOS)
        #endif
    }
}
