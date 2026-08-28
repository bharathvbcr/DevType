import Foundation

public enum CorrectionPipeline {
    public static func execute(
        rawTranscript: RawTranscript,
        corrector: TranscriptCorrector,
        policy: CorrectionPolicy,
        vocabulary: VocabularySnapshot,
        deadline: Date,
        privacyRoute: PrivacyRoute,
        sessionID: VoiceSessionID,
        generation: SessionGeneration
    ) async -> FinalTranscript {
        let spans = ProtectedSpanExtractor.extract(from: rawTranscript.text, dictionaryTerms: vocabulary.terms)

        let request = CorrectionRequest(
            sessionID: sessionID,
            generation: generation,
            rawTranscript: rawTranscript.text,
            policy: policy,
            protectedSpans: spans,
            deadline: deadline,
            privacyRoute: privacyRoute
        )

        do {
            let candidate = try await corrector.correct(request)
            let outcome = CorrectionValidator.validate(candidate: candidate, raw: rawTranscript, policy: policy, protectedSpans: spans)

            switch outcome {
            case .accepted:
                return FinalTranscript(
                    text: candidate.text,
                    rawTranscript: rawTranscript,
                    correctionCandidate: candidate,
                    validationOutcome: outcome
                )
            case .fallbackToRaw(let reason):
                return FinalTranscript(
                    text: rawTranscript.text,
                    rawTranscript: rawTranscript,
                    correctionCandidate: candidate,
                    validationOutcome: .fallbackToRaw(reason: reason)
                )
            case .rejected(let reasons):
                let firstReason = reasons.first ?? .correctionUnsupportedEdit
                return FinalTranscript(
                    text: rawTranscript.text,
                    rawTranscript: rawTranscript,
                    correctionCandidate: candidate,
                    validationOutcome: .fallbackToRaw(reason: firstReason)
                )
            case .notApplicable:
                return FinalTranscript(
                    text: rawTranscript.text,
                    rawTranscript: rawTranscript,
                    correctionCandidate: nil,
                    validationOutcome: .notApplicable
                )
            }
        } catch {
            let fallbackOutcome: ValidationOutcome = .fallbackToRaw(reason: .correctionTimeout)
            return FinalTranscript(
                text: rawTranscript.text,
                rawTranscript: rawTranscript,
                correctionCandidate: nil,
                validationOutcome: fallbackOutcome
            )
        }
    }
}
