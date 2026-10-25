// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation
import os

/// Marks synthetic events injected by DevType so the event tap can ignore them.
public enum SyntheticEventMarker {
    public static let magicUserData: Int64 = 0x534E_4950 // "SNIP"
}

public enum ExpansionDecision: Equatable {
    case proceed
    case abort(inputArrivedAt: TimeInterval)
}

public struct InputQuiescenceGuard: Equatable {
    public let armedAt: TimeInterval

    public init(armedAt: TimeInterval) {
        self.armedAt = armedAt
    }

    public func decide(lastInputAt: TimeInterval?) -> ExpansionDecision {
        guard let lastInputAt, lastInputAt > armedAt else { return .proceed }
        return .abort(inputArrivedAt: lastInputAt)
    }
}

public final class InputClock: @unchecked Sendable {
    /// §2.4: `mark(at:)` runs inside the CGEventTap callback on every key event. `NSLock` does
    /// not donate priority, so the user-interactive tap could block behind a lower-QoS thread
    /// holding this lock. `UnfairLock` (os_unfair_lock) does.
    private let lock = UnfairLock()
    private var last: TimeInterval?
    private let clock: () -> TimeInterval

    /// CGEvent.timestamp uses boot-relative nanoseconds → seconds.
    public static func seconds(sinceBootNanos nanos: UInt64) -> TimeInterval {
        Double(nanos) / 1_000_000_000
    }

    public static func monotonicNow() -> TimeInterval {
        seconds(sinceBootNanos: DispatchTime.now().uptimeNanoseconds)
    }

    public init(now: @escaping () -> TimeInterval = InputClock.monotonicNow) {
        self.clock = now
    }

    /// What one `mark(at:)` did, so exactly that mark can be taken back by `retract(_:)`.
    public struct Mark: Equatable {
        fileprivate let time: TimeInterval
        fileprivate let previous: TimeInterval?
    }

    @discardableResult
    public func mark(at eventTime: TimeInterval) -> Mark {
        lock.lock()
        let previous = last
        last = Swift.max(last ?? eventTime, eventTime)
        lock.unlock()
        return Mark(time: eventTime, previous: previous)
    }

    /// Takes back a mark for a key that turned out never to reach the field.
    ///
    /// The tap marks every key at entry, *before* it knows what becomes of the key: the ordering
    /// is what lets a debounce timeout prove quiescence (see `expandHeld`). A key that the
    /// type-ahead buffer then swallows is held and replayed *after* delivery, so it cannot move
    /// the caret or change the text under the erase the quiescence check protects — counting it
    /// aborted every expansion whose AX probe was slower than the user's next keystroke.
    ///
    /// Only the mark itself is undone: if a later key has marked since, `last` belongs to that
    /// key and stays. The callback is the sole writer, so this cannot race another mark; a reader
    /// that lands between mark and retract sees the key, which errs toward aborting.
    public func retract(_ mark: Mark) {
        lock.lock()
        if last == mark.time { last = mark.previous }
        lock.unlock()
    }

    private var timestampUnitsNoted = false

    /// Records, once per process, how `CGEvent.timestamp` compares with `DispatchTime` uptime.
    ///
    /// `mark(at:)` takes the event's own time and `arm()` takes `clock()`, so the deferred-expand
    /// quiescence decision is only meaningful when the two share a unit. The SDK calls the event
    /// timestamp "roughly nanoseconds since startup"; were a host to report mach ticks instead
    /// (Apple silicon's timebase is 125/3), every mark would read ~24× earlier than any arm and
    /// that guard could never abort. A constructed event carries 0, so no test can answer this —
    /// one report line from a real tap does: a ratio near 1 is nanoseconds, near 0.024 is ticks.
    /// A zero timestamp is skipped without spending the once.
    @discardableResult
    public func noteTimestampUnitsOnce(
        eventNanos: UInt64,
        uptimeNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Double? {
        guard eventNanos > 0, uptimeNanos > 0 else { return nil }
        lock.lock()
        let first = !timestampUnitsNoted
        timestampUnitsNoted = true
        lock.unlock()
        guard first else { return nil }
        let ratio = Double(eventNanos) / Double(uptimeNanos)
        DevTypeLog.debounce.notice(
            "[Debounce] event timestamp units ratio=\(ratio, format: .fixed(precision: 4), privacy: .public) (≈1 nanoseconds; ≈0.024 mach ticks)"
        )
        return ratio
    }

    public var lastInputAt: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    public func arm() -> InputQuiescenceGuard {
        InputQuiescenceGuard(armedAt: clock())
    }

    public func decide(_ quiescence: InputQuiescenceGuard) -> ExpansionDecision {
        quiescence.decide(lastInputAt: lastInputAt)
    }
}
