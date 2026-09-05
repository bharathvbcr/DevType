import Foundation

/// Answers "which triggers strictly extend this one?" without comparing every trigger
/// against every other trigger.
///
/// Two places needed that question and both answered it with a nested loop over the whole
/// library: `TriggerPrefixIndex`'s ambiguity pass (is this trigger a strict prefix of any
/// other?) and `SnippetStore.triggerConflicts(in:)`'s prefix-shadow pass (which triggers
/// does this one shadow?). The second folded its candidate with `lowercased()` *inside* the
/// inner loop, so a 1,000-trigger library performed a million string allocations — on the
/// main thread, on every keystroke in the manager's search field while the Conflicts chip
/// was active, and again on every library-health check.
///
/// Measured before this type existed, at 2,000 triggers: 118 ms for the ambiguity pass and
/// 180 ms for the prefix-shadow pass. Both are now sub-millisecond.
///
/// The mechanism is a property of lexicographic order: the strings carrying a given prefix
/// occupy one contiguous run, and that run begins immediately after the run of strings equal
/// to the prefix itself. So sorting the folded keys once turns each query into a short
/// forward walk whose length is the number of answers, rather than the size of the library.
///
/// Keys are supplied already folded — the caller owns the folding rule (the matcher keys
/// case-sensitive triggers verbatim and case-insensitive ones lowercased), and folding once
/// up front is the other half of the fix.
public struct TriggerPrefixScan {

    /// Folded keys in ascending order.
    private let sortedKeys: [String]
    /// `sortedKeys[i]` came from the caller's element at `callerIndex[i]`.
    private let callerIndex: [Int]
    /// Caller index -> its position in `sortedKeys`.
    private let position: [Int]
    /// For each position, the position just past the last key equal to it. Equal keys share
    /// a value, so a library of identical triggers answers in constant time per query rather
    /// than walking its own duplicates.
    private let runEnd: [Int]

    public init(foldedKeys: [String]) {
        let count = foldedKeys.count
        let order = (0..<count).sorted { lhs, rhs in
            let l = foldedKeys[lhs], r = foldedKeys[rhs]
            // Ties broken by caller index so the layout is deterministic across runs.
            return l == r ? lhs < rhs : l < r
        }
        var sorted: [String] = []
        sorted.reserveCapacity(count)
        for index in order { sorted.append(foldedKeys[index]) }

        var positions = [Int](repeating: 0, count: count)
        for (slot, index) in order.enumerated() { positions[index] = slot }

        // One backward pass labels every member of a run of equal keys with the run's end.
        var ends = [Int](repeating: count, count: count)
        var slot = count - 1
        while slot >= 0 {
            var start = slot
            while start > 0 && sorted[start - 1] == sorted[slot] { start -= 1 }
            let end = slot + 1
            for member in start...slot { ends[member] = end }
            slot = start - 1
        }

        self.sortedKeys = sorted
        self.callerIndex = order
        self.position = positions
        self.runEnd = ends
    }

    /// True when at least one key strictly extends the key at `index`.
    ///
    /// Constant time: the first candidate that could extend it sits at the end of its own
    /// run of equal keys, and if *that* one does not carry the prefix, nothing after it can.
    public func hasStrictExtension(of index: Int) -> Bool {
        guard position.indices.contains(index) else { return false }
        let slot = position[index]
        let next = runEnd[slot]
        guard next < sortedKeys.count else { return false }
        return sortedKeys[next].hasPrefix(sortedKeys[slot])
    }

    /// Visits the caller index of every key that *strictly* extends the key at `index`,
    /// in ascending key order. Keys equal to it are not extensions and are never visited.
    public func forEachStrictExtension(of index: Int, _ visit: (Int) -> Void) {
        guard position.indices.contains(index) else { return }
        let slot = position[index]
        let key = sortedKeys[slot]
        var cursor = runEnd[slot]
        while cursor < sortedKeys.count, sortedKeys[cursor].hasPrefix(key) {
            visit(callerIndex[cursor])
            cursor += 1
        }
    }
}
