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
/// Pure over its clock and scheduler so the whole policy is driven by a test: the wait is polled at
/// the witness interval (a read ends it early and the wait has to notice), every poll re-asks
/// whether the operation is still current, and the total is bounded by the same ceiling that
/// bounds the payload it is waiting for.
enum BoardHoldOff {
    /// Longest the whole wait may run: the lease a pending payload can hold the board, its read
    /// grace, and a poll of slack. A gate that is still closed past this is not going to open.
    static let maximumWait: TimeInterval =
        InjectTiming.unverifiedPayloadResidencyCeiling + InjectTiming.payloadReadGrace
        + InjectTiming.payloadWitnessPollInterval

    /// Calls `proceed` once `remaining()` reports zero, or `abandon` if `stillCurrent()` goes false
    /// or the wait exceeds `maximumWait`. Exactly one of the two is called, and nothing is
    /// scheduled after it. A board that is free at the start proceeds synchronously.
    static func untilFree(
        remaining: @escaping () -> TimeInterval,
        stillCurrent: @escaping () -> Bool,
        schedule: @escaping (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void,
        proceed: @escaping () -> Void,
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
        proceed: @escaping () -> Void,
        abandon: @escaping () -> Void
    ) {
        let wait = remaining()
        guard wait.isFinite, wait > 0 else {
            proceed()
            return
        }
        guard waited < maximumWait else {
            abandon()
            return
        }
        let delay = min(wait, InjectTiming.payloadWitnessPollInterval)
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
