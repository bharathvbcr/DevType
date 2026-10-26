import Foundation

/// Waits out a previous expansion's unread clipboard payload *before* the next one erases anything.
///
/// The paste's own publication gate (`PasteboardBroker.publicationGateWait`) exists for the same
/// reason but runs after the erase: the trigger is gone, the field has a hole, and the typed-ahead
/// keys the engine is holding give up at `TypeAheadBuffer.defaultDeadline` (0.35 s) while the gate
/// can last until the residency ceiling (2 s). Anything typed after the surrender is replayed ahead
/// of the paste and moves the input revision, which refuses the expansion — with the trigger already
/// deleted. Holding here instead means a refusal costs nothing: the field is untouched and the
/// swallowed key is still the caller's to put back.
///
/// Pure over its clock and scheduler so the whole policy is driven by a test: the wait is polled
/// (the board can be freed early — the user copied, the payload was released — and the wait has to
/// notice), and every poll re-asks whether the operation is still current.
///
/// The wait is bounded by `budget`, not by the payload's residency. The residency floor (0.45 s)
/// outlasts the type-ahead hold (0.35 s), and the hold surrenders on the first real key after its
/// deadline: a wait that ran the residency out let held keys land, moved the input revision, and
/// abandoned the expansion with its swallowed terminator already gone. Past the budget the inject
/// proceeds and publishes over the unread payload — exactly what every expansion did before the
/// gate existed — so the bounded wait can only ever improve on that, never cost a keystroke.
enum BoardHoldOff {
    /// How often the wait looks again. Short enough that a freed board is noticed promptly and an
    /// input arriving during the wait ends it within a poll.
    static let pollInterval: TimeInterval = 0.05

    /// Longest the wait may run before it gives up on the board: half the type-ahead hold. The
    /// erase and paste that follow take tens of milliseconds (2 ms per backspace, a 10 ms trailing
    /// settle, one chord), so the other half leaves them room inside the hold.
    static let budget: TimeInterval = TypeAheadBuffer.defaultDeadline / 2

    /// Calls `proceed(false)` once `remaining()` reports zero, `proceed(true)` when the budget is
    /// spent with the board still busy (the caller then publishes over it without waiting again),
    /// or `abandon` if `stillCurrent()` goes false. Exactly one is called, once, and nothing is
    /// scheduled after it. A board that is free at the start proceeds synchronously.
    static func untilFree(
        remaining: @escaping () -> TimeInterval,
        stillCurrent: @escaping () -> Bool,
        schedule: @escaping (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void,
        proceed: @escaping (_ gateWaived: Bool) -> Void,
        abandon: @escaping () -> Void
    ) {
        step(
            waited: 0, remaining: remaining, stillCurrent: stillCurrent, schedule: schedule,
            proceed: proceed, abandon: abandon
        )
    }

    private static func step(
        waited: TimeInterval,
        remaining: @escaping () -> TimeInterval,
        stillCurrent: @escaping () -> Bool,
        schedule: @escaping (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void,
        proceed: @escaping (_ gateWaived: Bool) -> Void,
        abandon: @escaping () -> Void
    ) {
        let wait = remaining()
        // A reading that is not a number cannot be waited out; treat it as a busy board whose
        // budget is spent rather than send the paste to wait on it again.
        guard wait.isFinite else {
            proceed(true)
            return
        }
        guard wait > 0 else {
            proceed(false)
            return
        }
        guard waited < budget else {
            proceed(true)
            return
        }
        let delay = min(wait, pollInterval, budget - waited)
        schedule(delay) {
            guard stillCurrent() else {
                abandon()
                return
            }
            step(
                waited: waited + delay, remaining: remaining, stillCurrent: stillCurrent,
                schedule: schedule, proceed: proceed, abandon: abandon
            )
        }
    }
}
