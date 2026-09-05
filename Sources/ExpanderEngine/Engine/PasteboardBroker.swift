import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// §8.1 / §1.7: the whole clipboard snapshot → paste → restore invariant, in one place.
///
/// The invariant this type exists to protect: **the user's clipboard must survive an expansion.**
/// That is harder than it looks, because the payload has to stay on the pasteboard long enough for
/// the target app to read it, which means restore is always deferred, which means two expansions
/// can overlap. Before §1.7 the second expansion snapshotted the *first* expansion's payload as
/// "the user's clipboard" and later restored it — so a back-to-back expand could leave a previous
/// snippet, including the concealed secure-clipboard password payload, on the clipboard forever.
///
/// Ownership is therefore explicit: a `ClipboardTicket` records what we replaced and the
/// generation token that decides whether our restore is still the current one, and a new expansion
/// *inherits* the pending ticket's contents when it finds its own payload still on the board.
public final class PasteboardBroker {
    public static let shared = PasteboardBroker()

    // MARK: - Types

    /// Outcome of one clipboard paste after optional operation-specific AX verification.
    public enum PasteDeliveryResult: Equatable {
        /// Cmd+V could not be posted (Post Events denied / CGEvent create failed).
        case notPosted
        /// AX confirmed the expected text landed.
        case delivered
        /// Legacy input retained for compatibility; current delivery treats readable misses as unavailable.
        case failed
        /// Cmd+V was posted but AX cannot confirm (normal for Chrome / Electron / many terminals).
        case unavailable
    }

    /// Pure policy for the post-Cmd+V clipboard-hold loop (unit-tested without AppKit paste).
    public enum PasteHoldDecision: Equatable {
        case succeed
        case failConfirmed
        case retryPaste
        case waitMore
        case giveUpUnverified
    }

    public typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    /// Exact result of a deliberate user clipboard write. The public UI contract is the
    /// `didWrite` boolean; the richer internal result keeps tests and diagnostics from collapsing
    /// "write failed but the old board was recovered" into either success or silent data loss.
    enum UserClipboardWriteOutcome: Equatable {
        case written
        case writeFailedPriorRestored
        case writeFailedNoPriorSnapshot
        case writeFailedRestoreFailed
        case ownershipLost

        var didWrite: Bool { self == .written }

        fileprivate var diagnosticLabel: String {
            switch self {
            case .written: return "written"
            case .writeFailedPriorRestored: return "writeFailedPriorRestored"
            case .writeFailedNoPriorSnapshot: return "writeFailedNoPriorSnapshot"
            case .writeFailedRestoreFailed: return "writeFailedRestoreFailed"
            case .ownershipLost: return "ownershipLost"
            }
        }
    }

    enum UserClipboardRestoreOutcome: Equatable {
        case restored
        case ownershipLost
        case failed
    }

    /// Fault-injectable boundary around AppKit's boolean-returning pasteboard writes. Production
    /// supplies closures over `NSPasteboard.general`; tests can force each refusal and ownership
    /// race without touching the user's real clipboard.
    struct UserClipboardWriteOperations {
        let clearContents: () -> Int
        let currentChangeCount: () -> Int
        let setString: (String) -> Bool
        let restoreSnapshot: (PasteboardSnapshot, Int) -> UserClipboardRestoreOutcome
    }

    enum ClipboardPublicationOutcome: Equatable {
        case published(ownedChangeCount: Int)
        case writeFailed(ownedChangeCount: Int)
        case ownershipLost
        case notPrepared
    }

    /// The original clear count is the only ownership authority. Steps contain already
    /// prepared representations; every write and every continuation is checked. This lock
    /// serializes our publishers, not external processes, which remain inherently concurrent.
    private static let publicationLock = NSLock()

    static func publishClipboard(
        clearContents: () -> Int,
        currentChangeCount: () -> Int,
        writes: [() -> Bool],
        expectedChangeCount: Int? = nil
    ) -> ClipboardPublicationOutcome {
        guard !writes.isEmpty, writes.count <= 16 else { return .notPrepared }
        publicationLock.lock()
        defer { publicationLock.unlock() }
        if let expectedChangeCount, currentChangeCount() != expectedChangeCount {
            return .ownershipLost
        }
        let owned = clearContents()
        for write in writes {
            guard currentChangeCount() == owned else { return .ownershipLost }
            let wrote = write()
            guard currentChangeCount() == owned else { return .ownershipLost }
            guard wrote else { return .writeFailed(ownedChangeCount: owned) }
        }
        return .published(ownedChangeCount: owned)
    }

    /// nspasteboard.org markers: tell clipboard managers not to record our payload.
    public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    /// §1.7: `oldItems` used to eagerly materialise **every** representation of **every** item on
    /// the main thread. A 20-image clipboard is tens of megabytes of copying on the keystroke path,
    /// and a lazily-provided item (a file promise, a Photos drag) is either paid for in full or
    /// silently lost. Bounded instead, with the tradeoff stated explicitly: we restore the first
    /// `snapshotMaxItems` items up to `snapshotMaxBytes`, and we do **not** attempt to preserve
    /// promised-file representations at all — forcing a promise here can block main indefinitely.
    /// Anything skipped is logged, so a user who loses a promise sees why.
    public static let snapshotMaxItems = 8
    public static let snapshotMaxBytes = 4 * 1024 * 1024
    public static let snapshotSkippedTypes: Set<String> = [
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-suggested-file-name",
        "com.apple.pasteboard.PasteboardName",
        "NSPromiseContentsPboardType"
    ]

    /// One expansion's ownership of the pasteboard.
    struct ClipboardTicket {
        let pasteboard: NSPasteboard
        let oldItems: PasteboardSnapshot?
        let generation: UInt64
        /// The `changeCount` we produced. Anything else means someone else wrote the board.
        var targetChangeCount: Int
    }

    /// §8.12: everything the release decision needs, captured at the moment ⌘V was posted.
    ///
    /// Residency is a property of the *keystroke*, not of whichever code path happens to finish
    /// first, so the deadline is absolute. The previous `deferBy:` delay was measured from wherever
    /// the caller stood: an outcome reached in 0 ms and one reached in 300 ms both waited the same
    /// extra interval, so the actual time the bytes spent on the board was never a stated number.
    struct PayloadResidency {
        /// When ⌘V finished posting.
        let postedAt: TimeInterval
        /// Minimum time on the board when nothing proves the host read it.
        let unverifiedHold: TimeInterval
        /// Hard cap including stall extensions. Never below `unverifiedHold`.
        let ceiling: TimeInterval
        /// Process the ⌘V was aimed at, for the stall probe. `nil` disables the probe.
        let targetPID: pid_t?
        /// Whether that process was answering AX when we posted. Without a positive baseline a
        /// silent app is just an app that never speaks AX, not a stalled one, and extending on
        /// that would hold every expansion in an AX-dead host to the ceiling.
        let hostRespondedAtPaste: Bool
        let bundleID: String?

        var hardDeadline: TimeInterval { postedAt + max(ceiling, unverifiedHold) }

    }

    // MARK: - State

    private let hid: HIDKeyPoster
    private let verifier: DeliveryVerifier
    private let timing: InjectTimingStore
    private let now: () -> TimeInterval

    /// §2.4: `os_unfair_lock` rather than `NSLock` — taken from the inject path.
    private let restoreLock = UnfairLock()
    private var restoreGeneration: UInt64 = 0
    private var pendingTicket: ClipboardTicket?

