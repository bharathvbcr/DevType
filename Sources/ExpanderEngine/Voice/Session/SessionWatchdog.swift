import Foundation

/// A single-shot deadline that fires unless it is disarmed first.
///
/// Bounds a phase of dictation. The coordinator uses one instance for finite active capture and
/// another after capture ends, so both a forgotten hands-free recording and a provider that never
/// yields have a deterministic route out of their phase.
///
/// Extracted from `VoiceSessionCoordinator` so the arm / disarm / fire logic can be tested
/// directly: inside the coordinator it was reachable only by running a real dictation.
public actor SessionWatchdog {

    /// Floor on the deadline. A zero or negative budget would fire immediately and turn
    /// every session into a timeout.
    public static let minimumSeconds: Double = 1.0
    /// A one-day ceiling is far above any legitimate dictation/provider wait and keeps both the
    /// sleep nanoseconds and `Date.addingTimeInterval` consumers comfortably representable.
    static let maximumSeconds: Double = 24 * 60 * 60

    private var task: Task<Void, Never>?
    private var armedGeneration: SessionGeneration?
    /// A generation identifies the owning session, but not a particular arm within that session.
    /// Keep a distinct token so a cancelled fire job from an earlier same-generation arm cannot
    /// clear its replacement after it has already crossed the cancellation check.
    private var armedID: UUID?
    private let expiryPreparation: (@Sendable (SessionGeneration) async -> Void)?

    public init() {
        expiryPreparation = nil
    }

    /// Deterministic seam for the cancellation-check-to-fire race. Production uses `init()`.
    init(expiryPreparation: @escaping @Sendable (SessionGeneration) async -> Void) {
        self.expiryPreparation = expiryPreparation
    }

    /// Whether a deadline is currently pending.
    public var isArmed: Bool { task != nil }

    /// The generation the pending deadline belongs to, if any.
    public var pendingGeneration: SessionGeneration? { armedGeneration }

    /// Arms the deadline, replacing any previous one.
    ///
    /// `onExpiry` receives the generation that was armed, so a late fire from a superseded
    /// session can be recognised and ignored by the caller.
    @discardableResult
    public func arm(
        seconds: Double,
        generation: SessionGeneration,
        onExpiry: @escaping @Sendable (SessionGeneration) async -> Void
    ) -> Bool {
        // An unstructured coordinator task from an older session may arrive after the new
        // generation armed its deadline. Never let that stale arm replace the current timer.
        if let armedGeneration, generation < armedGeneration {
            return false
        }
        task?.cancel()
        armedGeneration = generation
        let armID = UUID()
        armedID = armID

        let budget = Self.normalizedSeconds(seconds)
        let expiryPreparation = self.expiryPreparation
        // `maximumSeconds` is deliberately conservative, so this conversion cannot overflow.
        let nanoseconds = UInt64(budget * 1_000_000_000)
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await expiryPreparation?(generation)
            await self?.fire(generation: generation, armID: armID, onExpiry: onExpiry)
        }
        return true
    }

    /// Converts untrusted preference/configuration input into a representable sleep duration.
    /// NaN and negative infinity must not reach `UInt64(Double)`, which traps; positive infinity
    /// is bounded so a malformed setting cannot overflow the nanosecond conversion.
    static func normalizedSeconds(_ seconds: Double) -> Double {
        guard !seconds.isNaN else { return minimumSeconds }
        guard seconds.isFinite else {
            return seconds > 0 ? maximumSeconds : minimumSeconds
        }
        return min(max(minimumSeconds, seconds), maximumSeconds)
    }

    /// Cancels the pending deadline. Safe to call when nothing is armed.
    public func disarm() {
        task?.cancel()
        task = nil
        armedGeneration = nil
        armedID = nil
    }

    /// Cancels only the deadline owned by `generation`. Cleanup work is intentionally allowed to
    /// arrive late, but it must not tear down a newer session's timer.
    @discardableResult
    public func disarm(ifArmedFor generation: SessionGeneration) -> Bool {
        guard armedGeneration == generation else { return false }
        disarm()
        return true
    }

    private func fire(
        generation: SessionGeneration,
        armID: UUID,
        onExpiry: @escaping @Sendable (SessionGeneration) async -> Void
    ) async {
        // A newer arm — including one for the same generation — replaced this one between the
        // sleep ending and this actor-isolated check running.
        guard armedGeneration == generation, armedID == armID else { return }
        task = nil
        armedGeneration = nil
        armedID = nil
        await onExpiry(generation)
    }
}
