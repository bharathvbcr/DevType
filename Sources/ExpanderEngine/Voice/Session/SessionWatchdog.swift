import Foundation

/// A single-shot deadline that fires unless it is disarmed first.
///
/// Bounds every phase of a dictation after capture ends. Capture itself is deliberately
/// unbounded — the user decides how long to talk — but once the hotkey is released,
/// recognition, correction and delivery must all complete or the session must fail. Without
/// this, a provider that never yields leaves the HUD spinning with no route back to idle
/// and no way for the user to start again.
///
/// Extracted from `VoiceSessionCoordinator` so the arm / disarm / fire logic can be tested
/// directly: inside the coordinator it was reachable only by running a real dictation.
public actor SessionWatchdog {

    /// Floor on the deadline. A zero or negative budget would fire immediately and turn
    /// every session into a timeout.
    public static let minimumSeconds: Double = 1.0

    private var task: Task<Void, Never>?
    private var armedGeneration: SessionGeneration?

    public init() {}

    /// Whether a deadline is currently pending.
    public var isArmed: Bool { task != nil }

    /// The generation the pending deadline belongs to, if any.
    public var pendingGeneration: SessionGeneration? { armedGeneration }

    /// Arms the deadline, replacing any previous one.
    ///
    /// `onExpiry` receives the generation that was armed, so a late fire from a superseded
    /// session can be recognised and ignored by the caller.
    public func arm(
        seconds: Double,
        generation: SessionGeneration,
        onExpiry: @escaping @Sendable (SessionGeneration) async -> Void
    ) {
        task?.cancel()
        armedGeneration = generation

        let budget = max(Self.minimumSeconds, seconds)
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fire(generation: generation, onExpiry: onExpiry)
        }
    }

    /// Cancels the pending deadline. Safe to call when nothing is armed.
    public func disarm() {
        task?.cancel()
        task = nil
        armedGeneration = nil
    }

    private func fire(
        generation: SessionGeneration,
        onExpiry: @escaping @Sendable (SessionGeneration) async -> Void
    ) async {
        // A newer arm replaced this one between the sleep ending and this running.
        guard armedGeneration == generation else { return }
        task = nil
        armedGeneration = nil
        await onExpiry(generation)
    }
}
