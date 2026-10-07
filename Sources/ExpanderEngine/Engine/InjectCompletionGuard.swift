import Foundation

/// §1.3: guards the single-completion contract of one inject.
///
/// Two failure modes, both of which used to corrupt the serial inject queue silently: a path that
/// never calls its completion (the queue blocks forever and `isExpanding` never clears), and a path
/// that calls it twice (leaving a `DispatchGroup` more times than it was entered traps).
final class InjectCompletionGuard {
    private let lock = UnfairLock()
    private var invocations = 0
    private var timedOut = false
    private var cancelled = false
    private var outcome: PermissionCoordinator.InjectOutcome?
    private let shouldContinue: @Sendable () -> Bool

    init(shouldContinue: @escaping @Sendable () -> Bool = { true }) {
        self.shouldContinue = shouldContinue
    }

    /// Returns the 1-based invocation index. Only `1` may leave the group.
    func markCompleted(_ outcome: PermissionCoordinator.InjectOutcome) -> Int {
        lock.lock()
        invocations += 1
        if self.outcome == nil {
            self.outcome = outcome
        }
        let count = invocations
        lock.unlock()
        return count
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        if outcome == nil {
            outcome = .failedSilent
        }
        lock.unlock()
    }

    func cancel() { lock.withLock { cancelled = true } }

    /// Why continuation is blocked, in the order the guard tests it. Exists so a refused
    /// inject can name its cause instead of ending as a bare `return`: `.callerStopped` is
    /// the caller's own `shouldContinue` (for panel-driven injects, "the source app is no
    /// longer frontmost"), which is a different bug report from being superseded.
    enum ContinuationBlock: String {
        case cancelled = "supersededByNewerInject"
        case timedOut = "watchdogTimedOut"
        case alreadyCompleted = "alreadyCompleted"
        case callerStopped = "callerStopped"
    }

    /// `nil` when continuation is allowed. Non-destructive, and the single owner of the rule —
    /// `allowsContinuation` is this answer collapsed to a Bool, so the gate and the reason it
    /// reports can never disagree.
    func continuationBlock(observationOnly: Bool = false) -> ContinuationBlock? {
        let local: ContinuationBlock? = lock.withLock {
            if cancelled { return .cancelled }
            if timedOut { return .timedOut }
            if !observationOnly, invocations != 0 { return .alreadyCompleted }
            return nil
        }
        // Preserves the original short-circuit: the caller's closure is only consulted once
        // the local state says yes.
        if let local { return local }
        return shouldContinue() ? nil : .callerStopped
    }

    func allowsContinuation(observationOnly: Bool = false) -> Bool {
        continuationBlock(observationOnly: observationOnly) == nil
    }

    var didTimeOut: Bool {
        lock.withLock { timedOut }
    }

    var terminalOutcome: PermissionCoordinator.InjectOutcome? {
        lock.withLock { outcome }
    }
}
