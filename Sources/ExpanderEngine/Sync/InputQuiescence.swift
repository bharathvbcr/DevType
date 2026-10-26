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

    /// Boot-relative nanoseconds → seconds.
    public static func seconds(sinceBootNanos nanos: UInt64) -> TimeInterval {
        Double(nanos) / 1_000_000_000
    }

    /// How a real event's `CGEvent.timestamp` counts on this machine.
    public enum EventTimestampUnit: Equatable, Sendable {
        case uptimeNanoseconds
        case machTicks
    }

    /// The unit this process's events were found to use; decided once, from the first real event.
    private var eventUnit: EventTimestampUnit?

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Which clock `raw` was read from: whichever of `mach_absolute_time()` and uptime nanoseconds,
    /// sampled now, it lies nearer. An event is a few milliseconds old when the tap sees it; on
    /// Apple silicon the two clocks differ by a factor of 125/3, so the answer is never close.
    public static func decideEventTimestampUnit(
        raw: UInt64, machNow: UInt64, uptimeNanosNow: UInt64
    ) -> EventTimestampUnit {
        let toTicks = raw > machNow ? raw - machNow : machNow - raw
        let toNanos = raw > uptimeNanosNow ? raw - uptimeNanosNow : uptimeNanosNow - raw
        return toTicks < toNanos ? .machTicks : .uptimeNanoseconds
    }

    public static func nanoseconds(
        fromEventTimestamp raw: UInt64,
        unit: EventTimestampUnit,
        timebase: (numer: UInt64, denom: UInt64)
    ) -> UInt64 {
        switch unit {
        case .uptimeNanoseconds:
            return raw
        case .machTicks:
            guard timebase.denom > 0 else { return raw }
            return UInt64(Double(raw) * Double(timebase.numer) / Double(timebase.denom))
        }
    }

    /// Seconds since boot for a real event's `CGEvent.timestamp`, on the clock `arm()` reads.
    ///
    /// The SDK calls the timestamp "roughly nanoseconds since startup". A real tap on Apple silicon
    /// delivers mach ticks (field log, DevType 1.3.0 build 438: `ratio=0.0240`, i.e. 3/125), so
    /// treating it as nanoseconds put every mark ~41× earlier than any `arm()` and the
    /// deferred-expand quiescence guard could never abort. Rather than assume either unit — a
    /// wrong assumption the other way would put every key in the future and abort every
    /// expansion — the unit is measured on the first real event, logged once, and used from then
    /// on. A constructed event's 0 is passed through as 0 without deciding anything.
    public func seconds(
        fromEventTimestamp raw: UInt64,
        machNow: () -> UInt64 = { mach_absolute_time() },
        uptimeNanosNow: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> TimeInterval {
        guard raw > 0 else { return 0 }
        lock.lock()
        let decided = eventUnit
        lock.unlock()
        let unit: EventTimestampUnit
        if let decided {
            unit = decided
        } else {
            let nanosNow = uptimeNanosNow()
            let measured = Self.decideEventTimestampUnit(raw: raw, machNow: machNow(), uptimeNanosNow: nanosNow)
            lock.lock()
            let first = eventUnit == nil
            if first { eventUnit = measured }
            unit = eventUnit ?? measured
            lock.unlock()
            if first, nanosNow > 0 {
                let converted = Self.nanoseconds(fromEventTimestamp: raw, unit: unit, timebase: Self.timebase)
                DevTypeLog.debounce.notice(
                    "[Debounce] event timestamp units ratio=\(Double(raw) / Double(nanosNow), format: .fixed(precision: 4), privacy: .public) unit=\(unit == .machTicks ? "machTicks" : "nanoseconds", privacy: .public) converted=\(Double(converted) / Double(nanosNow), format: .fixed(precision: 4), privacy: .public)"
                )
            }
        }
        return Self.seconds(
            sinceBootNanos: Self.nanoseconds(fromEventTimestamp: raw, unit: unit, timebase: Self.timebase)
        )
    }

    /// The unit decided so far, for the diagnostic report and tests; nil before the first real event.
    public var eventTimestampUnit: EventTimestampUnit? {
        lock.lock()
        defer { lock.unlock() }
        return eventUnit
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