    public init(
        hid: HIDKeyPoster = HIDKeyPoster.shared,
        verifier: DeliveryVerifier = DeliveryVerifier.shared,
        timing: InjectTimingStore = InjectTimingStore.shared,
        now: @escaping () -> TimeInterval = InputClock.monotonicNow
    ) {
        self.hid = hid
        self.verifier = verifier
        self.timing = timing
        self.now = now
    }

    // MARK: - Generation tokens

    /// Next restore generation token. Pure helper for tests; production uses `beginRestoreGeneration()`.
    public static func nextRestoreGeneration(current: UInt64) -> UInt64 {
        current &+ 1
    }

    @discardableResult
    public func beginRestoreGeneration() -> UInt64 {
        restoreLock.lock()
        restoreGeneration = PasteboardBroker.nextRestoreGeneration(current: restoreGeneration)
        let token = restoreGeneration
        restoreLock.unlock()
        return token
    }

    /// Abandon scheduled restoration and paste work when a deliberate copy supersedes it.
    /// Clipboard handling markers are shared conventions and never establish ownership.
    public func invalidatePendingRestore() {
        _ = beginRestoreGeneration()
        restoreLock.lock()
        pendingTicket = nil
        restoreLock.unlock()
    }

    /// Pure policy: may the contents currently on the board be adopted as "the user's clipboard"
    /// and restored after an expansion?
    ///
    /// Not when they are concealed. A concealed payload is either a secret the user copied or a
    /// leftover of ours; restoring either one later would put a password back on the pasteboard
    /// *after* `SecretClipboard` cleared it, with nothing left to clear it again.
    public static func mayAdoptAsUserClipboard(types: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let types else { return true }
        return !types.contains(concealedType)
    }

    public func currentRestoreGeneration() -> UInt64 {
        restoreLock.lock()
        defer { restoreLock.unlock() }
        return restoreGeneration
    }

    // MARK: - Delays

    /// Blind size-only restore delay — the pre-§3.4 behaviour, kept for callers (and tests) that
    /// ask for the delay without an app to adapt to.
    public func calculateRestoreDelay(payloadBytes: Int) -> TimeInterval {
        InjectTimingStore.blindRestoreDelay(payloadBytes: payloadBytes)
    }

    /// §3.4: adaptive when we have measured this app, identical to `calculateRestoreDelay` when not.
    public func restoreDelay(bundleID: String?, payloadBytes: Int) -> TimeInterval {
        timing.restoreDelay(bundleID: bundleID, payloadBytes: payloadBytes)
    }

    public func calculateImageRestoreDelay(payloadBytes: Int) -> TimeInterval {
        InjectTimingStore.imageRestoreDelay(payloadBytes: payloadBytes)
    }

    // MARK: - Hold policy

    /// Historical counts and host trust are not proof that this asynchronous paste
    /// cannot still arrive. Keep this public adapter for existing clients; its former
    /// retry arguments cannot authorize a corrective write.
    public static let requiredFailureConfirmations = 2

    public static func decidePasteHold(
        delivery: DeliveryVerifier.TextDeliveryVerification,
        pasteAttemptsCompleted: Int,
        maxAttempts: Int = InjectTiming.pasteDeliveryMaxAttempts,
        elapsed: TimeInterval,
        holdTimeout: TimeInterval = InjectTiming.pasteDeliveryHoldTimeout,
        consecutiveFailures: Int = .max,
        trustFailureVerdict: Bool = true
    ) -> PasteHoldDecision {
        decidePasteHold(delivery: delivery, elapsed: elapsed, holdTimeout: holdTimeout)
    }

    public static func decidePasteHold(
        delivery: DeliveryVerifier.TextDeliveryVerification,
        elapsed: TimeInterval,
        holdTimeout: TimeInterval = InjectTiming.pasteDeliveryHoldTimeout
    ) -> PasteHoldDecision {
        if delivery == .delivered { return .succeed }
        return elapsed < holdTimeout ? .waitMore : .giveUpUnverified
    }

    // MARK: - Payload residency policy (§8.12)

    /// How much longer our payload must stay on the pasteboard, given how the paste ended.
    ///
    /// The question this answers is **not** "did the text arrive" but "has the host read the
    /// bytes yet" — and only one outcome answers it:
    ///
    /// - `.delivered`: AX found the text in the field, so the host demonstrably read the board.
    ///   Restore immediately; the user gets their clipboard back as fast as ever.
    /// - `.notPosted`: no ⌘V exists, so there is nothing to be consumed. Restore immediately.
    /// - `.unavailable`: ⌘V went out and AX could tell us nothing. This is the Electron/Chromium
    ///   case, the majority of real pastes, and it is *zero* evidence — hold for the full residency.
    /// - `.failed`: AX is readable and the text is absent. That is evidence about the *field*, not
    ///   about the pasteboard: a host that has not yet dequeued the keystroke reads exactly the
    ///   same. Hold.
    ///
    /// Returns 0 rather than a negative interval when the residency has already elapsed — by the
    /// time a slow verification ladder finishes, it usually has.
    public static func remainingPayloadResidency(
        result: PasteDeliveryResult,
        elapsedSincePaste: TimeInterval,
        unverifiedHold: TimeInterval
    ) -> TimeInterval {
        switch result {
        case .delivered, .notPosted:
            return 0
        case .failed, .unavailable:
            return max(0, unverifiedHold - max(0, elapsedSincePaste))
        }
    }

    /// May an unverified paste keep the payload *past* its residency because the target app has
    /// stopped answering AX?
    ///
    /// A frozen host is the failure mode a fixed residency cannot cover: our ⌘V sits in its event
    /// queue for as long as its main thread is busy, and no timer chosen in advance is long enough.
    /// An app that is not servicing AX is not servicing its event queue either, so "still stalled"
    /// is a live reason to believe the keystroke has not been consumed.
    ///
    /// Three conditions, all required, because the cost of a false extension is the user's
    /// clipboard staying wrong:
    /// 1. the host answered AX when we posted — otherwise silence is its normal state and proves
    ///    nothing (a check that could not run must not read as a check that ran);
    /// 2. it is not answering now;
    /// 3. we are still inside the hard ceiling.
    public static func shouldExtendResidencyForStalledHost(
        hostRespondedAtPaste: Bool,
        hostRespondsNow: Bool,
        elapsedSincePaste: TimeInterval,
        ceiling: TimeInterval = InjectTiming.unverifiedPayloadResidencyCeiling
    ) -> Bool {
        guard hostRespondedAtPaste, !hostRespondsNow else { return false }
        return elapsedSincePaste < ceiling
    }

    public static func label(for result: PasteDeliveryResult) -> String {
        switch result {
        case .notPosted: return "notPosted"
        case .delivered: return "delivered"
        case .failed: return "failed"
        case .unavailable: return "unavailable"
        }
    }

    // MARK: - User clipboard write

    /// Writes a string the user intends to keep (e.g. Preview → Copy).
    ///
    /// Invalidates any in-flight expansion restore so a later restore cannot clobber
    /// the copied text, and so `changeCount` tracking stays coherent with ownership.
    @discardableResult
    public func writeUserClipboardString(_ string: String) -> Bool {
        writeUserClipboard(representations: [(.string, Data(string.utf8))], pasteboard: .general)
    }

