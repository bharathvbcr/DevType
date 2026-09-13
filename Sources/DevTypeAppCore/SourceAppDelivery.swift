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
        /// Owner of the system-wide AX focused element. Defaults to `.notObserved` so a caller
        /// that builds an `Environment` without it keeps the pre-focus-wait behaviour.
        var axFocus: @Sendable () -> SelectionReader.AXFocusObservation = { .notObserved }
    }

    static func perform(
        sourceApp: NSRunningApplication?,
        onUnavailable: @escaping () -> Void,
        operation: @escaping (@escaping @Sendable () -> Bool) -> Void
    ) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        perform(
            sourcePID: sourceApp?.processIdentifier ?? 0,
            ownPID: ownPID,
            environment: Environment(
                frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                sourceTerminated: { sourceApp?.isTerminated ?? true },
                activate: { sourceApp?.activate() },
                schedule: { delay, action in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
                },
                // The operation's first act is to capture a paste target from AX, so waiting for
                // activation to reach NSWorkspace is not enough — the capture has to see the
                // source app's focused element, not the empty gap before it is published, and
                // not the short-lived one an app republishes while it comes back to the front.
                // The element identity is what lets the poll tell those two apart; see
                // `sourceFocusRetryDecision`.
                axFocus: {
                    guard let element = AXContextChecker.shared.focusedElement() else {
                        return classifyFocus(elementOwner: nil, elementIdentity: nil, ownPID: ownPID)
                    }
                    return classifyFocus(
                        elementOwner: SelectionMonitor.pid(owning: element),
                        elementIdentity: UInt64(CFHash(element)),
                        ownPID: ownPID
                    )
                }
            ),
            onUnavailable: onUnavailable,
            operation: operation
        )
    }

    /// Classify an AX focus reading for the focus wait. Pure: the AX round-trip stays at the
    /// call site so every branch is reachable in tests without a window server.
    ///
    /// Getting `.ownProcess` wrong in either direction is a real bug rather than a slow path.
    /// Reporting our own panel as `.external` lets the wait settle on DevType's own search
    /// field and capture *that* as the user's target; reporting a genuine external element as
    /// `.ownProcess` stalls every delivery for the whole budget and then reads anyway.
    static func classifyFocus(
        elementOwner: pid_t?,
        elementIdentity: UInt64?,
        ownPID: pid_t
    ) -> SelectionReader.AXFocusObservation {
        // No element at all: focus has not been published yet, by anyone.
        guard let elementIdentity else { return .unfocused }
        // An unreadable pid resolves to "not ours", the same way
        // `SelectionReader.makeCandidate` resolves it. Stalling a delivery that is perfectly
        // safe costs the user an already-generated payload, and the inject's own entry gate
        // still verifies the target before anything is written.
        guard elementOwner == ownPID else { return .external(element: elementIdentity) }
        return .ownProcess
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

        func poll(remainingPolls: Int, previousFocus: SelectionReader.AXFocusObservation) {
            let currentPID = frontmostPID()
            // Activation may still be pending while our panel is frontmost (or
            // the window server reports no app). A third app is a user's focus
            // change: stop instead of waiting to paste when they switch back.
            if let currentPID, currentPID != ownPID, currentPID != sourcePID {
                onUnavailable()
                return
            }
            // Probed only once the frontmost check has a chance of passing, so a source app
            // that never activates costs no AX round-trips at all.
            let focus = currentPID == sourcePID
                ? environment.axFocus()
                : SelectionReader.AXFocusObservation.notObserved
            switch SelectionReader.sourceFocusRetryDecision(
                sourcePID: sourcePID,
                frontmostPID: currentPID,
                sourceTerminated: sourceTerminated(),
                remainingPolls: remainingPolls,
                axFocus: focus,
                previousAXFocus: previousFocus
            ) {
            case .read:
                operation(shouldContinue)
            case .wait(let next):
                environment.schedule(SelectionReader.sourceFocusPollInterval) {
                    // This poll's observation is the next one's baseline — the settle is a
                    // property of consecutive reads, so it has to be carried, not re-derived.
                    poll(remainingPolls: next, previousFocus: focus)
                }
            case .fail:
                onUnavailable()
            }
        }

        environment.activate()
        poll(remainingPolls: SelectionReader.sourceFocusMaxPolls, previousFocus: .notObserved)
    }
}
