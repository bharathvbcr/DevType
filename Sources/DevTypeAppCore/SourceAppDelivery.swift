import AppKit
import ExpanderEngine

/// Restores a panel's source app before handing text to the injection pipeline.
/// Focus activation is asynchronous and may be refused. No caller may substitute
/// the app that happens to be frontmost after a fixed delay. The continuation
/// preserves the original process through the pipeline's later queue/clipboard waits.
enum SourceAppDelivery {
    /// Report-ready name of what the focus wait ended on. Settled means the same element answered
    /// twice running (`previous == focus`); an `.external` reading that differs from the last one
    /// was only read because the budget ran out, and says so. Every other reading is the budget
    /// running out with nothing published, and the read going ahead anyway.
    fileprivate static func label(
        _ focus: SelectionReader.AXFocusObservation,
        previous: SelectionReader.AXFocusObservation
    ) -> String {
        switch focus {
        case .external: return focus == previous ? "settled on a field" : "budget spent, field still changing"
        case .unfocused: return "budget spent, no field published (none, or a window-level container)"
        case .ownProcess: return "budget spent, focus still in DevType"
        case .notObserved: return "focus not probed"
        }
    }

    struct Environment {
        var frontmostPID: @Sendable () -> pid_t?
        var sourceTerminated: @Sendable () -> Bool
        var activate: () -> Void
        var schedule: (TimeInterval, @escaping () -> Void) -> Void
        /// Owner of the system-wide AX focused element. Defaults to `.notObserved` so a caller
        /// that builds an `Environment` without it keeps the pre-focus-wait behaviour.
        var axFocus: @Sendable () -> SelectionReader.AXFocusObservation = { .notObserved }
    }

    /// Whether a delivery aimed at `sourceApp` would be refused before it ever activates
    /// anything — asked by the panels *before* they spend the work delivery would then throw
    /// away. `nil` means "nothing in the entry guard objects"; the focus wait still applies.
    static func entryUnavailability(
        sourceApp: NSRunningApplication?
    ) -> SelectionReader.SourceUnavailability? {
        SelectionReader.sourceEntryUnavailability(
            sourcePID: sourceApp?.processIdentifier ?? 0,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            sourceTerminated: { sourceApp?.isTerminated ?? true }
        )
    }

    static func perform(
        sourceApp: NSRunningApplication?,
        onUnavailable: @escaping (SelectionReader.SourceUnavailability) -> Void,
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
                        ownPID: ownPID,
                        elementRole: AXContextChecker.shared.focusedElementRole(element: element)
                    )
                }
            ),
            onUnavailable: onUnavailable,
            operation: operation
        )
    }

    /// Classify an AX focus reading for the focus wait. `elementRole` is the focused element's
    /// `kAXRoleAttribute`; nil when the host did not answer it. Pure: the AX round-trip stays at the
    /// call site so every branch is reachable in tests without a window server.
    ///
    /// Getting `.ownProcess` wrong in either direction is a real bug rather than a slow path.
    /// Reporting our own panel as `.external` lets the wait settle on DevType's own search
    /// field and capture *that* as the user's target; reporting a genuine external element as
    /// `.ownProcess` stalls every delivery for the whole budget and then reads anyway.
    static func classifyFocus(
        elementOwner: pid_t?,
        elementIdentity: UInt64?,
        ownPID: pid_t,
        elementRole: String? = nil
    ) -> SelectionReader.AXFocusObservation {
        // No element at all: focus has not been published yet, by anyone.
        guard let elementIdentity else { return .unfocused }
        // An unreadable pid resolves to "not ours", the same way
        // `SelectionReader.makeCandidate` resolves it. Stalling a delivery that is perfectly
        // safe costs the user an already-generated payload, and the inject's own entry gate
        // still verifies the target before anything is written.
        guard elementOwner != ownPID else { return .ownProcess }
        // A window-level container is focus that has not arrived: Safari answers with its stable
        // AXWindow while WebKit restores the page, and a wait keyed on identity alone settles on
        // it after two polls and captures it as the paste target. Not stalled on forever — the
        // budget still ends in a read — and an unreadable role is not a container.
        if AXContextChecker.isWindowLevelContainer(role: elementRole) { return .unfocused }
        return .external(element: elementIdentity)
    }

    static func perform(
        sourcePID: pid_t,
        ownPID: pid_t,
        environment: Environment,
        onUnavailable: @escaping (SelectionReader.SourceUnavailability) -> Void,
        operation: @escaping (@escaping @Sendable () -> Bool) -> Void
    ) {
        if let unavailable = SelectionReader.sourceEntryUnavailability(
            sourcePID: sourcePID,
            ownPID: ownPID,
            sourceTerminated: environment.sourceTerminated
        ) {
            onUnavailable(unavailable)
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
                onUnavailable(.replacedByAnotherApp)
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
                // What the next field report needs to judge the replace guard's settle budget:
                // how long the source app took to publish a field after `activate()`, and whether
                // the wait settled on one or ran out and read anyway.
                let elapsed = Int(Date().timeIntervalSince(activatedAt) * 1000)
                let polls = SelectionReader.sourceFocusMaxPolls - remainingPolls
                DevTypeLog.inject.info(
                    "[SourceFocus] read after \(elapsed, privacy: .public) ms, \(polls, privacy: .public) polls — \(label(focus, previous: previousFocus), privacy: .public)"
                )
                operation(shouldContinue)
            case .wait(let next):
                environment.schedule(SelectionReader.sourceFocusPollInterval) {
                    // This poll's observation is the next one's baseline — the settle is a
                    // property of consecutive reads, so it has to be carried, not re-derived.
                    poll(remainingPolls: next, previousFocus: focus)
                }
            case .fail:
                // `sourceFocusRetryDecision` fails on a dead source and on an exhausted budget
                // alike. Re-ask rather than reporting the budget for both: "quit" and "never
                // came forward" are the difference between lost work and a stuck activation.
                onUnavailable(sourceTerminated() ? .sourceTerminated : .focusNeverReturned)
            }
        }

        let activatedAt = Date()
        environment.activate()
        poll(remainingPolls: SelectionReader.sourceFocusMaxPolls, previousFocus: .notObserved)
    }
}
