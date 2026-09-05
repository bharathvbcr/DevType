import AppKit
import Foundation

/// Narrow pasteboard surface used to fault-inject every write result. `NSPasteboard` reports
/// failures as booleans; ignoring those values turns a cleared clipboard into a false “Copied”.
protocol SecretPasteboardWriting: AnyObject {
    var changeCount: Int { get }
    @discardableResult func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: SecretPasteboardWriting {}

/// Puts a secret on the pasteboard for a manual ⌘V, and takes it off again.
///
/// This is the path that works when nothing else does. While a password field holds focus, macOS
/// Secure Event Input withholds keyboard events from every event tap *and* from hotkey
/// registration (TN2150), so DevType can neither see a typed trigger nor be summoned by a chord.
/// A menu-bar click needs neither: the menu is driven by the mouse, and the clipboard write is an
/// ordinary API call rather than a synthesised keystroke. The user then presses ⌘V themselves,
/// which is their own keystroke going to their own app — nothing DevType has to intercept.
///
/// The cost is that the value sits on the pasteboard, so this class exists mainly to bound that:
/// marked concealed for clipboard managers, and cleared on a timer that refuses to clear anything
/// the user copied afterwards.
public final class SecretClipboard {
    public static let shared = SecretClipboard()

    /// How long a copied secret stays on the pasteboard before being cleared.
    ///
    /// Long enough to switch apps, click the field and paste — including a slow first attempt in a
    /// browser that re-prompts for the account. Short enough that walking away from the machine
    /// does not leave a password on the clipboard for the rest of the day. The clear is also
    /// forced at quit; a timer alone would leave the value behind on a crash.
    public static let defaultClearAfter: TimeInterval = 90

    /// Result of a scheduled clear, so the caller can report honestly instead of assuming.
    public enum ClearOutcome: String, Equatable, Sendable {
        /// Our payload was still there and has been removed.
        case cleared
        /// The user (or another app) copied something afterwards. Left strictly alone.
        case supersededByUser
        /// Nothing was outstanding.
        case nothingToClear
    }

    public enum CopyOutcome: Equatable, Sendable {
        case copied(clearAt: Date)
        case empty
        case writeFailed

        public var didCopy: Bool {
            if case .copied = self { return true }
            return false
        }
    }

    private struct Ownership {
        let ticket: UInt64
        /// `changeCount` of the write we own. A later value means another writer owns the board.
        let changeCount: Int
    }

    /// Serializes this class's pasteboard I/O as well as ownership publication. External writers
    /// remain protected by the `changeCount` comparison; this lock only prevents two DevType copy
    /// and clear operations from interleaving their multi-write concealed payloads.
    private let operationLock = NSLock()
    private let lock = UnfairLock()
    private var nextOwnershipTicket: UInt64 = 0
    private var activeOwnership: Ownership?
    private var clearWorkItem: DispatchWorkItem?

    public init() {}

    /// Pure policy: may a scheduled clear actually wipe the pasteboard?
    ///
    /// Only when the board still holds *our* write. This is the same rule as the expansion
    /// restore path and it matters more here: a user who copies a bank account number thirty
    /// seconds after copying a password must not have it wiped by our timer. When in doubt, leave
    /// the clipboard alone — the cost of a missed clear is a secret living longer than intended,
    /// the cost of a wrong clear is destroying something the user is mid-way through using.
    public static func mayClear(ownedChangeCount: Int?, currentChangeCount: Int) -> Bool {
        guard let ownedChangeCount else { return false }
        return ownedChangeCount == currentChangeCount
    }

    /// Copy a secret to the pasteboard and schedule its removal.
    ///
    /// - Returns: when the value will be cleared, for the confirmation the UI shows. `nil` when
    ///   nothing was copied (empty value — never write an empty "secret" and claim success).
    @discardableResult
    public func copy(
        _ secret: String,
        clearAfter: TimeInterval = defaultClearAfter,
        pasteboard: NSPasteboard = .general,
        broker: PasteboardBroker? = .shared,
        schedule: ((@escaping () -> Void, TimeInterval) -> Void)? = nil
    ) -> Date? {
        guard case .copied(let clearAt) = copyResult(
            secret,
            clearAfter: clearAfter,
            pasteboardWriter: pasteboard,
            broker: broker,
            schedule: schedule
        ) else { return nil }
        return clearAt
    }

    @discardableResult
    public func copyResult(
        _ secret: String,
        clearAfter: TimeInterval = defaultClearAfter,
        pasteboard: NSPasteboard = .general,
        broker: PasteboardBroker? = .shared,
        schedule: ((@escaping () -> Void, TimeInterval) -> Void)? = nil
    ) -> CopyOutcome {
        copyResult(
            secret,
            clearAfter: clearAfter,
            pasteboardWriter: pasteboard,
            broker: broker,
            schedule: schedule
        )
    }

