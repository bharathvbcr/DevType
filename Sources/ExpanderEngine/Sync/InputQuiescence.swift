// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

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

    public func mark(at eventTime: TimeInterval) {
        lock.lock()
        last = Swift.max(last ?? eventTime, eventTime)
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
