import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Owned matching suspension and orphan recovery.
extension EventTapEngine {
    // MARK: - Owned matching suspension

    /// A single owner's claim on "matching is suspended".
    ///
    /// The bare `suspendMatching()` / `resumeMatching()` pair is a global reference count with no
    /// record of *who* holds it, and both ways of unbalancing it are silent catastrophes:
    ///
    ///   * **one suspend too many** — a panel opened twice (its `isOpen` check reads
    ///     `panel?.isVisible`, which is already false while the panel animates out) leaves the
    ///     count pinned above zero. The tap keeps running, the engine stays enabled, permissions
    ///     stay granted, and no snippet ever expands again until relaunch. Nothing in the
    ///     diagnostic report said so.
    ///   * **one resume too many** — a `close()` that runs without a matching `open()` decrements
    ///     *someone else's* suspension, so matching restarts while a fill-in panel is still
    ///     collecting keystrokes and the user's typing starts triggering expansions into it.
    ///
    /// Ownership makes both unrepresentable. `release()` is idempotent, so a double close is a
    /// no-op, and `deinit` releases, so a token dropped on the floor — the double-open case, where
    /// the second `open()` overwrites the first token — cannot leak either.
    public final class MatchingSuspension {
        private let id: UUID
        private weak var engine: EventTapEngine?
        private let releaseLock = UnfairLock()
        private var isReleased = false

        fileprivate init(id: UUID, engine: EventTapEngine) {
            self.id = id
            self.engine = engine
        }

        /// Idempotent: only the first call releases the underlying suspension.
        public func release() {
            releaseLock.lock()
            let alreadyReleased = isReleased
            isReleased = true
            releaseLock.unlock()
            guard !alreadyReleased else { return }
            engine?.releaseSuspension(id: id)
        }

        deinit {
            release()
        }
    }

    /// Suspends matching until the returned token is released or deallocated.
    ///
    /// `reason` is carried into the diagnostic report so a suspension that outlives its panel can
    /// be identified by name rather than inferred from the absence of expansions.
    public func suspendMatching(reason: String) -> MatchingSuspension {
        let id = UUID()
        performSuspend(id: id, reason: reason)
        return MatchingSuspension(id: id, engine: self)
    }

    func performSuspend(id: UUID?, reason: String) {
        lock.lock()
        _matchingSuspendCount += 1
        _matchingSuspendOwners.append((id: id, reason: reason, since: Date()))
        let depth = _matchingSuspendCount
        lock.unlock()
        let safeReason = DevTypeLog.boundedPublicIdentifier(reason, label: "suspensionReason")
        DevTypeLog.eventTap.debug(
            "[EventTap] matching suspended by \(safeReason, privacy: .public) depth=\(depth, privacy: .public)"
        )
        // From this instant keystrokes bypass matching (fill-in panel, inline search), so a live
        // hold can no longer observe the field it would erase — and its debounce timer would
        // fire *into the panel's text view*. Drop it before the first bypassed key.
        heldCoordinator.cancelAll(reason: .unobservedInput)
    }

    /// Releases one suspension.
    ///
    /// A token releases **its own** claim: an `id` with no live owner is a no-op rather than a
    /// decrement, so a second close, or a close racing the token's `deinit`, cannot consume a
    /// suspension that belongs to a different panel. `id == nil` is the legacy unowned
    /// `resumeMatching()` path and can only drop the most recent owner.
    func releaseSuspension(id: UUID?) {
        lock.lock()
        let index: Int?
        if let id {
            index = _matchingSuspendOwners.lastIndex { $0.id == id }
        } else {
            // Legacy `resumeMatching()` releases the newest *unowned* suspension. Falling back to
            // "the newest of any kind" would let an unbalanced legacy caller consume a panel's
            // token, which is the theft this type exists to prevent.
            index = _matchingSuspendOwners.lastIndex { $0.id == nil }
        }
        guard let index else {
            // Nothing of ours to release. Legacy callers with no owners at all still fall through
            // to the clamp below so the old contract (resume is always safe) is preserved.
            let hadOwners = !_matchingSuspendOwners.isEmpty
            if id == nil, !hadOwners {
                _matchingSuspendCount = max(0, _matchingSuspendCount - 1)
            }
            lock.unlock()
            return
        }
        _matchingSuspendOwners.remove(at: index)
        _matchingSuspendCount = max(0, _matchingSuspendCount - 1)
        let depth = _matchingSuspendCount
        lock.unlock()
        DevTypeLog.eventTap.debug(
            "[EventTap] matching suspension released depth=\(depth, privacy: .public)"
        )
    }