    /// Typed copy used by UI surfaces that must distinguish empty input from an actual
    /// pasteboard failure. All four writes are required: without the concealment/transient
    /// markers, a password may enter clipboard history, so a partial write is removed and fails.
    @discardableResult
    func copyResult(
        _ secret: String,
        clearAfter: TimeInterval = defaultClearAfter,
        pasteboardWriter: SecretPasteboardWriting,
        broker: PasteboardBroker? = .shared,
        schedule: ((@escaping () -> Void, TimeInterval) -> Void)? = nil
    ) -> CopyOutcome {
        guard !secret.isEmpty else { return .empty }

        operationLock.lock()

        lock.lock()
        nextOwnershipTicket &+= 1
        if nextOwnershipTicket == 0 { nextOwnershipTicket = 1 }
        let ticket = nextOwnershipTicket
        let supersededWork = clearWorkItem
        clearWorkItem = nil
        activeOwnership = nil
        lock.unlock()
        supersededWork?.cancel()

        // A deliberate secret copy supersedes any prior automatic clipboard session.
        broker?.invalidatePendingRestore()

        let writer = pasteboardWriter
        let publication = PasteboardBroker.publishClipboard(
            clearContents: { writer.clearContents() },
            currentChangeCount: { writer.changeCount },
            writes: [
                { writer.setString(secret, forType: .string) },
                { writer.setData(Data(), forType: PasteboardBroker.concealedType) },
                { writer.setData(Data(), forType: PasteboardBroker.transientType) },
                { writer.setData(Data(), forType: PasteboardBroker.autoGeneratedType) },
            ]
        )
        let ownedChangeCount: Int
        switch publication {
        case .published(let owned):
            ownedChangeCount = owned
        case .writeFailed(let owned):
            // A partial secret must not remain unmarked. The original clear count is
            // the authority; sampling a newer owner's count would erase their copy.
            if Self.mayClear(ownedChangeCount: owned, currentChangeCount: writer.changeCount) {
                writer.clearContents()
            }
            operationLock.unlock()
            DevTypeLog.inject.error("[Secret] clipboard publication failed")
            return .writeFailed
        case .ownershipLost, .notPrepared:
            operationLock.unlock()
            DevTypeLog.inject.error("[Secret] clipboard ownership changed during publication")
            return .writeFailed
        }

        let clearAction = { [weak self] in
            _ = self?.clearIfStillOurs(
                pasteboardWriter: writer,
                expectedTicket: ticket
            )
        }
        let work = schedule == nil ? DispatchWorkItem(block: clearAction) : nil

        lock.lock()
        activeOwnership = Ownership(ticket: ticket, changeCount: ownedChangeCount)
        clearWorkItem = work
        lock.unlock()
        operationLock.unlock()

        if let schedule {
            // Custom schedulers cannot be cancelled by `DispatchWorkItem`; the ticket makes an old
            // callback harmless after a newer copy, manual clear, or explicit invalidation.
            schedule(clearAction, clearAfter)
        } else if let work {
            DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter, execute: work)
        }

        // Length only. The value never reaches a log line, here or anywhere.
        DevTypeLog.inject.info(
            """
            [Secret] copied to clipboard chars=\(secret.count, privacy: .public) \
            clearAfter=\(Int(clearAfter), privacy: .public)s
            """
        )
        return .copied(clearAt: Date().addingTimeInterval(clearAfter))
    }

    /// Remove the secret now, if the board still holds ours. Safe to call at any time.
    @discardableResult
    public func clearIfStillOurs(pasteboard: NSPasteboard = .general) -> ClearOutcome {
        clearIfStillOurs(pasteboardWriter: pasteboard, expectedTicket: nil)
    }

    /// Internal writer seam makes ownership interleavings deterministic in tests. A scheduled clear
    /// supplies its ticket; a manual/quit clear passes nil and claims whichever write is current.
    @discardableResult
    func clearIfStillOurs(
        pasteboardWriter: SecretPasteboardWriting,
        expectedTicket: UInt64?
    ) -> ClearOutcome {
        operationLock.lock()
        lock.lock()
        let ownership = activeOwnership
        lock.unlock()

        guard let ownership,
              expectedTicket == nil || expectedTicket == ownership.ticket else {
            operationLock.unlock()
            return .nothingToClear
        }

        let outcome: ClearOutcome
        if Self.mayClear(
            ownedChangeCount: ownership.changeCount,
            currentChangeCount: pasteboardWriter.changeCount
        ) {
            pasteboardWriter.clearContents()
            outcome = .cleared
        } else {
            outcome = .supersededByUser
        }

        lock.lock()
        let pending = clearWorkItem
        if activeOwnership?.ticket == ownership.ticket {
            activeOwnership = nil
            clearWorkItem = nil
        }
        lock.unlock()
        operationLock.unlock()
        pending?.cancel()

        DevTypeLog.inject.info("[Secret] clipboard clear → \(outcome.rawValue, privacy: .public)")
        return outcome
    }

    /// True while a copied secret is still believed to be on the pasteboard.
    public var hasOutstandingSecret: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeOwnership != nil
    }
}
