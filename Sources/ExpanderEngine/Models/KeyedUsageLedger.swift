import Foundation

/// In-memory usage map shared by the snippet and command sidecars.
///
/// Both stores key a counter by a `Hashable` id, debounce the same dirty flag,
/// and answer `stat` / `reset` / `totalUsage` the same way. Hourly buckets and
/// palette rank boosts stay on the stores: those are different questions, and
/// this type does not grow a flag to choose between them.
final class KeyedUsageLedger<Key: Hashable, Stat> {
    private let lock = NSLock()
    private var stats: [Key: Stat]
    private var dirty: Bool
    private var revision: UInt64 = 0

    init(stats: [Key: Stat], dirty: Bool = false) {
        self.stats = stats
        self.dirty = dirty
    }

    var currentRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    func stat(for key: Key) -> Stat? {
        lock.lock()
        defer { lock.unlock() }
        return stats[key]
    }

    func allStats() -> [Key: Stat] {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    func totalUsage(_ count: (Stat) -> Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stats.values.reduce(0) { $0 + count($1) }
    }

    /// Applies `body` under the lock. A `true` result marks the map dirty and
    /// bumps the revision; `false` leaves both alone (a seed that found nothing new).
    @discardableResult
    func update(_ body: (inout [Key: Stat]) -> Bool) -> Bool {
        lock.lock()
        let changed = body(&stats)
        if changed {
            dirty = true
            revision &+= 1
        }
        lock.unlock()
        return changed
    }

    func reset(for key: Key) {
        lock.lock()
        if stats.removeValue(forKey: key) != nil {
            dirty = true
            revision &+= 1
        }
        lock.unlock()
    }

    func resetAll() {
        lock.lock()
        stats.removeAll()
        dirty = true
        revision &+= 1
        lock.unlock()
    }

    /// Hands the caller the dirty map and clears the flag, or `nil` when a
    /// flush would write nothing. `rearm` puts the flag back after a failed write.
    func takeDirtySnapshot() -> [Key: Stat]? {
        lock.lock()
        guard dirty else {
            lock.unlock()
            return nil
        }
        let snapshot = stats
        dirty = false
        lock.unlock()
        return snapshot
    }

    func rearm() {
        lock.lock()
        dirty = true
        lock.unlock()
    }
}
