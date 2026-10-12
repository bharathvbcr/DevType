import ExpanderEngine
import Foundation

/// Trigger-conflict analysis, computed once per library revision.
///
/// `SnippetStore.triggerConflicts()` re-reads the library and re-runs a quadratic-shaped scan on
/// every call, and one Preferences open reaches it from Home, the Snippets pane and Statistics.
/// The result is a pure function of the library and the detection preference, so it is keyed on
/// the store's `libraryRevision` (read together with the groups, so a save landing in between
/// cannot pair a new revision with an old library) and on the preference. Any save, reload or
/// relocation moves the revision; flipping the preference changes the key.
final class TriggerConflictsCache: @unchecked Sendable {
    static let shared = TriggerConflictsCache()

    private struct Entry {
        weak var store: SnippetStore?
        let revision: UInt64
        let detectionEnabled: Bool
        let conflicts: [SnippetStore.TriggerConflict]
    }

    private let lock = NSLock()
    private var entry: Entry?
    private var _computeCount = 0

    /// How many scans actually ran. A seam for tests that assert reuse.
    var computeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _computeCount
    }

    func conflicts(
        in store: SnippetStore = .shared,
        detectionEnabled: Bool = SnippetStore.isConflictDetectionEnabled
    ) -> [SnippetStore.TriggerConflict] {
        guard detectionEnabled else { return [] }
        let (groups, revision) = store.loadGroupsWithRevision()
        lock.lock()
        if let entry, entry.store === store, entry.revision == revision,
           entry.detectionEnabled == detectionEnabled {
            let cached = entry.conflicts
            lock.unlock()
            return cached
        }
        lock.unlock()

        let computed = SnippetStore.triggerConflicts(in: groups)

        lock.lock()
        entry = Entry(
            store: store,
            revision: revision,
            detectionEnabled: detectionEnabled,
            conflicts: computed
        )
        _computeCount += 1
        lock.unlock()
        return computed
    }
}
