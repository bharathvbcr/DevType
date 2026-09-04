import ExpanderEngine

/// Edge-trigger policy between polled/runtime status and persistent activity. Repeated probes are
/// intentionally quiet, and free-form refusal reasons never participate in event identity.
struct ActivityTransitionTracker {
    private struct PermissionState: Equatable {
        let snapshot: PermissionSnapshot
        let tapRunning: Bool
    }

    private enum InjectFailureState: Equatable {
        case refused
        case failed
    }

    private var lastPermissionState: PermissionState?
    private var lastInjectFailureState: InjectFailureState?
    private var lastSecureInputActive: Bool?

    mutating func signals(for status: PermissionCoordinator.Status) -> [ActivitySignal] {
        var signals: [ActivitySignal] = []
        let permissionState = PermissionState(
            snapshot: status.snapshot,
            tapRunning: status.tapRunning
        )
        if permissionState != lastPermissionState {
            // Healthy startup is expected state, not an event. An unhealthy first observation and
            // every later transition are useful because they explain why expansion changed.
            if lastPermissionState != nil
                || !status.snapshot.isFullyCapable
                || !status.tapRunning {
                signals.append(
                    .permissionState(snapshot: status.snapshot, tapRunning: status.tapRunning)
                )
            }
            lastPermissionState = permissionState
        }

        let failureState: InjectFailureState?
        switch status.lastInjectOutcome {
        case .refused:
            failureState = .refused
        case .failedSilent:
            failureState = .failed
        case .succeeded, .postedUnverified, .degradedAXOnly, .none:
            failureState = nil
        }
        if failureState != lastInjectFailureState {
            switch failureState {
            case .refused: signals.append(.injectionRefused)
            case .failed: signals.append(.injectionFailed)
            case .none: break
            }
            lastInjectFailureState = failureState
        }
        return signals
    }

    mutating func signalForSecureInput(active: Bool) -> ActivitySignal? {
        defer { lastSecureInputActive = active }
        guard let previous = lastSecureInputActive else {
            return active ? .secureInputChanged(active: true) : nil
        }
        guard previous != active else { return nil }
        return .secureInputChanged(active: active)
    }
}
