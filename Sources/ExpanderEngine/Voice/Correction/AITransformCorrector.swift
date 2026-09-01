import Foundation

/// Runs an `AITransformKind` over the transcript as the session's correction stage.
///
/// This is how "proofread every dictation before inserting it" is built: not as a second
/// pass bolted after correction, but as the correction stage itself, with a different
/// prompt. That matters because everything protecting the user already lives around this
/// stage — `ProtectedSpanExtractor` pins identifiers and versions, `CorrectionValidator`
/// rejects refusals, hallucinations and span damage, the deadline is enforced, and any
/// rejection falls back to the raw transcript.
///
/// A separate post-insertion pass would have inherited none of that, and would have paid a
/// second round trip for the privilege.
public final class AITransformCorrector: TranscriptCorrector, @unchecked Sendable {

    public let descriptor: CorrectionProviderDescriptor
    private let kind: AITransformKind
    private let fallback = DeterministicCorrector()

    public init(kind: AITransformKind = .proofread) {
        self.kind = kind
        self.descriptor = CorrectionProviderDescriptor(
            id: Self.id(for: kind),
            displayName: "Apple Intelligence (\(kind.rawValue))",
            modelVersion: "system-language-model",
            privacyRoute: .onDeviceOnly,
            supportsStructuredOutput: false
        )
    }

    /// Stable id per kind, so the registry can hold several and a session snapshot records
    /// which transform produced its text.
    public static func id(for kind: AITransformKind) -> String {
        "apple.transform.\(kind.rawValue)"
    }

    /// Whether a provider id names a rewriting transform.
    ///
    /// The session uses this to decide that the final transcript *supersedes* what live
    /// typing put on screen, rather than refining it. A proofread pass legitimately rewrites
    /// text the commit barrier has already sealed — which is the one case where replacing
    /// sealed text is correct rather than the bug this whole subsystem exists to prevent.
    public static func isTransformProvider(_ id: String) -> Bool {
        id.hasPrefix("apple.transform.")
    }

    public func probe() async -> ProviderReadiness {
        guard AIPreferences.isEnabled else {
            return .requiresConfiguration(.missingModelDownload)
        }
        guard AITextTransformSupport.isRunningOnCompatibleOS else {
            return .incompatible(reason: .modelNotFound)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard await AITextTransformer.shared.isAvailable else {
                return .temporarilyUnavailable(retryAfterSeconds: nil, reason: .modelNotFound)
            }
            return .ready(ProviderEvidence(
                providerID: descriptor.id,
                modelVersion: descriptor.modelVersion,
                probeTimestamp: Date(),
                capabilities: ["appleIntelligence", kind.rawValue, "onDevicePrivate"]
            ))
        }
        #endif
        return .incompatible(reason: .modelNotFound)
    }

    public func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let text = await transform(request) {
                return CorrectionCandidate(
                    text: text,
                    providerID: descriptor.id,
                    modelVersion: descriptor.modelVersion,
                    promptVersion: kind.rawValue
                )
            }
        }
        #endif
        // Unavailable, declined, or over deadline. Deterministic rules still run, so the
        // user gets punctuation and capitalisation rather than a raw transcript.
        return try await fallback.correct(request)
    }

    public func cancel(sessionID: VoiceSessionID) async {}

    // MARK: - Transform

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func transform(_ request: CorrectionRequest) async -> String? {
        let budget = request.deadline.timeIntervalSinceNow
        guard budget > 0.2 else { return nil }

        // Dictation can exceed the on-device context window, so the same chunking the
        // Foundation Models corrector uses applies here — a long dictation must not lose
        // its proofread pass entirely.
        let chunks = FoundationLanguageModelCorrector.chunk(
            request.rawTranscript,
            budgetTokens: FoundationLanguageModelCorrector.inputTokenBudget(
                instructions: CorrectionPromptBuilder.systemPrompt(
                    policy: request.policy,
                    protectedSpans: request.protectedSpans,
                    locale: request.locale
                )
            )
        )

        var corrected: [String] = []
        for chunk in chunks {
            guard request.deadline.timeIntervalSinceNow > 0.2 else {
                corrected.append(contentsOf: chunks.dropFirst(corrected.count))
                break
            }

            let result = await AITextTransformer.shared.transform(
                kind: kind,
                input: chunk,
                customInstructions: CorrectionPromptBuilder.systemPrompt(
                    policy: request.policy,
                    protectedSpans: request.protectedSpans,
                    locale: request.locale
                )
            )
            switch result {
            case .success(let output):
                // `.preserve`, deliberately: this output came from `AITextTransformer`,
                // which already applied `kind.markdownPolicy` to it. A second pass under a
                // different policy would both override that kind's contract and be the one
                // place where the stripper runs twice over the same text — which is exactly
                // where its idempotence stops holding, over freed fence bodies.
                let cleaned = CorrectionOutputSanitizer.sanitize(
                    output,
                    original: chunk,
                    markdown: .preserve
                )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                corrected.append(cleaned.isEmpty ? chunk : cleaned)
            case .failure(let error):
                DevTypeLog.voice.info("[Voice] \(self.kind.rawValue) pass declined: \(error.localizedDescription)")
                corrected.append(chunk)   // this chunk stays as spoken
            }
        }

        let joined = corrected.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
    #endif
}
