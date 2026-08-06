import Foundation
import os

/// §2.4: Priority-donating mutex for the keystroke hot path.
///
/// `NSLock` does **not** participate in priority inheritance, so the `userInteractive` event-tap
/// callback can end up blocked behind a `utility`-QoS file-watch thread that happens to hold the
/// same lock (e.g. the `snippets` setter running from a store listener). That inversion shows up
/// in the field as `tapDisabledByTimeout` — macOS killing the tap because our callback was slow.
///
/// `os_unfair_lock` does donate priority, but it must never be copied: the lock word has to stay
/// at one stable address for its whole lifetime. Holding it in a Swift `var` inside a class is
/// unsafe (exclusivity enforcement and closure capture are both free to make copies), so the lock
/// state lives in a single manually allocated, never-moved pointer instead.
public final class UnfairLock {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always)
    public func lock() {
        os_unfair_lock_lock(pointer)
    }

    @inline(__always)
    public func unlock() {
        os_unfair_lock_unlock(pointer)
    }

    /// Scoped variant. `os_unfair_lock` is **not** recursive — never call back into code that
    /// takes the same lock from inside `body`.
    @inline(__always)
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}
