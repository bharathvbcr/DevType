import Foundation

/// Which entry-gate condition refused an inject. Each case is its own line in the
/// diagnostic report, because each is a different bug: `.continuation` on a panel-driven
/// inject means the source app never came back to the front, while `.targetChanged` means
/// it did and then the focused element moved under us.
enum EntryGateRefusal: String {
    case superseded
    case continuation
    case secureInput
    case accessibility
    case targetChanged
    /// The gate refused, but no condition still reported false when the reason was
    /// classified. Named rather than guessed — a label invented here would send whoever
    /// reads the report after the wrong condition.
    case unreproduced

    var path: String { "entryGate_\(rawValue)" }

    var reason: String {
        switch self {
        case .superseded: return "A newer insertion replaced this one"
        case .continuation: return "Target application changed before insertion"
        case .secureInput: return AXContextChecker.secureInputActiveReason
        case .accessibility: return "Accessibility unavailable at insertion time"
        case .targetChanged: return "Target element or selection changed before insertion"
        case .unreproduced: return "Insertion context changed before insertion"
        }
    }

    /// Pure: names the entry-gate refusal from what each half reported, in the order
    /// `TextInjectionPipeline.operationIsCurrent` tests them. Pure so every branch is reachable
    /// in tests without a window server, an AX connection, or a focused app.
    static func classify(
        revisionCurrent: Bool,
        continuationBlock: InjectCompletionGuard.ContinuationBlock?,
        secureInputBlocked: Bool,
        axUntrusted: Bool,
        targetCurrent: Bool
    ) -> EntryGateRefusal {
        if !revisionCurrent { return .superseded }
        if let continuationBlock {
            return continuationBlock == .callerStopped ? .continuation : .superseded
        }
        if secureInputBlocked { return .secureInput }
        if axUntrusted { return .accessibility }
        if !targetCurrent { return .targetChanged }
        return .unreproduced
    }

    /// Which target mismatch a refusal records, if any.
    ///
    /// Only a `.targetChanged` refusal may carry one. The gate reads the target before it knows
    /// which condition will win, so a supersession or a Secure Input block can easily coincide
    /// with a target that also happens to have moved — and a report that prints
    /// `Refuse reason: superseded` beside `Target mismatch: elementChanged` sends the reader
    /// after a focus bug that had nothing to do with the refusal. The mismatch is evidence for
    /// exactly one label, so it is attached to exactly that one.
    static func recordedTargetMismatch(
        refusal: EntryGateRefusal,
        mismatch: PasteboardBroker.PasteTarget.Mismatch?
    ) -> String? {
        refusal == .targetChanged ? mismatch?.rawValue : nil
    }
}
