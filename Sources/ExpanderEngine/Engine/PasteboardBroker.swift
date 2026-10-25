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

    /// The writes that publish a payload representation by representation, in the only order that
    /// never exposes it unmarked: the three markers, then `payload`.
    ///
    /// A clipboard manager reacts to the change count moving at `clearContents()` and reads the
    /// board a moment later. The markers are what make it skip the entry, so they must already be
    /// on the board when the first payload byte is. Written after the payload, each marker is one
    /// more pasteboard round trip during which a secret sits readable and unmarked.
    static func concealedPublication(
        on writer: SecretPasteboardWriting,
        payload: [() -> Bool]
    ) -> [() -> Bool] {
        [transientType, concealedType, autoGeneratedType].map { marker in
            { writer.setData(Data(), forType: marker) }
        } + payload
    }

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
        /// Proof of a host read, when the payload was published lazily (text paste). `nil` for a
        /// payload that carries no such proof; the release policy then is the plain timer.
        var witness: PayloadReadWitness?
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
    private let environment: Environment

    /// Everything the text paste asks the machine instead of its arguments: which board it
    /// writes, whether ⌘V may be posted, whether Secure Input is on, whether the target is still
    /// the target, and how the user's clipboard is read. Production uses `.live`; a test hands in
    /// a named pasteboard and fixed answers, so the whole publish → ⌘V → hold → release sequence
    /// runs against a board that is not the user's clipboard.
    struct Environment {
        var pasteboard: () -> NSPasteboard = { .general }
        var canPostEvents: () -> Bool = { CGPreflightPostEventAccess() }
        var secureInputActive: () -> Bool = { AXContextChecker.isSecureEventInputEnabledLive() }
        var targetCurrent: (PasteTarget, _ checkRange: Bool, _ checkElement: Bool) -> Bool = {
            target, checkRange, checkElement in
            target.isCurrent(checkRange: checkRange, checkElement: checkElement)
        }
        var snapshot: (NSPasteboard) -> PasteboardSnapshot? = { PasteboardBroker.snapshotPasteboard($0) }

        static let live = Environment()
    }

    /// §2.4: `os_unfair_lock` rather than `NSLock` — taken from the inject path.
    private let restoreLock = UnfairLock()
    private var restoreGeneration: UInt64 = 0
    private var pendingTicket: ClipboardTicket?
    /// Until when `pendingTicket`'s payload may still be waiting to be read. Set when ⌘V goes out
    /// (that is when a read becomes possible), cleared with the ticket. A following paste waits on
    /// it — see `publicationGateWait`.
    private var pendingLeaseDeadline: TimeInterval?

    /// Native expansion bytes only. Keyed by standardized path + mtime + size,
    /// one entry per path, oldest insertion first. Not the TIFF+PNG fallback.
    private struct NativeImageCacheEntry {
        let path: String
        let modifiedAt: Date
        let byteCount: Int
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private let nativeImageCacheLock = UnfairLock()
    private var nativeImageCache: [NativeImageCacheEntry] = []
    private static let nativeImageCacheEntryLimit = 4

    public convenience init(
        hid: HIDKeyPoster = HIDKeyPoster.shared,
        verifier: DeliveryVerifier = DeliveryVerifier.shared,
        timing: InjectTimingStore = InjectTimingStore.shared,
        now: @escaping () -> TimeInterval = InputClock.monotonicNow
    ) {
        self.init(hid: hid, verifier: verifier, timing: timing, now: now, environment: .live)
    }

    init(
        hid: HIDKeyPoster,
        verifier: DeliveryVerifier = DeliveryVerifier.shared,
        timing: InjectTimingStore = InjectTimingStore.shared,
        now: @escaping () -> TimeInterval = InputClock.monotonicNow,
        environment: Environment
    ) {
        self.hid = hid
        self.verifier = verifier
        self.timing = timing
        self.now = now
        self.environment = environment
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
        pendingLeaseDeadline = nil
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

    /// Stat of a stored attachment. Tests inject this so they never touch Application Support.
    struct NativeImageFileAttributes: Equatable {
        var byteCount: Int
        var modifiedAt: Date
    }

    /// Image bytes that will be published, without the empty clipboard-manager markers.
    struct ExpansionImageRepresentations {
        var items: [(NSPasteboard.PasteboardType, Data)]
        var payloadBytes: Int
    }

    /// Expansion paste publishes stored PNG/JPEG/GIF/TIFF bytes under one native type.
    /// `NSImage` re-encoding flattens animated GIF and replaces the file with TIFF+PNG.
    /// bmp, webp, heic, unknown extensions, containment failures, and over-cap files
    /// keep that fallback. The cache holds only native payloads and is not taken across file IO.
    func expansionImageRepresentations(
        image: NSImage,
        imagePath: String?,
        attributes: ((URL) -> NativeImageFileAttributes?)? = nil,
        read: ((URL) -> Data?)? = nil
    ) -> ExpansionImageRepresentations {
        let attributeOf = attributes ?? { Self.nativeImageFileAttributes(at: $0) }
        let readBytes = read ?? { Self.readNativeImageFile(at: $0) }
        guard let imagePath, !imagePath.isEmpty,
              let pasteboardType = Self.nativeImagePasteboardType(for: imagePath) else {
            return fallbackExpansionImageRepresentations(image)
        }
        guard let url = ImageAttachmentStore.shared.resolvedURL(forImagePath: imagePath) else {
            return fallbackExpansionImageRepresentations(image)
        }
        guard let stat = attributeOf(url),
              stat.byteCount >= 0,
              stat.byteCount <= ImageAttachmentStore.maxImportedImageBytes else {
            return fallbackExpansionImageRepresentations(image)
        }
        let cachePath = url.standardizedFileURL.path
        if let cached = cachedNativeImage(path: cachePath, modifiedAt: stat.modifiedAt, byteCount: stat.byteCount) {
            return ExpansionImageRepresentations(
                items: [(cached.type, cached.data)],
                payloadBytes: cached.data.count
            )
        }
        guard let data = readBytes(url) else {
            return fallbackExpansionImageRepresentations(image)
        }
        guard data.count <= ImageAttachmentStore.maxImportedImageBytes else {
            return fallbackExpansionImageRepresentations(image)
        }
        if data.count == stat.byteCount {
            storeNativeImage(path: cachePath, modifiedAt: stat.modifiedAt, type: pasteboardType, data: data)
        }
        return ExpansionImageRepresentations(items: [(pasteboardType, data)], payloadBytes: data.count)
    }

    func nativeImagePayloadCacheSnapshot() -> (entryCount: Int, payloadBytes: Int) {
        nativeImageCacheLock.lock()
        defer { nativeImageCacheLock.unlock() }
        return (nativeImageCache.count, nativeImageCache.reduce(0) { $0 + $1.data.count })
    }

    private func fallbackExpansionImageRepresentations(_ image: NSImage) -> ExpansionImageRepresentations {
        let items = Self.imageRepresentations(image)
        return ExpansionImageRepresentations(
            items: items,
            payloadBytes: items.reduce(0) { $0 + $1.1.count }
        )
    }

    private static func nativeImagePasteboardType(for path: String) -> NSPasteboard.PasteboardType? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png":
            return .png
        case "jpg", "jpeg":
            return NSPasteboard.PasteboardType("public.jpeg")
        case "gif":
            return NSPasteboard.PasteboardType("public.gif")
        case "tiff":
            return .tiff
        default:
            return nil
        }
    }

    private static func nativeImageFileAttributes(at url: URL) -> NativeImageFileAttributes? {
        let values: [FileAttributeKey: Any]
        do {
            values = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return nil
        }
        guard (values[.type] as? FileAttributeType) == .typeRegular,
              let modifiedAt = values[.modificationDate] as? Date else {
            return nil
        }
        let byteCount: Int64?
        if let size = values[.size] as? Int64 {
            byteCount = size
        } else if let size = values[.size] as? Int {
            byteCount = Int64(size)
        } else if let size = values[.size] as? NSNumber {
            byteCount = size.int64Value
        } else {
            byteCount = nil
        }
        guard let byteCount, byteCount >= 0, byteCount <= Int64(Int.max) else { return nil }
        return NativeImageFileAttributes(byteCount: Int(byteCount), modifiedAt: modifiedAt)
    }

    /// Reads at most one byte past the import cap so an over-cap file is discarded
    /// without a re-encode and without caching those bytes.
    private static func readNativeImageFile(at url: URL) -> Data? {
        let cap = ImageAttachmentStore.maxImportedImageBytes
        let limit = cap >= Int.max ? Int.max : max(0, cap) + 1
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: limit)
        } catch {
            return nil
        }
    }

    private func cachedNativeImage(
        path: String,
        modifiedAt: Date,
        byteCount: Int
    ) -> (type: NSPasteboard.PasteboardType, data: Data)? {
        nativeImageCacheLock.lock()
        defer { nativeImageCacheLock.unlock() }
        guard let entry = nativeImageCache.first(where: {
            $0.path == path && $0.modifiedAt == modifiedAt && $0.byteCount == byteCount
        }) else { return nil }
        return (entry.type, entry.data)
    }

    private func storeNativeImage(
        path: String,
        modifiedAt: Date,
        type: NSPasteboard.PasteboardType,
        data: Data
    ) {
        nativeImageCacheLock.lock()
        defer { nativeImageCacheLock.unlock() }
        nativeImageCache.removeAll { $0.path == path }
        let cap = ImageAttachmentStore.maxImportedImageBytes
        guard data.count >= 0, cap >= 0, data.count <= cap else { return }
        while nativeImageCache.count >= Self.nativeImageCacheEntryLimit
            || Self.nativeImageCacheExceeds(nativeImageCache, adding: data.count, cap: cap) {
            guard !nativeImageCache.isEmpty else { break }
            nativeImageCache.removeFirst()
        }
        guard nativeImageCache.count < Self.nativeImageCacheEntryLimit,
              !Self.nativeImageCacheExceeds(nativeImageCache, adding: data.count, cap: cap) else { return }
        nativeImageCache.append(NativeImageCacheEntry(
            path: path,
            modifiedAt: modifiedAt,
            byteCount: data.count,
            type: type,
            data: data
        ))
    }

    private static func nativeImageCacheExceeds(
        _ entries: [NativeImageCacheEntry],
        adding: Int,
        cap: Int
    ) -> Bool {
        var used = 0
        for entry in entries {
            if entry.data.count < 0 || used > cap - entry.data.count { return true }
            used += entry.data.count
        }
        return adding > cap - used
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
        generation: UInt64,
        witness: PayloadReadWitness? = nil
    ) -> ClipboardTicket? {
        switch outcome {
        case .published(let owned):
            let ticket = ClipboardTicket(pasteboard: pasteboard, oldItems: oldItems,
                                         generation: generation, targetChangeCount: owned,
                                         witness: witness)
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

    /// A paste's way of following a control that was replaced under it. `vouch` is the caller's
    /// own judgement — the pipeline asks the same continuation policy the erase uses — and returns
    /// the replacement it accepts, or nil. Main-thread only, like every check that reads it.
    final class PasteTargetFollower {
        let vouch: () -> PasteTarget?
        /// The replacement this paste now follows; nil while the captured target still holds.
        var adopted: PasteTarget?
        init(vouch: @escaping () -> PasteTarget?) { self.vouch = vouch }
    }

    struct PasteTarget {
        let pid: pid_t?
        let element: AXUIElement?
        let range: NSRange?

        /// The target identity every later re-check compares against. `focus` lets an expansion
        /// that already resolved its element hand it over instead of paying another query.
        static func capture(
            focus: FocusedElementSource,
            baseline: DeliveryVerifier.FocusedTextObservation? = nil
        ) -> Self {
            let element = baseline?.target ?? focus.element
            return Self(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                        element: element,
                        range: baseline?.selectedRange ?? element.flatMap { DeliveryVerifier.selectedRange(for: $0) })
        }

        /// Which half of the comparison failed. `isCurrent` is this collapsed to a Bool, so the
        /// gate and the reason it reports can never disagree — the same shape
        /// `continuationBlock` / `allowsContinuation` use for the continuation gate.
        ///
        /// Kept as distinct cases because each is a different bug, and "Target element or
        /// selection changed before insertion" is the same sentence for all of them. A report
        /// that cannot tell `.elementChanged` (focus moved to another field) from
        /// `.focusArrived` (the target was captured before the app published a focused element
        /// at all) sends whoever reads it after the wrong cause — which is how a delivery race
        /// survives a round of fixes.
        enum Mismatch: String, Equatable {
            /// Nothing was captured to compare against; a target with no process fails closed.
            case noCapturedProcess
            case processChanged
            /// Captured a focused element, and now there is none.
            case focusLost
            /// Captured no focused element, and now there is one — focus *arriving*, not moving.
            case focusArrived
            case elementChanged
            case rangeChanged
        }

        func mismatch(
            pid currentPID: pid_t?,
            element current: AXUIElement?,
            range currentRange: NSRange?,
            checkRange: Bool,
            checkElement: Bool = true
        ) -> Mismatch? {
            guard let pid, pid > 0 else { return .noCapturedProcess }
            guard pid == currentPID else { return .processChanged }
            if checkElement {
                switch (element, current) {
                case (let original?, let observed?):
                    guard CFEqual(original, observed) else { return .elementChanged }
                case (nil, nil): break
                case (_?, nil): return .focusLost
                case (nil, _?): return .focusArrived
                }
            }
            guard !checkRange || range == nil || range == currentRange else { return .rangeChanged }
            return nil
        }

        func matches(
            pid currentPID: pid_t?,
            element current: AXUIElement?,
            range currentRange: NSRange?,
            checkRange: Bool,
            checkElement: Bool = true
        ) -> Bool {
            mismatch(pid: currentPID, element: current, range: currentRange,
                     checkRange: checkRange, checkElement: checkElement) == nil
        }

        /// Compare against live AX state, keeping the mismatch that decided it.
        ///
        /// One read answers both questions on purpose. The refuse path used to re-read focus to
        /// explain a decision a *previous* read had already made, so the label it printed could
        /// describe a different instant from the refusal it was labelling.
        ///
        /// §2.2: a documented re-check. It exists to catch the user moving between the capture
        /// and a mutation, so it must read focus live — never a threaded element.
        ///
        /// Focus is only read when the answer can depend on it: with neither `checkElement` nor
        /// `checkRange` the comparison is pid-only, and an N-character erase would otherwise pay
        /// N full focus queries for an element nothing looks at. `observeFocus` and `currentPID`
        /// are the test seam; production uses the live defaults.
        func liveMismatch(
            checkRange: Bool,
            checkElement: Bool = true,
            observeFocus: () -> AXUIElement? = { AXContextChecker.shared.focusedElement() },
            currentPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        ) -> Mismatch? {
            mismatch(observing: (checkElement || checkRange) ? observeFocus() : nil,
                     pid: currentPID(),
                     checkRange: checkRange,
                     checkElement: checkElement)
        }

        /// Compare against a focus reading the caller just took, reading the range through it.
        /// For the one caller whose fresh reading *is* the inject's focus resolution — the entry
        /// gate — so the comparison and the element the inject then uses are the same instant.
        func mismatch(
            observing current: AXUIElement?,
            pid currentPID: pid_t?,
            checkRange: Bool,
            checkElement: Bool = true
        ) -> Mismatch? {
            mismatch(pid: currentPID,
                     element: current,
                     range: checkRange ? current.flatMap { DeliveryVerifier.selectedRange(for: $0) } : nil,
                     checkRange: checkRange,
                     checkElement: checkElement)
        }

        func isCurrent(checkRange: Bool, checkElement: Bool = true) -> Bool {
            liveMismatch(checkRange: checkRange, checkElement: checkElement) == nil
        }
    }

    /// When AX `selectedRange` is a trustworthy same-caret signal.
    ///
    /// `beforeMutation` is the expand/erase gate: a proven native writer (`trusted`) can
    /// still stop an expansion if the caret moved; unknown and false-success hosts cannot
    /// — their range flickers, and treating that as a moved caret refuses a valid expand.
    /// A process we cannot name fails closed (check the range).
    ///
    /// `afterMutation` is clipboard paste after HID erase (and the 15 ms settle before ⌘V).
    /// Our own backspaces *are* supposed to move the caret; Electron then reports a
    /// different or nil range for tens of milliseconds. Pid + focused element still catch
    /// an app or field switch. Cursor 0.1.7 (165) aborted here with `notPosted` after a
    /// successful erase and restored `` `push ``.
    enum SelectionRangeGate: Equatable {
        case beforeMutation
        case afterMutation
    }

    static func verifySelectionRange(
        verdict: AXWriteCapabilityStore.Verdict?,
        bundleKnown: Bool,
        phase: SelectionRangeGate
    ) -> Bool {
        switch phase {
        case .afterMutation:
            return false
        case .beforeMutation:
            guard bundleKnown else { return true }
            return verdict == .trusted
        }
    }

    static func verifySelectionRange(
        bundleID: String?,
        role: String?,
        phase: SelectionRangeGate,
        store: AXWriteCapabilityStore = .shared
    ) -> Bool {
        guard let bundleID, !bundleID.isEmpty else {
            return verifySelectionRange(verdict: nil, bundleKnown: false, phase: phase)
        }
        return verifySelectionRange(
            verdict: store.verdict(for: bundleID, role: role),
            bundleKnown: true,
            phase: phase
        )
    }

    /// Whether paste/erase continue-guards should require `CFEqual` of the focused AX node.
    ///
    /// Combo boxes and menus retarget that node (dropdown, inner text field) while HID
    /// backspaces land. Requiring identity after mutation is the GitPulse refuse: the trigger
    /// was already deleted, then expand aborted because the combo box opened a list.
    /// Before mutation we still require identity so a click into a different field cannot
    /// authorize deleting that field's contents.
    static func verifyFocusedElement(role: String?, phase: SelectionRangeGate) -> Bool {
        switch phase {
        case .beforeMutation:
            return true
        case .afterMutation:
            return !AXWriteCapabilityStore.isAXWriteUnstableRole(role)
        }
    }

    /// Why Cmd+V was not posted after the clipboard payload was published. Distinct from the
    /// immediate pre-paste guards so a settle-delay abort is not silent in diagnostics.
    enum CmdVAbortReason: Equatable {
        case superseded
        case clipboardOwnershipLost
        case cancelled
        case postEventsDenied
        case secureInput
        case targetChanged

        var logSuffix: String {
            switch self {
            case .superseded, .cancelled:
                return "cancelled or superseded"
            case .clipboardOwnershipLost:
                return "clipboard ownership lost before Cmd+V"
            case .postEventsDenied:
                return "Post Events denied at paste time"
            case .secureInput:
                return "Secure Input active at paste time"
            case .targetChanged:
                return "target element or selection changed before paste"
            }
        }
    }

    static func cmdVAbortReason(
        generationMatches: Bool,
        clipboardOwned: Bool,
        shouldContinue: Bool,
        canPost: Bool,
        secureInputBlocked: Bool,
        targetCurrent: Bool
    ) -> CmdVAbortReason? {
        if !generationMatches { return .superseded }
        if !clipboardOwned { return .clipboardOwnershipLost }
        if !shouldContinue { return .cancelled }
        if !canPost { return .postEventsDenied }
        if secureInputBlocked { return .secureInput }
        if !targetCurrent { return .targetChanged }
        return nil
    }

    private func pasteContinuation(
        ticket: ClipboardTicket, target: PasteTarget, checkRange: Bool,
        checkElement: Bool = true, follower: PasteTargetFollower? = nil,
        allowSecureInput: Bool, shouldContinue: () -> Bool
    ) -> Bool {
        cmdVAbortReason(ticket: ticket, target: target, checkRange: checkRange,
                        checkElement: checkElement, follower: follower,
                        allowSecureInput: allowSecureInput, shouldContinue: shouldContinue) == nil
    }

    private func cmdVAbortReason(
        ticket: ClipboardTicket, target: PasteTarget, checkRange: Bool,
        checkElement: Bool = true, follower: PasteTargetFollower? = nil,
        allowSecureInput: Bool, shouldContinue: () -> Bool
    ) -> CmdVAbortReason? {
        Self.cmdVAbortReason(
            generationMatches: currentRestoreGeneration() == ticket.generation,
            clipboardOwned: ticket.pasteboard.changeCount == ticket.targetChangeCount,
            shouldContinue: shouldContinue(),
            canPost: environment.canPostEvents(),
            secureInputBlocked: !allowSecureInput && environment.secureInputActive(),
            targetCurrent: targetIsCurrent(
                target, follower: follower, checkRange: checkRange, checkElement: checkElement
            )
        )
    }

    /// Whether `target` is still the focused control — or, when the caller vouches for a
    /// replacement of it, whether *that* is. `environment.targetCurrent` stays the only judge of
    /// what is focused: an offered replacement is checked against the live focus exactly like the
    /// captured target, so a caller can narrow what the paste follows but never widen it.
    private func targetIsCurrent(
        _ target: PasteTarget, follower: PasteTargetFollower?, checkRange: Bool, checkElement: Bool
    ) -> Bool {
        let tracked = follower?.adopted ?? target
        if environment.targetCurrent(tracked, checkRange, checkElement) { return true }
        guard let follower, let replacement = follower.vouch(),
              environment.targetCurrent(replacement, checkRange, checkElement) else {
            return false
        }
        follower.adopted = replacement
        return true
    }

    private func logCmdVNotPosted(
        prefix: String,
        ticket: ClipboardTicket,
        target: PasteTarget,
        checkRange: Bool,
        checkElement: Bool = true,
        follower: PasteTargetFollower? = nil,
        allowSecureInput: Bool,
        shouldContinue: () -> Bool
    ) {
        let suffix = cmdVAbortReason(
            ticket: ticket, target: target, checkRange: checkRange,
            checkElement: checkElement, follower: follower,
            allowSecureInput: allowSecureInput, shouldContinue: shouldContinue
        )?.logSuffix ?? "Cmd+V was not posted"
        DevTypeLog.inject.error("\(prefix, privacy: .public) — \(suffix, privacy: .public)")
    }

    // MARK: - Text paste

    public func pasteViaClipboard(text: String, completion: ((Bool) -> Void)? = nil) {
        pasteViaClipboard(text: text, expectedText: nil, baseline: nil, focus: .live) { result in
            completion?(result != .notPosted)
        }
    }

    /// Clipboard paste that holds our payload until AX confirms delivery or the hold timeout
    /// expires (unverified). No ambiguous outcome authorizes another paste.
    ///
    /// - Parameters:
    ///   - bundleID: frontmost app, used for §3.4 timing adaptation and for whether AX
    ///     selectedRange is a trustworthy same-caret signal before ⌘V. Captured by the caller at
    ///     paste time rather than read here, so an app switch mid-paste cannot mislabel the sample.
    ///   - focusedRole: AX role of the original field, used with `bundleID` for delivery-trust
    ///     (range gate and confirmation). Historical confirmation counts never authorize replay.
    ///   - staleProbe: text the caller *removed* from the field just before this paste (the
    ///     erased trigger). If a verification read still shows it, the mirror is stale by
    ///     construction and its "missing" answer is discarded.
    ///   - leaveClipboardOnFailure: When true, skip immediate restore on `.notPosted` / `.failed` so the
    ///     concealed payload remains for a manual ⌘V (secure clipboard paste under Secure Input).
    ///   - holdTimeoutOverride: Optional longer hold (e.g. secure clipboard paste under SI).
    ///   - completeBeforeRestore: When true and no `expectedText`, report `.unavailable` right after
    ///     Cmd+V so callers are not blocked for the full hold window.
    ///   - followVouchedReplacement: Asked only when the captured target is no longer the focused
    ///     control. Returns the control that replaced it if the caller can vouch it is the same
    ///     one (WebKit swaps the text node under a typed expansion), nil otherwise. The answer is
    ///     still checked against the live focus before ⌘V; nil keeps the target pinned.
    func pasteViaClipboard(
        text: String,
        expectedText: String?,
        baseline: DeliveryVerifier.FocusedTextObservation?,
        focus: FocusedElementSource,
        bundleID: String? = nil,
        focusedRole: String? = nil,
        staleProbe: String? = nil,
        staleProbeCaseInsensitive: Bool = false,
        leaveClipboardOnFailure: Bool = false,
        holdTimeoutOverride: TimeInterval? = nil,
        completeBeforeRestore: Bool = false,
        allowSecureInput: Bool = false,
        followVouchedReplacement: (() -> PasteTarget?)? = nil,
        shouldContinue: @escaping () -> Bool = { true },
        completion: @escaping (PasteDeliveryResult) -> Void
    ) {
        // Re-check Post Events at paste time.
        if let holdTimeoutOverride,
           !holdTimeoutOverride.isFinite || holdTimeoutOverride < 0
            || holdTimeoutOverride > InjectTiming.secureClipboardPasteHoldTimeout {
            DevTypeLog.inject.error("[Inject] paste refused — invalid hold timeout override")
            completion(.notPosted)
            return
        }
        // A previous expansion's ⌘V may still be waiting to read the board. Publishing now would
        // make that host paste *this* text. Wait (bounded by its lease) and start over, so every
        // check below — target, focus, Secure Input — is made at the moment of publication.
        let gate = currentPublicationGateWait(pasteboard: environment.pasteboard())
        if gate > 0 {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + min(gate, InjectTiming.payloadWitnessPollInterval)
            ) {
                self.pasteViaClipboard(
                    text: text, expectedText: expectedText, baseline: baseline, focus: focus,
                    bundleID: bundleID, focusedRole: focusedRole, staleProbe: staleProbe,
                    staleProbeCaseInsensitive: staleProbeCaseInsensitive,
                    leaveClipboardOnFailure: leaveClipboardOnFailure,
                    holdTimeoutOverride: holdTimeoutOverride,
                    completeBeforeRestore: completeBeforeRestore,
                    allowSecureInput: allowSecureInput,
                    followVouchedReplacement: followVouchedReplacement,
                    shouldContinue: shouldContinue,
                    completion: completion
                )
            }
            return
        }
        let target = PasteTarget.capture(focus: focus, baseline: baseline)
        let follower = followVouchedReplacement.map { PasteTargetFollower(vouch: $0) }
        // HID erase (or a no-AX secure paste) has already happened; AX selectedRange is settling.
        let verifySelection = Self.verifySelectionRange(
            bundleID: bundleID, role: focusedRole, phase: .afterMutation
        )
        let checkElement = Self.verifyFocusedElement(role: focusedRole, phase: .afterMutation)
        guard shouldContinue() else {
            DevTypeLog.inject.error("[Inject] paste refused — cancelled or superseded")
            completion(.notPosted)
            return
        }
        guard environment.canPostEvents() else {
            DevTypeLog.inject.error("[Inject] paste refused — Post Events denied at paste time")
            completion(.notPosted)
            return
        }
        guard allowSecureInput || !environment.secureInputActive() else {
            DevTypeLog.inject.error("[Inject] paste refused — Secure Input active at paste time")
            completion(.notPosted)
            return
        }
        guard targetIsCurrent(target, follower: follower, checkRange: verifySelection, checkElement: checkElement) else {
            DevTypeLog.inject.error("[Inject] paste refused — target element or selection changed before paste")
            completion(.notPosted)
            return
        }

        let pasteboard = environment.pasteboard()
        guard let ticket = publishPayload(text, on: pasteboard) else {
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
                self.pasteContinuation(ticket: ticket, target: target, checkRange: verifySelection,
                                       checkElement: checkElement, follower: follower,
                                       allowSecureInput: allowSecureInput, shouldContinue: shouldContinue)
            }) { posted in
                guard posted else {
                    // No ⌘V exists, so nothing is waiting to read the board — only an explicit
                    // manual-paste window can keep the payload up.
                    self.logCmdVNotPosted(
                        prefix: "[Inject] paste refused",
                        ticket: ticket, target: target, checkRange: verifySelection,
                        checkElement: checkElement, follower: follower,
                        allowSecureInput: allowSecureInput, shouldContinue: shouldContinue
                    )
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
                // From here a host may read the payload. A following paste waits for that read, or
                // for the same ceiling that bounds this payload's own hold — not for a manual-paste
                // window (secure clipboard paste), which would stall every expansion behind it.
                self.registerPendingLease(
                    generation: ticket.generation,
                    deadline: residency.postedAt + InjectTiming.unverifiedPayloadResidencyCeiling
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
                                               checkElement: checkElement, follower: follower,
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

    /// Clipboard-pastes an image with the same snapshot/restore discipline as
    /// `pasteViaClipboard`. Used by image snippets only. PNG, JPEG, GIF, and TIFF
    /// attachments publish the stored file bytes; other paths keep TIFF + PNG.
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
        imagePath: String? = nil,
        bundleID: String? = nil,
        focus: FocusedElementSource,
        shouldContinue: @escaping () -> Bool = { true },
        completion: @escaping (PasteDeliveryResult) -> Void
    ) {
        let target = PasteTarget.capture(focus: focus)
        let imageRole = target.element.flatMap { AXContextChecker.shared.focusedElementRole(element: $0) }
        let verifySelection = Self.verifySelectionRange(
            bundleID: bundleID, role: imageRole, phase: .afterMutation
        )
        let checkElement = Self.verifyFocusedElement(role: imageRole, phase: .afterMutation)
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
        guard target.isCurrent(checkRange: verifySelection, checkElement: checkElement) else {
            DevTypeLog.inject.error("[Inject] image paste refused — target element or selection changed before paste")
            completion(.notPosted)
            return
        }

        // Prepare before acquiring the board: no partially prepared image may clear it.
        let prepared = expansionImageRepresentations(image: image, imagePath: imagePath)
        var representations = prepared.items
        guard !representations.isEmpty else {
            completion(.notPosted)
            return
        }
        let payloadBytes = prepared.payloadBytes
        // Markers first, as `concealedPublication` orders every marked write: the board must not
        // hold image bytes a clipboard manager could read before it holds the markers that tell it
        // to skip them.
        representations.insert(contentsOf: [
            (Self.transientType, Data()), (Self.concealedType, Data()), (Self.autoGeneratedType, Data())
        ], at: 0)
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
            // The target's own element: the pre-⌘V check below re-verifies it is still focused.
            let baseline = self.verifier.captureFocusedTextObservation(focus: .resolved(target.element))
            self.hid.postCmdVKeyEventsAsync(shouldContinue: {
                self.pasteContinuation(ticket: ticket, target: target, checkRange: verifySelection,
                                       checkElement: checkElement,
                                       allowSecureInput: false, shouldContinue: shouldContinue)
            }) { posted in
                guard posted else {
                    self.logCmdVNotPosted(
                        prefix: "[Inject] image paste refused",
                        ticket: ticket, target: target, checkRange: verifySelection,
                        checkElement: checkElement,
                        allowSecureInput: false, shouldContinue: shouldContinue
                    )
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
                                               checkElement: checkElement,
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
        return environment.snapshot(pasteboard)
    }

    /// Most times one paste re-reads the user's clipboard because it changed under the snapshot.
    private static let maxPublicationAttempts = 3

    /// The payload as one pasteboard item: the string is provided lazily, so the first read is
    /// observable (`PayloadReadWitness`), and the three nspasteboard.org markers are part of the
    /// same write — a clipboard manager that notices the change never sees the text without them.
    /// `nil` when the item cannot be built, so the write reports failure instead of publishing
    /// an unmarked payload.
    private static func payloadItem(witnessedBy witness: PayloadReadWitness) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        guard item.setDataProvider(witness, forTypes: [.string]) else { return nil }
        for marker in [transientType, concealedType, autoGeneratedType] {
            guard item.setData(Data(), forType: marker) else { return nil }
        }
        return item
    }

    /// Takes the board for one text paste: snapshot the user's clipboard, then publish `text`.
    ///
    /// The snapshot is only the user's clipboard if nothing wrote the board between reading it and
    /// clearing it. `expectedChangeCount` makes that a checked condition: a copy that lands in
    /// that gap is not overwritten with a stale restore later — the board is re-read, and the new
    /// copy is what gets snapshotted. Bounded, so a board that never stops changing fails the
    /// paste rather than spinning.
    private func publishPayload(_ text: String, on pasteboard: NSPasteboard) -> ClipboardTicket? {
        for attempt in 1...Self.maxPublicationAttempts {
            let boardBefore = pasteboard.changeCount
            let oldItems = acquireUserClipboardSnapshot(pasteboard: pasteboard)
            let generation = beginRestoreGeneration()
            let witness = PayloadReadWitness(text: text, clock: now)
            let publication = Self.publishClipboard(
                clearContents: { pasteboard.clearContents() },
                currentChangeCount: { pasteboard.changeCount },
                writes: [{
                    guard let item = Self.payloadItem(witnessedBy: witness) else { return false }
                    return pasteboard.writeObjects([item])
                }],
                expectedChangeCount: boardBefore
            )
            if case .ownershipLost = publication, attempt < Self.maxPublicationAttempts {
                DevTypeLog.inject.notice(
                    "[Clipboard] the clipboard changed under the snapshot — re-reading it (attempt \(attempt, privacy: .public))"
                )
                clearPendingTicket(generation: generation)
                continue
            }
            return ticketAfterPublication(
                publication, pasteboard: pasteboard, oldItems: oldItems, generation: generation,
                witness: witness
            )
        }
        return nil
    }

    private func registerPendingTicket(_ ticket: ClipboardTicket) {
        restoreLock.lock()
        pendingTicket = ticket
        pendingLeaseDeadline = nil
        restoreLock.unlock()
    }

    /// ⌘V for `generation`'s payload has gone out, so a host may read it until `deadline`.
    private func registerPendingLease(generation: UInt64, deadline: TimeInterval) {
        restoreLock.lock()
        if pendingTicket?.generation == generation {
            pendingLeaseDeadline = deadline
        }
        restoreLock.unlock()
    }

    private func clearPendingTicket(generation: UInt64) {
        restoreLock.lock()
        if pendingTicket?.generation == generation {
            pendingTicket = nil
            pendingLeaseDeadline = nil
        }
        restoreLock.unlock()
    }

    /// How long a new paste must hold off before it may write over the board.
    ///
    /// The previous expansion's ⌘V is already in the host's queue. If its payload has not been
    /// read yet, whoever reads next reads what is on the board *then* — so a second expansion that
    /// publishes now makes the first host paste the second expansion's text, and loses the first.
    /// Once the first payload is read (plus `payloadReadGrace`) or its lease runs out, the board
    /// may be taken; an inherited pending restore keeps the user's real clipboard for the end.
    ///
    /// Zero when there is nothing to protect: no pending lazily-published payload, the board has
    /// moved on (the user copied), or ⌘V never went out. Bounded by the lease, which is itself
    /// bounded by the residency ceiling.
    static func publicationGateWait(
        boardStillOurs: Bool,
        hasWitness: Bool,
        firstRead: TimeInterval?,
        leaseDeadline: TimeInterval?,
        now: TimeInterval
    ) -> TimeInterval {
        guard boardStillOurs, hasWitness, let leaseDeadline else { return 0 }
        if let firstRead {
            return max(0, firstRead + InjectTiming.payloadReadGrace - now)
        }
        return max(0, leaseDeadline - now)
    }

    private func currentPublicationGateWait(pasteboard: NSPasteboard) -> TimeInterval {
        restoreLock.lock()
        let pending = pendingTicket
        let lease = pendingLeaseDeadline
        restoreLock.unlock()
        return Self.publicationGateWait(
            boardStillOurs: pending.map { $0.targetChangeCount == pasteboard.changeCount } ?? false,
            hasWitness: pending?.witness != nil,
            firstRead: pending?.witness?.firstRead,
            leaseDeadline: lease,
            now: now()
        )
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

    /// Independent work bound on witness polls, for the same reason: a clock that stopped must not
    /// turn the poll into a loop. The ceiling allows `ceiling / pollInterval` = 40 of them.
    static let maxWitnessWaits = 64

    /// How much longer than the residency floor an unverified payload must stay on the board
    /// because no host has been seen to read it.
    ///
    /// The floor is a guess about how late a host can be; a read is the only proof it was not too
    /// late. So the hold can only get *longer* here, never shorter than the floor:
    /// - nobody has read the payload: keep holding, up to the hard deadline (the ceiling);
    /// - someone has: keep holding for `payloadReadGrace` after that first read, because one
    ///   paste can read the board more than once.
    /// Zero when the paste ended with read evidence (`.delivered` — AX found the text) or with no
    /// ⌘V (`.notPosted`), when the payload carries no witness, or when the board is no longer ours.
    static func witnessHoldRemaining(
        result: PasteDeliveryResult,
        hasWitness: Bool,
        firstRead: TimeInterval?,
        boardStillOurs: Bool,
        now: TimeInterval,
        residency: PayloadResidency
    ) -> TimeInterval {
        guard hasWitness, boardStillOurs else { return 0 }
        switch result {
        case .delivered, .notPosted:
            return 0
        case .failed, .unavailable:
            if let firstRead { return max(0, firstRead + InjectTiming.payloadReadGrace - now) }
            return max(0, residency.hardDeadline - now)
        }
    }

    /// Waits out the deadline, then re-asks the stall question before letting go.
    private func releaseWhenDue(
        _ ticket: ClipboardTicket,
        result: PasteDeliveryResult,
        residency: PayloadResidency?,
        notBefore: TimeInterval,
        extensionsUsed: Int = 0,
        witnessWaitsUsed: Int = 0,
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
                    witnessWaitsUsed: witnessWaitsUsed,
                    onReleased: onReleased
                )
            }
            return
        }

        // The floor has passed. Whether the host read the board by now is a fact the pasteboard
        // can tell us; a timer cannot.
        if let residency, witnessWaitsUsed < Self.maxWitnessWaits {
            let remaining = Self.witnessHoldRemaining(
                result: result,
                hasWitness: ticket.witness != nil,
                firstRead: ticket.witness?.firstRead,
                boardStillOurs: ticket.pasteboard.changeCount == ticket.targetChangeCount,
                now: now(),
                residency: residency
            )
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + min(remaining, InjectTiming.payloadWitnessPollInterval)
                ) {
                    self.releaseWhenDue(
                        ticket,
                        result: result,
                        residency: residency,
                        notBefore: notBefore,
                        extensionsUsed: extensionsUsed,
                        witnessWaitsUsed: witnessWaitsUsed + 1,
                        onReleased: onReleased
                    )
                }
                return
            }
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
                    witnessWaitsUsed: witnessWaitsUsed,
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
        /// A second clipboard publication superseded the observed copy before its text was read.
        case clipboardChanged

        public var diagnosticLabel: String {
            switch self {
            case .captured: return "captured"
            case .boardUnchanged: return "unchanged"
            case .noStringOnBoard: return "noString"
            case .postFailed: return "postFailed"
            case .sourceAppChanged: return "sourceChanged"
            case .secureInputActive: return "secureInput"
            case .clipboardChanged: return "clipboardChanged"
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

        func boundaryFailure() -> CopyCaptureOutcome? {
            if secureInputProvider() { return .secureInputActive }
            if !Self.frontmostProcessMatches(
                expectedPID: expectedFrontmostPID, actualPID: frontmostPIDProvider()
            ) { return .sourceAppChanged }
            return nil
        }

        // Snapshotting can traverse several clipboard representations. Re-check both volatile
        // gates after that work and immediately before input posting, not merely on reader entry.
        if let failure = boundaryFailure() { return failure }

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
            if let failure = boundaryFailure() { return failure }
            guard pasteboard.changeCount == baseline, now() < deadline else { break }
            usleep(pollMicroseconds)
        }
        if let failure = boundaryFailure() { return failure }
        guard pasteboard.changeCount != baseline else {
            // Nothing was written, so nothing needs restoring — the board was never touched.
            return .boardUnchanged
        }

        let afterCopy = pasteboard.changeCount

        // One extra poll interval: apps that declare types first and provide data second bump
        // `changeCount` before the string is actually there.
        usleep(pollMicroseconds)
        let capture = Self.readObservedCopy(
            expectedChangeCount: afterCopy,
            currentChangeCount: { pasteboard.changeCount },
            boundaryFailure: boundaryFailure,
            readString: { pasteboard.string(forType: .string) }
        )
        switch capture {
        case .captured, .noStringOnBoard: break
        default: return capture
        }

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

        return capture
    }

    /// A lazy string read can run target-app code. Check origin and clipboard ownership on
    /// both sides of that I/O; text from a superseding writer is never attributed to the source.
    static func readObservedCopy(
        expectedChangeCount: Int,
        currentChangeCount: () -> Int,
        boundaryFailure: () -> CopyCaptureOutcome?,
        readString: () -> String?
    ) -> CopyCaptureOutcome {
        if let failure = boundaryFailure() { return failure }
        guard currentChangeCount() == expectedChangeCount else { return .clipboardChanged }
        let text = readString()
        if let failure = boundaryFailure() { return failure }
        guard currentChangeCount() == expectedChangeCount else { return .clipboardChanged }
        guard let text else { return .noStringOnBoard }
        return .captured(text)
    }

    /// §1.7: bounded pasteboard snapshot. See `snapshotMaxItems` for the tradeoff.
    ///
    /// Representations that cannot be restored are not materialized. AppKit has no size
    /// query, so the first type that exceeds the remaining budget can still be read once.
    static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        return snapshotRepresentations(itemTypes: items.map(\.types)) { index, type in
            items[index].data(forType: type)
        }
    }

    /// Per item, then per type: skip promised types, skip a TIFF that sits beside PNG, JPEG,
    /// or GIF, and once the budget is already spent do not read this type or any later one.
    static func snapshotRepresentations(
        itemTypes: [[NSPasteboard.PasteboardType]],
        budget: Int = snapshotMaxBytes,
        maxItems: Int = snapshotMaxItems,
        read: (Int, NSPasteboard.PasteboardType) -> Data?
    ) -> PasteboardSnapshot {
        let jpeg = NSPasteboard.PasteboardType("public.jpeg")
        let gif = NSPasteboard.PasteboardType("public.gif")
        let legacyTIFF = NSPasteboard.PasteboardType("NeXT TIFF v4.0 pasteboard type")
        var result: PasteboardSnapshot = []
        var remaining = budget
        var skipped = 0

        for (index, types) in itemTypes.enumerated() where index < maxItems {
            let hasCompressedImage = types.contains { $0 == .png || $0 == jpeg || $0 == gif }
            var dict = [NSPasteboard.PasteboardType: Data]()
            for type in types {
                if snapshotSkippedTypes.contains(type.rawValue) {
                    skipped += 1
                    continue
                }
                if hasCompressedImage && (type == .tiff || type == legacyTIFF) {
                    skipped += 1
                    continue
                }
                if remaining <= 0 {
                    skipped += 1
                    continue
                }
                guard let data = read(index, type) else { continue }
                if data.count > remaining {
                    skipped += 1
                    continue
                }
                remaining -= data.count
                dict[type] = data
            }
            if !dict.isEmpty {
                result.append(dict)
            }
        }
        if itemTypes.count > maxItems {
            skipped += itemTypes.count - maxItems
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