    /// Live suspension owners and how long each has held. Empty when matching is running.
    public func matchingSuspensionOwners() -> [(reason: String, seconds: TimeInterval)] {
        let now = Date()
        lock.lock()
        let owners = _matchingSuspendOwners
        lock.unlock()
        return owners.map { (reason: $0.reason, seconds: now.timeIntervalSince($0.since)) }
    }

    /// Report line. **Matching suspended is a total expansion outage**, so it must never be
    /// summarized as anything softer, and it must appear whether or not anything else is wrong.
    public func matchingSuspensionDiagnostics() -> [String] {
        matchingSuspensionDiagnosticProjection(
            itemLimit: Int.max,
            byteLimit: Int.max
        ).retainedLines
    }

    /// Report path for live suspension owners. The owner list is operational state and cannot be
    /// capped without weakening release semantics, so diagnostics count it under the engine lock
    /// while retaining only a bounded projection. A leaked panel storm can no longer duplicate the
    /// entire owner list into a support report.
    func matchingSuspensionDiagnosticProjection(
        itemLimit: Int = DiagnosticReport.headerProjectionItemLimit,
        byteLimit: Int = DiagnosticReport.headerProjectionByteLimit
    ) -> DiagnosticReport.HeaderProjection {
        let now = Date()
        var builder = DiagnosticReport.HeaderProjectionBuilder(
            itemLimit: itemLimit,
            byteLimit: byteLimit
        )
        lock.lock()
        if _matchingSuspendOwners.isEmpty {
            builder.observe("Matching: running (not suspended)")
        } else {
            builder.observe("Matching: SUSPENDED — typed triggers cannot expand while this is true")
            for owner in _matchingSuspendOwners {
                let safeReason = DiagnosticPrivacy.boundedIdentifier(
                    owner.reason,
                    label: "suspensionOwner",
                    domain: "matching-suspension-owner"
                )
                builder.observe(
                    "  held by \(safeReason) for \(Int(max(0, now.timeIntervalSince(owner.since))))s"
                )
            }
        }
        lock.unlock()
        return builder.finish()
    }

    /// Whether DevType itself owns the frontmost app — i.e. one of our panels could legitimately
    /// be holding a suspension. Reads the cached frontmost context, never AppKit, so it is safe
    /// from the tap thread's health timer.
    func isDevTypeFrontmost() -> Bool {
        cachedFrontmostBundleID == ProcessIdentity.shared.bundleIdentifier
    }

    /// A suspension older than this with DevType in the background is orphaned, not in use.
    ///
    /// Every legitimate owner is a DevType panel that has keyboard focus (fill-in, inline search,
    /// AI action / preview). If DevType is not frontmost, no such panel is collecting keystrokes,
    /// so a suspension still standing after this long is a leak — and leaving it in place means
    /// the user types triggers into other apps forever with nothing happening.
    public static let orphanedSuspensionTimeout: TimeInterval = 30.0

    /// Force-clears suspensions that cannot belong to a live panel. Returns how many were cleared.
    ///
    /// Deliberately conditional on DevType not being frontmost: that is the one check that
    /// distinguishes "a panel is open and the user is typing into it" (must keep suspending) from
    /// "a panel closed without releasing" (must recover). Recovering on a timer alone would resume
    /// matching under a fill-in panel someone is still filling in.
    @discardableResult
    public func recoverOrphanedSuspensions(isDevTypeFrontmost: Bool, now: Date = Date()) -> Int {
        guard !isDevTypeFrontmost else { return 0 }
        lock.lock()
        let stale = _matchingSuspendOwners.filter {
            now.timeIntervalSince($0.since) >= Self.orphanedSuspensionTimeout
        }
        guard !stale.isEmpty else {
            lock.unlock()
            return 0
        }
        _matchingSuspendOwners.removeAll {
            now.timeIntervalSince($0.since) >= Self.orphanedSuspensionTimeout
        }
        _matchingSuspendCount = max(0, _matchingSuspendCount - stale.count)
        let depth = _matchingSuspendCount
        lock.unlock()
        for owner in stale {
            let safeReason = DevTypeLog.boundedPublicIdentifier(
                owner.reason,
                label: "suspensionReason"
            )
            DevTypeLog.eventTap.error(
                """
                [EventTap] orphaned matching suspension recovered — \
                \(safeReason, privacy: .public) held matching for \
                \(Int(now.timeIntervalSince(owner.since)), privacy: .public)s with DevType in the \
                background. Every typed trigger was silently ignored for that whole period.
                """
            )
        }
        matchDropLock.lock()
        _matchDrops.orphanedSuspensionsRecovered += stale.count
        matchDropLock.unlock()
        DevTypeLog.eventTap.notice(
            "[EventTap] matching resumed after orphan recovery depth=\(depth, privacy: .public)"
        )
        return stale.count
    }
}
