import AppKit
import ExpanderEngine

/// Restores a panel's source app before handing text to the injection pipeline.
/// Focus activation is asynchronous and may be refused. No caller may substitute
/// the app that happens to be frontmost after a fixed delay. The continuation
/// preserves the original process through the pipeline's later queue/clipboard waits.
enum SourceAppDelivery {
    struct Environment {
        var frontmostPID: @Sendable () -> pid_t?
        var sourceTerminated: @Sendable () -> Bool
        var activate: () -> Void
        var schedule: (TimeInterval, @escaping () -> Void) -> Void
    }

    static func perform(
        sourceApp: NSRunningApplication?,
        onUnavailable: @escaping () -> Void,
        operation: @escaping (@escaping @Sendable () -> Bool) -> Void
    ) {
        perform(
            sourcePID: sourceApp?.processIdentifier ?? 0,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            environment: Environment(
                frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                sourceTerminated: { sourceApp?.isTerminated ?? true },
                activate: { sourceApp?.activate() },
                schedule: { delay, action in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
                }
            ),
            onUnavailable: onUnavailable,
            operation: operation
        )
    }

    static func perform(
        sourcePID: pid_t,
        ownPID: pid_t,
        environment: Environment,
        onUnavailable: @escaping () -> Void,
        operation: @escaping (@escaping @Sendable () -> Bool) -> Void
    ) {
        guard sourcePID > 0, sourcePID != ownPID, !environment.sourceTerminated() else {
            onUnavailable()
            return
        }
        let frontmostPID = environment.frontmostPID
        let sourceTerminated = environment.sourceTerminated
        let shouldContinue: @Sendable () -> Bool = {
            !sourceTerminated() && frontmostPID() == sourcePID
        }

        func poll(remainingPolls: Int) {
            let currentPID = frontmostPID()
            // Activation may still be pending while our panel is frontmost (or
            // the window server reports no app). A third app is a user's focus
            // change: stop instead of waiting to paste when they switch back.
            if let currentPID, currentPID != ownPID, currentPID != sourcePID {
                onUnavailable()
                return
            }
            switch SelectionReader.sourceFocusRetryDecision(
                sourcePID: sourcePID,
                frontmostPID: currentPID,
                sourceTerminated: sourceTerminated(),
                remainingPolls: remainingPolls
            ) {
            case .read:
                operation(shouldContinue)
            case .wait(let next):
                environment.schedule(SelectionReader.sourceFocusPollInterval) {
                    poll(remainingPolls: next)
                }
            case .fail:
                onUnavailable()
            }
        }

        environment.activate()
        poll(remainingPolls: SelectionReader.sourceFocusMaxPolls)
    }
}
