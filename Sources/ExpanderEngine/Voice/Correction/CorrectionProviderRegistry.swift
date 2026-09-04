import Foundation

/// Resolves the corrector for a session, mirroring `SpeechProviderRegistry`.
///
/// Replaces a hardcoded `switch` in the session coordinator. Two things that switch could
/// not do and this can: a corrector may be **registered** (so tests can substitute a stub
/// and exercise the pipeline end to end), and the session's **privacy route is enforced at
/// resolution** — a corrector whose route is wider than the session's is never selected,
/// so a misconfigured preference cannot send a transcript somewhere the user did not agree
/// to.
///
/// Resolution always succeeds: `DeterministicCorrector` is on-device, dependency-free and
/// synchronous, so there is always a floor. Correction is an enhancement — never a reason
/// to fail a dictation.
public actor CorrectionProviderRegistry {
    public static let shared = CorrectionProviderRegistry()

    /// Correction is skipped entirely for this id; the raw transcript is delivered as-is.
    public static let disabledID = "deterministic.none"

    private var providers: [String: TranscriptCorrector] = [:]

    /// An isolated registry containing exactly `providers`. See the note on
    /// `SpeechProviderRegistry.init(providers:)`.
    public init(providers: [TranscriptCorrector]) {
        for provider in providers {
            self.providers[provider.descriptor.id] = provider
        }
    }

    /// The production registry: every shipping corrector.
    public init() {
        for provider in [
            DeterministicCorrector() as TranscriptCorrector,
            FoundationLanguageModelCorrector(),
            AITransformCorrector(kind: .proofread),
            OllamaCorrector(),
            OpenAICompatibleCorrector()
        ] {
            providers[provider.descriptor.id] = provider
        }
    }

    public func register(_ provider: TranscriptCorrector) {
        providers[provider.descriptor.id] = provider
    }

    public func corrector(for id: String) -> TranscriptCorrector? {
        providers[id]
    }

    public func descriptors() -> [CorrectionProviderDescriptor] {
        providers.values.map(\.descriptor).sorted { $0.id < $1.id }
    }

    /// Probes every corrector the session's privacy route permits.
    public func availableProviders(
        for privacyRoute: PrivacyRoute
    ) async -> [(descriptor: CorrectionProviderDescriptor, readiness: ProviderReadiness)] {
        var results: [(CorrectionProviderDescriptor, ProviderReadiness)] = []
        for provider in providers.values where privacyRoute.permits(provider.descriptor.privacyRoute) {
            results.append((provider.descriptor, await provider.probe()))
        }
        return results.sorted { $0.0.id < $1.0.id }
    }

    /// Returns the corrector to use, or `nil` when correction is disabled for this session.
    ///
    /// A preferred corrector is used only when the session's route permits it *and* it
    /// probes ready — an endpoint that is not running must not stall a dictation for the
    /// full timeout before falling back.
    public func resolveActiveCorrector(
        preferredID: String?,
        fallbackIDs: [String] = [],
        privacyRoute: PrivacyRoute
    ) async -> TranscriptCorrector? {
        guard let preferredID, preferredID != Self.disabledID else { return nil }

        var visited = Set<String>()
        for providerID in [preferredID] + fallbackIDs {
            guard providerID != DeterministicCorrector.providerID,
                  visited.insert(providerID).inserted,
                  let candidate = providers[providerID],
                  privacyRoute.permits(candidate.descriptor.privacyRoute),
                  await candidate.probe().isReady else {
                continue
            }
            return candidate
        }

        guard let floor = providers[DeterministicCorrector.providerID],
              privacyRoute.permits(floor.descriptor.privacyRoute) else {
            return nil
        }
        return floor
    }

}
