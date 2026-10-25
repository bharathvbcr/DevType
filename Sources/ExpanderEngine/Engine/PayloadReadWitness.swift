import AppKit
import Foundation

/// The pasteboard's own proof that a host read our payload.
///
/// Nothing else proves it. A synthetic ⌘V is fire-and-forget, `changeCount` does not move when
/// someone reads, and AX cannot see inside a web view, so the release of the user's clipboard was
/// a timer. A timer is a guess about how late a host can be: Safari and Chromium read the board
/// from a content process that can sit behind a busy UI process for far longer than the floor,
/// and a host that read after the restore pasted the user's *previous clipboard* instead of the
/// snippet.
///
/// The payload string is therefore published as a lazily provided representation. The pasteboard
/// calls `pasteboard(_:item:provideDataForType:)` when — and only when — a reader asks for the
/// data, whichever API it used (`stringForType:`, `pasteboardItems`, `readObjects`, the legacy
/// string type), and in whichever process. That call is the witness. Reading the list of types
/// does not fire it, so a clipboard manager that merely notices the change is not a reader.
///
/// What a witness may and may not do is the broker's policy, not this type's. Briefly: it can
/// only *lengthen* a hold (an unread payload is held toward the ceiling) and shorten a following
/// expansion's wait; a read never lowers the residency floor, because a clipboard manager that
/// ignores the Transient marker reads immediately and proves nothing about the host.
///
/// Verified against AppKit with a reader in a separate process (named pasteboard): the provider
/// fires once on the first read from every read API above, is served from cache for later reads,
/// and is not retained by us — the pasteboard keeps it until the content is cleared or finished.
final class PayloadReadWitness: NSObject, NSPasteboardItemDataProvider {
    private let text: String
    private let clock: () -> TimeInterval
    private let lock = UnfairLock()
    private var readAt: TimeInterval?

    init(text: String, clock: @escaping () -> TimeInterval) {
        self.text = text
        self.clock = clock
    }

    /// When a reader first asked for the payload, on the broker's clock; `nil` while unread.
    var firstRead: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return readAt
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        if readAt == nil { readAt = clock() }
        lock.unlock()
        if !item.setString(text, forType: type) {
            DevTypeLog.inject.error(
                "[Clipboard] could not provide the payload to a reader (type=\(type.rawValue, privacy: .public))"
            )
        }
    }
}
