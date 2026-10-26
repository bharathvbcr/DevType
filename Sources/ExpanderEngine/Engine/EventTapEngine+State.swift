import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Snippet snapshot, cached context and flag accessors.
extension EventTapEngine {
    /// §2.1: the setter is the **only** place the matcher is built. The tap callback used to
    /// reconstruct `AbbreviationMatcher(snippets:)` on every keystroke — at 1000 snippets that is
    /// ~2000 dictionary inserts + ~1000 string allocations per typed character, inside a
    /// CGEventTap callback macOS disables when it runs long.
    public var snippets: [SnippetModel] {
        get {
            matchStateLock.lock()
            defer { matchStateLock.unlock() }
            return _matchSnapshot.snippets
        }
        set {
            matchStateLock.lock()
            let revision = _snapshotRevision &+ 1
            _snapshotRevision = revision
            matchStateLock.unlock()

            // Secrets are filtered out here, at the one door into the matcher, rather than at the
            // callers. A keychain-backed snippet must never be reachable by typing: Secure Input
            // means the trigger cannot be seen where it would be wanted, and everywhere else a
            // trigger that fires on typing would put a password into the chat window the user was
            // mid-sentence in. Filtering in the setter means no future caller can reintroduce it,
            // and the value is not in the struct to leak even if one tried.
            let matchable = newValue.filter(\.isTypedTriggerExpandable)

            // Build outside the lock: a rebuild can take milliseconds at large libraries and the
            // tap callback reads this lock on the keystroke path.
            let snapshot = SnippetMatchSnapshot(snippets: matchable, revision: revision)

            // Kept **unfiltered** for `silentNoExpandDiagnostics()` only. The matcher must never
            // see it: the whole point of the filter above is that a secret is not reachable from
            // the keystroke path. This copy carries triggers, and a secret's `replacementText` is
            // empty by construction (`SnippetModel.init`), so no value is retained here.
            libraryLock.lock()
            _fullLibrary = newValue.map { snippet in
                var stripped = snippet
                stripped.replacementText = snippet.isSecret ? "" : snippet.replacementText
                return stripped
            }
            libraryLock.unlock()

            matchStateLock.lock()
            // Last writer wins; a slower build must never clobber a newer one.
            if snapshot.revision >= _matchSnapshot.revision {
                _matchSnapshot = snapshot
            }
            matchStateLock.unlock()

            logOverlongTriggers(in: snapshot)
        }
    }

    /// Thread that last ran `applySnippetSnapshot`'s build. Direct `snippets` assignment
    /// does not update this; tests that assign the setter stay synchronous on purpose.
    public var lastSnippetSnapshotBuiltOnMain: Bool {
        matchStateLock.lock()
        defer { matchStateLock.unlock() }
        return _lastSnippetSnapshotBuiltOnMain
    }

    /// Rebuilds the matcher. A main-thread caller (the library listener during a UI save)
    /// queues the build so the snapshot is not constructed on the main thread. A caller
    /// that is already off main runs inline and may wait. The setter stays synchronous.
    public func applySnippetSnapshot(_ snippets: [SnippetModel], completion: (() -> Void)? = nil) {
        let build = { [weak self] in
            guard let self else {
                completion?()
                return
            }
            self.matchStateLock.lock()
            self._lastSnippetSnapshotBuiltOnMain = Thread.isMainThread
            self.matchStateLock.unlock()
            self.snippets = snippets
            completion?()
        }
        if Thread.isMainThread {
            snapshotQueue.async(execute: build)
        } else {
            build()
        }
    }

    /// §2.1: current immutable `(snippets, matcher)` pair. Cheap — one reference copy.
    public var matchSnapshot: SnippetMatchSnapshot {
        matchStateLock.lock()
        defer { matchStateLock.unlock() }
        return _matchSnapshot
    }

    /// §2.3: last known frontmost app context (bundle ID, PID, mute + terminal verdicts).
    /// Updated from the `didActivateApplication` observer, never read from AppKit on the tap thread.
    public var frontmostContext: FrontmostContext {
        contextLock.lock()
        defer { contextLock.unlock() }
        return _frontmostContext
    }

    public var cachedFrontmostBundleID: String? {
        contextLock.lock()
        defer { contextLock.unlock() }
        return _frontmostContext.bundleID
    }

    /// User pause flag. When false, matching is skipped but the tap may still be installed.
    /// Persisted across launches so a deliberate pause survives relaunch / rebuild.
    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isEnabled
        }
        set {
            lock.lock()
            _isEnabled = newValue
            lock.unlock()
            if !newValue {
                // Pausing must silence everything already in motion, not just future matches: a
                // hold armed moments ago still has a live debounce timer, and firing it would
                // expand text while the user believes DevType is off.
                heldCoordinator.cancelAll(reason: .unobservedInput)
                pipeline.cancelCurrentInjection()
            }
            UserDefaults.standard.set(!newValue, forKey: ProcessIdentity.userPausedDefaultsKey)
        }
    }

    /// Whether a CGEvent tap is currently installed (independent of user pause).
    public var isTapRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isTapRunning
    }

    /// Whether `start()` has been called at all in this process.
    ///
    /// The window between the status item appearing and `PermissionCoordinator.start()`
    /// installing the tap is real — roughly 50ms at launch — and during it the tap is not
    /// running for the most ordinary reason there is: nobody has asked it to yet. Any status
    /// refresh landing in that window rendered Tap Failed, because "not running" was the only
    /// thing the display could see. Startup order alone cannot fix that; one more early
    /// refresh puts the flash straight back, which is why `setupStatusItem` carries a comment
    /// telling the next reader not to add one.
    public var hasAttemptedTapStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _hasAttemptedTapStart
    }

    /// True while an expansion inject + clipboard restore is in flight; matching is suppressed.
    public var isExpanding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isExpanding
    }

    /// When true, the tap still runs but abbreviation matching is skipped (fill-in panels, inline search).
    /// True while the suspend reference count is greater than zero.
    public var matchingSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _matchingSuspendCount > 0
    }

    /// Increment the matching-suspend reference count. Nested callers must pair with `resumeMatching()`.
    ///
    /// Prefer `suspendMatching(reason:)`, which returns an owned token. This bare pair is the
    /// primitive underneath it: balancing it correctly is the caller's problem, and every
    /// historical way of getting that wrong stops the app expanding anything at all.
    public func suspendMatching() {
        // Deliberately does **not** go through `suspendMatching(reason:)`: that returns an owned
        // token, and a discarded token deallocates immediately and releases itself, so the
        // suspension would end on the same line it began.
        performSuspend(id: nil, reason: "unattributed")
    }

    /// Decrement the matching-suspend reference count (clamped at zero). Matching resumes only when count hits 0.
    ///
    /// Clamping at zero is a safety net, not a licence: a spurious resume with another owner's
    /// suspension live *steals* it, and matching restarts under a panel that is still collecting
    /// keystrokes. `MatchingSuspension` exists so neither mistake is expressible.
    public func resumeMatching() {
        releaseSuspension(id: nil)
    }
}
