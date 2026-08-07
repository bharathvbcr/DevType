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
        let instructions = Self.resolvedInstructions(
            kind: kind,
            customInstructions: customInstructions
        )
        let session = LanguageModelSession(model: model, instructions: instructions)
        warmSession = session
        session.prewarm(promptPrefix: Prompt(Self.promptFramingPrefix))
    }

    /// Shared prompt framing used by `runTransform` and `prewarm` so the warm prefix matches.
    nonisolated static let promptFramingPrefix = "Transform this text:\n\n"

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
                streamPartials: streamPartials,
                onPartial: onPartial
            )
            once.complete(.success(text))
            return
        } catch let error as AITransformError {
            if case .inputTooLarge = error, kind.isChunkSafe {
                // Fall through to chunking.
            } else {
                once.complete(.failure(error))
                return
            }
        } catch {
            once.complete(.failure(Self.mapGenerationError(error)))
            return
        }

        // B′4: paragraph chunking for chunk-safe kinds, serialized on this actor latch.
        do {
            let chunks = Self.paragraphChunks(trimmed)
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
                    input: chunk
                )
                let piece = try await generateOnce(
                    kind: kind,
                    instructions: instructions,
                    input: chunk,
                    maxResponseTokens: budget.maxResponseTokens,
                    streamPartials: false,
                    onPartial: { _ in }
                )
                pieces.append(piece)
                assembled = pieces.joined(separator: "\n\n")
                if streamPartials {
                    let progress = assembled + (index + 1 < chunks.count ? "\n\n…" : "")
                    onPartial(progress)
                }
            }
            once.complete(.success(assembled))
        } catch let error as AITransformError {
            once.complete(.failure(error))
        } catch {
            once.complete(.failure(Self.mapGenerationError(error)))
        }
    }

    private func generateOnce(
        kind: AITransformKind,
        instructions: String,
        input: String,
        maxResponseTokens: Int,
        streamPartials: Bool,
        onPartial: @escaping @Sendable (String?) -> Void
    ) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        if session.isResponding {
            DevTypeLog.store.debug("[AI] session.isResponding was unexpectedly true before respond")
        }
        let prompt = "\(Self.promptFramingPrefix)\(input)"
        let options = Self.generationOptions(
            kind: kind,
            maxResponseTokens: maxResponseTokens,
            seed: nextSeed()
        )

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
            return lastText
        } else {
            let response = try await session.respond(
                to: prompt,
                generating: TransformedText.self,
                options: options
            )
            return response.content.text
        }
    }

    private func nextSeed() -> UInt64 {
        let seed = retrySeed
        retrySeed &+= 1
        return seed
    }

    nonisolated static func generationOptions(
        kind: AITransformKind,
        maxResponseTokens: Int,
        seed: UInt64
    ) -> GenerationOptions {
        if kind == .proofread {
            return GenerationOptions(
                sampling: .greedy,
                temperature: kind.temperature,
                maximumResponseTokens: maxResponseTokens
            )
        }
        return GenerationOptions(
            sampling: .random(top: 50, seed: seed),
            temperature: kind.temperature,
            maximumResponseTokens: maxResponseTokens
        )
    }

    nonisolated static func paragraphChunks(_ text: String) -> [String] {
        let parts = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text] : parts
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
            let f = await estimateTokenCount(Self.promptFramingPrefix)
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

    private static func mapGenerationError(_ error: Error) -> AITransformError {
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return .unknown(error.localizedDescription)
        }
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