    /// A deliberate image copy uses the same checked publication and recovery as a text copy.
    @discardableResult
    public func writeUserClipboardImage(_ image: NSImage, pasteboard: NSPasteboard = .general) -> Bool {
        writeUserClipboard(representations: Self.imageRepresentations(image), pasteboard: pasteboard)
    }

    private static func imageRepresentations(_ image: NSImage) -> [(NSPasteboard.PasteboardType, Data)] {
        var representations: [(NSPasteboard.PasteboardType, Data)] = []
        if let tiff = image.tiffRepresentation { representations.append((.tiff, tiff)) }
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
            representations.append((.png, png))
        }
        return representations
    }

    private func writeUserClipboard(
        representations: [(NSPasteboard.PasteboardType, Data)], pasteboard: NSPasteboard
    ) -> Bool {
        guard !representations.isEmpty else { return false }
        // Snapshot before invalidation so an in-flight expansion retains the original clipboard.
        let priorSnapshot = acquireUserClipboardSnapshot(pasteboard: pasteboard)
        return performUserClipboardWrite(
            priorSnapshot: priorSnapshot,
            clearContents: { pasteboard.clearContents() },
            currentChangeCount: { pasteboard.changeCount },
            writes: representations.map { type, data in { pasteboard.setData(data, forType: type) } },
            restoreSnapshot: { snapshot, owned in
                Self.restoreUserClipboardSnapshot(snapshot, ownedChangeCount: owned,
                    clearContents: { pasteboard.clearContents() },
                    currentChangeCount: { pasteboard.changeCount },
                    writeObjects: { pasteboard.writeObjects($0) })
            }
        ).didWrite
    }

    /// One canonical clear → write → conditional recovery transaction.
    ///
    /// Recovery is deliberately immediate and single-attempt: returning `false` must be truthful
    /// now, while retrying later would extend the interval in which another process can claim the
    /// pasteboard. The snapshot itself is capped by `snapshotMaxItems` / `snapshotMaxBytes`.
    @discardableResult
    func performUserClipboardWrite(
        _ string: String,
        priorSnapshot: PasteboardSnapshot?,
        operations: UserClipboardWriteOperations
    ) -> UserClipboardWriteOutcome {
        performUserClipboardWrite(
            priorSnapshot: priorSnapshot, clearContents: operations.clearContents,
            currentChangeCount: operations.currentChangeCount,
            writes: [{ operations.setString(string) }], restoreSnapshot: operations.restoreSnapshot
        )
    }

    @discardableResult
    func performUserClipboardWrite(
        priorSnapshot: PasteboardSnapshot?,
        clearContents: () -> Int,
        currentChangeCount: () -> Int,
        writes: [() -> Bool],
        restoreSnapshot: (PasteboardSnapshot, Int) -> UserClipboardRestoreOutcome
    ) -> UserClipboardWriteOutcome {
        guard !writes.isEmpty, writes.count <= 16 else { return .writeFailedNoPriorSnapshot }
        invalidatePendingRestore()
        let publication = Self.publishClipboard(
            clearContents: clearContents,
            currentChangeCount: currentChangeCount,
            writes: writes
        )

        let outcome: UserClipboardWriteOutcome
        switch publication {
        case .published:
            outcome = .written
        case .ownershipLost:
            outcome = .ownershipLost
        case .notPrepared:
            outcome = .writeFailedNoPriorSnapshot
        case .writeFailed(let ownedClearChangeCount):
            if let priorSnapshot, !priorSnapshot.isEmpty {
                switch restoreSnapshot(priorSnapshot, ownedClearChangeCount) {
                case .restored: outcome = .writeFailedPriorRestored
                case .ownershipLost: outcome = .ownershipLost
                case .failed: outcome = .writeFailedRestoreFailed
                }
            } else {
                outcome = .writeFailedNoPriorSnapshot
            }
        }

        let representationCount = writes.count
        let snapshotItemCount = priorSnapshot?.count ?? 0
        if outcome.didWrite {
            DevTypeLog.inject.info(
                "[Clipboard] user write outcome=written representations=\(representationCount, privacy: .public)"
            )
        } else {
            DevTypeLog.inject.error(
                "[Clipboard] user write outcome=\(outcome.diagnosticLabel, privacy: .public) representations=\(representationCount, privacy: .public) boundedSnapshotItems=\(snapshotItemCount, privacy: .public)"
            )
        }
        return outcome
    }

    /// Only a successful publication can reach the paste scheduler. A partial write
    /// may recover the previous snapshot while its original clear count is still ours.
    private func ticketAfterPublication(
        _ outcome: ClipboardPublicationOutcome,
        pasteboard: NSPasteboard,
        oldItems: PasteboardSnapshot?,
        generation: UInt64
    ) -> ClipboardTicket? {
        switch outcome {
        case .published(let owned):
            let ticket = ClipboardTicket(pasteboard: pasteboard, oldItems: oldItems,
                                         generation: generation, targetChangeCount: owned)
            registerPendingTicket(ticket)
            return ticket
        case .writeFailed(let owned):
            restore(ClipboardTicket(pasteboard: pasteboard, oldItems: oldItems,
                                    generation: generation, targetChangeCount: owned))
        case .ownershipLost, .notPrepared:
            clearPendingTicket(generation: generation)
        }
        DevTypeLog.inject.error("[Clipboard] automatic publication failed — paste not posted")
        return nil
    }

    struct PasteTarget {
        let pid: pid_t?
        let element: AXUIElement?
        let range: NSRange?

        static func capture(baseline: DeliveryVerifier.FocusedTextObservation? = nil) -> Self {
            let element = baseline?.target ?? AXContextChecker.shared.focusedElement()
            return Self(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                        element: element,
                        range: baseline?.selectedRange ?? element.flatMap { DeliveryVerifier.selectedRange(for: $0) })
        }

        func matches(pid currentPID: pid_t?, element current: AXUIElement?, range currentRange: NSRange?, checkRange: Bool) -> Bool {
            guard let pid, pid > 0, pid == currentPID else { return false }
            switch (element, current) {
            case (let original?, let observed?):
                guard CFEqual(original, observed) else { return false }
            case (nil, nil): break
            default: return false
            }
            return !checkRange || range == nil || range == currentRange
        }

        func isCurrent(checkRange: Bool) -> Bool {
            let current = AXContextChecker.shared.focusedElement()
            return matches(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                           element: current,
                           range: checkRange ? current.flatMap { DeliveryVerifier.selectedRange(for: $0) } : nil,
                           checkRange: checkRange)
        }
    }

    private func pasteContinuation(
        ticket: ClipboardTicket, target: PasteTarget, checkRange: Bool,
        allowSecureInput: Bool, shouldContinue: () -> Bool
    ) -> Bool {
        currentRestoreGeneration() == ticket.generation
            && ticket.pasteboard.changeCount == ticket.targetChangeCount
            && shouldContinue()
            && CGPreflightPostEventAccess()
            && (allowSecureInput || !AXContextChecker.isSecureEventInputEnabledLive())
            && target.isCurrent(checkRange: checkRange)
    }

    // MARK: - Text paste

    public func pasteViaClipboard(text: String, completion: ((Bool) -> Void)? = nil) {
        pasteViaClipboard(text: text, expectedText: nil, baseline: nil) { result in
            completion?(result != .notPosted)
        }
    }

    /// Clipboard paste that holds our payload until AX confirms delivery or the hold timeout
    /// expires (unverified). No ambiguous outcome authorizes another paste.
    ///
    /// - Parameters:
    ///   - bundleID: frontmost app, used only for §3.4 timing adaptation. Captured by the caller at
    ///     paste time rather than read here, so an app switch mid-paste cannot mislabel the sample.
    ///   - focusedRole: AX role of the original field, retained for role-scoped confirmation
    ///     diagnostics. Historical confirmation counts never authorize corrective replay.
    ///   - staleProbe: text the caller *removed* from the field just before this paste (the
    ///     erased trigger). If a verification read still shows it, the mirror is stale by
    ///     construction and its "missing" answer is discarded.
    ///   - leaveClipboardOnFailure: When true, skip immediate restore on `.notPosted` / `.failed` so the
    ///     concealed payload remains for a manual ⌘V (secure clipboard paste under Secure Input).
    ///   - holdTimeoutOverride: Optional longer hold (e.g. secure clipboard paste under SI).
    ///   - completeBeforeRestore: When true and no `expectedText`, report `.unavailable` right after
    ///     Cmd+V so callers are not blocked for the full hold window.
    public func pasteViaClipboard(
        text: String,
        expectedText: String?,
        baseline: DeliveryVerifier.FocusedTextObservation?,
        bundleID: String? = nil,
        focusedRole: String? = nil,
        staleProbe: String? = nil,
        staleProbeCaseInsensitive: Bool = false,
        leaveClipboardOnFailure: Bool = false,
        holdTimeoutOverride: TimeInterval? = nil,
        completeBeforeRestore: Bool = false,
        allowSecureInput: Bool = false,
        shouldContinue: @escaping () -> Bool = { true },
        completion: @escaping (PasteDeliveryResult) -> Void
    ) {
        // Re-check Post Events at paste time.
        if let holdTimeoutOverride,
           !holdTimeoutOverride.isFinite || holdTimeoutOverride < 0
            || holdTimeoutOverride > InjectTiming.secureClipboardPasteHoldTimeout {
            completion(.notPosted)
            return
        }
        let target = PasteTarget.capture(baseline: baseline)
        guard shouldContinue() else {
            DevTypeLog.inject.error("[Inject] paste refused — cancelled or superseded")
            completion(.notPosted)
            return
        }
        guard CGPreflightPostEventAccess() else {
            DevTypeLog.inject.error("[Inject] paste refused — Post Events denied at paste time")
            completion(.notPosted)
            return
        }
        guard allowSecureInput || !AXContextChecker.isSecureEventInputEnabledLive() else {
            DevTypeLog.inject.error("[Inject] paste refused — Secure Input active at paste time")
            completion(.notPosted)
            return
        }
        guard target.isCurrent(checkRange: true) else {
            DevTypeLog.inject.error("[Inject] paste refused — target element or selection changed before paste")
            completion(.notPosted)
            return
        }

        let pasteboard = NSPasteboard.general
        let oldItems = acquireUserClipboardSnapshot(pasteboard: pasteboard)
        let generation = beginRestoreGeneration()

        let publication = Self.publishClipboard(
            clearContents: { pasteboard.clearContents() },
            currentChangeCount: { pasteboard.changeCount },
            writes: [
                { pasteboard.setString(text, forType: .string) },
                { pasteboard.setData(Data(), forType: Self.transientType) },
                { pasteboard.setData(Data(), forType: Self.concealedType) },
                { pasteboard.setData(Data(), forType: Self.autoGeneratedType) },
            ]
        )
        guard let ticket = ticketAfterPublication(
            publication, pasteboard: pasteboard, oldItems: oldItems, generation: generation
        ) else {
            completion(.notPosted)
            return
        }

        let restoreDelayValue = holdTimeoutOverride
            ?? restoreDelay(bundleID: bundleID, payloadBytes: text.utf8.count)
        let holdTimeoutValue = holdTimeoutOverride
            ?? max(timing.holdTimeout(bundleID: bundleID), restoreDelayValue)
        // §8.12: the board must stay readable for the *host*, which is a different and longer
        // question than how long we keep interrogating AX. `atLeast` keeps an explicit caller
        // override (the 8 s secure-clipboard window) from being clamped down to the ceiling.
        let unverifiedHold = timing.unverifiedPayloadResidency(
            bundleID: bundleID,
            payloadBytes: text.utf8.count,
            atLeast: restoreDelayValue
        )
        // The ⌘V goes to whoever is frontmost when it is posted; resolving the pid here rather
        // than at release time means a later app switch cannot re-point the stall probe at an
        // innocent process.
        let targetPID = target.pid
        // Free responsiveness baseline: `baseline` is a completed AX read of this app's focused
        // element taken moments ago by the caller. If it answered, the app was alive; if it never
        // speaks AX, the stall probe stays disarmed rather than firing on every expansion.
        let hostRespondedAtPaste = baseline != nil

        DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.prePasteSettleDelay) {
            self.hid.postCmdVKeyEventsAsync(shouldContinue: {
                self.pasteContinuation(ticket: ticket, target: target, checkRange: true,
                                       allowSecureInput: allowSecureInput, shouldContinue: shouldContinue)
            }) { posted in
                guard posted else {
                    // No ⌘V exists, so nothing is waiting to read the board — only an explicit
                    // manual-paste window can keep the payload up.
                    self.releaseOwnership(
                        ticket,
                        result: .notPosted,
                        residency: nil,
                        notBefore: leaveClipboardOnFailure
                            ? (self.now() + restoreDelayValue)
                            : nil
                    )
                    completion(.notPosted)
                    return
                }

                let residency = PayloadResidency(
                    postedAt: self.now(),
                    unverifiedHold: unverifiedHold,
                    ceiling: max(InjectTiming.unverifiedPayloadResidencyCeiling, unverifiedHold),
                    targetPID: targetPID,
                    hostRespondedAtPaste: hostRespondedAtPaste,
                    bundleID: bundleID
                )

                guard let expectedText, !expectedText.isEmpty else {
                    // Nothing to verify, so this paste can never produce read evidence: it always
                    // owes the full residency.
                    if completeBeforeRestore {
                        completion(.unavailable)
                        self.releaseOwnership(ticket, result: .unavailable, residency: residency)
                    } else {
                        self.releaseOwnership(
                            ticket,
                            result: .unavailable,
                            residency: residency,
                            onReleased: { completion(.unavailable) }
                        )
                    }
                    return
                }

                self.runPasteHoldLoop(
                    expectedText: expectedText,
                    baseline: baseline,
                    bundleID: bundleID,
                    focusedRole: focusedRole,
                    staleProbe: staleProbe,
                    staleProbeCaseInsensitive: staleProbeCaseInsensitive,
                    pasteAttemptsCompleted: 1,
                    holdStarted: self.now(),
                    holdTimeout: holdTimeoutValue,
                    ticket: ticket,
                    residency: residency,
                    shouldContinue: {
                        self.pasteContinuation(ticket: ticket, target: target, checkRange: false,
                                               allowSecureInput: allowSecureInput, shouldContinue: shouldContinue)
                    },
                    completion: completion
                )
            }
        }
    }

    private func runPasteHoldLoop(
        expectedText: String,
        baseline: DeliveryVerifier.FocusedTextObservation?,
        bundleID: String?,
        focusedRole: String?,
        staleProbe: String?,
        staleProbeCaseInsensitive: Bool,
        pasteAttemptsCompleted: Int,
        holdStarted: TimeInterval,
        holdTimeout: TimeInterval,
        ticket: ClipboardTicket,
        residency: PayloadResidency,
        shouldContinue: @escaping () -> Bool,
        completion: @escaping (PasteDeliveryResult) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.pasteDeliverySettleDelay) {
            guard shouldContinue() else {
                self.releaseOwnership(ticket, result: .unavailable, residency: residency)
                completion(.unavailable)
                return
            }
            let delivery = self.verifier.verifyFocusedTextDelivery(
                expectedText: expectedText,
                baseline: baseline,
                staleProbe: staleProbe,
                staleProbeCaseInsensitive: staleProbeCaseInsensitive
            )
            let elapsed = (self.now() - holdStarted)
            let decision = PasteboardBroker.decidePasteHold(
                delivery: delivery, elapsed: elapsed, holdTimeout: holdTimeout
            )

            switch decision {
            case .succeed:
                // §3.4: this is the one moment the system actually *measures* how long this app
                // takes to consume a paste. Everything else in `InjectTiming` is a guess.
                self.timing.recordDeliveryLatency(elapsed, bundleID: bundleID)
                // Record only an attributed in-window confirmation. Historical confirmation
                // counts remain diagnostic and cannot authorize replay of a later operation.
                AXWriteCapabilityStore.shared.recordDeliveryConfirmed(
                    bundleID: bundleID,
                    role: focusedRole
                )
                // §8.12: the one outcome that proves the host read the board. Restore at once.
                self.releaseOwnership(ticket, result: .delivered, residency: residency)
                completion(.delivered)

            case .giveUpUnverified, .failConfirmed, .retryPaste:
                // Legacy verdict cases also fail closed. No observation-only outcome
                // can post a second Cmd+V or restore text into the target.
                self.releaseOwnership(ticket, result: .unavailable, residency: residency)
                completion(.unavailable)

            case .waitMore:
                self.runPasteHoldLoop(
                    expectedText: expectedText,
                    baseline: baseline,
                    bundleID: bundleID,
                    focusedRole: focusedRole,
                    staleProbe: staleProbe,
                    staleProbeCaseInsensitive: staleProbeCaseInsensitive,
                    pasteAttemptsCompleted: pasteAttemptsCompleted,
                    holdStarted: holdStarted,
                    holdTimeout: holdTimeout,
                    ticket: ticket,
                    residency: residency,
                    shouldContinue: shouldContinue,
                    completion: completion
                )
            }
        }
    }

    // MARK: - Image paste

    /// Clipboard-pastes an image (TIFF + PNG reps) with the same snapshot/restore
    /// discipline as `pasteViaClipboard`. Used by image snippets only.
    ///
    /// §3.4: two fixes here. The restore delay no longer runs image bytes through the *text*
    /// formula (a 1 MB image computed 25 s and clamped to 0.45 s, i.e. the number was noise), and
    /// the paste is no longer fire-and-forget — the payload is held while AX is polled for
    /// evidence the field changed, exactly like the text hold loop.
    ///
    /// Deliberately **no** automatic re-paste: unlike text there is no expected string to look for,
    /// and several hosts (Slack, Mail) attach an image without changing the focused element's
    /// `AXValue` at all. Re-pasting on that evidence would insert the image twice, which is worse
    /// than reporting `postedUnverified`. Verification here is reporting-only.
    public func pasteImageViaClipboard(
        image: NSImage,
        bundleID: String? = nil,
        shouldContinue: @escaping () -> Bool = { true },
        completion: @escaping (PasteDeliveryResult) -> Void
    ) {
        let target = PasteTarget.capture()
        guard shouldContinue() else {
            DevTypeLog.inject.error("[Inject] image paste refused — cancelled or superseded")
            completion(.notPosted)
            return
        }
        guard CGPreflightPostEventAccess() else {
            DevTypeLog.inject.error("[Inject] image paste refused — Post Events denied at paste time")
            completion(.notPosted)
            return
        }
        guard !AXContextChecker.isSecureEventInputEnabledLive() else {
            DevTypeLog.inject.error("[Inject] image paste refused — Secure Input active at paste time")
            completion(.notPosted)
            return
        }
        guard target.isCurrent(checkRange: true) else {
            DevTypeLog.inject.error("[Inject] image paste refused — target element or selection changed before paste")
            completion(.notPosted)
            return
        }

        // Encode before acquiring the board: no partially prepared image may clear it.
        var representations = Self.imageRepresentations(image)
        guard !representations.isEmpty else {
            completion(.notPosted)
            return
        }
        let payloadBytes = representations.reduce(0) { $0 + $1.1.count }
        representations.append(contentsOf: [
            (Self.transientType, Data()), (Self.concealedType, Data()), (Self.autoGeneratedType, Data())
        ])
        let pasteboard = NSPasteboard.general
        let oldItems = acquireUserClipboardSnapshot(pasteboard: pasteboard)
        let generation = beginRestoreGeneration()
        let publication = Self.publishClipboard(
            clearContents: { pasteboard.clearContents() },
            currentChangeCount: { pasteboard.changeCount },
            writes: representations.map { type, data in { pasteboard.setData(data, forType: type) } }
        )
        guard let ticket = ticketAfterPublication(
            publication, pasteboard: pasteboard, oldItems: oldItems, generation: generation
        ) else {
            completion(.notPosted)
            return
        }
        let restoreDelayValue = calculateImageRestoreDelay(payloadBytes: payloadBytes)
        let holdTimeoutValue = max(restoreDelayValue, InjectTiming.imageDeliveryHoldTimeout)
        // §8.12: an image snippet that pastes the user's old clipboard is the same defect wearing
        // a different payload type, so it gets the same residency floor. Image bytes are a poor
        // proxy for host read time, hence `max` with the size-derived delay rather than a swap.
        let unverifiedHold = max(restoreDelayValue, InjectTiming.unverifiedPayloadResidencyFloor)
        let targetPID = target.pid

        DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.prePasteSettleDelay) {
            let baseline = self.verifier.captureFocusedTextObservation()
            self.hid.postCmdVKeyEventsAsync(shouldContinue: {
                self.pasteContinuation(ticket: ticket, target: target, checkRange: true,
                                       allowSecureInput: false, shouldContinue: shouldContinue)
            }) { posted in
                guard posted else {
                    self.releaseOwnership(ticket, result: .notPosted, residency: nil)
                    completion(.notPosted)
                    return
                }
                let residency = PayloadResidency(
                    postedAt: self.now(),
                    unverifiedHold: unverifiedHold,
                    ceiling: max(InjectTiming.unverifiedPayloadResidencyCeiling, unverifiedHold),
                    targetPID: targetPID,
                    hostRespondedAtPaste: baseline != nil,
                    bundleID: bundleID
                )
                self.runImageHoldLoop(
                    holdStarted: self.now(),
                    holdTimeout: holdTimeoutValue,
                    ticket: ticket,
                    residency: residency,
                    shouldContinue: {
                        self.pasteContinuation(ticket: ticket, target: target, checkRange: false,
                                               allowSecureInput: false, shouldContinue: shouldContinue)
                    },
                    completion: completion
                )
            }
        }
    }

    private func runImageHoldLoop(
        holdStarted: TimeInterval,
        holdTimeout: TimeInterval,
        ticket: ClipboardTicket,
        residency: PayloadResidency,
        shouldContinue: @escaping () -> Bool,
        completion: @escaping (PasteDeliveryResult) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.pasteDeliverySettleDelay) {
            if shouldContinue(), (self.now() - holdStarted) < holdTimeout {
                self.runImageHoldLoop(holdStarted: holdStarted, holdTimeout: holdTimeout,
                    ticket: ticket, residency: residency, shouldContinue: shouldContinue, completion: completion)
                return
            }
            // Text changes cannot attribute an image paste. Retain full unverified
            // residency and do not train latency on unrelated field edits.
            self.releaseOwnership(ticket, result: .unavailable, residency: residency)
            completion(.unavailable)
        }
    }

    // MARK: - Ownership

    /// §1.7 step 1: work out what the *user's* clipboard actually is, before we overwrite it.
    ///
    /// If our own payload from a previous, still-pending expansion is on the board, then the user's
    /// real clipboard is whatever that expansion was holding — not what we can read right now.
    /// Snapshotting the board here is exactly the bug: expansion #2 would adopt expansion #1's
    /// snippet as "the user's clipboard" and faithfully restore it later.
    private func acquireUserClipboardSnapshot(pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        restoreLock.lock()
        let pending = pendingTicket
        restoreLock.unlock()

        if let pending, pending.targetChangeCount == pasteboard.changeCount {
            DevTypeLog.inject.notice(
                "[Inject] §1.7 clipboard still holds our previous payload — inheriting the pending restore instead of snapshotting it"
            )
            return pending.oldItems
        }
        if pending != nil {
            // The board moved on: either the user copied something (their content is what we are
            // about to snapshot, correctly) or the previous restore already ran. Either way the
            // stale ticket must not fire later — the generation bump below guarantees that.
            DevTypeLog.inject.debug(
                "[Inject] §1.7 abandoning stale clipboard ticket — pasteboard changed since our last paste"
            )
        }
        guard PasteboardBroker.mayAdoptAsUserClipboard(types: pasteboard.types) else {
            DevTypeLog.inject.info(
                "[Inject] clipboard holds a concealed payload — not adopting it as the user's clipboard"
            )
            return nil
        }
        return PasteboardBroker.snapshotPasteboard(pasteboard)
    }

    private func registerPendingTicket(_ ticket: ClipboardTicket) {
        restoreLock.lock()
        pendingTicket = ticket
        restoreLock.unlock()
    }

    private func clearPendingTicket(generation: UInt64) {
        restoreLock.lock()
        if pendingTicket?.generation == generation {
            pendingTicket = nil
        }
        restoreLock.unlock()
    }

    /// §8.1 / §8.12: the single pasteboard release. Every path that finishes with our payload on
    /// the board goes through here, and none of them decides its own timing.
    ///
    /// - Parameters:
    ///   - result: how the paste ended — the only input that can authorise an immediate release.
    ///   - residency: the ⌘V's residency, `nil` when no ⌘V was ever posted.
    ///   - notBefore: an independent floor, used by `leaveClipboardOnFailure` to keep a concealed
    ///     payload up for a manual ⌘V. Composed with residency by `max`, never by replacement —
    ///     a caller asking for an 8 s secure-paste window must not shorten it to the residency,
    ///     and the residency must not be shortened to a caller's smaller number either.
    ///   - onReleased: run after the user's clipboard is back, for callers whose contract is
    ///     "tell me when the board is theirs again".
    func releaseOwnership(
        _ ticket: ClipboardTicket,
        result: PasteDeliveryResult,
        residency: PayloadResidency?,
        notBefore: TimeInterval? = nil,
        onReleased: (() -> Void)? = nil
    ) {
        var deadline = notBefore ?? now()
        if let residency {
            let remaining = PasteboardBroker.remainingPayloadResidency(
                result: result,
                elapsedSincePaste: (now() - residency.postedAt),
                unverifiedHold: residency.unverifiedHold
            )
            deadline = max(deadline, (now() + remaining))
        }
        releaseWhenDue(
            ticket,
            result: result,
            residency: residency,
            notBefore: deadline,
            onReleased: onReleased
        )
    }

    /// Independent work bound in addition to the monotonic residency deadline.
    public static let maxStallExtensions = 16

    /// Waits out the deadline, then re-asks the stall question before letting go.
    private func releaseWhenDue(
        _ ticket: ClipboardTicket,
        result: PasteDeliveryResult,
        residency: PayloadResidency?,
        notBefore: TimeInterval,
        extensionsUsed: Int = 0,
        onReleased: (() -> Void)?
    ) {
        // A newer expansion (or a deliberate user-clipboard write) owns the board now. Bail before
        // spending an AX round trip on a ticket `restore` would refuse anyway.
        guard currentRestoreGeneration() == ticket.generation else {
            onReleased?()
            return
        }

        let wait = notBefore - now()
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                self.releaseWhenDue(
                    ticket,
                    result: result,
                    residency: residency,
                    notBefore: notBefore,
                    extensionsUsed: extensionsUsed,
                    onReleased: onReleased
                )
            }
            return
        }

        if let residency,
           extensionsUsed < Self.maxStallExtensions,
           Self.wantsStallExtension(result: result, residency: residency) {
            let elapsed = (now() - residency.postedAt)
            if PasteboardBroker.shouldExtendResidencyForStalledHost(
                hostRespondedAtPaste: residency.hostRespondedAtPaste,
                hostRespondsNow: residency.targetPID.map { AXContextChecker.appRespondsToAX(pid: $0) } ?? true,
                elapsedSincePaste: elapsed,
                ceiling: max(residency.ceiling, residency.unverifiedHold)
            ) {
                InjectTelemetryLog.shared.recordClipboardHoldExtension(bundleID: residency.bundleID)
                let safeBundleID = DevTypeLog.boundedPublicIdentifier(
                    residency.bundleID,
                    label: "bundleID"
                )
                DevTypeLog.inject.notice(
                    """
                    [Inject] §8.12 holding the payload past its \
                    \(Int(residency.unverifiedHold * 1000), privacy: .public)ms residency — \
                    \(safeBundleID, privacy: .public) has stopped answering AX, \
                    so it has not consumed ⌘V yet \
                    (elapsed=\(Int(elapsed * 1000), privacy: .public)ms)
                    """
                )
                let next = min(
                    (now() + InjectTiming.stalledHostResidencyProbeInterval),
                    residency.hardDeadline
                )
                releaseWhenDue(
                    ticket,
                    result: result,
                    residency: residency,
                    notBefore: next,
                    extensionsUsed: extensionsUsed + 1,
                    onReleased: onReleased
                )
                return
            }
        }

        if let residency, result != .delivered, result != .notPosted {
            InjectTelemetryLog.shared.recordUnverifiedClipboardHold(
                bundleID: residency.bundleID,
                heldFor: (now() - residency.postedAt)
            )
        }
        restore(ticket)
        onReleased?()
    }

    /// Only outcomes with no read evidence can be extended — `.delivered` already proved the read
    /// and `.notPosted` has nothing to be read.
    private static func wantsStallExtension(
        result: PasteDeliveryResult,
        residency: PayloadResidency
    ) -> Bool {
        guard residency.targetPID != nil, residency.hostRespondedAtPaste else { return false }
        switch result {
        case .delivered, .notPosted: return false
        case .failed, .unavailable: return true
        }
    }

    // MARK: - Copy capture (clipboard-fallback selection read)

    /// How long to wait for the target app to answer a synthetic ⌘C with a pasteboard write,
    /// and how often to look. Copies are near-instant in practice; the timeout exists for apps
    /// that write the board from a secondary thread after the key event round-trips.
    public static let copyCaptureTimeout: TimeInterval = 0.30
    public static let copyCapturePollInterval: TimeInterval = 0.02

    /// What a `captureSelectionViaCopy` attempt produced. The label is recorded in the selection
    /// diagnostics — a fallback that ran and found the board untouched is a different bug report
    /// from one that never posted.
    public enum CopyCaptureOutcome: Equatable {
        /// The app answered ⌘C with a string. May still be blank — the *reader* owns blankness.
        case captured(String)
        /// ⌘C was posted and the pasteboard never changed: nothing selected, or the app ignores
        /// the chord. Indistinguishable from outside, and both mean "no selection to use".
        case boardUnchanged
        /// The app wrote the board but with no string representation (an image, a file).
        case noStringOnBoard
        /// The key events could not be posted (Post Events revoked mid-session).
        case postFailed
        /// The app that owned the selection lost focus before ⌘C could be posted.
        case sourceAppChanged
        /// Secure Event Input became active after the reader's earlier preflight.
        case secureInputActive

        public var diagnosticLabel: String {
            switch self {
            case .captured: return "captured"
            case .boardUnchanged: return "unchanged"
            case .noStringOnBoard: return "noString"
            case .postFailed: return "postFailed"
            case .sourceAppChanged: return "sourceChanged"
            case .secureInputActive: return "secureInput"
            }
        }
    }

    /// Pure identity check shared by the reader's early gate and the broker's immediate pre-post
    /// gate. Unknown and non-process ids fail closed; equality alone is insufficient for pid 0.
    public static func frontmostProcessMatches(expectedPID: pid_t, actualPID: pid_t?) -> Bool {
        expectedPID > 0 && actualPID == expectedPID
    }

    /// Pure: restore only when the board still shows the copy we observed. Anything else means
    /// another writer got there after our capture, and writing over them would eat *their* data
    /// to clean up after ours.
    public static func shouldRestoreAfterCopyCapture(
        changeCountNow: Int,
        changeCountAfterCopy: Int
    ) -> Bool {
        changeCountNow == changeCountAfterCopy
    }

    /// Last-resort selection read: snapshot the board, post ⌘C, wait briefly for the target app
    /// to write, read the string, put the user's clipboard back.
    ///
    /// This is the one sanctioned synthetic-copy path — `SelectionReader`'s "no unmanaged ⌘C"
    /// rule is about clipboard *ownership*, and this method is the owner: the same snapshot /
    /// changeCount / verified-restore machinery every paste already goes through, including
    /// inheriting a still-pending expansion restore rather than adopting our own payload as
    /// "the user's clipboard".
    ///
    /// Costs up to `copyCaptureTimeout` of calling-thread wait, so it is only for explicit user
    /// gestures, and only after every AX tier has failed. Two limits it cannot remove: a clipboard
    /// manager will see the transient copy (the *target app* writes the board, so nspasteboard.org
    /// markers cannot be attached), and an app that treats ⌘C-with-no-selection as "copy the
    /// current line" will report that line as the selection — which is why the caller only runs
    /// this when AX could not even resolve a focused element, never on a readable-but-empty
    /// selection.
    ///
    /// - Parameters:
    ///   - expectedFrontmostPID: Process that owned the selection before AX probing. Required so
    ///     callers cannot accidentally post an unpinned copy.
    ///   - frontmostPIDProvider: Live process lookup immediately before posting; injectable only
    ///     so the focus-theft branch can be tested without moving the user's real focus.
    ///   - secureInputProvider: Live Secure Input lookup at the same boundary.
    ///   - postCopy: The ⌘C itself, injectable so tests can simulate the target app.
    public func captureSelectionViaCopy(
        pasteboard: NSPasteboard = .general,
        expectedFrontmostPID: pid_t,
        timeout: TimeInterval = copyCaptureTimeout,
        pollInterval: TimeInterval = copyCapturePollInterval,
        frontmostPIDProvider: () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        secureInputProvider: () -> Bool = {
            AXContextChecker.isSecureEventInputEnabledLive()
        },
        postCopy: (() -> Bool)? = nil
    ) -> CopyCaptureOutcome {
        // Validate before any clipboard access or keyboard event. The poll count also bounds
        // this loop if an injected clock stalls or unexpectedly moves backward.
        guard timeout.isFinite, timeout > 0, timeout <= 5,
              pollInterval.isFinite, pollInterval >= 0.001, pollInterval <= 0.1 else {
            return .postFailed
        }
        let pollMicroseconds = useconds_t(pollInterval * 1_000_000)
        let maximumPolls = Int(ceil(timeout / pollInterval))
        let snapshot = acquireUserClipboardSnapshot(pasteboard: pasteboard)
        let baseline = pasteboard.changeCount

        // Snapshotting can traverse several clipboard representations. Re-check both volatile
        // gates after that work and immediately before input posting, not merely on reader entry.
        guard !secureInputProvider() else { return .secureInputActive }
        guard Self.frontmostProcessMatches(
            expectedPID: expectedFrontmostPID,
            actualPID: frontmostPIDProvider()
        ) else {
            return .sourceAppChanged
        }

        let posted: Bool
        if let postCopy {
            posted = postCopy()
        } else {
            posted = hid.postCmdCKeyEvents {
                !secureInputProvider()
                    && Self.frontmostProcessMatches(
                        expectedPID: expectedFrontmostPID,
                        actualPID: frontmostPIDProvider()
                    )
            }
        }
        guard posted else {
            if secureInputProvider() { return .secureInputActive }
            if !Self.frontmostProcessMatches(
                expectedPID: expectedFrontmostPID,
                actualPID: frontmostPIDProvider()
            ) {
                return .sourceAppChanged
            }
            return .postFailed
        }

        let deadline = now() + timeout
        for _ in 0..<maximumPolls {
            guard pasteboard.changeCount == baseline, now() < deadline else { break }
            usleep(pollMicroseconds)
        }
        guard pasteboard.changeCount != baseline else {
            // Nothing was written, so nothing needs restoring — the board was never touched.
            return .boardUnchanged
        }

        let afterCopy = pasteboard.changeCount

        // One extra poll interval: apps that declare types first and provide data second bump
        // `changeCount` before the string is actually there.
        usleep(pollMicroseconds)
        let captured = pasteboard.string(forType: .string)

        if Self.shouldRestoreAfterCopyCapture(
            changeCountNow: pasteboard.changeCount,
            changeCountAfterCopy: afterCopy
        ) {
            let postClearChangeCount = pasteboard.clearContents()
            if let snapshot, !snapshot.isEmpty {
                writeCopyCaptureRestore(
                    snapshot,
                    to: pasteboard,
                    ownedChangeCount: postClearChangeCount,
                    attempt: 0
                )
            }
            // An empty snapshot restores to an empty board: leaving the captured selection up
            // would hand it to every clipboard manager watching the board.
        } else {
            DevTypeLog.inject.notice(
                "[Inject] copy-capture restore abandoned — another owner wrote the pasteboard during capture"
            )
        }

        guard let captured else { return .noStringOnBoard }
        return .captured(captured)
    }

    /// §1.7: bounded pasteboard snapshot. See `snapshotMaxItems` for the tradeoff.
    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        var result: PasteboardSnapshot = []
        var budget = snapshotMaxBytes
        var skipped = 0

        for item in items.prefix(snapshotMaxItems) {
            var dict = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if snapshotSkippedTypes.contains(type.rawValue) {
                    skipped += 1
                    continue
                }
                guard let data = item.data(forType: type) else { continue }
                if data.count > budget {
                    skipped += 1
                    continue
                }
                budget -= data.count
                dict[type] = data
            }
            if !dict.isEmpty {
                result.append(dict)
            }
        }
        if items.count > snapshotMaxItems {
            skipped += items.count - snapshotMaxItems
        }
        if skipped > 0 {
            DevTypeLog.inject.notice(
                "[Inject] §1.7 clipboard snapshot bounded — \(skipped, privacy: .public) representation(s) not preserved (promised files and payloads over \(snapshotMaxBytes, privacy: .public) bytes are skipped)"
            )
        }
        return result
    }

    /// Rebuilds `NSPasteboardItem`s from a bounded snapshot, atomically at the item-set level.
    /// `NSPasteboardItem.setData` can refuse an individual representation. Returning an item with
    /// only the successful flavors would let an outer `writeObjects` report success for an
    /// incomplete restore, so one refusal rejects the entire reconstruction before any item is
    /// published to the pasteboard.
    private static func makeRestoredItems(
        _ snapshot: PasteboardSnapshot,
        setData: (NSPasteboardItem, Data, NSPasteboard.PasteboardType) -> Bool = {
            item, data, type in item.setData(data, forType: type)
        }
    ) -> [NSPasteboardItem]? {
        guard !snapshot.isEmpty else { return nil }
        var restoredItems: [NSPasteboardItem] = []
        restoredItems.reserveCapacity(snapshot.count)
        for itemDict in snapshot {
            guard !itemDict.isEmpty else { return nil }
            let newItem = NSPasteboardItem()
            for (type, data) in itemDict {
                guard setData(newItem, data, type) else { return nil }
            }
            restoredItems.append(newItem)
        }
        return restoredItems
    }

    /// Conditional complete-snapshot restore used by the deliberate user-write transaction.
    /// Fault injection lives here so a representation refusal is tested through the same
    /// ownership checks and outcome type as production.
    static func restoreUserClipboardSnapshot(
        _ snapshot: PasteboardSnapshot,
        ownedChangeCount: Int,
        clearContents: () -> Int,
        currentChangeCount: () -> Int,
        setData: (NSPasteboardItem, Data, NSPasteboard.PasteboardType) -> Bool = {
            item, data, type in item.setData(data, forType: type)
        },
        writeObjects: @escaping ([NSPasteboardItem]) -> Bool
    ) -> UserClipboardRestoreOutcome {
        // Check both before and after rebuilding local items. Clipboard data providers can be
        // non-trivial, and a newer external owner that arrives during reconstruction stays put.
        guard currentChangeCount() == ownedChangeCount else { return .ownershipLost }
        guard let restoredItems = makeRestoredItems(snapshot, setData: setData) else {
            DevTypeLog.inject.error(
                "[Clipboard] bounded snapshot reconstruction failed — no partial representation set was written"
            )
            return .failed
        }
        // writeObjects appends to an existing item set. Clear only after reconstruction,
        // through the same original-owner publication policy, so no partial payload survives.
        switch publishClipboard(clearContents: clearContents, currentChangeCount: currentChangeCount,
                                writes: [{ writeObjects(restoredItems) }], expectedChangeCount: ownedChangeCount) {
        case .published: return .restored
        case .ownershipLost: return .ownershipLost
        case .writeFailed, .notPrepared: return .failed
        }
    }

    /// Retries only while the original clear count is still owned. A failed write
    /// never adopts a newer count, even when the new clipboard has privacy markers.
    private func writeCopyCaptureRestore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        ownedChangeCount: Int,
        attempt: Int
    ) {
        var recoveryOwnedCount = ownedChangeCount
        let outcome = Self.restoreUserClipboardSnapshot(
            snapshot,
            ownedChangeCount: ownedChangeCount,
            clearContents: { recoveryOwnedCount = pasteboard.clearContents(); return recoveryOwnedCount },
            currentChangeCount: { pasteboard.changeCount },
            writeObjects: { pasteboard.writeObjects($0) }
        )
        switch outcome {
        case .restored: return
        case .ownershipLost:
            DevTypeLog.inject.notice("[Inject] copy-capture restoration superseded by another writer")
            return
        case .failed: break
        }
        guard attempt + 1 < InjectTiming.maxPasteboardRestoreAttempts else {
            DevTypeLog.inject.error(
                "[Inject] copy-capture clipboard restore failed after \(InjectTiming.maxPasteboardRestoreAttempts, privacy: .public) attempts — the user's clipboard was not restored"
            )
            return
        }
        DevTypeLog.inject.notice(
            "[Inject] copy-capture clipboard restore write failed — retry \(attempt + 1, privacy: .public)"
        )
        let retryOwnedCount = recoveryOwnedCount
        DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.pasteboardRestoreRetryDelay) { [weak self] in
            self?.writeCopyCaptureRestore(
                snapshot,
                to: pasteboard,
                ownedChangeCount: retryOwnedCount,
                attempt: attempt + 1
            )
        }
    }

    func restore(_ ticket: ClipboardTicket, attempt: Int = 0) {
        guard currentRestoreGeneration() == ticket.generation else { return }
        let pasteboard = ticket.pasteboard
        guard pasteboard.changeCount == ticket.targetChangeCount else {
            DevTypeLog.inject.notice("[Inject] clipboard restoration superseded by another writer")
            clearPendingTicket(generation: ticket.generation)
            return
        }
        guard let oldItems = ticket.oldItems, !oldItems.isEmpty else {
            Self.publicationLock.lock()
            defer { Self.publicationLock.unlock() }
            if currentRestoreGeneration() == ticket.generation,
               pasteboard.changeCount == ticket.targetChangeCount {
                pasteboard.clearContents()
            }
            clearPendingTicket(generation: ticket.generation)
            return
        }
        // Reconstruct locally before clearing. A refused representation must not
        // erase the current payload or publish a partial snapshot.
        guard let restoredItems = Self.makeRestoredItems(oldItems) else {
            DevTypeLog.inject.error("[Inject] clipboard snapshot reconstruction failed")
            clearPendingTicket(generation: ticket.generation)
            return
        }
        guard currentRestoreGeneration() == ticket.generation else { return }
        let outcome = Self.publishClipboard(
            clearContents: { pasteboard.clearContents() },
            currentChangeCount: { pasteboard.changeCount },
            writes: [{ pasteboard.writeObjects(restoredItems) }],
            expectedChangeCount: ticket.targetChangeCount
        )
        switch outcome {
        case .writeFailed(let owned):
            if attempt + 1 < InjectTiming.maxPasteboardRestoreAttempts {
                var retryTicket = ticket
                retryTicket.targetChangeCount = owned
                DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.pasteboardRestoreRetryDelay) {
                    self.restore(retryTicket, attempt: attempt + 1)
                }
                return
            }
            DevTypeLog.inject.error("[Inject] clipboard restoration exhausted its write attempts")
        case .ownershipLost:
            DevTypeLog.inject.notice("[Inject] clipboard restoration lost ownership during publication")
        case .published, .notPrepared:
            break
        }
        clearPendingTicket(generation: ticket.generation)
    }
}
